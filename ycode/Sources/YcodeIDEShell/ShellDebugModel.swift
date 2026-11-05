import Foundation
import Observation
import YcodeDebug
import YcodeIDECore

/// The debugger's state for the SwiftUI shell (`specs/ide/debug.md`,
/// `reference-ui-4.md` §5–§6): breakpoints in the gutter and the
/// Breakpoint navigator, the Debug navigator's process, threads and frames,
/// the variables view, the console's filter and input line, and the debug
/// bar's commands. The session (`WorkspaceSession`) runs lldb-dap; this
/// mirrors what it publishes so views read it through Observation, and
/// turns the views' gestures into session calls. No toolkit types.
@MainActor
@Observable
public final class ShellDebugModel {
    @ObservationIgnored public let session: WorkspaceSession
    @ObservationIgnored weak var workspace: WorkspaceShellModel?

    // MARK: Session mirror

    /// A debug session is running (lldb-dap is attached).
    public private(set) var isDebugging = false
    /// The thread the program stopped on; nil while it runs.
    public private(set) var stoppedThread: Int?
    public var isPaused: Bool { stoppedThread != nil }
    public private(set) var threads: [DebugThread] = []
    public private(set) var frames: [StackFrame] = []
    public private(set) var selectedFrameID: Int?
    public private(set) var variables: [Variable] = []
    public private(set) var badges: [String: String] = [:]
    /// The selected frame's parameter names, read from its source
    /// (lldb-dap lists arguments with the locals).
    public private(set) var frameArguments: Set<String> = []
    public private(set) var isLoadingVariables = false
    public private(set) var process: DebugProcessInfo?
    /// The stop's line and its annotation ("Thread 1: breakpoint 1.1 (1)").
    public private(set) var stopMark: (file: String, line: Int, text: String)?
    public private(set) var breakpoints = BreakpointStore()
    public private(set) var breakpointIDs: [String: String] = [:]
    /// "<process> › Thread <n> › <index> <function>" (the debug bar).
    public private(set) var barPath = ""
    /// The console's text for `consoleFilter`.
    public private(set) var consoleText = ""
    /// Watch expressions' values at this stop (listed first).
    public private(set) var watchValues: [Variable] = []
    /// Always Show Disassembly's instructions and the PC's index.
    public private(set) var disassembly: [Instruction] = []
    public private(set) var disassemblyPCIndex: Int?

    // MARK: View state

    public var variableScope: VariableScope = .auto
    public var variableFilter = ""
    public var consoleFilter: ConsoleEntry.Filter = .all { didSet { syncConsole() } }
    /// The `(lldb)` prompt's line.
    public var consoleInput = ""
    /// The debug area's halves (the console bar's two toggles).
    public var showsVariables = true
    public var showsConsole = true
    /// Expanded aggregates by row id, and their fetched children.
    public internal(set) var expandedVariables: Set<String> = []
    public private(set) var childVariables: [String: [Variable]] = [:]
    public var selectedVariable: String?
    /// The Debug and Breakpoint navigators' selected and collapsed rows.
    public var debugSelection: String?
    public var collapsedDebugRows: Set<String> = []
    public var breakpointSelection: String?
    public var collapsedBreakpointRows: Set<String> = []
    /// The console row a click selected (Debug ▸ Console ▸ Copy Row).
    public var selectedConsoleRow: Int?
    // Editing (ShellDebugModel+Editing.swift).
    /// The breakpoint editor popover, when open.
    public var breakpointEditor: BreakpointEditorState?
    /// The gutter breakpoint under the pointer (its context menu's).
    public var gutterMenuLine: Int?
    /// The variables view row being edited in place, and its text.
    public var editingVariable: String?
    public var editText = ""
    /// Add Expression…: the new expression's field.
    public var isAddingExpression = false
    public var expressionText = ""
    /// View Memory's browser, when open.
    public var memoryBrowser: MemoryBrowserState?
    /// Debug ▸ Debug Workflow ▸ Navigate to Source File when Process Pauses.
    public var navigatesToSourceOnPause = true
    /// Copy and Copy Value (the toolkit's pasteboard, set by the app).
    @ObservationIgnored public var pasteboard: (any DebugPasteboard)?
    /// Where ↑/↓ are in the console history (nil: the line being typed).
    @ObservationIgnored private var historyCursor: Int?
    @ObservationIgnored private var childrenTask: Task<Void, Never>?
    /// Whether frames' source files are on this computer, by path.
    @ObservationIgnored private var sourceExists: [String: Bool] = [:]

    init(session: WorkspaceSession) {
        self.session = session
        breakpoints = session.breakpoints
        session.observe { [weak self] change in self?.sessionChanged(change) }
    }

    /// Loads the workspace's stored breakpoints (`Breakpoints_v2.xcbkptlist`,
    /// `reference-ui-5.md` §10.1); later changes are saved there.
    public func restoreBreakpoints() {
        session.attachBreakpointFile()
        breakpoints = session.breakpoints
    }

    // MARK: Session changes

    private func sessionChanged(_ change: WorkspaceSession.Change) {
        switch change {
        case .breakpoints:
            breakpoints = session.breakpoints
            breakpointIDs = session.breakpointIDs
        case .debugState:
            syncStopState()
        case .process:
            process = session.debugProcessInfo
            isDebugging = session.debugClient != nil
        case .activity:
            isDebugging = session.debugClient != nil
            process = session.debugProcessInfo
            syncStopState()
            stopMark = session.stopAnnotation
            barPath = session.debugBarPath
            if case .paused = session.activity { noteStop() }
        case .console:
            syncConsole()
        default:
            break
        }
    }

    private func syncStopState() {
        let newVariables = session.variables
        let newWatches = session.watchValues
        disassembly = session.disassembly
        disassemblyPCIndex = session.disassemblyPCIndex
        stoppedThread = session.stoppedThread
        threads = session.threads
        frames = session.frames
        selectedFrameID = session.selectedFrameID
        badges = session.variableBadges
        let frame = frames.first { $0.id == selectedFrameID } ?? frames.first
        frameArguments = frame.flatMap { f in f.file.map { Self.parameterNames(file: $0, line: f.line) } } ?? []
        isLoadingVariables = session.isLoadingVariables
        barPath = session.debugBarPath
        if stoppedThread == nil {
            stopMark = nil
            editingVariable = nil
        }
        if newVariables != variables || newWatches != watchValues {
            variables = newVariables
            watchValues = newWatches
            reloadExpandedChildren()
        }
    }

    func syncConsole() {
        consoleText = consoleFilter == .all ? session.console : session.consoleText(consoleFilter)
    }

    /// Once per stop (`reference-ui-4.md` §5.2): the Debug navigator is
    /// selected, the debug area shown, and the stop's line opened.
    private func noteStop() {
        guard session.stopCount != session.autoSelectedStop, let w = workspace else { return }
        session.autoSelectedStop = session.stopCount
        w.navigator = .debug
        w.isNavigatorShown = true
        w.isDebugAreaShown = true
        debugSelection = frames.first.map { Self.frameRowID($0.id) }
        if navigatesToSourceOnPause, let loc = session.currentLocation { show(file: loc.file, line: loc.line) }
    }

    /// Opens a file at a line with the caret at the line's start (the
    /// stop's band shows the line; a selection would cover it).
    func show(file: String, line: Int) {
        guard let w = workspace, FileManager.default.fileExists(atPath: file) else { return }
        w.open(file, line: line)
        if let b = w.editor?.buffer, w.editor?.path == file {
            let n = min(max(line - 1, 0), b.lineCount - 1)
            b.setCaret(b.document.lineRange(n).lowerBound)
        }
    }

    // MARK: Commands

    public func isEnabled(_ c: ShellCommand) -> Bool {
        switch c {
        case .pauseOrContinue: isDebugging
        case .stepOver, .stepInto, .stepOut: isPaused
        case .toggleBreakpointAtCurrentLine: workspace?.editor != nil
        case .toggleBreakpointsEnabledAtCurrentLine: caretLineBreakpointsEnabled != nil
        case .deleteAllBreakpoints: !breakpoints.isEmpty
        case .showDebugNavigator, .showBreakpointNavigator, .toggleBreakpointsActive, .clearConsole: true
        case .copyConsoleRowWithVisibleMetadata, .copyConsoleRowWithAllMetadata, .copyConsoleRowWithoutMetadata:
            selectedConsoleRowValue != nil
        case .createSwiftErrorBreakpoint: !breakpoints.exceptionFilters.contains("swift_throw")
        case .createExceptionBreakpoint, .createSymbolicBreakpoint, .toggleNavigateToSourceOnPause, .toggleAlwaysShowDisassembly: true
        case .viewMemory: isPaused && session.canReadMemory
        default: false
        }
    }

    public func perform(_ c: ShellCommand) {
        switch c {
        case .pauseOrContinue: Task { await session.continueOrPause() }
        case .stepOver: Task { await session.step("over") }
        case .stepInto: Task { await session.step("in") }
        case .stepOut: Task { await session.step("out") }
        case .toggleBreakpointsActive: session.breakpoints.isActive.toggle()
        case .toggleBreakpointAtCurrentLine:
            if let (file, line) = caretLocation { session.breakpoints.toggleExistence(file: file, line: line) }
        case .toggleBreakpointsEnabledAtCurrentLine:
            if let (file, line) = caretLocation { session.breakpoints.toggleEnabled(file: file, line: line) }
        case .deleteAllBreakpoints:
            session.breakpoints = BreakpointStore()
        case .clearConsole: workspace?.clearConsole()
        case .copyConsoleRowWithVisibleMetadata, .copyConsoleRowWithAllMetadata, .copyConsoleRowWithoutMetadata:
            if let k = Self.copyKind(c) { copyConsoleRow(k) }
        case .createSwiftErrorBreakpoint: addSwiftErrorBreakpoint()
        case .createExceptionBreakpoint: addExceptionBreakpoint()
        case .createSymbolicBreakpoint: addSymbolicBreakpoint()
        case .toggleNavigateToSourceOnPause: navigatesToSourceOnPause.toggle()
        case .toggleAlwaysShowDisassembly: toggleAlwaysShowDisassembly()
        case .viewMemory: viewMemory(of: selectedVariable.flatMap { id in variableRows.first { $0.id == id } })
        default: break
        }
    }

    /// The open file and the caret's 1-based line.
    var caretLocation: (String, Int)? {
        guard let e = workspace?.editor else { return nil }
        return (e.path, e.buffer.caretLine + 1)
    }

    /// Whether every breakpoint on the caret's line is enabled (nil: none).
    public var caretLineBreakpointsEnabled: Bool? {
        guard let (file, line) = caretLocation else { return nil }
        return breakpoints.lineIsEnabled(file: file, line: line)
    }

    // MARK: Gutter

    /// A click on a line number: adds a breakpoint, or enables or disables
    /// the line's (`BreakpointStore.click`).
    public func gutterClick(file: String, line: Int) { session.breakpoints.click(file: file, line: line) }

    /// A breakpoint dragged out of the gutter is deleted; dragged along it,
    /// moved.
    public func gutterDrag(file: String, from: Int, to: Int?) {
        if let to { session.breakpoints.move(file: file, from: from, to: to) } else { session.breakpoints.remove(file: file, line: from) }
    }

    /// What the gutter and the text show for a file: its breakpoints, and
    /// the selected frame's line with the stop's annotation.
    public func marks(for file: String) -> EditorDebugMarks {
        var m = EditorDebugMarks()
        m.breakpointsActive = breakpoints.isActive
        for b in breakpoints.all where b.file == file {
            let have = m.breakpoints[b.line]
            m.breakpoints[b.line] = .init(isEnabled: (have?.isEnabled ?? false) || b.isEnabled,
                                          isCustomized: (have?.isCustomized ?? false) || b.isCustomized)
        }
        let frame = frames.first { $0.id == selectedFrameID } ?? frames.first
        if isPaused, let f = frame, f.file == file, f.line > 0 {
            m.pcLine = f.line
            // The annotation belongs to the top frame's stop.
            if f.id == frames.first?.id, let s = stopMark, s.file == file, s.line == f.line { m.annotation = s.text }
        }
        return m
    }

    // MARK: Debug navigator

    static func frameRowID(_ id: Int) -> String { "frame:\(id)" }

    /// The Debug navigator (`reference-ui-4.md` §5.3): the process row
    /// "<product>  PID n", its gauges, the threads, and the stopped
    /// thread's frames (user frames, a dotted separator, the first system
    /// frame of each run). Empty without a session.
    public var debugRows: [DebugNavigatorRow] {
        guard isDebugging, let p = process else { return [] }
        var out: [DebugNavigatorRow] = []
        let processOpen = !collapsedDebugRows.contains("process")
        out.append(DebugNavigatorRow(id: "process", level: 0, title: p.product + (p.pid.map { "  PID \($0)" } ?? ""), symbol: "app.dashed",
                                     tint: .accent, isBold: true, isExpandable: true, isExpanded: processOpen, kind: .process))
        guard processOpen else { return out }
        let gaugeSymbols = ["CPU": "cpu", "Memory": "square.stack.3d.up", "Energy Impact": "gauge.with.dots.needle.33percent",
                            "Disk": "archivebox", "Network": "globe"]
        for (title, value) in p.gauges.rows {
            var g = DebugNavigatorRow(id: "gauge:\(title)", level: 1, title: title, symbol: gaugeSymbols[title] ?? "gauge.with.dots.needle.33percent",
                                      tint: .secondary, kind: .gauge)
            g.trailing = value
            if title == "Energy Impact" { g.fill = p.gauges.energyLevel }
            out.append(g)
        }
        for t in threads {
            let stopped = t.id == stoppedThread
            let id = "thread:\(t.id)"
            let open = stopped && !collapsedDebugRows.contains(id)
            out.append(DebugNavigatorRow(id: id, level: 1, title: DebugPresentation.threadRow(t), symbol: "list.bullet.rectangle",
                                         tint: stopped ? .accent : .secondary, isExpandable: stopped && !frames.isEmpty, isExpanded: open,
                                         kind: .thread))
            guard open else { continue }
            for row in DebugPresentation.groupFrames(frames, isUser: isUserFrame) {
                switch row {
                case .separator:
                    out.append(DebugNavigatorRow(id: "separator:\(out.count)", level: 2, title: "┈┈┈┈┈┈┈┈┈┈┈┈", symbol: "ellipsis",
                                                 tint: .secondary, isDimmed: true, kind: .separator))
                case .frame(let i, let f, let user):
                    var r = DebugNavigatorRow(id: Self.frameRowID(f.id), level: 2, title: "\(i) \(f.name)", symbol: user ? "person.fill" : "cpu",
                                              tint: user ? .accent : .secondary, isDimmed: !user, kind: .frame)
                    r.frameID = f.id
                    out.append(r)
                }
            }
        }
        return out
    }

    /// A user frame has its source on this computer: on Linux the C
    /// library's start-up frames name absolute build paths that are not.
    func isUserFrame(_ f: StackFrame) -> Bool {
        guard DebugPresentation.isUserFrame(f), let file = f.file else { return false }
        if let known = sourceExists[file] { return known }
        let exists = FileManager.default.fileExists(atPath: file)
        sourceExists[file] = exists
        return exists
    }

    /// A Debug navigator row was clicked: a frame shows its variables and
    /// opens its line.
    public func selectDebugRow(_ id: String) {
        debugSelection = id
        guard let row = debugRows.first(where: { $0.id == id }), let frameID = row.frameID,
              let f = frames.first(where: { $0.id == frameID }) else { return }
        selectedFrameID = frameID
        if let file = f.file, f.line > 0 { show(file: file, line: f.line) }
        Task { await session.selectFrame(frameID) }
    }

    public func setDebugRowExpanded(_ id: String, _ on: Bool) {
        if on { collapsedDebugRows.remove(id) } else { collapsedDebugRows.insert(id) }
    }

    // MARK: Breakpoint navigator

    /// The Breakpoint navigator (`reference-ui-4.md` §6): "<project>  n
    /// Breakpoint(s)", the exception and symbolic groups, then one group
    /// per file with "line N" rows, "ID n.m" and the enabled marker.
    public var breakpointRows: [DebugNavigatorRow] {
        let store = breakpoints
        guard !store.isEmpty else { return [] }
        var out: [DebugNavigatorRow] = []
        let n = store.all.count + store.symbolic.count + store.exceptionFilters.count
        let rootOpen = !collapsedBreakpointRows.contains("root")
        let project = workspace?.workspaceName ?? session.model.displayName
        out.append(DebugNavigatorRow(id: "root", level: 0, title: "\(project)  \(n) Breakpoint\(n == 1 ? "" : "s")",
                                     symbol: session.model.kind == .package ? "shippingbox" : "folder.badge.gearshape", tint: .accent, isBold: true,
                                     isExpandable: true, isExpanded: rootOpen, kind: .group))
        guard rootOpen else { return out }
        let exceptionNames = ["objc_throw": "Objective-C exceptions", "cpp_throw": "C++ exceptions", "swift_throw": "Swift errors"]
        if !store.exceptionFilters.isEmpty {
            out.append(DebugNavigatorRow(id: "exceptions", level: 1, title: "Exception Breakpoints", symbol: "xmark.octagon", tint: .secondary,
                                         isBold: true, kind: .group))
            for f in store.exceptionFilters {
                out.append(DebugNavigatorRow(id: "exception:\(f)", level: 2, title: exceptionNames[f] ?? f, symbol: "tag.fill", tint: .accent,
                                             isDimmed: !store.isActive, kind: .breakpoint))
            }
        }
        if !store.symbolic.isEmpty {
            out.append(DebugNavigatorRow(id: "symbolic", level: 1, title: "Symbolic Breakpoints", symbol: "tag", tint: .secondary,
                                         isBold: true, kind: .group))
            for (i, s) in store.symbolic.enumerated() {
                let name = s.name.isEmpty ? "Symbol" : s.name
                var r = DebugNavigatorRow(id: "symbolic:\(i)", level: 2, title: s.condition.isEmpty ? name : "\(name) [\(s.condition)]",
                                          symbol: "tag.fill", tint: .accent, isDimmed: !(s.isEnabled && store.isActive) || s.name.isEmpty,
                                          kind: .breakpoint)
                r.marker = s.isEnabled
                out.append(r)
            }
        }
        var ordinal = 0
        let ordinals = Dictionary(store.all.map { b -> (String, Int) in ordinal += 1; return ("\(b.file):\(b.line)", ordinal) },
                                  uniquingKeysWith: { a, _ in a })
        for file in Set(store.all.map(\.file)).sorted() {
            let id = "file:\(file)"
            let open = !collapsedBreakpointRows.contains(id)
            out.append(DebugNavigatorRow(id: id, level: 1, title: URL(fileURLWithPath: file).lastPathComponent,
                                         symbol: WorkspaceChrome.fileSymbol(file), tint: .accent, isBold: true, isExpandable: true,
                                         isExpanded: open, kind: .group))
            guard open else { continue }
            for b in store.all where b.file == file {
                let key = "\(b.file):\(b.line)"
                // "report(_:)  17" in the function around it, else "line 17".
                let symbol = SourceSymbolLocator.symbol(file: b.file, line: b.line)
                let place = b.column.map { "\(b.line):\($0)" } ?? "\(b.line)"
                let base = symbol.map { "\($0.name)  \(place)" } ?? "line \(place)"
                var r = DebugNavigatorRow(id: "bp:\(key)" + (b.column.map { ":\($0)" } ?? ""), level: 2,
                                          title: b.condition.isEmpty ? base : "\(base) [\(b.condition)]",
                                          symbol: symbol == nil ? "tag.fill" : "square.fill", tint: .accent,
                                          isDimmed: !(b.isEnabled && store.isActive), kind: .breakpoint)
                r.letter = symbol.map { $0.method ? "M" : "F" }
                r.trailing = "ID " + (breakpointIDs[key] ?? "\(ordinals[key] ?? 0).1")
                r.marker = b.isEnabled
                r.location = (b.file, b.line)
                out.append(r)
            }
        }
        return out
    }

    /// A breakpoint row was clicked: its line opens.
    public func selectBreakpointRow(_ id: String) {
        breakpointSelection = id
        if let loc = breakpointRows.first(where: { $0.id == id })?.location { show(file: loc.file, line: loc.line) }
    }

    public func setBreakpointRowExpanded(_ id: String, _ on: Bool) {
        if on { collapsedBreakpointRows.remove(id) } else { collapsedBreakpointRows.insert(id) }
    }

    /// The enabled marker at a breakpoint row's end.
    public func toggleBreakpointEnabled(_ id: String) {
        if id.hasPrefix("symbolic:"), let i = Int(id.dropFirst("symbolic:".count)), session.breakpoints.symbolic.indices.contains(i) {
            session.breakpoints.symbolic[i].isEnabled.toggle()
            return
        }
        guard let loc = breakpointRows.first(where: { $0.id == id })?.location else { return }
        session.breakpoints.toggleEnabled(file: loc.file, line: loc.line)
    }

    /// The row's context menu: Delete Breakpoint.
    public func deleteBreakpoint(_ id: String) {
        if let loc = breakpointRows.first(where: { $0.id == id })?.location {
            session.breakpoints.remove(file: loc.file, line: loc.line)
        } else if id.hasPrefix("symbolic:"), let i = Int(id.dropFirst("symbolic:".count)), session.breakpoints.symbolic.indices.contains(i) {
            if breakpointEditor?.target == .symbolic(index: i) { breakpointEditor = nil }
            session.breakpoints.symbolic.remove(at: i)
        } else if id.hasPrefix("exception:") {
            let f = String(id.dropFirst("exception:".count))
            session.breakpoints.exceptionFilters.removeAll { $0 == f }
        }
    }

    // MARK: Variables view

    /// The variables view's rows: the selected frame's variables for the
    /// scope and filter, with expanded aggregates' children under them.
    public var variableRows: [VariableRow] {
        var out: [VariableRow] = []
        var seen = Set<String>()
        func add(_ v: Variable, id: String, level: Int, badge: String?, container: Int? = nil, watch: Int? = nil) {
            guard seen.insert(id).inserted else { return }
            let open = expandedVariables.contains(id)
            var row = VariableRow(id: id, level: level, badge: badge, name: v.name, type: Self.typeText(v.type), value: v.value,
                                  reference: v.variablesReference, isExpanded: open && v.variablesReference != 0)
            row.container = container
            row.memoryReference = v.memoryReference
            row.watchIndex = watch
            out.append(row)
            guard open, let kids = childVariables[id] else { return }
            for k in kids { add(k, id: id + "/" + k.name, level: level + 1, badge: nil, container: v.variablesReference) }
        }
        // Watch expressions first (`debug.md` §Variables view depth).
        for (i, v) in watchValues.enumerated() { add(v, id: Self.watchRowID(i), level: 0, badge: nil, watch: i) }
        let filter = variableFilter.lowercased()
        for v in variables where variableScope.includes(v.name) && (variableScope != .local || !v.name.hasPrefix("$"))
            && (filter.isEmpty || v.name.lowercased().contains(filter)) {
            add(v, id: v.name, level: 0, badge: frameArguments.contains(v.name) ? "A" : (badges[v.name] ?? "L"))
        }
        return out
    }

    /// The parameter names of the function around a 1-based line: the
    /// nearest `func`, `init` or `subscript` declaration at or above it,
    /// its parameter list up to the matching parenthesis.
    static func parameterNames(file: String, line: Int) -> Set<String> {
        guard line > 0, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        let lines = text.components(separatedBy: "\n")
        guard line <= lines.count else { return [] }
        let keywords = ["func ", "init(", "init?(", "init!(", "init<", "subscript("]
        for i in stride(from: line - 1, through: 0, by: -1) {
            guard let k = keywords.compactMap({ lines[i].range(of: $0) }).first else { continue }
            let rest = lines[i][k.lowerBound...] + "\n" + lines[(i + 1)..<min(lines.count, i + 12)].joined(separator: "\n")
            guard let open = rest.firstIndex(of: "(") else { return [] }
            var depth = 0
            var end = open
            for idx in rest[open...].indices {
                if rest[idx] == "(" { depth += 1 } else if rest[idx] == ")" { depth -= 1 }
                if depth == 0 { end = idx; break }
            }
            guard end > open else { return [] }
            let list = rest[open...end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return DebugPresentation.argumentNames("f" + list)
        }
        return []
    }

    static func typeText(_ t: String?) -> String? {
        guard let t, !t.isEmpty, t != "<no-type>" else { return nil }
        return t
    }

    /// Expands or collapses an aggregate; its children are fetched once.
    public func setVariableExpanded(_ row: VariableRow, _ on: Bool) {
        guard row.isExpandable else { return }
        if !on {
            expandedVariables.remove(row.id)
            return
        }
        expandedVariables.insert(row.id)
        guard childVariables[row.id] == nil else { return }
        let ref = row.reference
        Task {
            let kids = await session.children(of: ref)
            childVariables[row.id] = kids
        }
    }

    /// A new stop (or frame) has new references: the expanded aggregates'
    /// children are fetched again by name.
    func reloadExpandedChildren() {
        childrenTask?.cancel()
        guard !expandedVariables.isEmpty, !variables.isEmpty || !watchValues.isEmpty else {
            childVariables = [:]
            return
        }
        let expanded = expandedVariables
        let top = watchValues.enumerated().map { (Self.watchRowID($0.offset), $0.element) } + variables.map { ($0.name, $0) }
        let session = session
        childrenTask = Task {
            var fetched: [String: [Variable]] = [:]
            var queue: [(String, Variable)] = top
            while !queue.isEmpty {
                let (id, v) = queue.removeFirst()
                guard expanded.contains(id), v.variablesReference != 0 else { continue }
                let kids = await session.children(of: v.variablesReference)
                if Task.isCancelled { return }
                fetched[id] = kids
                queue += kids.map { (id + "/" + $0.name, $0) }
            }
            childVariables = fetched
        }
    }

    /// Waits for children being fetched (tests).
    public func waitForChildren() async { await childrenTask?.value }

    /// Print Description: `po <name>` in the console.
    public func printDescription(_ row: VariableRow) {
        Task { await session.printDescription(of: row.name) }
    }

    // MARK: Console

    /// Return in the console's field: the line goes to LLDB.
    public func submitConsoleLine() {
        let line = consoleInput
        consoleInput = ""
        historyCursor = nil
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Task { await session.evaluateInConsole(line) }
    }

    /// ↑ / ↓ in the console's field: older and newer entered lines; past
    /// the newest, an empty line.
    public func consoleHistory(older: Bool) {
        let h = session.consoleHistory
        guard !h.isEmpty else { return }
        var i = historyCursor ?? h.count
        i += older ? -1 : 1
        if i < 0 { i = 0 }
        if i >= h.count {
            historyCursor = nil
            consoleInput = ""
            return
        }
        historyCursor = i
        consoleInput = h[i]
    }
}

/// One row of the Debug or Breakpoint navigator.
public struct DebugNavigatorRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case process, gauge, thread, frame, separator, group, breakpoint }
    public var id: String
    public var level: Int
    public var title: String
    public var symbol: String
    public var tint: OutlineRow.Tint
    public var isBold = false
    public var isExpandable = false
    public var isExpanded = false
    public var isDimmed = false
    public var kind: Kind
    /// A value at the row's right end (a gauge's reading, a breakpoint's ID).
    public var trailing: String?
    /// The Energy Impact bar's fill (0…1).
    public var fill: Double?
    /// A breakpoint's enabled marker (nil: none).
    public var marker: Bool?
    /// The kind letter drawn on the row's icon ("F" function, "M" method).
    public var letter: String?
    public var frameID: Int?
    public var location: (file: String, line: Int)?

    public init(id: String, level: Int, title: String, symbol: String, tint: OutlineRow.Tint, isBold: Bool = false,
                isExpandable: Bool = false, isExpanded: Bool = false, isDimmed: Bool = false, kind: Kind) {
        self.id = id
        self.level = level
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isBold = isBold
        self.isExpandable = isExpandable
        self.isExpanded = isExpanded
        self.isDimmed = isDimmed
        self.kind = kind
    }

    /// The row as the shared outline draws it.
    public var outline: OutlineRow {
        OutlineRow(id: id, level: level, title: title, detail: nil, symbol: symbol, tint: tint, isBold: isBold, isExpandable: isExpandable,
                   isExpanded: isExpanded, isDimmed: isDimmed, opens: kind == .frame || kind == .breakpoint)
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.level == b.level && a.title == b.title && a.symbol == b.symbol && a.tint == b.tint && a.isBold == b.isBold
            && a.isExpandable == b.isExpandable && a.isExpanded == b.isExpanded && a.isDimmed == b.isDimmed && a.kind == b.kind
            && a.trailing == b.trailing && a.fill == b.fill && a.marker == b.marker && a.letter == b.letter && a.frameID == b.frameID
            && a.location?.file == b.location?.file && a.location?.line == b.location?.line
    }
}

/// One row of the variables view: "A name: Type = value".
public struct VariableRow: Identifiable, Equatable, Sendable {
    /// The names from the top-level variable down ("s/x").
    public var id: String
    public var level: Int
    /// "A" (argument) or "L" (local) for a frame's own variables.
    public var badge: String?
    public var name: String
    public var type: String?
    public var value: String
    public var reference: Int
    public var isExpanded: Bool
    public var isExpandable: Bool { reference != 0 }
    /// The reference of the aggregate it is listed in (nil: a frame's own
    /// variable), for `setVariable`.
    public var container: Int?
    /// Where its value is in memory (View Memory).
    public var memoryReference: String?
    /// The watch expression's index, for a watch row.
    public var watchIndex: Int?
    public var isWatch: Bool { watchIndex != nil }

    /// "name: Type = value" (the badge is drawn apart).
    public var text: String { name + (type.map { ": \($0)" } ?? "") + " = " + value }
}

/// The debugger's marks in one file's editor.
public struct EditorDebugMarks: Equatable, Sendable {
    public struct Breakpoint: Equatable, Sendable {
        public var isEnabled: Bool
        public var isCustomized: Bool
    }
    /// By 1-based line.
    public var breakpoints: [Int: Breakpoint] = [:]
    public var breakpointsActive = true
    /// The selected frame's 1-based line while paused.
    public var pcLine: Int?
    /// The stop's annotation on that line.
    public var annotation: String?
    public init() {}
}
