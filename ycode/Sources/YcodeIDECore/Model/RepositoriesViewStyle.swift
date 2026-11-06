import Foundation

/// The Source Control navigator's Repositories view as both IDEs draw it
/// (`specs/ide/navigators.md` round 3 §2, checklist row 82): a grey filled
/// symbol for the repository and for each group, only Branches expanded at
/// first, no "(current)" after the current branch (the repository row
/// names it), a full-width Changes | Repositories control 9 from each side.
public enum RepositoriesViewStyle {
    /// Each group's symbol, near the reference's (a stacked drive, a clock,
    /// a tag, a tray, a globe) among the names both IDEs draw (the Linux
    /// IDE's symbol artwork has these).
    public static let groupSymbols = ["Branches": "square.stack.3d.up.fill", "Recents": "clock", "Tags": "tag.fill",
                                      "Stashes": "tray", "Remotes": "globe"]
    /// The repository row's symbol: a filled drive.
    public static let repositorySymbol = "externaldrive.fill"
    /// The groups collapsed at first (row ids "group:<title>").
    public static let initiallyCollapsed: Set<String> = ["group:Recents", "group:Tags", "group:Stashes", "group:Remotes"]
    /// The mode control's inset from each side of the navigator, and its height.
    public static let modeControlInset = 9.0
    public static let modeControlHeight = 16.0
}
