import Foundation

// The Settings window's measured geometry (`specs/ide/settings.md`,
// "Council round 3", R3.1–R3.3, and round 4, R4.1–R4.3), shared by the
// macOS IDE (`SettingsMetrics` in YcodeUI) and the Linux IDE's Settings
// window.

/// The measured geometry (points; window coordinates from the top-left).
public enum SettingsLayout {
    /// The window (R3.1).
    public static let windowSize = CGSize(width: 710, height: 452)
    /// The title area: the window buttons' band.
    public static let titleAreaHeight: CGFloat = 52
    /// The back/forward capsule: x 187.5–261, y 8.5–43.
    public static let capsuleFrame = CGRect(x: 187.5, y: 8.5, width: 73.5, height: 34.5)
    /// The title's ink starts 12.5 after the capsule, centred on y 26.
    public static let titleX: CGFloat = 273.5
    public static let titleCenterY: CGFloat = 26
    public static let titleFontSize: CGFloat = 17
    /// The title is semibold (R4.2: the stem 2.3 points at 17).
    public static let titleIsSemibold = true

    /// The sidebar (R3.2): 179.5 wide, then a 0.5-point divider.
    public static let sidebarWidth: CGFloat = 179.5
    public static let dividerWidth: CGFloat = 0.5
    public static var detailX: CGFloat { sidebarWidth + dividerWidth }
    public static let sidebarRowHeight: CGFloat = 32
    /// The first row's band starts under the title area.
    public static let sidebarTop: CGFloat = 52
    public static let selectionInset: CGFloat = 10
    /// The selection band is 160 wide (x 10–170; R4.2).
    public static let selectionWidth: CGFloat = 160
    public static let selectionRadius: CGFloat = 7
    public static let symbolCenterX: CGFloat = 29
    public static let symbolPointSize: CGFloat = 14
    /// Where every row's label ink starts.
    public static let sidebarLabelX: CGFloat = 47
    /// At most 12 rows fit the window with no scroller (R4.2): the last
    /// ends at y 436, 16 above the window's bottom.
    public static let sidebarMaxRows = 12

    /// The detail pane's cards (R3.3): 20 from the divider and the right edge.
    public static let cardInset: CGFloat = 20
    public static var cardWidth: CGFloat { windowSize.width - detailX - 2 * cardInset }
    public static let cardRadius: CGFloat = 12
    /// A one-line row, and the separator between rows (inset 10 each side).
    public static let rowHeight: CGFloat = 37.5
    public static let separatorHeight: CGFloat = 1
    public static let separatorInset: CGFloat = 10
    /// Labels' and headers' ink 10 inside the card (11 with the glyphs' bearing).
    public static let labelInset: CGFloat = 10
    /// Controls end 10 inside the card (the pop-up's circle 13.5).
    public static let controlInset: CGFloat = 10
    public static let popUpCircleInset: CGFloat = 13.5
    public static let popUpCircle: CGFloat = 20
    /// The value text ends 12.5 before the circle (R4.1, R4.2).
    public static let popUpTextGap: CGFloat = 12.5
    /// The switch (R4.1): a 36 × 16 track, 10 inside the card, with a
    /// pill knob about 21 × 12 at the leading (off) or trailing (on) end.
    public static let switchSize = CGSize(width: 36, height: 16)
    public static let switchKnobSize = CGSize(width: 21, height: 12)
    /// Help text: 11 points on a 14-point pitch, its first baseline 19 under
    /// the label's; it wraps 416 wide in a 490-point card.
    public static let helpFontSize: CGFloat = 11
    public static let helpLinePitch: CGFloat = 14
    public static let helpBaselineGap: CGFloat = 19
    public static var helpWidth: CGFloat { cardWidth - labelInset - 64 }
    /// A section header's cap top 22.5 above its card; a card's bottom 33
    /// above the next header's cap top; the first header's cap top 76 down
    /// the window (24 under the title area).
    public static let headerToCard: CGFloat = 22.5
    public static let cardToHeader: CGFloat = 33
    public static let firstHeaderCapTop: CGFloat = 76
    /// A pane that starts with a card (Editing) has it 20 under the title
    /// area (R4.1: card 1 at y 72).
    public static let firstCardTop: CGFloat = 72
    /// Two cards with no header between them are 10 apart (R4.1).
    public static let cardGap: CGFloat = 10
    public static let fontSize: CGFloat = 13

    /// A navigation row (Editing's Display, Completion, Indentation; R4.1):
    /// 44 tall, a 24 × 24 rounded-square icon 10 inside the card and
    /// centred in the row, the label's ink 45 inside the card (x 245),
    /// a disclosure chevron 5 × 9 ending 11 inside the card.
    public static let navigationRowHeight: CGFloat = 44
    public static let rowIconSize: CGFloat = 24
    public static let rowIconInset: CGFloat = 10
    /// A continuous corner: the fill reaches the edge 2–2.5 from the corner.
    public static let rowIconRadius: CGFloat = 5
    public static let navigationLabelInset: CGFloat = 45
    public static let disclosureSize = CGSize(width: 5, height: 9)
    public static let disclosureInset: CGFloat = 11
}

/// A navigation row's icon (R4.1): a vertical gradient, lighter at the
/// top, under a white symbol that Ycode draws (described in words in the
/// spec; no system artwork).
public enum SettingsRowIcon: String, CaseIterable, Sendable {
    /// Blue: a rounded-rectangle outline with a filled bar along its right
    /// side (a window with a side panel).
    case display
    /// Cyan: the lowercase letters "abc".
    case completion
    /// Periwinkle: an arrow pointing right into a vertical bar.
    case indentation
    /// Ycode's own (Components ▸ Ycode Simulator): green, a host with a
    /// link (two stacked bars with lights).
    case simulator

    /// The gradient's top and bottom colours (sRGB hex; the same in light
    /// and dark).
    public var gradient: (top: UInt32, bottom: UInt32) {
        switch self {
        case .display: (0x2BAFFF, 0x0091FE)
        case .completion: (0x63E3FF, 0x3BD3FE)
        case .indentation: (0x94A1FF, 0x6D7CFF)
        case .simulator: (0x5FD776, 0x2FBF4F)
        }
    }

    /// Editing's sub-page rows use these icons.
    public static func forEditingPage(_ title: String) -> SettingsRowIcon? {
        switch title {
        case "Display": .display
        case "Completion": .completion
        case "Indentation": .indentation
        default: nil
        }
    }
}

/// The Settings window's colours as sRGB hex pairs (light, dark): light as
/// measured in round 3 (R3.1–R3.3), dark as measured in round 4 (R4.1–R4.3)
/// where it was, else Ycode's own. Both IDEs draw with them.
public enum SettingsPaletteHex {
    public typealias Pair = (light: UInt32, dark: UInt32)
    public static let sidebar: Pair = (0xEDEDED, 0x262627)
    public static let divider: Pair = (0xD4D4D4, 0x414142)
    public static let detail: Pair = (0xFFFFFF, 0x1F1F1F)
    public static let card: Pair = (0xF7F7F7, 0x262626)
    public static let separator: Pair = (0xEBEBEB, 0x303030)
    public static let selection: Pair = (0x0070F5, 0x007AFF)
    /// Unselected rows' symbols (the accent colour).
    public static let symbol: Pair = (0x0575FA, 0x118BFF)
    public static let title: Pair = (0x4D4D4D, 0xE8E8E8)
    public static let label: Pair = (0x262626, 0xDEDEDE)
    public static let header: Pair = (0x272727, 0xDDDDDD)
    public static let help: Pair = (0x7C7C7C, 0x969696)
    public static let capsuleFill: Pair = (0xFAFAFA, 0x353535)
    public static let capsuleRim: Pair = (0xE2E2E2, 0x4A4A4A)
    public static let capsuleDivider: Pair = (0xC8C8C8, 0x555555)
    public static let chevron: Pair = (0x4D4D4D, 0xD8D8D8)
    public static let chevronDisabled: Pair = (0xAEAEAE, 0x6E6E6E)
    public static let popUpCircle: Pair = (0xE5E5E5, 0x363636)
    public static let popUpChevron: Pair = (0x232323, 0xD2D2D2)
    public static let switchOff: Pair = (0xDDDDDD, 0x3B3B3B)
    public static let switchOn: Pair = (0x0070F5, 0x0679F7)
    /// A navigation row's disclosure chevron.
    public static let disclosure: Pair = (0xB0B0B0, 0x5C5C5C)
}
