@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import OSLog
import RelayAEC
import Synchronization

/// Uses the captured speaker signal as an explicit AEC3 reverse reference. Audio
/// stays in memory. This adapter owns neither the downstream recognizer's start
/// nor its finish/cancel lifecycle; the capture service owns those operations.
final class ReferenceEchoPipeline: AudioTranscriptionPipeline, @unchecked Sendable {
    private static let sampleRate = 48_000.0
    private static let frameSize = 480
    private static let frameDuration = 0.01
    private static let referenceHistory = 2.0
    private let downstream: any AudioTranscriptionPipeline
    private let onFailure: @MainActor @Sendable (Error) -> Void
    private let queue = DispatchQueue(label: "com.asherbloom.Relay.echoCancellation", qos: .userInitiated)
    private let shared = Mutex(Intake())
    private let handle: OpaquePointer
    private let format: AVAudioFormat
    private let referenceHold: TimeInterval
    private let metricsEnabled = ProcessInfo.processInfo.environment["RELAY_ECHO_METRICS"] == "1"
    private let metricsLogger = Logger(subsystem: "com.asherbloom.Relay", category: "EchoMetrics")
    private let microphone: EchoInput
    private let reference: EchoInput
    // Everything below is confined to queue.
    private var enabled: Bool
    private var pendingMicrophone: [EchoFrame] = []
    private var microphoneOffset = 0
    private var pendingReference: [EchoFrame] = []
    private var referenceOffset = 0
    private var lastReverseTime: Double?
    private var flushTask: DispatchWorkItem?
    private var failure: Error?
    private var drained = false
    private var metrics = EchoMetrics()

    private struct Intake {
        var accepting = true
        var cancelled = false
        var pendingDuration = 0.0
        var reportedFailure = false
    }

    init(downstream: any AudioTranscriptionPipeline, enabled: Bool = true,
         referenceHold: TimeInterval = 0.2,
         onFailure: @escaping @MainActor @Sendable (Error) -> Void) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let handle = relay_aec_create(Int32(Self.sampleRate)) else {
            throw ReferenceEchoError.unavailable
        }
        guard relay_aec_frame_size(handle) == Self.frameSize else {
            relay_aec_destroy(handle)
            throw ReferenceEchoError.unavailable
        }
        self.handle = handle
        self.format = format
        self.downstream = downstream
        self.enabled = enabled
        self.onFailure = onFailure
        self.referenceHold = min(0.5, max(0, referenceHold.isFinite ? referenceHold : 0.2))
        microphone = EchoInput(format: format, policy: .primaryMicrophoneChannel)
        reference = EchoInput(format: format, policy: .automaticLayout)
    }

    deinit { relay_aec_destroy(handle) }

    func start() async throws {
        try Task.checkCancellation()
        guard shared.withLock({ $0.accepting && !$0.cancelled }) else { throw CancellationError() }
    }

    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double? = nil) {
        enqueue(buffer, hostTime: hostTime, isReference: false)
    }

    func accept(_ sample: CMSampleBuffer) {
        acceptSample(sample, isReference: false)
    }

    func acceptReference(_ buffer: AVAudioPCMBuffer, hostTime: Double? = nil) {
        enqueue(buffer, hostTime: hostTime, isReference: true)
    }

    func acceptReference(_ sample: CMSampleBuffer) {
        acceptSample(sample, isReference: true)
    }

    private func acceptSample(_ sample: CMSampleBuffer, isReference: Bool) {
        do {
            let buffer = try PCMBufferConversion.copy(sample)
            let hostTime = sample.presentationTimeStamp.seconds
            enqueue(buffer, hostTime: hostTime.isFinite ? hostTime : nil, isReference: isReference)
        } catch { reportFailure(error) }
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer, hostTime: Double?, isReference: Bool) {
        guard buffer.frameLength > 0, buffer.format.sampleRate.isFinite,
              buffer.format.sampleRate > 0 else { return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        let time = hostTime.flatMap { $0.isFinite ? $0 : nil }
            ?? CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let arrival = ProcessInfo.processInfo.systemUptime
        do {
            // Submission and closing intake share this lock. A drain barrier can
            // never overtake a buffer whose copy has already been accepted.
            try shared.withLock { intake in
                guard intake.accepting, !intake.cancelled else { return }
                guard duration <= 2, intake.pendingDuration + duration <= 4 else {
                    throw AudioTranscriptionError.audioBacklog
                }
                let copy = EchoPCM(try PCMBufferConversion.copy(buffer))
                intake.pendingDuration += duration
                queue.async { [self] in
                    defer { shared.withLock { $0.pendingDuration -= duration } }
                    guard shared.withLock({ !$0.cancelled }), failure == nil else { return }
                    do {
                        try consume(copy.buffer, hostTime: time, arrival: arrival, isReference: isReference)
                    } catch { failOnQueue(error) }
                }
            }
        } catch { reportFailure(error) }
    }

    /// Changes processing without restarting the microphone or touching the
    /// recognizer. Complete already-held near-end audio under the old setting.
    func setEnabled(_ value: Bool) {
        shared.withLock { intake in
            guard intake.accepting, !intake.cancelled else { return }
            queue.async { [self] in
                guard failure == nil, !drained, enabled != value,
                      shared.withLock({ !$0.cancelled }) else { return }
                do {
                    try processPending(force: true)
                    try resetProcessor()
                    enabled = value
                } catch { failOnQueue(error) }
            }
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, hostTime: Double,
                         arrival: TimeInterval, isReference: Bool) throws {
        let input = isReference ? reference : microphone
        if input.isDiscontinuous(buffer, at: hostTime) {
            if metricsEnabled { metrics.discontinuities += 1 }
            // Preserve the old resampler and partial-frame tail before resetting
            // adaptation. No microphone words disappear on a format/route gap.
            try append(input.finish(), isReference: isReference)
            try processPending(force: true)
            try resetProcessor()
            if isReference {
                pendingReference.removeAll(keepingCapacity: true)
                referenceOffset = 0
            }
        }
        try append(input.convert(buffer, at: hostTime, arrival: arrival), isReference: isReference)
        try processPending(force: false)
        scheduleFlushIfNeeded()
    }

    private func append(_ frames: [EchoFrame], isReference: Bool) throws {
        guard !frames.isEmpty else { return }
        if isReference {
            pendingReference.append(contentsOf: frames)
            if metricsEnabled {
                for frame in frames {
                    metrics.referenceFrames += 1
                    metrics.referenceSamples += frame.validSamples
                    metrics.referenceEnergy += Self.energy(frame.samples, count: frame.validSamples)
                }
                reportMetricsIfNeeded()
            }
            // A disconnected microphone must not grow a second audio recording.
            // Retain only the recent render history needed for future adaptation.
            let cutoff = (pendingReference.last?.hostTime ?? 0) - Self.referenceHistory
            while referenceOffset < pendingReference.count,
                  pendingReference[referenceOffset].hostTime < cutoff { referenceOffset += 1 }
            compactReference()
        } else {
            pendingMicrophone.append(contentsOf: frames)
            guard pendingMicrophone.count - microphoneOffset <= 200 else {
                throw AudioTranscriptionError.audioBacklog
            }
        }
    }

    private func processPending(force: Bool) throws {
        let now = ProcessInfo.processInfo.systemUptime
        while microphoneOffset < pendingMicrophone.count {
            guard shared.withLock({ !$0.cancelled }) else { return }
            let frame = pendingMicrophone[microphoneOffset]
            let referenceReady = pendingReference.last.map {
                $0.hostTime + Self.frameDuration >= frame.hostTime + Self.frameDuration - 0.005
            } ?? false
            guard force || !enabled || referenceReady || now - frame.arrival >= referenceHold else { break }
            if metricsEnabled, enabled, !referenceReady {
                metrics.missingReferenceFrames += 1
                if !force, now - frame.arrival >= referenceHold { metrics.holdTimeoutFrames += 1 }
            }
            let output: [Float]
            if enabled {
                try feedReference(through: frame.hostTime)
                var cleaned = [Float](repeating: 0, count: Self.frameSize)
                let delay = lastReverseTime.map { min(500, max(0, Int((frame.hostTime - $0) * 1_000))) } ?? 0
                let status = frame.samples.withUnsafeBufferPointer { near in
                    cleaned.withUnsafeMutableBufferPointer { destination in
                        relay_aec_process_capture(handle, near.baseAddress, destination.baseAddress,
                                                  Self.frameSize, Int32(delay))
                    }
                }
                try check(status)
                output = cleaned
            } else {
                output = frame.samples
                discardReference(before: frame.hostTime - Self.referenceHistory)
            }
            try deliver(output, frame: frame)
            if metricsEnabled {
                metrics.microphoneFrames += 1
                metrics.microphoneSamples += frame.validSamples
                metrics.rawEnergy += Self.energy(frame.samples, count: frame.validSamples)
                metrics.cleanEnergy += Self.energy(output, count: frame.validSamples)
                metrics.lastMicrophoneTime = frame.hostTime
                reportMetricsIfNeeded()
            }
            microphoneOffset += 1
        }
        if microphoneOffset > 0, microphoneOffset == pendingMicrophone.count || microphoneOffset >= 100 {
            pendingMicrophone.removeFirst(microphoneOffset)
            microphoneOffset = 0
        }
        compactReference()
    }

    private func feedReference(through microphoneTime: Double) throws {
        // Feed each render frame once, chronologically, before its matching
        // near-end frame. The 200 ms app hold is not an acoustic stream delay.
        while referenceOffset < pendingReference.count {
            let frame = pendingReference[referenceOffset]
            guard frame.hostTime <= microphoneTime + 0.005 else { break }
            referenceOffset += 1
            if let lastReverseTime, frame.hostTime < lastReverseTime + Self.frameDuration * 0.5 { continue }
            if let last = lastReverseTime {
                var next = last + Self.frameDuration
                // Silence fills only missing reference chronology. Near-end
                // speech is always passed through the adaptive processor.
                while next < frame.hostTime - 0.005, next <= microphoneTime {
                    if metricsEnabled { metrics.filledZeroReferenceFrames += 1 }
                    try sendReverse(Self.silence, at: next)
                    next += Self.frameDuration
                }
            }
            try sendReverse(frame.samples, at: frame.hostTime)
            if metricsEnabled { metrics.lastActualReferenceTime = frame.hostTime }
        }
        if lastReverseTime == nil || microphoneTime - (lastReverseTime ?? microphoneTime) >= Self.frameDuration * 0.75 {
            if metricsEnabled { metrics.filledZeroReferenceFrames += 1 }
            try sendReverse(Self.silence, at: microphoneTime)
        }
    }

    private static let silence = [Float](repeating: 0, count: frameSize)

    private func sendReverse(_ samples: [Float], at hostTime: Double) throws {
        let status = samples.withUnsafeBufferPointer {
            relay_aec_process_reverse(handle, $0.baseAddress, Self.frameSize)
        }
        try check(status)
        lastReverseTime = hostTime
    }

    private func deliver(_ samples: [Float], frame: EchoFrame) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frame.validSamples)), let channel = buffer.floatChannelData?[0] else {
            throw AudioTranscriptionError.audioFormat
        }
        buffer.frameLength = AVAudioFrameCount(frame.validSamples)
        for index in 0..<frame.validSamples {
            guard samples[index].isFinite else { throw ReferenceEchoError.processing(-10_001) }
            channel[index] = samples[index]
        }
        // Cancel closes delivery synchronously; its asynchronous barrier then
        // waits for all previously checked-out work before it returns.
        shared.withLock { intake in
            guard !intake.cancelled else { return }
            downstream.accept(buffer, hostTime: frame.hostTime)
        }
    }

    private func resetProcessor() throws {
        try check(relay_aec_reset(handle))
        lastReverseTime = nil
        if metricsEnabled {
            metrics.resets += 1
            metrics.lastActualReferenceTime = nil
        }
    }

    /// Opt-in aggregate signal statistics only. No samples, words, filenames,
    /// device identifiers, or recordings leave this serial in-memory pipeline.
    private func reportMetricsIfNeeded() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - metrics.lastReport >= 2 else { return }
        let elapsed = now - metrics.lastReport
        let rawRMS = sqrt(metrics.rawEnergy / Double(max(1, metrics.microphoneSamples)))
        let cleanRMS = sqrt(metrics.cleanEnergy / Double(max(1, metrics.microphoneSamples)))
        let referenceRMS = sqrt(metrics.referenceEnergy / Double(max(1, metrics.referenceSamples)))
        let delta = metrics.lastMicrophoneTime.flatMap { microphone in
            metrics.lastActualReferenceTime.map { (microphone - $0) * 1_000 }
        }
        let hasReferenceDelta = delta != nil
        let referenceDeltaMilliseconds = delta ?? 0
        let microphoneFrames = metrics.microphoneFrames
        let referenceFrames = metrics.referenceFrames
        let microphoneSamples = metrics.microphoneSamples
        let referenceSamples = metrics.referenceSamples
        let zeroReferenceFrames = metrics.filledZeroReferenceFrames
        let missingReferenceFrames = metrics.missingReferenceFrames
        let holdTimeoutFrames = metrics.holdTimeoutFrames
        let discontinuities = metrics.discontinuities
        let resets = metrics.resets
        metricsLogger.notice("Echo signal metrics: intervalSeconds=\(elapsed) enabled=\(self.enabled) rawMicRMS=\(rawRMS) cleanMicRMS=\(cleanRMS) referenceRMS=\(referenceRMS) micFrames=\(microphoneFrames) refFrames=\(referenceFrames) micSamples=\(microphoneSamples) refSamples=\(referenceSamples) zeroReferenceFrames=\(zeroReferenceFrames) missingReferenceFrames=\(missingReferenceFrames) holdTimeoutFrames=\(holdTimeoutFrames) discontinuities=\(discontinuities) resets=\(resets) hasReferenceDelta=\(hasReferenceDelta) micMinusReferenceMs=\(referenceDeltaMilliseconds)")
        metrics.clearInterval(at: now)
    }

    private static func energy(_ samples: [Float], count: Int) -> Double {
        var sum = 0.0
        for index in 0..<count {
            let sample = Double(samples[index])
            sum += sample * sample
        }
        return sum
    }

    private struct EchoMetrics {
        var lastReport = ProcessInfo.processInfo.systemUptime
        var microphoneFrames = 0
        var referenceFrames = 0
        var microphoneSamples = 0
        var referenceSamples = 0
        var rawEnergy = 0.0
        var cleanEnergy = 0.0
        var referenceEnergy = 0.0
        var filledZeroReferenceFrames = 0
        var missingReferenceFrames = 0
        var holdTimeoutFrames = 0
        var discontinuities = 0
        var resets = 0
        var lastMicrophoneTime: Double?
        var lastActualReferenceTime: Double?

        mutating func clearInterval(at time: TimeInterval) {
            let microphoneTime = lastMicrophoneTime
            let referenceTime = lastActualReferenceTime
            self = EchoMetrics()
            lastReport = time
            lastMicrophoneTime = microphoneTime
            lastActualReferenceTime = referenceTime
        }
    }

    private func discardReference(before time: Double) {
        while referenceOffset < pendingReference.count,
              pendingReference[referenceOffset].hostTime < time { referenceOffset += 1 }
    }

    private func compactReference() {
        if referenceOffset > 0, referenceOffset == pendingReference.count || referenceOffset >= 100 {
            pendingReference.removeFirst(referenceOffset)
            referenceOffset = 0
        }
    }

    private func scheduleFlushIfNeeded() {
        flushTask?.cancel()
        flushTask = nil
        guard microphoneOffset < pendingMicrophone.count else { return }
        let remaining = max(0, referenceHold - (ProcessInfo.processInfo.systemUptime
            - pendingMicrophone[microphoneOffset].arrival))
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.drained, self.failure == nil,
                  self.shared.withLock({ !$0.cancelled }) else { return }
            self.flushTask = nil
            do {
                try self.processPending(force: false)
                self.scheduleFlushIfNeeded()
            } catch { self.failOnQueue(error) }
        }
        flushTask = work
        queue.asyncAfter(deadline: .now() + max(0.001, remaining), execute: work)
    }

    /// Capture producers and their callback queues stop before this call. Flush
    /// the final sub-10 ms near-end tail, trimming padding before downstream.
    func drain() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            shared.withLock { intake in
                intake.accepting = false
                queue.async { [self] in
                    do {
                        flushTask?.cancel()
                        flushTask = nil
                        if !drained, !shared.withLock({ $0.cancelled }), failure == nil {
                            try append(reference.finish(), isReference: true)
                            try append(microphone.finish(), isReference: false)
                            try processPending(force: true)
                        }
                        drained = true
                        if let failure { throw failure }
                        continuation.resume()
                    } catch {
                        drained = true
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    func finish() async throws { try await drain() }

    func cancelImmediately() {
        shared.withLock { $0.accepting = false; $0.cancelled = true }
    }

    func cancel() async {
        cancelImmediately()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                flushTask?.cancel()
                flushTask = nil
                pendingMicrophone.removeAll()
                pendingReference.removeAll()
                microphoneOffset = 0
                referenceOffset = 0
                drained = true
                continuation.resume()
            }
        }
    }

    private func check(_ status: Int32) throws {
        guard status == 0 else { throw ReferenceEchoError.processing(status) }
    }

    private func failOnQueue(_ error: Error) {
        failure = error
        flushTask?.cancel()
        flushTask = nil
        reportFailure(error)
    }

    private func reportFailure(_ error: Error) {
        let report = shared.withLock { intake in
            guard !intake.reportedFailure, !intake.cancelled else { return false }
            intake.accepting = false
            intake.reportedFailure = true
            return true
        }
        if report { Task { @MainActor [onFailure] in onFailure(error) } }
    }
}

private struct EchoPCM: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private struct EchoFrame {
    let samples: [Float]
    let validSamples: Int
    let hostTime: Double
    let arrival: TimeInterval
}

/// Queue-confined resampling and 10 ms framing. The original capture host clock
/// follows every output frame, including converter tails and final padding.
private final class EchoInput {
    private let converter: PCMBufferConversion
    private var signature: MicrophoneFormatSignature?
    private var inputEnd: Double?
    private var outputEnd: Double?
    private var samples: [Float] = []
    private var start: Double?
    private var offset = 0
    private var bufferedArrival: TimeInterval?
    private let rate = 48_000.0
    private let frameSize = 480

    init(format: AVAudioFormat, policy: PCMBufferConversion.MonoInputPolicy) {
        converter = PCMBufferConversion(targetFormat: format, monoInputPolicy: policy)
    }

    func isDiscontinuous(_ buffer: AVAudioPCMBuffer, at hostTime: Double) -> Bool {
        guard let signature else { return false }
        if signature != MicrophoneFormatSignature(format: buffer.format) { return true }
        return inputEnd.map { abs(hostTime - $0) > AudioInputTimeline.gapTolerance } ?? false
    }

    func convert(_ buffer: AVAudioPCMBuffer, at hostTime: Double, arrival: TimeInterval) throws -> [EchoFrame] {
        signature = MicrophoneFormatSignature(format: buffer.format)
        inputEnd = hostTime + Double(buffer.frameLength) / buffer.format.sampleRate
        if outputEnd == nil { outputEnd = hostTime }
        let time = outputEnd ?? hostTime
        guard let converted = try converter.convert(buffer) else { return [] }
        return try append(converted, at: time, arrival: arrival, final: false)
    }

    func finish() throws -> [EchoFrame] {
        var frames: [EchoFrame] = []
        for tail in try converter.finishConversion() {
            frames.append(contentsOf: try append(tail, at: outputEnd ?? inputEnd ?? 0,
                arrival: bufferedArrival ?? ProcessInfo.processInfo.systemUptime, final: false))
        }
        frames.append(contentsOf: takeFrames(final: true))
        signature = nil
        inputEnd = nil
        outputEnd = nil
        return frames
    }

    private func append(_ buffer: AVAudioPCMBuffer, at time: Double,
                        arrival: TimeInterval, final: Bool) throws -> [EchoFrame] {
        guard let channel = buffer.floatChannelData?[0] else { throw AudioTranscriptionError.audioFormat }
        if start == nil { start = time; bufferedArrival = arrival }
        for index in 0..<Int(buffer.frameLength) {
            let value = channel[index]
            guard value.isFinite else { throw AudioTranscriptionError.audioConversion }
            samples.append(value)
        }
        outputEnd = time + Double(buffer.frameLength) / rate
        return takeFrames(final: final)
    }

    private func takeFrames(final: Bool) -> [EchoFrame] {
        var result: [EchoFrame] = []
        let arrival = bufferedArrival ?? ProcessInfo.processInfo.systemUptime
        while samples.count - offset >= frameSize || final && samples.count > offset {
            let count = min(frameSize, samples.count - offset)
            var block = [Float](repeating: 0, count: frameSize)
            block.replaceSubrange(0..<count, with: samples[offset..<(offset + count)])
            result.append(EchoFrame(samples: block, validSamples: count,
                hostTime: start ?? 0, arrival: arrival))
            offset += count
            start = (start ?? 0) + Double(count) / rate
        }
        if offset > 0 {
            samples.removeFirst(offset)
            offset = 0
        }
        if samples.isEmpty { start = nil; bufferedArrival = nil }
        return result
    }
}

private enum ReferenceEchoError: LocalizedError {
    case unavailable
    case processing(Int32)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Relay couldn’t prepare speaker echo reduction. Try starting the session again."
        case .processing:
            "Speaker echo reduction couldn’t process the incoming audio. The session stopped to avoid missing microphone speech."
        }
    }
}
