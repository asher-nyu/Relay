@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Conversion state is confined to the source's serial audio queue.
final class PCMBufferConversion {
    enum MonoInputPolicy: Sendable {
        case automaticLayout
        /// Voice-processing uplink is the primary microphone channel. Explicit selection
        /// avoids Apple's silent implicit remapping for unlabeled multichannel inputs.
        case primaryMicrophoneChannel
    }
    let targetFormat: AVAudioFormat
    private let monoInputPolicy: MonoInputPolicy
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    init(targetFormat: AVAudioFormat, monoInputPolicy: MonoInputPolicy = .automaticLayout) {
        self.targetFormat = targetFormat
        self.monoInputPolicy = monoInputPolicy
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer? {
        guard input.frameLength > 0 else { return nil }
        if input.format == targetFormat { return input }
        if inputFormat != input.format {
            guard let converter = AVAudioConverter(from: input.format, to: targetFormat) else {
                throw AudioTranscriptionError.audioFormat
            }
            converter.primeMethod = .none
            if targetFormat.channelCount == 1, monoInputPolicy == .primaryMicrophoneChannel {
                // A discrete-channel layout has no inferred center channel. Without this
                // explicit map, conversion can succeed while returning entirely zero PCM.
                converter.channelMap = [0]
            }
            self.converter = converter
            inputFormat = input.format
        }
        guard let converter else { throw AudioTranscriptionError.audioConversion }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let requested = ceil(Double(input.frameLength) * ratio) + 512
        guard requested > 0, requested < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(requested)) else {
            throw AudioTranscriptionError.audioFormat
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw AudioTranscriptionError.audioConversion }
        return output.frameLength > 0 ? output : nil
    }

    func flush() throws -> [AVAudioPCMBuffer] {
        guard let converter else { return [] }
        var buffers: [AVAudioPCMBuffer] = []
        // The converter only holds its bounded resampling tail; this is not a recording buffer.
        for _ in 0..<8 {
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 2048) else {
                throw AudioTranscriptionError.audioFormat
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, status in
                status.pointee = .endOfStream
                return nil
            }
            if let error { throw error }
            if output.frameLength > 0 { buffers.append(output) }
            if status == .endOfStream || output.frameLength == 0 { return buffers }
            if status == .error { throw AudioTranscriptionError.audioConversion }
        }
        return buffers
    }

    /// Drain a device's resampler before starting a new format or a discontinuous route.
    func finishConversion() throws -> [AVAudioPCMBuffer] {
        let tail = try flush()
        converter = nil
        inputFormat = nil
        return tail
    }

    static func copy(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let output = AVAudioPCMBuffer(pcmFormat: input.format, frameCapacity: input.frameLength) else {
            throw AudioTranscriptionError.audioFormat
        }
        output.frameLength = input.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard source.count == destination.count else { throw AudioTranscriptionError.audioFormat }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else {
                throw AudioTranscriptionError.audioFormat
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return output
    }

    static func copy(_ sample: CMSampleBuffer) throws -> AVAudioPCMBuffer {
        guard sample.isValid, let description = sample.formatDescription, sample.numSamples > 0 else {
            throw AudioTranscriptionError.audioFormat
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sample.numSamples)) else {
            throw AudioTranscriptionError.audioFormat
        }
        buffer.frameLength = AVAudioFrameCount(sample.numSamples)
        try sample.copyPCMData(fromRange: 0..<sample.numSamples, into: buffer.mutableAudioBufferList)
        return buffer
    }

    static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else { return 0 }
        let count = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        var loudestRMS = 0.0
        for channel in 0..<channels {
            var sum = 0.0
            for frame in 0..<count {
                let index = frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)
                let sampleChannel = buffer.format.isInterleaved ? 0 : channel
                let value: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    guard let samples = buffer.floatChannelData?[sampleChannel] else { return 0 }
                    value = Double(samples[index])
                case .pcmFormatInt16:
                    guard let samples = buffer.int16ChannelData?[sampleChannel] else { return 0 }
                    value = Double(samples[index]) / 32_768
                case .pcmFormatInt32:
                    guard let samples = buffer.int32ChannelData?[sampleChannel] else { return 0 }
                    value = Double(samples[index]) / 2_147_483_648
                case .pcmFormatFloat64:
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
                    let selected = buffer.format.isInterleaved ? 0 : channel
                    guard buffers.indices.contains(selected), let data = buffers[selected].mData else { return 0 }
                    let samples = data.assumingMemoryBound(to: Double.self)
                    value = samples[index]
                default: return 0
                }
                if value.isFinite { sum += value * value }
            }
            loudestRMS = max(loudestRMS, sqrt(sum / Double(count)))
        }
        let decibels = 20 * log10(max(loudestRMS, 0.000_001))
        return min(1, max(0, (decibels + 60) / 60))
    }
}
