import Foundation
import Testing
@testable import Relay

@Suite("Ordered library writes")
struct SessionLibraryTests {
    @Test("Older or duplicate revisions cannot downgrade an authoritative phrase clock")
    func staleSavesCannotDowngradeConfirmedTiming() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        var item = session()
        item.segments[0].timingIsConfirmed = false
        item.segments[0].timestamp = 0
        let original = item
        try await library.save(item, revision: 1)
        item.segments[0].timingIsConfirmed = true
        item.segments[0].timestamp = 7
        let confirmedSave = try await library.save(item, revision: 2)
        let staleSave = try await library.save(original, revision: 1)
        let duplicateSave = try await library.save(original, revision: 2)
        #expect(confirmedSave && !staleSave && !duplicateSave)
        let loaded = try await library.load()
        let reloaded = try #require(loaded.sessions.first)
        #expect(reloaded.segments[0].timingIsConfirmed)
        #expect(reloaded.segments[0].timestamp == 7)
        #expect(reloaded.segments[0].text == original.segments[0].text)
    }

    @Test("An older queued save cannot overwrite a newer snapshot")
    func rejectsOutOfOrderSaves() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        var item = session()
        let old = item
        item.title = "Latest title"
        let saved = try await library.save(item, revision: 2)
        let stale = try await library.save(old, revision: 1)
        let duplicate = try await library.save(old, revision: 2)
        #expect(saved)
        #expect(!stale)
        #expect(!duplicate)
        #expect(try await library.load().sessions == [item])
    }

    @Test("A deletion prevents queued saves from recreating its file")
    func preventsResurrection() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let item = session()
        try await library.save(item, revision: 1)
        try await library.delete(item.id, revision: 3)
        let older = try await library.save(item, revision: 2)
        let accidentalNewer = try await library.save(item, revision: 4)
        #expect(!older)
        #expect(!accidentalNewer)
        #expect(try await library.load().sessions.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: SessionStore(directory: directory).fileURL(for: item.id).path))
    }

    @Test("An old deletion cannot remove a newer saved session")
    func rejectsOutOfOrderDeletion() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let item = session()
        try await library.save(item, revision: 5)
        let stale = try await library.delete(item.id, revision: 4)
        #expect(!stale)
        #expect(try await library.load().sessions == [item])
    }

    @Test("Revisions are independent for different sessions")
    func separatesSessionRevisions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let first = session()
        let second = session()
        try await library.save(first, revision: 100)
        let saved = try await library.save(second, revision: 1)
        #expect(saved)
        #expect(try await library.load().sessions.count == 2)
    }

    @Test("Concurrent saves converge on the snapshot with the highest revision")
    func convergesConcurrentWrites() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let original = session()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in UInt64(1)...20 {
                var copy = original
                copy.segments[0].text = "Revision \(revision)"
                let snapshot = copy
                group.addTask {
                    try await library.save(snapshot, revision: revision)
                }
            }
            try await group.waitForAll()
        }
        #expect(try await library.load().sessions.first?.segments.first?.text == "Revision 20")
    }

    @Test("A failed newer write still invalidates older queued snapshots")
    func failedWriteBlocksStaleWrite() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let item = session()
        try await library.save(item, revision: 1)
        let file = SessionStore(directory: directory).fileURL(for: item.id)
        let validData = try Data(contentsOf: file)
        try Data("unreadable fictional fixture".utf8).write(to: file)
        await #expect(throws: (any Error).self) { try await library.save(item, revision: 5) }
        // Repair the fixture in place. A stale write must be rejected by its
        // revision guard, rather than because the file cannot be decoded.
        try validData.write(to: file, options: .atomic)
        let stale = try await library.save(item, revision: 4)
        #expect(!stale)
        #expect(try Data(contentsOf: file) == validData)
        let retry = try await library.save(item, revision: 6)
        #expect(retry)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Relay-LibraryTests-" + UUID().uuidString)
    }

    private func session() -> TranscriptSession {
        TranscriptSession(title: "Fictional session", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_790_000_010),
                          segments: [TranscriptSegment(source: .microphone, text: "Fictional transcript.", timestamp: 1)])
    }
}
