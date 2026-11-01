import AVFoundation
import Foundation
import Testing
@testable import Relay

@Suite("PCM sample formats")
struct PCMFormatTests {
    @Test("Meters the right channel and copies all sample formats without aliasing",
          arguments: [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32],
          [false, true])
    func stereoFormats(_ common: AVAudioCommonFormat, _ interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: common, sampleRate: 16_000,
                                               channels: 2, interleaved: interleaved))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audio in list { memset(audio.mData!, 0, Int(audio.mDataByteSize)) }
        // Only the right channel carries a signal: interleaved data must use buffer 0 with an offset.
        for frame in 0..<128 {
            let channel = interleaved ? 0 : 1
            let index = frame * buffer.stride + (interleaved ? 1 : 0)
            switch common {
            case .pcmFormatFloat32: buffer.floatChannelData![channel][index] = 0.25
            case .pcmFormatInt16: buffer.int16ChannelData![channel][index] = 8192
            case .pcmFormatInt32: buffer.int32ChannelData![channel][index] = 536_870_912
            case .pcmFormatFloat64:
                list[channel].mData!.assumingMemoryBound(to: Double.self)[index] = 0.25
            default: Issue.record("Unexpected format")
            }
        }
        let level = PCMBufferConversion.level(of: buffer)
        #expect(level > 0.7 && level < 0.9)
        let copy = try PCMBufferConversion.copy(buffer)
        for audio in list { memset(audio.mData!, 0, Int(audio.mDataByteSize)) }
        #expect(PCMBufferConversion.level(of: buffer) == 0)
        #expect(PCMBufferConversion.level(of: copy) == level)
        #expect(copy.frameLength == buffer.frameLength)
        #expect(copy.format == format)
    }

    @Test("Nonfinite input cannot poison the level indicator")
    func nonfiniteLevel() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        buffer.floatChannelData![0][0] = .nan
        buffer.floatChannelData![0][1] = .infinity
        buffer.floatChannelData![0][2] = -.infinity
        buffer.floatChannelData![0][3] = 0
        #expect(PCMBufferConversion.level(of: buffer) == 0)
    }
}
