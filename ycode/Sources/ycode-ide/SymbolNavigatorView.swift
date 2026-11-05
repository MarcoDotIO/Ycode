import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The Symbol navigator (⌘3): files with their declarations nested, each
/// with its letter badge (`SymbolBadge`), drawn with the outline metrics of
/// `WorkspaceChrome` (22-point rows, 12 points per level, the triangle at
/// x 12, the badge at x 25, the name at x 45). Selecting a declaration
/// opens its line; the bottom bar filters by name.
struct SymbolNavigator: View {
    @Bindable var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let s = model.symbols
        let rows = s.rows
        Group {
            if rows.isEmpty {
                EmptyNavigator(lines: s.isScanning ? ["Reading Symbols…"]
                               : (s.filterText.isEmpty ? ["No Symbols"] : ["No Symbols", "No declaration contains “\(s.filterText)”."]))
                    .shellTarget("symbols empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { r in
                            SymbolRowView(row: r, isSelected: r.id == s.selection, colors: c) { id, on in s.setExpanded(id, on) }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if r.line == nil { s.setExpanded(r.id, !r.isExpanded); s.selection = r.id } else { model.openSymbolRow(r) }
                                }
                                .shellTarget("symbol row \(r.title)")
                        }
                    }
                    .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .shellTarget("symbol navigator")
            }
        }
        .onAppear { model.refreshSymbolNavigator() }
    }
}

struct SymbolRowView: View {
    var row: SymbolNavigatorRow
    var isSelected: Bool
    var colors: ShellColors
    var toggle: (String, Bool) -> Void

    var body: some View {
        let c = colors
        let h = CGFloat(WorkspaceChrome.rowHeight)
        HStack(spacing: 0) {
            Group {
                if row.isExpandable {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(c.chevron)
                        .frame(width: 13, height: h)
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(row.id, !row.isExpanded) }
                } else {
                    Color.clear.frame(width: 13, height: h)
                }
            }
            .padding(.leading, CGFloat(WorkspaceChrome.disclosureX) + CGFloat(WorkspaceChrome.indentationPerLevel) * CGFloat(row.level))
            Group {
                if let k = row.kind {
                    SymbolBadge(kind: k)
                } else {
                    Image(systemName: WorkspaceChrome.fileSymbol(row.title)).font(.system(size: 13)).foregroundStyle(c.accent)
                }
            }
            .frame(width: 16, height: h)
            Text(verbatim: row.kind == nil ? WorkspaceChrome.jumpBarFileTitle(row.title, hideExtension: false) : row.title)
                .font(row.kind == nil ? ShellFonts.rowBold : ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                .padding(.leading, 4)
            Spacer(minLength: 6)
        }
        .frame(height: h)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.rowSelection).padding(.horizontal, 6)
            }
        }
    }
}

/// The Symbol navigator's bottom bar: the other navigators' filter capsule
/// (`NavigatorFilterBar`: the filter options glyph with its chevron, the
/// field, the same insets and outline), with a working field and a clear
/// button. It has no "+" (there is nothing to add), as the Find navigator.
struct SymbolFilterBar: View {
    @Bindable var symbols: SymbolNavigatorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(c.tertiaryLabel)
            TextField("Filter", text: $symbols.filterText)
                .textFieldStyle(.plain)
                .font(ShellFonts.row)
                .shellTarget("symbol filter")
            if !symbols.filterText.isEmpty {
                Button { symbols.filterText = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 9)
        .frame(height: CGFloat(WorkspaceChrome.filterBarHeight))
        .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
        .padding(.horizontal, CGFloat(WorkspaceChrome.selectorInset))
        .padding(.bottom, CGFloat(WorkspaceChrome.filterBarBottomInset))
        .padding(.top, 4)
    }
}
