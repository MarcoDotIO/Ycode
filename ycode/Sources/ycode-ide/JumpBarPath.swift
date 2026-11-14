import Foundation
import SwiftUI
import YcodeIDECore

/// The jump bar's path laid out and collapsed by the shared model
/// (`JumpBarPathLayout`; `editor-area.md` H.4, checklist rows 143–145), as
/// the macOS jump bar does it (`YcodeUI/Editor/JumpBar+Path.swift`): icon
/// to title 6, title to chevron 7, chevron (2 wide) to an icon 10.5 and to
/// an icon-less title 9.5; when the bar is too narrow the leading titles
/// go (icons stay), then the file's title is cut with a fade, and the last
/// item stays whole until then. Frames are taken as ink.
struct JumpBarPathView<Last: View>: View {
    let components: [(title: String, symbol: String)]
    let isActive: Bool
    let edited: Bool
    let background: Color
    @ViewBuilder let last: () -> Last
    let hasLast: Bool
    /// The file the path ends at: its component shows the project
    /// navigator's icon for it, a language's logo (council round 8, row 200).
    var fileName: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        JumpBarPathStack(wideChevrons: isActive) {
            ForEach(Array(components.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 { JumpBarChevron(active: isActive).layoutValue(key: JumpBarPathRole.self, value: .chevron) }
                // The icon in its role's slot (I.5, row 180: project 13,
                // group 12.5, file 12.5 with 11.5 of ink), scaled to fit.
                let role = JumpBarPathLayout.iconRole(index: pair.offset, count: components.count)
                // The navigator's glyphs, smaller (round 9, row 211), as macOS:
                // the file's line-art logo or JSON glyph, a group's folder,
                // the project's Ycode mark (dimmed without focus).
                let glyph = FileGlyphs.jumpBarGlyph(symbol: pair.element.symbol, role: role, fileName: fileName)
                JumpBarIconSlot(role: role, exactInk: glyph != nil) {
                    if let g = glyph {
                        if g == .ycodeMark {
                            YcodeSmallMark(size: CGFloat(FileGlyphs.jumpBarBox(g).width))
                                .opacity(isActive ? 1 : 0.55)
                                .shellTarget("jump path icon \(pair.offset)")
                        } else if let d = FileGlyphs.jumpBarDrawing(g) {
                            FileGlyphView(drawing: d, color: isActive
                                ? FileGlyphs.jumpBarGlyphTint(g, fileName: fileName).map { FileGlyphView.color($0, dark: scheme == .dark) } ?? c.accent
                                : c.secondaryLabel)
                                .shellTarget("jump path icon \(pair.offset)")
                        }
                    } else {
                        Image(systemName: pair.element.symbol).font(.system(size: 11))
                            .foregroundStyle(isActive ? JumpBarPaneLayout.tint(pair.element.symbol, scheme) : c.secondaryLabel)
                            .shellTarget("jump path icon \(pair.offset)")
                    }
                }
                .layoutValue(key: JumpBarPathRole.self, value: .icon(pair.offset))
                JumpBarClip(background: background) {
                    Text(verbatim: pair.element.title).font(ShellFonts.small)
                        .foregroundStyle(isActive ? c.label : c.secondaryLabel).lineLimit(1).fixedSize()
                        .shellTarget("jump path title \(pair.offset)")
                }
                .layoutValue(key: JumpBarPathRole.self, value: .title(pair.offset))
                // The title's first letter, measured only: the narrowest cut
                // keeps it (round 9, row 216).
                Text(verbatim: String(pair.element.title.prefix(1))).font(ShellFonts.small).lineLimit(1).fixedSize().opacity(0)
                    .accessibilityHidden(true)
                    .layoutValue(key: JumpBarPathRole.self, value: .initial(pair.offset))
            }
            if edited {
                // The unsaved changes' mark.
                Circle().fill(c.secondaryLabel).frame(width: 6, height: 6)
                    .help("Unsaved changes")
                    .shellTarget("edited mark")
                    .layoutValue(key: JumpBarPathRole.self, value: .mark)
            }
            if hasLast {
                if !components.isEmpty { JumpBarChevron(active: isActive).layoutValue(key: JumpBarPathRole.self, value: .chevron) }
                JumpBarClip(background: background) { last() }
                    .layoutValue(key: JumpBarPathRole.self, value: .last)
            }
        }
        .offset(y: CGFloat(JumpBarPaneLayout.pathRaise))
    }
}

/// What a view is in the path.
enum JumpBarPathRole: LayoutValueKey, Equatable {
    case icon(Int), title(Int), initial(Int), chevron, mark, last, other
    static let defaultValue = JumpBarPathRole.other
}

/// Places the path's views by `JumpBarPathLayout.fit`: it takes the width
/// it is offered (the bar up to the stepper) and keeps the path's ink 8.5
/// inside it, so the ink ends 23 inside the bar's edge (with the bar's
/// 14.5 of trailing padding) or 10.5 before the stepper.
struct JumpBarPathStack: Layout {
    /// The active pane's chevrons are 3 wide, each taking half its extra
    /// point from the gaps beside it (I.5).
    var wideChevrons = false
    static let endInset = JumpBarPathLayout.trailingInset - IssueStepper.trailingInset
    /// The unsaved changes' mark: this far after the file's title.
    static let markGap = 4.0
    /// A text's ink inside its frame: the toolkit's 11-point face leaves
    /// about 0.5 before the first glyph's ink and 0.75 after the last
    /// (measured on the x86 parity shots in dark: "Merger" framed 38, ink
    /// 37; "Sources" 43, 42; "Sample" 40, 38), so the path is spaced and
    /// fitted by ink, as the macOS one (I.5).
    static let textBearing = (leading: 0.5, trailing: 0.75)
    static func isText(_ role: JumpBarPathRole) -> Bool {
        switch role {
        case .title, .initial, .last: true
        default: false
        }
    }
    /// An icon's frame is its slot (`JumpBarIconSlot`), already ink-sized;
    /// a text's is its ink plus the face's bearings.
    static func inkWidth(_ role: JumpBarPathRole, _ frame: Double) -> Double {
        isText(role) ? max(0, frame - textBearing.leading - textBearing.trailing) : frame
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let height = sizes.map(\.height).max() ?? 0
        let roles = subviews.map { $0[JumpBarPathRole.self] }
        let full = fit(sizes: sizes, roles: roles, room: .infinity).width + Self.endInset
        // The rest of the bar when offered (the stack's only flexible child).
        guard let w = proposal.width, w.isFinite else { return CGSize(width: CGFloat(full), height: height) }
        return CGSize(width: w, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let roles = subviews.map { $0[JumpBarPathRole.self] }
        let f = fit(sizes: sizes, roles: roles, room: Double(bounds.width) - Self.endInset)
        var x = Double(bounds.minX)
        var previous: JumpBarPathRole?
        for (i, sv) in subviews.enumerated() {
            let role = roles[i]
            if case .initial = role {
                // Measured only: nothing drawn, no gap.
                sv.place(at: CGPoint(x: Double(bounds.minX), y: Double(bounds.midY)), anchor: .leading,
                         proposal: ProposedViewSize(width: 0, height: sizes[i].height))
                continue
            }
            var width = Self.inkWidth(role, Double(sizes[i].width))
            switch role {
            case .title(let k): width = k < f.titles.count ? f.titles[k] ?? -1 : width
            case .last: width = f.last ?? -1
            default: break
            }
            guard width >= 0 else {
                // A hidden title: nothing drawn, no gap.
                sv.place(at: CGPoint(x: x, y: Double(bounds.midY)), anchor: .leading, proposal: ProposedViewSize(width: 0, height: sizes[i].height))
                continue
            }
            if let previous { x += Self.gap(previous, role) }
            if role == .chevron, wideChevrons {
                // 3 wide from the 2-wide chevron's place: the extra point
                // comes out of the gap after it (round 9, row 217: 7 before,
                // 8.5 after).
                let w = JumpBarPathLayout.chevronInk(active: true)
                sv.place(at: CGPoint(x: x, y: Double(bounds.midY)), anchor: .leading,
                         proposal: ProposedViewSize(width: CGFloat(w), height: sizes[i].height))
            } else if case .icon = role {
                sv.place(at: CGPoint(x: x, y: Double(bounds.midY)), anchor: .leading, proposal: ProposedViewSize(sizes[i]))
            } else if Self.isText(role) {
                // The frame before the ink by its bearing; whole, the frame's
                // own width, cut, the ink shown and the bearing before it.
                let whole = width >= Self.inkWidth(role, Double(sizes[i].width)) - 0.01
                let w = whole ? Double(sizes[i].width) : width + Self.textBearing.leading
                sv.place(at: CGPoint(x: x - Self.textBearing.leading, y: Double(bounds.midY)), anchor: .leading,
                         proposal: ProposedViewSize(width: CGFloat(w), height: sizes[i].height))
            } else {
                sv.place(at: CGPoint(x: x, y: Double(bounds.midY)), anchor: .leading, proposal: ProposedViewSize(width: CGFloat(width), height: sizes[i].height))
            }
            x += width
            previous = role
        }
    }

    /// The model's fit for the measured views; the mark's room is kept.
    func fit(sizes: [CGSize], roles: [JumpBarPathRole], room: Double) -> JumpBarPathLayout.Fit {
        var icons: [Int: Double] = [:], titles: [Int: Double] = [:], initials: [Int: Double] = [:]
        var last: Double?, mark = 0.0
        for (s, r) in zip(sizes, roles) {
            switch r {
            case .icon(let k): icons[k] = Self.inkWidth(r, Double(s.width))
            case .title(let k): titles[k] = Self.inkWidth(r, Double(s.width))
            case .initial(let k): initials[k] = Self.inkWidth(r, Double(s.width))
            case .last: last = Self.inkWidth(r, Double(s.width))
            case .mark: mark = Self.markGap + Double(s.width)
            default: break
            }
        }
        let parts = titles.keys.sorted().map { JumpBarPathLayout.Part(icon: icons[$0], title: titles[$0] ?? 0, initial: initials[$0]) }
        var f = JumpBarPathLayout.fit(parts: parts, last: last, room: room - mark)
        f.width += mark
        return f
    }

    /// The ink gap between two neighbours (H.4).
    static func gap(_ a: JumpBarPathRole, _ b: JumpBarPathRole) -> Double {
        typealias L = JumpBarPathLayout
        switch (a, b) {
        case (.icon, .title): return L.iconToTitle
        case (.chevron, .icon): return L.chevronToIcon
        case (.chevron, _): return L.chevronToTitle
        case (_, .mark): return markGap
        default: return L.titleToChevron
        }
    }
}

/// A title cut to the width it is offered, fading out over its last
/// `JumpBarPathLayout.fade` points (E.2 item 4) into the bar's background.
struct JumpBarClip<Content: View>: View {
    let background: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        JumpBarClipLayout {
            content()
            LinearGradient(colors: [background.opacity(0), background], startPoint: .leading, endPoint: .trailing)
        }
        .clipped()
    }
}

/// The clip's layout: the content at its own size from the leading edge;
/// the fade over the last points only when the content is wider.
struct JumpBarClipLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(.unspecified)
        return CGSize(width: min(proposal.width ?? ideal.width, ideal.width), height: ideal.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let content = subviews.first else { return }
        let ideal = content.sizeThatFits(.unspecified)
        content.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(ideal))
        guard subviews.count > 1 else { return }
        let fade = CGFloat(JumpBarPathLayout.fade)
        let cut = ideal.width > bounds.width + 0.5 && bounds.width > 0
        subviews[1].place(at: CGPoint(x: bounds.maxX - (cut ? fade : 0), y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: cut ? fade : 0, height: cut ? bounds.height : 0))
    }
}

/// The path's chevron: a 1.25-point stroke 2 wide (3 in the active pane,
/// I.5) and 10 tall (round 10, row 247; as the macOS `JumpBarChevronView`).
/// Its layout frame stays 2 wide; the active one draws one point into the
/// gap after it.
struct JumpBarChevron: View {
    var active = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Row 217: #808080 / #DEDEDE in the active pane, the secondary label in the other.
        let color = JumpBarPathLayout.chevronColor(dark: scheme == .dark, active: active)
            .map { Color(.sRGB, red: Double($0 >> 16 & 0xFF) / 255, green: Double($0 >> 8 & 0xFF) / 255, blue: Double($0 & 0xFF) / 255) }
            ?? ShellColors(scheme).secondaryLabel
        let ink = CGFloat(JumpBarPathLayout.chevronInk(active: active))
        Canvas { ctx, size in
            let w = ink, h = CGFloat(JumpBarPathLayout.chevronHeight), s = CGFloat(JumpBarPathLayout.chevronStroke)
            var p = Path()
            p.move(to: CGPoint(x: s / 2, y: size.height / 2 - h / 2))
            p.addLine(to: CGPoint(x: w - s / 2, y: size.height / 2))
            p.addLine(to: CGPoint(x: s / 2, y: size.height / 2 + h / 2))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: CGFloat(JumpBarPathLayout.chevronWidth), height: 14)
    }
}

/// A path icon in its role's slot (`JumpBarPathLayout.iconSlot`, I.5): the
/// symbol's ink centred in the slot. The toolkit's 11-point symbols sit
/// inside their frames (ink 1 in from the leading edge, 2 from the
/// trailing, measured on the x86 parity shots), and their ink is no wider
/// than the roles' widths, so they are not scaled.
struct JumpBarIconSlot<Content: View>: View {
    let role: JumpBarPathLayout.IconRole
    /// The content's frame is its ink (one of Ycode's glyphs, `FileGlyphs`).
    var exactInk = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        JumpBarIconSlotLayout(role: role, exactInk: exactInk) { content() }
    }
}

struct JumpBarIconSlotLayout: Layout {
    let role: JumpBarPathLayout.IconRole
    var exactInk = false
    static let symbolInset = (leading: 1.0, trailing: 2.0)

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 0
        return CGSize(width: CGFloat(JumpBarPathLayout.iconSlot(role)), height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let s = subviews.first else { return }
        let size = s.sizeThatFits(.unspecified)
        let inset = exactInk ? (leading: 0.0, trailing: 0.0) : Self.symbolInset
        let ink = max(1, Double(size.width) - inset.leading - inset.trailing)
        let x = Double(bounds.minX) + (JumpBarPathLayout.iconSlot(role) - ink) / 2 - inset.leading
        s.place(at: CGPoint(x: x, y: Double(bounds.midY)), anchor: .leading, proposal: ProposedViewSize(size))
    }
}
