import AppKit
import YcodeIDECore

// Council round 4 (`specs/ide/settings.md` R4.1): a navigation row's icon
// (a 24 × 24 rounded square with a vertical gradient and a white symbol),
// its disclosure chevron, and the card switch (36 × 16). Everything is
// drawn by Ycode from the spec's descriptions; no system artwork.

/// A navigation row's icon: a rounded square, lighter at the top, with a
/// white symbol drawn by Ycode.
final class SettingsRowIconView: NSView {
    let icon: SettingsRowIcon

    init(_ icon: SettingsRowIcon) {
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: SettingsMetrics.rowIconSize, height: SettingsMetrics.rowIconSize))
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: SettingsMetrics.rowIconSize, height: SettingsMetrics.rowIconSize) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let square = NSBezierPath(roundedRect: r, xRadius: SettingsMetrics.rowIconRadius, yRadius: SettingsMetrics.rowIconRadius)
        let g = icon.gradient
        // Flipped: angle 90 runs from the top (y 0) to the bottom.
        NSGradient(starting: SettingsColors.rgb(g.top), ending: SettingsColors.rgb(g.bottom))?.draw(in: square, angle: 90)
        NSColor.white.set()
        Self.drawSymbol(icon, in: r)
    }

    /// The white symbol, in a flipped 24 × 24 box.
    static func drawSymbol(_ icon: SettingsRowIcon, in r: NSRect) {
        switch icon {
        case .display:
            // A window with a side panel: a rounded-rectangle outline, a bar
            // filled along its right side.
            let frame = NSRect(x: r.minX + 5, y: r.minY + 6.5, width: 14, height: 11)
            let outline = NSBezierPath(roundedRect: frame, xRadius: 2.5, yRadius: 2.5)
            outline.lineWidth = 1.5
            outline.stroke()
            let bar = NSBezierPath(roundedRect: NSRect(x: frame.maxX - 5.5, y: frame.minY, width: 5.5, height: frame.height),
                                   xRadius: 2.5, yRadius: 2.5)
            bar.fill()
            NSRect(x: frame.maxX - 5.5, y: frame.minY, width: 2.5, height: frame.height).fill()
        case .completion:
            // "abc", regular, about two thirds of the width.
            let text = NSAttributedString(string: "abc", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: NSColor.white])
            let size = text.size()
            text.draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2 - 0.5))
        case .indentation:
            // An arrow pointing right into a vertical bar.
            let p = NSBezierPath()
            p.move(to: NSPoint(x: r.minX + 5.5, y: r.midY))
            p.line(to: NSPoint(x: r.minX + 14.5, y: r.midY))
            p.move(to: NSPoint(x: r.minX + 11, y: r.midY - 3.5))
            p.line(to: NSPoint(x: r.minX + 14.5, y: r.midY))
            p.line(to: NSPoint(x: r.minX + 11, y: r.midY + 3.5))
            p.move(to: NSPoint(x: r.minX + 18, y: r.minY + 6.5))
            p.line(to: NSPoint(x: r.minX + 18, y: r.maxY - 6.5))
            p.lineWidth = 1.7
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        case .simulator:
            // A host with a link: two stacked bars, each with a light.
            for y in [r.minY + 6.5, r.minY + 13] {
                let bar = NSBezierPath(roundedRect: NSRect(x: r.minX + 5, y: y, width: 14, height: 4.5), xRadius: 1.5, yRadius: 1.5)
                bar.lineWidth = 1.3
                bar.stroke()
                NSBezierPath(ovalIn: NSRect(x: r.minX + 14.5, y: y + 1.25, width: 2, height: 2)).fill()
            }
        }
    }
}

/// A navigation row's disclosure chevron: pointing right, 5 × 9, ending 11
/// inside the card (the view is 6 wide: the chevron and a 1-point margin).
final class SettingsDisclosureView: NSView {
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: SettingsMetrics.disclosureSize.width + SettingsMetrics.disclosureInset - SettingsMetrics.controlInset,
               height: SettingsMetrics.disclosureSize.height)
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let s = SettingsMetrics.disclosureSize
        let r = NSRect(x: 0, y: (bounds.height - s.height) / 2, width: s.width, height: s.height)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX + 0.75, y: r.minY + 0.75))
        p.line(to: NSPoint(x: r.maxX - 0.75, y: r.midY))
        p.line(to: NSPoint(x: r.minX + 0.75, y: r.maxY - 0.75))
        p.lineWidth = 1.5
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        SettingsColors.disclosure.setStroke()
        p.stroke()
    }
}

/// Draws the card switch (R4.1): a 36 × 16 track, off #3B3B3B (dark) or
/// #DDDDDD (light), on the accent, with a white pill knob about 21 × 12 at
/// the leading (off) or trailing (on) end.
@MainActor
enum SettingsSwitchDrawing {
    static func draw(on: Bool, enabled: Bool, in bounds: NSRect) {
        let size = SettingsMetrics.switchSize
        let track = NSRect(x: bounds.maxX - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
        let alpha: CGFloat = enabled ? 1 : 0.45
        (on ? SettingsColors.switchOn : SettingsColors.switchOff).withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: track, xRadius: size.height / 2, yRadius: size.height / 2).fill()
        let k = SettingsMetrics.switchKnobSize
        let inset = (size.height - k.height) / 2
        let knob = NSRect(x: on ? track.maxX - inset - k.width : track.minX + inset, y: track.midY - k.height / 2, width: k.width, height: k.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 1
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.withAlphaComponent(enabled ? 1 : 0.8).setFill()
        NSBezierPath(roundedRect: knob, xRadius: k.height / 2, yRadius: k.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
