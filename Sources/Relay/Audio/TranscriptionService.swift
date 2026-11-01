@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import OSLog
@preconcurrency import ScreenCaptureKit
import Speech

@MainActor
@Observable
final class TranscriptionService {
    enum CaptureState: Equatable {
        case idle
        case preparing
        case running
        case stopping
        case failed(String)
    }

    var reducesSpeakerEcho = true {
        didSet {
            guard oldValue != reducesSpeakerEcho else { return }
            updateEchoProcessing()
            if state == .running { scheduleReferenceConfiguration() }
        }
    }
    private(set) var isSpeakerEchoReductionActive = false
    private(set) var state: CaptureState = .idle
    private(set) var detectedLocale: Locale?
    private(set) var captureStartedAt: Date?
    private(set) var captureReadyAt: Date?
    private(set) var level: Double = 0
    private var transcriptionStatusMessage: String?
    private var microphoneStatusMessage: String?
    var statusMessage: String? { microphoneStatusMessage ?? transcriptionStatusMessage }
    var onUpdate: ((TranscriptUpdate) -> Void)?
    var isRunning: Bool { state == .running }
    var isBusy: Bool { state == .preparing || state == .running || state == .stopping }

    @ObservationIgnored private let languageDetector = AutoLanguageDetector()
    @ObservationIgnored private var autoMode = false
    @ObservationIgnored private var autoBridges: [TranscriptSource: BufferedAudioPipeline] = [:]
    @ObservationIgnored private var autoDetectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAutoSamples: [Float]?
    @ObservationIgnored private var pipelines: [TranscriptSource: any AudioTranscriptionPipeline] = [:]
    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var streamOutput: SystemAudioOutput?
    @ObservationIgnored private var systemCaptureID: UUID?
    @ObservationIgnored private var microphoneController: MicrophoneCaptureController?
    @ObservationIgnored private var cachedMicrophone: MicrophoneCaptureController?
    @ObservationIgnored private var echoPipeline: ReferenceEchoPipeline?
    @ObservationIgnored private var transcribesSystemAudio = false
    @ObservationIgnored private var referenceStreamIsReady = false
    @ObservationIgnored private var referenceOperation = UUID()
    @ObservationIgnored private var referenceConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var installationProgress: Progress?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var captureOrigin: Double = 0
    @ObservationIgnored private var levels: [TranscriptSource: Double] = [:]
    @ObservationIgnored private var finishingError: String?
    @ObservationIgnored private let timingLogger = Logger(subsystem: "com.asherbloom.Relay", category: "CaptureStartup")
    @ObservationIgnored private var preparationStartedAt: TimeInterval = 0

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales.sorted {
            (Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier)
                .localizedStandardCompare(Locale.current.localizedString(forIdentifier: $1.identifier) ?? $1.identifier) == .orderedAscending
        }
    }

    func start(sources: Set<TranscriptSource>, locale: Locale) async throws {
        guard !isBusy else { return }
        preparationStartedAt = ProcessInfo.processInfo.systemUptime
        logStartup("manual.requested")
        captureStartedAt = nil
        captureReadyAt = nil
        transcribesSystemAudio = sources.contains(.systemAudio)
        let token = UUID()
        generation = token
        state = .preparing
        transcriptionStatusMessage = "Preparing transcription…"
        finishingError = nil
        autoMode = false
        pendingAutoSamples = nil
        detectedLocale = nil
        do {
            guard !sources.isEmpty else { throw AudioTranscriptionError.noSource }
            guard SpeechTranscriber.isAvailable else { throw AudioTranscriptionError.unavailable }
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw AudioTranscriptionError.unsupportedLanguage(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
            }
            try checkGeneration(token)
            logStartup("language.ready")
            detectedLocale = supported
            if sources.contains(.microphone) {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: break
                case .notDetermined:
                    transcriptionStatusMessage = "Waiting for microphone access…"
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AudioTranscriptionError.microphonePermission }
                default: throw AudioTranscriptionError.microphonePermission
                }
            }
            try checkGeneration(token)

            // One locale reservation supports both source modules; no speech or audio leaves this Mac.
            let modules = sources.sorted(by: { $0.rawValue < $1.rawValue }).map { source in
                (source, SpeechTranscriber(locale: supported, preset: .timeIndexedProgressiveTranscription))
            }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules.map(\.1)) {
                try checkGeneration(token)
                transcriptionStatusMessage = "Downloading \(Locale.current.localizedString(forLanguageCode: supported.language.languageCode?.identifier ?? supported.identifier) ?? "language") transcription…"
                installationProgress = request.progress
                try await request.downloadAndInstall()
                try checkGeneration(token)
                installationProgress = nil
            }
            try checkGeneration(token)
            logStartup("assets.ready")
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules.map(\.1)) else {
                throw AudioTranscriptionError.audioFormat
            }
            try checkGeneration(token)
            logStartup("format.ready")
            transcriptionStatusMessage = "Starting audio…"
            let origin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            captureOrigin = origin
            captureStartedAt = Date()
            var prepared: [SpeechPipeline] = []
            for (source, transcriber) in modules {
                try checkGeneration(token)
                let pipeline = SpeechPipeline(source: source, transcriber: transcriber, format: format, origin: origin,
                    onUpdate: { [weak self] update in
                        guard let self, self.generation == token else { return }
                        self.onUpdate?(update)
                    }, onLevel: { [weak self] value in
                        guard let self, self.generation == token, self.state == .running else { return }
                        self.levels[source] = source == .microphone && self.microphoneController?.isConnected != true ? 0 : value
                        self.level = self.levels.values.max() ?? 0
                    }, onFailure: { [weak self] error in
                        guard let self, self.generation == token else { return }
                        self.handleCaptureFailure(error)
                    })
                pipelines[source] = pipeline
                prepared.append(pipeline)
            }
            try await startPipelines(prepared, token: token)
            try checkGeneration(token)
            try prepareEchoPipeline(token: token)
            // Start the reference producer first so opening microphone audio has
            // its matching far-end signal. Both speech lanes remain independent.
            if needsSystemAudioCapture {
                try await startSystemAudio(pipeline: pipelines[.systemAudio], token: token)
            }
            try checkGeneration(token)
            if let pipeline = pipelines[.microphone] {
                startMicrophone(pipeline: echoPipeline ?? pipeline, token: token)
            }
            try checkGeneration(token)
            if let microphoneController { try await microphoneController.waitUntilReady() }
            try checkGeneration(token)
            try await configureReferenceCapture(token: token)
            try checkGeneration(token)
            captureReadyAt = Date()
            state = .running
            updateEchoProcessing()
            transcriptionStatusMessage = nil
            logStartup("service.running")
        } catch {
            if generation == token {
                await cleanUpImmediately()
                guard generation == token else { throw error }
                if error is CancellationError {
                    state = .idle
                    transcriptionStatusMessage = nil
                } else {
                    state = .failed(error.localizedDescription)
                    transcriptionStatusMessage = error.localizedDescription
                }
            }
            throw error
        }
    }

    /// Auto identifies the first spoken language from local audio, then keeps that session language.
    /// Buffering preserves the opening while the corresponding Apple speech model is prepared.
    func startAuto(sources: Set<TranscriptSource>) async throws {
        guard !isBusy else { return }
        preparationStartedAt = ProcessInfo.processInfo.systemUptime
        logStartup("auto.requested")
        captureStartedAt = nil
        captureReadyAt = nil
        transcribesSystemAudio = sources.contains(.systemAudio)
        let token = UUID()
        generation = token
        state = .preparing
        transcriptionStatusMessage = "Preparing automatic language detection…"
        finishingError = nil
        autoMode = true
        pendingAutoSamples = nil
        detectedLocale = nil
        do {
            guard !sources.isEmpty else { throw AudioTranscriptionError.noSource }
            guard SpeechTranscriber.isAvailable else { throw AudioTranscriptionError.unavailable }
            try await languageDetector.prepare()
            try checkGeneration(token)
            logStartup("detector.ready")
            if sources.contains(.microphone) {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: break
                case .notDetermined:
                    transcriptionStatusMessage = "Waiting for microphone access…"
                    guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AudioTranscriptionError.microphonePermission }
                default: throw AudioTranscriptionError.microphonePermission
                }
            }
            try checkGeneration(token)
            captureOrigin = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            captureStartedAt = Date()
            for source in sources {
                let bridge = try BufferedAudioPipeline(source: source,
                    onSamples: { [weak self] samples in
                        guard let self, self.generation == token, self.autoBridges[source] != nil,
                              self.detectedLocale == nil,
                              self.autoDetectionTask == nil else { return }
                        self.scheduleAutoDetection(samples: samples, token: token)
                    }, onLevel: { [weak self] value in
                        guard let self, self.generation == token, self.state == .running else { return }
                        self.levels[source] = source == .microphone && self.microphoneController?.isConnected != true ? 0 : value
                        self.level = self.levels.values.max() ?? 0
                    }, onFailure: { [weak self] error in
                        guard let self, self.generation == token else { return }
                        self.handleCaptureFailure(error)
                    })
                autoBridges[source] = bridge
                pipelines[source] = bridge
            }
            try prepareEchoPipeline(token: token)
            // Start the reference producer first so opening microphone audio has
            // its matching far-end signal. Both speech lanes remain independent.
            if needsSystemAudioCapture {
                try await startSystemAudio(pipeline: pipelines[.systemAudio], token: token)
            }
            try checkGeneration(token)
            if let pipeline = pipelines[.microphone] {
                startMicrophone(pipeline: echoPipeline ?? pipeline, token: token)
            }
            try checkGeneration(token)
            if let microphoneController { try await microphoneController.waitUntilReady() }
            try checkGeneration(token)
            try await configureReferenceCapture(token: token)
            try checkGeneration(token)
            captureReadyAt = Date()
            state = .running
            updateEchoProcessing()
            transcriptionStatusMessage = "Listening for speech…"
            logStartup("service.running")
            if let samples = pendingAutoSamples {
                pendingAutoSamples = nil
                scheduleAutoDetection(samples: samples, token: token)
            }
        } catch {
            if generation == token {
                await cleanUpImmediately()
                guard generation == token else { throw error }
                state = error is CancellationError ? .idle : .failed(error.localizedDescription)
                transcriptionStatusMessage = error is CancellationError ? nil : error.localizedDescription
            }
            throw error
        }
    }

    private func scheduleAutoDetection(samples: [Float], token: UUID) {
        guard generation == token else { return }
        if state == .preparing {
            // The microphone can now begin while system capture is obtaining access.
            // Keep the one-shot detection request until both setup paths have completed.
            if pendingAutoSamples == nil { pendingAutoSamples = samples }
            return
        }
        guard state == .running else { return }
        autoDetectionTask = Task { [weak self] in
            guard let self else { return }
            do { try await self.configureAutoLanguage(samples: samples, token: token) }
            catch is CancellationError {}
            catch {
                guard self.generation == token else { return }
                self.autoDetectionTask = nil
                self.finishingError = error.localizedDescription
                self.handleCaptureFailure(error)
            }
        }
    }

    private func configureAutoLanguage(samples: [Float], token: UUID) async throws {
        try checkGeneration(token)
        transcriptionStatusMessage = "Identifying language…"
        let code = try await languageDetector.detect(samples: samples)
        try checkGeneration(token)
        let locale: Locale
        if let equivalent = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: code)) {
            locale = equivalent
        } else if let candidate = await SpeechTranscriber.supportedLocales.first(where: {
            $0.language.languageCode?.identifier == code
        }) {
            locale = candidate
        } else {
            throw AudioTranscriptionError.unsupportedLanguage(Locale.current.localizedString(forLanguageCode: code) ?? code)
        }
        try checkGeneration(token)
        let label = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        transcriptionStatusMessage = "Preparing \(label)…"
        let modules = autoBridges.keys.map { source in
            (source, SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription))
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules.map(\.1)) {
            try checkGeneration(token)
            installationProgress = request.progress
            try await request.downloadAndInstall()
            try checkGeneration(token)
            installationProgress = nil
        }
        try checkGeneration(token)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules.map(\.1)) else {
            throw AudioTranscriptionError.audioFormat
        }
        try checkGeneration(token)
        // Capture timestamps use the host clock. The bridge replays each buffer's original time.
        let origin = captureOrigin
        var created: [(TranscriptSource, SpeechPipeline)] = []
        do {
            for (source, module) in modules {
                try checkGeneration(token)
                let pipeline = SpeechPipeline(source: source, transcriber: module, format: format, origin: origin,
                    onUpdate: { [weak self] update in
                        guard let self, self.generation == token else { return }
                        self.onUpdate?(update)
                    }, onLevel: { [weak self] value in
                        guard let self, self.generation == token, self.state == .running else { return }
                        self.levels[source] = source == .microphone && self.microphoneController?.isConnected != true ? 0 : value
                        self.level = self.levels.values.max() ?? 0
                    }, onFailure: { [weak self] error in
                        guard let self, self.generation == token else { return }
                        self.handleCaptureFailure(error)
                    })
                created.append((source, pipeline))
            }
            try await startPipelines(created.map(\.1), token: token)
            for (source, pipeline) in created {
                try checkGeneration(token)
                try await autoBridges[source]?.install(pipeline)
                try checkGeneration(token)
            }
        } catch {
            for (_, pipeline) in created { await pipeline.cancel() }
            throw error
        }
        try checkGeneration(token)
        detectedLocale = locale
        transcriptionStatusMessage = nil
    }

    /// Stops capture, drains conversion queues, then waits for final recognition results.
    func stop() async {
        if state == .preparing { cancel(); return }
        guard state == .running else { return }
        let token = generation
        state = .stopping
        transcriptionStatusMessage = "Finishing transcript…"
        invalidateReferenceConfiguration()
        let outputToDrain = streamOutput
        let streamToStop = stream
        let echoToDrain = echoPipeline
        echoPipeline = nil
        stream = nil
        streamOutput = nil
        systemCaptureID = nil
        referenceStreamIsReady = false
        await pauseMicrophone(token: token)
        if let streamToStop {
            do { try await streamToStop.stopCapture() }
            catch {
                if generation == token { finishingError = finishingError ?? error.localizedDescription }
            }
        }
        await outputToDrain?.drain()
        do { try await echoToDrain?.drain() }
        catch {
            if generation == token { finishingError = finishingError ?? error.localizedDescription }
        }
        guard generation == token else { await echoToDrain?.cancel(); return }
        stream = nil
        streamOutput = nil
        systemCaptureID = nil
        if autoMode, detectedLocale == nil {
            if finishingError != nil {
                autoDetectionTask?.cancel()
                installationProgress?.cancel()
            }
            if let task = autoDetectionTask {
                await task.value
                guard generation == token else { return }
            } else if finishingError == nil {
                for bridge in autoBridges.values {
                    let samples = await bridge.detectionSamples()
                    guard generation == token else { return }
                    if !samples.isEmpty {
                        do { try await configureAutoLanguage(samples: samples, token: generation) }
                        catch {
                            if generation == token { finishingError = error.localizedDescription }
                        }
                        guard generation == token else { return }
                        break
                    }
                }
            }
        }
        autoDetectionTask = nil
        transcriptionStatusMessage = "Finishing transcript…"
        for pipeline in pipelines.values {
            do { try await pipeline.finish() }
            catch {
                if generation == token { finishingError = finishingError ?? error.localizedDescription }
                await pipeline.cancel()
            }
            guard generation == token else { return }
        }
        installationProgress = nil
        pipelines.removeAll()
        autoBridges.removeAll()
        pendingAutoSamples = nil
        levels.removeAll()
        level = 0
        if let finishingError {
            state = .failed(finishingError)
            transcriptionStatusMessage = finishingError
        } else {
            state = .idle
            transcriptionStatusMessage = nil
        }
    }

    /// Immediate cancellation is for a cancelled setup or app termination, not a normal pause.
    func cancel() {
        captureStartedAt = nil
        captureReadyAt = nil
        generation = UUID()
        autoDetectionTask?.cancel()
        autoDetectionTask = nil
        pendingAutoSamples = nil
        autoBridges.removeAll()
        installationProgress?.cancel()
        installationProgress = nil
        invalidateReferenceConfiguration()
        let oldEcho = echoPipeline
        echoPipeline = nil
        oldEcho?.cancelImmediately()
        stopMicrophone()
        let oldStream = stream
        let oldPipelines = Array(pipelines.values)
        stream = nil
        streamOutput = nil
        systemCaptureID = nil
        pipelines.removeAll()
        levels.removeAll()
        level = 0
        state = .idle
        transcriptionStatusMessage = nil
        Task {
            try? await oldStream?.stopCapture()
            await oldEcho?.cancel()
            for pipeline in oldPipelines { await pipeline.cancel() }
        }
    }

    private func checkGeneration(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }

    private func startPipelines(_ prepared: [SpeechPipeline], token: UUID) async throws {
        try checkGeneration(token)
        try await AudioPipelineStartup.start(prepared)
        try checkGeneration(token)
        logStartup("recognizers.ready")
    }

    private func logStartup(_ stage: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - preparationStartedAt
        timingLogger.notice("Capture startup: stage=\(stage, privacy: .public) elapsed=\(elapsed)")
    }

    private var needsSystemAudioCapture: Bool {
        transcribesSystemAudio || (pipelines[.microphone] != nil && reducesSpeakerEcho)
    }

    private func updateEchoProcessing() {
        let enabled = echoPipeline != nil && reducesSpeakerEcho && referenceStreamIsReady
        echoPipeline?.setEnabled(enabled)
        isSpeakerEchoReductionActive = enabled && state == .running
    }

    private func checkReferenceOperation(_ token: UUID, operation: UUID?) throws {
        try checkGeneration(token)
        if let operation {
            guard operation == referenceOperation, state == .running else { throw CancellationError() }
        }
    }

    /// Requested transcript sources and the local echo reference have independent
    /// lifetimes. Microphone-only never acquires a System recognizer or Auto bridge.
    private func configureReferenceCapture(token: UUID, operation: UUID? = nil) async throws {
        try checkReferenceOperation(token, operation: operation)
        if needsSystemAudioCapture {
            if stream == nil {
                try await startSystemAudio(pipeline: pipelines[.systemAudio], token: token, operation: operation)
            }
        } else if let oldStream = stream {
            let oldOutput = streamOutput
            stream = nil
            streamOutput = nil
            systemCaptureID = nil
            referenceStreamIsReady = false
            updateEchoProcessing()
            try await oldStream.stopCapture()
            await oldOutput?.drain()
            try checkReferenceOperation(token, operation: operation)
        }
        updateEchoProcessing()
    }

    private func scheduleReferenceConfiguration() {
        let previous = referenceConfigurationTask
        previous?.cancel()
        let operation = UUID()
        referenceOperation = operation
        let token = generation
        referenceConfigurationTask = Task { [weak self] in
            // Serialize rapid ON/OFF/ON changes. A stale candidate always finishes
            // retiring itself before its successor can install a different stream.
            await previous?.value
            guard let self else { return }
            do {
                try await self.configureReferenceCapture(token: token, operation: operation)
            } catch is CancellationError { }
            catch {
                guard self.generation == token, self.referenceOperation == operation,
                      self.state == .running else { return }
                self.handleCaptureFailure(error)
            }
        }
    }

    @discardableResult
    private func invalidateReferenceConfiguration() -> Task<Void, Never>? {
        referenceOperation = UUID()
        let previous = referenceConfigurationTask
        referenceConfigurationTask = nil
        // Unpublished native permission/content requests can ignore cancellation.
        // Their local candidates reject this operation before publication and
        // retire themselves. They must not hold Pause or Quit open. An OFF task
        // may also be retiring a reference-only stream, whose wrapper is already
        // bypassed; late reference callbacks are rejected after echo intake closes.
        previous?.cancel()
        referenceStreamIsReady = false
        return previous
    }

    #if DEBUG
    var transcriptionSourcesForTesting: Set<TranscriptSource> { Set(pipelines.keys) }
    var isSpeakerReferenceCaptureActiveForTesting: Bool { referenceStreamIsReady && echoPipeline != nil }
    func waitForReferenceConfigurationForTesting() async { await referenceConfigurationTask?.value }
    #endif

    private func startSystemAudio(pipeline: (any AudioTranscriptionPipeline)?, token: UUID,
                                  operation: UUID? = nil) async throws {
        if state == .preparing { transcriptionStatusMessage = "Waiting for system audio access…" }
        if state == .running, !transcribesSystemAudio, !CGPreflightScreenCaptureAccess() {
            throw AudioTranscriptionError.speakerEchoReferencePermission
        }
        logStartup("system.content.requested")
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch {
            if !CGPreflightScreenCaptureAccess() {
                throw transcribesSystemAudio ? AudioTranscriptionError.systemAudioPermission : AudioTranscriptionError.speakerEchoReferencePermission
            }
            throw error
        }
        try checkReferenceOperation(token, operation: operation)
        logStartup("system.content.ready")
        guard let display = content.displays.first else { throw AudioTranscriptionError.noDisplay }
        let excluded = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.captureMicrophone = false
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        let captureID = UUID()
        let output = SystemAudioOutput(pipeline: pipeline, echoPipeline: echoPipeline) { [weak self] error in
            guard let self, self.generation == token, self.systemCaptureID == captureID else { return }
            self.handleCaptureFailure(error)
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        // No .screen output is registered: Relay consumes audio buffers only, never screen frames.
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        logStartup("system.capture.requested")
        do {
            try await stream.startCapture()
            try checkReferenceOperation(token, operation: operation)
            self.stream = stream
            streamOutput = output
            systemCaptureID = captureID
            referenceStreamIsReady = true
            updateEchoProcessing()
            logStartup("system.capture.ready")
        } catch {
            // Never publish an abandoned asynchronous candidate. Its own output
            // retains this generation's wrapper, so cleanup cannot stop a successor.
            try? await stream.stopCapture()
            await output.drain()
            throw error
        }
    }

    private func prepareEchoPipeline(token: UUID) throws {
        try checkGeneration(token)
        guard let microphone = pipelines[.microphone] else { return }
        echoPipeline = try ReferenceEchoPipeline(downstream: microphone, enabled: false) { [weak self] error in
            guard let self, self.generation == token else { return }
            self.handleCaptureFailure(error)
        }
    }

    private func startMicrophone(pipeline: any AudioTranscriptionPipeline, token: UUID) {
        logStartup("microphone.requested")
        let onStatus: @MainActor (String?) -> Void = { [weak self] message in
            guard let self, self.generation == token else { return }
            self.microphoneStatusMessage = message
            if message == nil, self.microphoneController?.isConnected == true {
                self.logStartup("microphone.connected")
            }
            if message != nil {
                self.levels[.microphone] = 0
                self.level = self.levels.values.max() ?? 0
            }
        }
        // The native graph always supplies raw microphone audio. AEC3 receives
        // the explicit system reference upstream of this session's recognizer,
        // so changing source or echo preference never swaps raw/voice-I/O units.
        let onProcessing: @MainActor (Bool) -> Void = { [weak self] _ in
            guard let self, self.generation == token else { return }
            self.isSpeakerEchoReductionActive = self.echoPipeline != nil && self.reducesSpeakerEcho && self.referenceStreamIsReady && self.state == .running
        }
        let controller: MicrophoneCaptureController
        if let cached = cachedMicrophone {
            cached.rebind(pipeline: pipeline, onStatus: onStatus, onProcessingState: onProcessing)
            controller = cached
        } else {
            controller = MicrophoneCaptureController(pipeline: pipeline, reducesSpeakerEcho: false,
                onStatus: onStatus, onProcessingState: onProcessing)
            cachedMicrophone = controller
        }
        microphoneController = controller
        controller.start()
    }

    // AVAudioEngine invokes this block on its realtime audio thread. Constructing it in
    // this explicitly nonisolated factory prevents inheriting the service's MainActor.
    nonisolated static func microphoneTap(for pipeline: any AudioTranscriptionPipeline) -> AVAudioNodeTapBlock {
        { @Sendable [pipeline] buffer, time in
            let hostTime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            pipeline.accept(buffer, hostTime: hostTime)
        }
    }

    private func pauseMicrophone(token: UUID) async {
        let controller = microphoneController
        microphoneController = nil
        await controller?.pause()
        guard generation == token else { return }
        microphoneStatusMessage = nil
        isSpeakerEchoReductionActive = false
    }

    private func stopMicrophone() {
        microphoneController = nil
        let oldController = cachedMicrophone
        cachedMicrophone = nil
        oldController?.stop()
        microphoneStatusMessage = nil
        isSpeakerEchoReductionActive = false
    }

    private func handleCaptureFailure(_ error: Error) {
        guard state == .running || state == .preparing else { return }
        finishingError = error.localizedDescription
        if state == .running {
            let token = generation
            Task {
                guard self.generation == token else { return }
                await self.stop()
            }
        } else {
            cancel()
            state = .failed(error.localizedDescription)
            transcriptionStatusMessage = error.localizedDescription
        }
    }

    private func cleanUpImmediately() async {
        captureStartedAt = nil
        captureReadyAt = nil
        // Detach this generation's resources before awaiting. A cancelled setup can then restart
        // without an older cleanup removing the new session's stream or pipelines.
        installationProgress?.cancel()
        installationProgress = nil
        invalidateReferenceConfiguration()
        let oldEcho = echoPipeline
        echoPipeline = nil
        oldEcho?.cancelImmediately()
        stopMicrophone()
        let oldStream = stream
        let oldPipelines = Array(pipelines.values)
        stream = nil
        streamOutput = nil
        systemCaptureID = nil
        pipelines.removeAll()
        autoBridges.removeAll()
        autoDetectionTask?.cancel()
        autoDetectionTask = nil
        pendingAutoSamples = nil
        level = 0
        try? await oldStream?.stopCapture()
        await oldEcho?.cancel()
        for pipeline in oldPipelines { await pipeline.cancel() }
    }

}

private final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.asherbloom.Relay.systemCapture", qos: .userInitiated)
    private let pipeline: (any AudioTranscriptionPipeline)?
    private let echoPipeline: ReferenceEchoPipeline?
    private let onFailure: @MainActor @Sendable (Error) -> Void

    init(pipeline: (any AudioTranscriptionPipeline)?, echoPipeline: ReferenceEchoPipeline?,
         onFailure: @escaping @MainActor @Sendable (Error) -> Void) {
        self.pipeline = pipeline
        self.echoPipeline = echoPipeline
        self.onFailure = onFailure
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.dataReadiness == .ready else { return }
        echoPipeline?.acceptReference(sampleBuffer)
        pipeline?.accept(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [onFailure] in onFailure(error) }
    }
}
