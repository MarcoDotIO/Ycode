import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Find ▸ Find Call Hierarchy in the Find navigator (`refactoring.md`
/// §Find): the function at the caret, its callers and their callers as a
/// tree, each row a disclosure triangle, the function's letter badge, its
/// name and its file and line; a row opens the declaration.
struct CallHierarchyOutline: View {
    var model: CallHierarchyModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let h = CGFloat(WorkspaceChrome.rowHeight)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { r in
                    HStack(spacing: 0) {
                        Group {
                            if r.isExpandable {
                                Image(systemName: r.isExpanded ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(c.chevron)
                                    .frame(width: 13, height: h)
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.setExpanded(r.id, !r.isExpanded) }
                            } else {
                                Color.clear.frame(width: 13, height: h)
                            }
                        }
                        .padding(.leading, CGFloat(WorkspaceChrome.disclosureX) + CGFloat(WorkspaceChrome.indentationPerLevel) * CGFloat(r.level))
                        SymbolBadge(kind: .function).frame(width: 16, height: h)
                        Text(verbatim: r.name).font(r.level == 0 ? ShellFonts.rowBold : ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                            .padding(.leading, 4)
                        Text(verbatim: r.detail).font(ShellFonts.row).foregroundStyle(c.secondaryLabel).lineLimit(1)
                            .padding(.leading, 6)
                        Spacer(minLength: 6)
                    }
                    .frame(height: h)
                    .background {
                        if model.selection == r.id {
                            RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.rowSelection).padding(.horizontal, 6)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = r.id }
                    .shellTarget("caller \(r.level) \(r.name)")
                }
            }
            .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .shellTarget("call hierarchy")
    }
}
