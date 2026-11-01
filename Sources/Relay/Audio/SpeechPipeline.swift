@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import Speech
import Synchronization

/// Sources prepare independently. Their owner retains every pipeline so an error
/// or cancellation can tear down all resources before a new session starts.
enum AudioPipelineStartup {
    static func start(_ pipelines: [any AudioTranscriptionPipeline]) async throws {
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for pipeline in pipelines {
                group.addTask { try await pipeline.start() }
            }
            for try await _ in group { }
        }
        try Task.checkCancellation()
    }
}

/// A source owns one analyzer and one serial conversion queue. PCM exists only in memory.
/// Immutable analyzer references are Sendable; mutable audio state is queue-confined or locked.
final class SpeechPipeline: AudioTranscriptionPipeline, @unchecked Sendable {
    let source: TranscriptSource
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let converter: PCMBufferConversion
    private let diagnostics: AudioCaptureDiagnostics
    private let speechActivity: SourceSpeechActivity
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let sequence: AsyncStream<AnalyzerInput>
    private let queue: DispatchQueue
    private let onUpdate: @MainActor @Sendable (TranscriptUpdate) -> Void
    private let onLevel: @MainActor @Sendable (Double) -> Void
    private let onFailure: @MainActor @Sendable (Error) -> Void
    private let onTimingMetadata: (@MainActor @Sendable (SpeechResultTiming.Metadata) -> Void)?
    private let timingMetricsEnabled = ProcessInfo.processInfo.environment["RELAY_SPEECH_TIMING_METRICS"] == "1"
    private var resultsTask: Task<Void, Never>?
    private let shared = Mutex(SharedState())
    private let timingLogger = Logger(subsystem: "com.asherbloom.Relay", category: "CaptureStartup")
    private let createdAt = ProcessInfo.processInfo.systemUptime
    private let captureMetricsEnabled = ProcessInfo.processInfo.environment["RELAY_CAPTURE_METRICS"] == "1"
    private struct SharedState {
        var accepting = true
        var pendingBuffers = 0
        var receivedAudio = false
        var failureReported = false
    }
    // Accessed only on queue.
    private var timeline: AudioInputTimeline
    private var lastInputFormat: MicrophoneFormatSignature?
    private var lastInputEndHostTime: Double?
    private var lastInputWasReplay = false
    private var lastLevelTime: Double = 0
    private var receivedFirstBuffer = false
    private var capturedBufferCount = 0
    private var capturedFrameCount: UInt64 = 0
    private var lastCaptureArrival: TimeInterval?
    private var largestCaptureGap: TimeInterval = 0
    private var lastCaptureReport: TimeInterval = 0

    init(source: TranscriptSource, transcriber: SpeechTranscriber, format: AVAudioFormat,
         origin: Double,
         onUpdate: @escaping @MainActor @Sendable (TranscriptUpdate) -> Void,
         onLevel: @escaping @MainActor @Sendable (Double) -> Void,
         onFailure: @escaping @MainActor @Sendable (Error) -> Void,
         onTimingMetadata: (@MainActor @Sendable (SpeechResultTiming.Metadata) -> Void)? = nil) {
        self.source = source
        speechActivity = SourceSpeechActivity(source: source)
        diagnostics = AudioCaptureDiagnostics(source: source)
        self.transcriber = transcriber
        timeline = AudioInputTimeline(sampleRate: format.sampleRate, origin: origin)
        self.onUpdate = onUpdate
        self.onLevel = onLevel
        self.onFailure = onFailure
        self.onTimingMetadata = onTimingMetadata
        converter = PCMBufferConversion(targetFormat: format,
            monoInputPolicy: source == .microphone ? .primaryMicrophoneChannel : .automaticLayout)
        queue = DispatchQueue(label: "com.asherbloom.Relay.audio.\(source.rawValue)", qos: .userInitiated)
        let stream = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .bufferingOldest(128))
        sequence = stream.stream
        input = stream.continuation
        analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
    }

    func start() async throws {
        logStartup("recognizer.prepare.requested")
        try await analyzer.prepareToAnalyze(in: converter.targetFormat)
        try Task.checkCancellation()
        guard shared.withLock({ $0.accepting }) else { throw CancellationError() }
        logStartup("recognizer.prepare.ready")
        resultsTask = Task { [self] in
            var segmentID = UUID()
            var resultTiming = SpeechSegmentTiming()
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    let text = String(result.text.characters)
                    let timestamp = resultTiming.resolve(in: result.text, range: result.range,
                        isFinal: result.isFinal, finalizationTime: result.resultsFinalizationTime,
                        activity: speechActivity.snapshot)
                    if timingMetricsEnabled || onTimingMetadata != nil {
                        let metadata = SpeechResultTiming.metadata(in: result.text, range: result.range,
                            chosenStart: timestamp, isFinal: result.isFinal,
                            finalizationTime: result.resultsFinalizationTime)
                        if timingMetricsEnabled { logResultTiming(metadata) }
                        await onTimingMetadata?(metadata)
                    }
                    await onUpdate(TranscriptUpdate(segmentID: segmentID, source: source,
                                                     text: text, isFinal: result.isFinal,
                                                     timestamp: timestamp,
                                                     timingIsConfirmed: result.isFinal && SpeechResultTiming.wordStart(in: result.text) != nil))
                    if result.isFinal { segmentID = UUID() }
                }
            } catch is CancellationError {
                // Cancellation is intentional during a cancelled preparation or immediate quit.
            } catch {
                reportFailure(error)
            }
        }
        try await analyzer.start(inputSequence: sequence)
        logStartup("recognizer.started")
    }

    private func logStartup(_ stage: String) {
        let elapsed = ProcessInfo.processInfo.systemUptime - createdAt
        timingLogger.notice("Speech startup: source=\(self.source.rawValue, privacy: .public) stage=\(stage, privacy: .public) elapsed=\(elapsed)")
    }

    private func logResultTiming(_ value: SpeechResultTiming.Metadata) {
        let rangeStart = value.resultStart ?? -1
        let rangeEnd = value.resultEnd ?? -1
        let earliestWord = value.earliestPositiveWordStart ?? -1
        let finalizationTime = value.finalizationTime ?? -1
        timingLogger.notice("Speech result timing: source=\(self.source.rawValue, privacy: .public) final=\(value.isFinal) rangeStart=\(rangeStart) rangeEnd=\(rangeEnd) finalizationTime=\(finalizationTime) spokenRuns=\(value.spokenRuns) missingWordRanges=\(value.missingWordRanges) zeroDurationWordRanges=\(value.zeroDurationWordRanges) positiveWordRanges=\(value.positiveDurationWordRanges) earliestPositiveWordStart=\(earliestWord) chosenStart=\(value.chosenStart)")
        let activity = speechActivity.snapshot
        let intervals = activity.voice.count > 12
            ? Array(activity.voice.prefix(6)) + Array(activity.voice.suffix(6)) : activity.voice
        let summary = intervals.map { String(format: "%.3f:%.3f", $0.start, $0.end) }.joined(separator: ",")
        let replay = activity.replayThrough.map { rangeEnd <= $0 + 0.05 } ?? false
        let candidate = activity.onset(after: max(0, rangeStart), through: max(0, rangeEnd),
                                       preservingReplayOrder: replay) ?? -1
        timingLogger.notice("Speech activity candidates: source=\(self.source.rawValue, privacy: .public) voiceIntervals=\(activity.voice.count) signalIntervals=\(activity.signal.count) replayResult=\(replay) candidate=\(candidate) audioEnd=\(activity.latestAudioEnd) voiceTimes=\(summary, privacy: .public)")
    }

    /// Runs on the existing conversion queue. Counts live incoming buffers only;
    /// replayed openings never masquerade as evidence of continued hardware input.
    private func recordCaptureArrival(frames: AVAudioFrameCount) {
        guard captureMetricsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let lastCaptureArrival { largestCaptureGap = max(largestCaptureGap, now - lastCaptureArrival) }
        lastCaptureArrival = now
        capturedBufferCount += 1
        capturedFrameCount += UInt64(frames)
        guard capturedBufferCount == 1 || now - lastCaptureReport >= 30 else { return }
        lastCaptureReport = now
        let elapsed = now - createdAt
        timingLogger.notice("Live capture progress: source=\(self.source.rawValue, privacy: .public) elapsed=\(elapsed) buffers=\(self.capturedBufferCount) frames=\(self.capturedFrameCount) largestArrivalGap=\(self.largestCaptureGap)")
    }

    /// The caller owns the incoming framework buffer. Copy before returning from its callback.
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double? = nil) {
        enqueue(buffer, hostTime: hostTime, replay: false)
    }

    /// The Auto bridge already bounds replay audio to 120 seconds. Replay uses backpressure.
    func replay(_ buffer: AVAudioPCMBuffer, hostTime: Double) {
        enqueue(buffer, hostTime: hostTime, replay: true)
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: Double?, replay: Bool) {
        let accepted = shared.withLock { state in
            guard state.accepting else { return false }
            guard replay || state.pendingBuffers < 128 else { return false }
            if !replay { state.pendingBuffers += 1 }
            return true
        }
        guard accepted else {
            if shared.withLock({ $0.accepting }) { reportFailure(AudioTranscriptionError.audioBacklog) }
            return
        }
        do {
            let copy = try PCMBufferConversion.copy(buffer)
            let copied = SendablePCM(copy)
            let time = hostTime ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds
            queue.async { [self] in
                defer { if !replay { shared.withLock { $0.pendingBuffers -= 1 } } }
                guard shared.withLock({ $0.accepting }) else { return }
                if !receivedFirstBuffer {
                    receivedFirstBuffer = true
                    logStartup("audio.firstBuffer")
                }
                if !replay { recordCaptureArrival(frames: copied.buffer.frameLength) }
                do {
                    let signature = MicrophoneFormatSignature(format: copied.buffer.format)
                    let gap = lastInputEndHostTime.map { time - $0 > AudioInputTimeline.gapTolerance } ?? false
                    if lastInputFormat != nil, lastInputFormat != signature || gap {
                        // A route transition ends the old resampler; never blend two devices or lose its tail.
                        for tail in try converter.finishConversion() { try yield(tail, replay: lastInputWasReplay) }
                    }
                    lastInputFormat = signature
                    lastInputEndHostTime = time + Double(copied.buffer.frameLength) / copied.buffer.format.sampleRate
                    lastInputWasReplay = replay
                    let convertedBuffer = try converter.convert(copied.buffer)
                    diagnostics.record(input: copied.buffer, output: convertedBuffer)
                    if let converted = convertedBuffer {
                        shared.withLock { $0.receivedAudio = true }
                        try yield(converted, hostTime: time, replay: replay)
                        let now = ProcessInfo.processInfo.systemUptime
                        if now - lastLevelTime >= 0.08 {
                            lastLevelTime = now
                            let level = PCMBufferConversion.level(of: converted)
                            Task { @MainActor [onLevel] in onLevel(level) }
                        }
                    }
                } catch { reportFailure(error) }
            }
        } catch {
            if !replay { shared.withLock { $0.pendingBuffers -= 1 } }
            reportFailure(error)
        }
    }

    func accept(_ sample: CMSampleBuffer) {
        do {
            let buffer = try PCMBufferConversion.copy(sample)
            let time = sample.presentationTimeStamp.seconds
            accept(buffer, hostTime: time.isFinite ? time : nil)
        } catch { reportFailure(error) }
    }

    private func yield(_ buffer: AVAudioPCMBuffer, hostTime: Double? = nil, replay: Bool = false) throws {
        let frame = timeline.nextStart(frameLength: Int64(buffer.frameLength), hostTime: hostTime)
        let start = CMTime(value: frame, timescale: CMTimeScale(converter.targetFormat.sampleRate))
        speechActivity.observe(buffer, at: start.seconds, isReplay: replay)
        let value = AnalyzerInput(buffer: buffer, bufferStartTime: start)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while shared.withLock({ $0.accepting }) {
            switch input.yield(value) {
            case .enqueued:
                return
            case .dropped:
                // bufferingOldest rejects this new value; retry the same buffer without losing it.
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw AudioTranscriptionError.audioBacklog
                }
                Thread.sleep(forTimeInterval: 0.002)
            case .terminated: return
            @unknown default: throw AudioTranscriptionError.audioBacklog
            }
        }
    }

    func finish() async throws {
        // Source capture is stopped first. This queue barrier drains every already-copied buffer.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    for tail in try converter.flush() { try yield(tail, replay: lastInputWasReplay) }
                    speechActivity.finish()
                    shared.withLock { $0.accepting = false }
                    input.finish()
                    continuation.resume()
                } catch {
                    shared.withLock { $0.accepting = false }
                    input.finish()
                    continuation.resume(throwing: error)
                }
            }
        }
        if shared.withLock({ $0.receivedAudio }) {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } else {
            await analyzer.cancelAndFinishNow()
        }
        // Results delivery crosses MainActor before this returns, so Export includes final words.
        await resultsTask?.value
        resultsTask = nil
    }

    func cancel() async {
        shared.withLock { $0.accepting = false }
        input.finish()
        resultsTask?.cancel()
        await analyzer.cancelAndFinishNow()
        await resultsTask?.value
        resultsTask = nil
    }

    private func reportFailure(_ error: Error) {
        let shouldReport = shared.withLock { state in
            guard !state.failureReported, state.accepting else { return false }
            state.failureReported = true
            return true
        }
        if shouldReport { Task { @MainActor [onFailure] in onFailure(error) } }
    }
}

private struct SendablePCM: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
