@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import OSLog

/// Owns microphone hardware, independently of the continuing recognition and system-audio streams.
/// Normal device changes reconnect this controller; they never end the transcript session.
@MainActor
final class MicrophoneCaptureController {
    private struct ConnectionGoal: Equatable {
        let route: MicrophoneDeviceRoute
        let echoReduction: Bool
    }
    private enum WaitingReason { case none, noDevice, echoReduction, transient }
    private enum ConnectionError: Error { case changing, noDevice }
    private var pendingPipeline: (any AudioTranscriptionPipeline)?
    private var onStatus: @MainActor (String?) -> Void
    private var onProcessingState: @MainActor (Bool) -> Void
    private let destination = MicrophoneTapDestination()
    private let logger = Logger(subsystem: "com.asherbloom.Relay", category: "Microphone")
    private let captureMetricsEnabled = ProcessInfo.processInfo.environment["RELAY_CAPTURE_METRICS"] == "1"
    private(set) var isConnected = false
    private var wantsEchoReduction: Bool
    private var alive = false
    private var isPausing = false
    private var hasConnected = false
    private var lifetime = UUID()
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var engineObserver: NSObjectProtocol?
    private var installed: MicrophoneConfigurationSnapshot?
    private var connectionTask: Task<Void, Never>?
    private var monitorTask: Task<Void, Never>?
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var goal: ConnectionGoal?
    private var needsRecheck = false
    private var waiting: WaitingReason = .none
    private var nextRetryTime: TimeInterval = 0
    private var recentAttempts: [TimeInterval] = []
    private var recentRetainedRestarts: [TimeInterval] = []
    private var installedTapID: UUID?
    private var activeTapID: UUID?
    private var receivedFirstBuffer = false
    private var readinessCycle = UUID()
    private let readiness = MicrophoneReadinessGate()

    #if DEBUG
    var engineForTesting: AVAudioEngine? { engine }
    #endif

    init(pipeline: any AudioTranscriptionPipeline, reducesSpeakerEcho: Bool,
         onStatus: @escaping @MainActor (String?) -> Void,
         onProcessingState: @escaping @MainActor (Bool) -> Void) {
        pendingPipeline = pipeline
        wantsEchoReduction = reducesSpeakerEcho
        self.onStatus = onStatus
        self.onProcessingState = onProcessingState
    }

    func start() {
        guard !alive, !isPausing, let pipeline = pendingPipeline else { return }
        pendingPipeline = nil
        alive = true
        hasConnected = false
        waiting = .none
        nextRetryTime = 0
        recentAttempts.removeAll()
        recentRetainedRestarts.removeAll()
        let token = UUID()
        lifetime = token
        readiness.reset()
        receivedFirstBuffer = false
        readinessCycle = UUID()
        destination.bind(pipeline, onFirstBuffer: Self.firstBufferCallback(controller: self, token: token,
            cycle: readinessCycle), minimumHostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
        addRouteListeners()
        if let engine, let installed, let installedTapID {
            let current = MicrophoneConfigurationSnapshot.read(engine: engine, includesSpeakerReference: wantsEchoReduction)
            let decision = MicrophoneConfigurationPolicy.decision(installed: installed, current: current,
                requiresVoiceProcessing: wantsEchoReduction)
            if decision == .restart || decision == .unchanged {
                activeTapID = installedTapID
                destination.selectGraph(installedTapID)
                installEngineObserver(engine)
                if decision == .restart {
                    requestRetainedRestart(engine: engine)
                } else {
                    isConnected = true
                    hasConnected = true
                    onProcessingState(wantsEchoReduction && current.voiceProcessingEnabled)
                    onStatus(nil)
                }
            } else {
                requestConnection()
            }
        } else {
            requestConnection()
        }
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.alive, self.lifetime == token else { return }
                self.handleConfigurationNotice()
            }
        }
    }

    nonisolated private static func firstBufferCallback(controller: MicrophoneCaptureController,
                                                       token: UUID, cycle: UUID) -> @Sendable (UUID) -> Void {
        { @Sendable [weak controller] graphID in
            Task { @MainActor in
                guard let controller, controller.alive, controller.lifetime == token,
                      controller.readinessCycle == cycle,
                      controller.activeTapID == graphID else { return }
                controller.receivedFirstBuffer = true
                controller.resolveReadiness()
            }
        }
    }

    func rebind(pipeline: any AudioTranscriptionPipeline,
                onStatus: @escaping @MainActor (String?) -> Void,
                onProcessingState: @escaping @MainActor (Bool) -> Void) {
        guard !alive, !isPausing else { return }
        pendingPipeline = pipeline
        self.onStatus = onStatus
        self.onProcessingState = onProcessingState
    }

    func waitUntilReady() async throws {
        let token = lifetime
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(12))
        while true {
            try Task.checkCancellation()
            guard alive, lifetime == token else { throw CancellationError() }
            if isConnected, receivedFirstBuffer, engine?.isRunning == true { return }
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { throw AudioTranscriptionError.microphoneUnavailable }
            if readiness.isCompleted { readiness.rearm() }
            try await readiness.wait(timeout: remaining)
        }
    }

    /// Keeps the prepared graph while stopping hardware and closing the old
    /// document's sink before any asynchronous teardown or final-word drain.
    func pause() async {
        guard !isPausing else { return }
        isPausing = true
        destination.close()
        pendingPipeline = nil
        let connecting = connectionTask
        deactivate()
        let token = lifetime
        engine?.pause()
        isConnected = false
        onProcessingState(false)
        onStatus(nil)
        await connecting?.value
        await destination.drain()
        guard lifetime == token else { return }
        isPausing = false
        onStatus = { _ in }
        onProcessingState = { _ in }
    }

    func setEchoReduction(_ enabled: Bool) {
        guard wantsEchoReduction != enabled else { return }
        wantsEchoReduction = enabled
        guard alive else { return }
        requestConnection()
    }

    func stop() {
        destination.close()
        pendingPipeline = nil
        deactivate()
        isPausing = false
        detachHardware()
        onStatus(nil)
        onStatus = { _ in }
        onProcessingState = { _ in }
    }

    private func deactivate() {
        alive = false
        lifetime = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        for (var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners.removeAll()
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        receivedFirstBuffer = false
        readiness.cancel()
    }

    private func resolveReadiness() {
        guard alive, isConnected, receivedFirstBuffer, engine?.isRunning == true else { return }
        if !readiness.isCompleted, let engine {
            let input = engine.inputNode
            let preferred = AVCaptureDevice.preferredMicrophoneMode.rawValue
            let active = AVCaptureDevice.activeMicrophoneMode.rawValue
            logger.notice("Microphone processing ready: requestedVoice=\(self.wantsEchoReduction) enabled=\(input.isVoiceProcessingEnabled) bypassed=\(input.isVoiceProcessingBypassed) muted=\(input.isVoiceProcessingInputMuted) agc=\(input.isVoiceProcessingAGCEnabled) preferredMicMode=\(preferred) activeMicMode=\(active)")
        }
        readiness.complete()
    }

    private func rearmReadiness() {
        receivedFirstBuffer = false
        readinessCycle = UUID()
        readiness.rearm()
        destination.rearmFirstBuffer(Self.firstBufferCallback(controller: self, token: lifetime,
            cycle: readinessCycle), minimumHostTime: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
    }

    private func handleConfigurationNotice() {
        guard alive else { return }
        if connectionTask != nil { needsRecheck = true; return }
        let route = MicrophoneDeviceRoute.current(includesSpeakerReference: wantsEchoReduction)
        if let engine, let installed {
            let current = MicrophoneConfigurationSnapshot.read(engine: engine, includesSpeakerReference: wantsEchoReduction)
            let decision = MicrophoneConfigurationPolicy.decision(installed: installed, current: current,
                                                                  requiresVoiceProcessing: wantsEchoReduction)
            log(current, decision: decision)
            switch decision {
            case .unchanged: return
            case .restart: requestRetainedRestart(engine: engine)
            case .reconnect, .waitForDevice: requestConnection()
            }
            return
        }
        let desired = ConnectionGoal(route: route, echoReduction: wantsEchoReduction)
        if desired != goal || waiting == .noDevice && route.hasInput {
            requestConnection()
        } else if (waiting == .transient || waiting == .echoReduction), ProcessInfo.processInfo.systemUptime >= nextRetryTime {
            requestConnection()
        }
    }

    private func requestRetainedRestart(engine target: AVAudioEngine) {
        guard alive, engine === target else { return }
        if connectionTask != nil { needsRecheck = true; return }
        rearmReadiness()
        let now = ProcessInfo.processInfo.systemUptime
        if waiting == .transient, now < nextRetryTime { return }
        recentRetainedRestarts.removeAll { now - $0 > 10 }
        guard recentRetainedRestarts.count < 3 else {
            isConnected = false
            onProcessingState(false)
            waiting = .transient
            nextRetryTime = now + 10
            onStatus("Microphone unavailable. Retrying…")
            return
        }
        recentRetainedRestarts.append(now)
        isConnected = false
        onProcessingState(false)
        onStatus(hasConnected ? "Reconnecting microphone…" : "Starting microphone…")
        let token = lifetime
        connectionTask = Task { @MainActor [weak self, target] in
            guard let self else { return }
            var rebuild = false
            defer {
                if self.lifetime == token {
                    self.connectionTask = nil
                    if rebuild {
                        self.needsRecheck = false
                        self.requestConnection()
                    } else if self.needsRecheck {
                        self.needsRecheck = false
                        self.handleConfigurationNotice()
                    }
                }
            }
            let restartTarget = NativeMicrophoneRestartTarget(engine: target)
            do {
                try await MicrophoneEngineRestart.perform(on: restartTarget, shouldContinue: { [weak self] in
                    guard let self, self.alive, self.lifetime == token, self.engine === target,
                          let installed = self.installed else { return false }
                    let current = MicrophoneConfigurationSnapshot.read(engine: target,
                                                                        includesSpeakerReference: self.wantsEchoReduction)
                    let decision = MicrophoneConfigurationPolicy.decision(installed: installed, current: current,
                                                                          requiresVoiceProcessing: self.wantsEchoReduction)
                    if decision == .reconnect || decision == .waitForDevice {
                        self.needsRecheck = true
                        return false
                    }
                    return true
                })
                guard self.alive, self.lifetime == token, self.engine === target,
                      let installed = self.installed else { return }
                let live = MicrophoneConfigurationSnapshot.read(engine: target,
                                                               includesSpeakerReference: self.wantsEchoReduction)
                guard MicrophoneConfigurationPolicy.decision(installed: installed, current: live,
                          requiresVoiceProcessing: self.wantsEchoReduction) == .unchanged else {
                    self.needsRecheck = true
                    return
                }
                self.installed = live
                self.waiting = .none
                self.nextRetryTime = 0
                self.isConnected = true
                self.hasConnected = true
                self.onProcessingState(self.wantsEchoReduction && live.voiceProcessingEnabled)
                self.onStatus(nil)
                self.resolveReadiness()
                let identity = String(describing: ObjectIdentifier(target))
                self.logger.notice("Microphone retained-engine restart succeeded: engine=\(identity, privacy: .public) running=\(live.isRunning) voice=\(live.voiceProcessingEnabled)")
            } catch is CancellationError {
                // Cancellation or a new route is handled by the generation guard/recheck.
            } catch {
                guard self.alive, self.lifetime == token, self.engine === target else { return }
                let nativeError = error as NSError
                self.logger.error("Microphone setup error: stage=restart retained engine domain=\(nativeError.domain, privacy: .public) code=\(nativeError.code)")
                rebuild = true
            }
        }
    }

    private func requestConnection() {
        guard alive else { return }
        if connectionTask != nil { needsRecheck = true; return }
        let desired = ConnectionGoal(route: .current(includesSpeakerReference: wantsEchoReduction),
                                     echoReduction: wantsEchoReduction)
        if desired != goal { recentAttempts.removeAll() }
        goal = desired
        detachHardware()
        guard desired.route.hasInput else {
            waiting = .noDevice
            onStatus("Waiting for a microphone…")
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        recentAttempts.removeAll { now - $0 > 5 }
        guard recentAttempts.count < 6 else {
            waiting = .transient
            nextRetryTime = now + 10
            onStatus("Microphone unavailable. Retrying…")
            return
        }
        onStatus(hasConnected ? "Reconnecting microphone…"
            : waiting == .transient ? "Microphone unavailable. Retrying…" : "Starting microphone…")
        let token = lifetime
        connectionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.lifetime == token {
                    self.connectionTask = nil
                    if self.needsRecheck {
                        self.needsRecheck = false
                        self.handleConfigurationNotice()
                    }
                }
            }
            for attempt in 0..<3 {
                if attempt > 0 {
                    do { try await Task.sleep(for: .milliseconds(attempt == 1 ? 160 : 500)) }
                    catch { return }
                }
                guard self.alive, self.lifetime == token, !Task.isCancelled else { return }
                let currentGoal = ConnectionGoal(route: .current(includesSpeakerReference: self.wantsEchoReduction),
                                                 echoReduction: self.wantsEchoReduction)
                self.goal = currentGoal
                guard currentGoal.route.hasInput else {
                    self.waiting = .noDevice
                    self.onStatus("Waiting for a microphone…")
                    return
                }
                self.recentAttempts.append(ProcessInfo.processInfo.systemUptime)
                do {
                    try await self.connect(goal: currentGoal, token: token)
                    self.waiting = .none
                    self.onStatus(nil)
                    return
                } catch AudioTranscriptionError.speakerEchoReductionUnavailable {
                    guard self.alive, self.lifetime == token, !Task.isCancelled else { return }
                    self.detachHardware()
                    if attempt < 2 { continue }
                    self.waiting = .echoReduction
                    self.nextRetryTime = ProcessInfo.processInfo.systemUptime + 30
                    self.onStatus(AudioTranscriptionError.speakerEchoReductionUnavailable.localizedDescription)
                    return
                } catch {
                    guard self.alive, self.lifetime == token, !Task.isCancelled else { return }
                    self.detachHardware()
                    if attempt == 2 {
                        self.waiting = .transient
                        self.nextRetryTime = ProcessInfo.processInfo.systemUptime + 10
                        self.onStatus("Microphone unavailable. Retrying…")
                    }
                }
            }
        }
    }

    private func connect(goal: ConnectionGoal, token: UUID) async throws {
        try Task.checkCancellation()
        guard alive, lifetime == token, wantsEchoReduction == goal.echoReduction else { throw CancellationError() }
        let began = ProcessInfo.processInfo.systemUptime
        let candidate = AVAudioEngine()
        logSetupStage("engine.created", since: began)
        var candidateTapInstalled = false
        var candidateGraphID: UUID?
        var stage = "enable voice processing"
        var formatDetails = "echoReduction=\(goal.echoReduction) inputDevice=\(goal.route.inputDeviceID) outputDevice=\(goal.route.outputDeviceID)"
        AudioCaptureDiagnostics.connectionStage(stage, details: formatDetails)
        do {
            logSetupStage("voice.configure.requested", since: began)
            try SpeakerEchoReduction.configure(VoiceProcessingEngineConfiguration(engine: candidate),
                                                requested: goal.echoReduction)
            logSetupStage("voice.configure.ready", since: began)
            let node = candidate.inputNode
            let nativeFormat = node.outputFormat(forBus: 0)
            formatDetails += " nativeInput=\(AudioCaptureDiagnostics.describe(nativeFormat))"
            let initializedOutput: (node: AVAudioOutputNode, format: AVAudioFormat)?
            if goal.echoReduction {
                // Materialize and inspect the voice-processing output before building the
                // mixer graph, following Apple's native voice-processing setup order.
                let output = candidate.outputNode
                let outputFormat = output.inputFormat(forBus: 0)
                initializedOutput = (output, outputFormat)
                formatDetails += " initialOutput=\(AudioCaptureDiagnostics.describe(outputFormat))"
            } else {
                initializedOutput = nil
            }
            AudioCaptureDiagnostics.connectionStage("voice processing configured", details: formatDetails)
            logSetupStage("voice.io.ready", since: began)
            guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else { throw ConnectionError.noDevice }
            let format: AVAudioFormat
            if let initializedOutput {
                // Match input/output voice-I/O formats and give VPIO a real render clock.
                // Digital silence is the only signal generated by this output graph.
                format = try VoiceProcessingOutput.voiceFormat(sampleRate: nativeFormat.sampleRate)
                stage = "connect silent output graph"
                formatDetails += " requestedVoice=\(AudioCaptureDiagnostics.describe(format))"
                AudioCaptureDiagnostics.connectionStage(stage, details: formatDetails)
                logSetupStage("graph.requested", since: began)
                try withExtendedLifetime(initializedOutput.format) {
                    try VoiceProcessingOutput.attach(to: candidate, output: initializedOutput.node, format: format)
                }
                logSetupStage("graph.ready", since: began)
                logSetupStage("unmute.requested", since: began)
                if node.isVoiceProcessingInputMuted { node.isVoiceProcessingInputMuted = false }
                logSetupStage("unmute.ready", since: began)
            } else {
                format = nativeFormat
            }
            let tapFormat = MicrophoneFormatSignature(format: format)
            stage = "install microphone tap"
            logSetupStage("diagnostics.preTap.requested", since: began)
            if AudioCaptureDiagnostics.isEnabled {
                formatDetails += " tapRequested=\(AudioCaptureDiagnostics.describe(format)) preTapInput=\(AudioCaptureDiagnostics.describe(node.outputFormat(forBus: 0)))"
                if goal.echoReduction {
                    formatDetails += " graphOutput=\(AudioCaptureDiagnostics.describe(candidate.outputNode.inputFormat(forBus: 0)))"
                }
                AudioCaptureDiagnostics.connectionStage(stage, details: formatDetails)
            }
            logSetupStage("diagnostics.preTap.ready", since: began)
            let graphID = UUID()
            candidateGraphID = graphID
            activeTapID = graphID
            receivedFirstBuffer = false
            destination.selectGraph(graphID)
            let tap = MicrophoneTapDestination.makeTap(destination: destination, graphID: graphID)
            logSetupStage("tap.requested", since: began)
            if #available(macOS 27, *) {
                try node.__installTap(onBus: 0, bufferSize: 4096, format: format,
                                      error: (), block: tap)
            } else {
                node.installTap(onBus: 0, bufferSize: 4096, format: format, block: tap)
            }
            candidateTapInstalled = true
            logSetupStage("tap.ready", since: began)
            stage = "prepare microphone engine"
            logSetupStage("diagnostics.postTap.requested", since: began)
            if AudioCaptureDiagnostics.isEnabled {
                AudioCaptureDiagnostics.connectionStage(stage, details: "postTapInput=\(AudioCaptureDiagnostics.describe(node.outputFormat(forBus: 0)))")
            }
            logSetupStage("diagnostics.postTap.ready", since: began)
            logSetupStage("prepare.requested", since: began)
            candidate.prepare()
            logSetupStage("prepare.ready", since: began)
            stage = "start microphone engine"
            AudioCaptureDiagnostics.connectionStage(stage)
            logSetupStage("hardware.start.requested", since: began)
            do { try candidate.start() }
            catch {
                let nativeError = error as NSError
                logger.error("Microphone setup error: stage=\(stage, privacy: .public) domain=\(nativeError.domain, privacy: .public) code=\(nativeError.code)")
                AudioCaptureDiagnostics.connectionStage(stage, details: formatDetails, error: error)
                if goal.echoReduction { throw AudioTranscriptionError.speakerEchoReductionUnavailable }
                throw error
            }
            logSetupStage("hardware.start.ready", since: began)
            stage = "validate running microphone"
            var live = MicrophoneConfigurationSnapshot.read(engine: candidate, includesSpeakerReference: goal.echoReduction)
            formatDetails += " liveInput=\(String(describing: live.format)) running=\(live.isRunning) liveVoice=\(live.voiceProcessingEnabled) boundInput=\(live.boundInputDeviceID) boundOutput=\(live.boundOutputDeviceID)"
            AudioCaptureDiagnostics.connectionStage(stage, details: formatDetails)
            var decision = MicrophoneConfigurationPolicy.initialDecision(route: goal.route, format: tapFormat,
                requiresVoiceProcessing: goal.echoReduction, current: live)
            logInitialValidation(live, goal: goal, format: tapFormat, decision: decision)
            if decision == .restart {
                rearmReadiness()
                stage = "restart stopped initial microphone"
                try await MicrophoneEngineRestart.perform(on: NativeMicrophoneRestartTarget(engine: candidate),
                    shouldContinue: { [weak self] in
                        guard let self, self.alive, self.lifetime == token,
                              self.wantsEchoReduction == goal.echoReduction else { return false }
                        let current = MicrophoneConfigurationSnapshot.read(engine: candidate,
                            includesSpeakerReference: goal.echoReduction)
                        let decision = MicrophoneConfigurationPolicy.initialDecision(route: goal.route,
                            format: tapFormat, requiresVoiceProcessing: goal.echoReduction, current: current)
                        return decision == .unchanged || decision == .restart
                    })
                live = MicrophoneConfigurationSnapshot.read(engine: candidate,
                    includesSpeakerReference: goal.echoReduction)
                decision = MicrophoneConfigurationPolicy.initialDecision(route: goal.route, format: tapFormat,
                    requiresVoiceProcessing: goal.echoReduction, current: live)
                logInitialValidation(live, goal: goal, format: tapFormat, decision: decision)
                let identity = String(describing: ObjectIdentifier(candidate))
                if decision == .unchanged {
                    logger.notice("Microphone initial retained-engine restart succeeded: engine=\(identity, privacy: .public)")
                }
            }
            try Task.checkCancellation()
            guard alive, lifetime == token, wantsEchoReduction == goal.echoReduction else { throw CancellationError() }
            guard decision == .unchanged else {
                if live.inputDeviceID == goal.route.inputDeviceID,
                   live.outputDeviceID == goal.route.outputDeviceID,
                   live.format == tapFormat, live.isRunning,
                   goal.echoReduction, !live.voiceProcessingEnabled {
                    throw AudioTranscriptionError.speakerEchoReductionUnavailable
                }
                throw ConnectionError.changing
            }
            engine = candidate
            tapInstalled = true
            installedTapID = graphID
            installed = live
            isConnected = true
            hasConnected = true
            onProcessingState(goal.echoReduction && live.voiceProcessingEnabled)
            // Installing this after start avoids treating graph construction as an external change.
            installEngineObserver(candidate)
            resolveReadiness()
            log(live, decision: .unchanged)
            logSetupStage("candidate.accepted", since: began)
        } catch {
            let nativeError = error as NSError
            logger.error("Microphone setup error: stage=\(stage, privacy: .public) domain=\(nativeError.domain, privacy: .public) code=\(nativeError.code)")
            AudioCaptureDiagnostics.connectionStage(stage, details: formatDetails, error: error)
            candidate.stop()
            if candidateTapInstalled { candidate.inputNode.removeTap(onBus: 0) }
            if let candidateGraphID, activeTapID == candidateGraphID {
                activeTapID = nil
                receivedFirstBuffer = false
                destination.selectGraph(nil)
            }
            throw error
        }
    }

    private func logSetupStage(_ stage: String, since began: TimeInterval) {
        guard captureMetricsEnabled else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        logger.notice("Microphone native setup: stage=\(stage, privacy: .public) elapsed=\(elapsed)")
    }

    private func logInitialValidation(_ current: MicrophoneConfigurationSnapshot, goal: ConnectionGoal,
                                      format: MicrophoneFormatSignature,
                                      decision: MicrophoneConfigurationDecision) {
        guard decision != .unchanged else { return }
        let inputMatches = current.inputDeviceID == goal.route.inputDeviceID
        let outputMatches = current.outputDeviceID == goal.route.outputDeviceID
        let formatMatches = current.format == format
        let voiceMatches = current.voiceProcessingEnabled == goal.echoReduction
        let expectedRoute = String(describing: goal.route)
        let expectedFormat = String(describing: format)
        let snapshot = String(describing: current)
        logger.error("Microphone initial validation: decision=\(String(describing: decision), privacy: .public) inputMatches=\(inputMatches) outputMatches=\(outputMatches) formatMatches=\(formatMatches) voiceMatches=\(voiceMatches) running=\(current.isRunning) expectedRoute=[\(expectedRoute, privacy: .public)] expectedFormat=[\(expectedFormat, privacy: .public)] current=[\(snapshot, privacy: .public)]")
    }

    private func detachHardware() {
        isConnected = false
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = nil
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        engine = nil
        installed = nil
        installedTapID = nil
        activeTapID = nil
        rearmReadiness()
        destination.selectGraph(nil)
        recentRetainedRestarts.removeAll()
        onProcessingState(false)
    }

    private func installEngineObserver(_ engine: AVAudioEngine) {
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver) }
        engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                                                object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleConfigurationNotice() }
        }
    }

    private func addRouteListeners() {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice,
                         kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            let block = Self.routeListener { [weak self] in self?.handleConfigurationNotice() }
            let result = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            if result == noErr { listeners.append((address, block)) }
        }
        // The low-frequency monitor remains as a fallback for devices that omit a HAL notification.
    }

    nonisolated private static func routeListener(_ changed: @escaping @MainActor @Sendable () -> Void) -> AudioObjectPropertyListenerBlock {
        { @Sendable _, _ in Task { @MainActor in changed() } }
    }

    private func log(_ snapshot: MicrophoneConfigurationSnapshot, decision: MicrophoneConfigurationDecision) {
        if decision != .unchanged {
            // Use only the snapshots already read by the recovery decision. In particular,
            // diagnostics here must not query or initialize any additional audio nodes.
            let original = String(describing: installed)
            let current = String(describing: snapshot)
            let elapsed = recentAttempts.last.map { ProcessInfo.processInfo.systemUptime - $0 } ?? -1
            logger.error("Microphone invalidation: decision=\(String(describing: decision), privacy: .public) sinceAttempt=\(elapsed) requestedVoice=\(self.wantsEchoReduction) installed=[\(original, privacy: .public)] current=[\(current, privacy: .public)]")
        }
        #if DEBUG
        if AudioCaptureDiagnostics.isEnabled, let engine {
            let now = ProcessInfo.processInfo.systemUptime
            let sinceAttempt = recentAttempts.last.map { now - $0 } ?? -1
            let retryIn = max(0, nextRetryTime - now)
            let recentCount = recentAttempts.filter { now - $0 <= 5 }.count
            var changed: [String] = []
            if let installed {
                if installed.inputDeviceID != snapshot.inputDeviceID { changed.append("physicalInput") }
                if installed.outputDeviceID != snapshot.outputDeviceID { changed.append("physicalOutput") }
                if installed.boundInputDeviceID != snapshot.boundInputDeviceID { changed.append("boundInput") }
                if installed.boundOutputDeviceID != snapshot.boundOutputDeviceID { changed.append("boundOutput") }
                if installed.format != snapshot.format { changed.append("format") }
                if installed.isRunning != snapshot.isRunning { changed.append("running") }
                if installed.voiceProcessingEnabled != snapshot.voiceProcessingEnabled { changed.append("voice") }
            } else {
                changed.append("noInstalledSnapshot")
            }
            func describe(_ value: MicrophoneConfigurationSnapshot) -> String {
                "physicalInput=\(value.inputDeviceID),physicalOutput=\(value.outputDeviceID),boundInput=\(value.boundInputDeviceID),boundOutput=\(value.boundOutputDeviceID),running=\(value.isRunning),voice=\(value.voiceProcessingEnabled),rate=\(value.format.sampleRate),channels=\(value.format.channelCount),formatID=\(value.format.formatID),flags=\(value.format.formatFlags),bytesPerFrame=\(value.format.bytesPerFrame),interleaved=\(value.format.interleaved)"
            }
            let original = installed.map(describe) ?? "none"
            let current = describe(snapshot)
            let changes = changed.isEmpty ? "none" : changed.joined(separator: ",")
            logger.info("Microphone transition: decision=\(String(describing: decision), privacy: .public) changes=\(changes, privacy: .public) sinceAttempt=\(sinceAttempt) retryIn=\(retryIn) recentAttempts=\(recentCount) waiting=\(String(describing: self.waiting), privacy: .public) requestedVoice=\(self.wantsEchoReduction) installed=[\(original, privacy: .public)] current=[\(current, privacy: .public)]")
            let node = engine.inputNode
            logger.info("Microphone hardware: decision=\(String(describing: decision), privacy: .public) running=\(snapshot.isRunning) rate=\(snapshot.format.sampleRate) channels=\(snapshot.format.channelCount) defaultInput=\(snapshot.inputDeviceID) defaultOutput=\(snapshot.outputDeviceID) boundInput=\(snapshot.boundInputDeviceID) boundOutput=\(snapshot.boundOutputDeviceID) voice=\(snapshot.voiceProcessingEnabled) muted=\(node.isVoiceProcessingInputMuted) bypassed=\(node.isVoiceProcessingBypassed) agc=\(node.isVoiceProcessingAGCEnabled)")
        }
        logger.debug("Microphone state: decision=\(String(describing: decision), privacy: .public) running=\(snapshot.isRunning) rate=\(snapshot.format.sampleRate) channels=\(snapshot.format.channelCount) input=\(snapshot.inputDeviceID) output=\(snapshot.outputDeviceID) boundInput=\(snapshot.boundInputDeviceID) boundOutput=\(snapshot.boundOutputDeviceID) voice=\(snapshot.voiceProcessingEnabled)")
        #endif
    }
}

@MainActor
private final class NativeMicrophoneRestartTarget: MicrophoneRestartTarget {
    private let engine: AVAudioEngine
    init(engine: AVAudioEngine) { self.engine = engine }
    var isRunning: Bool { engine.isRunning }
    func start() throws { try engine.start() }
}
