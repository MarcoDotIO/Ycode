import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// File ▸ Open Quickly… on the Linux IDE (council round 9, row 215;
/// `OpenQuicklyLayout`, as the AppKit `OpenQuicklyController`): a 640-point
/// glass panel 200 below the window's top; a field with no border, focus
/// ring or clear button after a 21-point magnifier; a separator inset 20;
/// 620 × 56 rows with a 22-point radius, #0064E1 / #0059D1 when selected,
/// the file's glyph, its name with the extension dimmed, and under it the
/// project's glyph and its group path. A click outside closes it.
struct OpenQuicklyLayer: View {
    var model: WorkspaceShellModel

    var body: some View {
        if model.openQuickly.isShown {
            ZStack(alignment: .top) {
                // A click elsewhere closes the panel (as the AppKit panel resigns key).
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.openQuickly.close() }
                OpenQuicklyPanel(model: model)
                    .padding(.top, CGFloat(OpenQuicklyLayout.top))
            }
        }
    }
}

struct OpenQuicklyPanel: View {
    typealias L = OpenQuicklyLayout
    var model: WorkspaceShellModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    static func color(_ v: UInt32) -> Color {
        Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    var body: some View {
        let oq = model.openQuickly
        let dark = scheme == .dark
        let radius = CGFloat(L.cornerRadius)
        VStack(alignment: .leading, spacing: 0) {
            header(dark)
            if !oq.results.isEmpty {
                Rectangle().fill(Self.color(L.separator(dark: dark)))
                    .frame(height: CGFloat(L.separatorHeight))
                    .padding(.horizontal, CGFloat(L.separatorInset))
                    .shellTarget("open quickly separator")
                rows(oq, dark)
                    .padding(.top, CGFloat(L.rowInset - L.separatorHeight))
                    .padding(.horizontal, CGFloat(L.rowInset))
                    .padding(.bottom, CGFloat(L.rowInset))
            }
        }
        .frame(width: CGFloat(L.width), height: CGFloat(oq.panelHeight), alignment: .top)
        .background {
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(PopoverChrome.fill(scheme))
                .shadow(color: Color.black.opacity(dark ? 0.5 : 0.18), radius: 16, y: 6)
                .overlay { RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(PopoverChrome.edge(scheme), lineWidth: 1) }
        }
        .onTapGesture {}
        .onAppear { fieldFocused = true }
        .onChange(of: oq.focusCount) { _, _ in fieldFocused = true }
        .shellTarget("open quickly")
    }

    func header(_ dark: Bool) -> some View {
        let oq = model.openQuickly
        return HStack(spacing: 0) {
            Image(systemName: "magnifyingglass")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: CGFloat(L.magnifierSize), height: CGFloat(L.magnifierSize))
                .foregroundStyle(Self.color(L.magnifier(dark: dark)))
                .padding(.leading, CGFloat(L.magnifierX))
                .accessibilityHidden(true)
            TextField(text: Binding(get: { oq.query }, set: { oq.query = $0 }), prompt: Text(verbatim: L.placeholder)) {
                Text(verbatim: L.placeholder)
            }
            .textFieldStyle(.plain)
            .font(.system(size: CGFloat(L.queryFontSize)))
            .foregroundStyle(Self.color(L.query(dark: dark)))
            .focused($fieldFocused)
            .onSubmit { model.openQuicklySelected() }
            .onKeyPress(.downArrow) { oq.move(by: 1); return .handled }
            .onKeyPress(.upArrow) { oq.move(by: -1); return .handled }
            .onKeyPress(.escape) { oq.close(); return .handled }
            .padding(.leading, CGFloat(L.queryX - L.magnifierX - L.magnifierSize))
            .padding(.trailing, CGFloat(L.separatorInset))
            .shellTarget("open quickly field")
        }
        .frame(height: CGFloat(L.headerHeight))
    }

    func rows(_ oq: ShellOpenQuicklyModel, _ dark: Bool) -> some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(Array(oq.results.enumerated()), id: \.offset) { pair in
                    OpenQuicklyRow(candidate: pair.element, selected: pair.offset == oq.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            oq.select(pair.offset)
                            model.openQuicklySelected()
                        }
                        .onTapGesture { oq.select(pair.offset) }
                        .shellTarget("open quickly row \(pair.offset)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: CGFloat(Double(min(oq.results.count, L.maximumVisibleRows)) * L.rowHeight))
    }
}

/// One result: the glyph in its 24.5 × 20.5 box, the name (its extension
/// dimmed) and under it the project's glyph and the group path (a symbol:
/// its file and line); white on the selection.
struct OpenQuicklyRow: View {
    typealias L = OpenQuicklyLayout
    var candidate: FuzzyMatch.Candidate
    var selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let dark = scheme == .dark
        let ink = selected ? Color.white : c.label
        let dim = selected ? Color.white.opacity(L.selectedExtensionOpacity) : c.secondaryLabel
        let (base, ext) = candidate.kind == .file ? L.splitExtension(candidate.title) : (candidate.title, "")
        let second = selected ? Color.white : c.secondaryLabel
        // Round 10, row 242: the name 17 points bold with its baseline 23
        // below the row's top; the second line 15 points with its baseline
        // at 44.5, the project's mark 12 × 12 4 before the path, a thin
        // chevron between groups (`OpenQuicklyLayout`), as the macOS cell.
        ZStack(alignment: .topLeading) {
            OpenQuicklyGlyph(candidate: candidate, selected: selected)
                .frame(width: CGFloat(L.glyphSize.width), height: CGFloat(L.glyphSize.height))
                .offset(x: CGFloat(L.glyphX), y: CGFloat((L.rowHeight - L.glyphSize.height) / 2))
            HStack(spacing: 0) {
                Text(verbatim: base).foregroundStyle(ink)
                Text(verbatim: ext).foregroundStyle(dim)
            }
            .font(.system(size: CGFloat(L.nameFontSize), weight: .bold))
            .lineLimit(1)
            .frame(maxWidth: CGFloat(L.rowWidth - L.nameX - 12), alignment: .leading)
            .alignmentGuide(.top) { d in d[VerticalAlignment.firstTextBaseline] - CGFloat(L.nameBaseline) }
            .alignmentGuide(.leading) { _ in -CGFloat(L.nameX) }
            .shellTarget("open quickly name \(candidate.title)")
            if candidate.kind == .file, !candidate.groupPath.isEmpty {
                YcodeSmallMark(size: CGFloat(L.breadcrumbGlyphSize))
                    .offset(x: CGFloat(L.nameX), y: CGFloat(L.breadcrumbGlyphCenter - L.breadcrumbGlyphSize / 2))
                OpenQuicklyBreadcrumb(groups: candidate.groupPath, color: second)
                    .alignmentGuide(.top) { d in d[VerticalAlignment.firstTextBaseline] - CGFloat(L.breadcrumbBaseline) }
                    .alignmentGuide(.leading) { _ in -CGFloat(L.nameX + L.breadcrumbGlyphSize + L.breadcrumbGap) }
            } else {
                Text(verbatim: candidate.line.map { "\(candidate.detail):\($0)" } ?? candidate.detail)
                    .font(.system(size: CGFloat(L.breadcrumbFontSize))).foregroundStyle(second).lineLimit(1)
                    .alignmentGuide(.top) { d in d[VerticalAlignment.firstTextBaseline] - CGFloat(L.breadcrumbBaseline) }
                    .alignmentGuide(.leading) { _ in -CGFloat(L.nameX) }
            }
        }
        .frame(width: CGFloat(L.rowWidth), height: CGFloat(L.rowHeight), alignment: .topLeading)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: CGFloat(L.rowCornerRadius), style: .continuous)
                    .fill(OpenQuicklyPanel.color(L.selection(dark: dark)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(candidate.title)
    }
}

/// The result's glyph (council round 9, row 211; group A1's vector glyphs):
/// a file's navigator glyph (`FileGlyphImage`) fitted to the 24.5 × 20.5
/// box in its type's tint, white on the selection
/// (`OpenQuicklyLayout.fileGlyphColor`); a file without one its symbol, a
/// symbol its kind's letter badge.
struct OpenQuicklyGlyph: View {
    var candidate: FuzzyMatch.Candidate
    var selected: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        if candidate.kind == .file, OpenQuicklyLayout.fileGlyph(candidate.title) != nil {
            let tint = OpenQuicklyLayout.fileGlyphColor(candidate.title, selected: selected)
                .map { FileGlyphView.color($0, dark: scheme == .dark) }
            FileGlyphImage(fileName: candidate.title, box: FileGlyphs.openQuicklyBox, tint: tint)
                .shellTarget("open quickly glyph \(candidate.title)")
        } else {
            // A symbol: its kind's letter badge, as the macOS row's.
            let symbol = candidate.kind == .file ? WorkspaceChrome.symbol(kind: .file, name: candidate.title, path: candidate.path)
                : candidate.symbolKind.map { DocumentSymbols.badge($0).lowercased() + ".square.fill" } ?? "f.square.fill"
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(selected ? Color.white : c.secondaryLabel)
        }
    }
}

/// A file result's group path (round 10, row 242): each group in 15-point
/// type, a thin tall chevron 3 × 14 (a 1-point stroke) with 7 of space at
/// each side between two, as the macOS `OpenQuicklyBreadcrumbView`.
struct OpenQuicklyBreadcrumb: View {
    typealias L = OpenQuicklyLayout
    var groups: [String]
    var color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 {
                    Canvas { ctx, _ in
                        let w = CGFloat(L.breadcrumbChevronWidth), h = CGFloat(L.breadcrumbChevronHeight), s = CGFloat(L.breadcrumbChevronStroke)
                        var p = Path()
                        p.move(to: CGPoint(x: s / 2, y: s / 2))
                        p.addLine(to: CGPoint(x: w - s / 2, y: h / 2))
                        p.addLine(to: CGPoint(x: s / 2, y: h - s / 2))
                        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: s, lineCap: .round, lineJoin: .round))
                    }
                    .frame(width: CGFloat(L.breadcrumbChevronWidth), height: CGFloat(L.breadcrumbChevronHeight))
                    // Its centre 6.5 above the baseline (38 against 44.5).
                    .alignmentGuide(.firstTextBaseline) { d in d.height / 2 + CGFloat(L.breadcrumbBaseline - L.breadcrumbChevronCenter) }
                    .padding(.horizontal, CGFloat(L.breadcrumbChevronGap))
                }
                Text(verbatim: pair.element).font(.system(size: CGFloat(L.breadcrumbFontSize))).foregroundStyle(color).lineLimit(1).fixedSize()
            }
        }
        .shellTarget("open quickly breadcrumb")
    }
}
