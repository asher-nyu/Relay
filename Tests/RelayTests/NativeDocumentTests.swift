import Foundation
import Testing
@testable import Relay

@Suite("Native Relay documents", .serialized)
@MainActor
struct NativeDocumentTests {
    @Test("Default local fallback is a Relay folder in Documents")
    func usesPersistentDefaultFolder() {
        let expected = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relay", isDirectory: true)
        #expect(SessionStore().directory == expected)
        #expect(SessionStore().directory.path != FileManager.default.temporaryDirectory.path)
    }

    @Test("Readable .relay filenames reserve collisions without replacing another document")
    func reservesHumanFilenames() throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionStore(directory: directory)
        let first = session(title: "Planning notes")
        let second = session(title: "Planning notes")
        let firstURL = try store.save(first)
        let originalData = try Data(contentsOf: firstURL)
        let secondURL = try store.save(second)
        #expect(firstURL.lastPathComponent == "Planning notes.relay")
        #expect(secondURL.lastPathComponent == "Planning notes 2.relay")
        #expect(try Data(contentsOf: firstURL) == originalData)
        #expect(try store.read(at: firstURL).id == first.id)
        #expect(try store.read(at: secondURL).id == second.id)
        #expect(try store.load().count == 2)
    }

    @Test("Explicit rename moves the file and keeps its identifier and transcript")
    func renamesNativeDocument() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let item = session(title: "Original notes")
        try await library.save(item, revision: 1)
        let original = try #require(await library.documentURL(for: item.id))
        try await library.rename(item, to: "Research call", revision: 2)
        let renamed = try #require(await library.documentURL(for: item.id))
        #expect(renamed.lastPathComponent == "Research call.relay")
        #expect(!FileManager.default.fileExists(atPath: original.path))
        let loaded = try SessionStore(directory: directory).read(at: renamed)
        #expect(loaded.id == item.id)
        #expect(loaded.segments == item.segments)
    }

    @Test("Repeated atomic autosaves never announce deletion or lose the open transcript")
    func atomicReplacementIsNotDeletion() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        let probe = DocumentEventProbe()
        await library.setChangeHandler { probe.record($0) }
        var item = session(title: "Atomic save regression")
        try await library.save(item, revision: 1)
        let url = try #require(await library.documentURL(for: item.id))
        for revision in UInt64(2)...12 {
            item.segments[0].text = "Fictional revision \(revision)."
            let saved = try await library.save(item, revision: revision)
            #expect(saved)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // This independent writer does not exclude the registered presenter.
        // Its atomic replacement must also be read as a change, not deletion.
        item.segments[0].text = "An external atomic replacement."
        try SessionStore(directory: directory).save(item, at: url)
        try await waitUntil { probe.updates > 0 }
        #expect(probe.removed.isEmpty)
        item.segments[0].text = "Still available after replacement."
        #expect(try await library.save(item, revision: 13))
        #expect(try SessionStore(directory: directory).read(at: url).segments[0].text == "Still available after replacement.")
        #expect(probe.removed.isEmpty)
    }

    @Test("A Finder-style coordinated rename remains authoritative for the next autosave")
    func followsExternalRename() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SessionLibrary(directory: directory)
        var item = session(title: "Original filename")
        try await library.save(item, revision: 1)
        let old = try #require(await library.documentURL(for: item.id))
        let target = directory.appendingPathComponent("Renamed in Finder.relay")
        try coordinatedMove(from: old, to: target)
        try await waitUntil {
            let actual = await library.documentURL(for: item.id)
            return actual?.lastPathComponent == "Renamed in Finder.relay"
        }
        item.segments[0].text = "A later live phrase."
        #expect(try await library.save(item, revision: 2))
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try SessionStore(directory: directory).read(at: target).title == "Renamed in Finder")
        #expect(try SessionStore(directory: directory).read(at: target).segments[0].text == "A later live phrase.")
    }

    @Test("Opening an external Relay document edits that file and restores its bookmark")
    func keepsExternalFileAtChosenLocation() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaultFolder = directory.appendingPathComponent("Default")
        let chosenFolder = directory.appendingPathComponent("Chosen")
        let externalStore = SessionStore(directory: chosenFolder)
        let original = session(title: "Workshop notes")
        let url = try externalStore.save(original)
        do {
            let library = SessionLibrary(directory: defaultFolder)
            var opened = try await library.open(at: url)
            opened.segments[0].text = "Updated in its chosen folder."
            #expect(try await library.save(opened, revision: 1))
            #expect(try SessionStore(directory: defaultFolder).documentURLs().isEmpty)
            #expect(try externalStore.read(at: url).segments[0].text == "Updated in its chosen folder.")
        }
        let reopenedLibrary = SessionLibrary(directory: defaultFolder)
        let restored = try await reopenedLibrary.load()
        #expect(restored.sessions.first?.id == original.id)
        #expect(restored.sessions.first?.segments[0].text == "Updated in its chosen folder.")
    }

    @Test("A file arriving in the default folder is discovered without reopening the library")
    func discoversArrivingFile() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = SessionLibrary(directory: directory)
        let probe = DocumentEventProbe()
        await library.setChangeHandler { probe.record($0) }
        #expect(try await library.load().sessions.isEmpty)
        let incoming = session(title: "Arriving from another Mac")
        let writer = SessionStore(directory: directory)
        let url = try writer.save(incoming)
        try await waitUntil { probe.discoveries.count == 1 }
        #expect(probe.discoveries[0].id == incoming.id)
        #expect(probe.discoveries[0].segments == incoming.segments)
        #expect(await library.documentURL(for: incoming.id)?.lastPathComponent == url.lastPathComponent)
        // A subsequent coordinated change goes to the individual file presenter
        // and must not create a second discovery of the same transcript.
        var revised = incoming
        revised.segments[0].text = "Updated remotely."
        try writer.save(revised, at: url)
        try await waitUntil { probe.updates > 0 }
        #expect(probe.discoveries.count == 1)
    }

    @Test("The folder observer ignores Relay's own new files and repeated autosaves")
    func discoveryIgnoresOwnWrites() async throws {
        let directory = fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = SessionLibrary(directory: directory)
        let probe = DocumentEventProbe()
        await library.setChangeHandler { probe.record($0) }
        var item = session(title: "Own recording")
        try await library.save(item, revision: 1)
        for revision in UInt64(2)...5 {
            item.segments[0].text = "Own revision \(revision)."
            try await library.save(item, revision: revision)
        }
        // Allow the folder-presenter operation queue to deliver its asynchronous
        // callbacks before asserting that no duplicate insertion was emitted.
        try await Task.sleep(for: .milliseconds(100))
        #expect(probe.discoveries.isEmpty)
        #expect(probe.removed.isEmpty)
        #expect(try await library.load().sessions.count == 1)
    }

    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The file presenter did not report the coordinated operation.")
        throw NativeDocumentTestError.timedOut
    }

    private func coordinatedMove(from source: URL, to destination: URL) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var error: NSError?
        var result: Result<Void, any Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving,
                               writingItemAt: destination, options: [], error: &error) { from, to in
            result = Result {
                try FileManager.default.moveItem(at: from, to: to)
                coordinator.item(at: from, didMoveTo: to)
            }
        }
        if let error { throw error }
        try result?.get()
    }

    private func fixtureDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Relay-NativeDocumentTests-" + UUID().uuidString)
    }

    private func session(title: String) -> TranscriptSession {
        TranscriptSession(title: title, startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_790_000_020),
                          segments: [TranscriptSegment(source: .microphone, text: "Fictional transcript.", timestamp: 1)])
    }
}

@MainActor
private final class DocumentEventProbe {
    var updates = 0
    var discoveries: [TranscriptSession] = []
    var removed: [UUID] = []
    func record(_ event: RelayLibraryEvent) {
        switch event {
        case .discovered(let item, _): discoveries.append(item)
        case .updated: updates += 1
        case .removed(let id): removed.append(id)
        case .issue: break
        }
    }
}

private enum NativeDocumentTestError: Error { case timedOut }
