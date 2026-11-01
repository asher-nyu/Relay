import Foundation
import Testing
@testable import Relay

@Suite("Microphone route continuity")
struct MicrophoneConfigurationTests {
    private func snapshot(input: UInt32 = 11, output: UInt32 = 22, running: Bool = true,
                          voice: Bool = true, rate: Double = 48_000) -> MicrophoneConfigurationSnapshot {
        MicrophoneConfigurationSnapshot(inputDeviceID: input, outputDeviceID: output,
            format: MicrophoneFormatSignature(sampleRate: rate, channelCount: 1),
            isRunning: running, voiceProcessingEnabled: voice)
    }

    @Test("A delayed VPIO startup notification does not interrupt a healthy microphone")
    func benignNotification() {
        let installed = snapshot()
        #expect(MicrophoneConfigurationPolicy.decision(installed: installed, current: snapshot(),
                                                       requiresVoiceProcessing: true) == .unchanged)
    }

    @Test("Physical microphone and speaker changes reconnect without ending recognition")
    func deviceChoices() {
        for current in [snapshot(input: 33), snapshot(output: 44)] {
            #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: current,
                                                           requiresVoiceProcessing: true) == .reconnect)
        }
    }

    @Test("An engine binding change is detected even when global default IDs stay the same")
    func ioUnitBindingChanges() {
        let installed = MicrophoneConfigurationSnapshot(inputDeviceID: 11, outputDeviceID: 22,
            format: MicrophoneFormatSignature(sampleRate: 48_000, channelCount: 1),
            isRunning: true, voiceProcessingEnabled: true, boundInputDeviceID: 101, boundOutputDeviceID: 101)
        let current = MicrophoneConfigurationSnapshot(inputDeviceID: 11, outputDeviceID: 22,
            format: installed.format, isRunning: true, voiceProcessingEnabled: true,
            boundInputDeviceID: 102, boundOutputDeviceID: 102)
        #expect(MicrophoneConfigurationPolicy.decision(installed: installed, current: current,
                                                       requiresVoiceProcessing: true) == .reconnect)
    }

    @Test("A configuration-stopped engine retains its graph when its route and format are unchanged")
    func stoppedGraph() {
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(running: false),
                                                       requiresVoiceProcessing: true) == .restart)
    }

    @Test("A changed format rebuilds rather than restarting an incompatible graph")
    func changedFormat() {
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(rate: 44_100),
                                                       requiresVoiceProcessing: true) == .reconnect)
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(running: false, rate: 44_100),
                                                       requiresVoiceProcessing: true) == .reconnect)
    }

    @Test("Stopping does not hide a changed physical device or voice-processing preference")
    func stoppedChangedRoute() {
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(input: 33, running: false),
                                                       requiresVoiceProcessing: true) == .reconnect)
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(running: false),
                                                       requiresVoiceProcessing: false) == .reconnect)
    }

    @Test("An unplugged microphone waits for availability")
    func noDevice() {
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(input: 0, running: false),
                                                       requiresVoiceProcessing: true) == .waitForDevice)
    }

    @Test("Changing the echo setting reconfigures the microphone in either direction")
    func echoPreferenceChanges() {
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(), current: snapshot(),
                                                       requiresVoiceProcessing: false) == .reconnect)
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(voice: false), current: snapshot(voice: false),
                                                       requiresVoiceProcessing: true) == .reconnect)
        #expect(MicrophoneConfigurationPolicy.decision(installed: snapshot(voice: false), current: snapshot(voice: false),
                                                       requiresVoiceProcessing: false) == .unchanged)
    }

    @Test("A route gap preserves session-relative time without sending audio backwards")
    func timelineGap() {
        var timeline = AudioInputTimeline(sampleRate: 16_000, origin: 1_000)
        #expect(timeline.nextStart(frameLength: 1_600, hostTime: 1_002) == 32_000)
        #expect(timeline.nextStart(frameLength: 1_600, hostTime: 1_002.099) == 33_600)
        #expect(timeline.nextStart(frameLength: 1_600, hostTime: 1_007.2) == 115_200)
        #expect(timeline.nextStart(frameLength: 1_600, hostTime: 1_002) == 116_800)
        #expect(timeline.nextStart(frameLength: 160, hostTime: nil) == 118_400)
    }

    @Test("Nonfinite host times and invalid clocks cannot corrupt the analyzer timeline")
    func timelineInvalidClock() {
        var timeline = AudioInputTimeline(sampleRate: 16_000, origin: 1_000)
        #expect(timeline.nextStart(frameLength: 160, hostTime: .nan) == 0)
        #expect(timeline.nextStart(frameLength: 160, hostTime: .infinity) == 160)
        #expect(timeline.nextStart(frameLength: 160, hostTime: 999) == 320)
    }
}
