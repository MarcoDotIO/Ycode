import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The debug area (`metrics.md` §7): the console over a 28-point bottom bar.
/// The variables view comes with L3 and has no column until then; the
/// console shows the run's output (lldb-dap), and the build log until a run
/// writes there.
struct DebugArea: View {
    @Bindable var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Group {
            VStack(spacing: 0) {
                LogView(lines: shownLines, colors: c)
                bar(c) {
                    Spacer(minLength: 0)
                    Button { model.clearConsole() } label: {
                        Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                    }
                    .buttonStyle(.plain)
                    .help("Clear Console")
                    .accessibilityLabel("Clear Console")
                    .shellTarget("clear console")
                }
            }
            .frame(minWidth: 150, maxWidth: .infinity)
            .shellTarget("debug pane")
        }
        .background(c.content)
        .shellTarget("debug area")
    }

    /// The console's lines: the run's output; the build log before a run.
    var shownLines: [String] {
        let console = model.console.replacingOccurrences(of: "\r", with: "")
        if model.debugPane == .console && !console.isEmpty || model.buildLog.isEmpty {
            return console.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        }
        return model.buildLog
    }

    func bar<C: View>(_ c: ShellColors, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) { content() }
            .padding(.horizontal, CGFloat(WorkspaceChrome.bottomBarSideInset))
            .frame(height: CGFloat(WorkspaceChrome.bottomBarHeight))
    }

}

/// Lines of output, newest at the bottom, kept scrolled to the end (the
/// console font: 11-point monospaced).
struct LogView: View {
    let lines: [String]
    let colors: ShellColors

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                        Text(verbatim: pair.element.isEmpty ? " " : pair.element)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(colors.label)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(pair.offset)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.hidden)
            .onChange(of: lines.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
