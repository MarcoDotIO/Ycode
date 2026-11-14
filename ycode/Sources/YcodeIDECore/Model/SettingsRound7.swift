import Foundation

// Council round 7 in Settings (`specs/ide/settings.md` R7.1–R7.4,
// checklist rows 182–185), shared by the macOS IDE (YcodeUI) and the Linux
// IDE (ycode-ide): the Theme list's cards, rows and controls below the
// first screen, the colour tracks in light and dark (the Foreground and
// Background sliders), the controls' accessibility values, and the
// Appearance thumbnails' close-up composition.

// MARK: The Theme list (R7.1, row 182)

public enum SettingsAppearanceR7 {
    /// A switch of the list, stored in the theme.
    public enum Switch: String, Sendable, CaseIterable {
        case backgroundGradient, customizeAllColors

        public var title: String {
            switch self {
            case .backgroundGradient: "Background Gradient"
            case .customizeAllColors: "Customize All Colors"
            }
        }
    }

    /// One row of the list after Theme and Name.
    public enum Row: Sendable, Equatable {
        /// A slider and a 48 × 28 colour button (56 tall).
        case slider(title: String, key: String)
        /// A switch (36.5 tall).
        case toggle(Switch)
        /// A 48 × 24 colour button only (47 tall).
        case color(title: String, key: String)

        public var title: String {
            switch self {
            case .slider(let t, _), .color(let t, _): t
            case .toggle(let s): s.title
            }
        }

        /// The colour row's key (`ThemeColorRows`), nil for a switch.
        public var key: String? {
            switch self {
            case .slider(_, let k), .color(_, let k): k
            case .toggle: nil
            }
        }

        public var height: CGFloat {
            switch self {
            case .slider: SettingsAppearanceR7.sliderRowHeight
            case .toggle: SettingsAppearanceR7.switchRowHeight
            case .color: SettingsAppearanceR7.colorRowHeight
            }
        }
    }

    /// Row heights: a slider row 56, a switch row 36.5, a colour-only row
    /// 47 (each plus a 1-point separator inside a card).
    public static let sliderRowHeight: CGFloat = 56
    public static var switchRowHeight: CGFloat { SettingsRowMetrics.switchRowHeight }
    public static let colorRowHeight: CGFloat = 47
    /// Every label's cap top is 13 under its row's top.
    public static let labelCapTop: CGFloat = 13
    /// The colour button of a colour-only row: 48 × 24, centred in the row
    /// (11.5 from its top and bottom), its right edge 10 inside the card.
    public static let colorButtonSize = CGSize(width: 48, height: 24)
    /// A slider row's colour button: 48 × 28.
    public static var sliderButtonSize: CGSize { SettingsAppearanceLayout.wellSize }
    /// The slider's frame (and its accessibility element): the track plus
    /// 11 above and below, 202.5 × 36.
    public static let sliderFrameHeight: CGFloat = 36
    /// Cards are 10 apart.
    public static let cardGap: CGFloat = 10
    /// A slider's keyboard and accessibility step.
    public static let sliderStep = 0.05

    /// Plain Text: the plain-text token's colour (absent: the text colour).
    public static let plainText = (title: "Plain Text", key: "identifier")
    /// The syntax rows in the reference's order (Comments, Documentation
    /// Comments, Keywords), then Ycode's rows the reference has not been
    /// seen to show, until its order is captured (R7.5).
    public static let syntaxRows: [(title: String, key: String)] = [
        ("Comments", "comment"), ("Documentation Comments", "docComment"), ("Keywords", "keyword"),
        ("Strings", "string"), ("Numbers", "number"), ("Preprocessor Statements", "preprocessor"), ("Attributes", "attribute"),
        ("Type Names", "typeName"), ("Selection", "selection"), ("Current Line", "currentLine"),
    ]

    /// The list's cards after card A (Theme, Name): [Foreground,
    /// Background, Background Gradient] [Customize All Colors] [Plain Text]
    /// [the syntax rows]. With Customize All Colors on, every colour row
    /// has its own slider.
    public static func cards(customizeAllColors: Bool) -> [[Row]] {
        func colour(_ r: (title: String, key: String)) -> Row {
            customizeAllColors ? .slider(title: r.title, key: r.key) : .color(title: r.title, key: r.key)
        }
        return [
            [.slider(title: "Foreground", key: "foreground"), .slider(title: "Background", key: "background"), .toggle(.backgroundGradient)],
            [.toggle(.customizeAllColors)],
            [colour(plainText)],
            syntaxRows.map(colour),
        ]
    }

    /// The rows' tops (window y, the list unscrolled), from card B's top:
    /// 391.5 for Foreground, as in the reference.
    public static func rowTops(customizeAllColors: Bool, from top: CGFloat = 391.5) -> [(row: Row, top: CGFloat)] {
        var y = top, out: [(Row, CGFloat)] = []
        for card in cards(customizeAllColors: customizeAllColors) {
            for (i, r) in card.enumerated() {
                if i > 0 { y += SettingsLayout.separatorHeight }
                out.append((r, y))
                y += r.height
            }
            y += cardGap
        }
        return out
    }

    /// A switch's value in a theme (Background Gradient: on when absent).
    public static func isOn(_ s: Switch, in t: EditorTheme) -> Bool {
        switch s {
        case .backgroundGradient: t.backgroundGradient ?? true
        case .customizeAllColors: t.customizeAllColors ?? false
        }
    }

    /// Sets a switch in a (user) theme; the default value is stored as absent.
    public static func set(_ s: Switch, _ on: Bool, in t: inout EditorTheme) {
        switch s {
        case .backgroundGradient: t.backgroundGradient = on ? nil : false
        case .customizeAllColors: t.customizeAllColors = on ? true : nil
        }
    }
}

// MARK: Colour tracks (R7.1's Background, R7.2's dark Foreground; rows 182–183)

/// What a slider row draws: its track's colour stops (positions 0–1, left
/// to right), the knob's position, and the colour under the knob (which
/// its colour button shows).
public struct ThemeColorTrack: Sendable {
    public typealias RGB = ThemeColorRows.RGB
    public var stops: [(position: Double, color: RGB)]
    public var strength: Double

    public init(stops: [(position: Double, color: RGB)], strength: Double) {
        self.stops = stops
        self.strength = min(max(strength, 0), 1)
    }

    /// The colour at `s` (0–1) along the track.
    public func color(at s: Double) -> RGB {
        let s = min(max(s, 0), 1)
        guard let first = stops.first else { return (0, 0, 0) }
        if s <= first.position { return first.color }
        for (a, b) in zip(stops, stops.dropFirst()) where s <= b.position {
            let t = b.position > a.position ? (s - a.position) / (b.position - a.position) : 1
            return ThemeColorRows.mix(a.color, b.color, t)
        }
        return stops[stops.count - 1].color
    }

    /// The knob's colour (and the colour button's).
    public var knobColor: RGB { color(at: strength) }
    /// The track's ends.
    public var low: RGB { stops.first?.color ?? (0, 0, 0) }
    public var high: RGB { stops.last?.color ?? (0, 0, 0) }
}

public extension ThemeColorRows {
    /// `a` blended towards `b` by `t` (0: `a`).
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        (a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t)
    }

    // Dark (R7.2): the track runs from a muted tone of the colour (greyed)
    // through the colour at 50 % to a pale tint at the right, the end that
    // stands out more from a dark editor (light runs pale → full colour).

    /// The muted end: half the colour, half a mid grey (#B4B4B4): #FF9EC4
    /// gives #DAA9BC (the reference's #DCAAB9).
    static let darkMutedGrey = 180.0 / 255
    static let darkMutedShare = 0.5
    /// The pale end: the colour 55 % of the way to white (#FFD4E5; the
    /// reference's #FFD4E7).
    static let darkPaleShare = 0.55
    /// The colour at 50 % in dark for rows whose colour has no hue: the
    /// reference's default Foreground #FF9EC4; other rows their light hue
    /// brightened (its largest channel to 1) and 38 % toward white.
    static let darkFallbackMids: [String: UInt32] = ["foreground": 0xFF9EC4]
    static let darkMidWhiteShare = 0.38

    static func darkMuted(_ m: RGB) -> RGB { mix(m, (darkMutedGrey, darkMutedGrey, darkMutedGrey), darkMutedShare) }
    static func darkPale(_ m: RGB) -> RGB { mix(m, (1, 1, 1), darkPaleShare) }

    /// A hue's colour at 50 % in dark.
    static func darkMid(ofHue h: RGB) -> RGB {
        let top = max(h.r, h.g, h.b, 0.001)
        return mix((h.r / top, h.g / top, h.b / top), (1, 1, 1), darkMidWhiteShare)
    }

    /// The dark track of a middle colour `m`: muted → `m` → pale.
    static func darkTrack(mid m: RGB, strength s: Double) -> ThemeColorTrack {
        ThemeColorTrack(stops: [(0, darkMuted(m)), (0.5, m), (1, darkPale(m))], strength: s)
    }

    /// The middle colour whose dark track puts `c` at `s`.
    static func darkMid(of c: RGB, strength s: Double) -> RGB {
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        if s <= 0.5 {
            // c = muted + (m − muted)·t, muted = (1 − k)·m + k·g, t = 2s.
            let t = 2 * s, k = darkMutedShare, g = darkMutedGrey
            let a = 1 - k + k * t, gk = k * g * (1 - t)
            return (clamp((c.r - gk) / a), clamp((c.g - gk) / a), clamp((c.b - gk) / a))
        }
        // c = m + (pale − m)·u, pale = (1 − p)·m + p, u = 2s − 1.
        let u = 2 * s - 1, p = darkPaleShare
        let a = 1 - p * u
        return (clamp((c.r - p * u) / a), clamp((c.g - p * u) / a), clamp((c.b - p * u) / a))
    }

    // The Background row (R7.1): the knob at the left in the background
    // colour, the track from that colour through a light blue to a blue at
    // the right (#4A5A69 → #5695C4 → #3B93CE in the reference's dark).

    static let backgroundTrackMid: UInt32 = 0x5695C4
    static let backgroundTrackEnd: UInt32 = 0x3B93CE
    static let backgroundTrackMidPosition = 0.6
    /// The default theme's Background row in dark shows the reference's
    /// swatch (#484748); in light, the editor's background.
    static let systemBackgroundDark: UInt32 = 0x484748

    static func backgroundTrack(base: RGB, strength s: Double) -> ThemeColorTrack {
        ThemeColorTrack(stops: [(0, base), (backgroundTrackMidPosition, rgb(backgroundTrackMid)), (1, rgb(backgroundTrackEnd))], strength: s)
    }

    /// What a slider row draws in an appearance. `resolved` is the colour
    /// the editor draws for the row (the theme's, else the system's).
    /// - light: round 6's track (pale tint → full colour, `display`);
    /// - dark: muted → the colour at 50 % → pale (R7.2); a stored strength
    ///   puts the theme's colour at the knob; a colour with a hue and no
    ///   strength sits at 50 %; a grey takes Ycode's dark colour for the row;
    /// - Background, both: the background colour at the knob (strength 0)
    ///   on a track to blue.
    static func track(_ key: String, in theme: EditorTheme, resolved: RGB, dark: Bool) -> ThemeColorTrack {
        let own = value(key, in: theme) != nil
        let stored = own ? theme.strengths?[key] : nil
        if key == "background" {
            if !own { return backgroundTrack(base: dark ? rgb(systemBackgroundDark) : resolved, strength: 0) }
            guard let s = stored else { return backgroundTrack(base: resolved, strength: 0) }
            // Past the light blue the base cannot be recovered: the system's.
            guard s < backgroundTrackMidPosition else {
                return backgroundTrack(base: dark ? rgb(systemBackgroundDark) : (1, 1, 1), strength: s)
            }
            // c = base + (mid − base)·t, t = s / 0.6.
            let t = s / backgroundTrackMidPosition, mid = rgb(backgroundTrackMid)
            func b(_ c: Double, _ m: Double) -> Double { min(max((c - m * t) / (1 - t), 0), 1) }
            return backgroundTrack(base: (b(resolved.r, mid.r), b(resolved.g, mid.g), b(resolved.b, mid.b)), strength: s)
        }
        guard dark else {
            let d = display(key, in: theme, resolved: resolved)
            return ThemeColorTrack(stops: [(0, paleTint(d.full, strength: 0)), (1, d.full)], strength: d.strength)
        }
        if let s = stored, isChromatic(resolved) { return darkTrack(mid: darkMid(of: resolved, strength: s), strength: s) }
        if isChromatic(resolved) { return darkTrack(mid: resolved, strength: defaultStrength) }
        let mid = darkFallbackMids[key].map(rgb) ?? darkMid(ofHue: rgb(fallbackHues[key] ?? 0xE35590))
        return darkTrack(mid: mid, strength: defaultStrength)
    }

    /// Sets a row from its slider (a user theme only): the colour at the
    /// knob becomes the row's colour, and the strength is stored with it.
    static func setFromSlider(_ key: String, track: ThemeColorTrack, strength s: Double, in theme: inout EditorTheme) {
        let c = track.color(at: s)
        set(key, hex(c.r, c.g, c.b), in: &theme)
        var all = theme.strengths ?? [:]
        all[key] = min(max(s, 0), 1)
        theme.strengths = all
    }

    // MARK: Accessibility (R7.3, row 184)

    /// A colour button's accessibility value, in the reference's form:
    /// "rgb 1 0.619608 0.768627 1" (sRGB components and the alpha, up to
    /// six decimals).
    static func accessibilityValue(_ c: RGB) -> String {
        func f(_ v: Double) -> String {
            var s = String(format: "%.6f", min(max(v, 0), 1))
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
            return s
        }
        return "rgb \(f(c.r)) \(f(c.g)) \(f(c.b)) 1"
    }

    /// A slider's accessibility value: its position as a percentage.
    static func percent(_ s: Double) -> String { "\(Int((min(max(s, 0), 1) * 100).rounded()))%" }

    /// A slider position one accessibility step up or down.
    static func stepped(_ s: Double, up: Bool) -> Double {
        let step = SettingsAppearanceR7.sliderStep
        return min(max(((s + (up ? step : -step)) / step).rounded() * step, 0), 1)
    }
}

// MARK: Thumbnails (R7.4, row 185)

/// The Appearance thumbnails' close-up (Ycode's own drawing, in the 67 × 44
/// thumbnail, top-left origin): the wallpaper; a thin bar along the top
/// with a small round mark at its left; a translucent rounded panel at the
/// upper left; and the top-left corner of a large window filling the lower
/// right, its top edge 40 % down, its three window buttons about 6 across
/// and 10 apart at 59 % of the height (R7.4's proportions of the 61-point
/// measurement applied to the 67 × 44 picture, R5.1).
public enum AppearanceThumbnailCloseUp {
    public static var size: CGSize { SettingsAppearanceLayout.thumbnailSize }
    /// The bar along the top and its mark.
    public static let barHeight: CGFloat = 3.5
    public static let markCenter = CGPoint(x: 4.5, y: 1.75)
    public static let markDiameter: CGFloat = 2
    /// The translucent panel (the reference's x 2–39, y 8–20 of 61).
    public static var panel: CGRect {
        let k = size.height / 61
        return CGRect(x: 2, y: 8 * k, width: 37, height: 12 * k)
    }
    public static let panelRadius: CGFloat = 3
    /// The window's top edge (40 % down) and its left edge (17 in; 6 in the
    /// split System thumbnail).
    public static var windowTop: CGFloat { (size.height * 0.40 * 2).rounded() / 2 }
    public static func windowLeft(system: Bool) -> CGFloat { system ? 6 : 17 }
    public static let windowRadius: CGFloat = 5
    /// The window buttons: 6 across, centres 10 apart, the first 11 inside
    /// the window's left edge (x 28, 38, 48 in the Light thumbnail), at
    /// 59 % of the height.
    public static let buttonDiameter: CGFloat = 6
    public static let buttonPitch: CGFloat = 10
    public static let firstButtonInset: CGFloat = 11
    public static var buttonY: CGFloat { (size.height * 0.59 * 2).rounded() / 2 }
    /// The title area runs from the window's top to 8 under the buttons' centres.
    public static var titleAreaHeight: CGFloat { buttonY - windowTop + 8 }
    public static let buttonColors: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]

    /// The window's rectangle (it runs past the right and bottom edges).
    public static func window(system: Bool) -> CGRect {
        let x = windowLeft(system: system)
        return CGRect(x: x, y: windowTop, width: size.width - x + 8, height: size.height - windowTop + 8)
    }

    /// The window buttons' centres.
    public static func buttonCenters(system: Bool) -> [CGPoint] {
        (0..<3).map { CGPoint(x: windowLeft(system: system) + firstButtonInset + CGFloat($0) * buttonPitch, y: buttonY) }
    }

    /// The bar's and the panel's fills (white over the wallpaper; the dark
    /// look a fainter white) as (colour, opacity).
    public static func barFill(dark: Bool) -> (color: UInt32, opacity: Double) { dark ? (0x000000, 0.35) : (0xFFFFFF, 0.55) }
    public static func panelFill(dark: Bool) -> (color: UInt32, opacity: Double) { dark ? (0xFFFFFF, 0.16) : (0xFFFFFF, 0.42) }
    public static func markFill(dark: Bool) -> UInt32 { dark ? 0xE6E6E6 : 0x1E1E1E }
}
