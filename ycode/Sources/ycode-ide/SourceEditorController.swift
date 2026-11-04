import Foundation
import Observation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax
#if os(Linux)
import OVPlatform
#else
import AppKit
#endif

/// One editor's view state (`docs/PARITY.md` §5.9 items 2–3): scrolling,
/// metrics, the caret's blink, keys and pointer. It lives as long as its
/// document, so a file shown again comes back where it was left.
///
/// Not observable: on OpenViews the editor's `Canvas` reads this state when
/// it draws, and a change asks the window to draw again from its last layout
/// (`invalidate()`), so typing, the caret's blink and scrolling do not lay out
/// the whole window. On Apple's SwiftUI (the shell's demonstration build) a
/// counter the view observes stands in.
@MainActor
final class SourceEditorController {
    /// Bumped by `invalidate()` where the toolkit has no redraw-only path.
    @Observable final class Redraw { var tick = 0 }
    let redraw = Redraw()

    let document: EditorDocument
    var buffer: EditorBuffer { document.buffer }

    // Scrolling.
    #if !os(Linux)
    var position = ScrollPosition(x: 0, y: 0)
    #endif
    /// The last scroll (the indicator shows for a second after it).
    var lastScroll: TimeInterval = -10
    private let indicatorTimer = NSObject()
    /// The viewport's origin in the content.
    var top: CGFloat = 0
    var left: CGFloat = 0
    var viewport = CGSize(width: 800, height: 600)
    private(set) var longestLine: CGFloat = 0

    // The caret.
    var caretOn = true
    private(set) var isFocused = false
    private var lastActivity: TimeInterval = 0
    #if os(Linux)
    var connection: TextSurfaceConnection?
    #endif

    // Metrics.
    let layout: EditorLineLayout
    /// Measures a non-ASCII character in the editor's font.
    final class Measure {
        var character: ((Character) -> CGFloat)?
    }
    let measure = Measure()
    var characterMeasure: ((Character) -> CGFloat)? {
        get { measure.character }
        set { measure.character = newValue }
    }
    /// The editor's origin in the window (the input method's caret rectangle).
    var windowOrigin = CGPoint.zero
    var fontSize: CGFloat = 12
    private(set) var measured = false
    var lineHeight: CGFloat = 15
    /// How far the text's top sits under the line's top, to center it.
    var textDrop: CGFloat = 0
    static let topInset: CGFloat = 4
    static let bottomInset: CGFloat = 8

    // Pointer.
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int)?
    private var dragStart: (range: Range<Int>, lines: Bool)?
    private var isPressed = false

    // Work after typing.
    private var refineTask: Task<Void, Never>?
    private var seenTextRevision = -1
    /// Escape outside the buffer's own use (closes the find bar).
    var onEscape: () -> Bool = { false }

    init(document: EditorDocument) {
        self.document = document
        let measure = measure
        layout = EditorLineLayout(tabWidth: Preferences.shared.tabWidth, advance: 7) { measure.character?($0) ?? 7 }
        fontSize = CGFloat(ShellPreferences.fontSize)
        lineHeight = (fontSize * 1.25).rounded()
        appliedRevision = ShellPreferences.shared.revision
    }

    /// The controller of `document`, kept with it.
    static func of(_ document: EditorDocument) -> SourceEditorController {
        if let c = document.viewState as? SourceEditorController { return c }
        let c = SourceEditorController(document: document)
        document.viewState = c
        return c
    }

    // MARK: Geometry

    var gutterWidth: CGFloat {
        let digits = max(3, String(buffer.lineCount).count)
        return max(CGFloat(WorkspaceChrome.gutterWidth), CGFloat(digits) * 6.2 + 26)
    }
    var numberRight: CGFloat { gutterWidth - 22 }
    var textOrigin: CGFloat { gutterWidth + CGFloat(WorkspaceChrome.textInset) }

    var contentHeight: CGFloat { CGFloat(buffer.lineCount) * lineHeight + Self.topInset + Self.bottomInset }
    var contentWidth: CGFloat { max(viewport.width, textOrigin + longestLine + 40) }

    func lineTop(_ n: Int) -> CGFloat { Self.topInset + CGFloat(n) * lineHeight }

    /// The visible lines.
    func visibleLines(height: CGFloat) -> Range<Int> {
        let first = max(0, Int((top - Self.topInset) / lineHeight))
        let last = min(buffer.lineCount, Int((top + height - Self.topInset) / lineHeight) + 1)
        return first..<max(first, last)
    }

    /// A viewport point → the text offset under it.
    func offset(at p: CGPoint) -> Int {
        let y = p.y + top - Self.topInset
        if y < 0 { return 0 }
        let n = Int(y / lineHeight)
        if n >= buffer.lineCount { return buffer.length }
        return layout.offset(atX: p.x + left - textOrigin, line: n, in: buffer)
    }

    /// The caret in viewport points.
    var caretRect: CGRect {
        let b = buffer
        let n = b.caretLine
        let x = textOrigin + layout.x(ofOffset: b.caret, line: n, in: b) - left
        return CGRect(x: x, y: lineTop(n) - top, width: 2, height: lineHeight)
    }

    /// The preferences the metrics were made for.
    private var appliedRevision = -1

    /// New settings (font size, tab width): measure again (called while
    /// drawing, before the metrics are used).
    func applyPreferences(revision: Int) {
        guard revision != appliedRevision else { return }
        appliedRevision = revision
        fontSize = CGFloat(ShellPreferences.fontSize)
        lineHeight = (fontSize * 1.25).rounded()
        layout.tabWidth = Preferences.shared.tabWidth
        measured = false
    }

    /// The width of a piece of text in the editor's font (Linux: through
    /// the drawing context the canvas last had).
    func prepareMetrics(measure: (String) -> CGSize) {
        guard !measured else { return }
        measured = true
        #if !os(Linux)
        characterMeasure = { [fontSize] ch in
            (String(ch) as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)]).width
        }
        #endif
        let ten = measure("0000000000")
        layout.reset(advance: ten.width / 10)
        textDrop = ((lineHeight - ten.height) / 2).rounded(.down)
        recomputeLongestLine()
    }

    private func recomputeLongestLine() {
        let w = layout.maxLineWidth(in: buffer)
        if w != longestLine { longestLine = w }
    }

    // MARK: Scrolling

    /// Draws the editor again.
    func invalidate() {
        #if os(Linux)
        connection?.setNeedsDisplay()
        #else
        redraw.tick &+= 1
        #endif
    }

    var now: TimeInterval {
        #if os(Linux)
        connection?.now ?? ProcessInfo.processInfo.systemUptime
        #else
        ProcessInfo.processInfo.systemUptime
        #endif
    }

    /// The viewport's size, from the drawing.
    func viewportChanged(_ size: CGSize) {
        guard size != viewport, size.width > 0, size.height > 0 else { return }
        viewport = size
        // Keep the offset inside the content.
        scroll(x: left, y: top)
    }

    /// A wheel or trackpad step (points, positive y up): three times the
    /// toolkit's step, about two lines per wheel notch.
    func wheel(_ d: CGSize) -> Bool {
        let (x, y) = (left - d.width * 3, top - d.height * 3)
        let mx = max(0, contentWidth - viewport.width), my = max(0, contentHeight - viewport.height)
        let nx = min(max(x, 0), mx), ny = min(max(y, 0), my)
        guard nx != left || ny != top else { return false }
        scroll(x: nx, y: ny)
        return true
    }

    /// The scroll view moved (Apple's SwiftUI).
    func scrolled(to r: CGRect) {
        let before = (top, left, viewport)
        if r.minY != top { top = max(0, r.minY) }
        if r.minX != left { left = max(0, r.minX) }
        if r.size != viewport, r.width > 0, r.height > 0 { viewport = r.size }
        if before != (top, left, viewport) { invalidate() }
    }

    func scroll(x: CGFloat, y: CGFloat) {
        let mx = max(0, contentWidth - viewport.width), my = max(0, contentHeight - viewport.height)
        let nx = min(max(x, 0), mx), ny = min(max(y, 0), my)
        if nx == left, ny == top { return }
        left = nx
        top = ny
        lastScroll = now
        #if os(Linux)
        // The indicator goes a second after the last step.
        connection?.setTimer(indicatorTimer, after: 1.05) { [weak self] in self?.invalidate() }
        #else
        position.scrollTo(x: nx, y: ny)
        #endif
        invalidate()
    }

    /// Scrolls just enough to show the caret.
    func revealCaret() {
        guard measured else { return }
        let n = buffer.caretLine
        var y = top, x = left
        let lt = lineTop(n)
        if lt < top { y = lt - Self.topInset }
        if lt + lineHeight > top + viewport.height { y = lt + lineHeight + Self.bottomInset - viewport.height }
        let cx = textOrigin + layout.x(ofOffset: buffer.caret, line: n, in: buffer)
        let margin = layout.advance * 4
        if cx - margin < left + gutterWidth { x = max(0, cx - gutterWidth - margin) }
        if cx + margin > left + viewport.width { x = cx + margin - viewport.width }
        scroll(x: x, y: y)
    }

    /// Scrolls the caret's line to the middle (a jump from elsewhere).
    func centerCaret() {
        guard measured else { return }
        let n = buffer.caretLine
        let cx = textOrigin + layout.x(ofOffset: buffer.caret, line: n, in: buffer)
        let x = cx + 40 > viewport.width ? cx + 40 - viewport.width : 0
        scroll(x: x, y: lineTop(n) - (viewport.height - lineHeight) / 2)
    }

    // MARK: After a change

    /// Anything the user did: the caret shows, and shows up.
    func noteActivity(reveal: Bool = true) {
        restartBlink()
        if reveal { revealCaret() }
        invalidate()
        let rev = buffer.textRevision
        if rev != seenTextRevision {
            seenTextRevision = rev
            textDidChange()
        }
    }

    private func textDidChange() {
        // The caret's line may be the longest now; a full pass waits for a pause.
        let w = layout.width(ofLine: buffer.caretLine, in: buffer)
        if w > longestLine { longestLine = w }
        scheduleRefine()
    }

    /// Swift's parser pass follows at once while it is quick, else after
    /// typing pauses (`specs/ide/source-editor.md`, Highlighting).
    func scheduleRefine(after delay: Double = 0.3) {
        refineTask?.cancel()
        let doc = buffer.document
        if doc.hasParsed, doc.lastRefineDuration < 0.008, doc.needsRefinement, buffer.refineHighlighting() {
            invalidate()
        }
        refineTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled, let self else { return }
            if self.buffer.refineHighlighting() { self.invalidate() }
            self.recomputeLongestLine()
        }
    }

    // MARK: The caret's blink

    private func restartBlink() {
        caretOn = true
        #if os(Linux)
        guard let connection else { return }
        lastActivity = connection.now
        scheduleBlink()
        #endif
    }

    private func scheduleBlink() {
        #if os(Linux)
        guard let connection, isFocused else {
            connection?.setTimer(self, after: nil) {}
            return
        }
        connection.setTimer(self, after: 0.53) { [weak self] in self?.blink() }
        #endif
    }

    private func blink() {
        #if os(Linux)
        guard isFocused, let connection else { return }
        // It rests after 10 s, so an idle window draws nothing.
        if connection.now - lastActivity >= 10 {
            if !caretOn {
                caretOn = true
                invalidate()
            }
            return
        }
        caretOn.toggle()
        invalidate()
        scheduleBlink()
        #endif
    }

    func setFocused(_ f: Bool) {
        isFocused = f
        caretOn = f
        if f { restartBlink() } else { scheduleBlink() }
        invalidate()
    }

    // MARK: Pointer

    func pointerChanged(start: CGPoint, location: CGPoint, time: TimeInterval, shift: Bool) {
        if !isPressed {
            isPressed = true
            press(start, time: time, shift: shift)
            if location != start { drag(location) }
        } else {
            drag(location)
        }
    }

    func pointerEnded() {
        isPressed = false
        dragStart = nil
    }

    private func press(_ p: CGPoint, time: TimeInterval, shift: Bool) {
        var count = 1
        // Half a second between clicks (the desktops' usual double-click time).
        if let l = lastClick, time - l.time < 0.5, hypot(p.x - l.point.x, p.y - l.point.y) < 5 {
            count = l.count % 3 + 1
        }
        lastClick = (time, p, count)
        let o = offset(at: p)
        let b = buffer
        if p.x < gutterWidth, !shift {
            // The gutter selects the line.
            b.selectLine(at: o)
            dragStart = (b.selection.range, true)
        } else if shift, count == 1 {
            b.extendSelection(to: o)
            dragStart = nil
        } else {
            switch count {
            case 2:
                b.selectWord(at: o)
                dragStart = (b.selection.range, false)
            case 3:
                b.selectLine(at: o)
                dragStart = (b.selection.range, true)
            default:
                b.setCaret(o)
                dragStart = nil
            }
        }
        noteActivity(reveal: false)
    }

    private func drag(_ p: CGPoint) {
        // Past an edge the view scrolls along.
        if p.y < 0 || p.y > viewport.height || p.x < gutterWidth || p.x > viewport.width {
            let dy = p.y < 0 ? p.y : max(0, p.y - viewport.height)
            let dx = p.x < gutterWidth ? p.x - gutterWidth : max(0, p.x - viewport.width)
            scroll(x: left + dx, y: top + dy)
        }
        let o = offset(at: p)
        if let d = dragStart {
            buffer.extendGranular(from: d.range, to: o, lines: d.lines)
        } else {
            buffer.extendSelection(to: o)
        }
        noteActivity(reveal: false)
    }

    // MARK: Commands

    /// Performs a key's command; true when it was one.
    func perform(_ command: EditorKeyCommand, clipboard: (get: () -> String?, set: (String) -> Void)) -> Bool {
        let b = buffer
        switch command {
        case .move(let unit, let forward, let extending):
            b.move(unit, forward: forward, extending: extending)
        case .moveVertically(let lines, let extending):
            b.moveVertically(lines: lines, extending: extending, layout: layout)
        case .page(let down, let extending):
            let lines = max(1, Int(viewport.height / lineHeight) - 1)
            b.moveVertically(lines: down ? lines : -lines, extending: extending, layout: layout)
            scroll(x: left, y: top + CGFloat(down ? lines : -lines) * lineHeight)
        case .deleteBackward(let unit): b.deleteBackward(unit)
        case .deleteForward(let unit): b.deleteForward(unit)
        case .newline: b.newline()
        case .tab(let backward): b.tab(backward: backward)
        case .selectAll: b.selectAll()
        case .copy:
            if let s = b.copyText() { clipboard.set(s) }
            return true
        case .cut:
            if let s = b.cutText() { clipboard.set(s) }
        case .paste:
            if let s = clipboard.get(), !s.isEmpty { b.paste(s) }
        case .undo: b.undo()
        case .redo: b.redo()
        case .escape:
            return onEscape()
        }
        noteActivity()
        return true
    }
}

#if os(Linux)
extension SourceEditorController: TextSurfaceClient {
    func surfaceConnected(_ c: TextSurfaceConnection?) {
        connection = c
    }

    private var clipboard: (get: () -> String?, set: (String) -> Void) {
        (get: { [connection] in connection?.clipboardText }, set: { [connection] in connection?.clipboardText = $0 })
    }

    func surfaceInsertText(_ text: String) {
        buffer.insertText(text)
        noteActivity()
    }

    func surfaceSetMarkedText(_ text: String, cursor: Int) {
        let starting = !buffer.hasMarkedText && !text.isEmpty
        buffer.setMarkedText(text, cursor: cursor)
        noteActivity()
        if starting { connection?.caretMoved() }
    }

    func surfaceHandleKey(_ e: KeyEvent) -> Bool {
        guard e.isDown else { return false }
        // Keys belong to the input method while it composes.
        if buffer.hasMarkedText { return false }
        guard let key = EditorKey(e.key) else { return false }
        var m: EditorKeyModifiers = []
        if e.modifiers.contains(.shift) { m.insert(.shift) }
        if e.modifiers.contains(.control) || e.modifiers.contains(.command) { m.insert(.primary) }
        if e.modifiers.contains(.option) { m.insert(.alt) }
        guard let c = EditorKeyBindings.command(key, m) else { return false }
        return perform(c, clipboard: clipboard)
    }

    var surfaceCaretRect: CGRect {
        var r = caretRect
        r.origin.x += windowOrigin.x
        r.origin.y += windowOrigin.y
        return r
    }

    func surfaceFocusChanged(_ focused: Bool) {
        if !focused, buffer.hasMarkedText { buffer.setMarkedText("", cursor: 0) }
        setFocused(focused)
    }

    func surfaceCanPerform(_ command: TextSurfaceCommand) -> Bool {
        let b = buffer
        switch command {
        case .undo: return b.canUndo && !b.isReadOnly
        case .redo: return b.canRedo && !b.isReadOnly
        case .cut, .delete: return !b.selection.isEmpty && !b.isReadOnly
        case .copy: return !b.selection.isEmpty
        case .paste: return !b.isReadOnly && (connection?.hasClipboardText ?? false)
        case .selectAll: return b.length > 0
        }
    }

    func surfacePerform(_ command: TextSurfaceCommand) {
        let c: EditorKeyCommand
        switch command {
        case .undo: c = .undo
        case .redo: c = .redo
        case .cut: c = .cut
        case .copy: c = .copy
        case .paste: c = .paste
        case .selectAll: c = .selectAll
        case .delete:
            buffer.deleteSelection()
            noteActivity()
            return
        }
        _ = perform(c, clipboard: clipboard)
    }
}

extension EditorKey {
    init?(_ k: OVPlatform.Key) {
        switch k {
        case .leftArrow: self = .left
        case .rightArrow: self = .right
        case .upArrow: self = .up
        case .downArrow: self = .down
        case .home: self = .home
        case .end: self = .end
        case .pageUp: self = .pageUp
        case .pageDown: self = .pageDown
        case .backspace: self = .backspace
        case .deleteForward: self = .delete
        case .return: self = .enter
        case .tab: self = .tab
        case .escape: self = .escape
        case .character(let c): self = .character(c)
        default: return nil
        }
    }
}
#else
extension SourceEditorController {
    /// On macOS (Apple's SwiftUI, where this shell is a demonstration; the
    /// product is the AppKit IDE): keys through `onKeyPress`, without an input method.
    func handle(_ p: KeyPress) -> KeyPress.Result {
        let key: EditorKey
        switch p.key {
        case .leftArrow: key = .left
        case .rightArrow: key = .right
        case .upArrow: key = .up
        case .downArrow: key = .down
        case .home: key = .home
        case .end: key = .end
        case .pageUp: key = .pageUp
        case .pageDown: key = .pageDown
        case .delete: key = .backspace
        case .deleteForward: key = .delete
        case .return: key = .enter
        case .tab: key = .tab
        case .escape: key = .escape
        default: key = .character(p.key.character)
        }
        var m: EditorKeyModifiers = []
        if p.modifiers.contains(.shift) { m.insert(.shift) }
        if p.modifiers.contains(.command) { m.insert(.primary) }
        if p.modifiers.contains(.option) { m.insert(.alt) }
        if let c = EditorKeyBindings.command(key, m) {
            let done = perform(c, clipboard: (get: { NSPasteboard.general.string(forType: .string) },
                                              set: { NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string) }))
            return done ? .handled : .ignored
        }
        guard m.isSubset(of: [.shift]), !p.characters.isEmpty else { return .ignored }
        buffer.insertText(p.characters)
        noteActivity()
        return .handled
    }
}
#endif
