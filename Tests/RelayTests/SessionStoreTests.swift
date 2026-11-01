import Foundation
import Testing
@testable import Relay

@Suite("Local transcript persistence")
struct SessionStoreTests {
    @Test("First launch has an empty library without creating files")
    func initiallyEmpty() throws {
        let store = makeStore()
        #expect(try store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path))
    }

    @Test("Session data round-trips and newest sessions appear first")
    func storesAndLoadsSessions() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let earlier = session(start: 1_790_000_000)
        let later = session(start: 1_790_003_600)
        try store.save(earlier)
        try store.save(later)
        let items = try store.load()
        #expect(items == [later, earlier])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL(for: later.id).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("Saving a revision replaces its session without duplicating history")
    func replacesOnlySavedSession() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var first = session()
        let second = session(start: 1_790_003_600)
        try store.save(first)
        try store.save(second)
        first.title = "Renamed transcript"
        first.segments[0].text = "Revised fictional text."
        let renamedURL = try store.rename(at: store.fileURL(for: first.id), to: first.title)
        try store.save(first, at: renamedURL)
        let loaded = try store.load()
        #expect(loaded.count == 2)
        #expect(loaded.first(where: { $0.id == first.id }) == first)
        #expect(loaded.first(where: { $0.id == second.id }) == second)
    }

    @Test("Deleting a session keeps other sessions and is safe to repeat")
    func deletesOneSession() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let first = session()
        let second = session(start: 1_790_003_600)
        try store.save(first)
        try store.save(second)
        try store.delete(id: first.id)
        try store.delete(id: first.id)
        #expect(try store.load() == [second])
    }

    @Test("Malformed session files are reported and remain unchanged")
    func preservesMalformedData() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let valid = session()
        try store.save(valid)
        let broken = store.fileURL(for: UUID())
        let original = Data("not a valid session".utf8)
        try original.write(to: broken)
        let result = try store.loadRecovering()
        #expect(result.sessions == [valid])
        #expect(result.issues.count == 1)
        #expect(result.issues[0].fileURL.resolvingSymlinksInPath() == broken.resolvingSymlinksInPath())
        #expect(try Data(contentsOf: broken) == original)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: broken) == original)
    }

    @Test("Saving cannot replace an unreadable file with the same identifier")
    func doesNotOverwriteUnreadableData() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = session()
        try store.save(item)
        let file = store.fileURL(for: item.id)
        let original = Data("existing unreadable work".utf8)
        try original.write(to: file)
        #expect(throws: (any Error).self) { try store.save(item, at: file) }
        #expect(try Data(contentsOf: file) == original)
    }

    @Test("Newer file formats remain intact during load and save")
    func preservesNewerFormats() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = session()
        try store.save(item)
        let file = store.fileURL(for: item.id)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["version"] = 900
        let newerData = try JSONSerialization.data(withJSONObject: object)
        try newerData.write(to: file)
        let result = try store.loadRecovering()
        #expect(result.sessions.isEmpty)
        #expect(result.issues.count == 1)
        #expect(throws: (any Error).self) { try store.save(item, at: file) }
        #expect(try Data(contentsOf: file) == newerData)
    }

    @Test("Duplicate or invalid phrase data is rejected before creating a file")
    func validatesBeforeSaving() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        item.segments.append(item.segments[0])
        #expect(throws: (any Error).self) { try store.save(item) }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: item.id).path))
        item.segments = [TranscriptSegment(source: .microphone, text: "Invalid time", timestamp: -.infinity)]
        #expect(throws: (any Error).self) { try store.save(item) }
    }

    @Test("A session identifier mismatch cannot be overwritten by a new save")
    func preservesMismatchedIdentifier() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = session()
        try store.save(item)
        let file = store.fileURL(for: item.id)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var data = try #require(object["session"] as? [String: Any])
        data["id"] = UUID().uuidString
        object["session"] = data
        let mismatched = try JSONSerialization.data(withJSONObject: object)
        try mismatched.write(to: file)
        let result = try store.loadRecovering()
        #expect(result.sessions.first?.id != item.id)
        #expect(throws: (any Error).self) { try store.save(item, at: file) }
        #expect(try Data(contentsOf: file) == mismatched)
    }

    @Test("A retracted partial is removed from disk while independent finalized text survives")
    func persistsPartialRetraction() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        let finalized = item.segments[0]
        let provisional = TranscriptSegment(source: .microphone, text: "A withdrawn hypothesis", isFinal: false, timestamp: 3)
        item.segments.append(provisional)
        let url = try store.save(item)
        // The incoming state omits both phrases. Only independently finalized
        // work is preserved by the merge; a missing partial stays retracted.
        item.segments = []
        try store.save(item, at: url)
        let restored = try store.read(at: url)
        #expect(restored.segments == [finalized])
        #expect(!restored.plainText.contains("withdrawn"))
    }

    @Test("Autosave merges preserve timing certainty and keep pending old clocks at the tail")
    func persistsTimingCertaintyThroughMergeAndFinalization() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        let confirmed = TranscriptSegment(source: .systemAudio, text: "Confirmed remote words.", timestamp: 120)
        let later = TranscriptSegment(source: .systemAudio, text: "Later confirmed remote words.", timestamp: 180)
        let pending = TranscriptSegment(source: .microphone, text: "Words without a confirmed clock.",
                                        isFinal: false, timestamp: 0, timingIsConfirmed: false)
        item.segments = [confirmed, later, pending]
        let url = try store.save(item)
        try store.save(item, at: url)
        let live = try store.read(at: url)
        #expect(live.segments.map(\.id) == [confirmed.id, later.id, pending.id])
        #expect(live.segments.map(\.timingIsConfirmed) == [true, true, false])
        #expect(live.segments.last?.timeLabel == "Live")
        var finished = SessionTranscript(segments: live.segments)
        finished.finalize()
        item.segments = finished.segments
        try store.save(item, at: url)
        let saved = try store.read(at: url)
        #expect(saved.segments.map(\.id) == [confirmed.id, later.id, pending.id],
                "Pause, autosave and reload must not insert an unknown zero clock before confirmed words.")
        let untimed = try #require(saved.segments.first { $0.id == pending.id })
        #expect(untimed.isFinal && !untimed.timingIsConfirmed)
        #expect(untimed.metadataLabel == "Microphone")
        #expect(saved.plainText.contains("Microphone\nWords without a confirmed clock."))
        #expect(!saved.plainText.contains("Microphone · 00:00"))
        #expect(saved.segments.first { $0.id == confirmed.id }?.timingIsConfirmed == true)
        var resumed = SessionTranscript(segments: saved.segments)
        let upgraded = resumed.apply(TranscriptUpdate(segmentID: pending.id, source: pending.source,
            text: pending.text, isFinal: true, timestamp: 165, timingIsConfirmed: true))
        #expect(upgraded)
        item.segments = resumed.segments
        try store.save(item, at: url)
        let positioned = try store.read(at: url)
        #expect(positioned.segments.map(\.id) == [confirmed.id, pending.id, later.id])
        #expect(positioned.segments[1].metadataLabel == "Microphone · 02:45")
    }

    @Test("Version-one files missing segment timing certainty decode without changing their words")
    func loadsLegacySegmentTimingCertainty() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        item.segments.append(TranscriptSegment(source: .systemAudio, text: "Legacy pending words.", isFinal: false, timestamp: 0))
        let url = try store.save(item)
        var envelope = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var contents = try #require(envelope["session"] as? [String: Any])
        var segments = try #require(contents["segments"] as? [[String: Any]])
        for index in segments.indices { segments[index].removeValue(forKey: "timingIsConfirmed") }
        contents["segments"] = segments
        envelope["session"] = contents
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let recovered = try store.read(at: url)
        #expect(recovered.segments == item.segments)
        #expect(recovered.segments.map(\.timingIsConfirmed) == [true, false])
        try store.save(recovered, at: url)
        #expect(try store.read(at: url).segments.map(\.timingIsConfirmed) == [true, false])
    }

    @Test("An identical untimed final cannot overwrite an externally confirmed clock")
    func preservesExternalConfirmedTimeWithoutBlockingIntentionalWordEdits() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        item.segments[0].timestamp = 7
        let url = try store.save(item)
        var stale = item
        stale.segments[0].timestamp = 0
        stale.segments[0].timingIsConfirmed = false
        var external = item
        external.segments[0].timestamp = 9
        try store.save(external, at: url)
        try store.save(stale, at: url)
        let preserved = try store.read(at: url)
        #expect(preserved.segments[0].timingIsConfirmed)
        #expect(preserved.segments[0].timestamp == 9)
        #expect(preserved.segments[0].text == item.segments[0].text)
        stale.segments[0].text = "An intentional edit has different words."
        try store.save(stale, at: url)
        let edited = try store.read(at: url)
        #expect(edited.segments[0].text == stale.segments[0].text)
        #expect(!edited.segments[0].timingIsConfirmed)
        #expect(edited.segments[0].metadataLabel == "Microphone")
    }

    @Test("Audio source choices persist per file without removing older source-labelled phrases")
    func persistsSourcesIndependentlyOfHistory() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        item.sources = [.systemAudio]
        let url = try store.save(item)
        let first = try store.read(at: url)
        #expect(first.sources == [.systemAudio])
        #expect(first.segments == item.segments)
        item.sources = [.microphone]
        try store.save(item, at: url)
        #expect(try store.read(at: url).sources == [.microphone])
        #expect(try store.read(at: url).segments == item.segments)
    }

    @Test("Conversation languages round-trip independently of their source choices and transcript")
    func persistsConversationLanguages() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var first = session()
        first.languageID = "fr-FR"
        first.sources = [.microphone]
        var second = session(start: 1_790_003_600)
        second.languageID = "auto"
        let firstURL = try store.save(first)
        let secondURL = try store.save(second)
        #expect(try store.read(at: firstURL).languageID == "fr-FR")
        #expect(try store.read(at: secondURL).languageID == "auto")
        first.languageID = "es-MX"
        try store.save(first, at: firstURL)
        let saved = try store.read(at: firstURL)
        #expect(saved.languageID == "es-MX" && saved.sources == [.microphone])
        #expect(saved.segments == first.segments && saved.startedAt == first.startedAt)
        #expect(try store.read(at: secondURL).languageID == "auto")
    }

    @Test("Legacy files receive English and normalize explicit locale separators on decode")
    func migratesLegacyConversationLanguage() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = session()
        let url = try store.save(item)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var document = try #require(object["session"] as? [String: Any])
        document.removeValue(forKey: "languageID")
        object["session"] = document
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let legacy = try store.read(at: url)
        #expect(legacy.languageID == "en-US" && legacy.segments == item.segments)
        document["languageID"] = "fr_FR"
        object["session"] = document
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let normalized = try store.read(at: url)
        #expect(normalized.languageID == "fr-FR")
        try store.save(normalized, at: url)
        #expect(try store.read(at: url).languageID == "fr-FR")
    }

    @Test("Invalid language metadata is rejected without overwriting a saved conversation")
    func rejectsInvalidConversationLanguage() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        let url = try store.save(item)
        let original = try Data(contentsOf: url)
        for identifier in ["", "en US", "en/US", "\n"] {
            item.languageID = identifier
            #expect(throws: (any Error).self) { try store.save(item, at: url) }
            #expect(try Data(contentsOf: url) == original)
        }
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var document = try #require(object["session"] as? [String: Any])
        document["languageID"] = ""
        object["session"] = document
        let invalid = try JSONSerialization.data(withJSONObject: object)
        try invalid.write(to: url)
        #expect(throws: (any Error).self) { try store.read(at: url) }
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test("Legacy files without source metadata retain both enabled sources even if only one spoke")
    func legacySourcesDefaultToBoth() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = session()
        let url = try store.save(item)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var data = try #require(object["session"] as? [String: Any])
        data.removeValue(forKey: "sources")
        object["session"] = data
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let recovered = try store.read(at: url)
        #expect(recovered.sources == Set(TranscriptSource.allCases))
        #expect(recovered.segments == item.segments)
        try store.save(recovered, at: url)
        #expect(try store.read(at: url).sources == Set(TranscriptSource.allCases))
    }

    @Test("An explicitly empty source set is rejected on save and decode without replacing the file")
    func rejectsExplicitlyEmptySources() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        let url = try store.save(item)
        let original = try Data(contentsOf: url)
        item.sources = []
        #expect(throws: (any Error).self) { try store.save(item, at: url) }
        #expect(try Data(contentsOf: url) == original)
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var data = try #require(object["session"] as? [String: Any])
        data["sources"] = [String]()
        object["session"] = data
        let invalid = try JSONSerialization.data(withJSONObject: object)
        try invalid.write(to: url)
        #expect(throws: (any Error).self) { try store.read(at: url) }
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test("Recorded duration survives saves independently of dates, source choices, and old metadata")
    func persistsRecordedDurationWithLegacyFallback() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        item.recordedDuration = 12.375
        let url = try store.save(item)
        #expect(try store.read(at: url).duration == 12.375)
        item.recordedDuration = 23.625
        item.sources = [.microphone]
        try store.save(item, at: url)
        let saved = try store.read(at: url)
        #expect(saved.recordedDuration == 23.625 && saved.duration == 23.625)
        #expect(saved.startedAt == item.startedAt && saved.endedAt == item.endedAt)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var legacy = try #require(object["session"] as? [String: Any])
        legacy.removeValue(forKey: "recordedDuration")
        object["session"] = legacy
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let restored = try store.read(at: url)
        #expect(restored.recordedDuration == nil)
        #expect(restored.duration == 60)
        #expect(restored.segments == item.segments)
    }

    @Test("Invalid recorded durations are rejected without overwriting the existing transcript")
    func rejectsInvalidRecordedDuration() throws {
        let store = makeStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var item = session()
        item.recordedDuration = 5
        let url = try store.save(item)
        let original = try Data(contentsOf: url)
        for invalid in [-1, -.infinity, .infinity, .nan] as [TimeInterval] {
            item.recordedDuration = invalid
            #expect(throws: (any Error).self) { try store.save(item, at: url) }
            #expect(try Data(contentsOf: url) == original)
        }
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var data = try #require(object["session"] as? [String: Any])
        data["recordedDuration"] = -1
        object["session"] = data
        let invalidDocument = try JSONSerialization.data(withJSONObject: object)
        try invalidDocument.write(to: url)
        #expect(throws: (any Error).self) { try store.read(at: url) }
        #expect(try Data(contentsOf: url) == invalidDocument)
    }

    private func makeStore() -> SessionStore {
        SessionStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("Relay-UnitTests-" + UUID().uuidString, isDirectory: true))
    }

    private func session(start: TimeInterval = 1_790_000_000) -> TranscriptSession {
        TranscriptSession(
            title: "Fictional planning call \(Int(start))",
            startedAt: Date(timeIntervalSince1970: start),
            endedAt: Date(timeIntervalSince1970: start + 60),
            segments: [TranscriptSegment(source: .microphone, text: "Let's schedule the design review.", timestamp: 2)]
        )
    }
}
