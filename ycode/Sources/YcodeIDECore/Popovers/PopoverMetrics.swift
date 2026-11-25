import Foundation

// One component model for the transient surfaces of both IDEs
// (`specs/ide/popovers.md` §11): the anchored popover (the scheme and
// destination choosers, Quick Help), the in-window panel (Jump to Line,
// Quick Actions, Open Quickly, Quick New Project) and the sheet (New
// Scheme). The AppKit IDE (`YcodeUI`) and the Linux IDE (`ycode-ide`) lay
// each one out from these numbers, so both draw it the same. Points, y
// growing downward from the window's top left, as the spec measures.

/// The side of its anchor a popover opens on.
public enum PopoverEdge: Sendable, Equatable {
    /// Under the anchor, the arrow pointing up (toolbar choosers).
    case below
    /// Over the anchor, the arrow pointing down (Quick Help).
    case above
}

/// An anchored popover's shape and its chooser rows (§2.2, §11.1).
public enum PopoverMetrics {
    /// The arrow: 26 wide at its base, 11 tall.
    public static let arrowWidth = 26.0
    public static let arrowHeight = 11.0
    /// The body's corners.
    public static let cornerRadius = 17.0
    /// The popover window's room around the body (frame 241 wide for a
    /// 213-wide body): the shadow's, and the arrow's on its side.
    public static let frameMargin = 14.0
    /// A text anchor leaves this much between the arrow's tip and the
    /// line (Quick Help, §4 item 1); a control anchor none.
    public static let textAnchorGap = 3.0

    /// Body widths: the scheme chooser's and the destination chooser's.
    public static let schemeBodyWidth = 213.0
    public static let destinationBodyWidth = 415.0
    /// Quick Help's body: 417 for every popover (§4.2).
    public static let quickHelpBodyWidth = QuickHelpPopoverMetrics.width

    /// The Filter field: 30 tall, 7 inside the body's top and sides.
    public static let filterHeight = 30.0
    public static let filterInset = 7.0
    /// From the field to the first row, and after the last row.
    public static let filterGap = 6.0
    public static let bottomPadding = 12.0
    public static let filterPlaceholder = "Filter"

    /// Rows and headings 24 tall; a separator row 12 with its hairline
    /// inset 24 at each side.
    public static let rowHeight = 24.0
    public static let separatorHeight = 12.0
    public static let separatorInset = 24.0
    /// The highlight: an accent rounded rectangle 12 inside the body's
    /// sides, radius 8.
    public static let highlightInset = 12.0
    public static let highlightRadius = 8.0
    /// Columns from the body's left: the checkmark, the row's glyph (16
    /// square) and the title; commands start at the title column. The OS
    /// version ends this far inside the body's right edge.
    public static let checkX = 18.0
    public static let glyphX = 32.0
    public static let glyphSide = 16.0
    public static let titleX = 54.0
    public static let trailingInset = 22.0
    public static let titleFontSize = 13.0
    public static let headingFontSize = 11.0

    /// The body's height around `rowsHeight` points of rows.
    public static func bodyHeight(rowsHeight: Double) -> Double {
        filterInset + filterHeight + filterGap + rowsHeight + bottomPadding
    }

    /// The first row's top in the body.
    public static var rowsTop: Double { filterInset + filterHeight + filterGap }
}

/// Where an anchored popover goes (§11.1): centred on its anchor, on the
/// preferred edge, never flipped; shifted along the edge only to stay
/// inside `bounds` (the screen), the arrow staying on the anchor.
public struct PopoverPlacement: Equatable, Sendable {
    /// The body (the drawn shape without its arrow), in the anchor's
    /// coordinates.
    public var body: CGRect
    /// The arrow's tip from the body's left edge.
    public var arrowTipX: Double
    /// The arrow's tip, in the anchor's coordinates.
    public var arrowTip: CGPoint
    public var edge: PopoverEdge

    /// The popover's frame: the body with its margin and the arrow.
    public var frame: CGRect { body.insetBy(dx: -PopoverMetrics.frameMargin, dy: -PopoverMetrics.frameMargin) }

    public static func place(anchor: CGRect, bodySize: CGSize, edge: PopoverEdge, gap: Double = 0, bounds: CGRect? = nil) -> PopoverPlacement {
        let m = PopoverMetrics.self
        var x = anchor.midX - bodySize.width / 2
        if let b = bounds {
            x = min(max(x, b.minX), b.maxX - bodySize.width)
        }
        x = x.rounded()
        let tipY = edge == .below ? anchor.maxY + gap : anchor.minY - gap
        let y = edge == .below ? tipY + m.arrowHeight : tipY - m.arrowHeight - bodySize.height
        let limit = m.cornerRadius + m.arrowWidth / 2
        let tipX = min(max(anchor.midX - x, limit), max(limit, bodySize.width - limit))
        return PopoverPlacement(body: CGRect(x: x, y: y, width: bodySize.width, height: bodySize.height), arrowTipX: tipX,
                                arrowTip: CGPoint(x: x + tipX, y: tipY), edge: edge)
    }
}

/// The in-window panels of §5 and §10: glass capsules centred on the
/// window, under the toolbar, a borderless field after a magnifier.
public struct InWindowPanel: Equatable, Sendable {
    public var width: Double
    /// The capsule's height before results; a panel listing results
    /// grows downward from it.
    public var height: Double
    /// From the toolbar's bottom edge to the panel's top.
    public var topBelowToolbar: Double
    public var fieldWidth: Double
    public var placeholder: String

    public static let jumpToLine = InWindowPanel(width: 640, height: 55, topBelowToolbar: 17, fieldWidth: 560, placeholder: "Line Number")
    public static let quickActions = InWindowPanel(width: 560, height: 55, topBelowToolbar: 3, fieldWidth: 480, placeholder: "Quick Actions")
    public static let openQuickly = InWindowPanel(width: 640, height: 55, topBelowToolbar: 18, fieldWidth: 560, placeholder: "Open Quickly")
    /// P-180 (the inventory row; not observed in the 2026-11-20 capture):
    /// 640 × 355 with its rows, placed as Jump to Line.
    public static let quickNewProject = InWindowPanel(width: 640, height: 55, topBelowToolbar: 17, fieldWidth: 560, placeholder: "New Project")

    /// The toolbar's bottom edge in the window (52-point band).
    public static let toolbarBottom = 52.0
    /// The field: 36 tall, 61 from the panel's left, 10 down.
    public static let fieldX = 61.0
    public static let fieldY = 10.0
    public static let fieldHeight = 36.0
    /// The magnifier, centred in the 55-point band before the field.
    public static let magnifierSize = 18.0
    public static let magnifierX = 26.0
    public static let fieldFontSize = 22.0
    /// Result rows under the field (Ycode's: the reference's were not
    /// measured), at most `maximumVisibleRows` before the list scrolls.
    public static let resultRowHeight = 32.0
    public static let maximumVisibleRows = 10
    public static let resultInset = 10.0

    /// Fully rounded: half the capsule's height.
    public var cornerRadius: Double { height / 2 }

    /// The panel's frame in a window `windowWidth` wide, `extraHeight`
    /// taller with results.
    public func frame(windowWidth: Double, toolbarBottom: Double = InWindowPanel.toolbarBottom, extraHeight: Double = 0) -> CGRect {
        CGRect(x: ((windowWidth - width) / 2).rounded(), y: toolbarBottom + topBelowToolbar, width: width, height: height + extraHeight)
    }

    /// The field's frame in the panel.
    public var fieldFrame: CGRect { CGRect(x: Self.fieldX, y: Self.fieldY, width: fieldWidth, height: Self.fieldHeight) }

    /// The height results add under the capsule.
    public static func resultsHeight(count: Int) -> Double {
        count == 0 ? 0 : Double(min(count, maximumVisibleRows)) * resultRowHeight + resultInset
    }
}

/// The New Scheme sheet (§3): 493 × 122, a Target pop-up and a Name field
/// with right-aligned labels, Cancel and OK at the bottom right.
public enum NewSchemeSheetMetrics {
    public static let width = 493.0
    public static let height = 122.0
    /// Labels end this far from the sheet's left edge; controls start 5 after.
    public static let labelRight = 55.0
    public static let controlX = 60.0
    public static let popUpWidth = 408.0
    public static let fieldWidth = 416.0
    public static let fieldHeight = 21.0
    public static let targetRowY = 20.0
    public static let nameRowY = 52.0
    public static let buttonWidth = 84.0
    public static let buttonHeight = 23.0
    public static let buttonGap = 12.0
    public static let buttonRight = 20.0
    public static let buttonBottom = 17.0

    /// OK's frame (the default button, rightmost), then Cancel's, from the
    /// sheet's top left.
    public static var okFrame: CGRect {
        CGRect(x: width - buttonRight - buttonWidth, y: height - buttonBottom - buttonHeight, width: buttonWidth, height: buttonHeight)
    }
    public static var cancelFrame: CGRect { okFrame.offsetBy(dx: -(buttonWidth + buttonGap), dy: 0) }
}

/// The materials' colours where a toolkit draws them itself (the Linux
/// IDE; on macOS the system's popover and glass views draw them), sRGB,
/// from `specs/ui/glass-materials.md` §1.
public enum PopoverMaterial {
    /// The chooser popovers' body (dark #3F3F40–#48484B, light #FCFBFE).
    public static func chooserBody(dark: Bool) -> UInt32 { dark ? 0x444446 : 0xFCFBFE }
    /// Quick Help's body. Dark ≈ #414141. Light: the reference's mid grey
    /// (#8F8F8F–#929292) is OPEN (`glass-materials.md` §7 item 2: confirm
    /// at 2x first), so Ycode uses the chooser's near-white until then.
    public static func quickHelpBody(dark: Bool) -> UInt32 { dark ? 0x414141 : 0xFCFBFE }
    /// Quick Help's declaration box: darker than the body in dark, white in light.
    public static func quickHelpDeclaration(dark: Bool) -> UInt32 { dark ? 0x333334 : 0xFFFFFF }
    /// A popover's 1-point edge.
    public static func popoverEdge(dark: Bool) -> UInt32 { dark ? 0x5C5C5E : 0xD8D8D9 }
    /// The in-window capsules (dark #3F3D3D with a #6F6E6E rim, light #FDFDFD).
    public static func capsuleFill(dark: Bool) -> UInt32 { dark ? 0x3F3D3D : 0xFDFDFD }
    public static func capsuleRim(dark: Bool) -> UInt32 { dark ? 0x6F6E6E : 0xE5E5E5 }
    /// Sheets: opaque, a lighter top rim; the window behind darkens by a
    /// third (dark) or a sixth (light).
    public static func sheetFill(dark: Bool) -> UInt32 { dark ? 0x232122 : 0xFFFFFF }
    public static func sheetRim(dark: Bool) -> UInt32 { dark ? 0x323131 : 0xE5E5E5 }
    public static func sheetDim(dark: Bool) -> Double { dark ? 1.0 / 3 : 1.0 / 6 }
    /// A capsule half held while its popover is open (§2.1).
    public static func pressedHalf(dark: Bool) -> UInt32 { dark ? 0x505050 : 0xDFDFDF }
    /// The highlight (the system accent blue).
    public static func highlight(dark: Bool) -> UInt32 { dark ? 0x0059D1 : 0x0064E1 }
}
