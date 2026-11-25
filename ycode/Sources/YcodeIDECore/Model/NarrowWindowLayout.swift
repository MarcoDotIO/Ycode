import Foundation

/// The workspace window when it is narrow (`specs/ide/parity-inventory.md`
/// P-024, `specs/ide/window-layout.md` §1, §4.1 and §4.2; council round 12).
/// The editor never goes below 300 points. Above the point where it reaches
/// 300 only the editor narrows: the navigator keeps 290 and the inspector
/// 260. On a live drag, when the editor would go below 300, the navigator
/// **collapses** (it slides out; it never shrinks first), and stays hidden
/// when the window widens again; then a shown inspector narrows toward
/// 201.5. The window's minimum width is the larger of the content floor
/// (the editor's 300, plus a shown inspector's 201.5 and its 1-point
/// divider: ≈ 503) and the toolbar's floor (≈ 410: the items that never
/// move into "»", and "»" itself). A frame set below the content's width
/// without a live resize may clip instead (§4 rule 3), but never squeezes
/// the editor. Both IDEs lay out their panes with this.
public enum NarrowWindowLayout {
    /// The editor never gets narrower than this.
    public static let editorMinimum = 300.0
    /// The inspector's narrowest (at the minimum width, §4.1).
    public static let inspectorMinimum = 201.5
    /// The toolbar's floor: room for the traffic lights, the Navigators /
    /// Coding Assistant group, Run | Stop, "»" and the inspector toggle
    /// (§4.1: measured 408 and 417 for the same items; the spec says use
    /// 410, the 9-point difference is OPEN).
    public static let toolbarFloor = 410.0
    /// The divider beside the inspector.
    public static let divider = 1.0
    /// The narrowest window that shows the three areas at their own widths
    /// (290 + 300 + 260): above it only the editor narrows.
    public static let contentMinimum = 850.0

    /// The content floor: the editor's 300, plus a shown inspector at its
    /// narrowest with its divider. The navigator never adds to it: it
    /// collapses instead of going below its width.
    public static func contentFloor(inspectorShown: Bool) -> Double {
        editorMinimum + (inspectorShown ? inspectorMinimum + divider : 0)
    }

    /// The window's minimum width (§4.1's rule): ≈ 503 points with the
    /// inspector shown, 410 with it hidden.
    public static func minimumWindowWidth(inspectorShown: Bool) -> Double {
        max(contentFloor(inspectorShown: inspectorShown).rounded(.up), toolbarFloor)
    }

    /// The minimum with the inspector shown (the larger of the two).
    public static var minimumWindowWidth: Double { minimumWindowWidth(inspectorShown: true) }

    /// The panes' widths in a window `width` points wide.
    public struct Panes: Sendable, Equatable {
        public var navigator: Double?
        public var editor: Double
        public var inspector: Double?
    }

    /// The panes for a window `width` wide after a live drag to it, from the
    /// widths the panes ask for (nil: hidden) and the dividers' width. The
    /// editor takes what is left down to `editorMinimum`; below that the
    /// navigator collapses (it does not shrink), then the inspector gives up
    /// room down to `inspectorMinimum`.
    public static func panes(width: Double, navigator: Double?, inspector: Double?, divider: Double = 1) -> Panes {
        let width = max(width, minimumWindowWidth(inspectorShown: inspector != nil))
        var nav = navigator, insp = inspector
        func dividers() -> Double { Double((nav == nil ? 0 : 1) + (insp == nil ? 0 : 1)) * divider }
        func editor() -> Double { width - (nav ?? 0) - (insp ?? 0) - dividers() }
        if editor() < editorMinimum - 1e-9, nav != nil { nav = nil }
        if editor() < editorMinimum, let i = insp {
            insp = max(inspectorMinimum, i - (editorMinimum - editor()))
        }
        return Panes(navigator: nav, editor: editor(), inspector: insp)
    }

    /// Whether a live resize to `width` collapses a shown navigator
    /// `navigator` wide beside an inspector `inspector` wide (nil: hidden):
    /// the editor would go below 300 (W ≈ 590 with the inspector hidden,
    /// ≈ 851 with it shown at 260).
    public static func liveResizeHidesNavigator(width: Double, navigator: Double = 290, inspector: Double?, divider: Double = 1) -> Bool {
        width - navigator - (inspector ?? 0) - Double(1 + (inspector == nil ? 0 : 1)) * divider < editorMinimum - 1e-9
    }

    /// The window width at which a live drag collapses the navigator.
    public static func navigatorCollapseWidth(navigator: Double = 290, inspector: Double?, divider: Double = 1) -> Double {
        editorMinimum + navigator + (inspector ?? 0) + Double(1 + (inspector == nil ? 0 : 1)) * divider
    }
}
