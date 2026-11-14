import Foundation

/// The Welcome window's recent row (`workspace-window.md` W7.6, council
/// row 194), shared by both IDEs: the title and the path at the
/// reference's sizes and place, so a path like
/// "/private/tmp/ycode-council-r7/council-r7/xcode/project" fits whole;
/// a longer one is cut in the middle (the platform's convention for
/// paths), keeping its leading folders and the project's folder. The
/// row's icon is Ycode's own (its mark for projects and workspaces, the
/// package glyph for packages), never the system's document icon.
public enum WelcomeRecentRow {
    /// The title: semibold, 5 % smaller than before (ink 66 wide for "GlassScroll").
    public static let titleSize = 12.4
    /// The path: about 4.9 points per character.
    public static let pathSize = 10.0
    /// The text's ink starts 48.5 from the selection's left (6 left of before).
    public static let textShift = -6.0
    /// The title's ink 2 lower, the path's 3.5 lower than before.
    public static let titleDrop = 2.0, pathDrop = 3.5
    /// Room kept at the row's right.
    public static let trailingInset = 24.0
    /// The path on the selection (#B3CEF1); elsewhere the secondary label colour.
    public static let selectedPathColor: UInt32 = 0xB3CEF1
}
