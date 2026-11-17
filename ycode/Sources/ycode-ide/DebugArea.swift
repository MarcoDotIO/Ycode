import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The debug area (`metrics.md` §7): the variables view and the console
/// side by side (DebugViews.swift), each over a 28-point bottom bar. The
/// console shows the run's output (lldb-dap) with the `(lldb)` prompt under
/// it, and the build log until a run writes there.
struct DebugArea: View {
    @Bindable var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme
    /// The console bar's filter field's text.
    @State private var consoleSearch = ""
    /// Where Activate Console puts the keyboard (P-123).
    enum ConsoleFocus: Hashable { case prompt, output }
    @FocusState private var consoleFocus: ConsoleFocus?

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 0) {
            if model.debug.showsVariables {
                VariablesPane(model: model).frame(minWidth: 150, maxWidth: .infinity)
                if model.debug.showsConsole { Hairline(color: c.separator, vertical: true) }
            }
            if model.debug.showsConsole {
                VStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if showsRunOutput {
                            ConsoleRowsView(model: model, colors: c, search: consoleSearch)   // DebugConsoleRows.swift
                        } else {
                            LogView(lines: shownLines.filter { consoleSearch.isEmpty || $0.localizedCaseInsensitiveContains(consoleSearch) }, colors: c)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .focusable()
                    .focused($consoleFocus, equals: .output)
                    .shellTarget("console output")
                    if model.debug.isDebugging { prompt(c) }
                    // Quick Look, the output options, the filter, Clear and
                    // the halves' toggles, as the AppKit bar (parity §6).
                    bar(c) {
                        QuickLookButton(text: { model.debug.selectedConsoleRowValue?.text ?? shownLines.last { !$0.isEmpty } }, target: "console quick look")
                        ConsoleOptionsMenu(model: model)   // DebugChrome.swift
                        FilterField(text: $consoleSearch, colors: c)
                            .frame(maxWidth: .infinity)
                            .shellTarget("console search")
                        Button { model.clearConsole() } label: {
                            Image(systemName: "trash").font(.system(size: 15)).foregroundStyle(c.barIcon)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Console")
                        .accessibilityLabel("Clear Console")
                        .shellTarget("clear console")
                        DebugHalvesToggles(model: model)
                    }
                }
                .frame(minWidth: 150, maxWidth: .infinity)
                .shellTarget("debug pane")
            }
        }
        .background(c.debugPane)
        .shellTarget("debug area")
        .onAppear { takeConsoleFocus() }
        .onChange(of: model.consoleFocusPending) { _, _ in takeConsoleFocus() }
    }

    /// Activate Console (⇧⌘C): the lldb prompt during a debug session,
    /// else the console's output, takes the keyboard from the editor.
    func takeConsoleFocus() {
        guard model.consoleFocusPending else { return }
        model.consoleFocusPending = false
        let target: ConsoleFocus = model.debug.isDebugging ? .prompt : .output
        // After the pass that shows the debug area (the editor asks for the
        // keyboard again as it is laid out anew; the later request wins),
        // and as a fresh request: the focus follows a binding that changes.
        Task { @MainActor in
            if consoleFocus != nil {
                consoleFocus = nil
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            consoleFocus = target
        }
    }

    /// The `(lldb)` command line (as `ConsolePrompt`, with the focus
    /// Activate Console moves into it).
    func prompt(_ c: ShellColors) -> some View {
        let d = model.debug
        return HStack(spacing: 6) {
            Text(verbatim: "(lldb)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(c.secondaryLabel)
            TextField("", text: Binding(get: { d.consoleInput }, set: { d.consoleInput = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { d.submitConsoleLine() }
                .onKeyPress(.upArrow) { d.consoleHistory(older: true); return .handled }
                .onKeyPress(.downArrow) { d.consoleHistory(older: false); return .handled }
                .focused($consoleFocus, equals: .prompt)
                .shellTarget("console input")
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }

    /// Whether the console shows the run's output (rows that can be
    /// selected and copied) rather than the build log.
    var showsRunOutput: Bool {
        let console = model.debug.consoleFilter == .all ? model.console : model.debug.consoleText
        return !console.isEmpty && (model.debugPane == .console || model.buildLog.isEmpty)
    }

    /// The console's lines: the run's output; the build log before a run.
    var shownLines: [String] {
        let console = (model.debug.consoleFilter == .all ? model.console : model.debug.consoleText).replacingOccurrences(of: "\r", with: "")
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
