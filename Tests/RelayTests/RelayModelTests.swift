import AppKit
import Foundation
import Testing
@testable import Relay

@Suite("Session library integration", .serialized)
@MainActor
struct RelayModelTests {
    @Test("New conversation defaults persist while copying and echo reduction stay enabled")
    func persistsPreferences() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "autoCopySelection")
        fixture.defaults.set(false, forKey: "reducesSpeakerEcho")
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        #expect(model.autoCopySelection && model.reducesSpeakerEcho)
        #expect(model.service.reducesSpeakerEcho)
        model.defaultLanguageID = "fr-FR"
        #expect(fixture.defaults.string(forKey: "transcriptionLanguage") == "fr-FR")
        let reopened = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        #expect(reopened.defaultLanguageID == "fr-FR")
        #expect(reopened.autoCopySelection && reopened.reducesSpeakerEcho)
    }

    @Test("Copy and export become available only for a completed nonempty transcript")
    func completedTranscriptAvailability() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        #expect(!model.canExport)
        var item = fixture.session()
        item.endedAt = nil
        model.sessions = [item]
        model.selectedID = item.id
        #expect(!model.canExport)
        item.endedAt = item.startedAt.addingTimeInterval(20)
        model.sessions = [item]
        #expect(model.canExport)
        item.segments = []
        model.sessions = [item]
        #expect(!model.canExport)
    }

    @Test("Search finds both session titles and recognized text")
    func searchesTitleAndTranscript() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        var first = fixture.session()
        first.title = "Design review"
        first.segments[0].text = "The prototype is ready for Thursday."
        var second = fixture.session()
        second.title = "Planning"
        second.segments[0].text = "Schedule the next workshop."
        model.sessions = [first, second]
        model.search = "REVIEW"
        #expect(model.filteredSessions.map(\.id) == [first.id])
        model.search = "Thursday"
        #expect(model.filteredSessions.map(\.id) == [first.id])
        model.search = "workshop"
        #expect(model.filteredSessions.map(\.id) == [second.id])
        model.search = ""
        #expect(model.filteredSessions.map(\.id) == [first.id, second.id])
    }

    @Test("A new transcription clears the selected history item")
    func preparesNewSession() throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        let item = fixture.session()
        model.sessions = [item]
        model.selectedID = item.id
        model.newSession()
        #expect(model.selectedID == nil)
        #expect(model.sessions == [item])
    }

    @Test("Interrupted sessions retain their last phrase and become exportable")
    func recoversInterruptedSession() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        var item = fixture.session()
        item.endedAt = nil
        item.segments[0].isFinal = false
        item.segments[0].text = "The last recognized words."
        try SessionStore(directory: fixture.directory).save(item)
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, permissions: .testing())
        try await waitUntil { model.isLoaded }
        let loaded = try #require(model.sessions.first)
        #expect(loaded.id == item.id)
        #expect(loaded.segments[0].text == "The last recognized words.")
        #expect(loaded.segments[0].isFinal)
        #expect(loaded.endedAt != nil)
        model.selectedID = loaded.id
        #expect(model.canExport)
    }

    @Test("Renaming a completed transcript updates the local file")
    func persistsRename() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let item = fixture.session()
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        model.sessions = [item]
        model.rename(item, to: "  Revised session name  ")
        try await waitUntil { (try? store.load().first?.title) == "Revised session name" }
        #expect(model.sessions.first?.title == "Revised session name")
        #expect(try store.load().first?.segments == item.segments)
    }

    @Test("Deleting one transcript removes its file and leaves other work intact")
    func deletesSelectedTranscript() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let first = fixture.session()
        let second = fixture.session()
        let store = SessionStore(directory: fixture.directory)
        try store.save(first)
        try store.save(second)
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        model.sessions = [first, second]
        model.selectedID = first.id
        model.delete(first)
        try await waitUntil { model.sessions.count == 1 }
        #expect(model.selectedID == nil)
        #expect(try store.load() == [second])
    }

    #if DEBUG
    @Test("The completed UI fixture can save source changes through the real document validator")
    func uiFixtureHasValidDatesForSourceEditing() async throws {
        let fixture = try ModelFixture()
        defer { fixture.cleanUp() }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let item = RelayModel.uiFixtureSession(at: now)
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        #expect(item.endedAt == now)
        #expect(item.startedAt < now)
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, automaticallyLoad: false, permissions: .testing())
        model.sessions = [item]
        model.selectedID = item.id
        #expect(await model.updateSelectedSources([.microphone]))
        #expect(model.notice == nil)
        let saved = try #require(store.load().first)
        #expect(saved.sources == [.microphone])
        #expect(saved.startedAt == item.startedAt && saved.endedAt == item.endedAt)
        #expect(saved.segments == item.segments)
    }
    #endif

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("The asynchronous library update did not complete.")
        throw ModelTestError.timedOut
    }
}

@MainActor
private struct ModelFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Relay-ModelTests-" + UUID().uuidString)
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "Relay-ModelTests-" + UUID().uuidString
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func session() -> TranscriptSession {
        let id = UUID()
        return TranscriptSession(id: id, title: "Fictional session \(id.uuidString.prefix(6))", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_790_000_020),
                          segments: [TranscriptSegment(source: .microphone, text: "Fictional spoken words.", timestamp: 2)])
    }
}

private enum ModelTestError: Error { case timedOut }
