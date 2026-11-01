#if DEBUG
@preconcurrency import AVFoundation
import AudioToolbox
import CoreGraphics
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import Relay

/// Explicit hardware opt-in only. The probe records counts, clocks, and format
/// metadata; it never copies or reads sample values, recognizes speech, or saves audio.
@Suite("Native microphone recovery integration", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_MICROPHONE_INTEGRATION"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_UI_TESTING"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_ECHO_INTEGRATION"] != "1"))
@MainActor
struct MicrophoneHardwareIntegrationTests {
    @Test("Raw-to-voice capture recovers and resumes a silent paused graph without changing destinations", .timeLimit(.minutes(3)))
    func nativeGraphRestartPreservesTapDelivery() async throws {
        try await NativeMicrophoneTestAccess.acquire()
        defer { NativeMicrophoneTestAccess.release() }
        #expect(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                "This opt-in test requires microphone access already granted to its signed app host.")
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw HardwareProbeError.permissionRequired
        }
        guard MicrophoneDeviceRoute.current(includesSpeakerReference: false).hasInput else {
            Issue.record("Connect a microphone before explicitly running the hardware regression.")
            throw HardwareProbeError.noMicrophone
        }

        // Reproduce the real transition: a raw microphone is first opened and
        // closed, then the native voice-processing graph is created.
        let rawProbe = MicrophoneMetadataProbe()
        let raw = MicrophoneCaptureController(pipeline: rawProbe, reducesSpeakerEcho: false,
            onStatus: { _ in }, onProcessingState: { _ in })
        defer { raw.stop() }
        raw.start()
        try await waitUntil("The raw microphone must deliver actual tap buffers.") {
            raw.isConnected && rawProbe.snapshot().bufferCount >= 3
        }
        try await Task.sleep(for: .seconds(1))
        let rawSnapshot = rawProbe.snapshot()
        #expect(rawSnapshot.frames > 0 && rawSnapshot.invalidBuffers == 0)
        raw.stop()

        let voiceProbe = MicrophoneMetadataProbe()
        let voice = MicrophoneCaptureController(pipeline: voiceProbe, reducesSpeakerEcho: true,
            onStatus: { _ in }, onProcessingState: { _ in })
        defer { voice.stop() }
        voice.start()
        try await waitUntil("The voice-processing microphone must deliver actual tap buffers.") {
            voice.isConnected && voiceProbe.snapshot().bufferCount >= 3
        }
        let retainedEngine = try #require(voice.engineForTesting)
        let retainedIdentity = ObjectIdentifier(retainedEngine)
        let initialBuffers = voiceProbe.snapshot().bufferCount

        // More than ten two-second monitor cycles must preserve the actual
        // graph and incoming audio, not merely report engine.isRunning.
        try await observe(voice, engine: retainedEngine, probe: voiceProbe, for: 30)
        #expect(voiceProbe.snapshot().bufferCount > initialBuffers + 20)

        let beforeStop = voiceProbe.snapshot().bufferCount
        retainedEngine.stop()
        #expect(!retainedEngine.isRunning)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: retainedEngine)
        try await waitUntil("The retained engine must restart and resume actual microphone callbacks.") {
            guard let current = voice.engineForTesting else { return false }
            let sample = voiceProbe.snapshot()
            return ObjectIdentifier(current) == retainedIdentity && current.isRunning && voice.isConnected &&
                sample.bufferCount >= beforeStop + 3 && sample.lastArrivalAge < 2
        }
        #expect(voice.engineForTesting === retainedEngine)
        try await observe(voice, engine: retainedEngine, probe: voiceProbe, for: 10)

        let completed = voiceProbe.snapshot()
        #expect(completed.frames > 0 && completed.invalidBuffers == 0)
        #expect(completed.unexpectedSampleBuffers == 0)
        #expect(completed.maxArrivalGap < 5,
                "A running flag must not hide stalled microphone callbacks.")
        #expect(completed.lastHostTime?.isFinite == true)
        #expect((completed.lastFormat?.sampleRate ?? 0) > 0)
        #expect((completed.lastFormat?.channelCount ?? 0) > 0)

        // A cached graph must stop microphone delivery completely while idle.
        // A configuration notice and multiple old monitor intervals must not
        // quietly restart hardware or keep the previous document's sink alive.
        await voice.pause()
        let pausedBuffers = voiceProbe.snapshot().bufferCount
        #expect(voice.engineForTesting === retainedEngine)
        #expect(!retainedEngine.isRunning && !voice.isConnected)
        #expect(try nativeUnitRunning(retainedEngine) == 0,
                "Pausing must stop the underlying voice I/O unit, not only close its transcript sink.")
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: retainedEngine)
        try await Task.sleep(for: .seconds(5))
        #expect(voice.engineForTesting === retainedEngine)
        #expect(!retainedEngine.isRunning && !voice.isConnected)
        #expect(try nativeUnitRunning(retainedEngine) == 0)
        #expect(voiceProbe.snapshot().bufferCount == pausedBuffers,
                "Paused hardware must not forward audio to its old transcript.")
        do {
            try await voice.waitUntilReady()
            Issue.record("An inactive controller must not report capture readiness.")
        } catch {
            #expect(error is CancellationError)
        }

        // Reuse exactly the same prepared graph for a distinct recognizer. Its
        // readiness must belong to an actual buffer sent to the new binding.
        let resumedProbe = MicrophoneMetadataProbe()
        voice.rebind(pipeline: resumedProbe, onStatus: { _ in }, onProcessingState: { _ in })
        let resumeRequestedAt = ProcessInfo.processInfo.systemUptime
        voice.start()
        let readiness = HardwareReadinessProbe()
        let waitForReadiness = Task { @MainActor in
            do {
                try await voice.waitUntilReady()
                readiness.resolved(hasBuffer: resumedProbe.snapshot().bufferCount > 0)
            } catch {
                readiness.failed()
            }
        }
        defer { waitForReadiness.cancel() }
        try await waitUntil("A warm graph must become ready only after delivering a new microphone buffer.") {
            readiness.snapshot().resolved
        }
        let warmReadySeconds = ProcessInfo.processInfo.systemUptime - resumeRequestedAt
        let ready = readiness.snapshot()
        #expect(!ready.failed && ready.hasBuffer)
        #expect(voice.engineForTesting === retainedEngine)
        #expect(retainedEngine.isRunning && voice.isConnected)
        #expect(try nativeUnitRunning(retainedEngine) == 1)
        try await observe(voice, engine: retainedEngine, probe: resumedProbe, for: 5)
        #expect(voiceProbe.snapshot().bufferCount == pausedBuffers,
                "Rebound capture must never deliver more audio to the previous transcript.")
        #expect(resumedProbe.snapshot().frames > 0 && resumedProbe.snapshot().invalidBuffers == 0)
        await waitForReadiness.value
        print("Native microphone regression: rawBuffers=\(rawSnapshot.bufferCount) voiceBuffers=\(completed.bufferCount) voiceFrames=\(completed.frames) maxCallbackGap=\(completed.maxArrivalGap) engineRetained=true pausedSilent=true reboundBuffers=\(resumedProbe.snapshot().bufferCount) warmReadinessSeconds=\(warmReadySeconds)")
    }

    private func observe(_ controller: MicrophoneCaptureController, engine: AVAudioEngine,
                         probe: MicrophoneMetadataProbe, for seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(250))
            guard controller.engineForTesting === engine else {
                Issue.record("An unchanged microphone route must not rebuild the voice-processing graph.")
                throw HardwareProbeError.engineReplaced
            }
            guard probe.snapshot().lastArrivalAge < 5 else {
                Issue.record("The retained native graph stopped delivering microphone buffers.")
                throw HardwareProbeError.callbacksStalled
            }
        }
        #expect(controller.isConnected && engine.isRunning)
    }

    private func nativeUnitRunning(_ engine: AVAudioEngine) throws -> UInt32 {
        let unit = try #require(engine.inputNode.audioUnit,
                                "The native voice input must expose its I/O Audio Unit.")
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_IsRunning,
                                         kAudioUnitScope_Global, 0, &running, &size)
        try #require(status == noErr, "The native I/O unit must report its running state.")
        try #require(size == UInt32(MemoryLayout<UInt32>.size))
        return running
    }

    private func waitUntil(_ message: String, _ condition: @MainActor () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("\(message)")
        throw HardwareProbeError.timedOut
    }
}

/// An additional explicit opt-in because this check plays a fictional fixture
/// over the selected speakers. Only energy/count metadata survives each buffer.
/// It measures the whole native processing chain, not isolated AEC ERLE.
@Suite("Native speaker echo processing metrics", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_MICROPHONE_INTEGRATION"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_UI_TESTING"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_ECHO_INTEGRATION"] == "1"))
@MainActor
struct MicrophoneEchoHardwareIntegrationTests {
    @Test("Cold and retained warm graphs reduce the same speaker fixture", .timeLimit(.minutes(3)))
    func coldAndWarmSpeakerResidualEnergy() async throws {
        try await NativeMicrophoneTestAccess.acquire()
        defer { NativeMicrophoneTestAccess.release() }
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                     "This explicit hardware check requires existing microphone permission.")
        try #require(MicrophoneDeviceRoute.current(includesSpeakerReference: true).hasInput)
        let bundle = Bundle(for: HardwareFixtureBundle.self)
        let fixture = try #require(bundle.url(forResource: "English", withExtension: "aiff", subdirectory: "Fixtures")
            ?? bundle.url(forResource: "English", withExtension: "aiff"))
        let player = try AVAudioPlayer(contentsOf: fixture)
        player.volume = 0.25
        player.numberOfLoops = -1
        try #require(player.prepareToPlay())
        let coldProbe = MicrophoneEnergyProbe()
        let controller = MicrophoneCaptureController(pipeline: coldProbe, reducesSpeakerEcho: true,
            onStatus: { _ in }, onProcessingState: { _ in })
        defer { player.stop(); controller.stop() }
        controller.start()
        try await controller.waitUntilReady()
        let engine = try #require(controller.engineForTesting)
        try #require(engine.inputNode.isVoiceProcessingEnabled)
        try #require(AVCaptureDevice.activeMicrophoneMode == .standard,
                     "Select Standard Mic Mode before this comparison; other modes override the bypass control.")

        // Playback is deliberately outside this engine's graph. No SCK audio is
        // replayed into the voice I/O downlink, whose output remains silence.
        // Disable AGC for this measurement only: otherwise processed signal
        // gain changes also amplify its noise floor relative to the bypass.
        engine.inputNode.isVoiceProcessingAGCEnabled = false
        try #require(!engine.inputNode.isVoiceProcessingAGCEnabled)
        engine.inputNode.isVoiceProcessingBypassed = true
        try #require(engine.inputNode.isVoiceProcessingBypassed)
        let baseline = try await measureFixture(player, probe: coldProbe, controller: controller,
                                                engine: engine, phase: "bypassed")
        engine.inputNode.isVoiceProcessingBypassed = false
        try #require(!engine.inputNode.isVoiceProcessingBypassed)
        try #require(!engine.inputNode.isVoiceProcessingAGCEnabled)
        let cold = try await measureFixture(player, probe: coldProbe, controller: controller,
                                            engine: engine, phase: "coldProcessed")

        await controller.pause()
        let warmProbe = MicrophoneEnergyProbe()
        controller.rebind(pipeline: warmProbe, onStatus: { _ in }, onProcessingState: { _ in })
        controller.start()
        try await controller.waitUntilReady()
        try #require(controller.engineForTesting === engine,
                     "The warm comparison must use the same prepared native graph.")
        try #require(!engine.inputNode.isVoiceProcessingBypassed)
        try #require(!engine.inputNode.isVoiceProcessingAGCEnabled)
        try #require(AVCaptureDevice.activeMicrophoneMode == .standard)
        let warm = try await measureFixture(player, probe: warmProbe, controller: controller,
                                            engine: engine, phase: "warmProcessed")

        #expect(baseline.speech.sampleCount > 10_000 && cold.speech.sampleCount > 10_000 && warm.speech.sampleCount > 10_000)
        #expect(baseline.speech.invalidFormats == 0 && cold.speech.invalidFormats == 0 && warm.speech.invalidFormats == 0)
        try #require(baseline.excessPower > 1e-8,
                     "The speakers must be audible above the room noise; check output route and volume before rerunning.")
        let coldToBaseline = cold.excessPower / baseline.excessPower
        let warmToBaseline = warm.excessPower / baseline.excessPower
        let warmToCold = warm.excessPower / max(cold.excessPower, baseline.excessPower * 0.005)
        print("Native echo metrics: mode=Standard agc=false bypassRMS=\(baseline.speech.rms) coldRMS=\(cold.speech.rms) warmRMS=\(warm.speech.rms) bypassNoiseRMS=\(baseline.noise.rms) coldNoiseRMS=\(cold.noise.rms) warmNoiseRMS=\(warm.noise.rms) coldResidualPowerRatio=\(coldToBaseline) warmResidualPowerRatio=\(warmToBaseline) warmToColdPowerRatio=\(warmToCold) sameGraph=true externalGraphPlayback=true")
        #expect(coldToBaseline < 0.5,
                "Native processing must measurably reduce speaker-fixture energy; enabled=true alone is insufficient.")
        #expect(warmToBaseline < 0.5)
        #expect(warmToCold <= 2,
                "Warm reuse must not worsen residual speaker power by more than 3 dB, allowing a -23 dB baseline floor.")
    }

    private func measureFixture(_ player: AVAudioPlayer, probe: MicrophoneEnergyProbe,
                                controller: MicrophoneCaptureController, engine: AVAudioEngine,
                                phase: String) async throws -> EchoMeasurement {
        player.stop()
        player.currentTime = 0
        let beforeSettling = probe.health().bufferCount
        print("Native echo window: phase=\(phase) stage=settling uptime=\(ProcessInfo.processInfo.systemUptime) agc=false")
        try await Task.sleep(for: .seconds(5))
        try await controller.waitUntilReady()
        try requireLiveCapture(controller, engine: engine, probe: probe)
        try #require(probe.health().bufferCount > beforeSettling,
                     "Native microphone callbacks must continue after the test-only property changes.")
        try #require(!engine.inputNode.isVoiceProcessingAGCEnabled)
        print("Native echo window: phase=\(phase) stage=noiseStart uptime=\(ProcessInfo.processInfo.systemUptime) agc=false")
        probe.beginWindow()
        try await Task.sleep(for: .seconds(1))
        let noise = probe.endWindow()
        try requireLiveCapture(controller, engine: engine, probe: probe)
        try #require(player.play(), "The bundled fictional fixture must actually start playback.")
        defer { player.stop() }
        // Let native adaptation settle, then sample the identical eight-second
        // fixture interval for every processing state without saving PCM.
        try await Task.sleep(for: .seconds(2))
        try requireLiveCapture(controller, engine: engine, probe: probe)
        print("Native echo window: phase=\(phase) stage=speechStart uptime=\(ProcessInfo.processInfo.systemUptime) agc=false")
        let firstBuffer = probe.health().bufferCount
        probe.beginWindow()
        for _ in 0..<32 {
            try await Task.sleep(for: .milliseconds(250))
            try requireLiveCapture(controller, engine: engine, probe: probe)
        }
        let speech = probe.endWindow()
        try #require(probe.health().bufferCount > firstBuffer + 10)
        try #require(!engine.inputNode.isVoiceProcessingAGCEnabled)
        let measurement = EchoMeasurement(noise: noise, speech: speech)
        print("Native echo window: phase=\(phase) stage=speechEnd uptime=\(ProcessInfo.processInfo.systemUptime) buffers=\(probe.health().bufferCount - firstBuffer) noiseRMS=\(noise.rms) speechRMS=\(speech.rms) excessPower=\(measurement.excessPower) agc=false")
        return measurement
    }

    private func requireLiveCapture(_ controller: MicrophoneCaptureController,
                                    engine: AVAudioEngine, probe: MicrophoneEnergyProbe) throws {
        try #require(controller.engineForTesting === engine,
                     "A processing comparison must retain the same native engine.")
        try #require(engine.isRunning && controller.isConnected)
        try #require(probe.health().lastArrivalAge < 2,
                     "Residual energy must come from fresh native microphone buffers.")
    }
}

/// Exercises the production service's controller cache rather than an isolated
/// engine. No transcript callback, document store, or audio-file writer is used.
@Suite("Native microphone service lifecycle", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_MICROPHONE_INTEGRATION"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_UI_TESTING"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_ECHO_INTEGRATION"] != "1"))
@MainActor
struct MicrophoneServiceLifecycleIntegrationTests {
    @Test("Cold and switched microphone capture retain echo reference without adding System transcripts", .timeLimit(.minutes(3)))
    func sourceModeSwitchesReachActualMicrophoneReadiness() async throws {
        try await NativeMicrophoneTestAccess.acquire()
        defer { NativeMicrophoneTestAccess.release() }
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                     "This explicit service regression requires existing microphone authorization.")
        try #require(CGPreflightScreenCaptureAccess(),
                     "Grant the signed host Screen & System Audio Recording access before opting in; this test never prompts.")
        try #require(MicrophoneDeviceRoute.current(includesSpeakerReference: false).hasInput)
        let service = TranscriptionService()
        service.reducesSpeakerEcho = true
        service.onUpdate = nil
        defer { service.cancel() }
        let steps: [(label: String, sources: Set<TranscriptSource>, preference: Bool, resetCache: Bool)] = [
            ("microphoneCold", [.microphone], true, false),
            ("bothCold", Set(TranscriptSource.allCases), true, true),
            ("microphoneAfterBoth", [.microphone], true, false),
            ("bothAfterMicrophone", Set(TranscriptSource.allCases), true, false),
            ("systemOnlyAfterBoth", [.systemAudio], true, false),
            ("microphoneColdInitiallyBypassed", [.microphone], false, true),
            ("bothAfterBypassedMicrophone", Set(TranscriptSource.allCases), true, false)
        ]
        for step in steps {
            if step.resetCache { service.cancel() }
            service.reducesSpeakerEcho = step.preference
            let requestedAt = ProcessInfo.processInfo.systemUptime
            // Cancelled steps have no retained native controller; other steps
            // exercise warm source switching through the production cache.
            try await service.start(sources: step.sources, locale: Locale(identifier: "en_US"))
            try #require(service.isRunning)
            try #require(service.captureReadyAt != nil,
                         "Start must complete its actual source readiness path, including the current first buffer whenever Microphone is selected.")
            #expect(service.transcriptionSourcesForTesting == step.sources,
                    "Reference-only System capture must not create a System recognizer or transcript source.")
            let hasMicrophone = step.sources.contains(.microphone)
            #expect(service.isSpeakerEchoReductionActive == (hasMicrophone && step.preference))
            if hasMicrophone {
                #expect(service.isSpeakerReferenceCaptureActiveForTesting == step.preference,
                        "A cold microphone-only bypass must not capture a speaker reference.")
                let readyAt = service.captureReadyAt
                service.reducesSpeakerEcho = false
                await service.waitForReferenceConfigurationForTesting()
                #expect(!service.isSpeakerEchoReductionActive)
                #expect(service.isRunning && service.captureReadyAt == readyAt,
                        "Changing AEC must not restart microphone capture or the session timer.")
                #expect(service.transcriptionSourcesForTesting == step.sources)
                if !step.sources.contains(.systemAudio) {
                    #expect(!service.isSpeakerReferenceCaptureActiveForTesting,
                            "Microphone-only bypass releases its unrequested System reference stream.")
                }
                service.reducesSpeakerEcho = true
                await service.waitForReferenceConfigurationForTesting()
                #expect(service.isSpeakerEchoReductionActive)
                #expect(service.isSpeakerReferenceCaptureActiveForTesting)
                #expect(service.isRunning && service.captureReadyAt == readyAt)
                #expect(service.transcriptionSourcesForTesting == step.sources,
                        "Enabling echo reduction adds a reference stream, not a System transcription lane.")
            } else {
                #expect(!service.isSpeakerEchoReductionActive && !service.isSpeakerReferenceCaptureActiveForTesting)
            }
            print("Native service lifecycle: phase=\(step.label) readySeconds=\(ProcessInfo.processInfo.systemUptime - requestedAt) actualMicrophoneBufferRequired=\(step.sources.contains(.microphone))")
            await service.stop()
            try #require(service.state == .idle,
                         "Each source configuration must finish draining before the next start.")
            #expect(service.transcriptionSourcesForTesting.isEmpty)
            #expect(!service.isSpeakerReferenceCaptureActiveForTesting)
        }
        #expect(!service.isRunning && !service.isBusy)
    }

    @Test("Rapid reference toggles and cancellation cannot disturb the next microphone-only generation", .timeLimit(.minutes(2)))
    func rapidReferenceChangesCannotInvalidateNextCapture() async throws {
        try await NativeMicrophoneTestAccess.acquire()
        defer { NativeMicrophoneTestAccess.release() }
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        try #require(CGPreflightScreenCaptureAccess(),
                     "This explicit native regression requires existing System Audio access and never prompts.")
        try #require(MicrophoneDeviceRoute.current(includesSpeakerReference: false).hasInput)
        let service = TranscriptionService()
        service.reducesSpeakerEcho = true
        service.onUpdate = nil
        defer { service.cancel() }
        try await service.start(sources: [.microphone], locale: Locale(identifier: "en_US"))
        let firstReadyAt = try #require(service.captureReadyAt)
        try #require(service.isRunning && service.isSpeakerEchoReductionActive)
        // Submit the whole burst before yielding. Superseded operations must
        // retire without disabling the final requested reference configuration.
        for preference in [false, true, false, true] {
            service.reducesSpeakerEcho = preference
        }
        await service.waitForReferenceConfigurationForTesting()
        #expect(service.isRunning && service.captureReadyAt == firstReadyAt)
        #expect(service.isSpeakerEchoReductionActive && service.isSpeakerReferenceCaptureActiveForTesting)
        #expect(service.transcriptionSourcesForTesting == [.microphone])

        service.reducesSpeakerEcho = false
        await service.waitForReferenceConfigurationForTesting()
        try #require(!service.isSpeakerReferenceCaptureActiveForTesting)
        #expect(service.isRunning && service.captureReadyAt == firstReadyAt)
        service.reducesSpeakerEcho = true
        // Allow the request to enter native asynchronous setup, but deliberately
        // do not wait for its completion before cancelling the old generation.
        await Task.yield()
        service.cancel()
        try await service.start(sources: [.microphone], locale: Locale(identifier: "en_US"))
        let secondReadyAt = try #require(service.captureReadyAt)
        await service.waitForReferenceConfigurationForTesting()
        try await Task.sleep(for: .milliseconds(200))
        #expect(secondReadyAt > firstReadyAt)
        #expect(service.state == .running && service.captureReadyAt == secondReadyAt,
                "An old reference candidate or late error must not clear the new capture's readiness.")
        #expect(service.isSpeakerEchoReductionActive && service.isSpeakerReferenceCaptureActiveForTesting)
        #expect(service.transcriptionSourcesForTesting == [.microphone],
                "Rapid reference maintenance must never create a System transcription lane.")
        await service.stop()
        #expect(service.state == .idle && !service.isBusy)
        #expect(service.transcriptionSourcesForTesting.isEmpty)
        #expect(!service.isSpeakerReferenceCaptureActiveForTesting)
    }

    @Test("Auto microphone-only capture uses a reference without creating a System transcription lane", .timeLimit(.minutes(2)))
    func automaticMicrophoneReferenceStaysSeparateFromTranscription() async throws {
        try await NativeMicrophoneTestAccess.acquire()
        defer { NativeMicrophoneTestAccess.release() }
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
        try #require(CGPreflightScreenCaptureAccess(),
                     "This explicit regression requires existing System Audio access and never prompts.")
        try #require(MicrophoneDeviceRoute.current(includesSpeakerReference: false).hasInput)
        let service = TranscriptionService()
        service.reducesSpeakerEcho = true
        service.onUpdate = nil
        defer { service.cancel() }
        try await service.startAuto(sources: [.microphone])
        try #require(service.isRunning && service.captureReadyAt != nil)
        let readyAt = service.captureReadyAt
        #expect(service.transcriptionSourcesForTesting == [.microphone],
                "Auto must not add a System bridge merely to obtain the echo reference.")
        #expect(service.isSpeakerEchoReductionActive && service.isSpeakerReferenceCaptureActiveForTesting)
        service.reducesSpeakerEcho = false
        await service.waitForReferenceConfigurationForTesting()
        #expect(!service.isSpeakerEchoReductionActive && !service.isSpeakerReferenceCaptureActiveForTesting)
        #expect(service.isRunning && service.captureReadyAt == readyAt)
        #expect(service.transcriptionSourcesForTesting == [.microphone])
        service.reducesSpeakerEcho = true
        await service.waitForReferenceConfigurationForTesting()
        #expect(service.isSpeakerEchoReductionActive && service.isSpeakerReferenceCaptureActiveForTesting)
        #expect(service.isRunning && service.captureReadyAt == readyAt)
        #expect(service.transcriptionSourcesForTesting == [.microphone])
        // This is a topology/readiness test, not a demand for narration in the
        // room. Silence may legitimately leave Auto without an identified language.
        await service.stop()
        if case .failed(let message) = service.state {
            #expect(message == AudioTranscriptionError.languageUncertain.localizedDescription)
        } else {
            #expect(service.state == .idle)
        }
        #expect(!service.isRunning && !service.isBusy)
        #expect(service.transcriptionSourcesForTesting.isEmpty)
        #expect(!service.isSpeakerReferenceCaptureActiveForTesting)
    }
}

/// Swift Testing serializes within a suite, not between independent suites.
/// Opt-in native cases must never compete for microphone/voice I/O hardware.
@MainActor
enum NativeMicrophoneTestAccess {
    private static var isInUse = false
    static func acquire() async throws {
        while isInUse {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        isInUse = true
    }
    static func release() { isInUse = false }
}

private struct EchoMeasurement {
    let noise: MicrophoneEnergyProbe.Energy
    let speech: MicrophoneEnergyProbe.Energy
    var excessPower: Double { max(0, speech.power - noise.power) }
}

private final class MicrophoneEnergyProbe: AudioTranscriptionPipeline, @unchecked Sendable {
    struct Energy: Sendable {
        var sampleCount: UInt64 = 0
        var squareSum = 0.0
        var invalidFormats = 0
        var power: Double { sampleCount == 0 ? 0 : squareSum / Double(sampleCount) }
        var rms: Double { sqrt(power) }
    }
    private struct State {
        var measuring = false
        var windowID = UUID()
        var energy = Energy()
        var bufferCount = 0
        var lastArrival: TimeInterval?
    }
    struct Health: Sendable {
        let bufferCount: Int
        let lastArrival: TimeInterval?
        var lastArrivalAge: TimeInterval {
            lastArrival.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        }
    }
    private let state = Mutex(State())
    func start() async throws { }
    func finish() async throws { }
    func cancel() async { }
    func accept(_ sample: CMSampleBuffer) { }
    func health() -> Health { state.withLock { Health(bufferCount: $0.bufferCount, lastArrival: $0.lastArrival) } }
    func beginWindow() { state.withLock { $0.energy = Energy(); $0.windowID = UUID(); $0.measuring = true } }
    func endWindow() -> Energy { state.withLock { $0.measuring = false; return $0.energy } }
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        let windowID = state.withLock { value -> UUID? in
            value.bufferCount += 1
            value.lastArrival = ProcessInfo.processInfo.systemUptime
            return value.measuring ? value.windowID : nil
        }
        guard let windowID else { return }
        guard buffer.format.channelCount == 1, let samples = buffer.floatChannelData?[0] else {
            state.withLock { if $0.measuring, $0.windowID == windowID { $0.energy.invalidFormats += 1 } }
            return
        }
        var squareSum = 0.0
        var validSamples: UInt64 = 0
        for frame in 0..<Int(buffer.frameLength) {
            let value = Double(samples[frame * buffer.stride])
            guard value.isFinite else { continue }
            squareSum += value * value
            validSamples += 1
        }
        state.withLock {
            guard $0.measuring, $0.windowID == windowID else { return }
            $0.energy.squareSum += squareSum
            $0.energy.sampleCount += validSamples
        }
    }
}

private final class HardwareFixtureBundle: NSObject { }

private final class HardwareReadinessProbe: Sendable {
    struct Snapshot: Sendable {
        var resolved = false
        var hasBuffer = false
        var failed = false
    }
    private let state = Mutex(Snapshot())
    func snapshot() -> Snapshot { state.withLock { $0 } }
    func resolved(hasBuffer: Bool) {
        state.withLock { $0.resolved = true; $0.hasBuffer = hasBuffer }
    }
    func failed() {
        state.withLock { $0.resolved = true; $0.failed = true }
    }
}

private final class MicrophoneMetadataProbe: AudioTranscriptionPipeline, @unchecked Sendable {
    struct Snapshot: Sendable {
        var bufferCount = 0
        var frames: UInt64 = 0
        var lastArrival: TimeInterval?
        var lastHostTime: TimeInterval?
        var maxArrivalGap: TimeInterval = 0
        var lastFormat: MicrophoneFormatSignature?
        var invalidBuffers = 0
        var unexpectedSampleBuffers = 0
        var lastArrivalAge: TimeInterval {
            lastArrival.map { ProcessInfo.processInfo.systemUptime - $0 } ?? .infinity
        }
    }
    private let state = Mutex(Snapshot())

    func snapshot() -> Snapshot { state.withLock { $0 } }
    func start() async throws { }
    func finish() async throws { }
    func cancel() async { }

    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        let arrival = ProcessInfo.processInfo.systemUptime
        let frames = UInt64(buffer.frameLength)
        let format = MicrophoneFormatSignature(format: buffer.format)
        state.withLock { value in
            if let previous = value.lastArrival { value.maxArrivalGap = max(value.maxArrivalGap, arrival - previous) }
            value.lastArrival = arrival
            value.lastHostTime = hostTime
            value.lastFormat = format
            value.bufferCount += 1
            value.frames += frames
            if frames == 0 || !format.sampleRate.isFinite || format.sampleRate <= 0 || format.channelCount == 0 {
                value.invalidBuffers += 1
            }
        }
    }

    func accept(_ sample: CMSampleBuffer) {
        state.withLock { $0.unexpectedSampleBuffers += 1 }
    }
}

private enum HardwareProbeError: Error {
    case permissionRequired, noMicrophone, engineReplaced, callbacksStalled, timedOut
}
#endif
