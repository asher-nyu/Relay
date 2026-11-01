import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import Relay

@Suite("Realtime microphone callback")
@MainActor
struct MicrophoneCallbackTests {
    @Test("A tap created by the main-actor service can run on the audio thread")
    func tapDoesNotInheritMainActor() async throws {
        let probe = TapPipelineProbe()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        for frame in 0..<64 { buffer.floatChannelData![0][frame] = 0.2 }
        let time = AVAudioTime(hostTime: mach_absolute_time())
        let invocation = TapInvocation(block: TranscriptionService.microphoneTap(for: probe), buffer: buffer, time: time)
        await Task.detached(priority: .userInitiated) {
            invocation.block(invocation.buffer, invocation.time)
        }.value
        let result = probe.result
        #expect(result.frames == 64)
        #expect(result.onMainThread == false)
        #expect(result.hostTime?.isFinite == true)
    }
}

/// The buffer is immutable after transfer. This models AVAudioEngine's background invocation.
private struct TapInvocation: @unchecked Sendable {
    let block: AVAudioNodeTapBlock
    let buffer: AVAudioPCMBuffer
    let time: AVAudioTime
}

private final class TapPipelineProbe: AudioTranscriptionPipeline, @unchecked Sendable {
    struct Result: Sendable {
        var frames: AVAudioFrameCount = 0
        var onMainThread: Bool?
        var hostTime: Double?
    }
    private let observation = Mutex(Result())
    var result: Result { observation.withLock { $0 } }
    func start() async throws {}
    func finish() async throws {}
    func cancel() async {}
    func accept(_ sample: CMSampleBuffer) {}
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        observation.withLock {
            $0.frames = buffer.frameLength
            $0.onMainThread = Thread.isMainThread
            $0.hostTime = hostTime
        }
    }
}
