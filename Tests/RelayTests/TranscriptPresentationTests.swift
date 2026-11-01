import AppKit
import Testing
@testable import Relay

@Suite("Live transcript presentation")
@MainActor
struct TranscriptPresentationTests {
    @Test("A late zero-time microphone hypothesis stays live at the tail until its word time is confirmed")
    func pendingMicrophoneUsesLiveTailThenConfirmedTime() {
        var transcript = SessionTranscript()
        let microphoneID = UUID()
        transcript.apply(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "The confirmed system phrase.", isFinal: true, timestamp: 120))
        transcript.apply(TranscriptUpdate(segmentID: microphoneID, source: .microphone,
            text: "A pending microphone phrase", isFinal: false, timestamp: 0))

        let view = RelayTranscriptTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.autoCopySelection = false
        render(transcript, in: view)
        #expect(view.string == "System audio · 02:00\nThe confirmed system phrase.\nMicrophone · Live\nA pending microphone phrase")
        #expect(!view.string.contains("Microphone · 00:00"))

        // A later finalized result must still precede the pending live row;
        // the provisional numeric estimate cannot position that row.
        transcript.apply(TranscriptUpdate(segmentID: UUID(), source: .systemAudio,
            text: "A later system phrase.", isFinal: true, timestamp: 180))
        transcript.apply(TranscriptUpdate(segmentID: microphoneID, source: .microphone,
            text: "A pending microphone phrase with more words", isFinal: false, timestamp: 4))
        render(transcript, in: view)
        #expect(view.string == "System audio · 02:00\nThe confirmed system phrase.\nSystem audio · 03:00\nA later system phrase.\nMicrophone · Live\nA pending microphone phrase with more words")

        transcript.apply(TranscriptUpdate(segmentID: microphoneID, source: .microphone,
            text: "A finalized microphone phrase with more words.", isFinal: true, timestamp: 165))
        render(transcript, in: view)
        #expect(view.string == "System audio · 02:00\nThe confirmed system phrase.\nMicrophone · 02:45\nA finalized microphone phrase with more words.\nSystem audio · 03:00\nA later system phrase.")
        #expect(!view.string.contains("· Live"))
        #expect(transcript.segments.filter { $0.id == microphoneID }.count == 1)

        let headers = metadata(in: view)
        #expect(headers == ["System audio · 02:00\n", "Microphone · 02:45\n", "System audio · 03:00\n"])
    }

    @Test("Both live sources remain in arrival order while their timestamp estimates change")
    func pendingSourcesHaveStableArrivalOrder() {
        var transcript = SessionTranscript()
        let systemID = UUID()
        let microphoneID = UUID()
        transcript.apply(TranscriptUpdate(segmentID: systemID, source: .systemAudio,
            text: "System words", isFinal: false, timestamp: 70))
        transcript.apply(TranscriptUpdate(segmentID: microphoneID, source: .microphone,
            text: "Microphone words", isFinal: false, timestamp: 0))
        transcript.apply(TranscriptUpdate(segmentID: systemID, source: .systemAudio,
            text: "System words continue", isFinal: false, timestamp: 100))
        let view = RelayTranscriptTextView(frame: .zero)
        view.autoCopySelection = false
        render(transcript, in: view)
        #expect(view.string == "System audio · Live\nSystem words continue\nMicrophone · Live\nMicrophone words")
        #expect(metadata(in: view) == ["System audio · Live\n", "Microphone · Live\n"])
    }

    @Test("A finalized phrase without confirmed word timing shows its source without an invented clock")
    func finalWithoutWordTimingHasNoDanglingSeparator() {
        let session = TranscriptSession(segments: [TranscriptSegment(source: .microphone,
            text: "Keep these finalized words.", isFinal: true, timestamp: 0,
            timingIsConfirmed: false)])
        let view = RelayTranscriptTextView(frame: .zero)
        view.autoCopySelection = false
        view.applyTranscript(TranscriptPresentation.attributedText(for: session), followsTail: false)
        #expect(view.string == "Microphone\nKeep these finalized words.")
        #expect(metadata(in: view) == ["Microphone\n"])
        #expect(!view.string.contains("Live"))
        #expect(!view.string.contains("00:00"))
        #expect(!view.string.contains("·"))
    }

    @Test("Selected live words follow their phrase through final timing and text revisions")
    func selectedPendingWordsSurviveConfirmedReorder() {
        let microphoneID = UUID()
        var transcript = transcriptWithPendingMicrophone(id: microphoneID)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        render(transcript, in: view)
        let selected = (view.string as NSString).range(of: "selected microphone words")
        view.setSelectedRange(selected, affinity: .downstream, stillSelecting: false)
        #expect(pasteboard.string(forType: .string) == "selected microphone words")
        pasteboard.clearContents()
        pasteboard.setString("Copied elsewhere", forType: .string)

        transcript.apply(TranscriptUpdate(segmentID: microphoneID, source: .microphone,
            text: "Please keep selected microphone words today.", isFinal: true, timestamp: 165))
        render(transcript, in: view)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "selected microphone words")
        #expect(pasteboard.string(forType: .string) == "Copied elsewhere",
                "A streaming revision does not overwrite the clipboard.")
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "selected microphone words")
        #expect(view.selectedRange().location < (view.string as NSString).range(of: "Later system words.").location)
    }

    @Test("Selecting a confirmed neighbor stays attached when a live row moves ahead of it")
    func selectedConfirmedNeighborSurvivesReorder() {
        let microphoneID = UUID()
        var transcript = transcriptWithPendingMicrophone(id: microphoneID)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        render(transcript, in: view)
        view.setSelectedRange((view.string as NSString).range(of: "Later system words."),
                              affinity: .downstream, stillSelecting: false)
        transcript.apply(TranscriptUpdate(segmentID: microphoneID, source: .microphone,
            text: "Please keep selected microphone words today.", isFinal: true, timestamp: 165))
        render(transcript, in: view)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "Later system words.")
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "Later system words.")
    }

    @Test("A passage across moved rows never expands to include an unselected neighbor")
    func movedPassagesRemainDiscontiguous() {
        let firstID = UUID(), neighborID = UUID(), movingID = UUID()
        let first = TranscriptSegment(id: firstID, source: .systemAudio, text: "First selected words.", timestamp: 120)
        let neighbor = TranscriptSegment(id: neighborID, source: .systemAudio, text: "Unselected neighbor.",
                                         isFinal: false, timestamp: 0)
        let moving = TranscriptSegment(id: movingID, source: .microphone, text: "Last selected words.",
                                       isFinal: false, timestamp: 0)
        var transcript = SessionTranscript(segments: [first, moving, neighbor])
        let before = TranscriptPresentation.attributedText(for: TranscriptSession(segments: transcript.segments))
        transcript.apply(TranscriptUpdate(segmentID: neighborID, source: .systemAudio,
            text: neighbor.text, isFinal: true, timestamp: 180))
        let after = TranscriptPresentation.attributedText(for: TranscriptSession(segments: transcript.segments))
        let lower = (before.string as NSString).range(of: first.text).location
        let upper = NSMaxRange((before.string as NSString).range(of: moving.text))
        let mapped = TranscriptSelectionPolicy.mapSelections([NSRange(location: lower, length: upper - lower)],
                                                             from: before, to: after)
        let selected = TranscriptSelectionPolicy.selectedText(in: after, ranges: mapped)
        #expect(selected?.contains(first.text) == true)
        #expect(selected?.contains(moving.text) == true)
        #expect(selected?.contains(neighbor.text) == false)
        #expect(mapped.count == 2)
    }

    private func transcriptWithPendingMicrophone(id: UUID) -> SessionTranscript {
        SessionTranscript(segments: [
            TranscriptSegment(source: .systemAudio, text: "Earlier system words.", timestamp: 120),
            TranscriptSegment(source: .systemAudio, text: "Later system words.", timestamp: 180),
            TranscriptSegment(id: id, source: .microphone, text: "Please keep selected microphone words",
                              isFinal: false, timestamp: 0)
        ])
    }

    private func render(_ transcript: SessionTranscript, in view: RelayTranscriptTextView) {
        let session = TranscriptSession(segments: transcript.segments)
        view.applyTranscript(TranscriptPresentation.attributedText(for: session), followsTail: true)
    }

    private func metadata(in view: RelayTranscriptTextView) -> [String] {
        guard let storage = view.textStorage else { return [] }
        var headers: [String] = []
        storage.enumerateAttribute(.relayTranscriptMetadata, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value as? Bool == true { headers.append((storage.string as NSString).substring(with: range)) }
        }
        return headers
    }
}
