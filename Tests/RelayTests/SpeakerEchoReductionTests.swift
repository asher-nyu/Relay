import Foundation
import Testing
@testable import Relay

@Suite("Speaker echo reduction configuration")
@MainActor
struct SpeakerEchoReductionTests {
    @Test("Echo reduction applies only to simultaneous system and microphone capture")
    func sourceSelection() {
        let selections: [Set<TranscriptSource>] = [[], [.systemAudio], [.microphone]]
        for sources in selections {
            #expect(!SpeakerEchoReduction.isRequested(sources: sources, preference: true))
        }
        #expect(SpeakerEchoReduction.isRequested(sources: [.systemAudio, .microphone], preference: true))
        #expect(!SpeakerEchoReduction.isRequested(sources: [.systemAudio, .microphone], preference: false))
    }

    @Test("A disabled preference leaves the microphone processing untouched")
    func disabledPreference() throws {
        let device = VoiceProcessingProbe()
        try SpeakerEchoReduction.configure(device, requested: false)
        #expect(device.events.isEmpty)
        #expect(!device.isVoiceProcessingEnabled)
    }

    @Test("Native echo reduction is enabled and verified before minimizing ducking")
    func enabledConfiguration() throws {
        let device = VoiceProcessingProbe()
        try SpeakerEchoReduction.configure(device, requested: true)
        #expect(device.events == ["enable", "verify", "minimum ducking"])
    }

    @Test("A running engine is rejected before its configuration is changed")
    func rejectsRunningEngine() {
        let device = VoiceProcessingProbe()
        device.running = true
        expectUnavailable(device)
        #expect(device.events.isEmpty)
    }

    @Test("A device error never silently falls back to an unprocessed microphone")
    func unsupportedHardware() {
        let device = VoiceProcessingProbe()
        device.enableError = CocoaError(.featureUnsupported)
        expectUnavailable(device)
        #expect(device.events == ["enable"])
    }

    @Test("A successful setter must actually enable native voice processing")
    func verifiesNativeState() {
        let device = VoiceProcessingProbe()
        device.honorsEnableRequest = false
        expectUnavailable(device)
        #expect(device.events == ["enable", "verify"])
    }

    private func expectUnavailable(_ device: VoiceProcessingProbe) {
        do {
            try SpeakerEchoReduction.configure(device, requested: true)
            Issue.record("An unavailable echo reduction setup must be reported to the microphone controller.")
        } catch {
            #expect(error as? AudioTranscriptionError == .speakerEchoReductionUnavailable)
        }
    }
}

@MainActor
private final class VoiceProcessingProbe: VoiceProcessingConfigurationTarget {
    var running = false
    var honorsEnableRequest = true
    var enableError: Error?
    var events: [String] = []
    private var enabled = false
    var isEngineRunning: Bool { running }
    var isVoiceProcessingEnabled: Bool {
        events.append("verify")
        return enabled
    }
    func enableVoiceProcessing() throws {
        events.append("enable")
        if let enableError { throw enableError }
        enabled = honorsEnableRequest
    }
    func minimizeOtherAudioDucking() {
        events.append("minimum ducking")
    }
}
