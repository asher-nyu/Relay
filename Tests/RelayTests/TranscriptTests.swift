import Foundation
import Testing
@testable import Relay

@Suite("Transcript revisions and exports")
struct TranscriptTests {
    @Test("An unfinished phrase is revised in place")
    func revisesPartialPhrase() {
        var transcript = SessionTranscript()
        let id = UUID()
        let changed1 = transcript.apply(update(id, text: "We should", final: false, at: 2))
        #expect(changed1)
        let changed2 = transcript.apply(update(id, text: "We should meet tomorrow.", final: true, at: 3))
        #expect(changed2)
        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].text == "We should meet tomorrow.")
        #expect(transcript.segments[0].timestamp == 3)
        #expect(transcript.segments[0].isFinal)
    }

    @Test("Late partial results cannot replace finalized text")
    func rejectsLatePartial() {
        let id = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(id, text: "The final wording.", final: true))
        let changed3 = !transcript.apply(update(id, text: "The final", final: false))
        #expect(changed3)
        let changed4 = !transcript.apply(update(id, text: "Unexpected replacement.", final: true))
        #expect(changed4)
        #expect(transcript.segments[0].text == "The final wording.")
    }

    @Test("Finalizing an identical partial still changes its state")
    func promotesUnchangedTextToFinal() {
        let id = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(id, text: "Hello.", final: false))
        let changed5 = !transcript.apply(update(id, text: "Hello.", final: false))
        #expect(changed5)
        let changed6 = transcript.apply(update(id, text: "Hello.", final: true))
        #expect(changed6)
        #expect(transcript.segments[0].isFinal)
    }

    @Test("System and microphone phrases retain chronological order")
    func interleavesAudioSources() {
        var transcript = SessionTranscript()
        let laterID = UUID()
        transcript.apply(update(laterID, source: .systemAudio, text: "Response.", final: false, at: 8))
        transcript.apply(update(UUID(), source: .microphone, text: "Question?", at: 2))
        transcript.apply(update(UUID(), source: .systemAudio, text: "Same time.", at: 8))
        transcript.apply(update(laterID, source: .systemAudio, text: "The full response.", final: true, at: 9))
        #expect(transcript.segments.map(\.text) == ["Question?", "Same time.", "The full response."])
        #expect(transcript.segments.map(\.timestamp) == [2, 8, 9])
    }

    @Test("A phrase cannot silently change audio source")
    func preservesPhraseSource() {
        let id = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(id, source: .microphone, text: "My words.", final: false))
        let changed7 = !transcript.apply(update(id, source: .systemAudio, text: "Different source."))
        #expect(changed7)
        #expect(transcript.segments[0].source == .microphone)
        #expect(transcript.segments[0].text == "My words.")
    }

    @Test("Empty and invalid updates do not create transcript rows")
    func ignoresInvalidUpdates() {
        var transcript = SessionTranscript()
        let changed8 = !transcript.apply(update(UUID(), text: " \n\t "))
        #expect(changed8)
        let changed9 = !transcript.apply(update(UUID(), text: "Invalid", at: -.infinity))
        #expect(changed9)
        let changed10 = !transcript.apply(update(UUID(), text: "Invalid", at: .nan))
        #expect(changed10)
        let changed11 = !transcript.apply(update(UUID(), text: "Invalid", at: -1))
        #expect(changed11)
        #expect(transcript.isEmpty)
    }

    @Test("Outer whitespace is trimmed while paragraph content is preserved")
    func preservesInteriorWhitespace() {
        var transcript = SessionTranscript()
        transcript.apply(update(UUID(), text: "  First paragraph.\n\nSecond  paragraph.\n "))
        #expect(transcript.segments[0].text == "First paragraph.\n\nSecond  paragraph.")
    }

    @Test("Ending a session finalizes every remaining live phrase")
    func finalizesRemainingPhrases() {
        var transcript = SessionTranscript()
        transcript.apply(update(UUID(), text: "Microphone", final: false))
        transcript.apply(update(UUID(), source: .systemAudio, text: "System", final: false))
        transcript.finalize()
        #expect(transcript.segments.count == 2)
        #expect(transcript.segments.allSatisfy { $0.isFinal })
    }

    @Test("Plain text includes every source and full text in chronological order")
    func exportsCompletePlainText() {
        let session = session(segments: [
            TranscriptSegment(source: .systemAudio, text: "A remote reply.", timestamp: 12),
            TranscriptSegment(source: .microphone, text: "A local question?", timestamp: 2)
        ])
        #expect(session.plainText == "Microphone · 00:02\nA local question?\n\nSystem audio · 00:12\nA remote reply.")
        #expect(session.markdown.contains("# Planning"))
        #expect(session.markdown.contains("**System audio · 00:12**\n\nA remote reply."))
    }

    @Test("Time labels support long sessions without wrapping at one hour")
    func formatsElapsedTime() {
        #expect(TranscriptFormatting.timeLabel(0) == "00:00")
        #expect(TranscriptFormatting.timeLabel(59.9) == "00:59")
        #expect(TranscriptFormatting.timeLabel(3601.9) == "1:00:01")
        #expect(TranscriptFormatting.timeLabel(36_000) == "10:00:00")
        #expect(TranscriptFormatting.timeLabel(.infinity) == "00:00")
    }

    @Test("Export names cannot contain path separators or empty base names")
    func sanitizesExportFilename() {
        var item = session()
        item.title = "  Project / Planning: 2026?  "
        let filename = item.exportFilename(extension: "txt")
        #expect(!filename.contains("/"))
        #expect(!filename.contains(":"))
        #expect(!filename.contains("?"))
        #expect(filename.hasSuffix(".txt"))
        item.title = "../../"
        #expect(item.exportFilename() == "Relay Transcript.txt")
        item.title = String(repeating: "é", count: 200)
        #expect(item.exportFilename(extension: "md").count == 103)
    }

    @Test("Completed sessions retain a fixed duration")
    func fixedCompletedDuration() {
        let item = session()
        #expect(item.duration == 600)
    }

    @Test("Recorded duration excludes preparation and paused gaps from a long-lived document")
    func recordedDurationOverridesWallClockSpan() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let item = TranscriptSession(startedAt: started, endedAt: started.addingTimeInterval(3_600),
            recordedDuration: 42.125)
        #expect(item.duration == 42.125)
    }

    @Test("A new document can remain at zero recorded time while its capture is preparing")
    func zeroRecordedDurationDoesNotAdvanceDuringPreparation() {
        let item = TranscriptSession(startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            recordedDuration: 0)
        #expect(item.endedAt == nil)
        #expect(item.duration == 0)
    }

    @Test("Legacy documents without recorded duration retain their existing date-based duration")
    func legacyDurationKeepsDateFallback() {
        let started = Date(timeIntervalSince1970: 1_790_000_000)
        let item = TranscriptSession(startedAt: started, endedAt: started.addingTimeInterval(600))
        #expect(item.recordedDuration == nil)
        #expect(item.duration == 600)
    }

    @Test("A provisional zero time can become the real first spoken-word time")
    func correctsLeadingSilenceTimestamp() {
        let id = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(id, text: "Welcome", final: false, at: 0))
        transcript.apply(update(UUID(), source: .systemAudio, text: "Earlier response.", at: 10))
        let changed = transcript.apply(update(id, text: "Welcome to Relay.", final: true, at: 20))
        #expect(changed)
        #expect(transcript.segments.map(\.text) == ["Earlier response.", "Welcome to Relay."])
        #expect(transcript.segments.map(\.timestamp) == [10, 20])
        #expect(transcript.segments.last?.timeLabel == "00:20")
    }

    @Test("A time-only partial correction is retained without duplicating a phrase")
    func correctsTimingWithoutChangingText() {
        let id = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(id, text: "Unchanged words.", final: false, at: 0))
        let changed = transcript.apply(update(id, text: "Unchanged words.", final: false, at: 12.5))
        #expect(changed)
        #expect(transcript.segments.count == 1)
        #expect(transcript.segments[0].timestamp == 12.5)
        #expect(!transcript.segments[0].isFinal)
    }

    @Test("Live corrections stay at the tail and final time ties preserve established order")
    func keepsCorrectedTimeTiesStable() {
        let moving = UUID()
        let peer = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(moving, text: "First arrival.", final: false, at: 0))
        transcript.apply(update(peer, source: .systemAudio, text: "Second arrival.", at: 10))
        transcript.apply(update(moving, text: "First arrival.", final: false, at: 10))
        #expect(transcript.segments.map(\.id) == [peer, moving])
        transcript.apply(update(moving, text: "First arrival revised.", final: true, at: 10))
        #expect(transcript.segments.map(\.id) == [peer, moving])
    }

    @Test("Punctuation-only hypotheses never create visible rows")
    func ignoresPunctuationOnlyResults() {
        var transcript = SessionTranscript()
        for text in [".", "…", "?!", "—", " “ ” ", "\n\t", "👏"] {
            let changed = transcript.apply(update(UUID(), text: text, final: false))
            #expect(!changed)
        }
        #expect(transcript.isEmpty)
    }

    @Test("Unicode letters and numbers remain valid transcript content")
    func preservesNonLatinSpeechAndNumbers() {
        var transcript = SessionTranscript()
        for text in ["你好。", "日本語", "مرحبا", "१२३", "٢٤", "2026", "Ⅳ", "é"] {
            let changed = transcript.apply(update(UUID(), text: text))
            #expect(changed)
        }
        #expect(transcript.segments.map(\.text) == ["你好。", "日本語", "مرحبا", "१२३", "٢٤", "2026", "Ⅳ", "é"])
    }

    @Test("Empty or punctuation-only finals retract a partial and reject late recreation")
    func retractsInvalidFinalHypotheses() {
        for finalText in ["", "  \n", ".", "…?!"] {
            let id = UUID()
            var transcript = SessionTranscript()
            transcript.apply(update(id, text: "Unconfirmed hypothesis", final: false, at: 1))
            let removed = transcript.apply(update(id, text: finalText, final: true, at: 2))
            #expect(removed)
            #expect(transcript.isEmpty)
            let recreated = transcript.apply(update(id, text: "Late partial", final: false, at: 1))
            #expect(!recreated)
            #expect(transcript.isEmpty)
        }
    }

    @Test("Invalid revisions cannot change a source, finalized timing, or protected words")
    func protectsFinalAndInvalidRevisions() {
        let id = UUID()
        var transcript = SessionTranscript()
        transcript.apply(update(id, text: "Protected words.", at: 5))
        let late = transcript.apply(update(id, text: "Changed", final: false, at: 50))
        let retraction = transcript.apply(update(id, text: ".", at: 5))
        #expect(!late)
        #expect(!retraction)
        #expect(transcript.segments[0].timestamp == 5)
        #expect(transcript.segments[0].text == "Protected words.")
        let partial = UUID()
        transcript.apply(update(partial, text: "Still provisional.", final: false, at: 1))
        let wrongSource = transcript.apply(update(partial, source: .systemAudio, text: "", at: 2))
        let invalidTime = transcript.apply(update(partial, text: ".", at: .nan))
        #expect(!wrongSource)
        #expect(!invalidTime)
        #expect(transcript.segments.last?.text == "Still provisional.")
    }

    @Test("Provisional clocks show Live while finalized unknown clocks keep only their source")
    func honestTimingLabels() {
        let pending = TranscriptSegment(source: .microphone, text: "Live words.", isFinal: false, timestamp: 0)
        #expect(!pending.timingIsConfirmed)
        #expect(pending.timeLabel == "Live")
        #expect(pending.metadataLabel == "Microphone · Live")
        let unknown = TranscriptSegment(source: .microphone, text: "Preserved words.", timestamp: 7,
                                        timingIsConfirmed: false)
        #expect(unknown.timeLabel.isEmpty)
        #expect(unknown.metadataLabel == "Microphone")
        #expect(TranscriptSegment(source: .systemAudio, text: "Confirmed.", timestamp: 165).metadataLabel == "System audio · 02:45")
    }

    @Test("Zero and old partial timestamps never reorder live arrivals ahead of finalized words")
    func pendingRowsRemainAtTailUntilConfirmedFinal() {
        let firstLive = UUID(), secondLive = UUID()
        var transcript = SessionTranscript(segments: [
            TranscriptSegment(source: .systemAudio, text: "At two minutes.", timestamp: 120),
            TranscriptSegment(source: .systemAudio, text: "At three minutes.", timestamp: 180)
        ])
        transcript.apply(update(firstLive, text: "First live arrival.", final: false, at: 0))
        transcript.apply(update(secondLive, source: .systemAudio, text: "Second live arrival.", final: false, at: 7))
        transcript.apply(update(firstLive, text: "First live arrival revised.", final: false, at: 200))
        #expect(transcript.segments.map(\.text) == ["At two minutes.", "At three minutes.", "First live arrival revised.", "Second live arrival."])
        #expect(transcript.segments.suffix(2).map(\.timeLabel) == ["Live", "Live"])
        transcript.apply(update(firstLive, text: "First live arrival finalized.", at: 165))
        #expect(transcript.segments.map(\.text) == ["At two minutes.", "First live arrival finalized.", "At three minutes.", "Second live arrival."])
        #expect(transcript.segments[1].timingIsConfirmed)
    }

    @Test("Draining live words never fabricates confirmation or a precise export clock")
    func finalizePreservesUnknownTiming() {
        var transcript = SessionTranscript()
        transcript.apply(update(UUID(), text: "Keep these words.", final: false, at: 7.2))
        transcript.finalize()
        let phrase = transcript.segments[0]
        #expect(phrase.isFinal && !phrase.timingIsConfirmed)
        #expect(phrase.timeLabel.isEmpty)
        let item = session(segments: transcript.segments)
        #expect(item.plainText == "Microphone\nKeep these words.")
        #expect(item.markdown.contains("**Microphone**\n\nKeep these words."))
        #expect(!item.markdown.contains("Microphone ·"))
    }

    @Test("Only an identical untimed final can acquire authoritative timing once")
    func upgradesUntimedFinalWithoutRevisingProtectedWords() {
        let id = UUID()
        let phrase = TranscriptSegment(id: id, source: .microphone, text: "Protected words.", timestamp: 0,
                                       timingIsConfirmed: false)
        var transcript = SessionTranscript(segments: [phrase,
            TranscriptSegment(source: .systemAudio, text: "Earlier system phrase.", timestamp: 120)])
        let changedWords = transcript.apply(TranscriptUpdate(segmentID: id, source: .microphone, text: "Changed words.",
            isFinal: true, timestamp: 165, timingIsConfirmed: true))
        #expect(!changedWords)
        let changedSource = transcript.apply(TranscriptUpdate(segmentID: id, source: .systemAudio, text: phrase.text,
            isFinal: true, timestamp: 165, timingIsConfirmed: true))
        #expect(!changedSource)
        let partialUpgrade = transcript.apply(TranscriptUpdate(segmentID: id, source: .microphone, text: phrase.text,
            isFinal: false, timestamp: 165, timingIsConfirmed: true))
        #expect(!partialUpgrade)
        let confirmedUpgrade = transcript.apply(TranscriptUpdate(segmentID: id, source: .microphone, text: phrase.text,
            isFinal: true, timestamp: 165, timingIsConfirmed: true))
        #expect(confirmedUpgrade)
        #expect(transcript.segments.last?.id == id)
        #expect(transcript.segments.last?.metadataLabel == "Microphone · 02:45")
        let changedConfirmedTime = transcript.apply(TranscriptUpdate(segmentID: id, source: .microphone, text: phrase.text,
            isFinal: true, timestamp: 200, timingIsConfirmed: true))
        #expect(!changedConfirmedTime)
        #expect(transcript.segments.last?.timestamp == 165)
    }

    @Test("Legacy segment decoding defaults missing timing certainty to finality")
    func legacyTimingCertainty() throws {
        for final in [false, true] {
            let original = TranscriptSegment(source: .microphone, text: "Legacy phrase.", isFinal: final, timestamp: 12)
            var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            object.removeValue(forKey: "timingIsConfirmed")
            let recovered = try JSONDecoder().decode(TranscriptSegment.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(recovered.timingIsConfirmed == final)
            #expect(recovered.timeLabel == (final ? "00:12" : "Live"))
        }
        let unknown = TranscriptSegment(source: .microphone, text: "Untimed final.", timestamp: 0, timingIsConfirmed: false)
        let recovered = try JSONDecoder().decode(TranscriptSegment.self, from: JSONEncoder().encode(unknown))
        #expect(recovered == unknown)
        #expect(recovered.timeLabel.isEmpty)
    }

    private func update(
        _ id: UUID,
        source: TranscriptSource = .microphone,
        text: String,
        final: Bool = true,
        at timestamp: TimeInterval = 0
    ) -> TranscriptUpdate {
        TranscriptUpdate(segmentID: id, source: source, text: text, isFinal: final, timestamp: timestamp)
    }

    private func session(segments: [TranscriptSegment] = []) -> TranscriptSession {
        TranscriptSession(
            title: "Planning",
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_000_600),
            segments: segments
        )
    }
}
