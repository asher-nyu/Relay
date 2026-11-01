import AVFoundation
import Foundation
import Testing
@testable import Relay

@Suite("Voice-processing output clock")
@MainActor
struct VoiceProcessingOutputTests {
    @Test("Voice I/O uses an explicit mono format at the native sample rate")
    func voiceFormat() throws {
        for rate in [44_100.0, 48_000.0] {
            let format = try VoiceProcessingOutput.voiceFormat(sampleRate: rate)
            #expect(format.sampleRate == rate)
            #expect(format.channelCount == 1)
            #expect(format.commonFormat == .pcmFormatFloat32)
            #expect(!format.isInterleaved)
        }
    }

    @Test("Invalid native formats cannot create a running voice-processing graph")
    func invalidVoiceFormat() {
        for rate in [0, -1, Double.nan, Double.infinity] {
            #expect(throws: AudioTranscriptionError.audioFormat) {
                _ = try VoiceProcessingOutput.voiceFormat(sampleRate: rate)
            }
        }
    }

    @Test("The native render callback runs off the main actor and generates digital silence only")
    func silentRender() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256))
        buffer.frameLength = 256
        for channel in 0..<2 {
            for frame in 0..<256 { buffer.floatChannelData![channel][frame] = 0.75 }
        }
        let invocation = SilentRenderInvocation(block: VoiceProcessingOutput.makeSilentRenderBlock(), buffer: buffer)
        let result = await Task.detached(priority: .userInitiated) {
            invocation.invoke()
        }.value
        #expect(result.succeeded)
        #expect(!result.onMainThread)
        for channel in 0..<2 {
            #expect((0..<256).allSatisfy { buffer.floatChannelData![channel][$0] == 0 })
        }
    }
}

/// The buffer is transferred for one render invocation and read again only after it completes.
private struct SilentRenderInvocation: @unchecked Sendable {
    let block: AVAudioSourceNodeRenderBlock
    let buffer: AVAudioPCMBuffer

    func invoke() -> (succeeded: Bool, onMainThread: Bool) {
        var isSilence: ObjCBool = false
        var timestamp = AudioTimeStamp()
        let status = block(&isSilence, &timestamp, buffer.frameLength, buffer.mutableAudioBufferList)
        return (status == noErr && isSilence.boolValue, Thread.isMainThread)
    }
}
