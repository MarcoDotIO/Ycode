import AppKit

/// The floating glass bars of the side areas (`specs/ide/liquid-glass.md`
/// §2.3–§2.5): the navigator's selector bar and bottom bar, the inspector's
/// tab bar and the Coding Assistant header. They are 30 points tall glass
/// capsules (`NSGlassEffectView`, macOS 26 and later) over content that may
/// scroll beneath them. Before macOS 26 nothing is drawn and the earlier
/// layout stays. Reduce Transparency, Increase Contrast and the inactive
/// window's flat look are the material's own.
@MainActor
enum GlassBars {
    /// Whether the Liquid Glass layout applies.
    static var enabled: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }
    /// A bar's height.
    static let height: CGFloat = 30
    /// A bar's top: one point above the toolbar's bottom (the reference's
    /// bars start at y 51 under a 52-point toolbar).
    static let topOffset: CGFloat = -1

    /// A glass capsule (corner radius half the bar's height) behind
    /// controls laid out as its siblings; a plain, empty view before
    /// macOS 26.
    static func capsule(cornerRadius: CGFloat = height / 2) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.cornerRadius = cornerRadius
            g.style = .regular
            return g
        }
        return NSView()
    }
}

/// The selected tab's recessed pill inside a glass bar (§2.3, §2.5): a
/// fully rounded quiet fill under the selected icon, no accent color. The
/// fill is a semantic system color set in `updateLayer`, so it follows
/// light and dark.
final class SelectionPillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = bounds.height / 2
        layer?.cornerCurve = .continuous
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    /// Centers the pill (`size`) under `target`, a view in the same
    /// superview; hidden when there is none.
    func follow(_ target: NSView?, size: NSSize) {
        guard let target, !target.isHidden, let sup = superview, target.superview != nil else { isHidden = true; return }
        let r = sup.convert(target.bounds, from: target)
        frame = NSRect(x: (r.midX - size.width / 2).rounded(), y: (r.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        isHidden = false
        needsDisplay = true
    }
}
