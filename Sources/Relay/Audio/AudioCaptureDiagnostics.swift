@preconcurrency import AVFoundation
import Foundation
import OSLog

/// Explicit, development-only signal diagnostics. Only counts, formats, and RMS levels
/// reach the log; no samples, recognized text, recordings, or transcript files are saved.
/// Instances are confined to their source's conversion queue, away from the realtime tap.
final class AudioCaptureDiagnostics {
    static let isEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["RELAY_AUDIO_DIAGNOSTICS"] == "1"
        #else
        false
        #endif
    }()

    private let source: TranscriptSource
    private let logger = Logger(subsystem: "com.asherbloom.Relay", category: "AudioSignal")
    private var inputBuffers = 0
    private var inputFrames: UInt64 = 0
    private var outputBuffers = 0
    private var outputFrames: UInt64 = 0
    private var peakInputRMS: [Double] = []
    private var peakOutputRMS: [Double] = []
    private var lastReport: TimeInterval = 0

    init(source: TranscriptSource) { self.source = source }

    func record(input: AVAudioPCMBuffer, output: AVAudioPCMBuffer?) {
        guard Self.isEnabled, source == .microphone else { return }
        inputBuffers += 1
        inputFrames += UInt64(input.frameLength)
        mergePeak(Self.rms(input), into: &peakInputRMS)
        if let output {
            outputBuffers += 1
            outputFrames += UInt64(output.frameLength)
            mergePeak(Self.rms(output), into: &peakOutputRMS)
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 2 else { return }
        lastReport = now
        let inputFormat = Self.describe(input.format)
        let outputFormat = output.map { Self.describe($0.format) } ?? "no converted output"
        let raw = peakInputRMS.map { String(format: "%.7f", $0) }.joined(separator: ",")
        let converted = peakOutputRMS.map { String(format: "%.7f", $0) }.joined(separator: ",")
        logger.info("Microphone signal: inputBuffers=\(self.inputBuffers) inputFrames=\(self.inputFrames) outputBuffers=\(self.outputBuffers) outputFrames=\(self.outputFrames) rawFormat=\(inputFormat, privacy: .public) convertedFormat=\(outputFormat, privacy: .public) rawChannelRMS=[\(raw, privacy: .public)] convertedChannelRMS=[\(converted, privacy: .public)]")
        peakInputRMS.removeAll(keepingCapacity: true)
        peakOutputRMS.removeAll(keepingCapacity: true)
    }

    private func mergePeak(_ current: [Double], into peaks: inout [Double]) {
        if peaks.count != current.count { peaks = current; return }
        for index in current.indices { peaks[index] = max(peaks[index], current[index]) }
    }

    static func connectionStage(_ stage: String, details: String = "", error: Error? = nil) {
        guard isEnabled else { return }
        let logger = Logger(subsystem: "com.asherbloom.Relay", category: "MicrophoneSetup")
        if let error {
            let native = error as NSError
            logger.error("Microphone setup failed: stage=\(stage, privacy: .public) domain=\(native.domain, privacy: .public) code=\(native.code) description=\(native.localizedDescription, privacy: .public) details=\(details, privacy: .public)")
        } else {
            logger.info("Microphone setup: stage=\(stage, privacy: .public) details=\(details, privacy: .public)")
        }
    }

    static func describe(_ format: AVAudioFormat) -> String {
        let description = format.streamDescription.pointee
        return "\(format.sampleRate)Hz/\(format.channelCount)ch/type\(format.commonFormat.rawValue)/interleaved=\(format.isInterleaved)/layout=\(format.channelLayout?.layoutTag ?? 0)/formatID=\(description.mFormatID)/flags=\(description.mFormatFlags)/bytesPerFrame=\(description.mBytesPerFrame)"
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> [Double] {
        guard buffer.frameLength > 0 else { return [] }
        let count = Int(buffer.frameLength)
        return (0..<Int(buffer.format.channelCount)).map { channel in
            var sum = 0.0
            for frame in 0..<count {
                let index = frame * buffer.stride + (buffer.format.isInterleaved ? channel : 0)
                let sampleChannel = buffer.format.isInterleaved ? 0 : channel
                let value: Double
                switch buffer.format.commonFormat {
                case .pcmFormatFloat32:
                    value = buffer.floatChannelData.map { Double($0[sampleChannel][index]) } ?? 0
                case .pcmFormatInt16:
                    value = buffer.int16ChannelData.map { Double($0[sampleChannel][index]) / 32_768 } ?? 0
                case .pcmFormatInt32:
                    value = buffer.int32ChannelData.map { Double($0[sampleChannel][index]) / 2_147_483_648 } ?? 0
                case .pcmFormatFloat64:
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
                    let selected = buffer.format.isInterleaved ? 0 : channel
                    value = buffers.indices.contains(selected) ? buffers[selected].mData.map {
                        $0.assumingMemoryBound(to: Double.self)[index]
                    } ?? 0 : 0
                default: value = 0
                }
                if value.isFinite { sum += value * value }
            }
            return sqrt(sum / Double(count))
        }
    }
}
