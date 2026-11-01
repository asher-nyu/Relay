import AppKit
import SwiftUI

extension NSAttributedString.Key {
    /// Marks source/time labels that remain visible as context but are excluded
    /// from passage selection and copying.
    static let relayTranscriptMetadata = NSAttributedString.Key("RelayTranscriptMetadata")
    /// Stable phrase identity anchors selected words when confirmed timing
    /// moves a live row into its chronological position.
    static let relayTranscriptSegmentID = NSAttributedString.Key("RelayTranscriptSegmentID")
}

/// A native transcript surface. Selection is copied as it changes, including
/// inside AppKit's mouse-tracking loop, rather than waiting for mouse-up.
struct TranscriptTextView: NSViewRepresentable {
    var attributedText: NSAttributedString
    var autoCopySelection = true
    var followsTail = true
    var sessionID: UUID? = nil
    var onSelectionStarted: (@MainActor () -> Void)? = nil
    /// Mouse-release position in the visible viewport, using a top-left origin.
    var onSelectionCopied: (@MainActor (CGPoint) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> RelayTranscriptContainerView {
        let scrollView = RelayTranscriptScrollView()
        let containerView = RelayTranscriptContainerView(scrollView: scrollView)
        scrollView.contentView = RelayTranscriptClipView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder

        let textView = RelayTranscriptTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.allowsUndo = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = .labelColor
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel("Transcript")
        textView.setAccessibilityIdentifier("relay.transcript")
        scrollView.documentView = textView
        textView.autoCopySelection = autoCopySelection
        textView.onSelectionStarted = onSelectionStarted
        textView.onSelectionCopied = onSelectionCopied
        textView.applyTranscript(attributedText, followsTail: followsTail, sessionID: sessionID)
        return containerView
    }

    func updateNSView(_ containerView: RelayTranscriptContainerView, context: Context) {
        let scrollView = containerView.scrollView
        guard let textView = scrollView.documentView as? RelayTranscriptTextView else { return }
        textView.autoCopySelection = autoCopySelection
        textView.onSelectionStarted = onSelectionStarted
        textView.onSelectionCopied = onSelectionCopied
        textView.applyTranscript(attributedText, followsTail: followsTail, sessionID: sessionID)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? RelayTranscriptTextView)?.copySelectedTextIfNeeded()
        }
    }
}

/// Keep the floating control outside NSScrollView's managed content hierarchy.
/// This gives mouse and accessibility hit testing the same fixed viewport target.
@MainActor
final class RelayTranscriptContainerView: NSView {
    let scrollView: RelayTranscriptScrollView
    private lazy var latestButton: NSButton = {
        let button = RelayJumpToLatestButton(image: NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)!,
                              target: self, action: #selector(jumpToLatest))
        button.bezelStyle = .glass
        button.borderShape = .circle
        button.controlSize = .large
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        button.toolTip = "Jump to Latest"
        button.setAccessibilityLabel("Jump to Latest")
        button.setAccessibilityIdentifier("relay.jumpToLatest")
        return button
    }()

    @objc private func jumpToLatest() {
        (scrollView.documentView as? RelayTranscriptTextView)?.jumpToLatest()
    }

    init(scrollView: RelayTranscriptScrollView) {
        self.scrollView = scrollView
        super.init(frame: scrollView.frame)
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        positionLatestButton()
    }

    private func positionLatestButton() {
        let side: CGFloat = 36
        latestButton.frame = NSRect(x: max(0, bounds.maxX - side - 18),
            y: isFlipped ? bounds.maxY - side - 16 : bounds.minY + 16,
            width: side, height: side)
    }

    func updateJumpToLatestVisibility() {
        if (scrollView.documentView as? RelayTranscriptTextView)?.showsJumpToLatest == true {
            if latestButton.superview == nil {
                positionLatestButton()
                addSubview(latestButton, positioned: .above, relativeTo: scrollView)
                window?.invalidateCursorRects(for: latestButton)
            }
        } else {
            // Remove the control from the visual and accessibility trees while
            // following, so there is no invisible action in the tab order.
            latestButton.removeFromSuperview()
        }
    }
}

/// The transcript beneath this floating control owns an I-beam cursor. Register
/// the button's own cursor so its interaction is unmistakably a button.
@MainActor
final class RelayJumpToLatestButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
}

@MainActor
final class RelayTranscriptScrollView: NSScrollView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(userDidScroll),
            name: NSScrollView.didLiveScrollNotification, object: self)
    }

    required init?(coder: NSCoder) { nil }

    func updateJumpToLatestVisibility() {
        (superview as? RelayTranscriptContainerView)?.updateJumpToLatestVisibility()
    }

    @objc private func userDidScroll(_ notification: Notification) {
        (documentView as? RelayTranscriptTextView)?.transcriptViewportDidScroll()
    }
}

/// A viewport-height change does not necessarily resize its text document.
/// Observe size changes only; ordinary wheel scrolling must remain available.
@MainActor
final class RelayTranscriptClipView: NSClipView {
    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        let textView = documentView as? RelayTranscriptTextView
        textView?.beginViewportLayoutChange()
        super.setFrameSize(newSize)
        textView?.endViewportLayoutChange()
        if sizeChanged {
            textView?.transcriptViewportDidResize()
        }
    }

    override func setBoundsOrigin(_ newOrigin: NSPoint) {
        let changed = bounds.origin != newOrigin
        super.setBoundsOrigin(newOrigin)
        if changed, let textView = documentView as? RelayTranscriptTextView,
           textView.isTrackingSelection {
            textView.transcriptViewportDidScroll()
        }
    }

    override func scroll(to newOrigin: NSPoint) {
        let previousOrigin = bounds.origin
        super.scroll(to: newOrigin)
        if bounds.origin != previousOrigin, let textView = documentView as? RelayTranscriptTextView,
           textView.isTrackingSelection {
            textView.transcriptViewportDidScroll()
        }
    }
}

@MainActor
final class RelayTranscriptTextView: NSTextView {
    var autoCopySelection = true
    var onSelectionStarted: (@MainActor () -> Void)?
    /// Completion feedback is separate from clipboard writes during selection.
    var onSelectionCopied: (@MainActor (CGPoint) -> Void)?
    /// A separate pasteboard can be supplied by tests without touching the user clipboard.
    var selectionPasteboard = NSPasteboard.general
    private(set) var isTrackingSelection = false
    private var isApplyingTranscript = false
    private var lastWrittenText: String?
    private var lastWrittenChangeCount: Int?
    private var followsTranscriptTail = false
    private(set) var isFollowingLatest = true
    private var displayedSessionID: UUID?
    private var tailScrollPending = false
    private var isAdjustingTranscriptLayout = false
    private var viewportLayoutDepth = 0

    private var shouldFollowTail: Bool { followsTranscriptTail && isFollowingLatest }
    private var bottomGap: CGFloat {
        guard let scrollView = enclosingScrollView else { return 0 }
        return max(0, bounds.maxY - scrollView.documentVisibleRect.maxY)
    }

    var showsJumpToLatest: Bool { !isFollowingLatest && bottomGap > 4 }

    func beginViewportLayoutChange() { viewportLayoutDepth += 1 }
    func endViewportLayoutChange() { viewportLayoutDepth -= 1 }

    /// Transcript updates and resize corrections also move the clip view. Only
    /// scrolling outside those operations changes the reader's follow choice.
    func transcriptViewportDidScroll() {
        guard !isApplyingTranscript, !isAdjustingTranscriptLayout, viewportLayoutDepth == 0 else { return }
        if bottomGap > 16 {
            isFollowingLatest = false
            tailScrollPending = false
        } else if bottomGap <= 4, !isTrackingSelection {
            isFollowingLatest = true
        }
        updateJumpToLatestVisibility()
    }

    private func updateJumpToLatestVisibility() {
        (enclosingScrollView as? RelayTranscriptScrollView)?.updateJumpToLatestVisibility()
    }

    func jumpToLatest() {
        isFollowingLatest = true
        // Also useful in a saved transcript. It enables future live following,
        // without starting capture or clearing the person's selected words.
        tailScrollPending = true
        scrollToTranscriptTailIfNeeded(force: true)
        updateJumpToLatestVisibility()
    }

    override func layout() {
        super.layout()
        scrollToTranscriptTailIfNeeded()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let sizeChanged = frame.size != newSize
        beginViewportLayoutChange()
        super.setFrameSize(newSize)
        endViewportLayoutChange()
        if sizeChanged, shouldFollowTail, !isAdjustingTranscriptLayout {
            tailScrollPending = true
            scrollToTranscriptTailIfNeeded()
        }
        updateJumpToLatestVisibility()
    }

    func transcriptViewportDidResize() {
        if shouldFollowTail {
            tailScrollPending = true
            scrollToTranscriptTailIfNeeded()
        }
        updateJumpToLatestVisibility()
    }

    func beginTranscriptSelection() {
        onSelectionStarted?()
        isTrackingSelection = true
        lastWrittenText = nil
    }

    override func keyDown(with event: NSEvent) {
        let previousOrigin = enclosingScrollView?.contentView.bounds.origin
        super.keyDown(with: event)
        if enclosingScrollView?.contentView.bounds.origin != previousOrigin {
            transcriptViewportDidScroll()
        }
    }

    func endTranscriptSelection() {
        isTrackingSelection = false
        // New words may have arrived during AppKit's tracking loop. Preserve
        // the passage the user just selected instead of catching up on release.
        transcriptViewportDidScroll()
        scrollToTranscriptTailIfNeeded()
    }

    override func mouseDown(with event: NSEvent) {
        beginTranscriptSelection()
        // NSTextView can coalesce selection notifications during a drag. An
        // event-tracking-mode timer also samples the current selected ranges
        // while super.mouseDown is running its nested tracking loop.
        let timer = Timer(timeInterval: 1.0 / 30.0, target: self,
                          selector: #selector(copySelectionDuringTracking), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .eventTracking)
        defer {
            timer.invalidate()
            endTranscriptSelection()
            let copied = copySelectedTextIfNeeded()
            // NSTextView runs its own mouse-tracking loop. Feedback belongs to
            // the completed gesture, never its intermediate selection changes.
            if copied, NSEvent.pressedMouseButtons & 1 == 0,
               let scrollView = enclosingScrollView, let window {
                let location = scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                let bounds = scrollView.bounds
                let viewportLocation = CGPoint(x: location.x - bounds.minX,
                                               y: scrollView.isFlipped ? location.y - bounds.minY : bounds.maxY - location.y)
                onSelectionCopied?(viewportLocation)
            }
        }
        super.mouseDown(with: event)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        let spokenRanges = textStorage.map {
            TranscriptSelectionPolicy.spokenRanges(in: $0, ranges: ranges.map(\.rangeValue))
        } ?? ranges.map(\.rangeValue)
        super.setSelectedRanges(spokenRanges.map { NSValue(range: $0) }, affinity: affinity, stillSelecting: flag)
        copySelectedTextIfNeeded()
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting flag: Bool) {
        setSelectedRanges([NSValue(range: charRange)], affinity: affinity, stillSelecting: flag)
    }

    @objc private func copySelectionDuringTracking() {
        guard isTrackingSelection else { return }
        copySelectedTextIfNeeded()
    }

    private var selectedSpokenText: String? {
        guard let storage = textStorage else { return nil }
        return TranscriptSelectionPolicy.selectedText(in: storage, ranges: selectedRanges.map(\.rangeValue))
    }

    @discardableResult
    func copySelectedTextIfNeeded() -> Bool {
        guard autoCopySelection, !isApplyingTranscript else { return false }
        return writeSpokenSelection(to: selectionPasteboard, force: false)
    }

    /// Native Command-C and the contextual Copy action follow the same passage
    /// policy as automatic selection copying, even when that option is disabled.
    override func copy(_ sender: Any?) {
        writeSpokenSelection(to: selectionPasteboard, force: true)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let text = selectedSpokenText else { return false }
        return pasteboard.setString(text, forType: .string)
    }

    override func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard types.contains(.string) else { return false }
        return writeSpokenSelection(to: pasteboard, force: true)
    }

    @discardableResult
    private func writeSpokenSelection(to pasteboard: NSPasteboard, force: Bool) -> Bool {
        guard let text = selectedSpokenText else { return false }
        let isSelectionPasteboard = pasteboard.name == selectionPasteboard.name
        if !force, isSelectionPasteboard,
           text == lastWrittenText, pasteboard.changeCount == lastWrittenChangeCount { return true }
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        if isSelectionPasteboard {
            lastWrittenText = text
            lastWrittenChangeCount = pasteboard.changeCount
        }
        return true
    }

    func applyTranscript(_ attributedText: NSAttributedString, followsTail: Bool, sessionID: UUID? = nil) {
        let changedSession = sessionID != displayedSessionID
        let startedFollowing = followsTail && !followsTranscriptTail
        if changedSession || startedFollowing { isFollowingLatest = true }
        displayedSessionID = sessionID
        followsTranscriptTail = followsTail
        if !followsTail { tailScrollPending = false }
        guard let storage = textStorage else { return }
        guard !storage.isEqual(to: attributedText) else {
            if shouldFollowTail, startedFollowing || changedSession { tailScrollPending = true }
            scrollToTranscriptTailIfNeeded()
            updateJumpToLatestVisibility()
            return
        }
        let previousText = NSAttributedString(attributedString: storage)
        let previousRanges = selectedRanges.map(\.rangeValue)
        let previousOrigin = enclosingScrollView?.contentView.bounds.origin ?? .zero
        let readingAnchor = changedSession ? nil : viewportAnchor()

        isApplyingTranscript = true
        defer {
            isApplyingTranscript = false
            scrollToTranscriptTailIfNeeded()
            updateJumpToLatestVisibility()
        }
        storage.setAttributedString(attributedText)
        let restoredRanges = TranscriptSelectionPolicy.mapSelections(previousRanges, from: previousText, to: attributedText)
            .map { NSValue(range: $0) }
        setSelectedRanges(restoredRanges, affinity: .downstream, stillSelecting: isTrackingSelection)
        if let container = textContainer {
            layoutManager?.ensureLayout(for: container)
            sizeToFit()
        }
        tailScrollPending = shouldFollowTail
        if (!shouldFollowTail || isTrackingSelection), let scrollView = enclosingScrollView {
            let origin = readingAnchor.flatMap {
                restoredViewportOrigin($0, from: previousText, to: attributedText, x: previousOrigin.x)
            } ?? (changedSession ? .zero : previousOrigin)
            scrollView.contentView.scroll(to: scrollView.contentView.constrainBoundsRect(
                NSRect(origin: origin, size: scrollView.contentView.bounds.size)).origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    private struct ViewportAnchor {
        var character: Int
        var offsetFromLine: CGFloat
    }

    /// Anchor the visible words, not just the scroll offset: confirmed speech
    /// can move a phrase chronologically or add wrapped lines above the reader.
    private func viewportAnchor() -> ViewportAnchor? {
        guard let scrollView = enclosingScrollView, let manager = layoutManager,
              let container = textContainer, manager.numberOfGlyphs > 0 else { return nil }
        let y = scrollView.contentView.bounds.minY
        let point = NSPoint(x: 0, y: max(0, y - textContainerOrigin.y))
        let glyph = manager.glyphIndex(for: point, in: container)
        guard glyph < manager.numberOfGlyphs else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return ViewportAnchor(character: manager.characterIndexForGlyph(at: glyph),
                              offsetFromLine: y - line.minY - textContainerOrigin.y)
    }

    private func restoredViewportOrigin(_ anchor: ViewportAnchor, from oldText: NSAttributedString,
                                        to newText: NSAttributedString, x: CGFloat) -> NSPoint? {
        guard let manager = layoutManager, newText.length > 0,
              let mapped = TranscriptSelectionPolicy.mapSelections(
                [NSRange(location: anchor.character, length: 0)], from: oldText, to: newText).first else { return nil }
        let glyph = manager.glyphIndexForCharacter(at: min(mapped.location, newText.length - 1))
        guard glyph < manager.numberOfGlyphs else { return nil }
        let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSPoint(x: x, y: line.minY + textContainerOrigin.y + anchor.offsetFromLine)
    }

    private func scrollToTranscriptTailIfNeeded(force: Bool = false) {
        guard tailScrollPending, (shouldFollowTail || force), !isTrackingSelection,
              !isApplyingTranscript, !isAdjustingTranscriptLayout,
              let scrollView = enclosingScrollView, let container = textContainer,
              scrollView.contentSize.width > 0, scrollView.contentSize.height > 0 else { return }
        isAdjustingTranscriptLayout = true
        defer { isAdjustingTranscriptLayout = false }

        // Background windows may not get a display pass. Resolve text height
        // now, then move the actual viewport without waiting for activation.
        layoutManager?.ensureLayout(for: container)
        sizeToFit()
        let clip = scrollView.contentView
        let bottom = max(bounds.minY, bounds.maxY - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: bottom))
        scrollView.reflectScrolledClipView(clip)
        tailScrollPending = false
        updateJumpToLatestVisibility()
    }
}

/// Selection offsets use UTF-16, as required by NSTextView and NSRange.
enum TranscriptSelectionPolicy {
    /// Native multi-range selection keeps the source labels out of both the
    /// highlight and accessibility selection, including during mouse tracking.
    static func spokenRanges(in text: NSAttributedString, ranges: [NSRange]) -> [NSRange] {
        var spoken: [NSRange] = []
        for range in ranges where range.location != NSNotFound && range.location <= text.length {
            let bounded = NSRange(location: range.location, length: min(range.length, text.length - range.location))
            guard bounded.length > 0 else { continue }
            text.enumerateAttribute(.relayTranscriptMetadata, in: bounded) { marker, run, _ in
                if marker as? Bool != true { spoken.append(run) }
            }
        }
        var merged: [NSRange] = []
        for range in spoken.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, range)
            } else { merged.append(range) }
        }
        if !merged.isEmpty { return merged }
        let caret = ranges.first(where: { $0.location != NSNotFound })?.location ?? 0
        return [NSRange(location: min(caret, text.length), length: 0)]
    }

    /// Phrase identity survives chronological row moves. Map body revisions
    /// separately from the source/time header so a changing Live label cannot
    /// enlarge a passage selection into metadata or a neighboring phrase.
    static func mapSelections(_ ranges: [NSRange], from oldText: NSAttributedString,
                              to newText: NSAttributedString) -> [NSRange] {
        let oldRows = segmentRanges(in: oldText)
        let newRows = segmentRanges(in: newText)
        guard !oldRows.isEmpty, !newRows.isEmpty else {
            return ranges.map { mapSelection($0, from: oldText.string, to: newText.string) }
        }
        var mapped: [NSRange] = []
        for range in ranges where range.location != NSNotFound {
            let start = min(range.location, oldText.length)
            let bounded = NSRange(location: start, length: min(range.length, oldText.length - start))
            if bounded.length == 0 {
                let index = min(start, max(0, oldText.length - 1))
                guard oldText.length > 0,
                      let id = oldText.attribute(.relayTranscriptSegmentID, at: index, effectiveRange: nil) as? String,
                      let oldRow = oldRows[id], let newRow = newRows[id] else { continue }
                let local = NSRange(location: start - oldRow.location, length: 0)
                let offset = mapSelection(local, from: oldText.attributedSubstring(from: oldRow).string,
                                         to: newText.attributedSubstring(from: newRow).string)
                mapped.append(NSRange(location: newRow.location + offset.location, length: 0))
                continue
            }
            oldText.enumerateAttribute(.relayTranscriptSegmentID, in: bounded) { value, selectedRow, _ in
                guard let id = value as? String, let oldRow = oldRows[id], let newRow = newRows[id] else { return }
                let oldSections = sections(in: oldText, row: oldRow)
                let newSections = sections(in: newText, row: newRow)
                for oldSection in oldSections {
                    let selected = NSIntersectionRange(selectedRow, oldSection.range)
                    guard selected.length > 0,
                          let newSection = newSections.first(where: { $0.isMetadata == oldSection.isMetadata }) else { continue }
                    let local = NSRange(location: selected.location - oldSection.range.location, length: selected.length)
                    let offset = mapSelection(local,
                        from: oldText.attributedSubstring(from: oldSection.range).string,
                        to: newText.attributedSubstring(from: newSection.range).string)
                    if offset.length > 0 {
                        mapped.append(NSRange(location: newSection.range.location + offset.location, length: offset.length))
                    }
                }
            }
        }
        // A selection spanning rows may become discontiguous after a move.
        // Keep only its mapped passages, never the intervening unselected row.
        var merged: [NSRange] = []
        for range in mapped.sorted(by: { $0.location < $1.location }) {
            if let previous = merged.last, range.location <= NSMaxRange(previous) {
                merged[merged.count - 1] = NSUnionRange(previous, range)
            } else { merged.append(range) }
        }
        return merged.isEmpty ? [NSRange(location: min(ranges.first?.location ?? 0, newText.length), length: 0)] : merged
    }

    private static func segmentRanges(in text: NSAttributedString) -> [String: NSRange] {
        var result: [String: NSRange] = [:]
        text.enumerateAttribute(.relayTranscriptSegmentID, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let id = value as? String { result[id] = range }
        }
        return result
    }

    private static func sections(in text: NSAttributedString, row: NSRange) -> [(isMetadata: Bool, range: NSRange)] {
        var result: [(isMetadata: Bool, range: NSRange)] = []
        text.enumerateAttribute(.relayTranscriptMetadata, in: row) { value, range, _ in
            result.append((value as? Bool == true, range))
        }
        return result
    }

    static func selectedText(in string: String, ranges: [NSRange]) -> String? {
        selectedText(in: NSAttributedString(string: string), ranges: ranges)
    }

    static func selectedText(in attributedText: NSAttributedString, ranges: [NSRange]) -> String? {
        let text = attributedText.string as NSString
        let pieces = ranges.compactMap { range -> String? in
            guard range.location != NSNotFound, range.location <= text.length, range.length > 0 else { return nil }
            let length = min(range.length, text.length - range.location)
            guard length > 0 else { return nil }
            let selectionRange = NSRange(location: range.location, length: length)
            var spokenText = ""
            var skippedMetadata = false
            attributedText.enumerateAttribute(.relayTranscriptMetadata, in: selectionRange) { marker, run, _ in
                if marker as? Bool == true {
                    skippedMetadata = true
                    return
                }
                let body = text.substring(with: run)
                // A header marks a segment boundary. Keep that boundary when
                // the header itself contains the only visible line break.
                if skippedMetadata, !spokenText.isEmpty, !body.isEmpty,
                   spokenText.last?.isNewline != true, body.first?.isNewline != true {
                    spokenText.append("\n")
                }
                spokenText.append(body)
                skippedMetadata = false
            }
            return spokenText.isEmpty ? nil : spokenText
        }
        // Metadata gaps split a single drag into native ranges. Keep the body
        // line break already present at those boundaries instead of doubling it.
        let selection = pieces.reduce("") { result, piece in
            guard !result.isEmpty else { return piece }
            let separator = result.last?.isNewline == true || piece.first?.isNewline == true ? "" : "\n"
            return result + separator + piece
        }
        return selection.isEmpty ? nil : selection
    }

    /// Keep a selection attached to unchanged text when a live recognition
    /// revision inserts, removes, or replaces text before it.
    static func mapSelection(_ range: NSRange, from oldString: String, to newString: String) -> NSRange {
        let old = Array(oldString.utf16)
        let new = Array(newString.utf16)
        guard range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let oldStart = min(range.location, old.count)
        let oldEnd = oldStart + min(range.length, old.count - oldStart)
        var prefix = 0
        while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
        // Do not place the edit boundary between a UTF-16 surrogate pair.
        if prefix > 0, prefix < old.count, (0xDC00...0xDFFF).contains(old[prefix]) { prefix -= 1 }
        var suffix = 0
        while suffix < min(old.count - prefix, new.count - prefix),
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, suffix < old.count,
           (0xDC00...0xDFFF).contains(old[old.count - suffix]) { suffix -= 1 }
        let oldEditEnd = old.count - suffix
        let newEditEnd = new.count - suffix
        let delta = new.count - old.count
        func map(_ offset: Int, isEnd: Bool) -> Int {
            if offset < prefix { return offset }
            if offset > oldEditEnd { return offset + delta }
            if prefix == oldEditEnd {
                // At an insertion, keep the original characters selected:
                // start boundaries follow the insertion, end boundaries stay.
                return isEnd ? prefix : newEditEnd
            }
            if offset == prefix { return prefix }
            if offset == oldEditEnd { return newEditEnd }
            return isEnd ? newEditEnd : prefix
        }
        let start = min(max(0, map(oldStart, isEnd: false)), new.count)
        let end = min(max(start, map(oldEnd, isEnd: true)), new.count)
        return NSRange(location: start, length: end - start)
    }
}
