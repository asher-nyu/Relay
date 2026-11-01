import CoreMedia
import Foundation
import Speech
import Testing
@testable import Relay

@Suite("Spoken-word result timing")
struct SpeechResultTimingTests {
    @Test("Leading silence in the result range does not become the word's timestamp")
    func leadingSilence() {
        let text = word("Welcome", start: 20, duration: 0.4)
        #expect(SpeechResultTiming.start(in: text, fallbackRange: range(0, 21)) == 20)
    }

    @Test("Leading punctuation and whitespace are ignored when choosing the first spoken run")
    func punctuationAndWhitespace() {
        let text = word("… ", start: 0, duration: 20)
            + word("Welcome", start: 20, duration: 0.4)
            + word(" to Relay.", start: 20.4, duration: 0.8)
        #expect(SpeechResultTiming.start(in: text, fallbackRange: range(0, 22)) == 20)
    }

    @Test("Non-Latin letters and spoken numbers have valid word timing")
    func unicodeSpeech() {
        for content in ["你好", "مرحبا", "42", "٢"] {
            #expect(SpeechResultTiming.start(in: word(content, start: 3, duration: 1), fallbackRange: range(0, 5)) == 3)
        }
    }

    @Test("The earliest valid spoken run is used even if run timing arrives out of order")
    func earliestRun() {
        let text = word("Hello ", start: 8, duration: 0.5) + word("world", start: 7, duration: 0.5)
        #expect(SpeechResultTiming.start(in: text, fallbackRange: range(0, 9)) == 7)
    }

    @Test("Missing, negative, and invalid word timing uses the safe result range")
    func unavailableWordTiming() {
        #expect(SpeechResultTiming.start(in: AttributedString("Hello"), fallbackRange: range(4, 1)) == 4)
        #expect(SpeechResultTiming.start(in: word("Hello", start: 0, duration: 0), fallbackRange: range(4, 1)) == 4)
        #expect(SpeechResultTiming.start(in: word("Hello", start: -1, duration: 1), fallbackRange: range(4, 1)) == 4)
        var invalid = AttributedString("Hello")
        invalid.audioTimeRange = .invalid
        #expect(SpeechResultTiming.start(in: invalid, fallbackRange: range(4, 1)) == 4)
        invalid.audioTimeRange = CMTimeRange(start: .positiveInfinity, duration: CMTime(seconds: 1, preferredTimescale: 16_000))
        #expect(SpeechResultTiming.start(in: invalid, fallbackRange: range(4, 1)) == 4)
    }

    @Test("Invalid and negative fallback times cannot leak into transcript timestamps")
    func invalidFallback() {
        let text = AttributedString("Hello")
        #expect(SpeechResultTiming.start(in: text, fallbackRange: .invalid) == 0)
        #expect(SpeechResultTiming.start(in: text, fallbackRange: range(-3, 1)) == 0)
        let infinite = CMTimeRange(start: .positiveInfinity, duration: .zero)
        #expect(SpeechResultTiming.start(in: text, fallbackRange: infinite) == 0)
    }

    private func word(_ text: String, start: Double, duration: Double) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.audioTimeRange = range(start, duration)
        return attributed
    }

    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 16_000),
                    duration: CMTime(seconds: duration, preferredTimescale: 16_000))
    }
}
