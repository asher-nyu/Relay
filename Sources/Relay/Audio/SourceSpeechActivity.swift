@preconcurrency import AVFoundation
import Foundation
import OSLog
import RelayAEC
import Synchronization

struct SpeechActivityInterval: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
}

/// A bounded, source-local history of times only. It contains no PCM or words.
struct SpeechActivitySnapshot: Sendable {
    // Voice intervals contain VAD-positive frames with independent signal
    // support. Classifier hangover at the room-noise floor is not voice evidence.
    var voice: [SpeechActivityInterval] = []
    var signal: [SpeechActivityInterval] = []
    var latestAudioEnd: TimeInterval = 0
    var replayThrough: TimeInterval?

    func onset(after boundary: TimeInterval, through end: TimeInterval,
               preservingReplayOrder: Bool = false) -> TimeInterval? {
        let upper = min(end, latestAudioEnd)
        let lower = max(0, boundary)
        guard upper >= lower else { return nil }
        let voiced = candidates(in: voice, after: lower, through: upper)
        if let detected = Self.episodeOnset(voiced, preservingReplayOrder: preservingReplayOrder) { return detected }
        // Quiet short speech can miss VAD. Recent signal-onset evidence is safer
        // than reusing an earlier analyzed range or a startup noise transient.
        return Self.episodeOnset(candidates(in: signal, after: lower, through: upper),
                                 preservingReplayOrder: preservingReplayOrder)
    }

    private static func episodeOnset(_ candidates: [SpeechActivityInterval],
                                     preservingReplayOrder: Bool) -> Double? {
        guard let first = candidates.first else { return nil }
        guard !preservingReplayOrder else { return first.start }
        var onset = first.start
        for index in candidates.indices.dropFirst() {
            if candidates[index].start - candidates[index - 1].end >= 2 {
                // No ASR phrase ever claimed the earlier episode. A new live
                // episode after a long quiet gap must not inherit startup noise.
                onset = candidates[index].start
            }
        }
        return onset
    }

    private func candidates(in intervals: [SpeechActivityInterval], after lower: Double,
                            through upper: Double) -> [SpeechActivityInterval] {
        var clusters: [(interval: SpeechActivityInterval, supportedDuration: Double)] = []
        for interval in intervals where interval.start <= upper && interval.end > lower {
            let end = min(upper, interval.end)
            let supportedStart = max(lower, interval.start)
            guard end > supportedStart else { continue }
            if let previous = clusters.last, interval.start - previous.interval.end <= 0.65 {
                // The gaps join words into an episode; they are never counted
                // as voiced duration. Nor can overlapping input double-count it.
                clusters[clusters.count - 1].supportedDuration += max(0, end - max(supportedStart, previous.interval.end))
                clusters[clusters.count - 1].interval.end = max(previous.interval.end, end)
            } else {
                clusters.append((SpeechActivityInterval(start: interval.start, end: end), end - supportedStart))
            }
        }
        return clusters.compactMap { cluster in
            let interval = cluster.interval
            guard interval.end > lower, interval.start <= upper else { return nil }
            guard cluster.supportedDuration >= 0.039_9 else { return nil }
            if interval.start >= lower - 0.02 { return SpeechActivityInterval(start: max(lower, interval.start), end: interval.end) }
            // Classic VAD retains a short hangover after speech ends. That tail
            // must not anchor a new utterance separated by a long quiet gap.
            // Truly continuous speech can still cross an ASR phrase boundary.
            return interval.end > lower + 0.3 ? SpeechActivityInterval(start: lower, end: interval.end) : nil
        }
    }
}

struct SpeechActivityHistory: Sendable {
    static let maximumIntervals = 4_096
    static let retainedDuration: TimeInterval = 300
    private(set) var snapshot = SpeechActivitySnapshot()
    private var voiceCandidate: Double?
    private var voiceCount = 0
    private var signalCandidate: Double?
    private var signalCount = 0

    mutating func append(start: Double, duration: Double, voice: Bool, signal: Bool) {
        guard start.isFinite, start >= 0, duration.isFinite, duration > 0 else { return }
        let end = start + duration
        guard end.isFinite else { return }
        snapshot.latestAudioEnd = max(snapshot.latestAudioEnd, end)
        if voice && signal {
            if voiceCandidate == nil { voiceCandidate = start }
            voiceCount += 1
            if voiceCount >= 2 {
                Self.appendInterval(to: &snapshot.voice, start: voiceCandidate ?? start, end: end)
            }
        } else { voiceCandidate = nil; voiceCount = 0 }
        if signal {
            if signalCandidate == nil { signalCandidate = start }
            signalCount += 1
            if signalCount >= 2 {
                Self.appendInterval(to: &snapshot.signal, start: signalCandidate ?? start, end: end)
            }
        } else { signalCandidate = nil; signalCount = 0 }
        trim()
    }

    mutating func advance(to end: Double, isReplay: Bool = false) {
        guard end.isFinite, end >= 0 else { return }
        snapshot.latestAudioEnd = max(snapshot.latestAudioEnd, end)
        if isReplay { snapshot.replayThrough = max(snapshot.replayThrough ?? 0, end) }
        trim()
    }

    mutating func discontinuity() {
        voiceCandidate = nil; voiceCount = 0
        signalCandidate = nil; signalCount = 0
    }

    private static func appendInterval(to intervals: inout [SpeechActivityInterval], start: Double, end: Double) {
        // Preserve rejected frames as gaps. A permissive 15 ms merge would
        // accidentally count a 10 ms noise-only frame as supported activity.
        if let last = intervals.last, start <= last.end + 0.000_001 {
            intervals[intervals.count - 1].end = max(last.end, end)
        } else { intervals.append(SpeechActivityInterval(start: start, end: end)) }
    }

    private mutating func trim() {
        let cutoff = max(0, snapshot.latestAudioEnd - Self.retainedDuration)
        Self.trim(&snapshot.voice, before: cutoff)
        Self.trim(&snapshot.signal, before: cutoff)
    }

    private static func trim(_ intervals: inout [SpeechActivityInterval], before cutoff: Double) {
        // Intervals are chronological. Avoid scanning the entire history on
        // every 10 ms frame, and amortize cap compaction in bounded batches.
        var expired = 0
        while expired < intervals.count, intervals[expired].end <= cutoff { expired += 1 }
        if intervals.count - expired > maximumIntervals {
            expired = max(expired, min(intervals.count, max(256, intervals.count - maximumIntervals)))
        }
        if expired > 0 { intervals.removeFirst(expired) }
        if !intervals.isEmpty { intervals[0].start = max(cutoff, intervals[0].start) }
    }
}

/// Observe the exact analyzed PCM clock. VAD is timing metadata only: it never
/// gates, replaces, or removes an AnalyzerInput buffer or recognized word.
final class SourceSpeechActivity: @unchecked Sendable {
    private let state = Mutex(SpeechActivityHistory())
    private let converter: PCMBufferConversion
    private var handle: OpaquePointer?
    // The source's conversion queue owns all remaining detector state.
    private var frames: [Float] = []
    private var frameStart: Double?
    private var conversionEnd: Double?
    private var previousInputEnd: Double?
    private var previousFormat: MicrophoneFormatSignature?
    private var noiseFloor = 0.000_001
    private let source: TranscriptSource?
    private let metricsEnabled = ProcessInfo.processInfo.environment["RELAY_SPEECH_TIMING_METRICS"] == "1"
    private let logger = Logger(subsystem: "com.asherbloom.Relay", category: "SpeechActivity")
    private var lastReport: TimeInterval = 0
    private var lastInputWasReplay = false

    init(source: TranscriptSource? = nil) {
        self.source = source
        // Mode 1 favors retaining quiet speech. The detector cannot censor ASR.
        handle = relay_vad_create(1)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                  sampleRate: 16_000, channels: 1, interleaved: false)!
        converter = PCMBufferConversion(targetFormat: format)
    }

    deinit { if let handle { relay_vad_destroy(handle) } }

    var snapshot: SpeechActivitySnapshot { state.withLock { $0.snapshot } }

    func observe(_ buffer: AVAudioPCMBuffer, at time: Double, isReplay: Bool = false) {
        let end = time + Double(buffer.frameLength) / buffer.format.sampleRate
        state.withLock { $0.advance(to: end, isReplay: isReplay) }
        lastInputWasReplay = isReplay
        do {
            let signature = MicrophoneFormatSignature(format: buffer.format)
            let gap = previousInputEnd.map { abs(time - $0) > AudioInputTimeline.gapTolerance } ?? false
            if previousFormat != nil, previousFormat != signature || gap {
                for tail in try converter.finishConversion() { inspect(tail, at: conversionEnd ?? time) }
                finishPartialFrame()
                if let handle, relay_vad_reset(handle) != 0 {
                    relay_vad_destroy(handle)
                    self.handle = nil
                }
                state.withLock { $0.discontinuity() }
                conversionEnd = nil
                noiseFloor = 0.000_001
            }
            previousFormat = signature
            previousInputEnd = end
            if conversionEnd == nil { conversionEnd = time }
            if let converted = try converter.convert(buffer) { inspect(converted, at: conversionEnd ?? time) }
        } catch {
            // Timing support can fail without interrupting a healthy recognizer.
            // The latest analyzed-audio endpoint remains a bounded fallback.
            frames.removeAll(keepingCapacity: true)
            frameStart = nil
            conversionEnd = nil
            state.withLock { $0.discontinuity() }
        }
    }

    func finish() {
        do {
            for tail in try converter.flush() { inspect(tail, at: conversionEnd ?? previousInputEnd ?? 0) }
            finishPartialFrame()
        } catch { }
    }

    private func inspect(_ buffer: AVAudioPCMBuffer, at time: Double) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        if frameStart == nil { frameStart = time }
        frames.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        conversionEnd = time + Double(buffer.frameLength) / 16_000
        var offset = 0
        while frames.count - offset >= 160 {
            inspectFrame(Array(frames[offset..<(offset + 160)]), at: frameStart ?? time, valid: 160)
            offset += 160
            frameStart = (frameStart ?? time) + 0.01
        }
        if offset > 0 { frames.removeFirst(offset) }
        if frames.isEmpty { frameStart = nil }
    }

    private func finishPartialFrame() {
        guard !frames.isEmpty, let frameStart else { return }
        let count = frames.count
        var padded = frames
        padded.append(contentsOf: repeatElement(0, count: 160 - count))
        inspectFrame(padded, at: frameStart, valid: count)
        frames.removeAll(keepingCapacity: true)
        self.frameStart = nil
    }

    private func inspectFrame(_ samples: [Float], at time: Double, valid: Int) {
        var sum = 0.0
        for value in samples.prefix(valid) {
            if value.isFinite { sum += Double(value) * Double(value) }
        }
        let rms = sqrt(sum / Double(max(1, valid)))
        var isVoice = false
        if let handle {
            let result = samples.withUnsafeBufferPointer { relay_vad_process(handle, $0.baseAddress, 160) }
            if result < 0 {
                relay_vad_destroy(handle)
                self.handle = nil
            } else { isVoice = result == 1 }
        }
        let isSignal = rms > max(0.000_005, noiseFloor * 1.6)
        if !isVoice { noiseFloor += 0.02 * (rms - noiseFloor) }
        state.withLock { $0.append(start: time, duration: Double(valid) / 16_000,
                                  voice: isVoice, signal: isSignal) }
        if metricsEnabled { reportActivity(rms: rms, voice: isVoice, signal: isSignal) }
    }

    private func reportActivity(rms: Double, voice: Bool, signal: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 1 else { return }
        lastReport = now
        let value = snapshot
        let sourceName = source?.rawValue ?? "fixture"
        let firstStart = value.voice.first?.start ?? -1
        let firstEnd = value.voice.first?.end ?? -1
        let lastStart = value.voice.last?.start ?? -1
        let lastEnd = value.voice.last?.end ?? -1
        let firstSignal = value.signal.first?.start ?? -1
        let lastSignal = value.signal.last?.start ?? -1
        logger.notice("Source activity: source=\(sourceName, privacy: .public) audioEnd=\(value.latestAudioEnd) rms=\(rms) noiseFloor=\(self.noiseFloor) rawVoiceNow=\(voice) supportedVoiceNow=\(voice && signal) signalNow=\(signal) detectorAvailable=\(self.handle != nil) replayNow=\(self.lastInputWasReplay) replayThrough=\(value.replayThrough ?? -1) voiceIntervals=\(value.voice.count) firstVoiceStart=\(firstStart) firstVoiceEnd=\(firstEnd) lastVoiceStart=\(lastStart) lastVoiceEnd=\(lastEnd) signalIntervals=\(value.signal.count) firstSignalStart=\(firstSignal) lastSignalStart=\(lastSignal)")
    }
}
