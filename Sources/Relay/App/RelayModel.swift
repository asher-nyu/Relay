import AppKit
import Observation
import Speech
import UniformTypeIdentifiers

@MainActor
protocol RelayTranscribing: AnyObject {
    var state: TranscriptionService.CaptureState { get }
    var level: Double { get }
    var statusMessage: String? { get }
    var isRunning: Bool { get }
    /// Raw audio timestamp epoch, which may precede source preparation.
    var captureStartedAt: Date? { get }
    /// The point at which all requested sources are ready for transcription.
    var captureReadyAt: Date? { get }
    var reducesSpeakerEcho: Bool { get set }
    var onUpdate: ((TranscriptUpdate) -> Void)? { get set }
    func start(sources: Set<TranscriptSource>, locale: Locale) async throws
    func startAuto(sources: Set<TranscriptSource>) async throws
    func stop() async
    func cancel()
}

extension RelayTranscribing {
    var captureStartedAt: Date? { nil }
    var captureReadyAt: Date? { nil }
}

extension TranscriptionService: RelayTranscribing { }

struct RelayNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct NewSessionPrompt: Identifiable, Equatable {
    let id = UUID()
    let activeID: UUID
    let title: String
    let isPaused: Bool
}

struct ResumeSessionPrompt: Identifiable, Equatable {
    let id = UUID()
    let activeID: UUID
    let targetID: UUID
    let activeTitle: String
    let targetTitle: String
}

@MainActor @Observable
final class RelayModel {
    var sessions: [TranscriptSession] = []
    var selectedID: UUID? {
        didSet {
            if let request = resumeSessionPrompt, selectedID != request.targetID {
                resumeSessionPrompt = nil
            }
        }
    }
    private(set) var activeID: UUID?
    private(set) var isLoaded = false
    private(set) var storageDescription = "Preparing storage…"
    private(set) var storageFolderURL: URL?
    private(set) var pendingWrites = 0
    private(set) var isQuitting = false
    private(set) var isChangingSources = false
    private(set) var isConfirmingNewSession = false
    private(set) var isDeletingTranscript = false
    var newSessionPrompt: NewSessionPrompt?
    var resumeSessionPrompt: ResumeSessionPrompt?
    var sources: Set<TranscriptSource> = [.systemAudio, .microphone]
    var supportedLanguages: [Locale] = [Locale(identifier: "en-US")]
    var notice: RelayNotice?
    var toast: String?
    var search = ""
    /// Remembered only for the next new conversation. Existing files carry
    /// their own language and never read this preference when resuming.
    var defaultLanguageID: String {
        didSet {
            let candidate = Self.canonicalLanguageID(defaultLanguageID)
            let canonical = TranscriptLanguage.isValid(candidate) ? candidate : TranscriptLanguage.defaultID
            if defaultLanguageID != canonical { defaultLanguageID = canonical }
            defaults.set(canonical, forKey: "transcriptionLanguage")
        }
    }
    let autoCopySelection = true
    let reducesSpeakerEcho = true
    let permissions: RelayPermissions
    let service: any RelayTranscribing

    private enum Phase { case idle, starting, recording, pausing, paused, ending }
    private var phase: Phase = .idle
    @ObservationIgnored private var library: SessionLibrary?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var transcript = SessionTranscript()
    @ObservationIgnored private var sessionToken = UUID()
    @ObservationIgnored private var captureTimestampOffset: TimeInterval = 0
    @ObservationIgnored private var capturePreparationOffset: TimeInterval = 0
    @ObservationIgnored private var captureReadyAt: Date?
    @ObservationIgnored private var captureStoppedAt: Date?
    @ObservationIgnored private var preparingUpdates: [TranscriptUpdate] = []
    @ObservationIgnored private var preservesEmptySession = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var sessionRevisions: [UUID: UInt64] = [:]
    @ObservationIgnored private var dirtyIDs: Set<UUID> = []
    @ObservationIgnored private var deletingIDs: Set<UUID> = []
    @ObservationIgnored private var requestedDeletionIDs: Set<UUID> = []
    @ObservationIgnored private var deletionTask: Task<Void, Never>?
    @ObservationIgnored private var deletionTaskToken = UUID()
    @ObservationIgnored private var renamingIDs: Set<UUID> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
    @ObservationIgnored private var endingTask: Task<Bool, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var sourceUpdateTask: Task<Bool, Never>?
    @ObservationIgnored private var serviceFailureToken: UUID?
    @ObservationIgnored private var permissionRevocationToken: UUID?

    init(
        directory: URL? = nil,
        defaults: UserDefaults = .standard,
        automaticallyLoad: Bool = true,
        service: (any RelayTranscribing)? = nil,
        permissions: RelayPermissions? = nil,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        #if DEBUG
        let isTesting = ProcessInfo.processInfo.environment["RELAY_UI_TESTING"] == "1"
        let preferences = isTesting && defaults === UserDefaults.standard
            ? (UserDefaults(suiteName: "com.asherbloom.Relay.UITests.\(ProcessInfo.processInfo.processIdentifier)") ?? defaults)
            : defaults
        #else
        let preferences = defaults
        #endif
        self.defaults = preferences
        self.now = now
        #if DEBUG
        if let permissions {
            self.permissions = permissions
        } else if isTesting {
            switch ProcessInfo.processInfo.environment["RELAY_PERMISSIONS_FIXTURE"] {
            case "missing": self.permissions = .testing(microphone: .notDetermined, systemAudio: false)
            case "denied": self.permissions = .testing(microphone: .denied, systemAudio: false)
            default: self.permissions = .testing()
            }
        } else {
            self.permissions = RelayPermissions()
        }
        let fixtureState = isTesting && ProcessInfo.processInfo.environment["RELAY_FIXTURE"] == "1"
            ? ProcessInfo.processInfo.environment["RELAY_FIXTURE_STATE"] : nil
        self.service = service ?? ((fixtureState == "recording" || fixtureState == "paused")
            ? RelayFixtureTranscriber() : TranscriptionService())
        #else
        self.permissions = permissions ?? RelayPermissions()
        self.service = service ?? TranscriptionService()
        #endif
        preferences.register(defaults: ["transcriptionLanguage": TranscriptLanguage.defaultID])
        let preferredLanguage = Self.canonicalLanguageID(preferences.string(forKey: "transcriptionLanguage") ?? TranscriptLanguage.defaultID)
        defaultLanguageID = TranscriptLanguage.isValid(preferredLanguage) ? preferredLanguage : TranscriptLanguage.defaultID
        self.service.reducesSpeakerEcho = true
        #if DEBUG
        let libraryDirectory = directory ?? (isTesting ? FileManager.default.temporaryDirectory
            .appendingPathComponent("RelayUITests-\(ProcessInfo.processInfo.processIdentifier)") : nil)
        #else
        let libraryDirectory = directory
        #endif
        if let libraryDirectory {
            library = SessionLibrary(directory: libraryDirectory)
            storageFolderURL = libraryDirectory
            storageDescription = "On My Mac"
        } else if !automaticallyLoad {
            library = SessionLibrary(directory: RelayStorageLocation.localDirectory,
                                     bookmarksURL: RelayStorageLocation.bookmarksURL, trashOnDelete: true)
            storageFolderURL = RelayStorageLocation.localDirectory
            storageDescription = "On My Mac"
        }
        if automaticallyLoad { Task { await load() } }
        else { isLoaded = true }
    }

    var selectedSession: TranscriptSession? { sessions.first { $0.id == selectedID } }
    var selectedLanguageID: String? { selectedSession?.languageID }
    /// Capture and drain work is global; toolbar actions belong to the selected
    /// document. A paused document retains ownership without keeping hardware on.
    var isBusy: Bool { (phase != .idle && phase != .paused) || endingTask != nil }
    var isPreparing: Bool { phase == .starting }
    var isPausing: Bool { phase == .pausing }
    var isPaused: Bool { phase == .paused && activeID != nil }
    var isStopping: Bool { phase == .pausing || phase == .ending || endingTask != nil }
    var isSelectedPreparing: Bool { selectedID == activeID && activeID != nil && isPreparing }
    var isSelectedPausing: Bool { selectedID == activeID && activeID != nil && isPausing }
    var isSelectedPaused: Bool { selectedID == activeID && activeID != nil && isPaused }
    var isSelectedRecording: Bool { selectedID == activeID && activeID != nil && phase == .recording }
    var isSelectedStopping: Bool { selectedID == activeID && activeID != nil && isStopping }
    var canStartNewSession: Bool {
        permissions.canCreateConversation && isLoaded && library != nil && !isQuitting && !isDeletingTranscript && !isChangingSources && !isConfirmingNewSession && activeID == nil && !isBusy
    }
    var canRequestNewSession: Bool {
        permissions.canCreateConversation && isLoaded && library != nil && !isQuitting && !isDeletingTranscript && !isChangingSources && !isConfirmingNewSession &&
            resumeSessionPrompt == nil && !isStopping && !isPreparing
    }
    var canEditSelectedSources: Bool {
        guard let selectedID, selectedSession != nil else { return false }
        return isLoaded && library != nil && !isQuitting && !isDeletingTranscript && !isChangingSources && !isConfirmingNewSession &&
            resumeSessionPrompt == nil && !isStopping && !isPreparing && !deletingIDs.contains(selectedID) && !renamingIDs.contains(selectedID)
    }
    var canEditSelectedLanguage: Bool { canEditSelectedSources }
    var canPauseSelectedSession: Bool {
        !isQuitting && !isDeletingTranscript && !isChangingSources && !isConfirmingNewSession && selectedID == activeID && activeID != nil && (phase == .starting || phase == .recording)
    }
    var canResumeSelectedSession: Bool {
        guard permissions.canCreateConversation, isLoaded, library != nil, !isQuitting, !isDeletingTranscript, !isStopping, !isPreparing,
              !isChangingSources, !isConfirmingNewSession, newSessionPrompt == nil,
              let selected = selectedSession, !selected.sources.isEmpty,
              !deletingIDs.contains(selected.id), !renamingIDs.contains(selected.id) else { return false }
        return activeID == nil || isPaused || (phase == .recording && activeID != selected.id)
    }
    var canEndSelectedSession: Bool {
        !isQuitting && !isDeletingTranscript && !isChangingSources && !isConfirmingNewSession && selectedID == activeID && activeID != nil && !isStopping
    }
    var canToggleRecording: Bool {
        canPauseSelectedSession || canResumeSelectedSession || (selectedSession == nil && canStartNewSession && !sources.isEmpty)
    }
    var canExport: Bool {
        guard let session = selectedSession else { return false }
        return session.endedAt != nil && !session.segments.isEmpty
    }
    var isShowingLive: Bool {
        activeID != nil && selectedID == activeID && phase != .paused && phase != .idle
    }

    /// A document's creation date is independent of its capture duration.
    /// Preparation, pauses, and recognition drain never advance this clock.
    func duration(for session: TranscriptSession, at date: Date) -> TimeInterval {
        guard session.id == activeID, phase == .recording, let captureReadyAt else {
            return session.duration
        }
        return captureTimestampOffset + max(0, date.timeIntervalSince(captureReadyAt))
    }
    var requiresTerminationWork: Bool {
        isBusy || isDeletingTranscript || isChangingSources || isConfirmingNewSession || endingTask != nil || pendingWrites > 0 || !dirtyIDs.isEmpty || !deletingIDs.isEmpty || !renamingIDs.isEmpty
    }
    var filteredSessions: [TranscriptSession] {
        guard !search.isEmpty else { return sessions }
        return sessions.filter {
            $0.displayTitle.localizedStandardContains(search) ||
            $0.segments.contains { $0.text.localizedStandardContains(search) }
        }
    }

    private func prepareLibrary() async throws -> SessionLibrary {
        if let library {
            await library.setChangeHandler { [weak self] event in self?.handleLibraryEvent(event) }
            return library
        }
        let location = try await RelayStorageLocation.resolve()
        let created = SessionLibrary(directory: location.directory,
                                     bookmarksURL: RelayStorageLocation.bookmarksURL, trashOnDelete: true)
        library = created
        storageFolderURL = location.directory
        storageDescription = location.description
        await created.setChangeHandler { [weak self] event in self?.handleLibraryEvent(event) }
        return created
    }

    private func load() async {
        do {
            let library = try await prepareLibrary()
            let result = try await library.load()
            sessions = result.sessions.map { session in
                var copy = session
                if copy.endedAt == nil {
                    let confirmedEnd = copy.segments.lazy.filter { $0.isFinal && $0.timingIsConfirmed }
                        .map(\.timestamp).max() ?? 0
                    let duration = max(copy.recordedDuration ?? 0, confirmedEnd)
                    copy.recordedDuration = duration
                    copy.endedAt = copy.startedAt.addingTimeInterval(duration)
                    for index in copy.segments.indices { copy.segments[index].isFinal = true }
                    markDirty(copy.id)
                }
                copy.segments = TranscriptFormatting.ordered(copy.segments)
                return copy
            }
            if !result.issues.isEmpty {
                notice = RelayNotice(title: "Some transcripts couldn’t be opened", message:
                    result.issues.map(\.message).joined(separator: "\n\n"))
            }
            // Persist interrupted-session recovery instead of reinterpreting it
            // as an active recording on every later launch.
            _ = await flushPendingWrites()
            #if DEBUG
            // Fixtures require the isolated UI-testing library as well as the
            // fixture setting; a screenshot launch can never replace real history.
            if ProcessInfo.processInfo.environment["RELAY_UI_TESTING"] == "1",
               ProcessInfo.processInfo.environment["RELAY_FIXTURE"] == "1" {
                let fixture = Self.uiFixtureSession()
                sessions = [fixture]
                if ProcessInfo.processInfo.environment["RELAY_FIXTURE_HISTORY"] == "1" {
                    let history = TranscriptSession(title: "Project Notes",
                        startedAt: fixture.startedAt.addingTimeInterval(-300),
                        endedAt: fixture.startedAt.addingTimeInterval(-240),
                        segments: [TranscriptSegment(source: .microphone,
                            text: "The next review is scheduled for Friday.", timestamp: 3)],
                        sources: [.microphone], recordedDuration: 60)
                    sessions.append(history)
                    markDirty(fixture.id)
                    markDirty(history.id)
                    _ = await flushPendingWrites()
                }
                selectedID = fixture.id
                let fixtureState = ProcessInfo.processInfo.environment["RELAY_FIXTURE_STATE"]
                if fixtureState == "recording" {
                    startCapture(in: fixture, resuming: true)
                } else if fixtureState == "paused" {
                    transcript = SessionTranscript(segments: fixture.segments)
                    activeID = fixture.id
                    phase = .paused
                }
            }
            #endif
        } catch { present(error, title: "Transcripts couldn’t be opened") }
        isLoaded = true
        let languages = await SpeechTranscriber.supportedLocales
        supportedLanguages = (languages.isEmpty ? [Locale(identifier: "en-US")] : languages).sorted {
            languageName($0.identifier).localizedStandardCompare(languageName($1.identifier)) == .orderedAscending
        }
        let languageIDs = Set(supportedLanguages.map { Self.canonicalLanguageID($0.identifier) })
        if defaultLanguageID != "auto", !languageIDs.contains(defaultLanguageID) {
            defaultLanguageID = languageIDs.contains("en-US") ? "en-US"
                : Self.canonicalLanguageID(supportedLanguages[0].identifier)
        }
    }

    #if DEBUG
    static func uiFixtureSession(at now: Date = Date()) -> TranscriptSession {
        // Capture one clock value: evaluating endedAt before the initializer's
        // default startedAt made the completed fixture fail real file validation.
        TranscriptSession(title: "Design Review", startedAt: now.addingTimeInterval(-120), endedAt: now, segments: [
            TranscriptSegment(source: .systemAudio, text: "The clearest ideas are often the ones we can explain simply. Let’s keep the next review focused on the experience.", timestamp: 0),
            TranscriptSegment(source: .microphone, text: "Agreed. We can share the revised prototype on Thursday, then leave time for everyone to try it.", timestamp: 12),
            TranscriptSegment(source: .systemAudio, text: "That gives us a useful starting point. I’ll bring the updated notes to the review.", timestamp: 24)
        ])
    }
    #endif

    private static func canonicalLanguageID(_ value: String) -> String {
        TranscriptLanguage.canonicalID(value)
    }

    func languageName(_ identifier: String) -> String {
        if identifier == "auto" { return "Auto Detect" }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    func toggleSource(_ source: TranscriptSource) {
        guard !isBusy, !isQuitting, !isChangingSources, !isConfirmingNewSession else { return }
        if sources.contains(source) { sources.remove(source) } else { sources.insert(source) }
    }

    func newSession() {
        permissions.refresh()
        guard canRequestNewSession else { return }
        guard let activeID else {
            newSessionPrompt = nil
            selectedID = nil
            return
        }
        guard let active = sessions.first(where: { $0.id == activeID }) else { return }
        if isPaused {
            let selection = selectedID
            isConfirmingNewSession = true
            newSessionPrompt = nil
            Task { [self] in
                defer { isConfirmingNewSession = false }
                guard await releasePausedSession(activeID), !isQuitting, selectedID == selection else { return }
                selectedID = nil
            }
        } else {
            newSessionPrompt = NewSessionPrompt(activeID: activeID, title: active.displayTitle, isPaused: false)
        }
    }

    func cancelNewSessionRequest() { newSessionPrompt = nil }

    @discardableResult
    func confirmNewSessionRequest(_ expectedPromptID: UUID? = nil) async -> Bool {
        permissions.refresh()
        guard let request = newSessionPrompt, canRequestNewSession else { return false }
        // The native alert captures its request identity. An old action must
        // never authorize a replacement alert for another file or request.
        guard expectedPromptID == nil || expectedPromptID == request.id else { return false }
        guard activeID == request.activeID else {
            newSessionPrompt = nil
            return false
        }
        isConfirmingNewSession = true
        newSessionPrompt = nil
        defer { isConfirmingNewSession = false }
        let selection = selectedID
        guard await stopCapture(pausing: true), !isQuitting, selectedID == selection,
              await releasePausedSession(request.activeID), !isQuitting, selectedID == selection else { return false }
        selectedID = nil
        return true
    }

    /// A paused file releases ownership only after all pending writes succeed.
    /// Switching documents must never strand unsaved content behind a new capture.
    private func releasePausedSession(_ id: UUID) async -> Bool {
        guard !isQuitting, activeID == id, isPaused else { return false }
        let token = sessionToken
        guard await flushPendingWrites(waitForDeletions: false), !isQuitting, activeID == id,
              isPaused, sessionToken == token else { return false }
        sessionToken = UUID()
        service.onUpdate = nil
        activeID = nil
        phase = .idle
        return true
    }

    /// Source choices belong to the selected file. A running capture is drained
    /// before its metadata changes; it restarts only after that file saves.
    /// The unstructured transaction survives cancellation of its UI caller.
    @discardableResult
    func updateSelectedSources(_ requested: Set<TranscriptSource>) async -> Bool {
        guard canEditSelectedSources, let id = selectedID,
              let selected = selectedSession else { return false }
        guard !requested.isEmpty else {
            notice = RelayNotice(title: "Choose an audio source",
                message: "Keep System audio or Microphone selected for this transcript.")
            return false
        }
        if selected.sources == requested, !dirtyIDs.contains(id) { return true }
        isChangingSources = true
        let task = Task { [self] in await applyConfiguration(to: id, sources: requested) }
        sourceUpdateTask = task
        let saved = await task.value
        sourceUpdateTask = nil
        isChangingSources = false
        return saved
    }

    @discardableResult
    func updateSelectedLanguage(_ requested: String) async -> Bool {
        guard canEditSelectedLanguage, let id = selectedID,
              let selected = selectedSession else { return false }
        let canonical = Self.canonicalLanguageID(requested)
        guard TranscriptLanguage.isValid(canonical) else {
            notice = RelayNotice(title: "Choose a transcription language",
                message: "Choose a supported language or Auto Detect for this conversation.")
            return false
        }
        if selected.languageID == canonical, !dirtyIDs.contains(id) { return true }
        // Language and audio-source changes share one transaction lock so two
        // controls cannot drain or restart the same capture concurrently.
        isChangingSources = true
        let task = Task { [self] in await applyConfiguration(to: id, languageID: canonical) }
        sourceUpdateTask = task
        let saved = await task.value
        sourceUpdateTask = nil
        isChangingSources = false
        return saved
    }

    private func applyConfiguration(to id: UUID, sources: Set<TranscriptSource>? = nil,
                                    languageID: String? = nil) async -> Bool {
        let shouldRestart = activeID == id && phase == .recording
        if shouldRestart {
            guard await stopCapture(pausing: true) else { return false }
            guard activeID == id, isPaused, !isQuitting else { return false }
        }
        guard !isQuitting, !deletingIDs.contains(id),
              let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        if let sources { sessions[index].sources = sources }
        if let languageID { sessions[index].languageID = languageID }
        markDirty(id)
        // Saving another history item's configuration must not flush or pause
        // the independently running document's debounce or capture lifecycle.
        guard await saveCurrent(id) else { return false }
        guard !dirtyIDs.contains(id), !isQuitting,
              let saved = sessions.first(where: { $0.id == id }) else { return false }
        if shouldRestart {
            guard activeID == id, isPaused else { return false }
            startCapture(in: saved, resuming: true, selectSession: selectedID == id)
        }
        return true
    }

    /// The primary control acts on the selected transcript. Switching from a
    /// recording document requires explicit confirmation before capture pauses.
    func toggleRecording() {
        permissions.refresh()
        guard canToggleRecording else { return }
        if canPauseSelectedSession {
            Task { _ = await pauseSession() }
        } else if selectedSession != nil {
            resumeSelectedSession()
        } else {
            beginSession()
        }
    }

    func resumeSelectedSession() {
        permissions.refresh()
        guard canResumeSelectedSession, let session = selectedSession else { return }
        if let previous = activeID, previous != session.id {
            if phase == .recording, let active = sessions.first(where: { $0.id == previous }) {
                resumeSessionPrompt = ResumeSessionPrompt(activeID: previous, targetID: session.id,
                    activeTitle: active.displayTitle, targetTitle: session.displayTitle)
                return
            }
            isConfirmingNewSession = true
            Task { [self] in
                defer { isConfirmingNewSession = false }
                guard await releasePausedSession(previous), !isQuitting, selectedID == session.id,
                      let latest = sessions.first(where: { $0.id == session.id }) else { return }
                startCapture(in: latest, resuming: true)
            }
            return
        }
        startCapture(in: session, resuming: true)
    }

    func cancelResumeSessionRequest(_ expectedPromptID: UUID? = nil) {
        guard expectedPromptID == nil || resumeSessionPrompt?.id == expectedPromptID else { return }
        resumeSessionPrompt = nil
    }

    @discardableResult
    func confirmResumeSessionRequest(_ expectedPromptID: UUID? = nil) async -> Bool {
        permissions.refresh()
        guard let request = resumeSessionPrompt,
              expectedPromptID == nil || request.id == expectedPromptID else { return false }
        guard canResumeSelectedSession, activeID == request.activeID,
              selectedID == request.targetID, phase == .recording,
              sessions.contains(where: { $0.id == request.activeID }) else {
            resumeSessionPrompt = nil
            return false
        }
        // Lock the handoff before any suspension. A second action cannot pause
        // twice or begin a different file before the current transcript saves.
        isConfirmingNewSession = true
        resumeSessionPrompt = nil
        defer { isConfirmingNewSession = false }
        guard await stopCapture(pausing: true), !isQuitting,
              selectedID == request.targetID, activeID == request.activeID,
              await releasePausedSession(request.activeID), !isQuitting,
              selectedID == request.targetID,
              !deletingIDs.contains(request.targetID), !renamingIDs.contains(request.targetID),
              let latest = sessions.first(where: { $0.id == request.targetID }),
              !latest.sources.isEmpty else { return false }
        startCapture(in: latest, resuming: true)
        return activeID == latest.id
    }

    private func beginSession() {
        permissions.refresh()
        guard canStartNewSession, !sources.isEmpty else { return }
        let session = TranscriptSession(startedAt: now(), sources: sources,
                                        languageID: defaultLanguageID, recordedDuration: 0)
        sessions.insert(session, at: 0)
        selectedID = session.id
        startCapture(in: session, resuming: false)
    }

    private func startCapture(in session: TranscriptSession, resuming: Bool, selectSession: Bool = true) {
        permissions.refresh()
        guard permissions.canCreateConversation, !session.sources.isEmpty, !isBusy, !isDeletingTranscript,
              !requestedDeletionIDs.contains(session.id), !deletingIDs.contains(session.id),
              activeID == nil || activeID == session.id && isPaused,
              let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        resumeSessionPrompt = nil
        transcript = SessionTranscript(segments: session.segments)
        transcript.finalize()
        sessions[index].segments = transcript.segments
        let confirmedEnd = session.segments.lazy.filter { $0.isFinal && $0.timingIsConfirmed }
            .map(\.timestamp).max() ?? 0
        captureTimestampOffset = resuming ? max(session.duration, confirmedEnd) : 0
        capturePreparationOffset = 0
        captureReadyAt = nil
        captureStoppedAt = nil
        preparingUpdates.removeAll()
        preservesEmptySession = resuming
        let token = UUID()
        sessionToken = token
        activeID = session.id
        if selectSession { selectedID = session.id }
        sessions[index].recordedDuration = captureTimestampOffset
        sessions[index].endedAt = nil
        // Set the lifecycle state before creating the task, so a rapid second
        // click cannot start a second session before the first task runs.
        phase = .starting
        let requestedSources = session.sources
        let requestedLanguage = session.languageID
        service.reducesSpeakerEcho = true
        service.onUpdate = { [weak self] update in
            guard let self, self.sessionToken == token, self.activeID == session.id else { return }
            self.receive(update)
        }
        recordingTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.sessionToken == token,
                  self.activeID == session.id, self.phase == .starting,
                  !self.requestedDeletionIDs.contains(session.id) else { return }
            self.permissions.refresh()
            guard self.permissions.canCreateConversation else {
                _ = await self.stopCapture(pausing: false)
                return
            }
            do {
                if requestedLanguage == "auto" {
                    try await service.startAuto(sources: requestedSources)
                } else {
                    try await service.start(sources: requestedSources, locale: Locale(identifier: requestedLanguage))
                }
                guard sessionToken == token, activeID == session.id, phase == .starting else { return }
                let readyAt = service.captureReadyAt ?? now()
                captureReadyAt = readyAt
                capturePreparationOffset = service.captureStartedAt.map {
                    max(0, readyAt.timeIntervalSince($0))
                } ?? 0
                phase = .recording
                applyPreparingUpdates()
            } catch is CancellationError {
                guard sessionToken == token, activeID == session.id else { return }
                _ = await stopCapture(pausing: false)
            } catch {
                guard sessionToken == token, activeID == session.id else { return }
                present(error, title: "Transcription couldn’t start")
                _ = await stopCapture(pausing: false)
            }
        }
    }

    /// Pausing releases capture hardware and drains final recognition results.
    /// The document stays selected and can continue with the same identifier.
    @discardableResult
    func pauseSession() async -> Bool {
        guard !isDeletingTranscript, !isChangingSources, !isConfirmingNewSession else { return false }
        return await stopCapture(pausing: true)
    }

    /// Ending completes the selected active document. Its saved history remains
    /// resumable, while a different transcript may now be started or resumed.
    @discardableResult
    func endSession() async -> Bool {
        guard !isDeletingTranscript, !isChangingSources, !isConfirmingNewSession else { return false }
        return await stopCapture(pausing: false)
    }

    private func stopCapture(pausing: Bool, expectedID: UUID? = nil,
                             expectedToken: UUID? = nil) async -> Bool {
        if let expectedID {
            guard activeID == expectedID, sessionToken == expectedToken else { return false }
        }
        resumeSessionPrompt = nil
        if let endingTask {
            let saved = await endingTask.value
            // End requested during a pause must complete the paused document,
            // rather than silently leave it owning the recording controls.
            if !pausing, activeID != nil {
                while self.endingTask != nil { await Task.yield() }
                return await stopCapture(pausing: false, expectedID: expectedID, expectedToken: expectedToken)
            }
            return saved
        }
        guard let id = activeID else { return await flushPendingWrites(waitForDeletions: false) }
        if pausing, phase == .paused { return await flushPendingWrites(waitForDeletions: false) }
        let wasPreparing = phase == .starting
        let wasPaused = phase == .paused
        if !wasPaused, let index = sessions.firstIndex(where: { $0.id == id }) {
            let stoppedAt = now()
            sessions[index].recordedDuration = duration(for: sessions[index], at: stoppedAt)
            captureStoppedAt = stoppedAt
        }
        phase = pausing ? .pausing : .ending
        let task = Task { [self] in
            if wasPreparing {
                recordingTask?.cancel()
                sessionToken = UUID()
                service.cancel()
            } else if !wasPaused {
                await service.stop()
                sessionToken = UUID()
            }
            return await finalizeSession(id, pausing: pausing, wasPaused: wasPaused)
        }
        endingTask = task
        let saved = await task.value
        endingTask = nil
        recordingTask = nil
        phase = pausing && activeID == id ? .paused : .idle
        return saved
    }

    private func finalizeSession(_ id: UUID, pausing: Bool, wasPaused: Bool) async -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard activeID == id, let index = sessions.firstIndex(where: { $0.id == id }) else {
            return await flushPendingWrites(waitForDeletions: false)
        }
        // A setup cancellation can still have recognized opening speech. Keep
        // those words at the frozen timeline boundary instead of discarding them.
        applyPreparingUpdates()
        transcript.finalize()
        sessions[index].segments = transcript.segments
        if !wasPaused { sessions[index].endedAt = captureStoppedAt ?? now() }
        if pausing { preservesEmptySession = true }
        service.onUpdate = nil
        if !pausing {
            activeID = nil
            if newSessionPrompt?.activeID == id { newSessionPrompt = nil }
        }
        if transcript.isEmpty && !pausing && !preservesEmptySession {
            // Discard only a new, unsaved empty attempt. A saved file retains
            // its identity, configuration, and duration even without speech.
            // Revision guards prevent queued writes from recreating a discard.
            revision += 1
            let deleteRevision = revision
            sessionRevisions[id] = deleteRevision
            deletingIDs.insert(id)
            pendingWrites += 1
            do {
                _ = try await library?.delete(id, revision: deleteRevision)
                sessions.removeAll { $0.id == id }
                dirtyIDs.remove(id)
                sessionRevisions.removeValue(forKey: id)
                if selectedID == id { selectedID = nil }
            } catch {
                markDirty(id)
                present(error, title: "Transcript couldn’t be saved")
                pendingWrites -= 1
                deletingIDs.remove(id)
                return false
            }
            pendingWrites -= 1
            deletingIDs.remove(id)
        } else {
            markDirty(id)
        }
        return await flushPendingWrites(waitForDeletions: false)
    }

    private func receive(_ update: TranscriptUpdate) {
        guard update.timestamp.isFinite, update.timestamp >= 0,
              activeID != nil, phase != .paused else { return }
        if phase == .starting {
            preparingUpdates.append(update)
            return
        }
        apply(update)
    }

    private func applyPreparingUpdates() {
        let updates = preparingUpdates
        preparingUpdates.removeAll()
        for update in updates { apply(update, capturedBeforeReady: captureReadyAt == nil) }
    }

    private func apply(_ update: TranscriptUpdate, capturedBeforeReady: Bool = false) {
        guard let id = activeID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Every fresh recognizer appends to actual captured duration. Its raw
        // setup interval and the wall-clock gap between captures are excluded.
        let localTimestamp = capturedBeforeReady ? 0 : max(0, update.timestamp - capturePreparationOffset)
        let positioned = TranscriptUpdate(segmentID: update.segmentID, source: update.source,
            text: update.text, isFinal: update.isFinal, timestamp: captureTimestampOffset + localTimestamp,
            timingIsConfirmed: update.timingIsConfirmed)
        guard transcript.apply(positioned) else { return }
        sessions[index].segments = transcript.segments
        markDirty(id)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(650))
                try Task.checkCancellation()
                guard let self, activeID == id, !deletingIDs.contains(id) else { return }
                // Snapshot at commit time, not before the debounce. A title
                // edited while listening must survive the next autosave.
                _ = await saveCurrent(id)
            } catch is CancellationError { }
            catch { }
        }
    }

    func handleServiceFailure() {
        guard case .failed(let message) = service.state, let id = activeID, phase != .ending,
              serviceFailureToken != sessionToken else { return }
        let token = sessionToken
        serviceFailureToken = token
        notice = RelayNotice(title: "Transcription stopped", message: message)
        Task { [weak self] in
            guard let self else { return }
            // A different file's deletion must not swallow a one-shot failure
            // event. Wait for transitions without applying an old failure to a
            // new capture that acquired the shared service in the meantime.
            while isDeletingTranscript || isChangingSources || isConfirmingNewSession {
                guard activeID == id, sessionToken == token, !isQuitting else { return }
                await Task.yield()
            }
            guard activeID == id, sessionToken == token, !isQuitting,
                  case .failed = service.state else { return }
            _ = await stopCapture(pausing: false, expectedID: id, expectedToken: token)
        }
    }

    /// The onboarding view replaces the capture controls when access changes.
    /// Pause the owned capture as well, so a remaining authorized source cannot
    /// continue recording behind that view. In-flight file operations retain
    /// their save guarantees; an old revocation cannot pause a later capture.
    func handlePermissionRevocation() {
        permissions.refresh()
        guard !permissions.isReady, !isQuitting, let id = activeID,
              phase == .starting || phase == .recording,
              permissionRevocationToken != sessionToken else { return }
        let token = sessionToken
        permissionRevocationToken = token
        newSessionPrompt = nil
        resumeSessionPrompt = nil
        Task { [weak self] in
            guard let self else { return }
            defer {
                if permissionRevocationToken == token { permissionRevocationToken = nil }
            }
            while isDeletingTranscript || isChangingSources || isConfirmingNewSession {
                guard activeID == id, sessionToken == token, !isQuitting else { return }
                await Task.yield()
            }
            permissions.refresh()
            guard activeID == id, sessionToken == token, !isQuitting,
                  !permissions.isReady else { return }
            _ = await stopCapture(pausing: true, expectedID: id, expectedToken: token)
        }
    }

    /// Drains in-flight writes first, then saves the latest dirty snapshots. A
    /// failed save keeps both the in-memory transcript and its dirty marker.
    @discardableResult
    func flushPendingWrites(waitForDeletions: Bool = true) async -> Bool {
        if waitForDeletions {
            while let deletionTask { await deletionTask.value }
        }
        saveTask?.cancel()
        saveTask = nil
        while pendingWrites > 0 || !renamingIDs.isEmpty { await Task.yield() }
        let ids = dirtyIDs.sorted { $0.uuidString < $1.uuidString }
        for id in ids {
            if deletingIDs.contains(id) { continue }
            _ = await saveCurrent(id)
        }
        while pendingWrites > 0 || !deletingIDs.isEmpty { await Task.yield() }
        return dirtyIDs.isEmpty
    }

    @discardableResult
    func prepareToQuit() async -> Bool {
        isQuitting = true
        resumeSessionPrompt = nil
        defer { isQuitting = false }
        while let deletionTask { await deletionTask.value }
        while isChangingSources || isConfirmingNewSession { await Task.yield() }
        let saved = if activeID != nil || endingTask != nil {
            await pauseSession()
        } else {
            await flushPendingWrites()
        }
        // Paused capture may retain prepared native resources for a fast
        // resume. Dispose them only after every transcript is safely saved.
        guard saved else { return false }
        // A concurrent pause caller must finish its lifecycle cleanup before
        // ownership is released; no stale completion can affect a later resume.
        while endingTask != nil { await Task.yield() }
        sessionToken = UUID()
        service.onUpdate = nil
        activeID = nil
        newSessionPrompt = nil
        phase = .idle
        service.cancel()
        return true
    }

    private func markDirty(_ id: UUID) {
        revision += 1
        sessionRevisions[id] = revision
        dirtyIDs.insert(id)
    }

    private func saveCurrent(_ id: UUID) async -> Bool {
        guard let library, !deletingIDs.contains(id), !renamingIDs.contains(id), dirtyIDs.contains(id),
              var snapshot = sessions.first(where: { $0.id == id }) else { return true }
        if id == activeID {
            snapshot.recordedDuration = duration(for: snapshot, at: now())
        }
        // Retrying a failed write is a new persistence intent. Its revision
        // supersedes both failed and already queued older snapshots.
        revision += 1
        let version = revision
        sessionRevisions[id] = version
        pendingWrites += 1
        defer { pendingWrites -= 1 }
        do {
            let saved = try await library.save(snapshot, revision: version)
            if saved, sessionRevisions[id] == version {
                dirtyIDs.remove(id)
                if id == activeID { preservesEmptySession = true }
                if let url = await library.documentURL(for: id), let index = sessions.firstIndex(where: { $0.id == id }) {
                    sessions[index].title = url.deletingPathExtension().lastPathComponent
                }
            }
            return saved || !dirtyIDs.contains(id)
        } catch {
            present(error, title: "Transcript couldn’t be saved")
            return false
        }
    }

    func copyTranscript() {
        guard canExport, let session = selectedSession else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.plainText, forType: .string)
        showToast("Transcript copied")
    }

    func exportTranscript(markdown: Bool = false) {
        guard canExport, let session = selectedSession else { return }
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = session.exportFilename(extension: markdown ? "md" : "txt")
        panel.allowedContentTypes = markdown ? [.init(filenameExtension: "md") ?? .plainText] : [.plainText]
        panel.canCreateDirectories = true
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try (markdown ? session.markdown : session.plainText).write(to: url, atomically: true, encoding: .utf8)
                self?.showToast("Transcript exported")
            } catch { self?.present(error, title: "Transcript couldn’t be exported") }
        }
    }

    func rename(_ session: TranscriptSession, to title: String) {
        guard let library, !isQuitting, !requestedDeletionIDs.contains(session.id), !isChangingSources, !isConfirmingNewSession,
              !deletingIDs.contains(session.id), !renamingIDs.contains(session.id),
              let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        let requestedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedTitle.isEmpty else { return }
        sessions[index].title = requestedTitle
        markDirty(session.id)
        let renameRevision = revision
        var snapshot = sessions[index]
        if session.id == activeID {
            snapshot.recordedDuration = duration(for: snapshot, at: now())
        }
        renamingIDs.insert(session.id)
        pendingWrites += 1
        Task {
            defer {
                pendingWrites -= 1
                renamingIDs.remove(session.id)
            }
            do {
                if try await library.rename(snapshot, to: requestedTitle, revision: renameRevision),
                   let url = await library.documentURL(for: session.id),
                   let index = sessions.firstIndex(where: { $0.id == session.id }) {
                    sessions[index].title = url.deletingPathExtension().lastPathComponent
                    if session.id == activeID { preservesEmptySession = true }
                    if sessionRevisions[session.id] == renameRevision { dirtyIDs.remove(session.id) }
                }
            } catch { present(error, title: "Transcript couldn’t be renamed") }
        }
    }

    func delete(_ session: TranscriptSession) {
        guard library != nil, !isQuitting, !requestedDeletionIDs.contains(session.id),
              !deletingIDs.contains(session.id),
              sessions.contains(where: { $0.id == session.id }) else { return }
        let id = session.id
        requestedDeletionIDs.insert(id)
        isDeletingTranscript = true
        if newSessionPrompt?.activeID == id { newSessionPrompt = nil }
        if let request = resumeSessionPrompt, request.activeID == id || request.targetID == id {
            resumeSessionPrompt = nil
        }
        let previous = deletionTask
        let token = UUID()
        deletionTaskToken = token
        deletionTask = Task { [self] in
            defer {
                requestedDeletionIDs.remove(id)
                isDeletingTranscript = !requestedDeletionIDs.isEmpty
                if deletionTaskToken == token { deletionTask = nil }
            }
            await previous?.value
            await performRequestedDeletion(id)
        }
    }

    private func performRequestedDeletion(_ id: UUID) async {
        // Existing source switches and handoffs may finish saving, but the
        // request blocks every restart before either can take new ownership.
        while isChangingSources || isConfirmingNewSession || renamingIDs.contains(id) { await Task.yield() }
        guard let library, sessions.contains(where: { $0.id == id }) else { return }
        if activeID == id {
            // Do not enter deletingIDs yet: finalization's flush must be able
            // to preserve drained words before the file is moved to the Trash.
            guard await stopCapture(pausing: true) else { return }
            guard activeID == id || activeID == nil else { return }
            sessionToken = UUID()
            recordingTask?.cancel()
            recordingTask = nil
            service.onUpdate = nil
            service.cancel()
            activeID = nil
            phase = .idle
            transcript = SessionTranscript()
            preparingUpdates.removeAll()
        } else if dirtyIDs.contains(id) {
            guard await saveCurrent(id) else { return }
        }
        guard sessions.contains(where: { $0.id == id }) else { return }
        deletingIDs.insert(id)
        revision += 1
        let deleteRevision = revision
        sessionRevisions[id] = deleteRevision
        pendingWrites += 1
        defer {
            pendingWrites -= 1
            deletingIDs.remove(id)
        }
        do {
            if try await library.delete(id, revision: deleteRevision) {
                sessions.removeAll { $0.id == id }
                dirtyIDs.remove(id)
                sessionRevisions.removeValue(forKey: id)
                if selectedID == id { selectedID = nil }
            }
        } catch { present(error, title: "Transcript couldn’t be deleted") }
    }

    func chooseTranscript() {
        let panel = NSOpenPanel()
        panel.title = "Open Transcript"
        panel.allowedContentTypes = [UTType("com.asherbloom.relay.transcript") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let storageFolderURL { panel.directoryURL = storageFolderURL }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.openTranscript(at: url)
        }
    }

    func openTranscript(at url: URL) {
        Task {
            while !isLoaded { await Task.yield() }
            do {
                let library = try await prepareLibrary()
                let item = try await library.open(at: url)
                if item.id != activeID {
                    sessions.removeAll { $0.id == item.id }
                    sessions.append(item)
                    sessions.sort { $0.startedAt > $1.startedAt }
                }
                selectedID = item.id
            } catch { present(error, title: "Transcript couldn’t be opened") }
        }
    }

    func revealStorageFolder() {
        guard let storageFolderURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([storageFolderURL])
    }

    private func handleLibraryEvent(_ event: RelayLibraryEvent) {
        switch event {
        case .discovered(let incoming, _):
            guard incoming.id != activeID, !deletingIDs.contains(incoming.id),
                  !sessions.contains(where: { $0.id == incoming.id }) else { return }
            sessions.append(incoming)
            sessions.sort { $0.startedAt > $1.startedAt }
        case .updated(let incoming, _):
            guard let index = sessions.firstIndex(where: { $0.id == incoming.id }) else { return }
            if !renamingIDs.contains(incoming.id) { sessions[index].title = incoming.title }
            if incoming.id == activeID {
                for segment in incoming.segments {
                    transcript.apply(TranscriptUpdate(segmentID: segment.id, source: segment.source,
                        text: segment.text, isFinal: segment.isFinal, timestamp: segment.timestamp,
                        timingIsConfirmed: segment.timingIsConfirmed))
                }
                sessions[index].segments = transcript.segments
            } else if !dirtyIDs.contains(incoming.id) {
                sessions[index] = incoming
            }
        case .removed(let id):
            if let request = resumeSessionPrompt, request.activeID == id || request.targetID == id {
                resumeSessionPrompt = nil
            }
            if activeID == id {
                sessionToken = UUID()
                recordingTask?.cancel()
                service.cancel()
                activeID = nil
                phase = endingTask == nil ? .idle : .ending
                saveTask?.cancel()
                service.onUpdate = nil
            }
            sessions.removeAll { $0.id == id }
            dirtyIDs.remove(id)
            sessionRevisions.removeValue(forKey: id)
            if selectedID == id { selectedID = nil }
        case .issue(let message):
            notice = RelayNotice(title: "Transcript couldn’t be updated", message: message)
        }
    }

    private func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task {
            do { try await Task.sleep(for: .seconds(2.5)); toast = nil }
            catch { }
        }
    }

    private func present(_ error: Error, title: String) {
        notice = RelayNotice(title: title, message: error.localizedDescription)
    }
}

#if DEBUG
/// UI-only transport fixture. Both testing gates are checked before construction;
/// it never requests permissions, opens audio hardware, or uses the real library.
@MainActor @Observable
private final class RelayFixtureTranscriber: RelayTranscribing {
    var state: TranscriptionService.CaptureState = .idle
    var level: Double = 0
    var statusMessage: String?
    var captureStartedAt: Date?
    var reducesSpeakerEcho = true
    var onUpdate: ((TranscriptUpdate) -> Void)?
    var isRunning: Bool { state == .running }
    func start(sources: Set<TranscriptSource>, locale: Locale) async throws {
        captureStartedAt = Date()
        state = .running
    }
    func startAuto(sources: Set<TranscriptSource>) async throws {
        try await start(sources: sources, locale: Locale(identifier: "en-US"))
    }
    func stop() async { state = .idle }
    func cancel() { state = .idle }
}
#endif
