import Foundation
import YcodeDebug
import YcodeIDECore

// The debugger's editing gestures in the Linux IDE (`specs/ide/debug.md`
// §The Linux IDE): the breakpoint editor popover, the Breakpoint
// navigator's "+" menu, watch expressions, Edit Value, Copy, View Memory
// and Debug ▸ Debug Workflow. No toolkit types.

/// The breakpoint editor popover: which breakpoint it edits and where it
/// points.
public struct BreakpointEditorState: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case line(file: String, line: Int)
        case symbolic(index: Int)
        case exception(filter: String)
    }
    public var target: Target
    /// What the popover's arrow points at, in window points (nil until the
    /// navigator row it belongs to has been laid out).
    public var anchor: CGRect?
    /// The Breakpoint navigator row it was opened from (the row reports
    /// its frame as the anchor).
    public var rowID: String?
    /// A new symbolic breakpoint: the Symbol field takes the keyboard.
    public var focusesSymbol = false

    public init(target: Target, anchor: CGRect? = nil, rowID: String? = nil) {
        self.target = target
        self.anchor = anchor
        self.rowID = rowID
    }
}

/// The kinds the breakpoint editor's Action pop-up offers.
public enum BreakpointActionKind: String, CaseIterable, Sendable {
    case log = "Log Message"
    case command = "Debugger Command"
    case sound = "Sound"

    public init(_ a: BreakpointStore.BreakpointAction) {
        switch a {
        case .log: self = .log
        case .debuggerCommand: self = .command
        case .sound: self = .sound
        }
    }

    /// The kinds this computer can run (Sound only with sounds to play).
    public static var available: [BreakpointActionKind] {
        BreakpointSound.names.isEmpty ? [.log, .command] : allCases
    }
}

/// The copy target of Copy and Copy Value (the toolkit's clipboard).
@MainActor
public protocol DebugPasteboard: AnyObject {
    func setString(_ s: String)
}

/// View Memory's browser: an address, and the bytes read there.
public struct MemoryBrowserState: Equatable, Sendable {
    /// Bytes per page (Previous / Next Page move by it).
    public static let pageSize = 256
    public static let bytesPerLine = 16
    public var addressText: String
    public var block: MemoryBlock?
    /// Why nothing is shown ("Memory could not be read").
    public var message: String?
    public var title: String

    public init(addressText: String = "", title: String = "Memory") {
        self.addressText = addressText
        self.title = title
    }

    /// One line: the address, 16 bytes in hex (two groups of eight) and
    /// the printable ASCII characters ("." for the others); "??" for bytes
    /// that could not be read.
    public struct Line: Equatable, Sendable {
        public var address: String
        public var hex: String
        public var ascii: String
    }

    public var lines: [Line] {
        guard let b = block else { return [] }
        let total = b.bytes.count + b.unreadable
        return stride(from: 0, to: total, by: Self.bytesPerLine).map { start in
            var hex: [String] = []
            var ascii = ""
            for i in start..<min(start + Self.bytesPerLine, total) {
                if i < b.bytes.count {
                    let v = b.bytes[i]
                    hex.append(String(format: "%02x", v))
                    ascii.append(v >= 0x20 && v < 0x7f ? Character(UnicodeScalar(v)) : ".")
                } else {
                    hex.append("??")
                    ascii.append(" ")
                }
            }
            let left = hex.prefix(8).joined(separator: " "), right = hex.dropFirst(8).joined(separator: " ")
            return Line(address: String(format: "0x%016llx", b.address + UInt64(start)), hex: right.isEmpty ? left : left + "  " + right,
                        ascii: ascii)
        }
    }
}

extension ShellDebugModel {
    // MARK: Breakpoint editor

    /// Edit Breakpoint… on a line's breakpoint (double-click or ⌘-click in
    /// the gutter, its context menu, the navigator's).
    public func editBreakpoint(file: String, line: Int, anchor: CGRect?, rowID: String? = nil) {
        guard breakpoints.breakpoint(file: file, line: line) != nil else { return }
        breakpointEditor = BreakpointEditorState(target: .line(file: file, line: line), anchor: anchor, rowID: rowID)
    }

    /// Edit Breakpoint… from a Breakpoint navigator row.
    public func editBreakpointRow(_ id: String) {
        if let loc = breakpointRows.first(where: { $0.id == id })?.location {
            editBreakpoint(file: loc.file, line: loc.line, anchor: nil, rowID: id)
        } else if id.hasPrefix("symbolic:"), let i = Int(id.dropFirst("symbolic:".count)), breakpoints.symbolic.indices.contains(i) {
            breakpointEditor = BreakpointEditorState(target: .symbolic(index: i), rowID: id)
        } else if id.hasPrefix("exception:") {
            breakpointEditor = BreakpointEditorState(target: .exception(filter: String(id.dropFirst("exception:".count))), rowID: id)
        }
    }

    /// The popover closed (Done, Escape, a click elsewhere): a symbolic
    /// breakpoint left without a symbol is removed.
    public func closeBreakpointEditor() {
        if case .symbolic(let i)? = breakpointEditor?.target, breakpoints.symbolic.indices.contains(i),
           breakpoints.symbolic[i].name.trimmingCharacters(in: .whitespaces).isEmpty {
            session.breakpoints.symbolic.remove(at: i)
        }
        breakpointEditor = nil
    }

    /// A navigator row's frame (window points): the anchor of the popover
    /// opened from it.
    public func noteBreakpointRowFrame(_ id: String, _ frame: CGRect) {
        guard breakpointEditor?.rowID == id, breakpointEditor?.anchor != frame else { return }
        breakpointEditor?.anchor = frame
    }

    /// The line breakpoint being edited.
    public var editedBreakpoint: BreakpointStore.Breakpoint? {
        guard case .line(let file, let line)? = breakpointEditor?.target else { return nil }
        return breakpoints.breakpoint(file: file, line: line)
    }

    /// The popover's title: "main.swift:12", the symbol, or the exception kind.
    public var breakpointEditorTitle: String {
        switch breakpointEditor?.target {
        case .line(let file, let line)?: return "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        case .symbolic?: return "Symbolic Breakpoint"
        case .exception(let f)?: return f.hasPrefix("swift_") ? "Swift Error Breakpoint" : "Exception Breakpoint"
        case nil: return ""
        }
    }

    private func editLine(_ change: (inout BreakpointStore.Breakpoint) -> Void) {
        guard case .line(let file, let line)? = breakpointEditor?.target else { return }
        session.breakpoints.edit(file: file, line: line, change)
    }

    /// The Condition field (a line or symbolic breakpoint).
    public var editorCondition: String {
        get {
            switch breakpointEditor?.target {
            case .line?: editedBreakpoint?.condition ?? ""
            case .symbolic(let i)? where breakpoints.symbolic.indices.contains(i): breakpoints.symbolic[i].condition
            default: ""
            }
        }
        set {
            // Kept as typed (a trailing space is part of typing "a == 3").
            let v = newValue.trimmingCharacters(in: .whitespaces).isEmpty ? "" : newValue
            switch breakpointEditor?.target {
            case .line?: editLine { $0.condition = v }
            case .symbolic(let i)? where breakpoints.symbolic.indices.contains(i): session.breakpoints.symbolic[i].condition = v
            default: break
            }
        }
    }

    /// "Ignore [n] times before stopping".
    public var editorIgnoreCount: String {
        get { editedBreakpoint.map { String($0.ignoreCount) } ?? "0" }
        set { editLine { $0.ignoreCount = max(0, Int(newValue.filter(\.isNumber).prefix(9)) ?? 0) } }
    }

    /// "Automatically continue after evaluating actions".
    public var editorAutoContinue: Bool {
        get { editedBreakpoint?.autoContinue ?? false }
        set { editLine { $0.autoContinue = newValue } }
    }

    /// The line breakpoint's actions, in order.
    public var editorActions: [BreakpointStore.BreakpointAction] { editedBreakpoint?.actions ?? [] }

    /// Add Action, or "+" after an action: a new Log Message action.
    public func addBreakpointAction(after index: Int? = nil) {
        editLine { b in
            let at = index.map { min($0 + 1, b.actions.count) } ?? b.actions.count
            b.actions.insert(.log(""), at: at)
        }
    }

    /// "−" beside an action.
    public func removeBreakpointAction(at index: Int) {
        editLine { if $0.actions.indices.contains(index) { $0.actions.remove(at: index) } }
    }

    /// The action's pop-up: a new kind keeps the text between a log
    /// message and a command; a sound starts with the first one.
    public func setBreakpointActionKind(_ kind: BreakpointActionKind, at index: Int) {
        editLine { b in
            guard b.actions.indices.contains(index), BreakpointActionKind(b.actions[index]) != kind else { return }
            let text: String
            switch b.actions[index] {
            case .log(let t), .debuggerCommand(let t): text = t
            case .sound: text = ""
            }
            switch kind {
            case .log: b.actions[index] = .log(text)
            case .command: b.actions[index] = .debuggerCommand(text)
            case .sound: b.actions[index] = .sound(BreakpointSound.names.first ?? "")
            }
        }
    }

    /// The action's text: the message, the command or the sound's name.
    public func setBreakpointActionText(_ text: String, at index: Int) {
        editLine { b in
            guard b.actions.indices.contains(index) else { return }
            switch b.actions[index] {
            case .log: b.actions[index] = .log(text)
            case .debuggerCommand: b.actions[index] = .debuggerCommand(text)
            case .sound: b.actions[index] = .sound(text)
            }
        }
    }

    /// The symbolic breakpoint's Symbol field.
    public var editorSymbol: String {
        get {
            guard case .symbolic(let i)? = breakpointEditor?.target, breakpoints.symbolic.indices.contains(i) else { return "" }
            return breakpoints.symbolic[i].name
        }
        set {
            guard case .symbolic(let i)? = breakpointEditor?.target, breakpoints.symbolic.indices.contains(i) else { return }
            session.breakpoints.symbolic[i].name = newValue.trimmingCharacters(in: .whitespaces).isEmpty ? "" : newValue
        }
    }

    /// The exception breakpoint's Break pop-up: On Throw or On Catch.
    public var editorBreaksOnCatch: Bool {
        get {
            guard case .exception(let f)? = breakpointEditor?.target else { return false }
            return f.hasSuffix("_catch")
        }
        set {
            guard case .exception(let f)? = breakpointEditor?.target, f.hasSuffix("_catch") != newValue,
                  let i = breakpoints.exceptionFilters.firstIndex(of: f) else { return }
            let base = f.split(separator: "_").first.map(String.init) ?? f
            let next = base + (newValue ? "_catch" : "_throw")
            if breakpoints.exceptionFilters.contains(next) {
                session.breakpoints.exceptionFilters.remove(at: i)
            } else {
                session.breakpoints.exceptionFilters[i] = next
            }
            breakpointEditor?.target = .exception(filter: next)
            breakpointEditor?.rowID = "exception:\(next)"
        }
    }

    // MARK: The "+" menu and Debug ▸ Breakpoints

    /// The exception filters Exception Breakpoint adds: C++ throws on
    /// Linux (Objective-C runs only on Apple platforms).
    public static var exceptionFilters: [String] {
        #if os(Linux)
        ["cpp_throw"]
        #else
        ["objc_throw", "cpp_throw"]
        #endif
    }

    /// Swift Error Breakpoint: stops where a Swift error is thrown.
    public func addSwiftErrorBreakpoint() {
        if !breakpoints.exceptionFilters.contains("swift_throw") { session.breakpoints.exceptionFilters.append("swift_throw") }
        revealBreakpointNavigator()
        breakpointSelection = "exception:swift_throw"
    }

    /// Exception Breakpoint…: adds it and opens its editor.
    public func addExceptionBreakpoint() {
        for f in Self.exceptionFilters where !breakpoints.exceptionFilters.contains(f) { session.breakpoints.exceptionFilters.append(f) }
        revealBreakpointNavigator()
        let id = "exception:\(Self.exceptionFilters.last ?? "cpp_throw")"
        breakpointSelection = id
        editBreakpointRow(id)
    }

    /// Symbolic Breakpoint…: a new row whose editor asks for the symbol.
    public func addSymbolicBreakpoint() {
        session.breakpoints.symbolic.append(.init(name: ""))
        revealBreakpointNavigator()
        let id = "symbolic:\(breakpoints.symbolic.count - 1)"
        breakpointSelection = id
        editBreakpointRow(id)
        breakpointEditor?.focusesSymbol = true
    }

    private func revealBreakpointNavigator() {
        collapsedBreakpointRows.remove("root")
        workspace?.navigator = .breakpoints
        workspace?.isNavigatorShown = true
    }

    /// The gutter's Reveal in Breakpoint Navigator.
    public func revealInBreakpointNavigator(file: String, line: Int) {
        revealBreakpointNavigator()
        collapsedBreakpointRows.remove("file:\(file)")
        breakpointSelection = breakpointRows.first { $0.location?.file == file && $0.location?.line == line }?.id
    }

    /// The breakpoint whose gutter context menu is open (the pointer is on it).
    public func gutterMenuBreakpoint(file: String) -> BreakpointStore.Breakpoint? {
        gutterMenuLine.flatMap { breakpoints.breakpoint(file: file, line: $0) }
    }

    /// The pointer moved in the gutter: the breakpoint line under it, if any.
    public func pointerInGutter(file: String, line: Int?) {
        let next = line.flatMap { breakpoints.breakpoint(file: file, line: $0) != nil ? $0 : nil }
        if next != gutterMenuLine { gutterMenuLine = next }
    }

    // MARK: Variables view

    /// The expression a row shows: "stats.round" for a child, the watch
    /// expression for a watch row.
    public func expression(of row: VariableRow) -> String {
        let parts = row.id.split(separator: "/").map(String.init)
        guard let head = parts.first else { return row.name }
        var base = head
        if head.hasPrefix("watch:"), let i = Int(head.dropFirst("watch:".count)), session.watchExpressions.indices.contains(i) {
            base = session.watchExpressions[i]
        }
        return parts.dropFirst().reduce(base) { path, name in
            // Array elements are listed as "[0]".
            name.hasPrefix("[") ? path + name : path + "." + name
        }
    }

    static func watchRowID(_ i: Int) -> String { "watch:\(i)" }

    /// Watch "<name>": the variable becomes a watch expression (kept for
    /// as long as the workspace is open).
    public func watch(_ row: VariableRow) {
        addWatchExpression(expression(of: row))
    }

    public func addWatchExpression(_ e: String) {
        let t = e.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !session.watchExpressions.contains(t) else { return }
        session.watchExpressions.append(t)
    }

    /// Delete Expression (a watch row).
    public func deleteWatch(_ row: VariableRow) {
        guard let i = row.watchIndex, session.watchExpressions.indices.contains(i) else { return }
        session.watchExpressions.remove(at: i)
        expandedVariables = expandedVariables.filter { !$0.hasPrefix(Self.watchRowID(i)) }
    }

    public var watchExpressions: [String] { session.watchExpressions }

    /// Add Expression…: an empty field at the top of the variables view.
    public func beginAddingExpression() {
        editingVariable = nil
        expressionText = ""
        isAddingExpression = true
    }

    public func commitExpression() {
        isAddingExpression = false
        addWatchExpression(expressionText)
        expressionText = ""
    }

    public func cancelExpression() {
        isAddingExpression = false
        expressionText = ""
    }

    /// Edit Value… (or a double-click): the value becomes a field.
    public func beginEditing(_ row: VariableRow) {
        guard isPaused, !row.isWatch || row.level > 0 else { return }
        isAddingExpression = false
        editingVariable = row.id
        editText = row.value
    }

    public func cancelEditing() { editingVariable = nil }

    /// Return in the field: `setVariable` in the row's container; the view
    /// reloads (expanded aggregates included).
    public func commitEditing() {
        guard let id = editingVariable, let row = variableRows.first(where: { $0.id == id }) else { editingVariable = nil; return }
        editingVariable = nil
        let value = editText.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != row.value else { return }
        let session = session
        let path = expression(of: row)
        Task {
            await session.setValue(value, of: row.name, container: row.container, expression: path)
            reloadExpandedChildren()
        }
    }

    /// Copy: "(Type) name = value", as LLDB prints a variable.
    public func copy(_ row: VariableRow) {
        pasteboard?.setString((row.type.map { "(\($0)) " } ?? "") + "\(row.name) = \(row.value)")
    }

    /// Copy Value: the value's text.
    public func copyValue(_ row: VariableRow) { pasteboard?.setString(row.value) }

    // MARK: View Memory

    /// View Memory (Debug ▸ Debug Workflow, or a variable's context menu):
    /// the browser at the variable's memory, else at the address typed.
    public func viewMemory(of row: VariableRow? = nil) {
        guard let row else {
            if memoryBrowser == nil { memoryBrowser = MemoryBrowserState() }
            return
        }
        let expr = expression(of: row)
        memoryBrowser = MemoryBrowserState(addressText: row.memoryReference ?? expr, title: "Memory of \"\(expr)\"")
        loadMemory()
    }

    /// Reads a page at the address field's address (or expression).
    public func loadMemory(offset: Int = 0) {
        guard let text = memoryBrowser?.addressText, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let session = session
        Task {
            guard let ref = await session.memoryReference(of: text) else {
                memoryBrowser?.block = nil
                memoryBrowser?.message = isPaused ? "“\(text)” is not an address" : "The process is not paused"
                return
            }
            let block = await session.readMemory(ref, offset: offset, count: MemoryBrowserState.pageSize)
            memoryBrowser?.block = block
            memoryBrowser?.message = block == nil ? "Memory could not be read" : nil
            if let b = block { memoryBrowser?.addressText = String(format: "0x%llx", b.address) }
        }
    }

    /// Previous Page / Next Page.
    public func pageMemory(forward: Bool) {
        guard memoryBrowser?.block != nil else { return }
        loadMemory(offset: forward ? MemoryBrowserState.pageSize : -MemoryBrowserState.pageSize)
    }

    public func closeMemoryBrowser() { memoryBrowser = nil }

    // MARK: Disassembly

    /// Debug ▸ Debug Workflow ▸ Always Show Disassembly.
    public var alwaysShowsDisassembly: Bool { session.alwaysShowDisassembly }

    /// The editor shows the disassembly instead of the source: Always Show
    /// Disassembly, or a selected frame without source on this computer
    /// (a Swift error breakpoint stops in the runtime's `swift_willThrow`).
    public var showsDisassembly: Bool {
        guard isPaused, !disassembly.isEmpty else { return false }
        let frame = frames.first { $0.id == selectedFrameID } ?? frames.first
        return session.alwaysShowDisassembly || frame.map { !WorkspaceSession.hasLocalSource($0) } == true
    }

    /// "<address>  <instruction>    ; <symbol>" per instruction.
    public var disassemblyLines: [String] {
        disassembly.map { i in
            // lldb-dap's instruction text may already end with "; <symbol>".
            let text = i.instruction.trimmingCharacters(in: .whitespaces)
            let symbol = i.symbol.flatMap { text.contains($0) ? nil : "    ; \($0)" } ?? ""
            return "\(i.address)  \(text)" + symbol
        }
    }

    /// "<function> (disassembly)".
    public var disassemblyTitle: String {
        let frame = frames.first { $0.id == selectedFrameID } ?? frames.first
        return "\(frame?.name ?? "Disassembly") (disassembly)"
    }

    func toggleAlwaysShowDisassembly() {
        session.alwaysShowDisassembly.toggle()
        if !session.alwaysShowDisassembly, let loc = session.currentLocation { show(file: loc.file, line: loc.line) }
    }

    /// Debug Workflow's check marks (nil: not a toggle).
    public func isChecked(_ c: ShellCommand) -> Bool? {
        switch c {
        case .toggleNavigateToSourceOnPause: navigatesToSourceOnPause
        case .toggleAlwaysShowDisassembly: session.alwaysShowDisassembly
        default: nil
        }
    }
}
