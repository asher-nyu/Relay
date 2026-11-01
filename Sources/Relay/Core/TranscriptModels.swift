import Foundation

enum TranscriptLanguage {
    static let defaultID = "en-US"

    static func canonicalID(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.lowercased() == "auto" ? "auto" : trimmed.replacingOccurrences(of: "_", with: "-")
    }

    /// Documents retain language identifiers even when a model is not installed
    /// on this Mac. Availability is a capture concern, not a migration rule.
    static func isValid(_ value: String) -> Bool {
        let canonical = canonicalID(value)
        return canonical == "auto" || canonical.range(
            of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression
        ) != nil
    }
}

enum TranscriptSource: String, Codable, CaseIterable, Hashable, Sendable {
    case systemAudio
    case microphone

    var displayName: String {
        switch self {
        case .systemAudio: "System audio"
        case .microphone: "Microphone"
        }
    }

    var systemImage: String {
        switch self {
        case .systemAudio: "speaker.wave.2"
        case .microphone: "mic"
        }
    }
}

struct TranscriptUpdate: Sendable {
    let segmentID: UUID
    let source: TranscriptSource
    let text: String
    let isFinal: Bool
    let timestamp: TimeInterval
    let timingIsConfirmed: Bool

    init(
        segmentID: UUID,
        source: TranscriptSource,
        text: String,
        isFinal: Bool,
        timestamp: TimeInterval,
        timingIsConfirmed: Bool? = nil
    ) {
        self.segmentID = segmentID
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.timingIsConfirmed = timingIsConfirmed ?? isFinal
    }
}

struct TranscriptSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let source: TranscriptSource
    var text: String
    var isFinal: Bool
    var timestamp: TimeInterval
    var timingIsConfirmed: Bool

    private enum CodingKeys: String, CodingKey {
        case id, source, text, isFinal, timestamp, timingIsConfirmed
    }

    init(
        id: UUID = UUID(),
        source: TranscriptSource,
        text: String,
        isFinal: Bool = true,
        timestamp: TimeInterval,
        timingIsConfirmed: Bool? = nil
    ) {
        self.id = id
        self.source = source
        self.text = text
        self.isFinal = isFinal
        self.timestamp = timestamp
        self.timingIsConfirmed = timingIsConfirmed ?? isFinal
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        source = try values.decode(TranscriptSource.self, forKey: .source)
        text = try values.decode(String.self, forKey: .text)
        isFinal = try values.decode(Bool.self, forKey: .isFinal)
        timestamp = try values.decode(TimeInterval.self, forKey: .timestamp)
        // Older files have precise times for final phrases, while stored live
        // hypotheses remain provisional. An explicit false is never upgraded.
        timingIsConfirmed = values.contains(.timingIsConfirmed)
            ? try values.decode(Bool.self, forKey: .timingIsConfirmed) : isFinal
    }

    var timeLabel: String {
        guard isFinal else { return "Live" }
        return timingIsConfirmed ? TranscriptFormatting.timeLabel(timestamp) : ""
    }

    var metadataLabel: String {
        let time = timeLabel
        return time.isEmpty ? source.displayName : "\(source.displayName) · \(time)"
    }
}

/// A recognizer may revise both the words and their timing until a phrase is
/// finalized. Stable identifiers replace hypotheses in place; corrected times
/// keep the combined audio sources in chronological order.
struct SessionTranscript: Equatable, Sendable {
    private(set) var segments: [TranscriptSegment]
    // A retracted final result seals its identifier just as a visible final
    // phrase does. Late partials must not recreate a removed hypothesis.
    private var retractedIDs: Set<UUID> = []

    init(segments: [TranscriptSegment] = []) {
        self.segments = []
        for segment in segments {
            apply(TranscriptUpdate(
                segmentID: segment.id,
                source: segment.source,
                text: segment.text,
                isFinal: segment.isFinal,
                timestamp: segment.timestamp,
                timingIsConfirmed: segment.timingIsConfirmed
            ))
        }
    }

    @discardableResult
    mutating func apply(_ update: TranscriptUpdate) -> Bool {
        guard update.timestamp.isFinite, update.timestamp >= 0,
              !retractedIDs.contains(update.segmentID) else { return false }
        let text = update.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let containsSpeech = text.contains { $0.isLetter || $0.isNumber }

        if let index = segments.firstIndex(where: { $0.id == update.segmentID }) {
            guard segments[index].source == update.source else { return false }
            if segments[index].isFinal {
                // A drained phrase may have words but no authoritative clock.
                // Only an identical final can add that missing clock later.
                guard !segments[index].timingIsConfirmed, update.isFinal,
                      update.timingIsConfirmed, segments[index].text == text else { return false }
                segments[index].timestamp = update.timestamp
                segments[index].timingIsConfirmed = true
                segments = TranscriptFormatting.ordered(segments)
                return true
            }
            // An empty or punctuation-only final retracts a live hypothesis.
            guard containsSpeech else {
                guard update.isFinal else { return false }
                retractedIDs.insert(update.segmentID)
                segments.remove(at: index)
                return true
            }
            guard segments[index].text != text || update.isFinal ||
                  segments[index].timingIsConfirmed != update.timingIsConfirmed ||
                  segments[index].timestamp != update.timestamp else { return false }
            segments[index].text = text
            segments[index].timestamp = update.timestamp
            segments[index].isFinal = update.isFinal
            segments[index].timingIsConfirmed = update.timingIsConfirmed
            segments = TranscriptFormatting.ordered(segments)
            return true
        }

        guard containsSpeech else {
            if update.isFinal { retractedIDs.insert(update.segmentID) }
            return false
        }
        let segment = TranscriptSegment(
            id: update.segmentID,
            source: update.source,
            text: text,
            isFinal: update.isFinal,
            timestamp: update.timestamp,
            timingIsConfirmed: update.timingIsConfirmed
        )
        // An unconfirmed live phrase belongs at the tail even when the native
        // analyzer reports an old analysis-range boundary as its guessed time.
        segments.append(segment)
        segments = TranscriptFormatting.ordered(segments)
        return true
    }

    mutating func finalize() {
        for index in segments.indices {
            segments[index].isFinal = true
        }
        segments = TranscriptFormatting.ordered(segments)
    }

    var text: String { TranscriptFormatting.text(segments) }
    var isEmpty: Bool { segments.isEmpty }
}

struct TranscriptSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    let startedAt: Date
    var endedAt: Date?
    var segments: [TranscriptSegment]
    var sources: Set<TranscriptSource>
    var languageID: String
    /// Accumulated capture time. Missing metadata retains older documents' date-based duration.
    var recordedDuration: TimeInterval?

    private enum CodingKeys: String, CodingKey {
        case id, title, startedAt, endedAt, segments, sources, languageID, recordedDuration
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        segments: [TranscriptSegment] = [],
        sources: Set<TranscriptSource> = Set(TranscriptSource.allCases),
        languageID: String = TranscriptLanguage.defaultID,
        recordedDuration: TimeInterval? = nil
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.segments = segments
        self.sources = sources
        self.languageID = TranscriptLanguage.canonicalID(languageID)
        self.recordedDuration = recordedDuration
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        segments = try values.decode([TranscriptSegment].self, forKey: .segments)
        // Legacy files without metadata use an English fallback independent of
        // the current preference for new conversations.
        languageID = values.contains(.languageID)
            ? TranscriptLanguage.canonicalID(try values.decode(String.self, forKey: .languageID))
            : TranscriptLanguage.defaultID
        guard TranscriptLanguage.isValid(languageID) else {
            throw DecodingError.dataCorruptedError(forKey: .languageID, in: values,
                debugDescription: "The transcript language identifier is invalid.")
        }
        recordedDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .recordedDuration)
        if let recordedDuration, !recordedDuration.isFinite || recordedDuration < 0 {
            throw DecodingError.dataCorruptedError(forKey: .recordedDuration, in: values,
                debugDescription: "Recorded duration must be finite and nonnegative.")
        }
        // Older version-one files did not record enabled sources. A source may
        // have been enabled but silent, so preserve the former both-source default.
        sources = values.contains(.sources)
            ? try values.decode(Set<TranscriptSource>.self, forKey: .sources)
            : Set(TranscriptSource.allCases)
        guard !sources.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .sources, in: values,
                debugDescription: "A transcript must enable at least one audio source.")
        }
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? startedAt.formatted(date: .abbreviated, time: .shortened)
            : trimmed
    }

    var duration: TimeInterval {
        recordedDuration ?? max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    /// Plain text keeps source and time information without any markup. This is
    /// also the full transcript copied by the session's Copy action.
    var plainText: String { TranscriptFormatting.text(segments) }

    var markdown: String {
        let safeTitle = displayTitle.replacingOccurrences(of: "\n", with: " ")
        var lines = ["# \(safeTitle)", "", "\(startedAt.formatted(date: .long, time: .shortened))", ""]
        for segment in TranscriptFormatting.ordered(segments) {
            lines.append("**\(segment.metadataLabel)**")
            lines.append("")
            lines.append(segment.text)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    func exportFilename(extension fileExtension: String = "txt") -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>\u{0000}").union(.controlCharacters)
        let cleaned = displayTitle.components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))
        let name = String((cleaned.isEmpty ? "Relay Transcript" : cleaned).prefix(100))
        let safeExtension = fileExtension.lowercased().filter { $0.isASCII && $0.isLetter }
        return name + "." + (safeExtension.isEmpty ? "txt" : safeExtension)
    }
}

enum TranscriptFormatting {
    /// Only confirmed final clocks determine chronology. All other phrases
    /// retain arrival order at the tail, including interrupted untimed finals.
    static func ordered(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.sorted {
            let leftConfirmed = $0.isFinal && $0.timingIsConfirmed
            let rightConfirmed = $1.isFinal && $1.timingIsConfirmed
            if leftConfirmed != rightConfirmed { return leftConfirmed }
            return leftConfirmed && $0.timestamp < $1.timestamp
        }
    }

    static func timeLabel(_ timestamp: TimeInterval) -> String {
        guard timestamp.isFinite else { return "00:00" }
        let bounded = min(max(0, timestamp.rounded(.down)), Double(Int.max / 2))
        let seconds = Int(bounded)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    static func text(_ segments: [TranscriptSegment]) -> String {
        ordered(segments)
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "\($0.metadataLabel)\n\($0.text)" }
            .joined(separator: "\n\n")
    }
}
