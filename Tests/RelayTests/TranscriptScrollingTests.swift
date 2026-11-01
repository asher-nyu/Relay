import AppKit
import Testing
@testable import Relay

@Suite("Live transcript scrolling", .serialized)
@MainActor
struct TranscriptScrollingTests {
    @Test("A small live viewport follows growing partial phrases and final phrases")
    func followsPartialAndFinalUpdates() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        var segments = history()
        let liveID = UUID()
        segments.append(TranscriptSegment(id: liveID, source: .systemAudio,
            text: "The latest thought begins here", isFinal: false, timestamp: 90))
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()

        segments[segments.count - 1].text +=
            " and continues across several lines as more words arrive from the speaker. " +
            "The new lines should remain visible throughout the transcription."
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()

        segments[segments.count - 1].isFinal = true
        segments.append(TranscriptSegment(source: .microphone,
            text: "This is the newest microphone phrase.", isFinal: false, timestamp: 95))
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
    }

    @Test("A background window reaches the latest text before it is brought forward")
    func followsUpdatesWithoutAKeyWindow() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        // Never order this window on screen or make it key. Its scrolling must
        // happen as text arrives, without an activation event to repair it.
        #expect(!fixture.window.isVisible)
        #expect(!fixture.window.isKeyWindow)
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()

        for index in 0..<4 {
            segments.append(TranscriptSegment(source: index.isMultiple(of: 2) ? .systemAudio : .microphone,
                text: "Background phrase \(index). Each new sentence must already be in view when Relay returns.",
                timestamp: Double(100 + index * 5)))
            fixture.render(segments, followsTail: true)
            try await fixture.expectLatestLineAtBottom()
            #expect(!fixture.window.isKeyWindow)
            #expect(!fixture.window.isVisible)
        }
    }

    @Test("Reading earlier text survives partial and final updates in foreground and background", arguments: [false, true])
    func preservesReadingPositionDuringLiveUpdates(foreground: Bool) async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        if foreground { fixture.window.makeKeyAndOrderFront(nil) }
        var segments = history()
        segments.append(TranscriptSegment(source: .systemAudio,
            text: "A new thought begins", isFinal: false, timestamp: 100))
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        fixture.scroll(to: NSPoint(x: 0, y: 75))
        let readingPosition = fixture.scrollView.contentView.bounds.origin
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.textView.showsJumpToLatest)

        segments[segments.count - 1].text += String(repeating: " and develops into another sentence", count: 12)
        fixture.render(segments, followsTail: true)
        try await fixture.expectReadingPosition(readingPosition)
        segments[segments.count - 1].isFinal = true
        segments.append(TranscriptSegment(source: .microphone,
            text: "The next speaker adds a fresh perspective.", isFinal: false, timestamp: 110))
        fixture.render(segments, followsTail: true)
        try await fixture.expectReadingPosition(readingPosition)
        #expect(fixture.textView.showsJumpToLatest)
        if !foreground {
            #expect(!fixture.window.isVisible)
            #expect(!fixture.window.isKeyWindow)
        }
    }

    @Test("A native mouse-wheel event detaches without relying on live-scroll notifications")
    func nativeMouseWheelPreservesReadingPosition() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                        wheelCount: 1, wheel1: 240, wheel2: 0, wheel3: 0))
        let event = try #require(NSEvent(cgEvent: wheel))
        // Phase-less wheel devices may never produce didLiveScroll. Dispatch
        // the real native event instead of manufacturing that notification.
        fixture.scrollView.scrollWheel(with: event)
        try await Task.sleep(for: .milliseconds(40))
        #expect(fixture.bottomGap > 100, "The wheel must actually move the viewport to earlier text.")
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.textView.showsJumpToLatest)
        let readingPosition = fixture.scrollView.contentView.bounds.origin

        segments.append(TranscriptSegment(source: .microphone,
            text: "A mouse-wheel reader keeps their place when new words arrive.", timestamp: 100))
        fixture.render(segments, followsTail: true)
        try await fixture.expectReadingPosition(readingPosition)
    }

    @Test("Jump to Latest returns immediately and follows subsequent background updates")
    func jumpToLatestResumesFollowing() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        fixture.scroll(to: .zero)
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.textView.showsJumpToLatest)

        // No recognition result is needed to make the button effective.
        fixture.textView.jumpToLatest()
        try await fixture.expectLatestLineAtBottom()
        #expect(fixture.textView.isFollowingLatest)
        #expect(!fixture.textView.showsJumpToLatest)
        segments.append(TranscriptSegment(source: .microphone,
            text: "Following continues while the window is in the background.", timestamp: 100))
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        #expect(!fixture.window.isKeyWindow)
    }

    @Test("Manually returning to the bottom resumes following with a small hysteresis band")
    func manualScrollBackToBottomResumesFollowing() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()

        fixture.scrollToBottom(gap: 10)
        #expect(fixture.textView.isFollowingLatest, "Tiny movements near the tail must not toggle following.")
        #expect(!fixture.textView.showsJumpToLatest)
        fixture.scrollToBottom(gap: 50)
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.textView.showsJumpToLatest)
        fixture.scrollToBottom(gap: 10)
        #expect(!fixture.textView.isFollowingLatest, "Returning partway through the threshold must not flicker following on.")
        fixture.scrollToBottom(gap: 3)
        #expect(fixture.textView.isFollowingLatest)
        #expect(!fixture.textView.showsJumpToLatest)

        segments.append(TranscriptSegment(source: .systemAudio,
            text: "Manual return to the bottom resumes automatic following.", timestamp: 100))
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
    }

    @Test("Selecting earlier words preserves the reading position and an unrelated clipboard")
    func selectionPreservesReadingPositionAndClipboard() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        fixture.scroll(to: .zero)
        let readingPosition = fixture.scrollView.contentView.bounds.origin
        let selectedWords = "a passage worth keeping"
        let range = (fixture.textView.string as NSString).range(of: selectedWords)
        #expect(range.location != NSNotFound)
        fixture.textView.setSelectedRange(range, affinity: .downstream, stillSelecting: false)
        #expect(fixture.pasteboard.string(forType: .string) == selectedWords)
        fixture.pasteboard.clearContents()
        fixture.pasteboard.setString("Copied in another app", forType: .string)

        segments.append(TranscriptSegment(source: .microphone,
            text: "A selected passage remains readable while the transcript grows.", timestamp: 100))
        fixture.render(segments, followsTail: true)
        try await fixture.expectReadingPosition(readingPosition)
        #expect((fixture.textView.string as NSString).substring(with: fixture.textView.selectedRange()) == selectedWords)
        #expect(fixture.pasteboard.string(forType: .string) == "Copied in another app")
    }

    @Test("Text arriving during a selection does not force the viewport down on release")
    func selectionReleaseKeepsItsReadingPosition() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        let readingPosition = fixture.scrollView.contentView.bounds.origin
        let selectedWords = "a passage worth keeping"
        let range = (fixture.textView.string as NSString).range(of: selectedWords, options: .backwards)
        fixture.textView.beginTranscriptSelection()
        fixture.textView.setSelectedRange(range, affinity: .downstream, stillSelecting: true)
        segments.append(TranscriptSegment(source: .systemAudio,
            text: String(repeating: "New speech arrives while the reader selects a passage. ", count: 12), timestamp: 100))
        fixture.render(segments, followsTail: true)
        #expect(abs(fixture.scrollView.contentView.bounds.origin.y - readingPosition.y) < 1)
        #expect(fixture.bottomGap > 100)

        fixture.textView.endTranscriptSelection()
        try await fixture.expectReadingPosition(readingPosition)
        #expect(fixture.textView.showsJumpToLatest)
        #expect(fixture.pasteboard.string(forType: .string) == selectedWords)
    }

    @Test("A corrected earlier phrase keeps the same visible passage anchored")
    func earlierTextGrowthPreservesVisibleWords() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        let marker = "Fictional phrase 6"
        let beforeLine = try fixture.lineRect(containing: marker)
        fixture.scroll(to: NSPoint(x: 0, y: beforeLine.minY + 3))
        let beforeOrigin = fixture.scrollView.contentView.bounds.origin.y
        let beforeOffset = beforeLine.minY - beforeOrigin
        #expect(!fixture.textView.isFollowingLatest)

        segments[0].text += String(repeating: "The speaker clarifies this earlier point. ", count: 15)
        fixture.render(segments, followsTail: true)
        let afterLine = try fixture.lineRect(containing: marker)
        let afterOrigin = fixture.scrollView.contentView.bounds.origin.y
        #expect(afterLine.minY > beforeLine.minY + 100, "The update must actually shift the visible passage in the document.")
        #expect(abs((afterLine.minY - afterOrigin) - beforeOffset) < 1,
                "Preserve the words being read, not just the old numeric scroll offset.")
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.textView.showsJumpToLatest)
    }

    @Test("Confirmed timing can reorder the visible phrase without displacing its words")
    func correctedTimestampPreservesVisiblePhrase() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        let marker = "Fictional phrase 6"
        let phraseID = segments[6].id
        let beforeLine = try fixture.lineRect(containing: marker)
        fixture.scroll(to: NSPoint(x: 0, y: beforeLine.minY + 3))
        let beforeOffset = beforeLine.minY - fixture.scrollView.contentView.bounds.origin.y
        #expect(!fixture.textView.isFollowingLatest)

        // Correct the currently visible phrase's clock, keeping its stable ID.
        // Presentation now places it between phrases 2 and 3 instead of 5 and 7.
        segments[6].timestamp = 11
        fixture.render(segments, followsTail: true)
        try await Task.sleep(for: .milliseconds(40))
        #expect(segments[6].id == phraseID)
        let orderedIDs = TranscriptFormatting.ordered(segments).map(\.id)
        #expect(orderedIDs.firstIndex(of: phraseID) == 3)
        let afterLine = try fixture.lineRect(containing: marker)
        let afterOffset = afterLine.minY - fixture.scrollView.contentView.bounds.origin.y
        #expect(beforeLine.minY > afterLine.minY + 100,
                "The fixture must actually reorder the visible phrase by multiple rows.")
        #expect(abs(afterOffset - beforeOffset) < 1,
                "The stable phrase identity must anchor the same visible words after reordering.")
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.textView.showsJumpToLatest)
    }

    @Test("A new transcript identity does not inherit another file's detached state")
    func newTranscriptStartsFollowing() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        let segments = history()
        let firstID = UUID()
        fixture.render(segments, followsTail: true, sessionID: firstID)
        try await fixture.expectLatestLineAtBottom()
        fixture.scroll(to: .zero)
        #expect(!fixture.textView.isFollowingLatest)
        fixture.render(segments, followsTail: true, sessionID: firstID)
        #expect(!fixture.textView.isFollowingLatest, "Routine re-rendering must not act like a new file.")

        fixture.render(segments, followsTail: true, sessionID: UUID())
        try await fixture.expectLatestLineAtBottom()
        #expect(fixture.textView.isFollowingLatest)
        #expect(!fixture.textView.showsJumpToLatest)
    }

    @Test("Resuming the same displayed text starts following without waiting for another phrase")
    func enablingFollowingWithUnchangedTextCatchesUp() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        let segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        fixture.render(segments, followsTail: false)
        fixture.scroll(to: .zero)
        #expect(fixture.bottomGap > 100)

        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
    }

    @Test("A paused transcript preserves the reading position when its saved content changes")
    func pausedTranscriptPreservesReadingPosition() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        var segments = history()
        fixture.render(segments, followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        fixture.render(segments, followsTail: false)
        fixture.scroll(to: NSPoint(x: 0, y: 75))
        let readingPosition = fixture.scrollView.contentView.bounds.origin
        #expect(fixture.bottomGap > 100)

        segments.append(TranscriptSegment(source: .systemAudio,
            text: "A final saved update should not move someone reading a paused transcript.", timestamp: 100))
        fixture.render(segments, followsTail: false)
        try await Task.sleep(for: .milliseconds(40))
        #expect(abs(fixture.scrollView.contentView.bounds.origin.y - readingPosition.y) < 1)
        #expect(fixture.bottomGap > 100)
    }

    @Test("Resizing a live viewport keeps the last line visible without another transcription update")
    func followsViewportResizingWithoutNewText() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        fixture.render(history(), followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        let originalText = fixture.textView.string
        let originalHeight = fixture.textView.bounds.height

        // Narrowing introduces new wrapped lines; changing only the viewport
        // height then exercises scrolling without any text or width revision.
        for size in [NSSize(width: 330, height: 128),
                     NSSize(width: 330, height: 84),
                     NSSize(width: 600, height: 180)] {
            fixture.window.setContentSize(size)
            fixture.window.contentView?.layoutSubtreeIfNeeded()
            #expect(abs(fixture.scrollView.contentSize.width - size.width) < 1)
            #expect(abs(fixture.scrollView.contentSize.height - size.height) < 1)
            try await fixture.expectLatestLineAtBottom()
            #expect(fixture.textView.string == originalText)
            if size.width == 330 {
                #expect(fixture.textView.bounds.height > originalHeight,
                        "The smaller width must genuinely reflow the transcript.")
            }
        }
    }

    @Test("Viewport resizing cannot re-enable following while earlier text is being read")
    func resizingDetachedViewportKeepsReadingPosition() async throws {
        let fixture = TranscriptScrollFixture()
        defer { fixture.close() }
        fixture.render(history(), followsTail: true)
        try await fixture.expectLatestLineAtBottom()
        fixture.scroll(to: NSPoint(x: 0, y: 75))
        let readingPosition = fixture.scrollView.contentView.bounds.origin

        // A height-only change keeps line geometry identical, making a precise
        // reading-position assertion possible while exercising the native resize.
        fixture.window.setContentSize(NSSize(width: 480, height: 180))
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        try await fixture.expectReadingPosition(readingPosition)
        #expect(fixture.textView.showsJumpToLatest)

        fixture.window.setContentSize(NSSize(width: 330, height: 128))
        fixture.window.contentView?.layoutSubtreeIfNeeded()
        #expect(!fixture.textView.isFollowingLatest)
        #expect(fixture.bottomGap > 100)
        #expect(fixture.textView.showsJumpToLatest)
    }

    private func history() -> [TranscriptSegment] {
        (0..<12).map { index in
            TranscriptSegment(source: index.isMultiple(of: 2) ? .systemAudio : .microphone,
                text: "Fictional phrase \(index) contains a passage worth keeping. " +
                      "The discussion continues with enough words to wrap inside a compact Relay window.",
                timestamp: Double(index * 5))
        }
    }
}

/// A real native text-and-scroll hierarchy with fictional content only. Its
/// short viewport models the transcript area in Relay's 300-point window.
@MainActor
private final class TranscriptScrollFixture {
    let window: NSWindow
    let scrollView: RelayTranscriptScrollView
    let textView: RelayTranscriptTextView
    let pasteboard = NSPasteboard.withUniqueName()

    init() {
        let viewport = NSRect(x: 0, y: 0, width: 480, height: 128)
        window = NSWindow(contentRect: viewport, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        scrollView = RelayTranscriptScrollView(frame: viewport)
        scrollView.contentView = RelayTranscriptClipView(frame: viewport)
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

        textView = RelayTranscriptTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width,
                                                      height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.selectionPasteboard = pasteboard
        scrollView.documentView = textView
        window.contentView = RelayTranscriptContainerView(scrollView: scrollView)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func close() {
        window.close()
        pasteboard.releaseGlobally()
    }

    func render(_ segments: [TranscriptSegment], followsTail: Bool, sessionID: UUID? = nil) {
        // Production feeds the presentation from SessionTranscript, which orders
        // confirmed timing before the view renders it. Exercise that same path.
        let session = TranscriptSession(segments: SessionTranscript(segments: segments).segments)
        textView.applyTranscript(TranscriptPresentation.attributedText(for: session), followsTail: followsTail, sessionID: sessionID)
    }

    func scroll(to origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
    }

    func scrollToBottom(gap: CGFloat = 0) {
        let y = max(0, textView.bounds.maxY - scrollView.contentView.bounds.height - gap)
        scroll(to: NSPoint(x: 0, y: y))
    }

    func lineRect(containing phrase: String) throws -> NSRect {
        let range = (textView.string as NSString).range(of: phrase)
        #expect(range.location != NSNotFound)
        let manager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        return manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
    }

    func expectReadingPosition(_ expected: NSPoint, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // Allow a deferred layout/update to run: an immediate assertion alone
        // would miss a queued forced tail-scroll.
        try await Task.sleep(for: .milliseconds(40))
        #expect(abs(scrollView.contentView.bounds.origin.y - expected.y) < 1,
                "Incoming text must not displace the reader.", sourceLocation: sourceLocation)
        #expect(!textView.isFollowingLatest, sourceLocation: sourceLocation)
        #expect(bottomGap > 100, sourceLocation: sourceLocation)
    }

    var bottomGap: CGFloat {
        max(0, textView.bounds.maxY - scrollView.documentVisibleRect.maxY)
    }

    func expectLatestLineAtBottom(sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while bottomGap > 1, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(textView.bounds.height > scrollView.contentSize.height * 3,
                "The fixture must genuinely overflow the native viewport.", sourceLocation: sourceLocation)
        #expect(bottomGap <= 1, "The clip view must already be at the document bottom.", sourceLocation: sourceLocation)
        #expect(textView.isFollowingLatest, sourceLocation: sourceLocation)
        #expect(!textView.showsJumpToLatest, sourceLocation: sourceLocation)
        let storage = try #require(textView.textStorage, sourceLocation: sourceLocation)
        let manager = try #require(textView.layoutManager, sourceLocation: sourceLocation)
        let container = try #require(textView.textContainer, sourceLocation: sourceLocation)
        let lastCharacter = NSRange(location: storage.length - 1, length: 1)
        let glyphs = manager.glyphRange(forCharacterRange: lastCharacter, actualCharacterRange: nil)
        let line = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let visible = scrollView.documentVisibleRect
        #expect(line.minY >= visible.minY - 1 && line.maxY <= visible.maxY + 1,
                "The final text line must be fully visible, not merely present in the text storage.",
                sourceLocation: sourceLocation)
    }
}
