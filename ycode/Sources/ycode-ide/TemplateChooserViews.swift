import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The template chooser's parts on Linux, shared by New Project and New
/// File (P-181, P-187), at the macOS sheet's measurements
/// (`TemplateChooserMetrics`): platform tabs sized to their labels, an
/// always-drawn 202-point filter, and a frameless grid of outlined glyphs
/// in five columns on a 137-point pitch, section headers on a darker band.
/// The grid takes keyboard focus; the arrow keys move the selection
/// (`TemplateGridNavigation`), Tab goes between the filter and the grid.
enum TemplateChooser {
    /// What has keyboard focus in the chooser.
    enum Focus: Hashable { case filter, grid }

    typealias M = TemplateChooserMetrics

    /// The section band's fill: a little darker than the sheet.
    static func bandFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.22) : Color.black.opacity(0.05)
    }

    /// The selected tile's grey (the macOS grid's unemphasized selection).
    static func tileFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)
    }
}

/// The platform tabs: segments as wide as their labels (not equal widths,
/// so "Multiplatform" is never cut, L-234), 10-point labels, 20 tall.
struct PlatformTabs: View {
    let tabs: [String]
    let selection: String
    let choose: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { t in
                let on = t == selection
                Text(verbatim: t).font(.system(size: CGFloat(TemplateChooser.M.platformLabelSize), weight: on ? .medium : .regular))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 9)
                    .frame(height: 18)
                    .background { if on { RoundedRectangle(cornerRadius: 4).fill(selectedFill) } }
                    .contentShape(Rectangle())
                    .onTapGesture { choose(t) }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { choose(t) }
                    .shellTarget("platform \(t)")
            }
        }
        .padding(1)
        .frame(height: 20)
        .background { RoundedRectangle(cornerRadius: 5).fill(track) }
    }

    var track: Color { scheme == .dark ? Color.white.opacity(0.119) : Color.black.opacity(0.07) }
    var selectedFill: Color { scheme == .dark ? Color.white.opacity(0.2) : Color.white }
}

/// The frameless template grid with its banded section headers.
struct TemplateGrid: View {
    let sections: [TemplateSection]
    /// The selected entry's key (`key(entry)`).
    let selectedKey: String?
    let key: (TemplateEntry) -> String
    let select: (TemplateEntry) -> Void
    let choose: (TemplateEntry) -> Void
    @Environment(\.colorScheme) private var scheme

    typealias M = TemplateChooserMetrics

    var body: some View {
        let c = ShellColors(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sections.filter { !$0.entries.isEmpty }, id: \.title) { section in
                    Text(verbatim: section.title).font(.system(size: 11, weight: .bold)).foregroundStyle(c.secondaryLabel)
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, minHeight: CGFloat(M.bandHeight), maxHeight: CGFloat(M.bandHeight), alignment: .leading)
                        .background(TemplateChooser.bandFill(scheme))
                    ForEach(Array(stride(from: 0, to: section.entries.count, by: M.columns)), id: \.self) { start in
                        HStack(spacing: CGFloat(M.columnSpacing)) {
                            ForEach(section.entries[start..<min(start + M.columns, section.entries.count)], id: \.title) { tile($0, c) }
                        }
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .scrollIndicators(.automatic)
    }

    func tile(_ e: TemplateEntry, _ c: ShellColors) -> some View {
        let selected = selectedKey == key(e)
        return VStack(spacing: 12) {
            symbol(e.symbol).resizable().scaledToFit().fontWeight(.light).foregroundStyle(c.secondaryLabel)
                .frame(width: CGFloat(M.iconSide), height: CGFloat(M.iconSide))
            Text(verbatim: e.title).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(2)
                .foregroundStyle(selected ? Color.white : c.label)
                .padding(.horizontal, 4)
                .background { if selected { RoundedRectangle(cornerRadius: 4).fill(Color.accentColor) } }
        }
        .padding(.top, 8)
        .frame(width: CGFloat(M.tileWidth), height: CGFloat(M.tileHeight), alignment: .top)
        .background { if selected { RoundedRectangle(cornerRadius: 6).fill(TemplateChooser.tileFill(scheme)).padding(2) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { select(e); choose(e) }
        .onTapGesture { select(e) }
        .help(e.summary)
        // A template tile is a button to accessibility (merge-sheet.md §13.2's rule).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(e.title)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { select(e) }
        .shellTarget("template \(e.title)")
    }
}

extension TemplateGrid {
    /// The entry an arrow key moves the selection to (nil: none).
    static func entry(moving k: TemplateGridNavigation.Key, in sections: [TemplateSection], selectedKey: String?,
                      key: (TemplateEntry) -> String) -> TemplateEntry? {
        let flat = sections.flatMap(\.entries)
        let i = flat.firstIndex { key($0) == selectedKey }
        guard let j = TemplateGridNavigation.index(moving: k, from: i, sectionCounts: sections.map(\.entries.count),
                                                   columns: TemplateChooserMetrics.columns), flat.indices.contains(j) else { return nil }
        return flat[j]
    }

    /// The arrow key of a key press, if it is one.
    static func navigationKey(_ k: KeyEquivalent) -> TemplateGridNavigation.Key? {
        switch k {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        case .downArrow: .down
        default: nil
        }
    }
}
