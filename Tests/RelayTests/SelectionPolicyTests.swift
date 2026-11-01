import AppKit
import Testing
@testable import Relay

@Suite("Transcript selection")
struct SelectionPolicyTests {
    @Test("Copy keeps whitespace and selected punctuation verbatim")
    func verbatimSelection() {
        #expect(TranscriptSelectionPolicy.selectedText(in: "First line.\n  Second line!", ranges: [NSRange(location: 10, length: 16)]) == ".\n  Second line!")
    }

    @Test("Caret and invalid selections leave the clipboard alone")
    func emptySelections() {
        #expect(TranscriptSelectionPolicy.selectedText(in: "Relay", ranges: []) == nil)
        #expect(TranscriptSelectionPolicy.selectedText(in: "Relay", ranges: [NSRange(location: 2, length: 0)]) == nil)
        #expect(TranscriptSelectionPolicy.selectedText(in: "Relay", ranges: [NSRange(location: NSNotFound, length: 4)]) == nil)
        #expect(TranscriptSelectionPolicy.selectedText(in: "Relay", ranges: [NSRange(location: 99, length: 4)]) == nil)
    }

    @Test("Multiple selected ranges copy only visible text")
    func multipleRanges() {
        #expect(TranscriptSelectionPolicy.selectedText(in: "System: Hello. Microphone: Yes.", ranges: [NSRange(location: 8, length: 6), NSRange(location: 27, length: 4)]) == "Hello.\nYes.")
    }

    @Test("Native UTF-16 offsets handle emoji and composed characters")
    func unicodeSelection() {
        let text = "Hello 👋🏽, café."
        let range = (text as NSString).range(of: "👋🏽, café")
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [range]) == "👋🏽, café")
    }

    @Test("Appending live text preserves the existing selected words")
    func appending() {
        let old = "One complete sentence."
        let selected = NSRange(location: 4, length: 18)
        #expect(TranscriptSelectionPolicy.mapSelection(selected, from: old, to: old + " More live text.") == selected)
    }

    @Test("Inserting text before a selection keeps it attached to the old words")
    func insertionBefore() {
        let old = "Hello world"
        let new = "Hello brave world"
        let mapped = TranscriptSelectionPolicy.mapSelection(NSRange(location: 6, length: 5), from: old, to: new)
        #expect(TranscriptSelectionPolicy.selectedText(in: new, ranges: [mapped]) == "world")
    }

    @Test("Replacing text before a selection adjusts its UTF-16 offset")
    func revisionBefore() {
        let old = "A short preface. Keep these words."
        let new = "A longer introduction. Keep these words."
        let mapped = TranscriptSelectionPolicy.mapSelection((old as NSString).range(of: "Keep these words."), from: old, to: new)
        #expect(TranscriptSelectionPolicy.selectedText(in: new, ranges: [mapped]) == "Keep these words.")
    }

    @Test("Removing selected content returns a valid range")
    func deletion() {
        let mapped = TranscriptSelectionPolicy.mapSelection(NSRange(location: 0, length: 100), from: "Old transcript", to: "")
        #expect(mapped == NSRange(location: 0, length: 0))
    }

    @Test("Unicode revisions never map outside the new string")
    func unicodeRevision() {
        let old = "👋 Hello, world."
        let new = "🌟 Hello, world."
        let mapped = TranscriptSelectionPolicy.mapSelection((old as NSString).range(of: "world"), from: old, to: new)
        #expect(TranscriptSelectionPolicy.selectedText(in: new, ranges: [mapped]) == "world")
    }

    @Test("Streaming updates preserve selection without replacing the clipboard")
    @MainActor func streamingDoesNotCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        view.applyTranscript(NSAttributedString(string: "Hello world"), followsTail: false)
        view.setSelectedRange(NSRange(location: 6, length: 5), affinity: .downstream, stillSelecting: false)
        #expect(pasteboard.string(forType: .string) == "world")
        pasteboard.clearContents()
        pasteboard.setString("Copied elsewhere", forType: .string)
        view.applyTranscript(NSAttributedString(string: "Hello brave world"), followsTail: true)
        #expect(view.selectedRange() == NSRange(location: 12, length: 5))
        #expect(pasteboard.string(forType: .string) == "Copied elsewhere")
    }

    @Test("Live selection changes replace the clipboard before selection ends")
    @MainActor func selectionBeforeMouseUp() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        view.applyTranscript(NSAttributedString(string: "Relay captures the conversation."), followsTail: false)
        view.setSelectedRange(NSRange(location: 0, length: 5), affinity: .downstream, stillSelecting: true)
        #expect(pasteboard.string(forType: .string) == "Relay")
        view.setSelectedRange(NSRange(location: 0, length: 14), affinity: .downstream, stillSelecting: true)
        #expect(pasteboard.string(forType: .string) == "Relay captures")
        view.setSelectedRange(NSRange(location: 14, length: 0), affinity: .downstream, stillSelecting: false)
        #expect(pasteboard.string(forType: .string) == "Relay captures")
    }
    private func attributedFixture() -> NSAttributedString {
        let text = NSMutableAttributedString(string: "")
        text.append(NSAttributedString(string: "System audio · 0:00\n", attributes: [.relayTranscriptMetadata: true]))
        text.append(NSAttributedString(string: "First sentence.\n"))
        text.append(NSAttributedString(string: "Microphone · 0:12\n", attributes: [.relayTranscriptMetadata: true]))
        text.append(NSAttributedString(string: "Second sentence with 👋🏽 and café."))
        return text
    }

    @Test("Selecting multiple sources copies spoken text without either header")
    func spokenTextAcrossSources() {
        let text = attributedFixture()
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [NSRange(location: 0, length: text.length)]) ==
                "First sentence.\nSecond sentence with 👋🏽 and café.")
    }

    @Test("A partial passage spanning a source header keeps body line boundaries")
    func partialCrossSourcePassage() {
        let text = attributedFixture()
        let string = text.string as NSString
        let start = string.range(of: "sentence.").location
        let end = NSMaxRange(string.range(of: "Second sentence"))
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [NSRange(location: start, length: end - start)]) ==
                "sentence.\nSecond sentence")
    }

    @Test("Partial source headers are omitted without removing selected body characters")
    func partialHeader() {
        let text = attributedFixture()
        let string = text.string as NSString
        let start = string.range(of: "audio").location
        let end = NSMaxRange(string.range(of: "First"))
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [NSRange(location: start, length: end - start)]) == "First")
        let header = string.range(of: "Microphone · 0:12\n")
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [header]) == nil)
    }

    @Test("Speech that resembles a source label or timecode is preserved verbatim")
    func spokenLabelsRemain() {
        let spoken = "Say System audio · 0:00, then say Microphone at 0:12."
        let text = NSMutableAttributedString(string: "Microphone · 0:01\n", attributes: [.relayTranscriptMetadata: true])
        text.append(NSAttributedString(string: spoken))
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [NSRange(location: 0, length: text.length)]) == spoken)
    }

    @Test("Removing a metadata-only line break still separates spoken segments")
    func metadataBoundary() {
        let text = NSMutableAttributedString(string: "First.")
        text.append(NSAttributedString(string: "\nMicrophone · 0:12\n", attributes: [.relayTranscriptMetadata: true]))
        text.append(NSAttributedString(string: "Second."))
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [NSRange(location: 0, length: text.length)]) == "First.\nSecond.")
    }

    @Test("Unicode passage selection removes only marked metadata")
    func attributedUnicode() {
        let text = attributedFixture()
        let range = (text.string as NSString).range(of: "👋🏽 and café")
        #expect(TranscriptSelectionPolicy.selectedText(in: text, ranges: [range]) == "👋🏽 and café")
    }

    @Test("Still-selecting updates replace the clipboard using only spoken passages")
    @MainActor func spokenDragSelection() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)
        let first = (text.string as NSString).range(of: "First sentence.")
        view.setSelectedRange(NSRange(location: 0, length: NSMaxRange(first)), affinity: .downstream, stillSelecting: true)
        #expect(pasteboard.string(forType: .string) == "First sentence.")
        view.setSelectedRange(NSRange(location: 0, length: text.length), affinity: .downstream, stillSelecting: true)
        #expect(pasteboard.string(forType: .string) == "First sentence.\nSecond sentence with 👋🏽 and café.")
    }

    @Test("Native Copy omits metadata even when automatic selection copying is off")
    @MainActor func nativeCopyUsesSpokenText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Before copying", forType: .string)
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        view.autoCopySelection = false
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)
        view.setSelectedRange(NSRange(location: 0, length: text.length), affinity: .downstream, stillSelecting: false)
        #expect(pasteboard.string(forType: .string) == "Before copying")
        view.copy(nil)
        #expect(pasteboard.string(forType: .string) == "First sentence.\nSecond sentence with 👋🏽 and café.")
        #expect(pasteboard.types?.contains(.string) == true)
        #expect(pasteboard.data(forType: .rtf) == nil)
        #expect(pasteboard.data(forType: .rtfd) == nil)
        #expect(pasteboard.data(forType: .html) == nil)
        #expect(view.string == text.string)
    }

    @Test("Header-only automatic and native copying leave existing clipboard content intact")
    @MainActor func headerOnlyDoesNotCopy() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep this", forType: .string)
        let initialCount = pasteboard.changeCount
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)
        let header = (text.string as NSString).range(of: "System audio · 0:00\n")
        view.setSelectedRange(header, affinity: .downstream, stillSelecting: true)
        view.copy(nil)
        #expect(!view.writeSelection(to: pasteboard, types: [.string]))
        #expect(!view.writeSelection(to: pasteboard, type: .string))
        #expect(pasteboard.changeCount == initialCount)
        #expect(pasteboard.string(forType: .string) == "Keep this")
    }

    @Test("Native pasteboard writing cannot leak headers through rich text")
    @MainActor func pasteboardTypesAreSpokenPlainText() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.autoCopySelection = false
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)
        view.setSelectedRange(NSRange(location: 0, length: text.length), affinity: .downstream, stillSelecting: false)
        #expect(view.writablePasteboardTypes == [.string])
        #expect(!view.writeSelection(to: pasteboard, types: [.rtf]))
        #expect(!view.writeSelection(to: pasteboard, type: .rtf))
        #expect(view.writeSelection(to: pasteboard, types: [.rtf, .string]))
        #expect(pasteboard.string(forType: .string) == "First sentence.\nSecond sentence with 👋🏽 and café.")
        #expect(pasteboard.data(forType: .rtf) == nil)
    }

    @Test("Live revisions keep highlighted body words selected without copying metadata")
    @MainActor func metadataSelectionSurvivesStreaming() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let before = attributedFixture()
        view.applyTranscript(before, followsTail: false)
        let selected = (before.string as NSString).range(of: "Second sentence")
        view.setSelectedRange(selected, affinity: .downstream, stillSelecting: false)
        #expect(pasteboard.string(forType: .string) == "Second sentence")
        pasteboard.clearContents()
        pasteboard.setString("Copied elsewhere", forType: .string)
        let after = NSMutableAttributedString(attributedString: before)
        after.replaceCharacters(in: (before.string as NSString).range(of: "First sentence."), with: "First sentence with a longer revision.")
        view.applyTranscript(after, followsTail: true)
        #expect((view.string as NSString).substring(with: view.selectedRange()) == "Second sentence")
        #expect(pasteboard.string(forType: .string) == "Copied elsewhere")
        #expect(view.textStorage?.attribute(.relayTranscriptMetadata, at: 0, effectiveRange: nil) as? Bool == true)
    }

    @Test("Native selection highlights only spoken runs during dragging and after release", arguments: [true, false])
    @MainActor func nativeHighlightSkipsMetadata(stillSelecting: Bool) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)

        view.setSelectedRange(NSRange(location: 0, length: text.length),
                              affinity: .downstream, stillSelecting: stillSelecting)
        let expected = [
            (text.string as NSString).range(of: "First sentence.\n"),
            (text.string as NSString).range(of: "Second sentence with 👋🏽 and café.")
        ]
        #expect(view.selectedRanges.map(\.rangeValue) == expected)
        expectMetadataUnselected(in: view)
        #expect(pasteboard.string(forType: .string) == "First sentence.\nSecond sentence with 👋🏽 and café.",
                "Skipping a source header must not insert an extra blank line.")

        // Exercise the multiple-range setter independently, including a header
        // selected on its own and a partial header joined to spoken words.
        let firstHeader = (text.string as NSString).range(of: "System audio · 0:00\n")
        let firstBody = (text.string as NSString).range(of: "First sentence.")
        let secondHeader = (text.string as NSString).range(of: "Microphone · 0:12\n")
        let secondWords = (text.string as NSString).range(of: "Second sentence")
        view.setSelectedRanges([
            NSValue(range: firstHeader),
            NSValue(range: firstBody),
            NSValue(range: NSRange(location: secondHeader.location,
                                   length: NSMaxRange(secondWords) - secondHeader.location))
        ], affinity: .upstream, stillSelecting: stillSelecting)
        #expect(view.selectedRanges.map(\.rangeValue) == [firstBody, secondWords])
        expectMetadataUnselected(in: view)
        #expect(pasteboard.string(forType: .string) == "First sentence.\nSecond sentence")
    }

    @Test("Select All exposes body-only native selections and preserves visible headers")
    @MainActor func selectAllHighlightsBodiesOnly() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)
        view.selectAll(nil)

        #expect(view.selectedRanges.count == 2)
        expectMetadataUnselected(in: view)
        #expect(view.string == text.string, "Labels stay visible; only selection excludes them.")
        #expect(pasteboard.string(forType: .string) == "First sentence.\nSecond sentence with 👋🏽 and café.")
    }

    @Test("A metadata-only selection collapses without highlighting or replacing the clipboard", arguments: [true, false])
    @MainActor func metadataOnlyHasNoHighlightedRange(stillSelecting: Bool) {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Keep the user's existing clipboard", forType: .string)
        let beforeCount = pasteboard.changeCount
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)

        let header = (text.string as NSString).range(of: "Microphone · 0:12\n")
        view.setSelectedRanges([NSValue(range: header)], affinity: .upstream, stillSelecting: stillSelecting)
        #expect(view.selectedRanges.count == 1)
        #expect(view.selectedRange().length == 0)
        #expect(view.selectedRange().location <= text.length)
        #expect(pasteboard.changeCount == beforeCount)
        #expect(pasteboard.string(forType: .string) == "Keep the user's existing clipboard")
    }

    @Test("A selection can cross a header and contract again without retaining its label")
    @MainActor func expandedSelectionCanContractAcrossMetadata() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        let text = attributedFixture()
        view.applyTranscript(text, followsTail: false)
        let string = text.string as NSString
        let first = string.range(of: "sentence.")
        let second = string.range(of: "Second sentence")
        let span = NSRange(location: first.location, length: NSMaxRange(second) - first.location)

        view.setSelectedRange(span, affinity: .downstream, stillSelecting: true)
        #expect(view.selectedRanges.count == 2)
        expectMetadataUnselected(in: view)
        #expect(pasteboard.string(forType: .string) == "sentence.\nSecond sentence")

        view.setSelectedRange(first, affinity: .upstream, stillSelecting: true)
        #expect(view.selectedRanges.map(\.rangeValue) == [first])
        #expect(pasteboard.string(forType: .string) == "sentence.")

        view.setSelectedRange(span, affinity: .upstream, stillSelecting: false)
        expectMetadataUnselected(in: view)
        #expect(pasteboard.string(forType: .string) == "sentence.\nSecond sentence")
    }

    @Test("Body-only highlighting survives chronological reordering without copying incoming content")
    @MainActor func bodySelectionSurvivesReorderedRows() {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let view = RelayTranscriptTextView(frame: .zero)
        view.selectionPasteboard = pasteboard
        var first = TranscriptSegment(source: .systemAudio, text: "First selected phrase.", timestamp: 30)
        let second = TranscriptSegment(source: .microphone, text: "Second selected phrase.", timestamp: 60)
        let before = TranscriptPresentation.attributedText(for: TranscriptSession(segments: [first, second]))
        view.applyTranscript(before, followsTail: false)
        view.selectAll(nil)
        expectMetadataUnselected(in: view)

        pasteboard.clearContents()
        pasteboard.setString("Copied in another app", forType: .string)
        first.timestamp = 90
        let incoming = TranscriptSegment(source: .systemAudio, text: "New unselected phrase.", timestamp: 120)
        let ordered = SessionTranscript(segments: [first, second, incoming]).segments
        view.applyTranscript(TranscriptPresentation.attributedText(for: TranscriptSession(segments: ordered)),
                             followsTail: false)

        #expect(view.selectedRanges.count == 2)
        expectMetadataUnselected(in: view)
        #expect(pasteboard.string(forType: .string) == "Copied in another app")
        let highlighted = view.selectedRanges.map { (view.string as NSString).substring(with: $0.rangeValue) }.joined()
        #expect(highlighted.contains(first.text))
        #expect(highlighted.contains(second.text))
        #expect(!highlighted.contains(incoming.text))
        view.copy(nil)
        let copied = pasteboard.string(forType: .string) ?? ""
        #expect(copied.contains("Second selected phrase.\nFirst selected phrase."))
        #expect(!copied.contains("\n\n"))
        #expect(!copied.contains("System audio"))
        #expect(!copied.contains("Microphone"))
    }

    @MainActor private func expectMetadataUnselected(in view: RelayTranscriptTextView) {
        guard let storage = view.textStorage else {
            Issue.record("The native text view must retain its attributed transcript.")
            return
        }
        for range in view.selectedRanges.map(\.rangeValue) where range.length > 0 {
            storage.enumerateAttribute(.relayTranscriptMetadata, in: range) { value, _, _ in
                #expect(value as? Bool != true, "Visible native selection must exclude source labels and timestamps.")
            }
        }
    }

}
