import Foundation

/// How the toolbar recovers room (`liquid-glass.md` §8.2, which supersedes
/// `reference-ui-6.md` §2.2's no-overflow rule): each step adds to the
/// previous one.
///
/// 1. The scheme capsule drops its titles: the scheme's and the
///    destination's glyphs with the "›" between them (about 87 wide),
///    before anything truncates.
/// 2. The editor-mode group may stay in the toolbar's "»" overflow (the
///    system's overflow control, at the end of the editor's section; the
///    group has the lowest visibility priority, so it is the first item
///    the system moves there).
/// 3. The activity subtitle truncates in the middle, in steps, down to
///    `activityMinimum`.
///
/// The round 2 capture is a one-step resize, so the order between the
/// steps is Ycode's reading (in the reference all three had happened at
/// 1100 points). Past the last step the remaining items overflow by
/// visibility priority.
public struct ToolbarFit: Equatable, Sendable {
    /// The editor-mode group may sit in the overflow menu.
    public var editorModesInOverflow = false
    /// The scheme capsule shows glyphs only.
    public var schemeGlyphsOnly = false
    /// The activity view's width cap (nil: its whole subtitle).
    public var activityWidth: CGFloat?
    public init(editorModesInOverflow: Bool = false, schemeGlyphsOnly: Bool = false, activityWidth: CGFloat? = nil) {
        self.editorModesInOverflow = editorModesInOverflow
        self.schemeGlyphsOnly = schemeGlyphsOnly
        self.activityWidth = activityWidth
    }

    /// The editor-mode group's toolbar identifier.
    public static let editorModesItem = "editorModes"

    /// The items this step lets the overflow menu hold.
    public var overflowAllowance: Set<String> { editorModesInOverflow ? [Self.editorModesItem] : [] }

    /// Whether `overflowed` (the identifiers in the overflow menu) is a
    /// fit for this step.
    public func accepts(overflowed: [String]) -> Bool { Set(overflowed).isSubset(of: overflowAllowance) }

    /// The narrowest the activity view gets.
    public static let activityMinimum: CGFloat = 72

    /// The steps in order, from nothing given up to the tightest.
    public static func steps(activityNatural: CGFloat) -> [ToolbarFit] {
        var out = [ToolbarFit(), ToolbarFit(schemeGlyphsOnly: true), ToolbarFit(editorModesInOverflow: true, schemeGlyphsOnly: true)]
        var w = activityNatural
        while w > activityMinimum {
            w = max(activityMinimum, (w - max(24, activityNatural * 0.15)).rounded(.down))
            out.append(ToolbarFit(editorModesInOverflow: true, schemeGlyphsOnly: true, activityWidth: w))
        }
        return out
    }
}
