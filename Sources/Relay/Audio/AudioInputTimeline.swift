import Foundation

/// Maps captured buffers to the session clock. Hardware reconnection leaves a real gap;
/// it must not make later words appear to have been spoken while the microphone was absent.
struct AudioInputTimeline: Sendable {
    static let gapTolerance: TimeInterval = 0.05
    private let sampleRate: Double
    private let origin: TimeInterval
    private var nextFrame: Int64?

    init(sampleRate: Double, origin: TimeInterval) {
        self.sampleRate = sampleRate
        self.origin = origin
    }

    mutating func nextStart(frameLength: Int64, hostTime: TimeInterval?) -> Int64 {
        let observed: Int64? = hostTime.flatMap { time in
            let frames = max(0, time - origin) * sampleRate
            guard frames.isFinite, frames < Double(Int64.max) else { return nil }
            return Int64(frames.rounded())
        }
        var start = nextFrame ?? observed ?? 0
        if let observed, Double(observed - start) / sampleRate > Self.gapTolerance {
            start = observed
        }
        // Small clock jitter and overlapping callbacks never send audio backwards.
        nextFrame = start + max(0, frameLength)
        return start
    }
}
