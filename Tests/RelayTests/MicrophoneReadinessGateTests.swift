import Foundation
import Testing
@testable import Relay

@Suite("Bounded microphone readiness", .serialized)
@MainActor
struct MicrophoneReadinessGateTests {
    @Test("Missing microphone buffers fail within the requested readiness deadline")
    func deadlineFailsAndRemovesWaiter() async {
        let gate = MicrophoneReadinessGate()
        do {
            try await gate.wait(timeout: .milliseconds(30))
            Issue.record("A microphone with no buffers must not report readiness.")
        } catch {
            #expect(error as? AudioTranscriptionError == .microphoneUnavailable)
        }
        #expect(gate.pendingCount == 0 && !gate.isCompleted)
    }

    @Test("First-buffer completion resolves every waiter and remains ready until reset")
    func completionIsStickyAndClearsDeadlines() async throws {
        let gate = MicrophoneReadinessGate()
        let first = Task { try await gate.wait(timeout: .milliseconds(60)) }
        let second = Task { try await gate.wait(timeout: .seconds(1)) }
        try await waitUntil { gate.pendingCount == 2 }
        gate.complete()
        try await first.value
        try await second.value
        #expect(gate.isCompleted && gate.pendingCount == 0)
        try await Task.sleep(for: .milliseconds(100))
        // The first waiter's old deadline must not undo completed readiness.
        try await gate.wait(timeout: .zero)
        #expect(gate.isCompleted && gate.pendingCount == 0)
    }

    @Test("Cancelling one caller removes only its own pending readiness request")
    func callerCancellationDoesNotCancelOtherWaiters() async throws {
        let gate = MicrophoneReadinessGate()
        let cancelled = Task { try await gate.wait(timeout: .seconds(1)) }
        let surviving = Task { try await gate.wait(timeout: .seconds(1)) }
        try await waitUntil { gate.pendingCount == 2 }
        cancelled.cancel()
        await expectCancellation(cancelled)
        #expect(gate.pendingCount == 1 && !gate.isCompleted)
        gate.complete()
        try await surviving.value
        #expect(gate.pendingCount == 0 && gate.isCompleted)
    }

    @Test("Reset cancels the previous session and its deadline cannot affect a new session")
    func resetPreventsStaleDeadlineCrossover() async throws {
        let gate = MicrophoneReadinessGate()
        let previous = Task { try await gate.wait(timeout: .milliseconds(60)) }
        try await waitUntil { gate.pendingCount == 1 }
        gate.reset()
        await expectCancellation(previous)
        #expect(!gate.isCompleted && gate.pendingCount == 0)

        let current = Task { try await gate.wait(timeout: .seconds(1)) }
        try await waitUntil { gate.pendingCount == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(gate.pendingCount == 1 && !gate.isCompleted,
                "The previous generation's short deadline must leave the new waiter intact.")
        gate.complete()
        try await current.value
        #expect(gate.isCompleted && gate.pendingCount == 0)
    }

    @Test("Cancelling a controller resolves all pending readiness requests")
    func controllerCancellationResolvesAllWaiters() async throws {
        let gate = MicrophoneReadinessGate()
        let first = Task { try await gate.wait(timeout: .seconds(1)) }
        let second = Task { try await gate.wait(timeout: .seconds(1)) }
        try await waitUntil { gate.pendingCount == 2 }
        gate.cancel()
        await expectCancellation(first)
        await expectCancellation(second)
        #expect(!gate.isCompleted && gate.pendingCount == 0)
    }

    @Test("A short caller deadline does not expire a different caller's longer wait")
    func deadlinesBelongToIndividualWaiters() async throws {
        let gate = MicrophoneReadinessGate()
        let short = Task { try await gate.wait(timeout: .milliseconds(30)) }
        let long = Task { try await gate.wait(timeout: .seconds(1)) }
        try await waitUntil { gate.pendingCount == 2 }
        do {
            try await short.value
            Issue.record("The short readiness request should time out.")
        } catch {
            #expect(error as? AudioTranscriptionError == .microphoneUnavailable)
        }
        #expect(gate.pendingCount == 1 && !gate.isCompleted)
        gate.complete()
        try await long.value
    }

    @Test("An already-cancelled caller never installs a readiness deadline")
    func cancelledBeforeWaitHasNoPendingRequest() async {
        let gate = MicrophoneReadinessGate()
        let task = Task { try await gate.wait(timeout: .seconds(1)) }
        // Both inherit MainActor; cancellation occurs before the task can enter.
        task.cancel()
        await expectCancellation(task)
        #expect(gate.pendingCount == 0 && !gate.isCompleted)
    }

    @Test("A native recovery rearms completed readiness without reporting the old buffer")
    func rearmRequiresFreshCompletion() async throws {
        let gate = MicrophoneReadinessGate()
        gate.complete()
        #expect(gate.isCompleted)
        gate.rearm()
        #expect(!gate.isCompleted)
        let current = Task { try await gate.wait(timeout: .seconds(1)) }
        try await waitUntil { gate.pendingCount == 1 }
        gate.complete()
        try await current.value
        #expect(gate.isCompleted && gate.pendingCount == 0)
    }

    @Test("Rearming a native recovery preserves existing callers and their original deadline")
    func rearmPreservesPendingDeadline() async throws {
        let gate = MicrophoneReadinessGate()
        let pending = Task { try await gate.wait(timeout: .milliseconds(60)) }
        try await waitUntil { gate.pendingCount == 1 }
        gate.rearm()
        gate.rearm()
        #expect(gate.pendingCount == 1 && !gate.isCompleted)
        do {
            try await pending.value
            Issue.record("Recovery must not make an existing initial-buffer deadline unbounded.")
        } catch {
            #expect(error as? AudioTranscriptionError == .microphoneUnavailable,
                    "A native recovery must not cancel a legitimate pending readiness caller.")
        }
        #expect(gate.pendingCount == 0)
    }

    private func expectCancellation(_ task: Task<Void, Error>) async {
        do {
            try await task.value
            Issue.record("An invalidated readiness request must throw cancellation.")
        } catch {
            #expect(error is CancellationError)
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The readiness request did not enter.")
        throw ReadinessFixtureError.timedOut
    }
}

private enum ReadinessFixtureError: Error { case timedOut }
