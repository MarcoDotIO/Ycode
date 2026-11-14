import Foundation

/// The jump bar's path: its spacing and the order in which it gives way
/// when the bar is too narrow (`specs/ide/editor-area.md` E.2 item 4, H.4;
/// `fidelity-council.md` rows 143–145). Shared by the AppKit jump bar and
/// the Linux IDE's, so both lay out and collapse the same path.
///
/// Every width here is **ink**: the measured extent of a glyph, a title's
/// text or the chevron, not its view's frame. Each toolkit adds its own
/// views' padding around the ink.
public enum JumpBarPathLayout {
    // MARK: Spacing (H.4, row 143)

    /// From a component's icon to its title.
    public static let iconToTitle = 6.0
    /// From a title (or an icon whose title is hidden) to the chevron.
    public static let titleToChevron = 7.0
    /// From a chevron to the next component's icon.
    public static let chevronToIcon = 10.5
    /// From a chevron to a title with no icon ("No Selection", a symbol).
    public static let chevronToTitle = 9.5
    /// The chevron: a stroke 2 wide (Ycode's drawing). Round 10, row 247:
    /// its ink 10 tall (y 61–71 in the reference) with a 1.25-point stroke,
    /// so its centre line spans 8.75.
    public static let chevronWidth = 2.0
    public static let chevronStroke = 1.25
    public static let chevronInkHeight = 10.0
    public static var chevronHeight: Double { chevronInkHeight - chevronStroke }
    /// The path's ink ends at least this far inside the bar's trailing edge
    /// (H.4: at 1100 it ends at 540.5 in a pane ending at 563.5).
    public static let trailingInset = 23.0
    /// The path's ink ends at least this far before the issue stepper when
    /// it shows (Ycode's choice: the stepper's end inset and the path's
    /// share the 23).
    public static let stepperGap = 10.5
    /// A cut title fades out over its last points instead of ending in an
    /// ellipsis (E.2 item 4).
    public static let fade = 4.0
    /// A cut title narrower than this goes altogether, with its gap (I.5,
    /// row 180: the reference keeps the project's "Gl" at 9 points, two
    /// letters fading, before it gives the title up).
    public static let minimumCut = 9.0

    // MARK: Icon slots (I.5, row 180)

    /// The icons' slots, the reference's ink widths: the project's 13, a
    /// group's 12.5, the file's 12.5 with its 11.5 of ink centred (so its
    /// ink starts 11 after a chevron and its title 6.5 after the ink: the
    /// reference's 490–501.5 then 508 at 1250, 426.5–438 at 1100). Each
    /// slot is followed by `iconToTitle` (6) to its title, so the advances
    /// are the reference's 19 (project), 18.5 (group) and 18.5 (file, 18
    /// from its ink's start to the title's).
    public enum IconRole: Sendable, Equatable { case project, group, file }
    public static func iconRole(index: Int, count: Int) -> IconRole {
        count > 1 && index == 0 ? .project : index == count - 1 ? .file : .group
    }
    public static func iconSlot(_ role: IconRole) -> Double {
        switch role {
        case .project: 13
        case .group, .file: 12.5
        }
    }
    /// The ink drawn in the slot (an icon whose own ink is wider is drawn
    /// smaller to fit it; a narrower one is centred).
    public static func iconInk(_ role: IconRole) -> Double {
        switch role {
        case .project: 13
        case .group: 12.5
        case .file: 11.5
        }
    }
    /// The active pane's chevrons are 3 wide (the inactive pane's 2, I.5);
    /// the extra point is taken from the gap **after** the chevron (round 9,
    /// row 217: a name, 7, the 3-wide chevron, 8.5, "No Selection"), so the
    /// path's length is the same in both panes.
    public static func chevronInk(active: Bool) -> Double { active ? 3 : chevronWidth }

    /// The chevron's colour, 0xRRGGBB (round 9, row 217, the active pane):
    /// #808080 in light, #DEDEDE in dark; nil: the inactive pane's
    /// secondary label colour.
    public static func chevronColor(dark: Bool, active: Bool) -> UInt32? {
        active ? (dark ? 0xDEDEDE : 0x808080) : nil
    }

    // MARK: Collapse (H.4, row 144)

    /// One path component: its icon's ink width (nil: none), its title's,
    /// and its title's first letter's (nil: unknown).
    public struct Part: Equatable, Sendable {
        public var icon: Double?
        public var title: Double
        public var initial: Double?
        public init(icon: Double?, title: Double, initial: Double? = nil) {
            self.icon = icon
            self.title = title
            self.initial = initial
        }

        /// The narrowest cut before the title goes: its initial and a little
        /// of the fade after it (round 9, row 216: "G", "M" with a tail
        /// fade; round 7's "Gl" at 9), else `minimumCut`.
        public var minimumCut: Double {
            guard let initial else { return JumpBarPathLayout.minimumCut }
            return min(title, initial + JumpBarPathLayout.initialFade)
        }
    }

    /// How much of the fade shows after a title cut to its initial.
    public static let initialFade = 2.5

    /// What the path shows: for each component its title's visible ink
    /// width (nil: hidden, the icon stays), and the last item's (nil:
    /// hidden). A width below the title's own is a cut with a fade.
    public struct Fit: Equatable, Sendable {
        public var titles: [Double?]
        public var last: Double?
        /// The path's ink width as shown.
        public var width: Double
    }

    /// The path's ink width with the titles shown at `titles` (nil:
    /// hidden) and the last item at `last` (nil: none).
    public static func width(parts: [Part], titles: [Double?], last: Double?) -> Double {
        var w = 0.0
        for (i, p) in parts.enumerated() {
            let title = i < titles.count ? titles[i] : p.title
            if i > 0 { w += titleToChevron + chevronWidth + (p.icon != nil ? chevronToIcon : (title != nil ? chevronToTitle : 0)) }
            if let icon = p.icon { w += icon }
            if let t = title { w += (p.icon != nil ? iconToTitle : 0) + t }
        }
        if let last {
            if !parts.isEmpty { w += titleToChevron + chevronWidth + chevronToTitle }
            w += last
        }
        return w
    }

    /// How the path fits `room` points of ink (from its first ink to the
    /// limit `trailingInset` inside the bar's edge, or `stepperGap` before
    /// the issue stepper). The order (I.5; round 9, row 216):
    /// 1. the leading components' titles go, their icons stay: the middle
    ///    ones (the groups) first, from the first, each cut from its end
    ///    with a fade down to its initial, then gone; then the first
    ///    component's (the project's) the same way, so at 1250 with the
    ///    stepper the project shows "G" beside the groups' bare icons;
    /// 2. then the file's title (the last component) is cut from its end
    ///    to its initial ("M"), then goes;
    /// 3. the last item ("No Selection" or the symbol) stays whole until
    ///    everything before it is reduced; only then is it cut ("No Sele"
    ///    with a fade), and it never goes.
    public static func fit(parts: [Part], last: Double?, room: Double) -> Fit {
        var titles: [Double?] = parts.map(\.title)
        var lastW = last
        func current() -> Double { width(parts: parts, titles: titles, last: lastW) }
        guard current() > room else { return Fit(titles: titles, last: lastW, width: current()) }
        // A component without an icon keeps its title (it would show nothing).
        let leading = parts.indices.dropLast()
        let order = Array(leading.dropFirst()) + Array(leading.prefix(1))
        for i in order where parts[i].icon != nil {
            cut(&titles[i], over: current() - room, minimum: parts[i].minimumCut)
            if current() <= room { return Fit(titles: titles, last: lastW, width: current()) }
        }
        if let f = parts.indices.last, parts[f].icon != nil {
            cut(&titles[f], over: current() - room, minimum: parts[f].minimumCut)
            if current() <= room { return Fit(titles: titles, last: lastW, width: current()) }
        }
        if lastW != nil {
            // The last item is cut but never goes.
            lastW = max(minimumCut, (lastW ?? 0) - (current() - room))
        }
        return Fit(titles: titles, last: lastW, width: current())
    }

    /// Cuts a title by `overflow`; below `minimum` it goes, with its gap.
    static func cut(_ title: inout Double?, over overflow: Double, minimum: Double = minimumCut) {
        guard let t = title, overflow > 0 else { return }
        let left = t - overflow
        title = left >= minimum - 0.001 ? left : nil
    }
}
