import CoreMedia
import Foundation
import Speech

/// A result's analyzed range can start before the first spoken word, including a long
/// initial silence. Word timing follows the actual utterance instead of that silent range.
enum SpeechResultTiming {
    struct Metadata: Sendable {
        let resultStart: TimeInterval?
        let resultEnd: TimeInterval?
        let spokenRuns: Int
        let missingWordRanges: Int
        let zeroDurationWordRanges: Int
        let positiveDurationWordRanges: Int
        let earliestPositiveWordStart: TimeInterval?
        let chosenStart: TimeInterval
        let isFinal: Bool
        let finalizationTime: TimeInterval?
    }

    /// Numeric timing evidence only; text/audio is never retained in this value.
    static func metadata(in text: AttributedString, range: CMTimeRange,
                         chosenStart: TimeInterval, isFinal: Bool,
                         finalizationTime: CMTime = .invalid) -> Metadata {
        var spokenRuns = 0
        var missing = 0
        var zero = 0
        var positiveStarts: [Double] = []
        for run in text.runs {
            guard String(text[run.range].characters).unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { continue }
            spokenRuns += 1
            guard let timing = run.audioTimeRange, timing.isValid,
                  timing.start.isNumeric, timing.duration.isNumeric,
                  timing.start.seconds.isFinite, timing.duration.seconds.isFinite else {
                missing += 1
                continue
            }
            if timing.duration.seconds == 0 { zero += 1 }
            if timing.duration.seconds > 0, timing.start.seconds >= 0 {
                positiveStarts.append(timing.start.seconds)
            }
        }
        func finite(_ time: CMTime) -> TimeInterval? {
            time.isNumeric && time.seconds.isFinite ? time.seconds : nil
        }
        return Metadata(resultStart: finite(range.start), resultEnd: finite(range.end),
            spokenRuns: spokenRuns, missingWordRanges: missing, zeroDurationWordRanges: zero,
            positiveDurationWordRanges: positiveStarts.count, earliestPositiveWordStart: positiveStarts.min(),
            chosenStart: chosenStart, isFinal: isFinal, finalizationTime: finite(finalizationTime))
    }

    static func wordStart(in text: AttributedString) -> TimeInterval? {
        let spokenStarts = text.runs.compactMap { run -> TimeInterval? in
            let characters = String(text[run.range].characters)
            guard characters.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains),
                  let range = run.audioTimeRange, range.isValid,
                  range.start.isNumeric, range.duration.isNumeric,
                  range.start.seconds.isFinite, range.start.seconds >= 0,
                  range.duration.seconds.isFinite, range.duration.seconds > 0 else { return nil }
            return range.start.seconds
        }
        return spokenStarts.min()
    }

    static func start(in text: AttributedString, fallbackRange: CMTimeRange) -> TimeInterval {
        if let earliest = wordStart(in: text) { return earliest }
        let fallback = fallbackRange.start.seconds
        return fallbackRange.start.isNumeric && fallback.isFinite ? max(0, fallback) : 0
    }
}

/// Apple’s volatile attributes can describe the complete analyzed range,
/// including silence, rather than the first word. Freeze an observed source
/// onset for that live segment; final ASR word timings remain authoritative.
struct SpeechSegmentTiming {
    private(set) var provisionalStart: TimeInterval?
    private(set) var finalizedThrough: TimeInterval = 0

    mutating func resolve(in text: AttributedString, range: CMTimeRange, isFinal: Bool,
                          finalizationTime: CMTime, activity: SpeechActivitySnapshot) -> TimeInterval {
        let rangeStart = Self.finite(range.start).map { max(0, $0) } ?? finalizedThrough
        let rangeEnd = Self.finite(range.end).map { max(rangeStart, $0) } ?? activity.latestAudioEnd
        let boundary = max(finalizedThrough, rangeStart)
        let upper = max(boundary, min(rangeEnd, activity.latestAudioEnd))
        let replay = activity.replayThrough.map { rangeEnd <= $0 + 0.05 } ?? false
        let hasWords = text.characters.contains { $0.isLetter || $0.isNumber }
        if isFinal {
            let start = SpeechResultTiming.wordStart(in: text) ?? provisionalStart
                ?? activity.onset(after: boundary, through: upper, preservingReplayOrder: replay) ?? max(boundary, upper)
            finalizedThrough = max(finalizedThrough, Self.finite(finalizationTime) ?? rangeEnd)
            provisionalStart = nil
            return max(0, start)
        }
        guard hasWords else { return provisionalStart ?? boundary }
        if provisionalStart == nil {
            // A VAD/energy miss cannot send a new live phrase back to time zero.
            // The analyzed endpoint is still in this source’s actual audio clock;
            // it is a provisional fallback, never a replacement for final timing.
            provisionalStart = activity.onset(after: boundary, through: upper, preservingReplayOrder: replay) ?? upper
        }
        return provisionalStart ?? upper
    }

    private static func finite(_ time: CMTime) -> TimeInterval? {
        time.isNumeric && time.seconds.isFinite ? time.seconds : nil
    }
}
