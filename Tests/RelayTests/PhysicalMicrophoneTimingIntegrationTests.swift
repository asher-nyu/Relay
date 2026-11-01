#if DEBUG
@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Speech
import Synchronization
import Testing
@testable import Relay

/// Explicit native opt-in. Same-host synthesized speech plays over the current
/// speakers and reaches the actual microphone; Relay excludes its own playback
/// from System capture. Nothing changes system volume, saves PCM or opens files.
@Suite("Physical microphone word timing", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_MICROPHONE_INTEGRATION"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_UI_TESTING"] == "1"),
       .enabled(if: ProcessInfo.processInfo.environment["RELAY_ECHO_INTEGRATION"] != "1"))
@MainActor
struct PhysicalMicrophoneTimingIntegrationTests {
    @Test("Physical microphone words stay Live until their native final word time is confirmed", .timeLimit(.minutes(2)))
    func physicalSpeechAfterQuietUsesItsLiveOnset() async throws {
        try await NativeMicrophoneTestAccess.acquire()
        defer { NativeMicrophoneTestAccess.release() }
        try #require(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                     "Grant the signed host microphone access before explicitly running this test; it never prompts.")
        try #require(CGPreflightScreenCaptureAccess(),
                     "The signed host must already have System Audio access; this test never prompts.")
        try #require(MicrophoneDeviceRoute.current(includesSpeakerReference: false).hasInput)
        try #require(SpeechTranscriber.isAvailable)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        let voice = try #require(voices.sorted { lhs, rhs in
            let left = Self.voiceRank(lhs)
            let right = Self.voiceRank(rhs)
            if left != right { return left > right }
            let leftIsAva = lhs.name.localizedCaseInsensitiveContains("Ava")
            let rightIsAva = rhs.name.localizedCaseInsensitiveContains("Ava")
            if leftIsAva != rightIsAva { return leftIsAva }
            return lhs.identifier < rhs.identifier
        }.first,
                                 "Install an English synthesis voice before opting into the audible physical test.")
        let service = TranscriptionService()
        service.reducesSpeakerEcho = true
        let results = PhysicalTimingResults()
        service.onUpdate = { results.append($0) }
        let synthesizer = AVSpeechSynthesizer()
        let fixture = "The copper lantern is beside the blue notebook. This is a microphone timing check. We are testing the live words after a quiet pause."
        let speechClock = PhysicalSpeechClock(cueRange: (fixture as NSString).range(of: "copper"))
        synthesizer.delegate = speechClock
        defer {
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer.delegate = nil
            service.onUpdate = nil
            service.cancel() // Also disposes the prepared microphone cache after stop.
        }

        try await service.start(sources: Set(TranscriptSource.allCases), locale: Locale(identifier: "en-US"))
        try #require(service.isRunning && service.captureReadyAt != nil)
        try #require(service.isSpeakerEchoReductionActive)
        try #require(service.isSpeakerReferenceCaptureActiveForTesting)
        let captureDate = try #require(service.captureStartedAt)
        // Pair the wall clock with the host clock once, using the service's
        // real capture epoch rather than assuming readiness happened at zero.
        let anchorDate = Date()
        let anchorHost = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let originHost = anchorHost - anchorDate.timeIntervalSince(captureDate)

        // This includes genuine room/microphone background, unlike a buffer of
        // digital zeros. Half a second extra leaves room for onset pre-roll.
        try await Task.sleep(for: .milliseconds(8_500))
        try #require(service.isRunning && service.isSpeakerEchoReductionActive)
        let quietEndedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let utterance = AVSpeechUtterance(string: fixture)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        synthesizer.speak(utterance)
        try await waitUntil("The installed synthesis voice must begin speaking.", timeout: 15) {
            speechClock.snapshot.startedAt != nil
        }
        try await waitUntil("The fictional physical speech must finish without cancellation.", timeout: 35) {
            speechClock.snapshot.finished || speechClock.snapshot.cancelled
        }
        let spoken = speechClock.snapshot
        try #require(!spoken.cancelled)
        let firstWordAt = try #require(spoken.openingCueAt,
                                      "The synthesizer must report the actual first distinctive opening word.")
        #expect(firstWordAt >= quietEndedAt - 0.05)
        let expectedOnset = firstWordAt - originHost
        #expect(expectedOnset >= 8)
        try await Task.sleep(for: .seconds(4))
        try #require(service.isRunning && service.isSpeakerEchoReductionActive)
        await service.stop() // Drains both real recognizers before examining final words.
        #expect(service.state == .idle)
        service.cancel()
        #expect(!service.isBusy && !service.isSpeakerEchoReductionActive)

        let opening = results.updates.filter {
            $0.update.source == .microphone && $0.arrivedAt >= firstWordAt - 0.25 &&
                Self.containsOpening($0.update.text)
        }
        let live = opening.filter { !$0.update.isFinal }
        let microphoneUpdates = results.updates.filter { $0.update.source == .microphone }
        let systemUpdates = results.updates.filter { $0.update.source == .systemAudio }
        let microphoneMarkerHits = microphoneUpdates.filter { Self.containsOpening($0.update.text) }
        let systemMarkerHits = systemUpdates.filter { Self.containsOpening($0.update.text) }
        print("Physical microphone fixture diagnostics: expectedCue=\(expectedOnset) voiceName=\(voice.name) voiceIdentifier=\(voice.identifier) utteranceVolume=1.0 microphoneLive=\(microphoneUpdates.filter { !$0.update.isFinal }.count) microphoneFinal=\(microphoneUpdates.filter { $0.update.isFinal }.count) systemLive=\(systemUpdates.filter { !$0.update.isFinal }.count) systemFinal=\(systemUpdates.filter { $0.update.isFinal }.count) microphoneMarkerHits=\(microphoneMarkerHits.count) systemMarkerHits=\(systemMarkerHits.count) matchingOpeningLive=\(live.count) matchingOpeningFinal=\(opening.filter { $0.update.isFinal }.count) recognizedTextLogged=false audioFilesWritten=false")
        let firstLive = try #require(live.first,
                                    "Actual microphone recognition must emit the fictional opening before finalization.")
        let finals = opening.filter { $0.update.isFinal }
        let final = try #require(finals.first,
                                "The same opening must finalize after the native drain.")
        for update in live {
            #expect(!update.update.timingIsConfirmed,
                    "A volatile range or activity estimate is not a confirmed word time.")
            #expect(Self.segment(update.update).timeLabel == "Live",
                    "Unconfirmed live words must never display an estimated numeric timestamp.")
        }
        for update in finals {
            #expect(update.update.timingIsConfirmed,
                    "The fictional opening must receive actual native word timing at finalization.")
            #expect(update.update.timestamp >= 8)
            #expect(abs(update.update.timestamp - expectedOnset) <= 1.25,
                    "The confirmed native opening time must agree with the physical speech cue.")
            #expect(Self.segment(update.update).timeLabel == TranscriptFormatting.timeLabel(update.update.timestamp))
        }
        // These are the two observed failure shapes: startup zero and a later
        // room-noise estimate. Neither may masquerade as a clock in the UI.
        for estimate in [0.0, 7.21375] {
            let unconfirmed = TranscriptUpdate(segmentID: UUID(), source: .microphone,
                text: "Fictional live opening", isFinal: false, timestamp: estimate,
                timingIsConfirmed: false)
            #expect(Self.segment(unconfirmed).timeLabel == "Live")
        }
        let systemRecognizedFixture = results.updates.contains {
            guard $0.update.source == .systemAudio else { return false }
            let words = Self.normalized($0.update.text)
            return words.contains("microphone timing check") ||
                words.contains("copper lantern") || words.contains("blue notebook")
        }
        #expect(!systemRecognizedFixture,
                "Same-host synthesis must remain excluded from the System reference; otherwise this is not a near-end test.")
        let estimateOutsideCueTolerance = abs(firstLive.update.timestamp - expectedOnset) > 1.25
        print("Physical microphone timing: expectedOnset=\(expectedOnset) firstLiveEstimate=\(firstLive.update.timestamp) liveEstimateOutsideCueTolerance=\(estimateOutsideCueTolerance) liveLabel=Live finalOnset=\(final.update.timestamp) finalTimingConfirmed=\(final.update.timingIsConfirmed) liveOpeningUpdates=\(live.count) systemFixtureRecognized=\(systemRecognizedFixture) echoReductionEnabled=true audioFilesWritten=false")
    }

    private func waitUntil(_ message: String, timeout: TimeInterval,
                           _ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("\(message)")
                throw PhysicalTimingError.timedOut
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
    }

    private static func containsOpening(_ text: String) -> Bool {
        let words = normalized(text)
        return words.contains("copper lantern") || words.contains("blue notebook")
    }

    private static func voiceRank(_ voice: AVSpeechSynthesisVoice) -> Int {
        switch voice.quality {
        case .premium: 2
        case .enhanced: 1
        case .default: 0
        @unknown default: 0
        }
    }

    private static func segment(_ update: TranscriptUpdate) -> TranscriptSegment {
        TranscriptSegment(id: update.segmentID, source: update.source, text: update.text,
            isFinal: update.isFinal, timestamp: update.timestamp, timingIsConfirmed: update.timingIsConfirmed)
    }
}

private enum PhysicalTimingError: Error { case timedOut }

@MainActor
private final class PhysicalTimingResults {
    struct Received {
        let update: TranscriptUpdate
        let arrivedAt: Double
    }
    var updates: [Received] = []
    func append(_ update: TranscriptUpdate) {
        updates.append(Received(update: update, arrivedAt: CMClockGetTime(CMClockGetHostTimeClock()).seconds))
    }
}

/// Delegate callbacks may arrive outside MainActor. Only clock/boolean metadata
/// crosses the lock; no utterance or synthesizer is transferred between actors.
private final class PhysicalSpeechClock: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    struct Snapshot: Sendable {
        var startedAt: Double?
        var openingCueAt: Double?
        var finished = false
        var cancelled = false
    }
    private let state = Mutex(Snapshot())
    private let cueRange: NSRange
    init(cueRange: NSRange) {
        self.cueRange = cueRange
        super.init()
    }
    var snapshot: Snapshot { state.withLock { $0 } }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        state.withLock { if $0.startedAt == nil { $0.startedAt = now } }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard NSIntersectionRange(characterRange, cueRange).length > 0 else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        state.withLock { if $0.openingCueAt == nil { $0.openingCueAt = now } }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        state.withLock { $0.finished = true }
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        state.withLock { $0.cancelled = true }
    }
}
#endif
