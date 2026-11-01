@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Synchronization

/// Holds the beginning of an Auto session in memory while its language is identified and prepared.
/// A 120-second bound prevents growing indefinitely when a model download stalls.
final class BufferedAudioPipeline: AudioTranscriptionPipeline, @unchecked Sendable {
    private struct PendingAudio: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let hostTime: Double
    }
    private let queue: DispatchQueue
    private let converter: PCMBufferConversion
    private let diagnostics: AudioCaptureDiagnostics
    private let onSamples: @MainActor @Sendable ([Float]) -> Void
    private let onLevel: @MainActor @Sendable (Double) -> Void
    private let onFailure: @MainActor @Sendable (Error) -> Void
    private let accepting = Mutex(true)
    // Accessed only on queue.
    private var pending: [PendingAudio] = []
    private var pendingFrames = 0
    private var heardSpeech = false
    private var lastInputFormat: MicrophoneFormatSignature?
    private var lastInputEndHostTime: Double?
    private var destination: SpeechPipeline?
    private var sampleWindow: [Float] = []
    private var speechFrames = 0
    private var detectionRequested = false
    private var lastLevelTime: Double = 0
    private var failureReported = false

    init(source: TranscriptSource,
         onSamples: @escaping @MainActor @Sendable ([Float]) -> Void,
         onLevel: @escaping @MainActor @Sendable (Double) -> Void,
         onFailure: @escaping @MainActor @Sendable (Error) -> Void) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                         channels: 1, interleaved: false) else {
            throw AudioTranscriptionError.audioFormat
        }
        converter = PCMBufferConversion(targetFormat: format,
            monoInputPolicy: source == .microphone ? .primaryMicrophoneChannel : .automaticLayout)
        diagnostics = AudioCaptureDiagnostics(source: source)
        queue = DispatchQueue(label: "com.asherbloom.Relay.auto.\(source.rawValue)", qos: .userInitiated)
        self.onSamples = onSamples
        self.onLevel = onLevel
        self.onFailure = onFailure
    }

    func start() async throws {}

    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double? = nil) {
        guard accepting.withLock({ $0 }) else { return }
        do {
            let copied = PendingAudio(buffer: try PCMBufferConversion.copy(buffer),
                                      hostTime: hostTime ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            queue.async { [self] in
                guard accepting.withLock({ $0 }) else { return }
                do {
                    if let destination { destination.accept(copied.buffer, hostTime: copied.hostTime); return }
                    let signature = MicrophoneFormatSignature(format: copied.buffer.format)
                    let gap = lastInputEndHostTime.map { copied.hostTime - $0 > AudioInputTimeline.gapTolerance } ?? false
                    if lastInputFormat != nil, lastInputFormat != signature || gap {
                        var tailTime = lastInputEndHostTime ?? copied.hostTime
                        for tail in try converter.finishConversion() {
                            try retain(tail, hostTime: tailTime)
                            tailTime += Double(tail.frameLength) / tail.format.sampleRate
                        }
                    }
                    lastInputFormat = signature
                    lastInputEndHostTime = copied.hostTime + Double(copied.buffer.frameLength) / copied.buffer.format.sampleRate
                    let convertedBuffer = try converter.convert(copied.buffer)
                    diagnostics.record(input: copied.buffer, output: convertedBuffer)
                    if let converted = convertedBuffer {
                        try retain(converted, hostTime: copied.hostTime)
                    }
                } catch { report(error) }
            }
        } catch { Task { @MainActor [onFailure] in onFailure(error) } }
    }

    private func retain(_ converted: AVAudioPCMBuffer, hostTime: Double) throws {
        let level = PCMBufferConversion.level(of: converted)
        if level > 0.28 { heardSpeech = true }
        pendingFrames += Int(converted.frameLength)
        pending.append(PendingAudio(buffer: converted, hostTime: hostTime))
        if !heardSpeech {
            // Waiting in a quiet room has no time limit. Preserve a one-second pre-roll
            // so the beginning of a word survives the transition into language detection.
            while pending.count > 1, pendingFrames - Int(pending[0].buffer.frameLength) >= 16_000 {
                pendingFrames -= Int(pending.removeFirst().buffer.frameLength)
            }
        }
        guard pendingFrames <= 16_000 * 120 else { throw AudioTranscriptionError.languagePreparationTooLong }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastLevelTime >= 0.08 {
            lastLevelTime = now
            Task { @MainActor [onLevel] in onLevel(level) }
        }
        if let samples = converted.floatChannelData?[0], level > 0.28 || !sampleWindow.isEmpty {
            let remaining = max(0, 30 * 16_000 - sampleWindow.count)
            let count = min(remaining, Int(converted.frameLength))
            sampleWindow.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
            if level > 0.28 { speechFrames += Int(converted.frameLength) }
        }
        if !detectionRequested, speechFrames >= 16_000 * 3 || sampleWindow.count >= 16_000 * 12 && speechFrames >= 16_000 {
            detectionRequested = true
            let snapshot = sampleWindow
            Task { @MainActor [onSamples] in onSamples(snapshot) }
        }
    }

    func accept(_ sample: CMSampleBuffer) {
        do {
            let buffer = try PCMBufferConversion.copy(sample)
            let time = sample.presentationTimeStamp.seconds
            accept(buffer, hostTime: time.isFinite ? time : nil)
        } catch { Task { @MainActor [onFailure] in onFailure(error) } }
    }

    /// Queue ordering prevents a gap between the saved opening and the live stream.
    func install(_ pipeline: SpeechPipeline) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard accepting.withLock({ $0 }) else { continuation.resume(throwing: CancellationError()); return }
                do {
                    for audio in pending { pipeline.replay(audio.buffer, hostTime: audio.hostTime) }
                    var tailTime = pending.last.map { $0.hostTime + Double($0.buffer.frameLength) / $0.buffer.format.sampleRate }
                        ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds
                    for tail in try converter.flush() {
                        pipeline.replay(tail, hostTime: tailTime)
                        tailTime += Double(tail.frameLength) / tail.format.sampleRate
                    }
                    pending.removeAll()
                    pendingFrames = 0
                    sampleWindow.removeAll()
                    destination = pipeline
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func detectionSamples() async -> [Float] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: speechFrames > 0 ? sampleWindow : [])
            }
        }
    }

    func finish() async throws {
        let target: SpeechPipeline? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                accepting.withLock { $0 = false }
                pending.removeAll()
                sampleWindow.removeAll()
                continuation.resume(returning: destination)
            }
        }
        try await target?.finish()
    }

    func cancel() async {
        accepting.withLock { $0 = false }
        let target: SpeechPipeline? = await withCheckedContinuation { continuation in
            queue.async { [self] in
                pending.removeAll()
                sampleWindow.removeAll()
                continuation.resume(returning: destination)
                destination = nil
            }
        }
        await target?.cancel()
    }

    private func report(_ error: Error) {
        guard !failureReported else { return }
        failureReported = true
        accepting.withLock { $0 = false }
        Task { @MainActor [onFailure] in onFailure(error) }
    }
}
