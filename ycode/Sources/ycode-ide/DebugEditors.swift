import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if !os(Linux)
import AppKit
#endif

// The debugger's editing views (`specs/ide/debug.md` §The Linux IDE): the
// breakpoint editor popover, the breakpoints' context menus and the
// Breakpoint navigator's "+" menu, the disassembly and the memory browser
// over the editor. Their state is `ShellDebugModel`'s
// (ShellDebugModel+Editing.swift).

// MARK: - The breakpoint editor popover

/// The popover over the whole window, its arrow at the breakpoint (the
/// gutter's line or the navigator's row). A click outside it, Escape or
/// Done closes it; changes apply as they are made.
struct BreakpointEditorLayer: View {
    var model: WorkspaceShellModel
    static let width: CGFloat = 448

    var body: some View {
        let d = model.debug
        GeometryReader { geo in
            if let e = d.breakpointEditor, let anchor = e.anchor {
                let origin = geo.frame(in: .global).origin
                let a = anchor.offsetBy(dx: -origin.x, dy: -origin.y)
                let height = estimatedHeight(d)
                let x = min(a.maxX + 9, max(8, geo.size.width - Self.width - 8))
                let y = min(max(8, a.midY - 30), max(8, geo.size.height - height - 8))
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { d.closeBreakpointEditor() }
                    BreakpointEditorCard(model: model)
                        .offset(x: x, y: y)
                    PopoverArrowLeft().fill(PopoverChrome.fill(scheme))
                        .overlay { PopoverArrowLeft().stroke(PopoverChrome.edge(scheme), lineWidth: 1) }
                        .frame(width: 9, height: 18)
                        .offset(x: x - 8, y: a.midY - 9)
                }
            }
        }
        .allowsHitTesting(model.debug.breakpointEditor?.anchor != nil)
    }

    @Environment(\.colorScheme) private var scheme

    func estimatedHeight(_ d: ShellDebugModel) -> CGFloat {
        switch d.breakpointEditor?.target {
        case .line?: 196 + CGFloat(d.editorActions.count) * 62
        default: 130
        }
    }
}

/// The popover's raised surface (as Quick Help's).
enum PopoverChrome {
    static func fill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(.sRGB, red: 0.19, green: 0.19, blue: 0.2) : Color.white
    }
    static func edge(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.14) }
}

/// A triangle pointing left (the popover's arrow beside the gutter).
struct PopoverArrowLeft: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.midY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        return p
    }
}

/// The editor's rows (`debug.md` §Breakpoint editing): for a line
/// breakpoint Condition, Ignore n times before stopping, the actions (Add
/// Action; each with its kind, "+", "−" and its text) and "Automatically
/// continue after evaluating actions"; for a symbolic one Symbol and
/// Condition; for an exception one the kind and Break (On Throw / On Catch).
struct BreakpointEditorCard: View {
    var model: WorkspaceShellModel
    @FocusState private var symbolFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: d.breakpointEditorTitle).font(ShellFonts.rowBold).foregroundStyle(c.label)
                .shellTarget("breakpoint editor title")
            switch d.breakpointEditor?.target {
            case .line?: lineRows(d, c)
            case .symbolic?: symbolicRows(d, c)
            case .exception(let f)?: exceptionRows(d, c, filter: f)
            case nil: EmptyView()
            }
            HStack {
                Spacer()
                Button("Done") { d.closeBreakpointEditor() }
                    .shellTarget("breakpoint editor done")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: BreakpointEditorLayer.width, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(PopoverChrome.fill(scheme))
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.18), radius: 12, y: 4)
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(PopoverChrome.edge(scheme), lineWidth: 1) }
        }
        .onTapGesture {}
        .onKeyPress(.escape) { d.closeBreakpointEditor(); return .handled }
        .onAppear { if d.breakpointEditor?.focusesSymbol == true { symbolFocused = true } }
        .shellTarget("breakpoint editor")
    }

    static let labelWidth: CGFloat = 76

    func label(_ s: String, _ c: ShellColors) -> some View {
        Text(verbatim: s).font(ShellFonts.row).foregroundStyle(c.label)
            .frame(width: Self.labelWidth, alignment: .trailing)
    }

    func field(_ placeholder: String, _ get: @escaping () -> String, _ set: @escaping (String) -> Void, target: String) -> some View {
        TextField(placeholder, text: Binding(get: get, set: set))
            .textFieldStyle(.roundedBorder)
            .font(ShellFonts.editor(12))
            .onSubmit { model.debug.closeBreakpointEditor() }
            .onKeyPress(.escape) { model.debug.closeBreakpointEditor(); return .handled }
            .shellTarget(target)
    }

    @ViewBuilder
    func lineRows(_ d: ShellDebugModel, _ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            label("Condition", c)
            field("", { d.editorCondition }, { d.editorCondition = $0 }, target: "breakpoint condition")
        }
        HStack(spacing: 8) {
            label("Ignore", c)
            field("", { d.editorIgnoreCount }, { d.editorIgnoreCount = $0 }, target: "breakpoint ignore")
                .frame(width: 48)
            Text("times before stopping").font(ShellFonts.row).foregroundStyle(c.label)
            Spacer(minLength: 0)
        }
        HStack(alignment: .top, spacing: 8) {
            label("Action", c).padding(.top, 3)
            VStack(alignment: .leading, spacing: 8) {
                if d.editorActions.isEmpty {
                    Button("Add Action") { d.addBreakpointAction() }
                        .shellTarget("breakpoint add action")
                }
                ForEach(Array(d.editorActions.enumerated()), id: \.offset) { pair in
                    actionRow(pair.offset, pair.element, d, c)
                }
            }
        }
        HStack(spacing: 8) {
            label("Options", c)
            Toggle("Automatically continue after evaluating actions",
                   isOn: Binding(get: { d.editorAutoContinue }, set: { d.editorAutoContinue = $0 }))
                .toggleStyle(.checkbox)
                .font(ShellFonts.row)
                .shellTarget("breakpoint auto continue")
        }
    }

    @ViewBuilder
    func actionRow(_ i: Int, _ a: BreakpointStore.BreakpointAction, _ d: ShellDebugModel, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                PopUpMenu(title: BreakpointActionKind(a).rawValue, colors: c) {
                    ForEach(BreakpointActionKind.available, id: \.rawValue) { k in
                        Button(k.rawValue) { d.setBreakpointActionKind(k, at: i) }
                    }
                }
                .shellTarget("breakpoint action kind \(i)")
                Spacer(minLength: 4)
                Button { d.addBreakpointAction(after: i) } label: { BarIcon("plus.circle", size: 13) }
                    .buttonStyle(.plain).help("Add an action after this one").shellTarget("breakpoint action add \(i)")
                Button { d.removeBreakpointAction(at: i) } label: { BarIcon("minus.circle", size: 13) }
                    .buttonStyle(.plain).help("Remove this action").shellTarget("breakpoint action remove \(i)")
            }
            switch a {
            case .log(let m):
                field("Message", { m }, { d.setBreakpointActionText($0, at: i) }, target: "breakpoint action text \(i)")
                Text(verbatim: "@exp@ = expression    %B = breakpoint name    %H = hit count")
                    .font(ShellFonts.mini).foregroundStyle(c.secondaryLabel)
            case .debuggerCommand(let command):
                field("Debugger command", { command }, { d.setBreakpointActionText($0, at: i) }, target: "breakpoint action text \(i)")
            case .sound(let name):
                PopUpMenu(title: name.isEmpty ? "None" : name, colors: c) {
                    ForEach(BreakpointSound.names, id: \.self) { n in
                        Button(n) { d.setBreakpointActionText(n, at: i); BreakpointSound.play(n) }
                    }
                }
                .shellTarget("breakpoint action sound \(i)")
            }
        }
    }

    @ViewBuilder
    func symbolicRows(_ d: ShellDebugModel, _ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            label("Symbol", c)
            TextField("Function or method name", text: Binding(get: { d.editorSymbol }, set: { d.editorSymbol = $0 }))
                .textFieldStyle(.roundedBorder)
                .font(ShellFonts.editor(12))
                .focused($symbolFocused)
                .onSubmit { d.closeBreakpointEditor() }
                .onKeyPress(.escape) { d.closeBreakpointEditor(); return .handled }
                .shellTarget("breakpoint symbol")
        }
        HStack(spacing: 8) {
            label("Condition", c)
            field("", { d.editorCondition }, { d.editorCondition = $0 }, target: "breakpoint condition")
        }
    }

    @ViewBuilder
    func exceptionRows(_ d: ShellDebugModel, _ c: ShellColors, filter: String) -> some View {
        HStack(spacing: 8) {
            label("Exception", c)
            Text(verbatim: filter.hasPrefix("swift_") ? "Swift" : filter.hasPrefix("objc_") ? "Objective-C" : "C++")
                .font(ShellFonts.row).foregroundStyle(c.label)
        }
        HStack(spacing: 8) {
            label("Break", c)
            PopUpMenu(title: d.editorBreaksOnCatch ? "On Catch" : "On Throw", colors: c) {
                Button("On Throw") { d.editorBreaksOnCatch = false }
                Button("On Catch") { d.editorBreaksOnCatch = true }
            }
            .shellTarget("breakpoint break")
        }
    }
}

/// A pop-up button: its title and the up-down chevron in a rounded box.
struct PopUpMenu<Items: View>: View {
    var title: String
    var colors: ShellColors
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu { items() } label: {
            HStack(spacing: 6) {
                Text(verbatim: title).font(ShellFonts.row).foregroundStyle(colors.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(colors.label)
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(colors.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(colors.fieldStroke, lineWidth: 1) }
            }
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Context menus and the "+" menu

/// A breakpoint's context menu in the gutter: Edit Breakpoint…, Disable
/// (Enable) Breakpoint, Delete Breakpoint, Reveal in Breakpoint Navigator.
struct BreakpointMenuItems: View {
    var model: WorkspaceShellModel
    var breakpoint: BreakpointStore.Breakpoint
    let controller: SourceEditorController

    var body: some View {
        let d = model.debug
        let b = breakpoint
        Button("Edit Breakpoint…") { d.editBreakpoint(file: b.file, line: b.line, anchor: DebugGutter.anchor(controller, line: b.line)) }
        Button(b.isEnabled ? "Disable Breakpoint" : "Enable Breakpoint") { d.session.breakpoints.toggleEnabled(file: b.file, line: b.line) }
        Button("Delete Breakpoint") { d.session.breakpoints.remove(file: b.file, line: b.line) }
        Divider()
        Button("Reveal in Breakpoint Navigator") { d.revealInBreakpointNavigator(file: b.file, line: b.line) }
    }
}

/// A Breakpoint navigator row's context menu.
struct BreakpointRowMenuItems: View {
    var model: WorkspaceShellModel
    var row: DebugNavigatorRow

    var body: some View {
        let d = model.debug
        if row.kind == .breakpoint {
            Button("Edit Breakpoint…") { d.editBreakpointRow(row.id) }
            if let on = row.marker {
                Button(on ? "Disable Breakpoint" : "Enable Breakpoint") { d.toggleBreakpointEnabled(row.id) }
            }
            Button("Delete Breakpoint") { d.deleteBreakpoint(row.id) }
        }
    }
}

/// The Breakpoint navigator's "+" menu (`debug.md` §Breakpoint editing):
/// the kinds this computer can stop on. The others (Runtime Issue,
/// Constraint Error, Test Failure) need Apple's runtimes.
struct BreakpointAddMenuItems: View {
    var model: WorkspaceShellModel

    var body: some View {
        let d = model.debug
        Button("Swift Error Breakpoint") { d.addSwiftErrorBreakpoint() }
            .disabled(d.breakpoints.exceptionFilters.contains("swift_throw"))
        Button("Exception Breakpoint…") { d.addExceptionBreakpoint() }
        Button("Symbolic Breakpoint…") { d.addSymbolicBreakpoint() }
    }
}

// MARK: - Over the editor: disassembly and memory

/// What covers the source editor while the debugger shows something else:
/// the memory browser (View Memory) or the disassembly (Always Show
/// Disassembly).
struct DebugEditorOverlay: View {
    var model: WorkspaceShellModel

    var body: some View {
        let d = model.debug
        if d.memoryBrowser != nil {
            MemoryBrowserView(model: model)
        } else if d.showsDisassembly {
            DisassemblyView(model: model)
        }
    }
}

/// The selected frame's instructions, read-only, the program counter's
/// line marked as the stopped line (`debug.md` §Disassembly).
struct DisassemblyView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        let lines = d.disassemblyLines
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                Text(verbatim: d.disassemblyTitle).font(ShellFonts.small).foregroundStyle(c.label)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            Hairline(color: c.separator, vertical: false)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { pair in
                        let pc = pair.offset == d.disassemblyPCIndex
                        HStack(spacing: 0) {
                            Rectangle().fill(pc ? DebugColors.pcLine.opacity(0.9) : Color.clear).frame(width: 3)
                            Text(verbatim: pair.element).font(ShellFonts.editor(12)).foregroundStyle(c.label).lineLimit(1)
                                .padding(.leading, 10)
                            Spacer(minLength: 0)
                        }
                        .frame(height: 17)
                        .background(pc ? DebugColors.pcLine.opacity(0.25) : Color.clear)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .background(c.content)
        .shellTarget("disassembly")
    }
}

/// View Memory's browser: the address field, Previous / Next Page, and
/// 16 bytes a line (address, hex in two groups, ASCII).
struct MemoryBrowserView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = model.debug
        let m = d.memoryBrowser ?? MemoryBrowserState()
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                Text(verbatim: m.title).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                Spacer(minLength: 8)
                Text("Address").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                TextField("Address or expression", text: Binding(get: { d.memoryBrowser?.addressText ?? "" },
                                                               set: { d.memoryBrowser?.addressText = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(ShellFonts.editor(11))
                    .frame(width: 200)
                    .onSubmit { d.loadMemory() }
                    .shellTarget("memory address")
                Button { d.pageMemory(forward: false) } label: { BarIcon("chevron.left", size: 11, isEnabled: m.block != nil) }
                    .buttonStyle(.plain).help("Previous Page").disabled(m.block == nil).shellTarget("memory previous")
                Button { d.pageMemory(forward: true) } label: { BarIcon("chevron.right", size: 11, isEnabled: m.block != nil) }
                    .buttonStyle(.plain).help("Next Page").disabled(m.block == nil).shellTarget("memory next")
                Button { d.closeMemoryBrowser() } label: { BarIcon("xmark", size: 10) }
                    .buttonStyle(.plain).help("Close the memory browser").shellTarget("memory close")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            Hairline(color: c.separator, vertical: false)
            if let message = m.message {
                Text(verbatim: message).font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(m.lines.enumerated()), id: \.offset) { pair in
                            let l = pair.element
                            HStack(spacing: 18) {
                                Text(verbatim: l.address).foregroundStyle(c.secondaryLabel)
                                Text(verbatim: l.hex).foregroundStyle(c.label)
                                Text(verbatim: l.ascii).foregroundStyle(c.label)
                                Spacer(minLength: 0)
                            }
                            .font(ShellFonts.editor(12))
                            .lineLimit(1)
                            .frame(height: 17)
                            .padding(.leading, 12)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(c.content)
        .shellTarget("memory browser")
    }
}

// MARK: - The clipboard

/// Copy and Copy Value go through the shell's one clipboard path
/// (`ShellPasteboard`: OpenViews' clipboard on Linux, AppKit's on macOS).
@MainActor
final class LocalDebugPasteboard: DebugPasteboard {
    weak var model: WorkspaceShellModel?
    init(model: WorkspaceShellModel) { self.model = model }

    func setString(_ s: String) { ShellPasteboard.copy(s) }
}
