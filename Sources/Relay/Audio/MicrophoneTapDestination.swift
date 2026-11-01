@preconcurrency import AVFoundation
import Foundation
import Synchronization

/// A retained hardware tap never owns a document's recognizer. Closing this router
/// prevents new deliveries immediately; draining completes every delivery already
/// checked out before its old recognizer is finalized.
final class MicrophoneTapDestination: @unchecked Sendable {
    private struct State {
        var pipeline: (any AudioTranscriptionPipeline)?
        var graphID: UUID?
        var onFirstBuffer: (@Sendable (UUID) -> Void)?
        var reportedFirstBuffer = false
        var minimumDeliveryHostTime: Double?
        var minimumReadinessHostTime: Double?
        var inFlight = 0
        var drainWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())

    func bind(_ pipeline: any AudioTranscriptionPipeline,
              onFirstBuffer: @escaping @Sendable (UUID) -> Void,
              minimumHostTime: Double? = nil) {
        state.withLock {
            $0.pipeline = pipeline
            $0.onFirstBuffer = onFirstBuffer
            $0.reportedFirstBuffer = false
            $0.minimumDeliveryHostTime = minimumHostTime
            $0.minimumReadinessHostTime = minimumHostTime
        }
    }

    func selectGraph(_ graphID: UUID?) {
        state.withLock {
            $0.graphID = graphID
            $0.reportedFirstBuffer = false
        }
    }

    func rearmFirstBuffer(_ callback: @escaping @Sendable (UUID) -> Void,
                          minimumHostTime: Double? = nil) {
        state.withLock {
            $0.onFirstBuffer = callback
            $0.reportedFirstBuffer = false
            $0.minimumReadinessHostTime = minimumHostTime
        }
    }

    func close() {
        state.withLock {
            $0.pipeline = nil
            $0.onFirstBuffer = nil
            $0.graphID = nil
            $0.reportedFirstBuffer = false
            $0.minimumDeliveryHostTime = nil
            $0.minimumReadinessHostTime = nil
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { value in
                guard value.inFlight > 0 else { return true }
                value.drainWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }

    func accept(_ buffer: AVAudioPCMBuffer, hostTime: Double?, graphID: UUID) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0,
              buffer.format.channelCount > 0 else { return }
        let delivery = state.withLock { value -> ((any AudioTranscriptionPipeline), (@Sendable (UUID) -> Void)?)? in
            guard value.graphID == graphID, let pipeline = value.pipeline else { return nil }
            if let minimum = value.minimumDeliveryHostTime {
                guard let hostTime, hostTime.isFinite, hostTime >= minimum else { return nil }
            }
            value.inFlight += 1
            let eligibleForReadiness = value.minimumReadinessHostTime.map { minimum in
                hostTime.map { $0.isFinite && $0 >= minimum } ?? false
            } ?? true
            let callback: (@Sendable (UUID) -> Void)?
            if !value.reportedFirstBuffer, eligibleForReadiness {
                callback = value.onFirstBuffer
                value.reportedFirstBuffer = true
            } else {
                callback = nil
            }
            return (pipeline, callback)
        }
        guard let (pipeline, onFirstBuffer) = delivery else { return }
        pipeline.accept(buffer, hostTime: hostTime)
        let waiters = state.withLock { value -> [CheckedContinuation<Void, Never>] in
            value.inFlight -= 1
            guard value.inFlight == 0 else { return [] }
            let waiters = value.drainWaiters
            value.drainWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
        onFirstBuffer?(graphID)
    }

    nonisolated static func makeTap(destination: MicrophoneTapDestination, graphID: UUID) -> AVAudioNodeTapBlock {
        { @Sendable [destination] buffer, time in
            let hostTime = time.isHostTimeValid ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
            destination.accept(buffer, hostTime: hostTime, graphID: graphID)
        }
    }
}
