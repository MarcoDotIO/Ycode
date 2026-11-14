import AppKit
import QuartzCore
import YcodeIDECore

/// The source editor's rows at the document's end and across a re-wrap
/// (council round 7, `editor-area.md` I.3, I.4, I.6; rows 178, 179, 181):
///
/// - **The final empty line** (I.3). A document that ends with a line break
///   has one more line, empty, after it: TextKit lays it out as an empty
///   line fragment at the end of the last paragraph's layout fragment, so
///   the gutter numbers it, the current-line band draws on it and the
///   insertion point goes there (⌘↓), like any other line.
/// - **The exact height** (I.6). TextKit estimates the height of text it
///   has not laid out yet, and wrapped rows count short in that estimate:
///   the scroller's knob was 15 % too long and grew shorter as the text
///   scrolled. Documents up to `exactLayoutLines` are laid out whole, so
///   the knob is the track times the visible height over the whole
///   scrollable height (the final line and the overscroll included).
/// - **A re-wrap keeps the top line** (I.4). When the text view's width
///   changes (a split, a window or pane resize, a font change), the first
///   visible logical line stays at the top, at the same fraction of its
///   first row, in every pane, active or not; the gutter is drawn again in
///   the same pass.
extension SourceTextView {
    /// Documents up to this many lines are laid out whole after an open or
    /// a re-wrap (an 845-line file takes a few milliseconds).
    static let exactLayoutLines = 5_000

    /// Whether the text ends with a line break, so the line after it is the
    /// final empty line.
    var endsWithLineBreak: Bool {
        let ns = string as NSString
        return ns.length > 0 && ns.character(at: ns.length - 1) == 10
    }

    /// The final empty line's row (view coordinates), or nil when the text
    /// does not end with a line break.
    func finalEmptyLineRect() -> NSRect? {
        guard endsWithLineBreak, let tlm = textLayoutManager else { return nil }
        tlm.ensureLayout(for: NSTextRange(location: tlm.documentRange.endLocation))
        var rect: NSRect?
        tlm.enumerateTextLayoutFragments(from: tlm.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { fragment in
            if let extra = Self.extraLine(of: fragment) {
                let frame = fragment.layoutFragmentFrame
                rect = NSRect(x: 0, y: frame.minY + extra.typographicBounds.minY + self.textContainerOrigin.y, width: self.bounds.width,
                              height: extra.typographicBounds.height)
            }
            return false
        }
        if let rect { return rect }
        // No fragment for it (an empty document's layout): the insertion
        // point's own rectangle at the end.
        let ns = string as NSString
        guard let end = segmentRects(NSRange(location: ns.length, length: 0)).last else { return nil }
        return NSRect(x: 0, y: end.minY, width: bounds.width, height: max(end.height, Theme.lineHeight))
    }

    /// The empty line fragment TextKit adds after a final line break, when
    /// `fragment` is the last paragraph's.
    static func extraLine(of fragment: NSTextLayoutFragment) -> NSTextLineFragment? {
        let lines = fragment.textLineFragments
        guard lines.count >= 2, let last = lines.last, last.characterRange.length == 0,
              let end = fragment.textLayoutManager?.documentRange.endLocation,
              fragment.rangeInElement.endLocation.compare(end) != .orderedAscending else { return nil }
        return last
    }

    /// `lineRect`'s height for a fragment that also holds the final empty
    /// line: the fragment without that line.
    static func height(of fragment: NSTextLayoutFragment) -> CGFloat {
        let h = fragment.layoutFragmentFrame.height
        guard let extra = extraLine(of: fragment) else { return h }
        return max(0, h - extra.typographicBounds.height)
    }

    // MARK: Exact height (I.6)

    /// Lays the whole document out (up to `exactLayoutLines`) and sets the
    /// view's height to the text's exact height plus the overscroll.
    func settleDocumentHeight() {
        guard let tlm = textLayoutManager, lineIndex.lineCount <= Self.exactLayoutLines, enclosingScrollView != nil else { return }
        tlm.ensureLayout(for: tlm.documentRange)
        let text = tlm.usageBoundsForTextContainer.maxY + textContainerOrigin.y + textContainerInset.height
        let height = max(text, minSize.height)
        displayState.lastHeight = -1
        if abs(frame.height - heightWithOverscrollPreview(height)) > 0.25 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    /// The height `heightWithOverscroll` would give `base` (no state change).
    func heightWithOverscrollPreview(_ base: CGFloat) -> CGFloat { base + overscrollExtra(base: base) }

    // MARK: Re-wrap (I.4)

    /// Where the text's top is, as a logical line and the points below its
    /// first row's top (a top inside a later row of the line keeps that
    /// row: the points run on through the line's rows).
    struct TopAnchor: Equatable {
        var line: Int
        var into: CGFloat
    }

    /// The first visible logical line at the clip view's top edge (below
    /// the content inset: the text runs under the jump bar). At the top of
    /// the document (or past it) it is line 1 with `into` at or below 0, so
    /// that line 1 stays where it is too (row 223).
    func topAnchor() -> TopAnchor? {
        guard let scroll = enclosingScrollView, let tlm = textLayoutManager, let tcm = tlm.textContentManager else { return nil }
        let y = scroll.contentView.bounds.minY + scroll.contentInsets.top - textContainerOrigin.y
        guard y > 0 else { return TopAnchor(line: 1, into: y) }
        guard let fragment = tlm.textLayoutFragment(for: CGPoint(x: 0, y: y)) else { return nil }
        let offset = tcm.offset(from: tcm.documentRange.location, to: fragment.rangeInElement.location)
        return TopAnchor(line: lineIndex.line(at: offset), into: y - fragment.layoutFragmentFrame.minY)
    }

    /// Scrolls so that `anchor` is at the clip view's top edge again.
    func restore(_ anchor: TopAnchor) {
        guard let scroll = enclosingScrollView, let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let r = lineIndex.range(ofLine: anchor.line),
              let loc = tcm.location(tcm.documentRange.location, offsetBy: r.location) else { return }
        tlm.ensureLayout(for: NSTextRange(location: tlm.documentRange.location, end: loc) ?? NSTextRange(location: loc))
        guard let fragment = tlm.textLayoutFragment(for: loc) else { return }
        let frame = fragment.layoutFragmentFrame
        let into = min(anchor.into, max(0, Self.height(of: fragment) - 0.5))
        let clip = scroll.contentView
        let y = frame.minY + into + textContainerOrigin.y - scroll.contentInsets.top
        let kept = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: clip.bounds.minX, y: y), size: clip.bounds.size)).origin
        if kept != clip.bounds.origin {
            clip.scroll(to: kept)
            scroll.reflectScrolledClipView(clip)
        }
    }

    /// A width change (of the view or of its text container): the text
    /// re-wraps under the same top line, the height is made exact again and
    /// the gutter drawn in the same pass. Nested changes run inside the
    /// outer one.
    func keepingTopLine(_ change: () -> Void) {
        guard !rowsState.isRewrapping else { return change() }
        // While the window's layout moves, the line pinned at its start
        // (row 223): a scroll the system makes mid-motion cannot move it.
        let anchor = rowsState.motionAnchor ?? topAnchor()
        rowsState.isRewrapping = true
        defer { rowsState.isRewrapping = false }
        change()
        // While the window's layout moves (the inspector's slide, a live
        // resize) the whole document is not laid out on every frame: that
        // took most of each frame's time, so the slide drew a new position
        // only every 60–70 ms (round 8, row 204). TextKit lays out what is
        // on screen; the exact height follows once, when the motion ends.
        if isInLayoutMotion {
            rowsState.needsSettle = true
            SourceTextRowsState.pending.add(self)
        } else {
            // A single re-wrap (a window resized in one step, a split): the
            // new width's frame first, the exact height after it (row 206).
            settleAfterFirstFrame()
        }
        if let anchor { restore(anchor) }
        // The visible rows re-wrap in this frame, not at the motion's end
        // (row 223: the re-wrap stalled at about 0.31 of the slide, then
        // landed in one frame after it).
        if isInLayoutMotion {
            textLayoutManager?.textViewportLayoutController.layoutViewport()
            needsDisplay = true
        }
        (enclosingScrollView?.verticalRulerView ?? owner?.gutter)?.needsDisplay = true
    }

    /// Pins the top line for a motion of the window's layout (the
    /// inspector's slide, a live resize): every re-wrap until its end keeps
    /// this line, and the end restores it once more (row 223).
    func beginMotionAnchor() {
        guard rowsState.motionAnchor == nil else { return }
        rowsState.motionAnchor = topAnchor()
        SourceTextRowsState.anchored.add(self)
    }

    /// The motion's end: the pinned line at the top again, then unpinned.
    /// For `settleWindow` after it, a scroll the system makes on its own
    /// (its insertion point scrolled into view under the jump bar) is
    /// undone; a scroll event or a new selection ends that watch.
    func endMotionAnchor() {
        SourceTextRowsState.anchored.remove(self)
        guard let anchor = rowsState.motionAnchor else { return }
        rowsState.motionAnchor = nil
        restore(anchor)
        guard let clip = enclosingScrollView?.contentView else { return }
        let scrolls = EditorScrollView.scrollGeneration
        let selection = selectedRange()
        let until = CACurrentMediaTime() + Self.settleWindow
        clip.postsBoundsChangedNotifications = true
        rowsState.settleWatch.map(NotificationCenter.default.removeObserver)
        let center = NotificationCenter.default
        rowsState.settleWatch = center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard CACurrentMediaTime() < until, EditorScrollView.scrollGeneration == scrolls, self.selectedRange() == selection,
                      !self.rowsState.isRestoring else {
                    if CACurrentMediaTime() >= until || EditorScrollView.scrollGeneration != scrolls || self.selectedRange() != selection {
                        self.rowsState.settleWatch.map(NotificationCenter.default.removeObserver)
                        self.rowsState.settleWatch = nil
                    }
                    return
                }
                self.rowsState.isRestoring = true
                self.restore(anchor)
                self.rowsState.isRestoring = false
            }
        }
    }

    /// How long after a motion's end the pinned line is still kept (row
    /// 223: the line jumped about 80 ms after the slide's end).
    static let settleWindow: CFTimeInterval = 0.3

    /// Whether the window's layout is in motion: an inspector slide or a
    /// live resize of this window.
    var isInLayoutMotion: Bool { EditorBlurMotion.isHolding || inLiveResize }

    /// The exact height a re-wrap left for later (`keepingTopLine`), now,
    /// under the same top line (`liveResizeEnded`: called as this view's
    /// live resize ends).
    func settleAfterMotion(liveResizeEnded: Bool = false) {
        guard rowsState.needsSettle, !EditorBlurMotion.isHolding, liveResizeEnded || !inLiveResize else { return }
        rowsState.needsSettle = false
        SourceTextRowsState.pending.remove(self)
        let anchor = rowsState.motionAnchor ?? topAnchor()
        rowsState.isRewrapping = true
        defer { rowsState.isRewrapping = false }
        settleDocumentHeight()
        if let anchor { restore(anchor) }
        (enclosingScrollView?.verticalRulerView ?? owner?.gutter)?.needsDisplay = true
    }

    /// After an open or a re-wrap: the exact height once the frame showing the new text
    /// has been committed (council round 8, row 206: the whole document's
    /// layout no longer delays the switch's frame); at once off every
    /// display.
    func settleAfterFirstFrame() {
        let onScreen = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        guard onScreen, lineIndex.lineCount > Self.firstFrameLines else { return settleDocumentHeight() }
        rowsState.needsSettle = true
        rowsState.settleGeneration += 1
        let g = rowsState.settleGeneration
        // A run-loop timer: the run loop waits for it, so the frame is
        // committed first.
        let timer = Timer(timeInterval: 0.008, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.rowsState.settleGeneration == g else { return }
                self.settleAfterMotion()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Documents up to this many lines are laid out whole before the first
    /// frame (cheaper than a second pass).
    static let firstFrameLines = 150

    /// Every text view's deferred height, once the motion has ended.
    static func settleAllAfterMotion() {
        for v in SourceTextRowsState.pending.allObjects { v.settleAfterMotion() }
        for v in SourceTextRowsState.anchored.allObjects where !v.inLiveResize { v.endMotionAnchor() }
    }
}

/// The re-wrap's state (one per text view).
@MainActor
final class SourceTextRowsState {
    var isRewrapping = false
    /// A re-wrap during a motion (or an open) left the exact height for later.
    var needsSettle = false
    /// The latest deferred settle after an open.
    var settleGeneration = 0
    /// The text views waiting for it.
    static let pending = NSHashTable<SourceTextView>.weakObjects()
    /// The top line pinned for a motion of the window's layout (row 223).
    var motionAnchor: SourceTextView.TopAnchor?
    /// The text views with a pinned top line.
    static let anchored = NSHashTable<SourceTextView>.weakObjects()
    /// The watch on the clip view after a motion's end, and whether it is
    /// putting the line back.
    var settleWatch: NSObjectProtocol?
    var isRestoring = false
}
