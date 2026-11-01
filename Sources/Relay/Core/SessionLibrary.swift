import Foundation

enum RelayLibraryEvent: Sendable {
    case discovered(TranscriptSession, URL)
    case updated(TranscriptSession, URL)
    case removed(UUID)
    case issue(String)
}

/// Coordinates native documents and honors the order of user intent rather
/// than the order in which asynchronous save tasks reach this actor.
actor SessionLibrary {
    private let store: SessionStore
    private let bookmarksURL: URL
    private let trashOnDelete: Bool
    private var latestRevision: [UUID: UInt64] = [:]
    private var deletedIDs: Set<UUID> = []
    private var locations: [UUID: URL] = [:]
    private var presenters: [UUID: RelayDocumentPresenter] = [:]
    private var folderPresenter: RelayFolderPresenter?
    private var reportedCandidates: Set<URL> = []
    private var scopedURLs: [UUID: URL] = [:]
    private var bookmarks: [String: Data] = [:]
    private var onChange: (@MainActor @Sendable (RelayLibraryEvent) -> Void)?

    init(directory: URL? = nil, bookmarksURL: URL? = nil, trashOnDelete: Bool = false) {
        store = SessionStore(directory: directory)
        self.bookmarksURL = bookmarksURL ?? (directory?.appendingPathComponent(".relay-state", isDirectory: true)
            .appendingPathComponent("Recent Documents.json") ?? RelayStorageLocation.bookmarksURL)
        self.trashOnDelete = trashOnDelete
    }

    deinit {
        if let folderPresenter { NSFileCoordinator.removeFilePresenter(folderPresenter) }
        for presenter in presenters.values { NSFileCoordinator.removeFilePresenter(presenter) }
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
    }

    func setChangeHandler(_ handler: @escaping @MainActor @Sendable (RelayLibraryEvent) -> Void) {
        onChange = handler
        observeDefaultDirectory()
    }

    func load() throws -> SessionLoadResult {
        observeDefaultDirectory()
        var sessions: [TranscriptSession] = []
        var issues: [SessionLoadIssue] = []
        for url in try store.documentURLs() {
            do {
                let item = try store.read(at: url)
                if let existing = documentURL(for: item.id),
                   existing.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() {
                    throw SessionStoreError.duplicateIdentifier(url)
                }
                register(item.id, at: url)
                sessions.append(item)
            } catch { issues.append(SessionLoadIssue(fileURL: url, message: error.localizedDescription)) }
        }
        if FileManager.default.fileExists(atPath: bookmarksURL.path) {
            do { bookmarks = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: bookmarksURL)) }
            catch { issues.append(SessionLoadIssue(fileURL: bookmarksURL, message: "Some recent document locations couldn’t be restored. The location file has been kept.")) }
        }
        for (id, data) in bookmarks {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !Self.isInTrash(url), FileManager.default.fileExists(atPath: url.path) else { continue }
                if locations.values.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) { continue }
                let item = try open(at: url, remember: stale)
                guard item.id.uuidString == id else { throw SessionStoreError.invalidDocument("A recent transcript's identifier has changed.") }
                sessions.append(item)
            } catch { issues.append(SessionLoadIssue(fileURL: bookmarksURL, message: error.localizedDescription)) }
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        return SessionLoadResult(sessions: sessions, issues: issues)
    }

    func open(at url: URL, remember: Bool = true) throws -> TranscriptSession {
        guard url.isFileURL, url.pathExtension.lowercased() == "relay", !Self.isInTrash(url) else {
            throw SessionStoreError.invalidDocument("Choose a Relay transcript outside the Trash.")
        }
        let accessing = url.startAccessingSecurityScopedResource()
        do {
            let item = try store.read(at: url)
            if let existing = documentURL(for: item.id),
               existing.standardizedFileURL.resolvingSymlinksInPath() != url.standardizedFileURL.resolvingSymlinksInPath() {
                throw SessionStoreError.duplicateIdentifier(url)
            }
            if accessing {
                if let old = scopedURLs[item.id] { old.stopAccessingSecurityScopedResource() }
                scopedURLs[item.id] = url
            }
            deletedIDs.remove(item.id)
            register(item.id, at: url)
            if remember {
                do { try rememberLocation(item.id, at: url) }
                catch { emit(.issue("The transcript is open, but its location couldn’t be saved for the next launch. " + error.localizedDescription)) }
            }
            return item
        } catch {
            if accessing { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    @discardableResult
    func save(_ session: TranscriptSession, revision: UInt64) throws -> Bool {
        guard !deletedIDs.contains(session.id), accepts(revision, for: session.id) else { return false }
        latestRevision[session.id] = revision
        let savedURL = try store.save(session, at: documentURL(for: session.id), presenter: presenters[session.id])
        register(session.id, at: savedURL)
        observeDefaultDirectory()
        return true
    }

    @discardableResult
    func rename(_ session: TranscriptSession, to title: String, revision: UInt64) throws -> Bool {
        guard !deletedIDs.contains(session.id), accepts(revision, for: session.id) else { return false }
        latestRevision[session.id] = revision
        let original = documentURL(for: session.id) ?? store.existingURLForID(session.id)
        if let original {
            let moved = try store.rename(at: original, to: title, presenter: presenters[session.id])
            register(session.id, at: moved)
            try rememberLocation(session.id, at: moved)
            try store.save(session, at: moved, presenter: presenters[session.id])
        } else {
            var copy = session
            copy.title = title
            let created = try store.save(copy)
            register(session.id, at: created)
        }
        observeDefaultDirectory()
        return true
    }

    @discardableResult
    func delete(_ id: UUID, revision: UInt64) throws -> Bool {
        guard accepts(revision, for: id) else { return false }
        latestRevision[id] = revision
        try store.delete(id: id, at: documentURL(for: id), moveToTrash: trashOnDelete, presenter: presenters[id])
        remove(id)
        return true
    }

    func documentURL(for id: UUID) -> URL? {
        presenters[id]?.presentedItemURL ?? locations[id]
    }

    private func observeDefaultDirectory() {
        guard folderPresenter == nil,
              FileManager.default.fileExists(atPath: store.directory.path) else { return }
        let presenter = RelayFolderPresenter(directory: store.directory) { [weak self] url in
            Task { await self?.discoverCandidate(at: url) }
        }
        folderPresenter = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    private func discoverCandidate(at proposedURL: URL?) {
        let candidates: [URL]
        if let proposedURL { candidates = [proposedURL] }
        else { candidates = (try? store.documentURLs()) ?? [] }
        let root = store.directory.standardizedFileURL.resolvingSymlinksInPath()
        for url in candidates {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard url.pathExtension.lowercased() == "relay", !url.lastPathComponent.hasPrefix("."),
                  canonical.deletingLastPathComponent() == root,
                  FileManager.default.fileExists(atPath: url.path), !Self.isInTrash(url) else { continue }
            // Own writes and callbacks for already-presented documents must not
            // reinsert history items or generate an observation/save loop.
            if locations.keys.contains(where: {
                documentURL(for: $0)?.standardizedFileURL.resolvingSymlinksInPath() == canonical
            }) { continue }
            do {
                let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try FileManager.default.startDownloadingUbiquitousItem(at: url)
                    continue
                }
                let item = try store.read(at: url)
                guard !deletedIDs.contains(item.id) else { continue }
                if let existing = documentURL(for: item.id) {
                    if FileManager.default.fileExists(atPath: existing.path) {
                        throw SessionStoreError.duplicateIdentifier(url)
                    }
                    // A folder notification may arrive before the individual
                    // file presenter's move notification. Follow the same file.
                    register(item.id, at: url)
                    emit(.updated(item, url))
                } else {
                    register(item.id, at: url)
                    emit(.discovered(item, url))
                }
                reportedCandidates.remove(canonical)
            } catch {
                // Partial downloads and repeated provider notifications should
                // not create repeated alerts for an unchanged invalid file.
                if reportedCandidates.insert(canonical).inserted { emit(.issue(error.localizedDescription)) }
            }
        }
    }

    private func accepts(_ revision: UInt64, for id: UUID) -> Bool {
        guard let latest = latestRevision[id] else { return true }
        return revision > latest
    }

    private func register(_ id: UUID, at url: URL) {
        locations[id] = url
        if let existing = presenters[id] {
            if existing.presentedItemURL?.standardizedFileURL == url.standardizedFileURL { return }
            NSFileCoordinator.removeFilePresenter(existing)
        }
        let presenter = RelayDocumentPresenter(url: url) { [weak self] event in
            Task { await self?.handle(event, for: id) }
        }
        presenters[id] = presenter
        NSFileCoordinator.addFilePresenter(presenter)
    }

    private func handle(_ event: RelayFileEvent, for id: UUID) {
        guard !deletedIDs.contains(id) else { return }
        switch event {
        case .removed:
            remove(id)
            emit(.removed(id))
        case .moved(let url):
            if Self.isInTrash(url) {
                remove(id)
                emit(.removed(id))
                return
            }
            locations[id] = url
            do {
                try rememberLocation(id, at: url)
                let item = try store.read(at: url)
                emit(.updated(item, url))
            } catch { emit(.issue(error.localizedDescription)) }
        case .changed:
            guard let url = documentURL(for: id) else { return }
            do {
                let item = try store.read(at: url)
                guard item.id == id else { throw SessionStoreError.invalidDocument("The document's identifier has changed.") }
                emit(.updated(item, url))
            } catch {
                if !FileManager.default.fileExists(atPath: url.path) {
                    remove(id)
                    emit(.removed(id))
                } else { emit(.issue(error.localizedDescription)) }
            }
        }
    }

    private func remove(_ id: UUID) {
        deletedIDs.insert(id)
        locations.removeValue(forKey: id)
        if let presenter = presenters.removeValue(forKey: id) { NSFileCoordinator.removeFilePresenter(presenter) }
        if let url = scopedURLs.removeValue(forKey: id) { url.stopAccessingSecurityScopedResource() }
        bookmarks.removeValue(forKey: id.uuidString)
        try? saveBookmarks()
    }

    private func rememberLocation(_ id: UUID, at url: URL) throws {
        let root = store.directory.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        if url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root) {
            if bookmarks.removeValue(forKey: id.uuidString) != nil { try saveBookmarks() }
            return
        }
        bookmarks[id.uuidString] = try url.bookmarkData(options: .withSecurityScope,
            includingResourceValuesForKeys: nil, relativeTo: nil)
        try saveBookmarks()
    }

    private func saveBookmarks() throws {
        let parent = bookmarksURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try JSONEncoder().encode(bookmarks).write(to: bookmarksURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bookmarksURL.path)
    }

    private func emit(_ event: RelayLibraryEvent) {
        guard let onChange else { return }
        Task { @MainActor in onChange(event) }
    }

    private static func isInTrash(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/.Trash/") || path.contains("/.Trashes/")
    }
}
