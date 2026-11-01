@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import Relay

/// Exercises the persistent native tap's destination without opening audio
/// hardware or reading PCM values. Buffers contain no user audio.
@Suite("Microphone tap destination", .serialized)
@MainActor
struct MicrophoneTapDestinationTests {
    @Test("Unbound taps and taps without a selected graph discard buffers")
    func unboundTapDoesNotForward() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let buffer = try makeBuffer()
        destination.selectGraph(graphID)
        destination.accept(buffer, hostTime: 12, graphID: graphID)

        let probe = DestinationMetadataProbe()
        let firstBuffers = DestinationFirstBufferProbe()
        destination.selectGraph(nil)
        destination.bind(probe, onFirstBuffer: { firstBuffers.record($0) })
        destination.accept(buffer, hostTime: 12, graphID: graphID)
        #expect(probe.snapshot().buffers == 0)
        #expect(firstBuffers.snapshot().isEmpty)
    }

    @Test("A matching graph forwards timing and signals its first nonempty buffer once")
    func matchingGraphForwardsAndReadinessIsOneShot() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe()
        let firstBuffers = DestinationFirstBufferProbe()
        destination.bind(probe, onFirstBuffer: { firstBuffers.record($0) })
        destination.selectGraph(graphID)
        let empty = try makeBuffer(frames: 0)
        let buffer = try makeBuffer(frames: 64)
        destination.accept(empty, hostTime: 9, graphID: graphID)
        #expect(probe.snapshot().buffers == 0)
        #expect(firstBuffers.snapshot().isEmpty)

        destination.accept(buffer, hostTime: 12.5, graphID: graphID)
        destination.accept(buffer, hostTime: 12.75, graphID: graphID)
        let snapshot = probe.snapshot()
        #expect(snapshot.buffers == 2 && snapshot.frames == 128)
        #expect(snapshot.lastHostTime == 12.75)
        #expect(firstBuffers.snapshot() == [graphID])
    }

    @Test("A stale native graph cannot deliver audio or announce readiness")
    func rejectsStaleGraphAfterReplacement() throws {
        let destination = MicrophoneTapDestination()
        let firstGraph = UUID()
        let replacementGraph = UUID()
        let probe = DestinationMetadataProbe()
        let firstBuffers = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.bind(probe, onFirstBuffer: { firstBuffers.record($0) })
        destination.selectGraph(firstGraph)
        destination.accept(buffer, hostTime: 1, graphID: firstGraph)
        destination.selectGraph(replacementGraph)
        destination.accept(buffer, hostTime: 2, graphID: firstGraph)
        #expect(probe.snapshot().buffers == 1)
        #expect(firstBuffers.snapshot() == [firstGraph])

        destination.accept(buffer, hostTime: 3, graphID: replacementGraph)
        #expect(probe.snapshot().buffers == 2)
        #expect(firstBuffers.snapshot() == [firstGraph, replacementGraph])
    }

    @Test("Closing a destination prevents further callbacks and releases its previous binding")
    func closedTapStaysSilentAndCanRebind() async throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let oldProbe = DestinationMetadataProbe()
        let newProbe = DestinationMetadataProbe()
        let oldFirst = DestinationFirstBufferProbe()
        let newFirst = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.bind(oldProbe, onFirstBuffer: { oldFirst.record($0) })
        destination.selectGraph(graphID)
        destination.accept(buffer, hostTime: 1, graphID: graphID)
        destination.close()
        await destination.drain()
        destination.accept(buffer, hostTime: 2, graphID: graphID)
        #expect(oldProbe.snapshot().buffers == 1)
        #expect(oldFirst.snapshot() == [graphID])

        destination.bind(newProbe, onFirstBuffer: { newFirst.record($0) })
        destination.selectGraph(graphID)
        destination.accept(buffer, hostTime: 3, graphID: graphID)
        #expect(oldProbe.snapshot().buffers == 1)
        #expect(newProbe.snapshot().buffers == 1)
        #expect(newFirst.snapshot() == [graphID])
    }

    @Test("Rebinding the same retained graph gives the new session its own readiness signal")
    func retainedGraphReadinessBelongsToCurrentBinding() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let first = DestinationMetadataProbe()
        let second = DestinationMetadataProbe()
        let firstReady = DestinationFirstBufferProbe()
        let secondReady = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.selectGraph(graphID)
        destination.bind(first, onFirstBuffer: { firstReady.record($0) })
        destination.accept(buffer, hostTime: 1, graphID: graphID)
        destination.bind(second, onFirstBuffer: { secondReady.record($0) })
        destination.accept(buffer, hostTime: 2, graphID: graphID)
        destination.accept(buffer, hostTime: 3, graphID: graphID)
        #expect(first.snapshot().buffers == 1 && second.snapshot().buffers == 2)
        #expect(firstReady.snapshot() == [graphID])
        #expect(secondReady.snapshot() == [graphID])
    }

    @Test("A retained-engine recovery rearms readiness without replacing its destination")
    func rearmPreservesGraphAndPipeline() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe()
        let firstCycle = DestinationFirstBufferProbe()
        let recoveryCycle = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.bind(probe, onFirstBuffer: { firstCycle.record($0) })
        destination.selectGraph(graphID)
        destination.accept(buffer, hostTime: 1, graphID: graphID)
        destination.rearmFirstBuffer { recoveryCycle.record($0) }
        destination.accept(buffer, hostTime: 2, graphID: graphID)
        destination.accept(buffer, hostTime: 3, graphID: graphID)
        #expect(probe.snapshot().buffers == 3)
        #expect(firstCycle.snapshot() == [graphID])
        #expect(recoveryCycle.snapshot() == [graphID])
    }

    @Test("An already checked-out first buffer keeps its old recovery callback")
    func rearmRejectsStaleFirstBufferCompletion() async throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe(blockDelivery: true)
        let previousCycle = DestinationFirstBufferProbe()
        let recoveryCycle = DestinationFirstBufferProbe()
        destination.bind(probe, onFirstBuffer: { previousCycle.record($0) })
        destination.selectGraph(graphID)
        let box = DestinationBufferBox(try makeBuffer())
        let oldDelivery = Task.detached {
            destination.accept(box.buffer, hostTime: 1, graphID: graphID)
        }
        defer { probe.unblock() }
        try await waitUntil { probe.snapshot().buffers == 1 }
        destination.rearmFirstBuffer { recoveryCycle.record($0) }
        probe.unblock()
        await oldDelivery.value
        #expect(previousCycle.snapshot() == [graphID])
        #expect(recoveryCycle.snapshot().isEmpty,
                "An old first-buffer completion must not announce readiness for the new recovery cycle.")
        probe.unblock()
        destination.accept(box.buffer, hostTime: 2, graphID: graphID)
        #expect(recoveryCycle.snapshot() == [graphID])
    }

    @Test("A new binding rejects old, absent, and nonfinite host times at its delivery boundary")
    func bindingCutoffPreventsPreviousSessionAudio() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe()
        let ready = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.bind(probe, onFirstBuffer: { ready.record($0) }, minimumHostTime: 10)
        destination.selectGraph(graphID)
        let rejectedTimes: [Double?] = [9.99, nil, .nan, .infinity, -.infinity]
        for hostTime in rejectedTimes {
            destination.accept(buffer, hostTime: hostTime, graphID: graphID)
        }
        #expect(probe.snapshot().buffers == 0 && ready.snapshot().isEmpty)
        destination.accept(buffer, hostTime: 10, graphID: graphID)
        destination.accept(buffer, hostTime: 10.01, graphID: graphID)
        #expect(probe.snapshot().buffers == 2)
        #expect(ready.snapshot() == [graphID])
    }

    @Test("Recovery keeps useful same-session tail audio but requires a newer buffer for readiness")
    func recoveryCutoffDoesNotDiscardCurrentSessionTail() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe()
        let initialReady = DestinationFirstBufferProbe()
        let recoveredReady = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.bind(probe, onFirstBuffer: { initialReady.record($0) }, minimumHostTime: 10)
        destination.selectGraph(graphID)
        destination.accept(buffer, hostTime: 10, graphID: graphID)
        destination.rearmFirstBuffer({ recoveredReady.record($0) }, minimumHostTime: 20)
        destination.accept(buffer, hostTime: 9, graphID: graphID)
        destination.accept(buffer, hostTime: 15, graphID: graphID)
        #expect(probe.snapshot().buffers == 2,
                "Tail audio after the session boundary must remain available to the same recognizer.")
        #expect(initialReady.snapshot() == [graphID] && recoveredReady.snapshot().isEmpty)
        destination.accept(buffer, hostTime: 20, graphID: graphID)
        destination.accept(buffer, hostTime: 21, graphID: graphID)
        #expect(probe.snapshot().buffers == 4 && recoveredReady.snapshot() == [graphID])
    }

    @Test("Unclocked recovery buffers cannot satisfy readiness even when delivery has no cutoff")
    func readinessCutoffRequiresFiniteHostTime() throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe()
        let ready = DestinationFirstBufferProbe()
        let buffer = try makeBuffer()
        destination.bind(probe, onFirstBuffer: { _ in })
        destination.selectGraph(graphID)
        destination.rearmFirstBuffer({ ready.record($0) }, minimumHostTime: 20)
        let invalidReadinessTimes: [Double?] = [nil, .nan, .infinity, -.infinity, 19.99]
        for hostTime in invalidReadinessTimes {
            destination.accept(buffer, hostTime: hostTime, graphID: graphID)
        }
        #expect(probe.snapshot().buffers == invalidReadinessTimes.count)
        #expect(ready.snapshot().isEmpty)
        destination.accept(buffer, hostTime: 20, graphID: graphID)
        #expect(ready.snapshot() == [graphID])
    }

    @Test("Close is synchronous while drain waits for a previously checked-out callback")
    func drainWaitsForInFlightDeliveryWithoutForwardingNewBuffers() async throws {
        let destination = MicrophoneTapDestination()
        let graphID = UUID()
        let probe = DestinationMetadataProbe(blockDelivery: true)
        let firstBuffers = DestinationFirstBufferProbe()
        destination.bind(probe, onFirstBuffer: { firstBuffers.record($0) })
        destination.selectGraph(graphID)
        let box = DestinationBufferBox(try makeBuffer())
        let delivery = Task.detached {
            destination.accept(box.buffer, hostTime: 1, graphID: graphID)
        }
        defer { probe.unblock() }
        try await waitUntil { probe.snapshot().buffers == 1 }

        // If close holds the destination lock across a client callback, the
        // bounded wait fails and the defer releases the fake delivery gate.
        let closeFinished = DestinationCompletionProbe()
        let closing = Task.detached {
            destination.close()
            closeFinished.complete()
        }
        try await waitUntil { closeFinished.isComplete }
        await closing.value
        let drainFinished = DestinationCompletionProbe()
        let draining = Task {
            await destination.drain()
            drainFinished.complete()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!drainFinished.isComplete)
        destination.accept(box.buffer, hostTime: 2, graphID: graphID)
        #expect(probe.snapshot().buffers == 1)
        probe.unblock()
        await delivery.value
        await draining.value
        #expect(drainFinished.isComplete)
        let countAfterDrain = firstBuffers.snapshot().count
        destination.accept(box.buffer, hostTime: 3, graphID: graphID)
        #expect(probe.snapshot().buffers == 1)
        #expect(firstBuffers.snapshot().count == countAfterDrain)
    }

    private func makeBuffer(frames: AVAudioFrameCount = 32) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        return buffer
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The metadata-only callback did not enter.")
        throw DestinationFixtureError.timedOut
    }
}

private final class DestinationMetadataProbe: AudioTranscriptionPipeline, @unchecked Sendable {
    struct Snapshot: Sendable {
        var buffers = 0
        var frames: UInt64 = 0
        var lastHostTime: TimeInterval?
    }
    private let state = Mutex(Snapshot())
    private let blocksDelivery: Bool
    private let deliveryGate = DispatchSemaphore(value: 0)

    init(blockDelivery: Bool = false) { blocksDelivery = blockDelivery }
    func snapshot() -> Snapshot { state.withLock { $0 } }
    func unblock() { deliveryGate.signal() }
    func start() async throws { }
    func finish() async throws { }
    func cancel() async { }
    func accept(_ sample: CMSampleBuffer) { }
    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?) {
        state.withLock {
            $0.buffers += 1
            $0.frames += UInt64(buffer.frameLength)
            $0.lastHostTime = hostTime
        }
        if blocksDelivery { deliveryGate.wait() }
    }
}

private final class DestinationFirstBufferProbe: Sendable {
    private let graphs = Mutex<[UUID]>([])
    func record(_ graphID: UUID) { graphs.withLock { $0.append(graphID) } }
    func snapshot() -> [UUID] { graphs.withLock { $0 } }
}

private final class DestinationCompletionProbe: Sendable {
    private let completed = Mutex(false)
    var isComplete: Bool { completed.withLock { $0 } }
    func complete() { completed.withLock { $0 = true } }
}

private final class DestinationBufferBox: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}

private enum DestinationFixtureError: Error { case timedOut }
