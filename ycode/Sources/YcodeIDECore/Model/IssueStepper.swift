import Foundation

/// The issue stepper at the right end of every editor's jump bar
/// (`specs/ide/editor-area.md` G.8, E.2; `fidelity-council.md` row 139),
/// shared by the macOS and Linux IDEs: a back chevron, the symbol of the
/// workspace's most severe issue kind, a forward chevron. It shows whenever
/// the workspace has errors or warnings, in every pane (an image's too),
/// whatever file the pane shows; the chevrons step through the issues.
///
/// Its counts are the toolbar issue capsule's (row 138):
/// `IssueNavigatorModel.capsuleCounts(fresh:)`, so the two never disagree.
public enum IssueStepper {
    public enum Kind: Equatable, Sendable {
        case error, warning

        /// The kind's symbol: a red circle with a white cross, a yellow
        /// triangle with a white mark (G.8).
        public var symbol: String {
            switch self {
            case .error: "xmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            }
        }
    }

    /// The kind the stepper shows for the capsule's counts; nil hides it.
    public static func kind(errors: Int, warnings: Int) -> Kind? {
        errors > 0 ? .error : (warnings > 0 ? .warning : nil)
    }

    // MARK: Colours (H.5, council row 161)

    /// The chevrons' colour (0xRRGGBB): #7F7F7F in light (H.5), #9D9D9D
    /// in dark (G.8).
    public static func chevronColor(dark: Bool) -> UInt32 { dark ? 0x9D9D9D : 0x7F7F7F }

    /// The kind's symbol fill (its mark white): the warning triangle
    /// #FFCB00 in light (H.5), #FFE015 in dark; the error circle the
    /// system red.
    public static func symbolFill(_ kind: Kind, dark: Bool) -> UInt32 {
        switch kind {
        case .error: 0xFF3B30
        case .warning: dark ? 0xFFE015 : 0xFFCB00
        }
    }

    // MARK: Geometry (G.8: x 1084.5–1124.5 in a 1400-point window)

    /// The stepper's right end inside the jump bar's right edge.
    public static let trailingInset = 14.5
    /// The chevrons' glyph box (`chevronColor`).
    public static let chevronWidth = 6.5
    public static let chevronHeight = 11.5
    /// The kind's symbol.
    public static let symbolWidth = 11.0
    public static let symbolHeight = 10.5
    /// Between the three parts.
    public static var spacing: Double { (width - 2 * chevronWidth - symbolWidth) / 2 }
    /// The whole stepper.
    public static let width = 40.0
}
