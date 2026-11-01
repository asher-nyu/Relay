import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import Relay

/// Deterministic PCM checks exercise the adapter and its actual AEC processor.
/// They do not establish performance in a physical room or open audio devices.
@Suite("Explicit-reference echo pipeline", .serialized)
@MainActor
struct ReferenceEchoPipelineTests {
    private let rate = 48_000.0

    @Test("Bypass preserves fragmented samples, a 257-sample tail, and original host times")
    func bypassFramingAndTail() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures, enabled: false)
        try await pipeline.start()
        let samples = signal(count: 3 * 480 + 257, seed: 11)
        var cursor = 0
        for count in [137, 251, 575, 734] {
            pipeline.accept(try buffer(Array(samples[cursor..<(cursor + count)])),
                            hostTime: 1_000 + Double(cursor) / rate)
            cursor += count
        }
        try await pipeline.drain()
        let output = sink.snapshot
        #expect(output.samples == samples)
        #expect(output.chunks.map { $0.samples.count } == [480, 480, 480, 257])
        for (index, chunk) in output.chunks.enumerated() {
            #expect(abs((chunk.hostTime ?? 0) - (1_000 + Double(index) * 0.01)) < 0.000_001)
            #expect(chunk.sampleRate == rate && chunk.channels == 1)
        }
        #expect(failures.errors.isEmpty)
        expectDownstreamLifecycleUntouched(output)
        try await pipeline.finish()
        pipeline.accept(try buffer([0.5, 0.5]), hostTime: 2_000)
        #expect(sink.snapshot.sampleCount == samples.count)
    }

    @Test("Conversion normalizes stereo input to 48 kHz primary-channel microphone audio")
    func convertsStereoWithoutChoosingTheSilentChannel() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures, enabled: false)
        let inputRate = 44_100.0
        let first = (0..<8_820).map { Float(0.18 * sin(Double($0) * 2 * .pi * 700 / inputRate)) }
        let second = [Float](repeating: 0, count: first.count)
        pipeline.accept(try buffer(first, sampleRate: inputRate, secondChannel: second), hostTime: 1_000)
        try await pipeline.drain()
        let output = sink.snapshot
        #expect(abs(output.sampleCount - 9_600) <= 64)
        try #require(output.sampleCount > 1_000)
        #expect(output.chunks.allSatisfy { $0.sampleRate == rate && $0.channels == 1 && $0.samples.count <= 480 })
        #expect(output.samples.allSatisfy { $0.isFinite })
        #expect(rms(output.samples, in: 500..<(output.sampleCount - 500)) > 0.08)
        #expect(abs((output.chunks.first?.hostTime ?? 0) - 1_000) < 0.000_001)
        #expect(failures.errors.isEmpty)
    }

    @Test("A device gap flushes the partial frame without fabricating speech across the gap")
    func gapKeepsOldTailAndNewEpoch() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures, enabled: false)
        let first = signal(count: 257, seed: 12)
        let second = signal(count: 480, seed: 13)
        pipeline.accept(try buffer(first), hostTime: 1_000)
        pipeline.accept(try buffer(second), hostTime: 1_002)
        try await pipeline.drain()
        let output = sink.snapshot
        #expect(output.samples == first + second)
        #expect(output.chunks.map { $0.samples.count } == [257, 480])
        #expect(output.chunks.compactMap(\.hostTime) == [1_000, 1_002])
        #expect(failures.errors.isEmpty)
    }

    @Test("A microphone callback can precede its reference while final padding stays invisible")
    func lateReferenceAndTrimmedTail() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures, referenceHold: 0.5)
        let samples = signal(count: 3 * 480 + 257, seed: 14)
        pipeline.accept(try buffer(samples.map { $0 * 0.5 }), hostTime: 1_000)
        pipeline.acceptReference(try buffer(samples), hostTime: 1_000)
        try await pipeline.drain()
        let output = sink.snapshot
        #expect(output.sampleCount == samples.count)
        #expect(output.chunks.last?.samples.count == 257)
        #expect(output.chunks.compactMap(\.hostTime).enumerated().allSatisfy {
            abs($0.element - (1_000 + Double($0.offset) * 0.01)) < 0.000_001
        })
        #expect(output.samples.allSatisfy { $0.isFinite })
        #expect(failures.errors.isEmpty)
    }

    @Test("Near-end audio is retained when no speaker reference is available", .timeLimit(.minutes(1)))
    func nearEndWithoutReferenceIsNotMuted() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures)
        let near = signal(count: 8 * 48_000, seed: 21)
        try await feed(microphone: near, into: pipeline, sink: sink)
        try await pipeline.drain()
        let output = sink.snapshot.samples
        try #require(output.count == near.count)
        #expect(output.allSatisfy { $0.isFinite })
        let retained = bestCorrelation(output: output, target: near, in: (2 * 48_000)..<(7 * 48_000))
        // High-pass/filter-bank processing changes phase and introduces delay;
        // exact sample equality or zero-lag correlation would be invalid here.
        #expect(retained.coefficient > 0.55)
        #expect(retained.gain > 0.35 && retained.gain < 1.5)
        #expect(failures.errors.isEmpty)
    }

    @Test("An explicit delayed reference reduces synthetic echo while retaining independent double talk", .timeLimit(.minutes(2)))
    func delayedEchoAndDoubleTalk() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures)
        let count = 26 * 48_000
        let far = signal(count: count, seed: 31)
        let independent = signal(count: count, seed: 32)
        var echo = [Float](repeating: 0, count: count)
        var near = [Float](repeating: 0, count: count)
        var microphone = [Float](repeating: 0, count: count)
        for index in 0..<count {
            for (delay, gain) in [(2_400, Float(0.42)), (2_880, Float(0.17)), (3_360, Float(0.08))] where index >= delay {
                echo[index] += far[index - delay] * gain
            }
            if index >= 16 * 48_000 { near[index] = independent[index] * 0.8 }
            microphone[index] = echo[index] + near[index]
        }
        try await feed(microphone: microphone, reference: far, into: pipeline, sink: sink)
        try await pipeline.drain()
        let output = sink.snapshot.samples
        try #require(output.count == count)
        #expect(output.allSatisfy { $0.isFinite })
        let adapted = (9 * 48_000)..<(15 * 48_000)
        let residualRatio = rms(output, in: adapted) / max(rms(echo, in: adapted), 0.000_001)
        #expect(residualRatio < 0.6, "The delayed synthetic echo should decrease after adaptation; this is not a physical-room guarantee.")
        let doubleTalk = bestCorrelation(output: output, target: near, in: (18 * 48_000)..<(24 * 48_000))
        #expect(doubleTalk.coefficient > 0.45)
        #expect(doubleTalk.gain > 0.25 && doubleTalk.gain < 1.5)
        #expect(failures.errors.isEmpty)
        expectDownstreamLifecycleUntouched(sink.snapshot)
    }

    @Test("Disabling echo processing passes subsequent PCM without restarting the recognizer")
    func changingPreferenceUsesBypassWithoutLifecycleChanges() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures)
        try await pipeline.start()
        let opening = signal(count: 480, seed: 41)
        pipeline.acceptReference(try buffer([Float](repeating: 0, count: 480)), hostTime: 1_000)
        pipeline.accept(try buffer(opening), hostTime: 1_000)
        try await waitUntil { sink.snapshot.sampleCount >= 480 }
        pipeline.setEnabled(false)
        let bypassed = signal(count: 2 * 480 + 257, seed: 42)
        pipeline.accept(try buffer(bypassed), hostTime: 1_000.01)
        try await pipeline.drain()
        let output = sink.snapshot
        #expect(Array(output.samples.dropFirst(480)) == bypassed)
        #expect(output.sampleCount == opening.count + bypassed.count)
        #expect(failures.errors.isEmpty)
        expectDownstreamLifecycleUntouched(output)
    }

    @Test("Immediate cancellation synchronously closes delivery and leaves downstream ownership alone")
    func cancellationClosesDelivery() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures, referenceHold: 0.5)
        pipeline.accept(try buffer(signal(count: 4_800, seed: 51)), hostTime: 1_000)
        pipeline.cancelImmediately()
        let countAtCancellation = sink.snapshot.sampleCount
        pipeline.accept(try buffer(signal(count: 480, seed: 52)), hostTime: 1_000.1)
        pipeline.acceptReference(try buffer(signal(count: 480, seed: 53)), hostTime: 1_000.1)
        await pipeline.cancel()
        try await pipeline.drain()
        #expect(sink.snapshot.sampleCount == countAtCancellation)
        #expect(failures.errors.isEmpty)
        expectDownstreamLifecycleUntouched(sink.snapshot)
    }

    @Test("An oversized callback reports one bounded-backlog failure and closes intake")
    func oversizedInputIsRejected() async throws {
        let sink = EchoRecordingSink()
        let failures = EchoFailures()
        let pipeline = try makePipeline(sink: sink, failures: failures, enabled: false)
        let oversized = try buffer([Float](repeating: 0.1, count: 96_001))
        pipeline.accept(oversized, hostTime: 1_000)
        pipeline.accept(oversized, hostTime: 1_003)
        pipeline.accept(try buffer([Float](repeating: 0.1, count: 480)), hostTime: 1_006)
        try await pipeline.drain()
        try await waitUntil { failures.errors.count == 1 }
        #expect(failures.errors.first as? AudioTranscriptionError == .audioBacklog)
        #expect(sink.snapshot.sampleCount == 0)
    }

    private func makePipeline(sink: EchoRecordingSink, failures: EchoFailures,
                              enabled: Bool = true, referenceHold: TimeInterval = 0) throws -> ReferenceEchoPipeline {
        try ReferenceEchoPipeline(downstream: sink, enabled: enabled, referenceHold: referenceHold,
                                  onFailure: { failures.errors.append($0) })
    }

    private func feed(microphone: [Float], reference: [Float]? = nil,
                      into pipeline: ReferenceEchoPipeline, sink: EchoRecordingSink) async throws {
        try await pipeline.start()
        if let reference { #expect(reference.count == microphone.count) }
        var cursor = 0
        while cursor < microphone.count {
            let batchEnd = min(microphone.count, cursor + 48_000)
            while cursor < batchEnd {
                let end = min(batchEnd, cursor + 480)
                let time = 1_000 + Double(cursor) / rate
                if let reference {
                    pipeline.acceptReference(try buffer(Array(reference[cursor..<end])), hostTime: time)
                }
                pipeline.accept(try buffer(Array(microphone[cursor..<end])), hostTime: time)
                cursor = end
            }
            // Observable downstream delivery provides backpressure without
            // sleeps that simulate real time or a production-only test hook.
            try await waitUntil { sink.snapshot.sampleCount >= cursor }
        }
    }

    private func buffer(_ samples: [Float], sampleRate: Double = 48_000,
                         secondChannel: [Float]? = nil) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                                channels: secondChannel == nil ? 1 : 2, interleaved: false))
        let result = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        result.frameLength = result.frameCapacity
        for index in samples.indices {
            result.floatChannelData![0][index] = samples[index]
            if let secondChannel { result.floatChannelData![1][index] = secondChannel[index] }
        }
        return result
    }

    private func signal(count: Int, seed: UInt64) -> [Float] {
        var state = seed
        var low = 0.0
        var previousLow = 0.0
        var high = 0.0
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let white = Double(Int32(truncatingIfNeeded: state >> 32)) / Double(Int32.max)
            low += 0.28 * (white - low)
            high = 0.96 * (high + low - previousLow)
            previousLow = low
            return Float(high * 0.3)
        }
    }

    private func rms(_ samples: [Float], in range: Range<Int>) -> Double {
        guard !range.isEmpty else { return 0 }
        return sqrt(range.reduce(0.0) { $0 + Double(samples[$1]) * Double(samples[$1]) } / Double(range.count))
    }

    private func bestCorrelation(output: [Float], target: [Float], in range: Range<Int>) -> EchoCorrelation {
        func evaluate(lag: Int, stride step: Int) -> EchoCorrelation {
            var cross = 0.0
            var targetEnergy = 0.0
            var outputEnergy = 0.0
            for index in stride(from: max(range.lowerBound, lag), to: min(range.upperBound, output.count), by: step) {
                let expected = Double(target[index - lag])
                let actual = Double(output[index])
                cross += expected * actual
                targetEnergy += expected * expected
                outputEnergy += actual * actual
            }
            return EchoCorrelation(coefficient: cross / max(sqrt(targetEnergy * outputEnergy), 0.000_000_001),
                                   gain: cross / max(targetEnergy, 0.000_000_001), lag: lag)
        }
        // Coarse-to-fine matching accounts for up to 50 ms of algorithmic
        // delay without an expensive full-rate quadratic correlation search.
        var best = EchoCorrelation(coefficient: -1, gain: 0, lag: 0)
        for lag in stride(from: 0, through: 2_400, by: 8) {
            let value = evaluate(lag: lag, stride: 24)
            if value.coefficient > best.coefficient { best = value }
        }
        for lag in max(0, best.lag - 8)...min(2_400, best.lag + 8) {
            let value = evaluate(lag: lag, stride: 8)
            if value.coefficient > best.coefficient { best = value }
        }
        return best
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("The echo pipeline did not finish the bounded test batch.")
                throw EchoTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func expectDownstreamLifecycleUntouched(_ state: EchoSinkSnapshot) {
        #expect(state.starts == 0 && state.finishes == 0 && state.cancels == 0)
        #expect(state.sampleBufferCalls == 0)
    }
}

private struct EchoCorrelation { let coefficient: Double; let gain: Double; let lag: Int }
private enum EchoTestError: Error { case timedOut }

@MainActor
private final class EchoFailures { var errors: [any Error] = [] }

private struct EchoOutputChunk: Sendable {
    let samples: [Float]
    let hostTime: Double?
    let sampleRate: Double
    let channels: AVAudioChannelCount
}

private struct EchoSinkSnapshot: Sendable {
    var chunks: [EchoOutputChunk] = []
    var sampleCount = 0
    var starts = 0
    var finishes = 0
    var cancels = 0
    var sampleBufferCalls = 0
    var samples: [Float] { chunks.flatMap(\.samples) }
}

private final class EchoRecordingSink: AudioTranscriptionPipeline, @unchecked Sendable {
    private let storage = Mutex(EchoSinkSnapshot())
    var snapshot: EchoSinkSnapshot { storage.withLock { $0 } }
    func start() async throws { storage.withLock { $0.starts += 1 } }
    func finish() async throws { storage.withLock { $0.finishes += 1 } }
    func cancel() async { storage.withLock { $0.cancels += 1 } }
    func accept(_ sample: CMSampleBuffer) { storage.withLock { $0.sampleBufferCalls += 1 } }
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        let count = Int(buffer.frameLength)
        let samples = buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: count)) } ?? []
        storage.withLock {
            $0.chunks.append(EchoOutputChunk(samples: samples, hostTime: hostTime,
                                            sampleRate: buffer.format.sampleRate, channels: buffer.format.channelCount))
            $0.sampleCount += count
        }
    }
}
