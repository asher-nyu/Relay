import Foundation
import Testing
@testable import Relay

@Suite("Retained microphone engine recovery", .serialized)
@MainActor
struct MicrophoneRestartTests {
    @Test("A stopped engine retries its existing graph and tap with bounded backoff")
    func retriesExistingEngineUntilRunning() async throws {
        let target = RestartFixtureTarget(outcomes: [.nativeError(1), .nativeError(2), .running])
        var delays: [Duration] = []
        try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { true }, sleep: { delays.append($0) })
        #expect(target.isRunning)
        #expect(target.startCount == 3)
        #expect(delays == [.milliseconds(160), .milliseconds(500)])
    }

    @Test("Exhausted recovery propagates the last native error instead of silently appearing connected")
    func exhaustionPreservesLastNativeError() async {
        let target = RestartFixtureTarget(outcomes: [.nativeError(10), .nativeError(20), .nativeError(30)])
        var delays: [Duration] = []
        do {
            try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { true }, sleep: { delays.append($0) })
            Issue.record("Recovery must fail when every native start fails.")
        } catch {
            #expect(error as? RestartFixtureError == .native(30))
        }
        #expect(!target.isRunning)
        #expect(target.startCount == 3)
        #expect(delays == [.milliseconds(160), .milliseconds(500)])
    }

    @Test("An invalidated controller cannot restart hardware after its backoff finishes")
    func invalidationDuringBackoffPreventsFurtherStarts() async {
        let target = RestartFixtureTarget(outcomes: [.nativeError(1), .running])
        var alive = true
        var delays: [Duration] = []
        do {
            try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { alive }, sleep: {
                delays.append($0)
                alive = false
            })
            Issue.record("Invalidated recovery must cancel.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(target.startCount == 1)
        #expect(delays == [.milliseconds(160)])
        #expect(!target.isRunning)
    }

    @Test("Already-running hardware is preserved without a native start or backoff")
    func runningEngineIsUntouched() async throws {
        let target = RestartFixtureTarget(isRunning: true, outcomes: [.nativeError(1)])
        var sleepCount = 0
        try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { true }, sleep: { _ in sleepCount += 1 })
        #expect(target.isRunning)
        #expect(target.startCount == 0 && sleepCount == 0)
    }

    @Test("A controller invalidated before recovery cannot touch the retained engine")
    func invalidBeforeFirstAttempt() async {
        let target = RestartFixtureTarget(outcomes: [.running])
        do {
            try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { false }, sleep: { _ in
                Issue.record("An invalidated recovery must not wait or retry.")
            })
            Issue.record("Invalidated recovery must cancel before its first attempt.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(target.startCount == 0)
    }

    @Test("Cancellation of the retry sleep stops recovery without a second native start")
    func cancelledBackoffDoesNotRestart() async {
        let target = RestartFixtureTarget(outcomes: [.nativeError(1), .running])
        do {
            try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { true }, sleep: { _ in
                throw CancellationError()
            })
            Issue.record("Cancelled backoff must propagate cancellation.")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(target.startCount == 1)
        #expect(!target.isRunning)
    }

    @Test("A successful native return must actually leave the engine running")
    func rejectsStartsThatRemainStopped() async {
        let target = RestartFixtureTarget(outcomes: [.remainedStopped, .remainedStopped, .remainedStopped])
        var sleepCount = 0
        do {
            try await MicrophoneEngineRestart.perform(on: target, shouldContinue: { true }, sleep: { _ in sleepCount += 1 })
            Issue.record("A stopped engine must not be accepted as recovered.")
        } catch let error as MicrophoneRestartError {
            if case .remainedStopped = error { }
            else { Issue.record("Expected the engine-remained-stopped error.") }
        } catch {
            Issue.record("Unexpected recovery error: \(error)")
        }
        #expect(!target.isRunning)
        #expect(target.startCount == 3 && sleepCount == 2)
    }
}

@MainActor
private final class RestartFixtureTarget: MicrophoneRestartTarget {
    enum Outcome { case nativeError(Int), running, remainedStopped }
    var isRunning: Bool
    private let outcomes: [Outcome]
    private(set) var startCount = 0

    init(isRunning: Bool = false, outcomes: [Outcome]) {
        self.isRunning = isRunning
        self.outcomes = outcomes
    }

    func start() throws {
        let index = startCount
        startCount += 1
        guard outcomes.indices.contains(index) else {
            Issue.record("Recovery exceeded its supplied native attempts.")
            throw RestartFixtureError.native(-1)
        }
        switch outcomes[index] {
        case .nativeError(let code): throw RestartFixtureError.native(code)
        case .running: isRunning = true
        case .remainedStopped: isRunning = false
        }
    }
}

private enum RestartFixtureError: Error, Equatable { case native(Int) }
