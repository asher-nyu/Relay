@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing
@testable import Relay

@Suite("Concurrent recognizer preparation", .serialized)
@MainActor
struct AudioPipelineStartupTests {
    @Test("Both source preparations enter before either needs to finish")
    func startsSourcesConcurrently() async throws {
        let rendezvous = StartupRendezvous(expected: 2)
        let first = StartupFixturePipeline { try await rendezvous.enter() }
        let second = StartupFixturePipeline { try await rendezvous.enter() }
        try await AudioPipelineStartup.start([first, second])
        #expect(first.snapshot().started == 1 && second.snapshot().started == 1)
        #expect(first.snapshot().completed && second.snapshot().completed)
    }

    @Test("One preparation failure cancels its suspended sibling and preserves the original error")
    func failureCancelsSiblingPreparation() async {
        let started = StartupRendezvous(expected: 1)
        let slow = StartupFixturePipeline {
            try await started.enter()
            try await Task.sleep(for: .seconds(30))
        }
        let failing = StartupFixturePipeline {
            try await started.waitForAll()
            throw StartupFixtureError.expectedFailure
        }
        do {
            try await AudioPipelineStartup.start([slow, failing])
            Issue.record("A failed source must fail the combined preparation.")
        } catch {
            #expect(error as? StartupFixtureError == .expectedFailure)
        }
        #expect(slow.snapshot().started == 1 && slow.snapshot().cancelled)
        #expect(!slow.snapshot().completed && !failing.snapshot().completed)
    }

    @Test("Cancelling the caller cancels every in-flight source preparation")
    func callerCancellationStopsAllPreparations() async throws {
        let first = StartupFixturePipeline { try await Task.sleep(for: .seconds(30)) }
        let second = StartupFixturePipeline { try await Task.sleep(for: .seconds(30)) }
        let task = Task { try await AudioPipelineStartup.start([first, second]) }
        try await waitUntil { first.snapshot().started == 1 && second.snapshot().started == 1 }
        task.cancel()
        do {
            try await task.value
            Issue.record("Cancelled combined preparation must propagate cancellation.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(first.snapshot().cancelled && second.snapshot().cancelled)
        #expect(!first.snapshot().completed && !second.snapshot().completed)
    }

    @Test("Already-cancelled preparation never starts either source")
    func cancelledBeforeStartDoesNotTouchSources() async {
        let first = StartupFixturePipeline { }
        let second = StartupFixturePipeline { }
        let task = Task { try await AudioPipelineStartup.start([first, second]) }
        // This test runs on MainActor, so the inherited task cannot enter the
        // helper before the synchronous cancellation below.
        task.cancel()
        do {
            try await task.value
            Issue.record("A cancelled preparation must not run source setup.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(first.snapshot().started == 0 && second.snapshot().started == 0)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("The source preparations did not enter concurrently.")
        throw StartupFixtureError.timedOut
    }
}

private actor StartupRendezvous {
    private let expected: Int
    private var arrivals = 0
    init(expected: Int) { self.expected = expected }

    func enter() async throws {
        arrivals += 1
        try await waitForAll()
    }

    func waitForAll() async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while arrivals < expected {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw StartupFixtureError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class StartupFixturePipeline: AudioTranscriptionPipeline, @unchecked Sendable {
    struct Snapshot: Sendable {
        var started = 0
        var completed = false
        var cancelled = false
    }
    private let state = Mutex(Snapshot())
    private let operation: @Sendable () async throws -> Void

    init(operation: @escaping @Sendable () async throws -> Void) { self.operation = operation }
    func snapshot() -> Snapshot { state.withLock { $0 } }

    func start() async throws {
        state.withLock { $0.started += 1 }
        do {
            try await operation()
            state.withLock { $0.completed = true }
        } catch {
            if error is CancellationError { state.withLock { $0.cancelled = true } }
            throw error
        }
    }

    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?) { }
    func accept(_ sample: CMSampleBuffer) { }
    func finish() async throws { }
    func cancel() async { }
}

private enum StartupFixtureError: Error, Equatable { case expectedFailure, timedOut }
