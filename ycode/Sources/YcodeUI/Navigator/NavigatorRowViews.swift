import AppKit
import YcodeIDECore

/// The navigator's rows (`metrics.md` §12.1, §13.1; `navigators.md` "Council
/// round 2" §3, §4; `fidelity-council.md` rows 12, 38, 39, 47).
///
/// - The selection band is 22 tall, inset 10 on both sides, corners 8: the
///   accent colour (#0070F5) with a white label and icon while the outline
///   has focus in the key window; otherwise a quiet grey (#E7E7E8 on the
///   inactive #F2F2F3), never nothing.
/// - Labels are regular weight in #3B3B3C.
/// - Every row is an accessibility row titled with its name.
final class NavigatorRowView: NSTableRowView {
    static let bandHeight: CGFloat = 22
    static let bandInset: CGFloat = 10
    static let bandRadius: CGFloat = 8

    /// The grey band when the outline is not focused (black at 4.5 % on
    /// the light side area, white at 10 % on the dark one).
    static var unfocusedBand: NSColor {
        NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.045)
        }
    }

    /// The band's rectangle in the row.
    static func bandRect(in bounds: NSRect) -> NSRect {
        let h = min(bandHeight, bounds.height)
        return NSRect(x: bounds.minX + bandInset, y: bounds.midY - h / 2, width: max(0, bounds.width - 2 * bandInset), height: h)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none, isSelected else { return }
        (isEmphasized ? NSColor.controlAccentColor : Self.unfocusedBand).setFill()
        NSBezierPath(roundedRect: Self.bandRect(in: bounds), xRadius: Self.bandRadius, yRadius: Self.bandRadius).fill()
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected && isEmphasized ? .emphasized : .normal
    }
}

/// A row's cell: the label and icon turn white on the accent band.
final class NavigatorCellView: NSTableCellView {
    /// The label's colour on no band or the grey band.
    var labelColor: NSColor = NavigatorCellView.rowLabelColor
    /// The icon's tint on no band or the grey band.
    var iconTint: NSColor?
    /// Plain labels follow the band; attributed ones (details, Find
    /// matches) keep their own colours.
    var recolorsLabel = true
    /// #3B3B3C in light, the system label colour in dark.
    static var rowLabelColor: NSColor {
        NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .labelColor
                : NSColor(srgbRed: 0x3B / 255.0, green: 0x3B / 255.0, blue: 0x3C / 255.0, alpha: 1)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyStyle() }
    }

    func applyStyle() {
        let on = backgroundStyle == .emphasized
        if recolorsLabel, let label = textField {
            let color = on ? NSColor.alternateSelectedControlTextColor : labelColor
            if label.textColor != color { label.textColor = color }
        }
        imageView?.contentTintColor = on ? .alternateSelectedControlTextColor : iconTint
    }
}

/// A row's label. A source-list outline restyles its rows' titles as
/// they are drawn (`NSTableCellView`'s source-list attributes replace the
/// cell's value with the plain title in the row's font), which flattened a
/// styled title, a Find match with its replacement struck out, to plain
/// text on screen. A styled title is kept.
final class NavigatorRowLabel: NSTextField {
    override class var cellClass: AnyClass? {
        get { StyledTitleCell.self }
        set {}
    }

    /// The styled title to keep (nil: the outline styles the title).
    var styledTitle: NSAttributedString? {
        get { (cell as? StyledTitleCell)?.styledTitle }
        set { (cell as? StyledTitleCell)?.styledTitle = newValue }
    }

    final class StyledTitleCell: NSTextFieldCell {
        var styledTitle: NSAttributedString?
        override var objectValue: Any? {
            get { super.objectValue }
            set { super.objectValue = styledTitle ?? newValue }
        }
    }
}
