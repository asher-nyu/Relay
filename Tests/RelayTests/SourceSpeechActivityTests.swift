import AVFoundation
import CoreMedia
import Foundation
import Speech
import Testing
@testable import Relay

@Suite("Source-local live speech timing")
struct SourceSpeechActivityTests {
    @Test("Activity starts after leading silence and rejects a short classification spike")
    func leadingSilenceAndDebounce() {
        var history = SpeechActivityHistory()
        history.append(start: 0, duration: 20, voice: false, signal: false)
        history.append(start: 20, duration: 0.01, voice: true, signal: true)
        #expect(history.snapshot.onset(after: 0, through: 21) == nil)
        history.append(start: 20.01, duration: 0.01, voice: true, signal: true)
        history.append(start: 20.02, duration: 0.01, voice: true, signal: true)
        history.append(start: 20.03, duration: 0.01, voice: true, signal: true)
        #expect(history.snapshot.onset(after: 0, through: 21) == 20)
    }

    @Test("Previous VAD hangover cannot anchor a new utterance after a long gap")
    func priorHangover() {
        let activity = SpeechActivitySnapshot(voice: [.init(start: 9, end: 12.2), .init(start: 32, end: 34)],
            latestAudioEnd: 35)
        #expect(activity.onset(after: 12, through: 35) == 32)
        let continuous = SpeechActivitySnapshot(voice: [.init(start: 9, end: 15)], latestAudioEnd: 16)
        #expect(continuous.onset(after: 12, through: 16) == 12)
    }

    @Test("Quiet signal onset is available when voice classification misses")
    func quietFallback() {
        let activity = SpeechActivitySnapshot(signal: [.init(start: 0, end: 1), .init(start: 20, end: 21)],
            latestAudioEnd: 22)
        #expect(activity.onset(after: 0, through: 22) == 20)
        var quiet = SpeechActivityHistory()
        for frame in 0..<4 {
            quiet.append(start: 20 + Double(frame) * 0.01, duration: 0.01,
                         voice: false, signal: true)
        }
        #expect(quiet.snapshot.voice.isEmpty)
        #expect(quiet.snapshot.onset(after: 0, through: 21) == 20)
    }

    @Test("VAD-positive room noise below the signal floor cannot become trusted voice")
    func belowFloorVoice() {
        var history = SpeechActivityHistory()
        for frame in 0..<300 {
            // The physical quiet-room trace includes VAD-positive intervals
            // longer than 0.6 s with RMS at or below its learned noise floor.
            history.append(start: Double(frame) * 0.01, duration: 0.01,
                           voice: true, signal: false)
        }
        #expect(history.snapshot.voice.isEmpty)
        #expect(history.snapshot.signal.isEmpty)
        history.append(start: 3, duration: 17, voice: false, signal: false)
        for frame in 0..<8 {
            history.append(start: 20 + Double(frame) * 0.01, duration: 0.01,
                           voice: true, signal: true)
        }
        #expect(history.snapshot.onset(after: 0, through: 21) == 20)
    }

    @Test("Clustering short noise spikes cannot count their quiet gaps as speech")
    func clusteredSpikesRequireActualSupport() {
        let spikes: [SpeechActivityInterval] = [.init(start: 0, end: 0.01),
            .init(start: 0.2, end: 0.21), .init(start: 0.4, end: 0.41)]
        let noise = SpeechActivitySnapshot(voice: spikes, signal: spikes, latestAudioEnd: 1)
        #expect(noise.onset(after: 0, through: 1) == nil)
        let speech = SpeechActivitySnapshot(voice: spikes + [.init(start: 20, end: 20.08)],
            signal: spikes + [.init(start: 20, end: 20.08)], latestAudioEnd: 21)
        #expect(speech.onset(after: 0, through: 21) == 20)
        #expect(speech.onset(after: 0, through: 21, preservingReplayOrder: true) == 20)
        // Support outside the result's range cannot make an earlier spike valid.
        let crossing = SpeechActivitySnapshot(voice: [.init(start: 20, end: 21)], latestAudioEnd: 22)
        #expect(crossing.onset(after: 0, through: 20.02) == nil)
    }

    @Test("Rejected ten-millisecond frames remain gaps in supported history")
    func supportedDurationExcludesRejectedFrames() {
        var history = SpeechActivityHistory()
        for frame in 0..<5 {
            history.append(start: Double(frame) * 0.01, duration: 0.01,
                           voice: true, signal: frame != 2)
        }
        #expect(history.snapshot.voice.count == 2)
        let actualDuration = history.snapshot.voice.reduce(0) { $0 + $1.end - $1.start }
        #expect(abs(actualDuration - 0.04) < 0.000_001)
        #expect(history.snapshot.onset(after: 0, through: 1) == 0)
    }

    @Test("An isolated classifier spike cannot anchor later real speech")
    func oldIsolatedActivity() {
        let activity = SpeechActivitySnapshot(voice: [.init(start: 0, end: 0.02), .init(start: 20, end: 21)],
            latestAudioEnd: 22)
        #expect(activity.onset(after: 0, through: 22) == 20)
        let words = SpeechActivitySnapshot(voice: [.init(start: 20, end: 20.3), .init(start: 20.7, end: 21)],
            latestAudioEnd: 22)
        #expect(words.onset(after: 0, through: 22) == 20)
    }

    @Test("A new live episode does not inherit an unrecognized startup interval")
    func unclaimedStartupEpisode() {
        let activity = SpeechActivitySnapshot(voice: [.init(start: 0, end: 1), .init(start: 165, end: 167)],
            latestAudioEnd: 168)
        #expect(activity.onset(after: 0, through: 168) == 165)
        #expect(activity.onset(after: 0, through: 168, preservingReplayOrder: true) == 0)
        var live = SpeechSegmentTiming()
        #expect(live.resolve(in: attributed("Current speech", at: 0, duration: 168),
            range: range(0, 168), isFinal: false, finalizationTime: .zero, activity: activity) == 165)
        var replay = SpeechSegmentTiming()
        var replayActivity = activity
        replayActivity.replayThrough = 168
        #expect(replay.resolve(in: attributed("Earlier speech", at: 0, duration: 168),
            range: range(0, 168), isFinal: false, finalizationTime: .zero, activity: replayActivity) == 0)
    }

    @Test("Several phrases within one live episode retain the earliest onset")
    func earliestWithinEpisode() {
        let activity = SpeechActivitySnapshot(voice: [.init(start: 20, end: 22), .init(start: 23, end: 25),
            .init(start: 26, end: 30)], latestAudioEnd: 31)
        #expect(activity.onset(after: 0, through: 31) == 20)
    }

    @Test("Actual voiced startup noise followed by silence cannot anchor the next live episode")
    func actualStartupNoiseEpisode() throws {
        let detector = SourceSpeechActivity()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for frame in 0..<2_400 {
            for sample in 0..<160 {
                let time = Double(frame) * 0.01 + Double(sample) / 16_000
                let active = frame < 100 || frame >= 2_200
                let value = active ? (sin(time * 2 * .pi * 180) + 0.5 * sin(time * 2 * .pi * 360)) * 0.15 : 0
                buffer.floatChannelData![0][sample] = Float(value)
            }
            detector.observe(buffer, at: Double(frame) * 0.01)
        }
        detector.finish()
        let snapshot = detector.snapshot
        #expect((snapshot.voice.first?.start ?? 100) < 0.1)
        let onset = try #require(snapshot.onset(after: 0, through: 24))
        #expect(onset >= 21.9 && onset < 22.3)
    }

    @Test("A live segment freezes its source onset and final words refine it")
    func freezeAndRefine() {
        var timing = SpeechSegmentTiming()
        let activity = SpeechActivitySnapshot(voice: [.init(start: 20.02, end: 21.5)], latestAudioEnd: 31)
        let wholeRange = attributed("Welcome", at: 0, duration: 31)
        #expect(timing.resolve(in: wholeRange, range: range(0, 31), isFinal: false,
            finalizationTime: .zero, activity: activity) == 20.02)
        let revised = SpeechActivitySnapshot(voice: [.init(start: 20, end: 22)], latestAudioEnd: 32)
        #expect(timing.resolve(in: attributed("Welcome to Relay", at: 0, duration: 32),
            range: range(0, 32), isFinal: false, finalizationTime: .zero, activity: revised) == 20.02)
        #expect(timing.resolve(in: attributed("Welcome to Relay.", at: 19.92, duration: 1.32),
            range: range(19.92, 1.32), isFinal: true,
            finalizationTime: time(21.24), activity: revised) == 19.92)
        #expect(timing.provisionalStart == nil)
        let later = SpeechActivitySnapshot(voice: [.init(start: 20, end: 21.4), .init(start: 35, end: 36)],
            latestAudioEnd: 37)
        #expect(timing.resolve(in: attributed("Next phrase", at: 21.24, duration: 15.76),
            range: range(21.24, 15.76), isFinal: false,
            finalizationTime: time(21.24), activity: later) == 35)
    }

    @Test("Detector misses keep live time on the analyzed clock instead of an old boundary")
    func unavailableActivityFallback() {
        var timing = SpeechSegmentTiming()
        let empty = SpeechActivitySnapshot(latestAudioEnd: 34)
        #expect(timing.resolve(in: attributed("Quiet phrase", at: 0, duration: 34),
            range: range(0, 34), isFinal: false, finalizationTime: .zero, activity: empty) == 34)
        #expect(timing.resolve(in: attributed("Quiet phrase.", at: 32, duration: 1),
            range: range(32, 1), isFinal: true, finalizationTime: time(33), activity: empty) == 32)
    }

    @Test("Two sources keep independent timing state")
    func independentSources() {
        var microphone = SpeechSegmentTiming()
        var system = SpeechSegmentTiming()
        let words = attributed("Hello", at: 0, duration: 40)
        let micActivity = SpeechActivitySnapshot(voice: [.init(start: 9, end: 10)], latestAudioEnd: 40)
        let systemActivity = SpeechActivitySnapshot(voice: [.init(start: 22, end: 23)], latestAudioEnd: 40)
        #expect(microphone.resolve(in: words, range: range(0, 40), isFinal: false,
            finalizationTime: .zero, activity: micActivity) == 9)
        #expect(system.resolve(in: words, range: range(0, 40), isFinal: false,
            finalizationTime: .zero, activity: systemActivity) == 22)
    }

    @Test("Long sessions retain bounded interval metadata")
    func boundedHistory() {
        var history = SpeechActivityHistory()
        for frame in 0..<100_000 {
            let active = frame % 4 < 2
            history.append(start: Double(frame) * 0.01, duration: 0.01, voice: active, signal: active)
        }
        #expect(history.snapshot.voice.count <= SpeechActivityHistory.maximumIntervals)
        #expect(history.snapshot.signal.count <= SpeechActivityHistory.maximumIntervals)
        #expect((history.snapshot.voice.first?.start ?? 1_000) >= history.snapshot.latestAudioEnd - 300)
        history.advance(to: 2_000)
        #expect(history.snapshot.voice.isEmpty && history.snapshot.signal.isEmpty)
    }

    @Test("Sorted expiry removes old intervals and clips a surviving boundary interval")
    func sortedExpiryBoundary() {
        var history = SpeechActivityHistory()
        for frame in 0..<10 {
            history.append(start: Double(frame) * 0.01, duration: 0.01, voice: true, signal: true)
        }
        history.append(start: 1, duration: 1, voice: false, signal: false)
        for frame in 0..<10 {
            history.append(start: 200 + Double(frame) * 0.01, duration: 0.01, voice: true, signal: true)
        }
        history.advance(to: 301)
        #expect(history.snapshot.voice.count == 1 && history.snapshot.signal.count == 1)
        #expect(history.snapshot.voice.first?.start == 200)
        history.advance(to: 500.05)
        #expect(abs((history.snapshot.voice.first?.start ?? 0) - 200.05) < 0.000_001)
        #expect(abs((history.snapshot.voice.first?.end ?? 0) - 200.1) < 0.000_001)
        history.advance(to: 501)
        #expect(history.snapshot.voice.isEmpty && history.snapshot.signal.isEmpty)
    }

    @Test("Actual detector conversion accepts analyzer PCM formats without altering their samples",
           arguments: [16_000.0, 44_100.0, 48_000.0])
    func actualPCMFormats(rate: Double) throws {
        let detector = SourceSpeechActivity()
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16,
            sampleRate: rate, channels: 1, interleaved: false))
        for frame in 0..<400 {
            let count = Int(rate / 100)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = buffer.frameCapacity
            let samples = try #require(buffer.int16ChannelData?[0])
            for index in 0..<count {
                let second = Double(frame) * 0.01 + Double(index) / rate
                let voice = frame >= 200 ? (sin(second * 2 * .pi * 180)
                    + 0.5 * sin(second * 2 * .pi * 360) + 0.3 * sin(second * 2 * .pi * 720)) * 0.15 : 0
                samples[index] = Int16(voice * 32_767)
            }
            let before = Array(UnsafeBufferPointer(start: samples, count: count))
            detector.observe(buffer, at: 100 + Double(frame) * 0.01)
            #expect(Array(UnsafeBufferPointer(start: samples, count: count)) == before)
        }
        detector.finish()
        let onset = try #require(detector.snapshot.onset(after: 100, through: 105))
        #expect(onset >= 101.9 && onset < 102.3)
    }

    private func attributed(_ value: String, at start: Double, duration: Double) -> AttributedString {
        var text = AttributedString(value)
        text.audioTimeRange = range(start, duration)
        return text
    }
    private func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 16_000) }
    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: time(start), duration: time(duration))
    }
}
