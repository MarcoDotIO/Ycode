import Foundation

// Council round 6 in Settings (`specs/ide/settings.md` R6.1–R6.3,
// checklist rows 149–153), shared by the macOS IDE (YcodeUI) and the Linux
// IDE (ycode-ide): content-sized card rows, the Theme row's raised content,
// the Choose… button's corners, the Foreground row's hue, strength, track,
// knob and well, and Components' size subtitle and "Last used".

// MARK: Row heights (R6.3, row 153)

/// A card row's height follows its content: a pop-up row is about 37.25
/// tall (drawn 37 or 37.5 on the half-point grid), a switch row 36.5, a
/// switch with a two-line description 66; the label's cap top is 13 under
/// the row's top and a description's ink 17.5 under the title's cap top.
public enum SettingsRowMetrics {
    /// What a row holds, which sets its height.
    public enum Kind: Sendable, Equatable {
        /// A pop-up, a value, a stepper, a button: 37.25.
        case popUp
        /// A switch: 36.5.
        case toggle
    }

    public static let popUpRowHeight: CGFloat = 37.25
    public static let switchRowHeight: CGFloat = 36.5
    public static func height(_ kind: Kind) -> CGFloat { kind == .toggle ? switchRowHeight : popUpRowHeight }

    /// The label's cap top under the row's top (round 5: 14, centred).
    public static let labelCapTop: CGFloat = 13
    /// A description's first ink top (its cap top) under the title's cap
    /// top (round 5: 20.5).
    public static let helpCapGap: CGFloat = 17.5
    /// A row with a description ends 13.75 under the description's last
    /// baseline: a switch with two lines is 66 tall (13 + the title's cap
    /// 9.2 + the baseline gap 16.1 + 14 + 13.75 with a 13-point system face).
    public static let helpBottomFromLastBaseline: CGFloat = 13.75
    /// A pop-up row with a description ends 3.5 lower: the reference's
    /// General card 1 (Restore, two lines) keeps its 69.5 points, so the
    /// next card starts at y 223 in both apps.
    public static let popUpHelpExtraBottom: CGFloat = 3.5
    public static func helpBottom(_ kind: Kind) -> CGFloat {
        helpBottomFromLastBaseline + (kind == .popUp ? popUpHelpExtraBottom : 0)
    }

    /// The baseline gap between the title's and the description's first
    /// line, from the faces' cap heights: 17.5 between the cap tops.
    public static func helpBaselineGap(titleCapHeight: CGFloat, helpCapHeight: CGFloat) -> CGFloat {
        helpCapGap + helpCapHeight - titleCapHeight
    }

    /// A row's height with a description of `lines` lines (14-point pitch).
    public static func describedRowHeight(lines: Int, titleCapHeight: CGFloat, helpCapHeight: CGFloat) -> CGFloat {
        labelCapTop + titleCapHeight + helpBaselineGap(titleCapHeight: titleCapHeight, helpCapHeight: helpCapHeight)
            + CGFloat(max(lines, 1) - 1) * SettingsLayout.helpLinePitch + helpBottomFromLastBaseline
    }

    /// How far a one-line row's label sits above the row's centre: its cap
    /// top 13 under the top instead of centred.
    public static func labelRaise(rowHeight: CGFloat, capHeight: CGFloat) -> CGFloat {
        (rowHeight - capHeight) / 2 - labelCapTop
    }

    /// Row tops in a card snap to the half-point grid (a 1-point separator
    /// between rows): the reference's General card from y 223 has its
    /// separators at 260.5, 298.5, 337 and 375.
    public static func snappedSeparatorTops(cardTop: CGFloat, rows: [CGFloat]) -> [CGFloat] {
        var y = cardTop, out: [CGFloat] = []
        for h in rows.dropLast() {
            y += h
            out.append((y * 2).rounded(.toNearestOrAwayFromZero) / 2)
            y += SettingsLayout.separatorHeight
        }
        return out
    }
}

// MARK: Appearance (R6.1, rows 149–151)

public enum SettingsAppearanceR6 {
    /// The Theme row's label and Choose… sit 2.25 above the row's centre:
    /// the button 5.5 under the card's top (y 310.5–334.5 in a 39.5 row from
    /// 305), the label's cap top 12.5 under it (317.5).
    public static let themeRowRaise: CGFloat = 2.25
    /// Choose… (and the other card push buttons): a rounded rectangle of
    /// radius 6, not a capsule.
    public static let pushButtonRadius: CGFloat = 6
    /// The slider's knob: about 28 across, a 3-point white rim around the
    /// colour under it.
    public static let knobDiameter: CGFloat = 28
    public static let knobRim: CGFloat = 3
    /// The track's and the well's 1-point darker edge: the colour scaled
    /// toward black (the reference's #E5538E edged #CD4379; the well's
    /// #EF98B4 edged #CF7894).
    public static let trackEdgeFactor = 0.88
    public static let wellEdgeFactor = 0.86
    public static let edgeWidth: CGFloat = 1
    /// The well's rim (#DFDFDF light).
    public static let wellRim: SettingsPaletteHex.Pair = (0xDFDFDF, 0x4A4A4A)
}

/// The colour rows' hue and strength (R6.1): the track runs in one hue
/// from a pale tint at the left to the full colour at the right, the knob
/// sits at the theme's stored strength (50 % for a system colour, as in the
/// default theme) and the well shows the colour under the knob. A grey
/// colour (the default theme's text) takes Ycode's own hue for its row, so
/// no track is grey.
public extension ThemeColorRows {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// The strength of a row whose theme colour is the system's (or grey).
    static let defaultStrength = 0.5
    /// The pale end keeps a quarter of the colour over white.
    static let paleStrength = 0.25

    /// Ycode's own hue per row, for colours that have none (sRGB hex).
    static let fallbackHues: [String: UInt32] = [
        "foreground": 0xE35590, "comment": 0x5F9A50, "docComment": 0x4F8A3E, "string": 0xD0563B, "number": 0x3D6FD0,
        "keyword": 0xB5428F, "preprocessor": 0xC27C1E, "attribute": 0x9A7A3A, "typeName": 0x6A55C8,
        "background": 0x4A8FE0, "selection": 0x3D7BEA, "currentLine": 0x7A9CE0,
    ]

    static func rgb(_ v: UInt32) -> RGB {
        (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Whether a colour has a hue worth a track (its chroma at least 0.12).
    static func isChromatic(_ c: RGB) -> Bool { max(c.r, c.g, c.b) - min(c.r, c.g, c.b) >= 0.12 }

    /// The colour at strength `s` of `full`: over white, from a quarter of
    /// the colour (the pale end) to the colour itself.
    static func paleTint(_ full: RGB, strength s: Double) -> RGB {
        let k = paleStrength + (1 - paleStrength) * min(max(s, 0), 1)
        return (1 + (full.r - 1) * k, 1 + (full.g - 1) * k, 1 + (full.b - 1) * k)
    }

    /// The full colour that `paleTint(_, strength: s)` turns into `c`.
    static func fullColor(of c: RGB, strength s: Double) -> RGB {
        let k = paleStrength + (1 - paleStrength) * min(max(s, 0), 1)
        func f(_ v: Double) -> Double { min(max(1 + (v - 1) / k, 0), 1) }
        return (f(c.r), f(c.g), f(c.b))
    }

    /// A colour scaled toward black (the track's and the well's edges).
    static func darker(_ c: RGB, _ factor: Double) -> RGB { (c.r * factor, c.g * factor, c.b * factor) }

    /// What a row shows: its full colour (the track's right end) and the
    /// knob's strength. `resolved` is the colour the editor draws for the
    /// row (the theme's, else the system's in the current appearance).
    /// - a stored strength: the theme's colour is the knob's, so the full
    ///   colour is recovered from it;
    /// - a theme colour with a hue: the colour itself, at full strength;
    /// - a system colour (the default theme) or a grey: 50 %, in the
    ///   colour's own hue, else Ycode's hue for the row.
    static func display(_ key: String, in theme: EditorTheme, resolved: RGB) -> (full: RGB, strength: Double) {
        let own = value(key, in: theme) != nil
        if own, let s = theme.strengths?[key], isChromatic(resolved) {
            return (fullColor(of: resolved, strength: s), min(max(s, 0), 1))
        }
        if own, isChromatic(resolved) { return (resolved, 1) }
        let full = isChromatic(resolved) ? resolved : rgb(fallbackHues[key] ?? 0xE35590)
        return (full, defaultStrength)
    }

    /// Sets a row from the slider: the knob's colour becomes the theme's
    /// colour and the strength is stored with it (a user theme only).
    static func setStrength(_ key: String, full: RGB, strength s: Double, in theme: inout EditorTheme) {
        let c = paleTint(full, strength: s)
        set(key, hex(c.r, c.g, c.b), in: &theme)
        var all = theme.strengths ?? [:]
        all[key] = min(max(s, 0), 1)
        theme.strengths = all
    }

    /// Sets a row from the well (a typed colour, or nil for the system's):
    /// the colour is the row's full colour, and the stored strength goes.
    static func setTyped(_ key: String, _ hex: String?, in theme: inout EditorTheme) {
        set(key, hex, in: &theme)
        theme.strengths?[key] = nil
        if theme.strengths?.isEmpty == true { theme.strengths = nil }
    }
}

// MARK: Components (R6.2, row 152)

public enum SettingsComponentsR6 {
    /// A size subtitle ("15.94 GB") starts 3.25 right of the title;
    /// "Built-in" and the other words do not.
    public static let sizeSubtitleInset: CGFloat = 3.25
    /// "Last used …" is the subtitle's size (11 points; cap height 8).
    public static var lastUsedFontSize: CGFloat { SettingsComponentsLayout.subtitleFontSize }
}

public extension ComponentsRow {
    /// Whether the subtitle is an installed size (it starts with a digit).
    var subtitleIsSize: Bool { subtitle.first?.isNumber == true }
    /// The subtitle's inset from the title's left edge.
    var subtitleInset: CGFloat { subtitleIsSize ? SettingsComponentsR6.sizeSubtitleInset : 0 }
}
