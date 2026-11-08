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
    /// The chevron: a 1-point stroke 2 wide (Ycode's drawing; its height is
    /// Ycode's choice, the "›" of the 11-point face).
    public static let chevronWidth = 2.0
    public static let chevronHeight = 6.0
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
    /// A cut title narrower than this goes altogether, with its gap (Ycode's
    /// choice: the reference showed "Gla" at about 20 and "Lo" at 13).
    public static let minimumCut = 8.0

    // MARK: Collapse (H.4, row 144)

    /// One path component: its icon's ink width (nil: none) and its title's.
    public struct Part: Equatable, Sendable {
        public var icon: Double?
        public var title: Double
        public init(icon: Double?, title: Double) {
            self.icon = icon
            self.title = title
        }
    }

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
    /// limit `trailingInset` inside the bar's edge). The order:
    /// 1. the leading components' titles go, their icons stay: the middle
    ///    ones (the groups) first, from the first, each cut from its end
    ///    with a fade until it goes; then the first component's (the
    ///    project's);
    /// 2. then the file's title (the last component) is cut from its end,
    ///    until it goes;
    /// 3. the last item ("No Selection" or the symbol) stays whole until
    ///    everything before it is reduced; only then is it cut.
    public static func fit(parts: [Part], last: Double?, room: Double) -> Fit {
        var titles: [Double?] = parts.map(\.title)
        var lastW = last
        func current() -> Double { width(parts: parts, titles: titles, last: lastW) }
        guard current() > room else { return Fit(titles: titles, last: lastW, width: current()) }
        // A component without an icon keeps its title (it would show nothing).
        let leading = parts.indices.dropLast()
        let order = Array(leading.dropFirst()) + Array(leading.prefix(1))
        for i in order where parts[i].icon != nil {
            cut(&titles[i], over: current() - room)
            if current() <= room { return Fit(titles: titles, last: lastW, width: current()) }
        }
        if let f = parts.indices.last, parts[f].icon != nil {
            cut(&titles[f], over: current() - room)
            if current() <= room { return Fit(titles: titles, last: lastW, width: current()) }
        }
        if lastW != nil {
            // The last item is cut but never goes.
            lastW = max(minimumCut, (lastW ?? 0) - (current() - room))
        }
        return Fit(titles: titles, last: lastW, width: current())
    }

    /// Cuts a title by `overflow`; below `minimumCut` it goes, with its gap.
    static func cut(_ title: inout Double?, over overflow: Double) {
        guard let t = title, overflow > 0 else { return }
        let left = t - overflow
        title = left >= minimumCut ? left : nil
    }
}
