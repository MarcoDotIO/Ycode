import Foundation

// Glass materials and scroll edges (issue #58; `specs/ui/glass-materials.md`).
// Part A is the reference's surfaces and what happens where scrolling
// content meets a bar: **no progressive scroll-edge effect** in the
// workspace, a fixed 2-pt divider under the jump bar, the text clipped at
// it, and a sticky first line of the enclosing declaration. Part B is
// Ycode's rule for glass surfaces the reference does not have. Both IDEs
// read these values.

public enum GlassMaterials {
    // MARK: Scroll edges (§3)

    /// The workspace draws no gradient, fade or blur ramp where content
    /// scrolls under the toolbar or the jump bar (§3.1). Settings-style
    /// windows are the only place for the system's soft edge (P-154).
    public static let workspaceHasProgressiveScrollEdge = false

    /// The jump bar's divider: 2 points under its band, the same at every
    /// scroll offset. Its two rows, top first.
    public static let jumpBarDividerHeight = 2.0
    public static func jumpBarDivider(dark: Bool) -> (top: StateColor, bottom: StateColor) {
        dark ? (StateColor(0x3D3D3C), StateColor(0x363636)) : (StateColor(0xE4E4E4), StateColor(0xE5E5E5))
    }

    /// The sticky first line of the enclosing declaration (§3.2): a band
    /// 20 points tall in the editor's background, opaque, with the line's
    /// number in the gutter, then a 2-point separator across the gutter and
    /// the text (not the minimap). The band starts on the divider's second
    /// row, so with the header shown only the divider's first row shows.
    public static let stickyBandHeight = 20.0
    public static let stickySeparatorHeight = 2.0
    public static func stickySeparator(dark: Bool) -> (top: StateColor, bottom: StateColor) {
        dark ? (StateColor(0x3C3A3C), StateColor(0x353636)) : (StateColor(0xE6E5E6), StateColor(0xE5E5E5))
    }

    /// How far the sticky band reaches up over the jump bar's divider.
    public static let stickyOverlapsDivider = 1.0

    /// Where the sticky band starts, below the jump bar band's bottom edge
    /// (`bandBottom`, the divider's top).
    public static func stickyBandTop(belowJumpBarBand bandBottom: Double) -> Double {
        bandBottom + jumpBarDividerHeight - stickyOverlapsDivider
    }

    /// The sticky line: the first lines of the declarations enclosing the
    /// first visible line (1-based), outermost first, at most one per
    /// `limit`. With the header shown, the line under it is the one that
    /// counts, so the header is found once more below its own height.
    public static func stickyLines(regions: [FoldRegion], firstVisibleLine: (_ belowPoints: Double) -> Int,
                                   lineHeight: Double, lineText: (Int) -> String) -> [Int] {
        let top = firstVisibleLine(0)
        var lines = EditorDisplayModel.structureHeaderLines(regions, topLine: top, lineText: lineText)
        guard !lines.isEmpty else { return [] }
        let covered = EditorMetrics.stickyHeaderHeight(rows: lines.count, lineHeight: lineHeight)
        lines = EditorDisplayModel.structureHeaderLines(regions, topLine: firstVisibleLine(covered), lineText: lineText)
        return lines
    }

    // MARK: Surfaces (§1)

    /// The toolbar band over the side areas and over the editor.
    public static func toolbarBand(dark: Bool, overEditor: Bool) -> StateColor {
        if dark { return StateColor(overEditor ? 0x262727 : 0x29292A) }
        return StateColor(overEditor ? 0xFFFFFF : 0xEDEDEE)
    }

    /// A toolbar glass item: fill, top rim and bottom rim (36 tall, fully
    /// rounded; a soft shadow ≈ 10 pt below in light).
    public static func toolbarItem(dark: Bool) -> (fill: StateColor, topRim: StateColor, bottomRim: StateColor) {
        dark ? (StateColor(0x444446), StateColor(0x696A6C), StateColor(0x747577))
            : (StateColor(0xF6F6F8), StateColor(0xFFFFFF), StateColor(0xD8D8D9))
    }

    /// The opaque side areas, flush with the window's edges.
    public static func navigatorArea(dark: Bool) -> StateColor { dark ? StateColor(0x29292A) : StateColor(0xEDEDEE) }
    public static func inspectorArea(dark: Bool) -> StateColor { dark ? StateColor(0x282829) : StateColor(0xEDEDEE) }

    /// The jump bar's band: the editor's colour.
    public static func jumpBarBand(dark: Bool) -> StateColor { dark ? StateColor(0x262627) : StateColor(0xFFFFFF) }

    /// Sheets: an opaque panel over a dimmed window (the toolbar too). The
    /// window behind darkens by about a third in dark, a sixth in light.
    public static func sheet(dark: Bool) -> (fill: StateColor, rim: StateColor, dimming: Double) {
        dark ? (StateColor(0x232122), StateColor(0x323131), 1.0 / 3) : (StateColor(0xFFFFFF), StateColor(0xE5E5E5), 1.0 / 6)
    }

    /// Corner radii (§2).
    public static let popoverRadius = 17.0
    public static let sheetRadius = 17.0
    public static let libraryRadius = 24.0
    /// The in-window palettes (Jump to Line, Quick Actions, Open Quickly):
    /// 55 tall, fully rounded.
    public static let paletteHeight = 55.0
    public static var paletteRadius: Double { paletteHeight / 2 }
    /// The glass bars over the side areas: 30 tall, 7 in from the edges.
    public static let floatingBarHeight = 30.0
    public static let floatingBarInset = 7.0

    /// Popovers and in-window panels leave the workspace active (traffic
    /// lights coloured, toolbar unchanged); a sheet dims and deactivates it
    /// (§4).
    public static func workspaceStaysActive(behind role: GlassRole) -> Bool { role != .decision }

    // MARK: Part B: Ycode-only glass (§6)

    /// The role of a surface the reference does not have.
    public enum GlassRole: String, CaseIterable, Sendable {
        /// A control in the toolbar.
        case toolbarControl
        /// A transient chooser anchored to a control.
        case chooser
        /// A transient command or search field over the editor.
        case commandField
        /// A task that needs a decision.
        case decision
        /// A list, inspector, editor or the debug area.
        case contentArea
        /// A bar floating over scrolling content in a Ycode-only area.
        case floatingBar
    }

    /// The material a Ycode-only surface of `role` uses.
    public enum Material: String, Sendable {
        /// A glass capsule or circle, 36 tall, grouped in one capsule.
        case toolbarGlass
        /// The system popover with an arrow to its control.
        case popover
        /// An in-window glass capsule like Jump to Line.
        case paletteGlass
        /// An opaque sheet centred in the dimmed window.
        case opaqueSheet
        /// No glass: opaque fills and flat controls.
        case opaque
        /// A glass capsule like the navigator selector, content blurred under it.
        case barGlass
    }

    public static func material(for role: GlassRole) -> Material {
        switch role {
        case .toolbarControl: return .toolbarGlass
        case .chooser: return .popover
        case .commandField: return .paletteGlass
        case .decision: return .opaqueSheet
        case .contentArea: return .opaque
        case .floatingBar: return .barGlass
        }
    }

    /// The corner radius of a surface of `material` that is `height` tall.
    public static func radius(_ material: Material, height: Double) -> Double {
        switch material {
        case .toolbarGlass, .paletteGlass, .barGlass: return height / 2
        case .popover: return popoverRadius
        case .opaqueSheet: return sheetRadius
        case .opaque: return 0
        }
    }

    /// With Reduce Transparency or Increase Contrast, glass becomes its
    /// opaque fill and rims become 1-point outlines (§6 item 3).
    public static func usesGlass(reduceTransparency: Bool, increaseContrast: Bool) -> Bool {
        !(reduceTransparency || increaseContrast)
    }
}
