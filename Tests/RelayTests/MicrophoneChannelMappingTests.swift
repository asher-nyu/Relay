import AVFoundation
import Foundation
import Testing
@testable import Relay

@Suite("Microphone channel mapping")
struct MicrophoneChannelMappingTests {
    @Test("A nine-channel discrete VPIO stream retains audible processed microphone audio")
    func discreteVoiceProcessing() throws {
        let input = try makeInput(channels: 9, activeChannels: Set(0..<9))
        let output = try convert(input)
        #expect(output.frameLength > 0)
        #expect(rms(output) > 0.1)
        #expect(rms(output) < 0.16)
    }

    @Test("A raw three-channel microphone uses its primary channel explicitly")
    func rawMicrophone() throws {
        let input = try makeInput(channels: 3, activeChannels: [0])
        let output = try convert(input)
        #expect(rms(output) > 0.1)
    }

    @Test("Additional channels are never mixed into the processed microphone uplink")
    func excludesOtherChannels() throws {
        let input = try makeInput(channels: 9, activeChannels: Set(1..<9))
        let output = try convert(input)
        #expect(rms(output) == 0)
    }

    @Test("Microphone channel mapping survives a device format change")
    func formatChange() throws {
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let converter = PCMBufferConversion(targetFormat: target, monoInputPolicy: .primaryMicrophoneChannel)
        for channels: UInt32 in [3, 9] {
            let output = try #require(try converter.convert(makeInput(channels: channels, activeChannels: [0])))
            #expect(rms(output) > 0.1)
        }
    }

    private func makeInput(channels: UInt32, activeChannels: Set<Int>) throws -> AVAudioPCMBuffer {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   interleaved: false, channelLayout: layout)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        input.frameLength = 4_800
        for channel in 0..<Int(channels) {
            for frame in 0..<4_800 {
                input.floatChannelData![channel][frame] = activeChannels.contains(channel)
                    ? Float(0.2 * sin(Double(frame) * 2 * .pi * 440 / 48_000)) : 0
            }
        }
        return input
    }

    private func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let converter = PCMBufferConversion(targetFormat: target, monoInputPolicy: .primaryMicrophoneChannel)
        return try #require(try converter.convert(input))
    }

    private func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        var sum = 0.0
        for index in 0..<Int(buffer.frameLength) {
            let value = Double(buffer.int16ChannelData![0][index]) / 32_768
            sum += value * value
        }
        return sqrt(sum / Double(buffer.frameLength))
    }
}
