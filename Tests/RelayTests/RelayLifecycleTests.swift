import Foundation
import Testing
@testable import Relay

@Suite("Transcription lifecycle and save protection", .serialized)
@MainActor
struct RelayLifecycleTests {
    @Test("The remembered language affects new files while Resume uses each file's saved language")
    func newLanguageDefaultDoesNotOverrideSavedConversation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.defaultLanguageID = "fr_FR"
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let frenchID = try #require(model.activeID)
        #expect(model.selectedLanguageID == "fr-FR" && audio.requestedLocale == "fr-FR")
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "A fictional first conversation.", isFinal: true, timestamp: 0))
        model.defaultLanguageID = "es-MX"
        #expect(audio.startCount == 1 && model.selectedLanguageID == "fr-FR")
        #expect(await model.pauseSession())
        model.resumeSelectedSession()
        try await waitUntil { model.isSelectedRecording }
        #expect(model.activeID == frenchID && audio.requestedLocale == "fr-FR")
        #expect(await model.endSession())
        model.newSession()
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let spanishID = try #require(model.activeID)
        #expect(spanishID != frenchID && audio.requestedLocale == "es-MX")
        #expect(model.selectedLanguageID == "es-MX")
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "A separate fictional conversation.", isFinal: true, timestamp: 0))
        #expect(await model.endSession())
        let stored = try SessionStore(directory: fixture.directory).load()
        #expect(stored.first { $0.id == frenchID }?.languageID == "fr-FR")
        #expect(stored.first { $0.id == spanishID }?.languageID == "es-MX")
        #expect(fixture.defaults.string(forKey: "transcriptionLanguage") == "es-MX")
    }

    @Test("A live language change drains and restarts its captured file without changing the new-file default")
    func switchesLiveLanguageWithoutRedirectingSelection() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        var history = fixture.session()
        history.languageID = "de-DE"
        try SessionStore(directory: fixture.directory).save(history)
        model.sessions = [history]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let active = try #require(model.activeID)
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "The last words", isFinal: false, timestamp: 0))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "The last words before changing language.", isFinal: true, timestamp: 0)
        let change = Task { await model.updateSelectedLanguage("fr_FR") }
        try await waitUntil { model.isChangingSources }
        #expect(!model.canEditSelectedLanguage && !model.canEditSelectedSources && !model.canRequestNewSession)
        #expect(!(await model.updateSelectedSources([.microphone])))
        model.selectedID = history.id
        #expect(await change.value)
        try await waitUntil { audio.isRunning }
        #expect(model.activeID == active && model.selectedID == history.id)
        #expect(audio.requestedLocale == "fr-FR" && audio.stopCount == 1 && audio.startCount == 2)
        #expect(model.defaultLanguageID == "en-US" && model.selectedLanguageID == "de-DE")
        let saved = try #require(SessionStore(directory: fixture.directory).load().first { $0.id == active })
        #expect(saved.languageID == "fr-FR" && saved.sources == Set(TranscriptSource.allCases))
        #expect(saved.segments.first?.text == "The last words before changing language.")
        #expect(model.sessions.first { $0.id == history.id } == history)
        audio.finalUpdateOnStop = nil
        #expect(await model.endSession())
    }

    @Test("Language edits persist in paused and saved files without starting audio, including Auto Detect")
    func editsPausedAndSavedLanguagesWithoutStartingCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep this fictional transcript.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        #expect(await model.updateSelectedLanguage("es_MX"))
        #expect(model.isSelectedPaused && !audio.isRunning && audio.startCount == 1)
        #expect(model.selectedLanguageID == "es-MX" && model.defaultLanguageID == "en-US")
        #expect(await model.endSession())
        #expect(await model.updateSelectedLanguage("AUTO"))
        #expect(model.activeID == nil && !audio.isRunning && audio.startCount == 1)
        #expect(try SessionStore(directory: fixture.directory).load().first?.languageID == "auto")
        model.defaultLanguageID = "fr-FR"
        model.resumeSelectedSession()
        try await waitUntil { model.isSelectedRecording }
        #expect(audio.autoStartCount == 1 && model.activeID == id)
        #expect(model.selectedLanguageID == "auto" && model.defaultLanguageID == "fr-FR")
        #expect(await model.endSession())
    }

    @Test("A failed language-change save keeps the existing words safely paused without a restart")
    func failedLanguageSaveDoesNotRestart() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Save these words before restarting.", isFinal: true, timestamp: 0))
        #expect(!(await model.updateSelectedLanguage("fr-FR")))
        #expect(model.activeID == id && model.isSelectedPaused && !audio.isRunning)
        #expect(audio.startCount == 1 && model.requiresTerminationWork)
        #expect(model.selectedSession?.segments.first?.text == "Save these words before restarting.")
        #expect(model.defaultLanguageID == "en-US")
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.first?.text == "Save these words before restarting.")
    }

    @Test("Editing a history file's language leaves a different live conversation and its audio untouched")
    func historyLanguageChangeDoesNotAffectLiveCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let history = fixture.session()
        try SessionStore(directory: fixture.directory).save(history)
        model.sessions = [history]
        model.defaultLanguageID = "fr-FR"
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let active = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "The live conversation continues.", isFinal: false, timestamp: 0))
        model.selectedID = history.id
        #expect(await model.updateSelectedLanguage("es-MX"))
        #expect(model.activeID == active && audio.isRunning && audio.startCount == 1 && audio.stopCount == 0)
        #expect(audio.requestedLocale == "fr-FR" && model.defaultLanguageID == "fr-FR")
        #expect(model.selectedLanguageID == "es-MX")
        #expect(model.sessions.first { $0.id == active }?.languageID == "fr-FR")
        #expect(try SessionStore(directory: fixture.directory).load().first { $0.id == history.id }?.languageID == "es-MX")
        #expect(await model.endSession())
    }

    @Test("Missing permissions block New, creation, and Resume without replacing an existing file")
    func permissionGatePreservesExistingConversation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let permissions = RelayPermissions.testing(microphone: .denied, systemAudio: false)
        let model = fixture.model(service: audio, permissions: permissions)
        model.defaultLanguageID = "de-DE"
        var history = fixture.session()
        history.languageID = "fr-FR"
        let store = SessionStore(directory: fixture.directory)
        try store.save(history)
        model.sessions = [history]
        model.selectedID = history.id
        #expect(model.permissions === permissions)
        #expect(!model.canRequestNewSession && !model.canStartNewSession && !model.canResumeSelectedSession)
        model.newSession()
        model.toggleRecording()
        model.resumeSelectedSession()
        #expect(model.selectedID == history.id && model.sessions == [history])
        #expect(model.activeID == nil && audio.startCount == 0 && !model.isBusy)
        permissions.setTestingAccess(microphone: .authorized, systemAudio: false)
        model.resumeSelectedSession()
        #expect(audio.startCount == 0 && model.activeID == nil)
        model.selectedID = nil
        model.toggleRecording()
        #expect(model.sessions == [history] && model.activeID == nil)
        #expect(try store.load() == [history])
        permissions.setTestingAccess(microphone: .authorized, systemAudio: true)
        model.selectedID = history.id
        model.resumeSelectedSession()
        try await waitUntil { model.isSelectedRecording }
        #expect(audio.startCount == 1 && model.activeID == history.id)
        #expect(audio.requestedLocale == "fr-FR" && model.selectedLanguageID == "fr-FR")
        #expect(model.defaultLanguageID == "de-DE")
        #expect(await model.endSession())
    }

    @Test("Revocation before the queued startup prevents audio and removes only the unused new attempt")
    func permissionRevocationBeforeQueuedStartupDoesNotCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let permissions = RelayPermissions.testing()
        let model = fixture.model(service: audio, permissions: permissions)
        model.toggleRecording()
        #expect(model.isPreparing && audio.startCount == 0)
        permissions.setTestingAccess(microphone: .denied, systemAudio: true)
        try await waitUntil { !model.isBusy && model.activeID == nil }
        #expect(audio.startCount == 0 && model.sessions.isEmpty && model.selectedID == nil)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("Permission revocation during a language change leaves the saved file paused")
    func revokedPermissionDoesNotRestartChangedConversation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let permissions = RelayPermissions.testing()
        let model = fixture.model(service: audio, permissions: permissions)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep the saved words.", isFinal: true, timestamp: 0))
        let change = Task { await model.updateSelectedLanguage("fr-FR") }
        try await waitUntil { model.isChangingSources }
        permissions.setTestingAccess(microphone: .authorized, systemAudio: false)
        #expect(await change.value)
        #expect(model.activeID == id && model.isSelectedPaused && !audio.isRunning && audio.startCount == 1)
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.languageID == "fr-FR" && saved.segments.first?.text == "Keep the saved words.")
        #expect(!model.canResumeSelectedSession && !model.canRequestNewSession)
        #expect(await model.prepareToQuit())
    }

    @Test("Preparation and malformed language edits cannot interrupt or alter a conversation")
    func rejectsLanguageChangesDuringPreparationAndInvalidIdentifiers() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber(suspendStartup: true)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        #expect(!model.canEditSelectedLanguage)
        #expect(!(await model.updateSelectedLanguage("fr-FR")))
        audio.releaseFirstStart()
        try await waitUntil { model.isSelectedRecording }
        #expect(!(await model.updateSelectedLanguage("")))
        #expect(model.selectedLanguageID == "en-US" && audio.stopCount == 0 && audio.isRunning)
        #expect(await model.endSession())
    }

    @Test("Permission revocation pauses once after unrelated deletion and preserves final recognition")
    func permissionRevocationStopsCaptureBehindOnboarding() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let permissions = RelayPermissions.testing()
        let model = fixture.model(service: audio, permissions: permissions)
        let history = fixture.session()
        let store = SessionStore(directory: fixture.directory)
        try store.save(history)
        model.sessions = [history]
        model.defaultLanguageID = "fr-FR"
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Preserve these recognized words", isFinal: false, timestamp: 0))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Preserve these recognized words after access changes.", isFinal: true, timestamp: 0)
        model.delete(history)
        permissions.setTestingAccess(microphone: .denied, systemAudio: true)
        model.handlePermissionRevocation()
        model.handlePermissionRevocation()
        try await waitUntil { model.isSelectedPaused && !model.isDeletingTranscript }
        #expect(await model.flushPendingWrites())
        #expect(model.activeID == id && !audio.isRunning && audio.stopCount == 1)
        #expect(!model.canResumeSelectedSession && model.notice == nil)
        let saved = try store.load()
        #expect(saved.map(\.id) == [id])
        #expect(saved[0].languageID == "fr-FR")
        #expect(saved[0].segments.map(\.text) == ["Preserve these recognized words after access changes."])
        audio.finalUpdateOnStop = nil
        #expect(await model.prepareToQuit())
    }

    @Test("A stale revocation cannot pause a restored or successor capture")
    func restoredPermissionDoesNotApplyOldRevocationToSuccessor() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let permissions = RelayPermissions.testing()
        let model = fixture.model(service: audio, permissions: permissions)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let first = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The first saved conversation.", isFinal: true, timestamp: 0))
        permissions.setTestingAccess(microphone: .denied, systemAudio: true)
        model.handlePermissionRevocation()
        // Restore access before the queued handler runs, then explicitly finish
        // this file. Its old authorization event must not follow the next file.
        permissions.setTestingAccess(microphone: .authorized, systemAudio: true)
        #expect(await model.endSession())
        model.newSession()
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        for _ in 0..<5 { await Task.yield() }
        #expect(model.activeID != first && audio.isRunning && audio.stopCount == 1)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The successor stays active.", isFinal: true, timestamp: 0))
        #expect(await model.endSession())
    }

    @Test("An immediate Delete prevents the queued setup from entering the shared audio service")
    func immediateDeletionSkipsUnenteredStartup() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        let discarded = try #require(model.selectedSession)
        // No suspension occurs between creating the startup task and recording
        // the deletion intent. The older task must check ownership on entry.
        model.delete(discarded)
        #expect(audio.startCount == 0)
        #expect(await model.flushPendingWrites())
        #expect(audio.startCount == 0 && !audio.isRunning && model.activeID == nil)
        #expect(model.sessions.isEmpty)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        #expect(audio.startCount == 1 && model.activeID != discarded.id)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The successor owns the first real startup.", isFinal: true, timestamp: 0))
        #expect(await model.endSession())
        let saved = try SessionStore(directory: fixture.directory).load()
        #expect(saved.count == 1 && saved[0].id != discarded.id)
        #expect(saved[0].segments.map(\.text) == ["The successor owns the first real startup."])
    }

    @Test("A service failure deferred by unrelated history deletion still stops and preserves its active file")
    func unrelatedDeletionDoesNotSwallowServiceFailure() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let history = fixture.session()
        let store = SessionStore(directory: fixture.directory)
        try store.save(history)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.sessions = [history]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let active = try #require(model.activeID)
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Preserve these words", isFinal: false, timestamp: 0))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Preserve these words after the failure.", isFinal: true, timestamp: 0)
        model.delete(history)
        audio.state = .failed("Fictional capture failure during another file’s deletion")
        model.handleServiceFailure()
        let firstNotice = model.notice?.id
        model.handleServiceFailure()
        #expect(model.notice?.id == firstNotice, "One failed generation produces one notice and one deferred stop.")
        // This waits for the unrelated deletion. Its completion releases the
        // failure handler, whose final recognition may legitimately dirty the
        // active transcript while this first flush is still saving a snapshot.
        _ = await model.flushPendingWrites()
        try await waitUntil { model.activeID == nil && !model.isBusy && !model.isDeletingTranscript }
        #expect(await model.flushPendingWrites())
        #expect(audio.stopCount == 1 && !audio.isRunning)
        let saved = try store.load()
        #expect(saved.map(\.id) == [active])
        #expect(saved[0].segments.map(\.text) == ["Preserve these words after the failure."])
        #expect(!model.sessions.contains { $0.id == history.id })
    }

    @Test("A failed deleted generation cannot stop the successor after its transaction barrier clears")
    func deferredFailureCannotStopSuccessorAfterDeletion() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "This old file was explicitly deleted.", isFinal: true, timestamp: 0))
        let old = try #require(model.selectedSession)
        model.delete(old)
        audio.state = .failed("Fictional old-generation failure")
        model.handleServiceFailure()
        #expect(await model.flushPendingWrites())
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let successor = try #require(model.activeID)
        for _ in 0..<5 { await Task.yield() }
        #expect(successor != old.id && audio.isRunning && audio.stopCount == 1)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The new capture remains running.", isFinal: true, timestamp: 0))
        #expect(model.activeID == successor && model.isSelectedRecording)
        #expect(await model.endSession())
        #expect(try SessionStore(directory: fixture.directory).load().map(\.id) == [successor])
    }

    @Test("Deleting the live file drains once and late callbacks cannot recreate it or contaminate its successor")
    func deletesLiveFileAndRejectsLateRecognition() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let item = try #require(model.selectedSession)
        let oldCallback = audio.onUpdate
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Keep the final words", isFinal: false, timestamp: 1))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Keep the final words.", isFinal: true, timestamp: 1)
        model.delete(item)
        #expect(model.isDeletingTranscript && !model.canRequestNewSession && !model.canToggleRecording)
        #expect(await model.flushPendingWrites())
        #expect(model.sessions.isEmpty && model.selectedID == nil && model.activeID == nil)
        #expect(!model.isDeletingTranscript && !model.isBusy && !audio.isRunning)
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
        oldCallback?(TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Late deleted words.", isFinal: true, timestamp: 2))
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        #expect(model.activeID != item.id)
        oldCallback?(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "Another late deleted phrase.", isFinal: true, timestamp: 3))
        #expect(model.selectedSession?.segments.isEmpty == true)
        audio.finalUpdateOnStop = nil
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Only the successor words.", isFinal: true, timestamp: 0))
        #expect(await model.endSession())
        let saved = try SessionStore(directory: fixture.directory).load()
        #expect(saved.count == 1 && saved[0].id != item.id)
        #expect(saved[0].segments.map(\.text) == ["Only the successor words."])
    }

    @Test("Deleting a paused file releases its cache without stopping recognition twice")
    func deletesPausedFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Saved paused words.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        let item = try #require(model.selectedSession)
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.map(\.text) == ["Saved paused words."])
        model.delete(item)
        #expect(await model.flushPendingWrites())
        #expect(model.activeID == nil && model.sessions.isEmpty && model.selectedID == nil)
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
        #expect(!model.requiresTerminationWork)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("Deleting during startup cancels ownership before an old preparation can complete")
    func deletesPreparingFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber(suspendStartup: true)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        let item = try #require(model.selectedSession)
        let oldCallback = audio.onUpdate
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "An opening phrase captured during setup.", isFinal: false, timestamp: 0))
        model.delete(item)
        #expect(await model.flushPendingWrites())
        #expect(model.activeID == nil && model.sessions.isEmpty && !model.isBusy)
        #expect(audio.cancelCount >= 1 && audio.stopCount == 0)
        audio.releaseFirstStart()
        oldCallback?(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Late startup completion.", isFinal: true, timestamp: 1))
        for _ in 0..<5 { await Task.yield() }
        #expect(model.sessions.isEmpty && !model.isBusy && !audio.isRunning)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("Deleting during an in-flight pause waits for one drain without a flush deadlock")
    func deletesDuringPause() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Drain this before deletion.", isFinal: true, timestamp: 0))
        let item = try #require(model.selectedSession)
        let pause = Task { await model.pauseSession() }
        try await waitUntil { model.isSelectedPausing }
        model.delete(item)
        #expect(await model.flushPendingWrites())
        #expect(await pause.value)
        #expect(audio.stopCount == 1 && !audio.isRunning)
        #expect(model.sessions.isEmpty && model.activeID == nil && !model.requiresTerminationWork)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("Deleting saved history never stops the separately recording file")
    func deletesOtherFileWithoutInterruptingCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let history = fixture.session()
        try SessionStore(directory: fixture.directory).save(history)
        model.sessions = [history]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let active = try #require(model.activeID)
        model.selectedID = history.id
        model.delete(history)
        #expect(await model.flushPendingWrites())
        #expect(model.activeID == active && audio.isRunning)
        #expect(audio.stopCount == 0 && audio.cancelCount == 0)
        #expect(!model.sessions.contains { $0.id == history.id })
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The other file keeps recording.", isFinal: true, timestamp: 1))
        model.selectedID = active
        #expect(model.isSelectedRecording)
        #expect(model.selectedSession?.segments.map(\.text) == ["The other file keeps recording."])
        #expect(await model.endSession())
        #expect(try SessionStore(directory: fixture.directory).load().map(\.id) == [active])
    }

    @Test("Delete during a source switch prevents its deferred recording restart")
    func deletionWinsPendingSourceRestart() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Do not restart this deleted file.", isFinal: true, timestamp: 0))
        let item = try #require(model.selectedSession)
        let changing = Task { await model.updateSelectedSources([.microphone]) }
        try await waitUntil { model.isChangingSources }
        model.delete(item)
        #expect(await model.flushPendingWrites())
        _ = await changing.value
        #expect(audio.startCount == 1 && audio.stopCount == 1 && !audio.isRunning)
        #expect(model.sessions.isEmpty && model.activeID == nil && !model.isChangingSources)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("A failed preservation save leaves the paused words available for deletion retry")
    func failedDeletionSaveRetainsWordsForRetry() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("Fictional storage obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Retain these words until they can be saved safely.", isFinal: true, timestamp: 0))
        let item = try #require(model.selectedSession)
        model.delete(item)
        #expect(!(await model.flushPendingWrites()))
        #expect(model.activeID == item.id && model.isPaused && model.sessions.count == 1)
        #expect(model.selectedSession?.segments.map(\.text) == ["Retain these words until they can be saved safely."])
        #expect(model.notice != nil && !model.isDeletingTranscript)
        try FileManager.default.removeItem(at: fixture.directory)
        model.delete(item)
        #expect(await model.flushPendingWrites())
        #expect(model.sessions.isEmpty && model.activeID == nil && !model.requiresTerminationWork)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("Quitting waits for an already requested live deletion instead of saving it again")
    func quitWaitsForLiveDeletion() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The user chose to delete this file.", isFinal: true, timestamp: 0))
        model.delete(try #require(model.selectedSession))
        #expect(model.requiresTerminationWork)
        #expect(await model.prepareToQuit())
        #expect(model.sessions.isEmpty && model.activeID == nil && !audio.isRunning)
        #expect(!model.requiresTerminationWork)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("A late cancelled setup cannot discard the next session")
    func protectsRestartFromOldSetup() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber(suspendStartup: true)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        let firstID = try #require(model.activeID)
        #expect(await model.endSession())
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 2 }
        let secondID = try #require(model.activeID)
        #expect(firstID != secondID)
        audio.releaseFirstStart()
        await Task.yield()
        await Task.yield()
        #expect(model.activeID == secondID)
        #expect(model.sessions.map(\.id) == [secondID])
        audio.releaseFirstStart()
        try await waitUntil { audio.isRunning }
        #expect(await model.endSession())
    }

    @Test("Ending a session includes the recognizer's last finalized words")
    func drainsFinalRecognitionResult() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .microphone, text: "We should meet", isFinal: false, timestamp: 1))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .microphone, text: "We should meet tomorrow.", isFinal: true, timestamp: 1)
        #expect(await model.endSession())
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.segments.count == 1)
        #expect(saved.segments[0].text == "We should meet tomorrow.")
        #expect(saved.segments[0].isFinal)
        #expect(model.canExport)
        #expect(!model.requiresTerminationWork)
    }

    @Test("Repeated end requests share a single recognizer stop")
    func coalescesEnding() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio, text: "A fictional reply.", isFinal: true, timestamp: 0))
        async let first = model.endSession()
        async let second = model.endSession()
        let results = await [first, second]
        #expect(results == [true, true])
        #expect(audio.stopCount == 1)
        #expect(try SessionStore(directory: fixture.directory).load().count == 1)
    }

    @Test("A pending autosave preserves a title changed during transcription")
    func autosaveKeepsLatestTitle() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone, text: "A fictional planning note.", isFinal: false, timestamp: 0))
        let item = try #require(model.selectedSession)
        model.rename(item, to: "Planning notes")
        // Exercise the actual 650ms debounce rather than replacing it with a
        // direct flush: this previously restored the pre-rename snapshot.
        try await Task.sleep(for: .milliseconds(750))
        #expect(try SessionStore(directory: fixture.directory).load().first?.title == "Planning notes")
        #expect(await model.endSession())
    }

    @Test("Deleting while a rename is queued cannot recreate the transcript")
    func queuedRenameCannotResurrectDeletedSession() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(service: TestTranscriber())
        let item = fixture.session()
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        model.sessions = [item]
        model.rename(item, to: "Queued rename")
        model.delete(item)
        #expect(await model.flushPendingWrites())
        #expect(model.sessions.isEmpty)
        #expect(try store.load().isEmpty)
    }

    @Test("Quit waits for a rename that has not reached the filesystem yet")
    func quittingFlushesQueuedRename() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model(service: TestTranscriber())
        let item = fixture.session()
        try SessionStore(directory: fixture.directory).save(item)
        model.sessions = [item]
        model.rename(item, to: "Latest name before quitting")
        #expect(model.requiresTerminationWork)
        #expect(await model.prepareToQuit())
        #expect(try SessionStore(directory: fixture.directory).load().first?.title == "Latest name before quitting")
        #expect(!model.requiresTerminationWork)
    }

    @Test("A save failure blocks quitting and retains the complete transcript for retry")
    func failedSaveRetainsTranscriptAndBlocksQuit() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        // A file where the sessions directory belongs reliably forces I/O
        // failure without changing permissions or touching real app data.
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone, text: "Keep every word.", isFinal: true, timestamp: 0))
        #expect(!(await model.endSession()))
        #expect(model.selectedSession?.segments.first?.text == "Keep every word.")
        #expect(model.canExport)
        #expect(model.requiresTerminationWork)
        #expect(!(await model.prepareToQuit()))
        #expect(audio.cancelCount == 0)
        #expect(model.notice != nil)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
        #expect(audio.cancelCount == 1)
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.first?.text == "Keep every word.")
        #expect(!model.requiresTerminationWork)
    }

    @Test("Discovering another document preserves the current live session and selection")
    func discoveredFileDoesNotInterruptCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        let audio = TestTranscriber()
        let model = RelayModel(directory: fixture.directory, defaults: fixture.defaults, service: audio, permissions: .testing())
        try await waitUntil { model.isLoaded }
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let active = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep the current session running.", isFinal: true, timestamp: 0))
        var incoming = fixture.session()
        incoming.title = "Arriving workshop notes"
        try SessionStore(directory: fixture.directory).save(incoming)
        try await waitUntil { model.sessions.contains(where: { $0.id == incoming.id }) }
        #expect(model.activeID == active)
        #expect(model.selectedID == active)
        #expect(model.isBusy)
        #expect(model.isShowingLive)
        #expect(model.selectedSession?.segments.first?.text == "Keep the current session running.")
        #expect(await model.endSession())
        #expect(try SessionStore(directory: fixture.directory).load().count == 2)
    }

    @Test("Legacy locale separators normalize to the same picker identifier")
    func canonicalizesLanguagePreference() throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set("en_US", forKey: "transcriptionLanguage")
        let model = fixture.model(service: TestTranscriber())
        #expect(model.defaultLanguageID == "en-US")
        model.defaultLanguageID = "fr_FR"
        #expect(model.defaultLanguageID == "fr-FR")
        #expect(fixture.defaults.string(forKey: "transcriptionLanguage") == "fr-FR")
    }

    @Test("Pausing drains recognition and resumes the same document with continuing timestamps")
    func pausesAndResumesSameDocument() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        let firstPhrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: firstPhrase, source: .microphone,
            text: "Before the pause", isFinal: false, timestamp: 2))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: firstPhrase, source: .microphone,
            text: "Before the pause.", isFinal: true, timestamp: 2)
        #expect(await model.pauseSession())
        #expect(model.activeID == id)
        #expect(model.isPaused && model.isSelectedPaused)
        #expect(!model.isBusy && !model.isShowingLive)
        #expect(model.canExport && model.canResumeSelectedSession && model.canEndSelectedSession)
        #expect(model.selectedSession?.segments.first?.text == "Before the pause.")
        #expect(model.selectedSession?.endedAt != nil)
        let frozenDuration = try #require(model.selectedSession?.duration)
        try await Task.sleep(for: .milliseconds(20))
        #expect(frozenDuration == model.selectedSession?.duration)
        #expect(try SessionStore(directory: fixture.directory).load().first?.endedAt != nil)
        audio.finalUpdateOnStop = nil
        #expect(await model.updateSelectedSources([.microphone]))
        #expect(await model.updateSelectedLanguage("fr-FR"))
        model.resumeSelectedSession()
        try await waitUntil { audio.isRunning }
        #expect(model.activeID == id && model.sessions.count == 1)
        #expect(model.selectedSession?.endedAt == nil)
        #expect(audio.requestedSources == [.microphone])
        #expect(audio.requestedLocale == "fr-FR")
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "After the pause.", isFinal: true, timestamp: 1))
        let result = try #require(model.selectedSession)
        #expect(result.segments.map(\.text) == ["Before the pause.", "After the pause."])
        #expect(result.segments[1].timestamp == max(frozenDuration, result.segments[0].timestamp) + 1)
        #expect(result.segments[1].timestamp > result.segments[0].timestamp)
        #expect(await model.endSession())
        #expect(model.activeID == nil && !model.isPaused)
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.count == 2)
    }

    @Test("A completed transcript resumes without replacing its identifier or history")
    func resumesCompletedDocument() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let item = fixture.session()
        try SessionStore(directory: fixture.directory).save(item)
        model.sessions = [item]
        model.selectedID = item.id
        #expect(!model.canEndSelectedSession)
        #expect(model.canResumeSelectedSession)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        #expect(model.activeID == item.id)
        #expect(model.isSelectedRecording && model.canPauseSelectedSession)
        #expect(model.selectedSession?.segments == item.segments)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "A later continuation.", isFinal: true, timestamp: 0))
        #expect(model.selectedSession?.segments.count == 2)
        #expect(await model.endSession())
        #expect(model.sessions.count == 1)
        #expect(model.selectedSession?.id == item.id)
        #expect(model.canResumeSelectedSession && !model.canEndSelectedSession)
    }

    @Test("Browsing completed history never controls or overwrites a different capture")
    func selectedHistoryDoesNotControlAnotherSession() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let history = fixture.session()
        model.sessions = [history]
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let active = try #require(model.activeID)
        model.selectedID = history.id
        #expect(model.isBusy)
        #expect(!model.isSelectedRecording && !model.isSelectedPreparing)
        #expect(!model.canEndSelectedSession && !model.canPauseSelectedSession)
        #expect(model.canResumeSelectedSession && model.canToggleRecording)
        model.toggleRecording()
        #expect(model.resumeSessionPrompt?.activeID == active)
        #expect(model.resumeSessionPrompt?.targetID == history.id)
        #expect(model.activeID == active && audio.stopCount == 0)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Recording continues while the prompt is open.", isFinal: true, timestamp: 0))
        #expect(model.sessions.first { $0.id == active }?.segments.last?.text == "Recording continues while the prompt is open.")
        model.cancelResumeSessionRequest()
        #expect(model.resumeSessionPrompt == nil && audio.isRunning && audio.stopCount == 0)
        model.selectedID = active
        #expect(await model.pauseSession())
        model.selectedID = history.id
        #expect(model.canResumeSelectedSession && model.canToggleRecording)
        model.resumeSelectedSession()
        try await waitUntil { model.activeID == history.id && model.isSelectedRecording }
        #expect(audio.stopCount == 1 && audio.startCount == 2)
        #expect(model.sessions.first { $0.id == active }?.endedAt != nil)
        #expect(!model.canStartNewSession)
        #expect(model.canRequestNewSession)
        model.newSession()
        #expect(model.newSessionPrompt?.activeID == history.id)
        model.cancelNewSessionRequest()
        #expect(model.selectedID == history.id)
        #expect(await model.endSession())
        #expect(model.activeID == nil && model.canStartNewSession)
    }

    @Test("End requested during a pause completes after a single recognizer drain")
    func endDuringPauseDoesNotLeavePausedOwnership() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep this final phrase.", isFinal: true, timestamp: 0))
        async let pause = model.pauseSession()
        try await waitUntil { model.isPausing }
        #expect(!model.canResumeSelectedSession)
        async let end = model.endSession()
        let results = await [pause, end]
        #expect(results == [true, true])
        #expect(audio.stopCount == 1)
        #expect(model.activeID == nil && !model.isPaused && !model.isBusy)
        #expect(model.canResumeSelectedSession && !model.canEndSelectedSession)
    }

    @Test("Paused documents reopen safely as resumable saved history")
    func pausedDocumentSurvivesRelaunch() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Saved while paused.", isFinal: false, timestamp: 3))
        #expect(await model.pauseSession())
        let id = try #require(model.activeID)
        let reloaded = RelayModel(directory: fixture.directory, defaults: fixture.defaults, service: TestTranscriber(), permissions: .testing())
        try await waitUntil { reloaded.isLoaded }
        reloaded.selectedID = id
        #expect(reloaded.activeID == nil && !reloaded.isBusy)
        #expect(reloaded.canResumeSelectedSession && reloaded.canExport)
        #expect(reloaded.selectedSession?.segments.first?.isFinal == true)
        #expect(await model.endSession())
    }

    @Test("Pause cancels preparation without late setup changing the resumed document")
    func pauseDuringPreparationProtectsResume() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber(suspendStartup: true)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        let id = try #require(model.activeID)
        #expect(await model.pauseSession())
        #expect(model.isSelectedPaused)
        model.resumeSelectedSession()
        try await waitUntil { audio.pendingStartCount == 2 }
        audio.releaseFirstStart()
        await Task.yield()
        #expect(model.activeID == id && model.isSelectedPreparing)
        audio.releaseFirstStart()
        try await waitUntil { audio.isRunning }
        #expect(model.activeID == id)
        #expect(await model.endSession())
        #expect(model.sessions.map(\.id) == [id])
        #expect(try SessionStore(directory: fixture.directory).load().first?.id == id)
    }

    @Test("Pause save failure keeps words available and blocks quitting until retry")
    func pauseSaveFailureRetainsWords() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Do not lose these words.", isFinal: true, timestamp: 0))
        #expect(!(await model.pauseSession()))
        #expect(model.isSelectedPaused && model.selectedSession?.segments.count == 1)
        #expect(!(await model.prepareToQuit()))
        #expect(model.requiresTerminationWork)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.first?.text == "Do not lose these words.")
    }

    @Test("Each transcript resumes its own sources independently of the next-session draft")
    func resumedSourcesDoNotBleedBetweenFiles() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.sources = [.microphone]
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let microphoneID = try #require(model.activeID)
        #expect(model.selectedSession?.sources == [.microphone])
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Microphone document.", isFinal: true, timestamp: 0))
        #expect(await model.endSession())
        model.newSession()
        model.sources = [.systemAudio]
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let systemID = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "System audio document.", isFinal: true, timestamp: 0))
        #expect(await model.endSession())
        model.sources = []
        model.selectedID = microphoneID
        #expect(model.canResumeSelectedSession)
        model.resumeSelectedSession()
        try await waitUntil { audio.isRunning }
        #expect(audio.requestedSources == [.microphone])
        #expect(await model.endSession())
        model.selectedID = systemID
        model.resumeSelectedSession()
        try await waitUntil { audio.isRunning }
        #expect(audio.requestedSources == [.systemAudio])
        #expect(await model.endSession())
        let stored = try SessionStore(directory: fixture.directory).load()
        #expect(stored.first { $0.id == microphoneID }?.sources == [.microphone])
        #expect(stored.first { $0.id == systemID }?.sources == [.systemAudio])
    }

    @Test("Changing live sources drains final words and resumes only after the same file saves")
    func switchesLiveSourcesWithoutLosingWords() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .systemAudio,
            text: "Final words", isFinal: false, timestamp: 1))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .systemAudio,
            text: "Final words before switching.", isFinal: true, timestamp: 1)
        let change = Task { await model.updateSelectedSources([.microphone]) }
        try await waitUntil { model.isChangingSources }
        #expect(!model.canRequestNewSession && !model.canEndSelectedSession && !model.canEditSelectedSources)
        #expect(!(await model.endSession()))
        #expect(!(await model.updateSelectedSources([.systemAudio])))
        #expect(await change.value)
        try await waitUntil { audio.isRunning }
        #expect(model.activeID == id && model.sessions.count == 1)
        #expect(audio.requestedSources == [.microphone] && audio.stopCount == 1)
        #expect(model.selectedSession?.segments.first?.text == "Final words before switching.")
        let stored = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(stored.sources == [.microphone])
        #expect(stored.segments.first?.isFinal == true)
        audio.finalUpdateOnStop = nil
        #expect(await model.endSession())
    }

    @Test("An immediate restart failure after a source change cannot leave a phantom active capture")
    func failedSourceRestartFinalizesSafely() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep the previous capture.", isFinal: true, timestamp: 0))
        audio.failingStartAttempt = 2
        #expect(await model.updateSelectedSources([.microphone]))
        try await waitUntil { model.activeID == nil && !model.isBusy }
        #expect(model.notice != nil && !model.isChangingSources)
        #expect(model.selectedSession?.id == id)
        #expect(model.selectedSession?.segments.first?.text == "Keep the previous capture.")
        #expect(model.canResumeSelectedSession)
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.id == id && saved.sources == [.microphone] && saved.endedAt != nil)
    }

    @Test("Editing a paused or completed file's sources never starts audio")
    func sourceChangesStayPausedOrCompleted() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep the existing words.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        let id = try #require(model.activeID)
        let starts = audio.startCount
        #expect(await model.updateSelectedSources([.systemAudio]))
        #expect(model.isSelectedPaused && !audio.isRunning && audio.startCount == starts)
        #expect(model.activeID == id && model.selectedSession?.sources == [.systemAudio])
        #expect(await model.endSession())
        #expect(await model.updateSelectedSources([.microphone]))
        #expect(model.activeID == nil && !audio.isRunning && audio.startCount == starts)
        #expect(model.selectedSession?.segments.first?.text == "Keep the existing words.")
        #expect(try SessionStore(directory: fixture.directory).load().first?.sources == [.microphone])
    }

    @Test("A source change cannot remove the last source or interrupt preparation")
    func rejectsEmptySourcesAndPreparationChanges() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber(suspendStartup: true)
        let model = fixture.model(service: audio)
        model.sources = [.microphone]
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        #expect(!model.canEditSelectedSources && !model.canRequestNewSession)
        #expect(!(await model.updateSelectedSources([.systemAudio])))
        audio.releaseFirstStart()
        try await waitUntil { audio.isRunning }
        #expect(!(await model.updateSelectedSources([])))
        #expect(audio.stopCount == 0 && audio.isRunning)
        #expect(model.selectedSession?.sources == [.microphone])
        #expect(await model.endSession())
    }

    @Test("A failed source-change save leaves the capture safely paused with all words")
    func failedSourceSaveDoesNotRestart() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Save before restarting.", isFinal: true, timestamp: 0))
        #expect(!(await model.updateSelectedSources([.microphone])))
        #expect(model.activeID == id && model.isSelectedPaused && !audio.isRunning)
        #expect(audio.startCount == 1)
        #expect(model.selectedSession?.segments.first?.text == "Save before restarting.")
        #expect(model.requiresTerminationWork)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
    }

    @Test("Updating history sources preserves a separate live capture and its selection")
    func historySourceChangeDoesNotAffectLiveSession() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        var history = fixture.session()
        history.sources = [.microphone]
        try SessionStore(directory: fixture.directory).save(history)
        model.sessions = [history]
        model.sources = [.systemAudio]
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let active = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "Uninterrupted live audio.", isFinal: false, timestamp: 0))
        model.selectedID = history.id
        #expect(model.canEditSelectedSources)
        #expect(await model.updateSelectedSources([.systemAudio]))
        #expect(model.activeID == active && model.selectedID == history.id)
        #expect(audio.isRunning && audio.stopCount == 0 && audio.startCount == 1)
        #expect(model.sessions.first { $0.id == active }?.sources == [.systemAudio])
        #expect(model.sessions.first { $0.id == active }?.segments.first?.text == "Uninterrupted live audio.")
        #expect(await model.endSession())
    }

    @Test("Cancelling a source-change caller does not cancel its atomic save and restart")
    func cancelledCallerDoesNotSplitSourceTransaction() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep this transaction whole.", isFinal: true, timestamp: 0))
        let task = Task { await model.updateSelectedSources([.microphone]) }
        try await waitUntil { model.isChangingSources }
        task.cancel()
        #expect(await task.value)
        try await waitUntil { audio.isRunning }
        #expect(model.selectedSession?.sources == [.microphone])
        #expect(try SessionStore(directory: fixture.directory).load().first?.sources == [.microphone])
        #expect(await model.endSession())
    }

    @Test("New transcription confirmation can be cancelled without changing the running document")
    func cancelsNewRequestWithoutStopping() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        model.newSession()
        #expect(model.newSessionPrompt?.activeID == id)
        #expect(model.newSessionPrompt?.isPaused == false)
        model.cancelNewSessionRequest()
        #expect(model.newSessionPrompt == nil && model.activeID == id)
        #expect(audio.isRunning && audio.stopCount == 0)
        #expect(await model.endSession())
    }

    @Test("Confirming New saves the active file and returns to setup without starting audio")
    func confirmsNewRequestAfterSaving() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Save this before a new transcript.", isFinal: false, timestamp: 0))
        model.newSession()
        #expect(await model.confirmNewSessionRequest())
        #expect(model.activeID == nil && model.selectedID == nil && !audio.isRunning)
        #expect(model.newSessionPrompt == nil && audio.startCount == 1)
        #expect(model.sessions.first?.id == id)
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.first?.text == "Save this before a new transcript.")
        model.sources = [.systemAudio]
        #expect(model.canToggleRecording)
    }

    @Test("New from a paused transcript opens setup directly without a second audio drain")
    func newFromPausedDocumentNeedsNoConfirmation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Paused and saved.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        model.newSession()
        #expect(model.newSessionPrompt == nil)
        try await waitUntil { model.selectedID == nil && model.activeID == nil && !model.isConfirmingNewSession }
        #expect(model.selectedID == nil && model.activeID == nil && audio.stopCount == 1)
    }

    @Test("Resuming another file saves and releases the previously paused file")
    func resumesDifferentFileAfterPausedSave() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let other = fixture.session()
        model.sessions = [other]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let pausedID = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Preserve file A before switching.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        model.selectedID = other.id
        #expect(model.canResumeSelectedSession)
        model.resumeSelectedSession()
        #expect(model.resumeSessionPrompt == nil)
        try await waitUntil { model.activeID == other.id && model.isSelectedRecording }
        #expect(model.resumeSessionPrompt == nil)
        #expect(audio.startCount == 2 && audio.stopCount == 1)
        let savedA = try #require(SessionStore(directory: fixture.directory).load().first { $0.id == pausedID })
        #expect(savedA.endedAt != nil)
        #expect(savedA.segments.first?.text == "Preserve file A before switching.")
        #expect(model.selectedSession?.segments == other.segments)
        #expect(await model.endSession())
    }

    @Test("Confirmed Resume drains and saves the current file before continuing the selected file")
    func confirmedResumePreservesBothFiles() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let target = TranscriptSession(title: "Review notes", startedAt: clock.date.addingTimeInterval(-600),
            endedAt: clock.date.addingTimeInterval(-300),
            segments: [TranscriptSegment(source: .systemAudio, text: "The previous review.", timestamp: 30)],
            sources: [.systemAudio], recordedDuration: 45)
        let store = SessionStore(directory: fixture.directory)
        try store.save(target)
        let model = fixture.model(service: audio, now: { clock.date })
        model.sessions = [target]
        model.sources = [.microphone]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let firstID = try #require(model.activeID)
        let firstStartedAt = try #require(model.selectedSession?.startedAt)
        let phraseID = UUID()
        clock.advance(135)
        audio.emit(TranscriptUpdate(segmentID: phraseID, source: .microphone,
            text: "Finish this phrase", isFinal: false, timestamp: 134))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phraseID, source: .microphone,
            text: "Finish this phrase before switching.", isFinal: true, timestamp: 134)
        model.selectedID = target.id
        model.resumeSelectedSession()
        let request = try #require(model.resumeSessionPrompt)
        #expect(audio.stopCount == 0 && audio.startCount == 1)
        // The new recognizer starts a fresh audio epoch after the old one drains.
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        #expect(await model.confirmResumeSessionRequest(request.id))
        try await waitUntil { model.activeID == target.id && model.isSelectedRecording }
        #expect(model.selectedID == target.id && model.resumeSessionPrompt == nil)
        #expect(audio.startCount == 2 && audio.stopCount == 1 && audio.requestedSources == target.sources)
        let savedFirst = try #require(store.load().first { $0.id == firstID })
        #expect(savedFirst.startedAt == firstStartedAt && savedFirst.sources == [.microphone])
        #expect(savedFirst.duration == 135)
        let finalPhrase = try #require(savedFirst.segments.first)
        #expect(savedFirst.segments.count == 1 && finalPhrase.isFinal)
        #expect(finalPhrase.text == "Finish this phrase before switching.")
        let resumed = try #require(model.selectedSession)
        #expect(resumed.id == target.id && resumed.startedAt == target.startedAt)
        #expect(resumed.sources == target.sources && resumed.segments == target.segments)
        #expect(model.duration(for: resumed, at: clock.date) == 45)
        audio.finalUpdateOnStop = nil
        clock.advance(2)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "Continue the review.", isFinal: true, timestamp: 1))
        #expect(model.selectedSession?.segments.last?.timestamp == 46)
        #expect(await model.endSession())
        let savedTarget = try #require(store.load().first { $0.id == target.id })
        #expect(savedTarget.duration == 47)
    }

    @Test("A failed Resume-confirmation save keeps the current file paused and never starts the target")
    func confirmedResumeSaveFailureRetainsCurrentFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let target = fixture.session()
        model.sessions = [target]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let firstID = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Preserve the current recording.", isFinal: true, timestamp: 0))
        model.selectedID = target.id
        model.resumeSelectedSession()
        let request = try #require(model.resumeSessionPrompt)
        #expect(!(await model.confirmResumeSessionRequest(request.id)))
        #expect(model.activeID == firstID && model.isPaused && model.selectedID == target.id)
        #expect(audio.startCount == 1 && audio.stopCount == 1 && !audio.isRunning)
        #expect(model.sessions.first { $0.id == firstID }?.segments.first?.text == "Preserve the current recording.")
        #expect(model.sessions.first { $0.id == target.id }?.segments == target.segments)
        #expect(model.notice != nil && model.requiresTerminationWork)
        try FileManager.default.removeItem(at: fixture.directory)
        model.resumeSelectedSession()
        #expect(model.resumeSessionPrompt == nil, "Retrying from the safely paused state needs no second confirmation.")
        try await waitUntil { model.activeID == target.id && model.isSelectedRecording }
        #expect(try SessionStore(directory: fixture.directory).load().contains { $0.id == firstID })
        #expect(await model.endSession())
    }

    @Test("Stale Resume requests and changed target selection cannot pause the current recording")
    func staleResumeRequestCannotAuthorizeAnotherTarget() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let target = fixture.session()
        let another = fixture.session()
        model.sessions = [target, another]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let firstID = try #require(model.activeID)
        model.selectedID = target.id
        model.resumeSelectedSession()
        let stale = try #require(model.resumeSessionPrompt)
        model.cancelResumeSessionRequest()
        model.resumeSelectedSession()
        let current = try #require(model.resumeSessionPrompt)
        #expect(current.id != stale.id)
        #expect(!(await model.confirmResumeSessionRequest(stale.id)))
        #expect(model.resumeSessionPrompt?.id == current.id)
        #expect(model.activeID == firstID && audio.isRunning && audio.stopCount == 0)
        model.selectedID = another.id
        #expect(!(await model.confirmResumeSessionRequest(current.id)))
        #expect(model.activeID == firstID && audio.isRunning && audio.stopCount == 0 && audio.startCount == 1)
        #expect(model.selectedID == another.id)
        model.cancelResumeSessionRequest()
        #expect(await model.endSession())
    }

    @Test("Selection changes or quit during a confirmed Resume drain cannot start its stale target", arguments: [false, true])
    func interruptedConfirmedResumeDoesNotStartTarget(quitting: Bool) async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(60)
        let model = fixture.model(service: audio)
        let target = fixture.session()
        let latest = fixture.session()
        model.sessions = [target, latest]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let firstID = try #require(model.activeID)
        let phrase = UUID()
        audio.emit(TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Keep the final", isFinal: false, timestamp: 0))
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: phrase, source: .microphone,
            text: "Keep the final words.", isFinal: true, timestamp: 0)
        model.selectedID = target.id
        model.resumeSelectedSession()
        let request = try #require(model.resumeSessionPrompt)
        let confirming = Task { await model.confirmResumeSessionRequest(request.id) }
        try await waitUntil { model.isPausing }
        if quitting {
            let quit = Task { await model.prepareToQuit() }
            #expect(!(await confirming.value))
            #expect(await quit.value)
            #expect(model.activeID == nil && !model.requiresTerminationWork)
        } else {
            model.selectedID = latest.id
            #expect(!(await confirming.value))
            #expect(model.selectedID == latest.id && !audio.isRunning)
        }
        #expect(audio.startCount == 1 && audio.stopCount == 1)
        let saved = try #require(SessionStore(directory: fixture.directory).load().first { $0.id == firstID })
        #expect(saved.segments.first?.text == "Keep the final words." && saved.segments.first?.isFinal == true)
        if !quitting { #expect(await model.prepareToQuit()) }
    }

    @Test("A paused New request cannot leave an unsaved file behind")
    func pausedNewSaveFailurePreservesCurrentFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "This paused file still needs saving.", isFinal: true, timestamp: 0))
        #expect(!(await model.pauseSession()))
        model.newSession()
        try await waitUntil { !model.isConfirmingNewSession }
        #expect(model.newSessionPrompt == nil)
        #expect(model.selectedID == id && model.activeID == id && model.isPaused)
        #expect(model.selectedSession?.segments.first?.text == "This paused file still needs saving.")
        #expect(model.notice != nil && model.requiresTerminationWork && audio.startCount == 1)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
    }

    @Test("A failed paused-file save blocks another file's resume until retry succeeds")
    func failedPausedSaveBlocksDifferentResume() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let other = fixture.session()
        model.sessions = [other]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let pausedID = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Do not strand these unsaved words.", isFinal: true, timestamp: 0))
        #expect(!(await model.pauseSession()))
        model.selectedID = other.id
        model.resumeSelectedSession()
        try await waitUntil { !model.isConfirmingNewSession }
        #expect(model.activeID == pausedID && model.isPaused)
        #expect(model.selectedID == other.id && audio.startCount == 1 && !audio.isRunning)
        #expect(model.sessions.first { $0.id == pausedID }?.segments.first?.text == "Do not strand these unsaved words.")
        try FileManager.default.removeItem(at: fixture.directory)
        model.resumeSelectedSession()
        try await waitUntil { model.activeID == other.id && model.isSelectedRecording }
        #expect(audio.startCount == 2)
        #expect(try SessionStore(directory: fixture.directory).load().contains { $0.id == pausedID })
        #expect(await model.endSession())
    }

    @Test("Changing selection during a paused-file handoff never starts a stale target")
    func selectionChangeCancelsStaleResumeTarget() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let target = fixture.session()
        let latest = fixture.session()
        model.sessions = [target, latest]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Preserve the paused transcript.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        model.selectedID = target.id
        model.resumeSelectedSession()
        model.selectedID = latest.id
        try await waitUntil { !model.isConfirmingNewSession }
        #expect(model.selectedID == latest.id && audio.startCount == 1 && !audio.isRunning)
        #expect(!model.isSelectedPreparing && !model.isSelectedRecording)
        #expect(await model.prepareToQuit())
    }

    @Test("Quit during a paused-file handoff saves without starting the requested file")
    func quitCancelsPendingResumeTarget() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        let target = fixture.session()
        model.sessions = [target]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Save before quitting the handoff.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        model.selectedID = target.id
        model.resumeSelectedSession()
        #expect(await model.prepareToQuit())
        #expect(model.activeID == nil && audio.startCount == 1 && !model.requiresTerminationWork)
    }

    @Test("A failed New confirmation keeps the existing transcript instead of creating a replacement")
    func failedNewSaveKeepsExistingDocument() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let id = try #require(model.activeID)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The existing document must remain.", isFinal: true, timestamp: 0))
        model.newSession()
        #expect(!(await model.confirmNewSessionRequest()))
        #expect(model.selectedID == id && model.sessions.count == 1)
        #expect(model.selectedSession?.segments.first?.text == "The existing document must remain.")
        #expect(!audio.isRunning && audio.startCount == 1 && model.requiresTerminationWork)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
    }

    @Test("A stale New confirmation cannot end a different active document")
    func staleNewRequestCannotEndAnotherCapture() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        model.newSession()
        let request = try #require(model.newSessionPrompt)
        #expect(await model.endSession())
        model.selectedID = nil
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        let current = try #require(model.activeID)
        #expect(current != request.activeID)
        model.newSessionPrompt = request
        #expect(!(await model.confirmNewSessionRequest()))
        #expect(model.activeID == current && audio.isRunning && audio.stopCount == 1)
        #expect(await model.endSession())
    }

    @Test("A stale alert action cannot confirm the newer request currently displayed")
    func staleAlertActionCannotAuthorizeReplacementRequest() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        model.newSession()
        let oldRequest = try #require(model.newSessionPrompt)
        model.cancelNewSessionRequest()
        model.newSession()
        let currentRequest = try #require(model.newSessionPrompt)
        #expect(currentRequest.id != oldRequest.id)
        #expect(!(await model.confirmNewSessionRequest(oldRequest.id)))
        #expect(model.newSessionPrompt?.id == currentRequest.id)
        #expect(audio.isRunning && audio.stopCount == 0)
        #expect(await model.confirmNewSessionRequest(currentRequest.id))
        #expect(model.activeID == nil && model.selectedID == nil && !audio.isRunning)
    }

    @Test("Quitting during a live source switch waits for its save without restarting audio")
    func quitWaitsForSourceTransaction() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.isRunning }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Finish saving before quitting.", isFinal: true, timestamp: 0))
        let sourceChange = Task { await model.updateSelectedSources([.microphone]) }
        try await waitUntil { model.isChangingSources }
        #expect(await model.prepareToQuit())
        _ = await sourceChange.value
        #expect(!model.isChangingSources && model.activeID == nil && !audio.isRunning)
        #expect(audio.startCount == 1)
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.first?.text == "Finish saving before quitting.")
    }

    @Test("A new capture starts at zero after preparation and checkpoints only captured time")
    func newTimerExcludesPreparation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber(suspendStartup: true)
        audio.captureStartedAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        clock.advance(3)
        #expect(try elapsed(model, at: clock.date) == 0)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep the opening words.", isFinal: true, timestamp: 1))
        audio.captureReadyAt = clock.date
        audio.releaseFirstStart()
        try await waitUntil { model.isSelectedRecording }
        #expect(try elapsed(model, at: clock.date) == 0)
        #expect(model.selectedSession?.segments.first?.timestamp == 0)
        clock.advance(2)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "The next spoken phrase.", isFinal: true, timestamp: 4))
        #expect(try elapsed(model, at: clock.date) == 2)
        #expect(model.selectedSession?.segments.last?.timestamp == 1)
        #expect(await model.flushPendingWrites())
        #expect(try SessionStore(directory: fixture.directory).load().first?.recordedDuration == 2)
        #expect(await model.endSession())
        #expect(model.selectedSession?.duration == 2)
    }

    @Test("Pause and resume retain captured duration across a long gap and fresh preparation")
    func resumedTimerExcludesPauseAndPreparation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber(suspendStartup: true)
        audio.captureStartedAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        clock.advance(3)
        audio.captureReadyAt = clock.date
        audio.releaseFirstStart()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        let createdAt = try #require(model.selectedSession?.startedAt)
        clock.advance(135)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Before the long pause.", isFinal: true, timestamp: 137))
        #expect(await model.pauseSession())
        #expect(model.selectedSession?.duration == 135)
        clock.advance(86_400)
        #expect(try elapsed(model, at: clock.date) == 135)
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = nil
        model.resumeSelectedSession()
        try await waitUntil { audio.pendingStartCount == 1 }
        clock.advance(7)
        #expect(try elapsed(model, at: clock.date) == 135)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep this new opening too.", isFinal: true, timestamp: 1))
        audio.captureReadyAt = clock.date
        audio.releaseFirstStart()
        try await waitUntil { model.isSelectedRecording }
        #expect(try elapsed(model, at: clock.date) == 135)
        #expect(model.selectedSession?.segments.last?.timestamp == 135)
        clock.advance(3)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Continue the same transcript.", isFinal: true, timestamp: 9))
        #expect(model.selectedSession?.segments.last?.timestamp == 137)
        #expect(try elapsed(model, at: clock.date) == 138)
        #expect(await model.endSession())
        #expect(model.selectedSession?.id == id && model.selectedSession?.startedAt == createdAt)
        #expect(model.selectedSession?.duration == 138)
        #expect(try SessionStore(directory: fixture.directory).load().first?.recordedDuration == 138)
    }

    @Test("An unconfirmed stored estimate cannot extend resumed capture time")
    func resumedClockIgnoresUnconfirmedEstimate() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let unknown = TranscriptSegment(source: .microphone, text: "Preserve these untimed words.",
                                        timestamp: 180, timingIsConfirmed: false)
        let item = TranscriptSession(title: "Fictional timing recovery",
            startedAt: clock.date.addingTimeInterval(-60), endedAt: clock.date,
            segments: [unknown], recordedDuration: 60)
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        let model = fixture.model(service: audio, now: { clock.date })
        model.sessions = [item]
        model.selectedID = item.id
        model.resumeSelectedSession()
        try await waitUntil { model.isSelectedRecording }
        #expect(try elapsed(model, at: clock.date) == 60)
        let nextID = UUID()
        audio.emit(TranscriptUpdate(segmentID: nextID, source: .microphone,
            text: "The next confirmed phrase.", isFinal: true, timestamp: 0.5))
        #expect(model.selectedSession?.segments.first { $0.id == nextID }?.timestamp == 60.5)
        clock.advance(2)
        #expect(await model.pauseSession())
        let saved = try #require(store.load().first)
        #expect(saved.recordedDuration == 62)
        #expect(saved.segments.first { $0.id == nextID }?.timestamp == 60.5)
        #expect(saved.segments.first { $0.id == unknown.id } == unknown)
    }

    @Test("Changing live sources freezes the same clock during restart preparation")
    func sourceChangeTimerExcludesPreparation() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber(suspendStartup: true)
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        audio.releaseFirstStart()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        clock.advance(42)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "Before changing the sources.", isFinal: true, timestamp: 41))
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = nil
        let change = Task { await model.updateSelectedSources([.microphone]) }
        try await waitUntil { audio.pendingStartCount == 1 }
        clock.advance(17)
        #expect(try elapsed(model, at: clock.date) == 42)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The opening on the changed source.", isFinal: true, timestamp: 2))
        audio.captureReadyAt = clock.date
        audio.releaseFirstStart()
        #expect(await change.value)
        try await waitUntil { model.isSelectedRecording }
        #expect(try elapsed(model, at: clock.date) == 42)
        #expect(model.selectedSession?.segments.last?.timestamp == 42)
        clock.advance(4)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "After the sources are ready.", isFinal: true, timestamp: 19))
        #expect(model.selectedSession?.segments.last?.timestamp == 44)
        #expect(await model.endSession())
        #expect(model.selectedSession?.id == id && model.selectedSession?.duration == 46)
    }

    @Test("Ending freezes duration before final recognition drains")
    func endTimerExcludesRecognitionDrain() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        audio.stopDelay = .milliseconds(40)
        audio.finalUpdateOnStop = TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "The final recognized words.", isFinal: true, timestamp: 11)
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        clock.advance(12)
        let stoppedAt = clock.date
        let ending = Task { await model.endSession() }
        try await waitUntil { model.isSelectedStopping }
        clock.advance(90)
        #expect(try elapsed(model, at: clock.date) == 12)
        #expect(await ending.value)
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.duration == 12 && saved.endedAt == stoppedAt)
        #expect(saved.segments.first?.text == "The final recognized words.")
    }

    @Test("Legacy duration survives a failed resume without including the wall-clock gap")
    func legacyTimerSurvivesFailedResume() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.failingStartAttempt = 1
        let item = TranscriptSession(title: "Legacy fictional transcript",
            startedAt: clock.date.addingTimeInterval(-86_400),
            endedAt: clock.date.addingTimeInterval(-86_265),
            segments: [TranscriptSegment(source: .microphone, text: "Preserve the existing words.", timestamp: 130)])
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        let model = fixture.model(service: audio, now: { clock.date })
        model.sessions = [item]
        model.selectedID = item.id
        model.resumeSelectedSession()
        try await waitUntil { model.activeID == nil && !model.isBusy }
        #expect(model.notice != nil)
        #expect(model.selectedSession?.duration == 135)
        #expect(model.selectedSession?.segments == item.segments)
        #expect(try store.load().first?.recordedDuration == 135)
    }

    @Test("A failed save preserves exact captured duration for a later retry")
    func failedSaveRetainsCapturedDuration() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        clock.advance(135)
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Keep this complete transcript.", isFinal: true, timestamp: 134))
        #expect(!(await model.endSession()))
        #expect(model.selectedSession?.duration == 135 && model.requiresTerminationWork)
        clock.advance(86_400)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.duration == 135)
        #expect(saved.segments.first?.text == "Keep this complete transcript.")
    }

    @Test("Cancelling preparation preserves early recognized words without counting setup time")
    func cancellationKeepsEarlyWordsAtFrozenBoundary() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber(suspendStartup: true)
        audio.captureStartedAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Retain this opening speech.", isFinal: false, timestamp: 2))
        clock.advance(5)
        #expect(await model.endSession())
        audio.releaseFirstStart()
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.duration == 0)
        #expect(saved.segments.first?.timestamp == 0)
        #expect(saved.segments.first?.text == "Retain this opening speech.")
        #expect(saved.segments.first?.isFinal == true)
    }

    @Test("Quitting a silent recording preserves its file, sources, and captured duration")
    func quittingSilentCapturePreservesFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.sources = [.microphone]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        clock.advance(30)
        #expect(await model.prepareToQuit())
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.id == id && saved.segments.isEmpty && saved.sources == [.microphone])
        #expect(saved.duration == 30 && saved.endedAt == clock.date)
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
        #expect(model.activeID == nil && !model.requiresTerminationWork)
    }

    @Test("Quitting an already paused silent file preserves its frozen state")
    func quittingPausedSilentFilePreservesState() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.sources = [.systemAudio]
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        clock.advance(17)
        #expect(await model.pauseSession())
        let store = SessionStore(directory: fixture.directory)
        let before = try #require(store.load().first)
        clock.advance(3_600)
        #expect(await model.prepareToQuit())
        let after = try #require(store.load().first)
        #expect(after.id == before.id && after.segments.isEmpty && after.sources == before.sources)
        #expect(after.duration == 17 && after.endedAt == before.endedAt)
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
        #expect(model.activeID == nil && !model.requiresTerminationWork)
    }

    @Test("A silent-file quit save failure preserves paused state for a later retry")
    func silentQuitSaveFailureCanRetry() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        try Data("fictional obstruction".utf8).write(to: fixture.directory)
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.captureStartedAt = clock.date
        audio.captureReadyAt = clock.date
        let model = fixture.model(service: audio, now: { clock.date })
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        clock.advance(27)
        #expect(!(await model.prepareToQuit()))
        #expect(model.activeID == id && model.isPaused && model.requiresTerminationWork)
        #expect(model.selectedSession?.duration == 27 && model.selectedSession?.segments.isEmpty == true)
        #expect(audio.cancelCount == 0)
        clock.advance(86_400)
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await model.prepareToQuit())
        let saved = try #require(SessionStore(directory: fixture.directory).load().first)
        #expect(saved.id == id && saved.duration == 27 && saved.segments.isEmpty)
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
    }

    @Test("Cancelling Resume preserves an already saved silent file")
    func cancellingSilentResumePreservesFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber(suspendStartup: true)
        let item = TranscriptSession(title: "Quiet workspace", startedAt: clock.date.addingTimeInterval(-600),
            endedAt: clock.date.addingTimeInterval(-300), sources: [.microphone], recordedDuration: 135)
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        let model = fixture.model(service: audio, now: { clock.date })
        model.sessions = [item]
        model.selectedID = item.id
        model.resumeSelectedSession()
        try await waitUntil { audio.pendingStartCount == 1 }
        clock.advance(4)
        #expect(await model.endSession())
        audio.releaseFirstStart()
        let saved = try #require(store.load().first)
        #expect(saved.id == item.id && saved.sources == item.sources && saved.segments.isEmpty)
        #expect(saved.duration == 135 && saved.startedAt == item.startedAt)
        #expect(model.selectedID == item.id && model.canResumeSelectedSession)
    }

    @Test("A failed Resume preserves an already saved silent file")
    func failedSilentResumePreservesFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let clock = TestCaptureClock()
        let audio = TestTranscriber()
        audio.failingStartAttempt = 1
        let item = TranscriptSession(title: "Quiet planning", startedAt: clock.date.addingTimeInterval(-600),
            endedAt: clock.date.addingTimeInterval(-300), sources: [.systemAudio], recordedDuration: 45)
        let store = SessionStore(directory: fixture.directory)
        try store.save(item)
        let model = fixture.model(service: audio, now: { clock.date })
        model.sessions = [item]
        model.selectedID = item.id
        model.resumeSelectedSession()
        try await waitUntil { model.activeID == nil && !model.isBusy }
        let saved = try #require(store.load().first)
        #expect(saved.id == item.id && saved.sources == item.sources && saved.segments.isEmpty)
        #expect(saved.duration == 45 && model.notice != nil && model.canResumeSelectedSession)
    }

    @Test("Cancelling a genuinely new empty startup still discards the unused attempt")
    func cancellingFreshEmptyStartupDiscardsAttempt() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber(suspendStartup: true)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { audio.pendingStartCount == 1 }
        #expect(await model.endSession())
        audio.releaseFirstStart()
        #expect(model.sessions.isEmpty && model.selectedID == nil)
        #expect(try SessionStore(directory: fixture.directory).load().isEmpty)
    }

    @Test("Quit during an in-flight silent pause preserves the file and drains only once")
    func quittingDuringSilentPausePreservesFile() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        audio.stopDelay = .milliseconds(40)
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        let id = try #require(model.activeID)
        let pause = Task { await model.pauseSession() }
        try await waitUntil { model.isSelectedPausing }
        #expect(await model.prepareToQuit())
        #expect(await pause.value)
        #expect(try SessionStore(directory: fixture.directory).load().first?.id == id)
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
        #expect(model.activeID == nil && !model.requiresTerminationWork)
    }

    @Test("Quitting a paused transcript releases cached capture resources after saving")
    func quittingReleasesPausedResourcesAfterSave() async throws {
        let fixture = try LifecycleFixture()
        defer { fixture.cleanUp() }
        let audio = TestTranscriber()
        let model = fixture.model(service: audio)
        model.toggleRecording()
        try await waitUntil { model.isSelectedRecording }
        audio.emit(TranscriptUpdate(segmentID: UUID(), source: .microphone,
            text: "Save this paused transcript.", isFinal: true, timestamp: 0))
        #expect(await model.pauseSession())
        #expect(audio.cancelCount == 0)
        #expect(await model.prepareToQuit())
        #expect(audio.stopCount == 1 && audio.cancelCount == 1)
        #expect(model.activeID == nil && !model.requiresTerminationWork)
        #expect(try SessionStore(directory: fixture.directory).load().first?.segments.first?.text == "Save this paused transcript.")
    }

    private func elapsed(_ model: RelayModel, at date: Date) throws -> TimeInterval {
        model.duration(for: try #require(model.selectedSession), at: date)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The expected lifecycle state did not arrive.")
        throw LifecycleTestError.timedOut
    }
}

@MainActor
private final class TestTranscriber: RelayTranscribing {
    var reducesSpeakerEcho = true
    var state: TranscriptionService.CaptureState = .idle
    var level: Double = 0
    var statusMessage: String?
    var isRunning: Bool { state == .running }
    var onUpdate: ((TranscriptUpdate) -> Void)?
    var captureStartedAt: Date?
    var captureReadyAt: Date?
    private(set) var requestedSources: Set<TranscriptSource> = []
    private(set) var requestedLocale: String?
    var finalUpdateOnStop: TranscriptUpdate?
    var stopDelay: Duration = .zero
    private(set) var stopCount = 0
    private(set) var cancelCount = 0
    private(set) var startCount = 0
    private(set) var autoStartCount = 0
    var failingStartAttempt: Int?
    private let suspendStartup: Bool
    private var token = UUID()
    private var starts: [CheckedContinuation<Void, any Error>] = []
    var pendingStartCount: Int { starts.count }

    init(suspendStartup: Bool = false) { self.suspendStartup = suspendStartup }

    func start(sources: Set<TranscriptSource>, locale: Locale) async throws {
        startCount += 1
        requestedSources = sources
        requestedLocale = locale.identifier
        let generation = UUID()
        token = generation
        state = .preparing
        if failingStartAttempt == startCount {
            state = .failed("Fictional startup failure")
            throw LifecycleTestError.startupFailed
        }
        if suspendStartup {
            try await withCheckedThrowingContinuation { continuation in starts.append(continuation) }
        }
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        state = .running
    }

    func startAuto(sources: Set<TranscriptSource>) async throws {
        autoStartCount += 1
        try await start(sources: sources, locale: Locale(identifier: "en-US"))
    }

    func stop() async {
        stopCount += 1
        state = .stopping
        if stopDelay != .zero { try? await Task.sleep(for: stopDelay) }
        if let finalUpdateOnStop { onUpdate?(finalUpdateOnStop) }
        state = .idle
    }

    func cancel() {
        cancelCount += 1
        token = UUID()
        state = .idle
    }

    func releaseFirstStart() { starts.removeFirst().resume() }
    func emit(_ update: TranscriptUpdate) { onUpdate?(update) }
}

@MainActor
private struct LifecycleFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Relay-LifecycleTests-" + UUID().uuidString)
    let suiteName = "Relay-LifecycleTests-" + UUID().uuidString
    let defaults: UserDefaults

    init() throws { defaults = try #require(UserDefaults(suiteName: suiteName)) }

    func model(service: any RelayTranscribing, permissions: RelayPermissions = .testing(),
               now: @escaping @MainActor () -> Date = { Date() }) -> RelayModel {
        RelayModel(directory: directory, defaults: defaults, automaticallyLoad: false,
                   service: service, permissions: permissions, now: now)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func session() -> TranscriptSession {
        TranscriptSession(title: "Fictional session", startedAt: Date(timeIntervalSince1970: 1_790_000_000),
                          endedAt: Date(timeIntervalSince1970: 1_790_000_010),
                          segments: [TranscriptSegment(source: .microphone, text: "Fictional transcript.", timestamp: 1)])
    }
}

@MainActor
private final class TestCaptureClock {
    var date = Date(timeIntervalSince1970: 1_790_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

private enum LifecycleTestError: Error { case timedOut, startupFailed }
