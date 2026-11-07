import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The console while it shows the run's output: its rows (one per line,
/// `ConsoleRows`), newest at the bottom and kept scrolled to the end. A
/// click selects a row; its menu has the Debug ▸ Console ▸ Copy Row items
/// (the macOS IDE's console rows, `debug.md`).
struct ConsoleRowsView: View {
    var model: WorkspaceShellModel
    let colors: ShellColors
    /// The console bar's filter: only rows containing it.
    var search = ""

    var body: some View {
        let d = model.debug
        // The session's entries are not observed; the console's text and
        // the filter are, and change with them.
        let rows = model.console.isEmpty && d.consoleText.isEmpty ? [] : d.consoleRows
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()).filter { search.isEmpty || $0.element.text.localizedCaseInsensitiveContains(search) }, id: \.offset) { pair in
                        let text = pair.element.text.replacingOccurrences(of: "\r", with: "")
                        Text(verbatim: text.isEmpty ? " " : text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(colors.label)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .background {
                                if d.selectedConsoleRow == pair.offset {
                                    Rectangle().fill(colors.rowSelection.opacity(0.6))
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { d.selectedConsoleRow = pair.offset }
                            .contextMenu {
                                Button("Copy Row with Visible Metadata") { copy(pair.offset, .visibleMetadata) }
                                Button("Copy Row with All Metadata") { copy(pair.offset, .allMetadata) }
                                Button("Copy Row without Metadata") { copy(pair.offset, .withoutMetadata) }
                            }
                            .id(pair.offset)
                            .shellTarget("console row \(pair.offset)")
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: rows.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A row's menu acts on that row (it becomes the selection).
    func copy(_ row: Int, _ kind: ShellDebugModel.ConsoleRowCopy) {
        model.debug.selectedConsoleRow = row
        model.debug.copyConsoleRow(kind)
    }
}
