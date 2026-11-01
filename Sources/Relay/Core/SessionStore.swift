import Foundation

struct SessionLoadIssue: Identifiable, Sendable {
    let fileURL: URL
    let message: String
    var id: URL { fileURL }
}

struct SessionLoadResult: Sendable {
    let sessions: [TranscriptSession]
    let issues: [SessionLoadIssue]
}

enum SessionStoreError: LocalizedError {
    case invalidDocument(String)
    case unsupportedVersion(Int)
    case unreadableSession(URL, String)
    case duplicateIdentifier(URL)
    case unavailableDocument

    var errorDescription: String? {
        switch self {
        case .invalidDocument(let reason): "The transcript data is invalid. \(reason)"
        case .unsupportedVersion(let version): "This transcript uses an unsupported file format (version \(version))."
        case .unreadableSession(let url, let reason): "“\(url.lastPathComponent)” could not be opened. \(reason) The file has been kept."
        case .duplicateIdentifier(let url): "“\(url.lastPathComponent)” has the same identifier as another transcript. Both files have been kept."
        case .unavailableDocument: "This transcript is no longer in its previous location. Open it from Finder to continue."
        }
    }
}

/// A .relay document is versioned JSON. Files are coordinated with Finder and
/// iCloud Drive and retain readable names; the stable UUID lives inside the file.
struct SessionStore: Sendable {
    let directory: URL
    private static let formatVersion = 1
    private static let maximumFileSize = 32 * 1024 * 1024
    private struct Envelope: Codable { let version: Int; let session: TranscriptSession }

    init(directory: URL? = nil) { self.directory = directory ?? RelayStorageLocation.localDirectory }

    func documentURLs() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "relay" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func load() throws -> [TranscriptSession] {
        let result = try loadRecovering()
        if let issue = result.issues.first { throw SessionStoreError.unreadableSession(issue.fileURL, issue.message) }
        return result.sessions
    }

    func loadRecovering() throws -> SessionLoadResult {
        var sessions: [TranscriptSession] = []
        var issues: [SessionLoadIssue] = []
        var identifiers = Set<UUID>()
        for file in try documentURLs() {
            do {
                let item = try read(at: file)
                guard identifiers.insert(item.id).inserted else { throw SessionStoreError.duplicateIdentifier(file) }
                sessions.append(item)
            } catch { issues.append(SessionLoadIssue(fileURL: file, message: error.localizedDescription)) }
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        return SessionLoadResult(sessions: sessions, issues: issues)
    }

    func read(at url: URL) throws -> TranscriptSession {
        try coordinatedRead(at: url) { file in
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumFileSize else {
                throw SessionStoreError.invalidDocument("The session file is too large or unavailable.")
            }
            var session = try Self.decode(Data(contentsOf: file))
            session.title = file.deletingPathExtension().lastPathComponent
            return session
        }
    }

    /// A supplied URL is authoritative, including a file the user moved outside
    /// Relay's default folder. Autosaving never renames that file from stale UI.
    @discardableResult
    func save(_ session: TranscriptSession, at existingURL: URL? = nil, presenter: NSFilePresenter? = nil) throws -> URL {
        try Self.validate(session)
        let existing = existingURL ?? existingURLForID(session.id)
        if let existing {
            guard FileManager.default.fileExists(atPath: existing.path) else { throw SessionStoreError.unavailableDocument }
            return try coordinatedWrite(at: existing, options: .forReplacing, presenter: presenter) { file in
                let previous = try Self.decode(Data(contentsOf: file))
                guard previous.id == session.id else {
                    throw SessionStoreError.unreadableSession(file, "Its session identifier has changed.")
                }
                var snapshot = Self.merging(session, with: previous)
                snapshot.title = file.deletingPathExtension().lastPathComponent
                try Self.encoded(snapshot).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return file
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let baseName = Self.documentName(for: session)
        for suffix in 1...10_000 {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let destination = directory.appendingPathComponent(name).appendingPathExtension("relay")
            do {
                return try coordinatedWrite(at: destination, options: []) { file in
                    guard !FileManager.default.fileExists(atPath: file.path) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    var snapshot = session
                    snapshot.title = name
                    // Write complete content to a hidden sibling first. Moving
                    // it into place reserves the name without exposing an empty
                    // document or overwriting a file created by another process.
                    let staging = directory.appendingPathComponent(".relay-write-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try Self.encoded(snapshot).write(to: staging, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
                    try FileManager.default.moveItem(at: staging, to: file)
                    return file
                }
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw SessionStoreError.invalidDocument("Choose a different transcript name.")
    }

    /// Only an explicit rename action changes a filename. Finder moves remain
    /// authoritative for subsequent autosaves.
    func rename(at original: URL, to title: String, presenter: NSFilePresenter? = nil) throws -> URL {
        let baseName = Self.sanitizedName(title)
        let parent = original.deletingLastPathComponent()
        if original.deletingPathExtension().lastPathComponent == baseName { return original }
        for suffix in 1...10_000 {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let destination = parent.appendingPathComponent(name).appendingPathExtension("relay")
            if original.standardizedFileURL == destination.standardizedFileURL { return original }
            var coordinationError: NSError?
            var result: Result<URL, any Error>?
            let coordinator = NSFileCoordinator(filePresenter: presenter)
            coordinator.coordinate(writingItemAt: original, options: .forMoving,
                                   writingItemAt: destination, options: [], error: &coordinationError) { source, target in
                result = Result {
                    guard !FileManager.default.fileExists(atPath: target.path) else { throw CocoaError(.fileWriteFileExists) }
                    try FileManager.default.moveItem(at: source, to: target)
                    coordinator.item(at: source, didMoveTo: target)
                    return target
                }
            }
            do {
                if let coordinationError { throw coordinationError }
                guard let result else { throw SessionStoreError.unavailableDocument }
                return try result.get()
            } catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
        }
        throw SessionStoreError.invalidDocument("Choose a different transcript name.")
    }

    func delete(id: UUID, at url: URL? = nil, moveToTrash: Bool = false, presenter: NSFilePresenter? = nil) throws {
        guard let file = url ?? existingURLForID(id) else { return }
        try coordinatedWrite(at: file, options: .forDeleting, presenter: presenter) { location in
            if FileManager.default.fileExists(atPath: location.path) {
                if moveToTrash {
                    try FileManager.default.trashItem(at: location, resultingItemURL: nil)
                } else {
                    try FileManager.default.removeItem(at: location)
                }
            }
        }
    }

    func fileURL(for id: UUID) -> URL {
        existingURLForID(id) ?? directory.appendingPathComponent(id.uuidString).appendingPathExtension("relay")
    }

    func existingURLForID(_ id: UUID) -> URL? {
        guard let urls = try? documentURLs() else { return nil }
        return urls.first { (try? read(at: $0).id) == id }
    }

    private static func documentName(for session: TranscriptSession) -> String {
        if !session.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return sanitizedName(session.title) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Transcript " + formatter.string(from: session.startedAt)
    }

    private static func sanitizedName(_ title: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0000}").union(.controlCharacters))
            .filter { !$0.isEmpty }.joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        return cleaned.isEmpty ? "Transcript" : String(cleaned.prefix(120))
    }

    private static func decode(_ data: Data) throws -> TranscriptSession {
        guard data.count <= maximumFileSize else { throw SessionStoreError.invalidDocument("The session file is too large.") }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.version == formatVersion else { throw SessionStoreError.unsupportedVersion(envelope.version) }
        try validate(envelope.session)
        return envelope.session
    }

    private static func encoded(_ session: TranscriptSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(Envelope(version: formatVersion, session: session))
        guard data.count <= maximumFileSize else { throw SessionStoreError.invalidDocument("The transcript exceeds the supported file size.") }
        return data
    }

    private static func merging(_ incoming: TranscriptSession, with saved: TranscriptSession) -> TranscriptSession {
        var copy = incoming
        let incomingIDs = Set(incoming.segments.map(\.id))
        // Unfinished hypotheses can be retracted by the recognizer. Preserve
        // independent finalized phrases, but never restore a saved partial that
        // is absent from the caller's latest authoritative transcript.
        var segments = saved.segments.filter { $0.isFinal || incomingIDs.contains($0.id) }
        for segment in incoming.segments {
            if let index = segments.firstIndex(where: { $0.id == segment.id }) {
                if !segments[index].isFinal || segment.isFinal {
                    var replacement = segment
                    let savedPhrase = segments[index]
                    if savedPhrase.isFinal, savedPhrase.timingIsConfirmed,
                       segment.isFinal, !segment.timingIsConfirmed,
                       savedPhrase.source == segment.source, savedPhrase.text == segment.text {
                        // An external update may confirm this exact phrase
                        // before the caller's next autosave reaches disk.
                        replacement.timestamp = savedPhrase.timestamp
                        replacement.timingIsConfirmed = true
                    }
                    segments[index] = replacement
                }
            } else { segments.append(segment) }
        }
        copy.segments = TranscriptFormatting.ordered(segments)
        return copy
    }

    private static func validate(_ session: TranscriptSession) throws {
        guard TranscriptLanguage.isValid(session.languageID) else {
            throw SessionStoreError.invalidDocument("Its transcription language is invalid.")
        }
        guard !session.sources.isEmpty else {
            throw SessionStoreError.invalidDocument("Choose at least one audio source.")
        }
        if let duration = session.recordedDuration, !duration.isFinite || duration < 0 {
            throw SessionStoreError.invalidDocument("Its recorded duration is invalid.")
        }
        guard session.startedAt.timeIntervalSinceReferenceDate.isFinite,
              session.endedAt?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw SessionStoreError.invalidDocument("Its recording dates are invalid.")
        }
        if let endedAt = session.endedAt, endedAt < session.startedAt {
            throw SessionStoreError.invalidDocument("Its end time is earlier than its start time.")
        }
        var identifiers = Set<UUID>()
        for segment in session.segments {
            guard identifiers.insert(segment.id).inserted else { throw SessionStoreError.invalidDocument("It contains duplicate phrases.") }
            guard segment.timestamp.isFinite, segment.timestamp >= 0 else { throw SessionStoreError.invalidDocument("It contains an invalid phrase time.") }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionStoreError.invalidDocument("It contains an empty phrase.") }
        }
    }

    private func coordinatedRead<T>(at url: URL, body: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { file in
            result = Result { try body(file) }
        }
        if let error { throw error }
        guard let result else { throw SessionStoreError.unavailableDocument }
        return try result.get()
    }

    private func coordinatedWrite<T>(at url: URL, options: NSFileCoordinator.WritingOptions,
                                     presenter: NSFilePresenter? = nil, body: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, any Error>?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: options, error: &error) { file in
            result = Result { try body(file) }
        }
        if let error { throw error }
        guard let result else { throw SessionStoreError.unavailableDocument }
        return try result.get()
    }
}
