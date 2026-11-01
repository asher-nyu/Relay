import AVFoundation
import Testing
@testable import Relay

@Suite("Audio conversion")
struct AudioConversionTests {
    @Test("Capture buffers are copied before the framework can reuse them")
    func deepCopy() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16))
        source.frameLength = 16
        for index in 0..<16 { source.floatChannelData![0][index] = Float(index) / 16 }
        let copy = try PCMBufferConversion.copy(source)
        source.floatChannelData![0][7] = -1
        #expect(copy.frameLength == 16)
        #expect(copy.floatChannelData![0][7] == 7.0 / 16)
    }

    @Test("Stereo system sound resamples to mono without losing duration")
    func downmixAndResample() throws {
        let input = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800))
        buffer.frameLength = 4800
        for channel in 0..<2 {
            for frame in 0..<4800 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.2)
            }
        }
        let converter = PCMBufferConversion(targetFormat: target)
        let output = try #require(try converter.convert(buffer))
        let tail = try converter.flush()
        let frames = Int(output.frameLength) + tail.reduce(0) { $0 + Int($1.frameLength) }
        #expect(abs(frames - 1600) <= 32)
        #expect(output.format == target)
        #expect(PCMBufferConversion.level(of: output) > 0.1)
        for index in 0..<Int(output.frameLength) { #expect(output.floatChannelData![0][index].isFinite) }
    }

    @Test("Empty audio is not submitted to speech recognition")
    func emptyInput() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        let converter = PCMBufferConversion(targetFormat: format)
        #expect(try converter.convert(buffer) == nil)
        #expect(PCMBufferConversion.level(of: buffer) == 0)
    }

    @Test("Silence produces a zero level and loud input remains bounded")
    func levelBounds() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        for index in 0..<64 { buffer.floatChannelData![0][index] = 0 }
        #expect(PCMBufferConversion.level(of: buffer) == 0)
        for index in 0..<64 { buffer.floatChannelData![0][index] = 2 }
        #expect(PCMBufferConversion.level(of: buffer) == 1)
    }

    @Test("The converter adapts to a microphone format change")
    func formatChange() throws {
        let target = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let converter = PCMBufferConversion(targetFormat: target)
        for rate in [44_100.0, 48_000.0] {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410))
            buffer.frameLength = 4410
            for index in 0..<4410 { buffer.floatChannelData![0][index] = 0.1 }
            let output = try #require(try converter.convert(buffer))
            #expect(output.format == target)
            #expect(output.frameLength > 0)
        }
    }
}
