import AppKit

/// The toolbar's activity view: workspace name, then status text, then
/// issue counts. See `specs/ide/workspace-window.md` §Toolbar.
@MainActor
public final class ActivityView: NSView {
    public var workspaceName = "" { didSet { needsDisplay = true } }
    /// The activity line; empty while idle (no "Ready", reference-ui-5.md §4.3, T4).
    public var status = "" { didSet { needsDisplay = true } }
    public var errors = 0 { didSet { needsDisplay = true } }
    public var warnings = 0 { didSet { needsDisplay = true } }
    public var isBusy = false { didSet { needsDisplay = true } }

    public override var intrinsicContentSize: NSSize { NSSize(width: 240, height: 34) }

    /// Two lines at the toolbar's left (reference-ui.md §5): the workspace
    /// name, and under it the activity. Issue counts are in their own
    /// capsule (`IssueCapsuleView`, reference-ui-2.md §2). While idle only
    /// the name is drawn, centered vertically.
    public override func draw(_ dirtyRect: NSRect) {
        let name = NSAttributedString(string: workspaceName, attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        let line = NSAttributedString(string: status, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        let lineHeight = status.isEmpty ? 0 : line.size().height
        let top = (bounds.height - name.size().height - lineHeight) / 2
        // Flipped drawing is not used: y grows upward.
        if !status.isEmpty { line.draw(at: NSPoint(x: 0, y: top)) }
        name.draw(at: NSPoint(x: 0, y: top + lineHeight))
        if isBusy {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 1, width: min(120, bounds.width) * 0.6, height: 2).fill()
        }
    }
}

/// The toolbar's issue capsule right of the scheme pill: errors, then
/// warnings, then failed tests; zero counts are left out and the capsule
/// is hidden with nothing to show (reference-ui-2.md §2).
@MainActor
public final class IssueCapsuleView: NSView {
    public var errors = 0 { didSet { update() } }
    public var warnings = 0 { didSet { update() } }
    public var failedTests = 0 { didSet { update() } }
    /// The visible parts as (symbol, count), in order (tests).
    public var parts: [(String, Int)] {
        [("xmark.octagon.fill", errors), ("exclamationmark.triangle.fill", warnings), ("xmark.diamond.fill", failedTests)].filter { $0.1 > 0 }
    }

    func update() {
        isHidden = parts.isEmpty
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: max(1, CGFloat(parts.count) * 40 + 8), height: 24)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard !parts.isEmpty else { return }
        NSColor.quaternaryLabelColor.withAlphaComponent(0.25).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 10, yRadius: 10).fill()
        var x: CGFloat = 8
        for (symbol, count) in parts {
            let color = symbol.hasPrefix("exclamation") ? Theme.warningColor : Theme.errorColor
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [color])) {
                img.draw(in: NSRect(x: x, y: bounds.midY - 6, width: 12, height: 12))
            }
            let t = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
            t.draw(at: NSPoint(x: x + 15, y: bounds.midY - t.size().height / 2))
            x += 40
        }
    }
}
