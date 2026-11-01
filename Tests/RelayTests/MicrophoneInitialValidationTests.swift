import Foundation
import Testing
@testable import Relay

@Suite("Initial microphone graph validation")
struct MicrophoneInitialValidationTests {
    private let route = MicrophoneDeviceRoute(inputDeviceID: 11, outputDeviceID: 22)
    private let format = MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 1)

    @Test("A matching running candidate can be published with its native aggregate binding")
    func acceptsCompatibleRunningCandidate() {
        #expect(decision(snapshot()) == .unchanged)
        #expect(decision(snapshot(boundInput: 901, boundOutput: 902)) == .unchanged)
    }

    @Test("Only a stopped candidate with the exact requested configuration can restart in place")
    func repairsCompatibleStoppedCandidate() {
        #expect(decision(snapshot(running: false)) == .restart)
        #expect(decision(snapshot(running: false, boundInput: 901, boundOutput: 902)) == .restart)
    }

    @Test("Changed physical devices reject the unpublished candidate even when it only appears stopped")
    func changedPhysicalRouteCannotBeRepairedAsSameGraph() {
        for running in [false, true] {
            #expect(decision(snapshot(input: 33, running: running)) == .reconnect)
            #expect(decision(snapshot(output: 44, running: running)) == .reconnect)
        }
    }

    @Test("Every incompatible PCM format requires a new candidate instead of an initial restart")
    func incompatibleFormatsCannotRestartInPlace() {
        let alternatives = [
            MicrophoneFormatSignature(sampleRate: 44_100, channelCount: 1),
            MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 9),
            MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 1, formatID: 1),
            MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 1, formatFlags: 2),
            MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 1, bytesPerFrame: 8),
            MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 1, interleaved: true)
        ]
        for changed in alternatives {
            for running in [false, true] {
                #expect(decision(snapshot(format: changed, running: running)) == .reconnect)
            }
        }
    }

    @Test("A stopped graph cannot silently ignore required echo processing")
    func requiredVoiceModeMustMatch() {
        #expect(decision(snapshot(running: false, voice: false)) == .reconnect)
        #expect(decision(snapshot(voice: false)) == .reconnect)
    }

    @Test("Raw microphone acceptance also respects the requested processing mode")
    func rawModeMustMatch() {
        let rawRoute = MicrophoneDeviceRoute(inputDeviceID: 11, outputDeviceID: 0)
        #expect(MicrophoneConfigurationPolicy.initialDecision(route: rawRoute, format: format,
            requiresVoiceProcessing: false, current: snapshot(output: 0, voice: false)) == .unchanged)
        #expect(MicrophoneConfigurationPolicy.initialDecision(route: rawRoute, format: format,
            requiresVoiceProcessing: false, current: snapshot(output: 0, running: false, voice: false)) == .restart)
        #expect(MicrophoneConfigurationPolicy.initialDecision(route: rawRoute, format: format,
            requiresVoiceProcessing: false, current: snapshot(output: 0, running: false, voice: true)) == .reconnect)
    }

    @Test("An unavailable microphone waits instead of publishing or restarting a candidate")
    func missingInputWaitsForDevice() {
        #expect(decision(snapshot(input: 0)) == .waitForDevice)
        #expect(decision(snapshot(input: 0, running: false, voice: false)) == .waitForDevice)
    }

    private func decision(_ current: MicrophoneConfigurationSnapshot) -> MicrophoneConfigurationDecision {
        MicrophoneConfigurationPolicy.initialDecision(route: route, format: format,
            requiresVoiceProcessing: true, current: current)
    }

    private func snapshot(input: UInt32 = 11, output: UInt32 = 22,
                          format: MicrophoneFormatSignature? = nil,
                          running: Bool = true, voice: Bool = true,
                          boundInput: UInt32 = 101, boundOutput: UInt32 = 101) -> MicrophoneConfigurationSnapshot {
        MicrophoneConfigurationSnapshot(inputDeviceID: input, outputDeviceID: output,
            format: format ?? self.format, isRunning: running, voiceProcessingEnabled: voice,
            boundInputDeviceID: boundInput, boundOutputDeviceID: boundOutput)
    }
}
