import AppKit
import YcodeIDECore

/// The jump bar's leading items (council round 10, row 247;
/// `JumpBarLeading`): Ycode's Related Items grid, 13 × 13 at 13 in from
/// the bar's leading edge, four 6 × 6 squares of 1-point strokes on whole
/// pixels; with a file open a 1 × 12 divider at 35 (#E6E6E6 / #3C3C3C),
/// and the path's first ink at 49. The Linux jump bar (`ycode-ide`
/// `EditorArea.swift`) lays out the same items.
extension JumpBar {
    /// The divider between the grid and the path, and the room around it.
    func addPathDivider() {
        guard let grid = stack.arrangedSubviews.last else { return }
        typealias L = JumpBarLeading
        let gridEnd = L.gridX + L.gridSide
        stack.setCustomSpacing(CGFloat(L.dividerX - gridEnd), after: grid)
        let d = JumpBarDividerView()
        stack.addArrangedSubview(d)
        // The first icon adds its lead-in (JumpBar+Path.swift).
        stack.setCustomSpacing(CGFloat(L.pathX - L.dividerX - L.dividerWidth) - Self.firstIconLeadIn, after: d)
    }

    /// The path divider (tests).
    var pathDivider: JumpBarDividerView? { stack.arrangedSubviews.lazy.compactMap { $0 as? JumpBarDividerView }.first }
}

/// The Related Items button: Ycode's grid in the reference's grey
/// (#9A9A9A / #858585), its frame the grid's 13 × 13.
final class JumpBarGridButton: NSButton {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: JumpBarLeading.gridSide, height: JumpBarLeading.gridSide))
        identifier = NSUserInterfaceItemIdentifier("square.grid.2x2")
        isBordered = false
        title = ""
        toolTip = "Navigate to Related Items"
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CGFloat(JumpBarLeading.gridSide)),
            heightAnchor.constraint(equalToConstant: CGFloat(JumpBarLeading.gridSide)),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: JumpBarLeading.gridSide, height: JumpBarLeading.gridSide) }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        let v = JumpBarLeading.gridColor(dark: isDark)
        let color = NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        let side = CGFloat(JumpBarLeading.gridSide)
        let r = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        GlyphPixelGrid.draw(JumpBarLeading.grid, in: r, color: isHighlighted ? color.blended(withFraction: 0.3, of: .labelColor) ?? color : color,
                            flipped: isFlipped)
    }
}

/// The 1 × 12 divider after the grid (#E6E6E6 / #3C3C3C).
final class JumpBarDividerView: NSView {
    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: JumpBarLeading.dividerWidth, height: JumpBarLeading.dividerHeight))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: CGFloat(JumpBarLeading.dividerWidth)),
            heightAnchor.constraint(equalToConstant: CGFloat(JumpBarLeading.dividerHeight)),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: JumpBarLeading.dividerWidth, height: JumpBarLeading.dividerHeight) }
    override var allowsVibrancy: Bool { false }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    override func draw(_ dirtyRect: NSRect) {
        let v = JumpBarLeading.dividerColor(dark: isDark)
        NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1).setFill()
        bounds.fill()
    }
}
