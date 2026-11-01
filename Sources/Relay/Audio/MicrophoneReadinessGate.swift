import Foundation

/// A microphone setup either delivers its first real buffer or fails within a
/// bounded time. Deadlines belong to this generation, never a later session.
@MainActor
final class MicrophoneReadinessGate {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let deadline: Task<Void, Never>
    }
    private var generation = UUID()
    private var waiters: [UUID: Waiter] = [:]
    private(set) var isCompleted = false
    var pendingCount: Int { waiters.count }

    func reset() {
        cancel()
        isCompleted = false
    }

    func complete() {
        isCompleted = true
        finishAll(with: .success(()))
    }

    /// Recovery requires a fresh buffer but must not cancel existing callers or
    /// extend their original setup deadline.
    func rearm() {
        isCompleted = false
    }

    func cancel() {
        generation = UUID()
        isCompleted = false
        finishAll(with: .failure(CancellationError()))
    }

    func wait(timeout: Duration = .seconds(12)) async throws {
        try Task.checkCancellation()
        if isCompleted { return }
        let id = UUID()
        let token = generation
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard generation == token, !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if isCompleted { continuation.resume(); return }
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.generation == token else { return }
                    self.finish(id, with: .failure(AudioTranscriptionError.microphoneUnavailable))
                }
                waiters[id] = Waiter(continuation: continuation, deadline: deadline)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.finish(id, with: .failure(CancellationError()))
            }
        }
        try Task.checkCancellation()
    }

    private func finish(_ id: UUID, with result: Result<Void, Error>) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.deadline.cancel()
        waiter.continuation.resume(with: result)
    }

    private func finishAll(with result: Result<Void, Error>) {
        let completed = Array(waiters.values)
        waiters.removeAll()
        for waiter in completed {
            waiter.deadline.cancel()
            waiter.continuation.resume(with: result)
        }
    }
}
