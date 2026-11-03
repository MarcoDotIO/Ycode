import Foundation

/// How the toolbar recovers room (`reference-ui-6.md` §2.2): each step
/// adds to the previous one.
public struct ToolbarFit: Equatable, Sendable {
    /// The editor-mode capsule is one pull-down.
    public var editorModesCollapsed = false
    /// The scheme pop-up's width cap (nil: its whole name).
    public var schemeWidth: CGFloat?
    /// The activity view's width cap (nil: its whole subtitle).
    public var activityWidth: CGFloat?
    public init(editorModesCollapsed: Bool = false, schemeWidth: CGFloat? = nil, activityWidth: CGFloat? = nil) {
        self.editorModesCollapsed = editorModesCollapsed
        self.schemeWidth = schemeWidth
        self.activityWidth = activityWidth
    }

    /// The narrowest the scheme pop-up and the activity view get.
    public static let schemeMinimum: CGFloat = 56
    public static let activityMinimum: CGFloat = 72

    /// The steps in order, from nothing collapsed to the tightest: fold the
    /// editor modes; then shorten the scheme name in steps down to
    /// `schemeMinimum`; then the activity view down to `activityMinimum`.
    public static func steps(schemeNatural: CGFloat, activityNatural: CGFloat) -> [ToolbarFit] {
        var out = [ToolbarFit(), ToolbarFit(editorModesCollapsed: true)]
        func shrink(_ natural: CGFloat, _ minimum: CGFloat) -> [CGFloat] {
            var widths: [CGFloat] = []
            var w = natural
            while w > minimum {
                w = max(minimum, (w - max(24, natural * 0.15)).rounded(.down))
                widths.append(w)
            }
            return widths
        }
        let scheme = shrink(schemeNatural, schemeMinimum)
        for w in scheme { out.append(ToolbarFit(editorModesCollapsed: true, schemeWidth: w)) }
        let schemeLast = scheme.last
        for w in shrink(activityNatural, activityMinimum) {
            out.append(ToolbarFit(editorModesCollapsed: true, schemeWidth: schemeLast, activityWidth: w))
        }
        return out
    }
}
