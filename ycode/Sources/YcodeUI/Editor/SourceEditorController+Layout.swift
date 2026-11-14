import AppKit
import YcodeIDECore

/// The editor's geometry under its bars (`specs/ide/editor-area.md`
/// §C.1–§C.5, `liquid-glass.md` §7.3): the text scrolls under the toolbar
/// band, the jump bar, the sticky header and the bottom bar; the content
/// insets keep it clear of them at rest. The minimap sits between the text
/// and the scroll bar's lane, which is at the editor's right edge.
extension SourceEditorController {
    /// The content insets: the safe area (the toolbar above, the debug bar
    /// below), the jump bar and the find bar.
    var barInsets: NSEdgeInsets {
        let safe = view.safeAreaInsets
        return NSEdgeInsets(top: safe.top + JumpBar.height + (isShowingFindBar ? findBar.frame.height : 0), left: 0, bottom: safe.bottom, right: 0)
    }

    /// The scroll bar's lane at the right edge: the layout-taking style's
    /// width, none for overlay scroll bars.
    var scrollerLaneWidth: CGFloat {
        guard scrollView.scrollerStyle == .legacy, scrollView.hasVerticalScroller, let s = scrollView.verticalScroller, !s.isHidden else { return 0 }
        return s.frame.width
    }

    func updateEditorInsets() {
        guard isViewLoaded else { return }
        let insets = barInsets
        let old = scrollView.contentInsets
        if abs(old.top - insets.top) > 0.25 || abs(old.bottom - insets.bottom) > 0.25 {
            let atTop = scrollView.contentView.bounds.minY <= -old.top + 0.5
            // The content insets already keep the scroll bar's track
            // clear of the bars (metrics.md §12.2: y 86–839).
            scrollView.contentInsets = insets
            if atTop {
                scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.minX, y: -insets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        let lane = scrollerLaneWidth
        // The minimap covers the scroller's first 3 points and meets its
        // 11-point lane: no darker strip between them (G.2, row 116).
        let overlap = minimapWidthValue > 0 && lane >= CGFloat(EditorMetrics.minimapStrip) ? CGFloat(EditorMetrics.minimapStrip) : 0
        if overlap != minimapOverlap {
            let base = minimapWidthValue
            minimapOverlap = overlap
            minimapWidth.constant = base > 0 ? base + overlap : 0
        }
        if minimapTrailing.constant != -(lane - overlap) { minimapTrailing.constant = -(lane - overlap) }
        let header = -(lane + minimapWidthValue)
        if stickyHeaderTrailing.constant != header { stickyHeaderTrailing.constant = header }
        updateTextContainerWidth()
        updateMinimapViewport()
    }

    /// The text container ends 10 before the minimap's separator (80
    /// columns in an 850-point editor).
    func updateTextContainerWidth() {
        guard Preferences.shared.wrapLines, let tc = textView.textContainer else { return }
        let clip = scrollView.contentView
        // Before the editor has a size, the container follows the view.
        guard view.bounds.width > 200, clip.bounds.width > 200 else {
            tc.widthTracksTextView = true
            return
        }
        // The clip view runs under the gutter (its bounds start left of 0),
        // so the text's room is measured in the text view's coordinates.
        let visibleEnd = textView.convert(NSPoint(x: clip.bounds.maxX, y: 0), from: clip).x
        let end: CGFloat
        if minimapWidthValue > 0, !minimap.isHidden {
            end = textView.convert(NSPoint(x: minimapLeftEdge, y: 0), from: view).x - CGFloat(EditorMetrics.textToMinimap)
        } else {
            end = visibleEnd
        }
        // A row's last cell may end a point past the edge (row 115).
        let width = max(40, min(end, visibleEnd) - textView.textContainerOrigin.x) + CGFloat(EditorMetrics.wrapTolerance)
        let docWidth = clip.bounds.width + min(0, clip.bounds.minX)
        // A re-wrap keeps the first visible line at the top (I.4, row 179).
        guard tc.widthTracksTextView || abs(tc.size.width - width) > 0.5 || abs(textView.frame.width - docWidth) > 0.5 else { return }
        textView.keepingTopLine {
            tc.widthTracksTextView = false
            if abs(tc.size.width - width) > 0.5 { tc.size = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude) }
            if abs(textView.frame.width - docWidth) > 0.5 { textView.setFrameSize(NSSize(width: docWidth, height: textView.frame.height)) }
        }
    }

    /// Where the text container ends, in the text view's coordinates.
    var textContainerEnd: CGFloat {
        guard let tc = textView.textContainer else { return textView.bounds.width }
        return tc.widthTracksTextView || !Preferences.shared.wrapLines ? textView.bounds.width : textView.textContainerOrigin.x + tc.size.width
    }

    /// The minimap follows the scroll position.
    func updateMinimapViewport() {
        guard minimapWidthValue > 0 else { return }
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let visibleHeight = max(0, clip.bounds.height - insets.top - insets.bottom)
        let top = clip.bounds.minY + insets.top
        let docHeight = textView.frame.height
        let scrollable = max(1, docHeight - visibleHeight)
        minimap.contentTop = insets.top
        minimap.visibleTop = max(0, top)
        minimap.visibleHeight = visibleHeight
        minimap.scrollFraction = min(1, max(0, top / scrollable))
        minimap.advance = Theme.advance
    }

    /// A click in the minimap: that document point to the middle of the
    /// visible area.
    func scrollMinimapTarget(_ y: CGFloat) {
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        let visibleHeight = max(0, clip.bounds.height - insets.top - insets.bottom)
        let maxY = max(-insets.top, textView.frame.height - clip.bounds.height + insets.bottom)
        let target = min(maxY, max(-insets.top, y - visibleHeight / 2 - insets.top))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The minimap's bars from the text and its colours.
    func updateMinimapRows() {
        guard minimapWidthValue > 0, let storage = textView.textStorage else { minimap.rows = []; return }
        let advance = max(1, Theme.advance)
        let width = textView.textContainer.map { $0.widthTracksTextView ? textView.bounds.width : $0.size.width } ?? textView.bounds.width
        // Without wrapping the container is unbounded: no column limit.
        let columns = width.isFinite && width < 100_000 ? Int(width / advance) : 10_000
        minimap.textTopInset = CGFloat(EditorMetrics.firstLineInset)
        // One bar per token (§D.6): the syntax document's tokens.
        let doc = syntax.document.flatMap { $0.units.count == storage.length ? $0 : nil }
        let tokens = doc.map { MinimapView.tokenInteriors($0.tokens(in: 0..<storage.length)) } ?? IndexSet()
        minimap.rows = MinimapView.rows(of: storage, columns: columns, tabWidth: Preferences.shared.tabWidth, wraps: Preferences.shared.wrapLines,
                                        tokens: tokens)
        updateMinimapViewport()
    }
}

/// Wrapped lines continue 4 columns past their own indentation
/// (`editor-area.md` §C.1): each paragraph gets its own head indent when
/// TextKit lays it out; the text storage is left alone.
extension SourceEditorController: NSTextContentStorageDelegate {
    public nonisolated func textContentStorage(_ textContentStorage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? {
        let snap = wrapSnapshot
        guard snap.wraps, snap.advance > 0, let text = textContentStorage.textStorage, NSMaxRange(range) <= text.length, range.length > 0 else { return nil }
        let para = text.attributedSubstring(from: range)
        let indent = EditorMetrics.wrappedIndent(of: Substring(para.string), tabWidth: snap.tabWidth)
        let base = (para.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle) ?? NSParagraphStyle.default
        let style = (base.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.headIndent = CGFloat(indent) * snap.advance
        let out = NSMutableAttributedString(attributedString: para)
        out.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: out.length))
        return NSTextParagraph(attributedString: out)
    }
}

/// What the (nonisolated) paragraph delegate reads; written on the main
/// actor when the settings or the font change.
struct WrapSnapshot: Sendable {
    var wraps = true
    var advance: CGFloat = 8
    var tabWidth = 4
}
