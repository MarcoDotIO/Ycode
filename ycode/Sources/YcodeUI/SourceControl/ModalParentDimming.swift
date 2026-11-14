import AppKit
import YcodeIDECore

/// The parent window's state while Ycode's window-modal alert or sheet is up
/// (`specs/ide/merge-sheet.md` §13.1, council round 4 row 97). Before the
/// veil darkens it, the window draws as disabled:
/// - its text at its disabled tone, about 0.63 of its value: the content
///   and the toolbar's text items (the scheme, the activity view, the
///   issues) are drawn at that opacity over the window's background;
/// - its toolbar buttons at their disabled tone (about 0.33): AppKit's own
///   disabled state for the segmented controls, buttons and image items;
/// - only the close button disabled (AppKit's own disabled window button,
///   grey); the overlay leaves the window buttons uncovered, so minimize
///   and zoom stay in colour and usable above the veil.
/// `restore` puts every value back as it was.
@MainActor
public final class ModalParentDimming {
    /// The text's share of its value while disabled (§13.1).
    public static let textTone = CGFloat(MergeModalTone.text)

    public private(set) weak var window: NSWindow?
    public private(set) var isApplied = false
    private var closeWasEnabled = true
    private var items: [(item: NSToolbarItem, autovalidates: Bool, enabled: Bool)] = []
    private var controls: [(control: NSControl, enabled: Bool)] = []
    private var faded: [(view: NSView, alpha: CGFloat)] = []

    public init(window: NSWindow) {
        self.window = window
    }

    /// The views drawn at the text tone, and the controls disabled (tests).
    public var fadedViews: [NSView] { faded.map(\.view) }
    public var disabledControls: [NSControl] { controls.map(\.control) }
    public var disabledItems: [NSToolbarItem] { items.map(\.item) }

    /// Draws the window as disabled, fading over `duration`.
    public func apply(duration: TimeInterval) {
        guard !isApplied, let w = window else { return }
        isApplied = true
        if let close = w.standardWindowButton(.closeButton) {
            closeWasEnabled = close.isEnabled
            close.isEnabled = false
        }
        if let content = w.contentView { faded.append((content, content.alphaValue)) }
        for item in w.toolbar?.items ?? [] {
            if let v = item.view {
                if let c = v as? NSControl, Self.isGlyphButton(c) {
                    controls.append((c, c.isEnabled))
                    c.isEnabled = false
                } else {
                    faded.append((v, v.alphaValue))
                }
            } else if item.isEnabled || item.autovalidates {
                items.append((item, item.autovalidates, item.isEnabled))
                item.autovalidates = false
                item.isEnabled = false
            }
        }
        setAlpha(duration: duration) { Self.tone(of: $0) }
    }

    /// Puts the window back as it was, fading over `duration`.
    public func restore(duration: TimeInterval) {
        guard isApplied else { return }
        isApplied = false
        window?.standardWindowButton(.closeButton)?.isEnabled = closeWasEnabled
        for c in controls { c.control.isEnabled = c.enabled }
        for i in items {
            i.item.isEnabled = i.enabled
            i.item.autovalidates = i.autovalidates
        }
        let old = Dictionary(faded.map { (ObjectIdentifier($0.view), $0.alpha) }, uniquingKeysWith: { a, _ in a })
        setAlpha(duration: duration) { old[ObjectIdentifier($0)] ?? 1 }
        controls = []
        items = []
        faded = []
        window?.toolbar?.validateVisibleItems()
    }

    private func setAlpha(duration: TimeInterval, _ value: @escaping (NSView) -> CGFloat) {
        let views = faded.map(\.view)
        guard duration > 0, window?.isVisible == true else {
            for v in views { v.alphaValue = value(v) }
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for v in views { v.animator().alphaValue = value(v) }
        }
    }

    /// A faded view's share: the issue capsule's symbols and counts at the
    /// glyphs' disabled tone (`workspace-window.md` W7.2: circle #6F2A27,
    /// count #6F6F70 in dark), every other view at the text tone.
    static func tone(of v: NSView) -> CGFloat { v is IssueCapsuleView ? CGFloat(MergeModalTone.glyph) : textTone }

    /// A toolbar control that shows glyphs (run, history, the panes and
    /// editor modes): AppKit's disabled state gives its disabled tone. Text
    /// controls (pop-ups) and custom views fade to the text tone instead.
    static func isGlyphButton(_ c: NSControl) -> Bool {
        if c is NSSegmentedControl { return true }
        if let b = c as? NSButton, !(b is NSPopUpButton) { return b.image != nil && b.title.isEmpty }
        return false
    }
}
