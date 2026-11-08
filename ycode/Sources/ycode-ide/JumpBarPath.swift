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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        JumpBarPathStack {
            ForEach(Array(components.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 { JumpBarChevron().layoutValue(key: JumpBarPathRole.self, value: .chevron) }
                Image(systemName: pair.element.symbol).font(.system(size: 11))
                    .foregroundStyle(isActive ? JumpBarPaneLayout.tint(pair.element.symbol, scheme) : c.secondaryLabel)
                    .layoutValue(key: JumpBarPathRole.self, value: .icon(pair.offset))
                JumpBarClip(background: background) {
                    Text(verbatim: pair.element.title).font(ShellFonts.small)
                        .foregroundStyle(isActive ? c.label : c.secondaryLabel).lineLimit(1).fixedSize()
                }
                .layoutValue(key: JumpBarPathRole.self, value: .title(pair.offset))
            }
            if edited {
                // The unsaved changes' mark.
                Circle().fill(c.secondaryLabel).frame(width: 6, height: 6)
                    .help("Unsaved changes")
                    .shellTarget("edited mark")
                    .layoutValue(key: JumpBarPathRole.self, value: .mark)
            }
            if hasLast {
                if !components.isEmpty { JumpBarChevron().layoutValue(key: JumpBarPathRole.self, value: .chevron) }
                JumpBarClip(background: background) { last() }
                    .layoutValue(key: JumpBarPathRole.self, value: .last)
            }
        }
        .offset(y: CGFloat(JumpBarPaneLayout.pathRaise))
    }
}

/// What a view is in the path.
enum JumpBarPathRole: LayoutValueKey, Equatable {
    case icon(Int), title(Int), chevron, mark, last, other
    static let defaultValue = JumpBarPathRole.other
}

/// Places the path's views by `JumpBarPathLayout.fit`: it takes the width
/// it is offered (the bar up to the stepper) and keeps the path's ink 8.5
/// inside it, so the ink ends 23 inside the bar's edge (with the bar's
/// 14.5 of trailing padding) or 10.5 before the stepper.
struct JumpBarPathStack: Layout {
    static let endInset = JumpBarPathLayout.trailingInset - IssueStepper.trailingInset
    /// The unsaved changes' mark: this far after the file's title.
    static let markGap = 4.0
    /// The toolkit's 11-point symbols sit inside their frames (measured on
    /// the x86 parity shots: ink 1 in from the leading edge, 2 from the
    /// trailing), so an icon is spaced by its ink.
    static let iconInk = (leading: 1.0, trailing: 2.0)
    static func inkWidth(_ role: JumpBarPathRole, _ frame: Double) -> Double {
        if case .icon = role { return max(0, frame - iconInk.leading - iconInk.trailing) }
        return frame
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
            if case .icon = role {
                sv.place(at: CGPoint(x: x - Self.iconInk.leading, y: Double(bounds.midY)), anchor: .leading, proposal: ProposedViewSize(sizes[i]))
            } else {
                sv.place(at: CGPoint(x: x, y: Double(bounds.midY)), anchor: .leading, proposal: ProposedViewSize(width: CGFloat(width), height: sizes[i].height))
            }
            x += width
            previous = role
        }
    }

    /// The model's fit for the measured views; the mark's room is kept.
    func fit(sizes: [CGSize], roles: [JumpBarPathRole], room: Double) -> JumpBarPathLayout.Fit {
        var icons: [Int: Double] = [:], titles: [Int: Double] = [:]
        var last: Double?, mark = 0.0
        for (s, r) in zip(sizes, roles) {
            switch r {
            case .icon(let k): icons[k] = Self.inkWidth(r, Double(s.width))
            case .title(let k): titles[k] = Double(s.width)
            case .last: last = Double(s.width)
            case .mark: mark = Self.markGap + Double(s.width)
            default: break
            }
        }
        let parts = titles.keys.sorted().map { JumpBarPathLayout.Part(icon: icons[$0], title: titles[$0] ?? 0) }
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

/// The path's chevron: a 1-point stroke 2 wide and 6 tall in the
/// secondary label colour (as the macOS `JumpBarChevronView`).
struct JumpBarChevron: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let color = ShellColors(scheme).secondaryLabel
        Canvas { ctx, size in
            let w = CGFloat(JumpBarPathLayout.chevronWidth), h = CGFloat(JumpBarPathLayout.chevronHeight)
            var p = Path()
            p.move(to: CGPoint(x: 0.5, y: size.height / 2 - h / 2))
            p.addLine(to: CGPoint(x: w - 0.5, y: size.height / 2))
            p.addLine(to: CGPoint(x: 0.5, y: size.height / 2 + h / 2))
            ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
        }
        .frame(width: CGFloat(JumpBarPathLayout.chevronWidth), height: 14)
    }
}
