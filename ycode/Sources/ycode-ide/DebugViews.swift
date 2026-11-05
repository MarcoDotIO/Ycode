import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// The debugger's views (`specs/ide/debug.md`, `reference-ui-4.md` §5–§6,
// `reference-ui-2.md` §9): the Debug and Breakpoint navigators, the debug
// bar's controls, the variables view and the console's prompt and bar.
// Their state is `ShellDebugModel`'s.

/// Breakpoints' blue (the AppKit IDE's `Theme.breakpointColor`).
enum DebugColors {
    static let breakpoint = Color(.sRGB, red: 0, green: 122 / 255, blue: 1)
    /// The stopped line's band and its annotation (`Theme.currentLineColor`).
    static let pcLine = Color(.sRGB, red: 52 / 255, green: 199 / 255, blue: 89 / 255)
    static let argumentBadge = Color(.sRGB, red: 175 / 255, green: 82 / 255, blue: 222 / 255)
}

// MARK: - Navigators

/// The Debug navigator (⌘7): the process, its gauges, threads and the
/// stopped thread's frames; "No Debug Session" without one.
struct DebugNavigator: View {
    var model: WorkspaceShellModel

    var body: some View {
        let d = model.debug
        let rows = d.debugRows
        if rows.isEmpty {
            EmptyNavigator(lines: NavigatorBars.specs[ShellNavigator.debug.selectorIndex].emptyState)
                .shellTarget("debug navigator empty")
        } else {
            DebugOutline(rows: rows, selection: d.debugSelection, select: { d.selectDebugRow($0) },
                         toggle: { d.setDebugRowExpanded($0, $1) }, target: "debug navigator") { row in
                if row.kind == .process {
                    HStack(spacing: 8) {
                        Button { d.perform(.pauseOrContinue) } label: { BarIcon(d.isPaused ? "play" : "pause", size: 11) }
                            .buttonStyle(.plain).help(d.isPaused ? "Continue the process" : "Pause the process")
                        Button { model.perform(.stop) } label: { BarIcon("stop", size: 11) }
                            .buttonStyle(.plain).help("Stop the process")
                    }
                }
            }
        }
    }
}

/// The Breakpoint navigator (⌘8): the project, the files and their
/// breakpoints with their IDs and enabled markers; "No Breakpoints".
struct BreakpointNavigator: View {
    var model: WorkspaceShellModel

    var body: some View {
        let d = model.debug
        let rows = d.breakpointRows
        if rows.isEmpty {
            EmptyNavigator(lines: NavigatorBars.specs[ShellNavigator.breakpoints.selectorIndex].emptyState)
                .shellTarget("breakpoint navigator empty")
        } else {
            DebugOutline(rows: rows, selection: d.breakpointSelection, select: { d.selectBreakpointRow($0) },
                         toggle: { d.setBreakpointRowExpanded($0, $1) }, target: "breakpoint navigator",
                         contextMenu: { row in AnyView(BreakpointRowMenuItems(model: model, row: row)) },
                         open: { d.editBreakpointRow($0) },
                         rowFrame: { id, f in d.noteBreakpointRowFrame(id, f) }) { row in
                if let on = row.marker {
                    Button { d.toggleBreakpointEnabled(row.id) } label: {
                        Image(systemName: on ? "tag.fill" : "tag").font(.system(size: 11))
                            .foregroundStyle(on ? DebugColors.breakpoint : Color.gray)
                    }
                    .buttonStyle(.plain)
                    .help("Click to enable or disable the breakpoint")
                    .shellTarget("marker \(row.title)")
                }
            }
        }
    }
}

/// A navigator outline whose rows carry a value at their right end (a
/// gauge's reading, a breakpoint's ID) and, after it, the row's own
/// controls.
struct DebugOutline<Accessory: View>: View {
    var rows: [DebugNavigatorRow]
    var selection: String?
    var select: (String) -> Void
    var toggle: (String, Bool) -> Void
    var target: String
    var contextMenu: ((DebugNavigatorRow) -> AnyView)?
    /// A double-click on a breakpoint row (Edit Breakpoint).
    var open: ((String) -> Void)?
    /// Rows report their window frames (the breakpoint editor's anchor).
    var rowFrame: ((String, CGRect) -> Void)?
    @ViewBuilder var accessory: (DebugNavigatorRow) -> Accessory
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { r in
                    OutlineRowView(row: r.outline, isSelected: r.id == selection, colors: c, toggle: toggle)
                        .overlay(alignment: .leading) { letter(r) }
                        .overlay(alignment: .trailing) { trailing(r, c) }
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if r.kind == .breakpoint { open?(r.id) } }
                        .onTapGesture { if r.kind != .separator && r.kind != .gauge { select(r.id) } }
                        .contextMenu {
                            if let contextMenu, r.kind == .breakpoint { contextMenu(r) }
                        }
                        .background {
                            if let rowFrame, r.kind == .breakpoint { RowFrameReader(id: r.id, report: rowFrame) }
                        }
                        .shellTarget("row \(r.title)")
                }
            }
            .padding(.top, CGFloat(WorkspaceChrome.firstRowGap))
            .padding(.bottom, 8)
        }
        .scrollIndicators(.hidden)
        .shellTarget(target)
    }

    /// A breakpoint's kind letter on its icon (the icon sits after the
    /// disclosure column: `OutlineRowView`'s metrics).
    @ViewBuilder
    func letter(_ r: DebugNavigatorRow) -> some View {
        if let l = r.letter {
            Text(verbatim: l).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                .frame(width: 16, height: CGFloat(WorkspaceChrome.rowHeight))
                .padding(.leading, CGFloat(WorkspaceChrome.disclosureX) + CGFloat(WorkspaceChrome.indentationPerLevel) * CGFloat(r.level) + 13)
                .opacity(r.isDimmed ? 0.55 : 1)
                .allowsHitTesting(false)
        }
    }

    func trailing(_ r: DebugNavigatorRow, _ c: ShellColors) -> some View {
        HStack(spacing: 6) {
            if let fill = r.fill {
                ZStack(alignment: .leading) {
                    Capsule().fill(c.separator).frame(width: 44, height: 6)
                    Capsule().fill(DebugColors.pcLine).frame(width: max(0, 44 * fill), height: 6)
                }
                .help("Energy Impact")
            }
            if let t = r.trailing {
                Text(verbatim: t).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
            }
            accessory(r)
        }
        .padding(.trailing, 12)
        .frame(height: CGFloat(WorkspaceChrome.rowHeight))
    }
}

// MARK: - Debug bar

/// A bar's icon: a symbol in the secondary label color (dimmed when off).
struct BarIcon: View {
    var name: String
    var size: CGFloat
    var color: Color?
    var isEnabled = true
    @Environment(\.colorScheme) private var scheme

    init(_ name: String, size: CGFloat = 13, color: Color? = nil, isEnabled: Bool = true) {
        self.name = name
        self.size = size
        self.color = color
        self.isEnabled = isEnabled
    }

    var body: some View {
        let c = ShellColors(scheme)
        Image(systemName: name).font(.system(size: size))
            .foregroundStyle(color ?? (isEnabled ? c.secondaryLabel : c.tertiaryLabel))
            .frame(width: 20, height: 20)
            .contentShape(Rectangle())
    }
}

/// The debug bar's left part (`reference-ui-4.md` §5.4): the breakpoints
/// toggle; while a session runs, Continue (Pause), Step Over, Step Into
/// and Step Out, then "<process> › Thread n › <index> <function>".
struct DebugBarItems: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        let active = d.breakpoints.isActive
        HStack(spacing: 6) {
            button(active ? "tag.fill" : "tag", color: active ? DebugColors.breakpoint : nil,
                   help: active ? "Deactivate breakpoints" : "Activate breakpoints", target: "bar breakpoints") {
                model.perform(.toggleBreakpointsActive)
            }
            if d.isDebugging {
                button(d.isPaused ? "play" : "pause", help: d.isPaused ? "Continue program execution" : "Pause program execution",
                       target: "bar continue") { model.perform(.pauseOrContinue) }
                button("arrow.turn.down.right", isEnabled: d.isPaused, help: "Step over", target: "bar step over") { model.perform(.stepOver) }
                button("arrow.down.to.line", isEnabled: d.isPaused, help: "Step into", target: "bar step into") { model.perform(.stepInto) }
                button("arrow.up.to.line", isEnabled: d.isPaused, help: "Step out", target: "bar step out") { model.perform(.stepOut) }
                if !d.barPath.isEmpty {
                    Text(verbatim: d.barPath).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
                        .padding(.leading, 6)
                        .shellTarget("bar path")
                }
            }
        }
    }

    func button(_ symbol: String, color: Color? = nil, isEnabled: Bool = true, help: String, target: String,
                action: @escaping () -> Void) -> some View {
        Button(action: action) { BarIcon(symbol, color: color, isEnabled: isEnabled) }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(help)
            .accessibilityLabel(help)
            .shellTarget(target)
    }
}

// MARK: - Variables view

/// The variables view (`reference-ui-4.md` §5.5): "A name: Type = value"
/// rows with disclosure triangles for aggregates, over its bottom bar: the
/// scope pop-up and the filter (`reference-ui-2.md` §9.1).
struct VariablesPane: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        VStack(spacing: 0) {
            ZStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if d.isAddingExpression { NewExpressionRow(model: model, colors: c) }
                        ForEach(d.variableRows) { r in
                            VariableRowView(row: r, isSelected: d.selectedVariable == r.id, colors: c, model: model) { on in d.setVariableExpanded(r, on) }
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { d.selectedVariable = r.id; d.beginEditing(r) }
                                .onTapGesture { d.selectedVariable = r.id }
                                .contextMenu { VariableMenuItems(model: model, row: r) }
                                .shellTarget("variable \(r.id)")
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                if d.isLoadingVariables && d.variableRows.isEmpty {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                // The empty area: Add Expression… only.
                Button("Add Expression…") { d.beginAddingExpression() }.disabled(!d.isPaused)
            }
            HStack(spacing: 8) {
                Menu {
                    ForEach(VariableScope.allCases, id: \.rawValue) { s in
                        Button(s.title) { d.variableScope = s }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(verbatim: d.variableScope.title).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(c.label)
                    }
                    .fixedSize()
                }
                .menuStyle(.borderlessButton)
                .help("Variables scope")
                .shellTarget("variables scope")
                Spacer(minLength: 4)
                FilterField(text: Binding(get: { d.variableFilter }, set: { d.variableFilter = $0 }), colors: c)
                    .frame(maxWidth: 180)
                    .shellTarget("variables filter")
                // With the console hidden its bar's toggles come here.
                if !d.showsConsole { DebugHalvesToggles(model: model) }
            }
            .padding(.horizontal, CGFloat(WorkspaceChrome.bottomBarSideInset))
            .frame(height: CGFloat(WorkspaceChrome.bottomBarHeight))
        }
        .shellTarget("variables view")
        .onAppear { if d.pasteboard == nil { d.pasteboard = LocalDebugPasteboard(model: model) } }
    }
}

/// A variable's context menu (`debug.md` §Variables view depth).
struct VariableMenuItems: View {
    var model: WorkspaceShellModel
    var row: VariableRow

    var body: some View {
        let d = model.debug
        let r = row
        let name = d.expression(of: r)
        Button("Print Description of \"\(name)\"") { d.printDescription(r) }.disabled(!d.isPaused)
        Button("Copy") { d.copy(r) }
        Button("Copy Value") { d.copyValue(r) }
        Divider()
        Button("View Memory of \"\(name)\"") { d.viewMemory(of: r) }.disabled(!d.isPaused || !d.session.canReadMemory)
        if !r.isWatch || r.level > 0 {
            Button("Watch \"\(name)\"") { d.watch(r) }.disabled(d.watchExpressions.contains(name))
        }
        Divider()
        Button("Edit Value…") { d.selectedVariable = r.id; d.beginEditing(r) }.disabled(!d.isPaused || (r.isWatch && r.level == 0))
        Button("Add Expression…") { d.beginAddingExpression() }.disabled(!d.isPaused)
        if r.isWatch && r.level == 0 {
            Button("Delete Expression") { d.deleteWatch(r) }
        }
    }
}

/// Add Expression…'s field at the top of the variables view: Return adds
/// the watch expression, Escape cancels.
struct NewExpressionRow: View {
    var model: WorkspaceShellModel
    var colors: ShellColors
    @FocusState private var focused: Bool

    var body: some View {
        let d = model.debug
        HStack(spacing: 4) {
            Color.clear.frame(width: 12, height: 18).padding(.leading, 6)
            TextField("Expression", text: Binding(get: { d.expressionText }, set: { d.expressionText = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($focused)
                .onSubmit { d.commitExpression() }
                .onKeyPress(.escape) { d.cancelExpression(); return .handled }
                .padding(.horizontal, 3)
                .frame(maxWidth: 320, minHeight: 16, maxHeight: 16)
                .background {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(DebugColors.breakpoint, lineWidth: 1)
                }
                .shellTarget("new expression")
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .onAppear { focused = true }
    }
}

/// Reports a view's window frame as it changes.
struct RowFrameReader: View {
    var id: String
    var report: (String, CGRect) -> Void

    var body: some View {
        GeometryReader { geo in
            let f = geo.frame(in: .global)
            Color.clear.onChange(of: f, initial: true) { _, new in report(id, new) }
        }
    }
}

struct VariableRowView: View {
    var row: VariableRow
    var isSelected: Bool
    var colors: ShellColors
    var model: WorkspaceShellModel?
    var toggle: (Bool) -> Void

    var body: some View {
        let c = colors
        HStack(spacing: 4) {
            Group {
                if row.isExpandable {
                    Button { toggle(!row.isExpanded) } label: {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold)).foregroundStyle(c.chevron)
                            .frame(width: 12, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .shellTarget("disclosure \(row.id)")
                } else {
                    Color.clear.frame(width: 12, height: 18)
                }
            }
            .padding(.leading, 6 + CGFloat(row.level) * 14)
            if let b = row.badge {
                Text(verbatim: b).font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                    .frame(width: 13, height: 13)
                    .background { RoundedRectangle(cornerRadius: 3).fill(b == "A" ? DebugColors.argumentBadge : DebugColors.breakpoint) }
            } else if row.isWatch && row.level == 0 {
                // Watch expressions line up with the badged rows.
                Color.clear.frame(width: 13, height: 13)
            }
            if let d = model?.debug, d.editingVariable == row.id {
                // Edit Value: the value becomes a field (Return sets it).
                (Text(verbatim: row.name).foregroundStyle(c.label)
                    + Text(verbatim: row.type.map { ": \($0)" } ?? "").foregroundStyle(c.secondaryLabel)
                    + Text(verbatim: " = ").foregroundStyle(c.secondaryLabel))
                    .font(.system(size: 11))
                    .lineLimit(1)
                ValueEditField(model: model!)
            } else {
                (Text(verbatim: row.name).foregroundStyle(c.label)
                    + Text(verbatim: row.type.map { ": \($0)" } ?? "").foregroundStyle(c.secondaryLabel)
                    + Text(verbatim: " = ").foregroundStyle(c.secondaryLabel)
                    + Text(verbatim: row.value).foregroundStyle(row.isWatch && row.value == "<unavailable>" ? c.secondaryLabel : c.label))
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 18)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: 4).fill(c.rowSelection).padding(.horizontal, 4) }
        }
    }
}

/// Edit Value's field in a variables row.
struct ValueEditField: View {
    var model: WorkspaceShellModel
    @FocusState private var focused: Bool

    var body: some View {
        let d = model.debug
        TextField("", text: Binding(get: { d.editText }, set: { d.editText = $0 }))
            .textFieldStyle(.plain)
            .font(.system(size: 11))
            .focused($focused)
            .onSubmit { d.commitEditing() }
            .onKeyPress(.escape) { d.cancelEditing(); return .handled }
            .padding(.horizontal, 3)
            .frame(minWidth: 80, maxWidth: 220, minHeight: 16, maxHeight: 16)
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Color.black.opacity(0.001))
                    .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(DebugColors.breakpoint, lineWidth: 1) }
            }
            .onAppear { focused = true }
            .shellTarget("variable value field")
    }
}

/// A bottom bar's filter field: the funnel, the field, flat.
struct FilterField: View {
    @Binding var text: String
    var colors: ShellColors

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(colors.tertiaryLabel)
            TextField("Filter", text: $text).textFieldStyle(.plain).font(ShellFonts.small)
        }
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background { Capsule(style: .continuous).stroke(colors.capsuleStroke, lineWidth: 1) }
    }
}

// MARK: - Console

/// The console's `(lldb)` prompt and input line (`debug.md` §Debug
/// console): Return evaluates the line; ↑ / ↓ walk the history.
struct ConsolePrompt: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        HStack(spacing: 6) {
            Text(verbatim: "(lldb)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(c.secondaryLabel)
            TextField("", text: Binding(get: { d.consoleInput }, set: { d.consoleInput = $0 }))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit { d.submitConsoleLine() }
                .onKeyPress(.upArrow) { d.consoleHistory(older: true); return .handled }
                .onKeyPress(.downArrow) { d.consoleHistory(older: false); return .handled }
                .shellTarget("console input")
        }
        .padding(.horizontal, 6)
        .frame(height: 20)
    }
}

/// The console bar's items before the trash (`reference-ui-2.md` §9.2):
/// the output filter (All, Debugger, Target Output).
struct ConsoleFilterMenu: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        Menu {
            ForEach(ConsoleEntry.Filter.allCases, id: \.rawValue) { f in
                Button(f.rawValue) { d.consoleFilter = f }
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: d.consoleFilter.rawValue).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(c.label)
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .help("Console output")
        .shellTarget("console filter")
    }
}

/// The two toggles at the console bar's end: show or hide the variables
/// view and the console.
struct DebugHalvesToggles: View {
    var model: WorkspaceShellModel

    var body: some View {
        let d = model.debug
        HStack(spacing: 4) {
            Button { if d.showsConsole || !d.showsVariables { d.showsVariables.toggle() } } label: {
                BarIcon("rectangle.lefthalf.inset.filled", size: 12, color: d.showsVariables ? DebugColors.breakpoint : nil)
            }
            .buttonStyle(.plain).help("Show or hide the variables view").shellTarget("toggle variables")
            Button { if d.showsVariables || !d.showsConsole { d.showsConsole.toggle() } } label: {
                BarIcon("rectangle.righthalf.inset.filled", size: 12, color: d.showsConsole ? DebugColors.breakpoint : nil)
            }
            .buttonStyle(.plain).help("Show or hide the console").shellTarget("toggle console")
        }
    }
}
