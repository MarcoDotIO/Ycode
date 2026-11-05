import Foundation
import YcodeProject
import YcodeWorkspace
import YcodeBuild
import YcodeDebug

/// Breakpoints of a workspace: file lines (and line columns), each enabled
/// or disabled, plus the global "breakpoints active" switch. See
/// `specs/ide/source-editor.md` §Breakpoint gutter and
/// `specs/ide/reference-ui-5.md` §10 (Debug ▸ Breakpoints, persistence).
public struct BreakpointStore: Equatable, Sendable {
    public struct Breakpoint: Equatable, Hashable, Sendable {
        public var file: String
        public var line: Int
        public var isEnabled: Bool
        /// A column breakpoint's 1-based column (Debug ▸ Breakpoints ▸
        /// Create Column Breakpoint); nil for a line breakpoint.
        public var column: Int?
        /// Stop only when this expression is true.
        public var condition = ""
        /// Skip this many hits before stopping.
        public var ignoreCount = 0
        public var actions: [BreakpointAction] = []
        /// Continue after the actions instead of stopping.
        public var autoContinue = false

        /// Whether anything beyond file and line is set (drawn darker).
        public var isCustomized: Bool { !condition.isEmpty || ignoreCount > 0 || !actions.isEmpty || autoContinue }

        /// The DAP form. A single log action with "automatically continue"
        /// (and no `%B` / `%H` token) becomes the adapter's log point; other
        /// actions are run by Ycode when the breakpoint stops
        /// (`runsActionsInIDE`, `WorkspaceSession+BreakpointActions.swift`).
        public var dap: SourceBreakpoint {
            SourceBreakpoint(line: line, column: column, condition: condition.isEmpty ? nil : condition,
                             hitCondition: ignoreCount > 0 ? String(ignoreCount) : nil, logMessage: adapterLogMessage)
        }

        /// The log point lldb-dap runs without stopping, when the
        /// breakpoint's only action is a log message that continues.
        public var adapterLogMessage: String? {
            guard autoContinue, actions.count == 1, case .log(let m) = actions[0], !BreakpointMessage.needsIDE(m) else { return nil }
            return BreakpointMessage.dapLogMessage(m)
        }

        /// Ycode runs the actions (and the automatic continue) at the
        /// breakpoint's stops: everything the adapter's log point cannot.
        public var runsActionsInIDE: Bool { adapterLogMessage == nil && (!actions.isEmpty || autoContinue) }
    }

    /// A breakpoint action (`specs/ide/debug.md` §Breakpoint editing).
    public enum BreakpointAction: Equatable, Hashable, Sendable {
        /// A message for the console; `@expr@` or `{expr}` show a value,
        /// `%B` the breakpoint and `%H` its hit count.
        case log(String)
        /// An LLDB command; its output goes to the console.
        case debuggerCommand(String)
        /// A sound by name (`BreakpointSound.names`).
        case sound(String)
    }

    /// A symbolic breakpoint (stop in functions with this name).
    public struct Symbolic: Equatable, Hashable, Sendable {
        public var name: String
        public var condition = ""
        public var isEnabled = true
        public init(name: String, condition: String = "", isEnabled: Bool = true) {
            self.name = name
            self.condition = condition
            self.isEnabled = isEnabled
        }
    }

    /// Exception breakpoints by adapter filter id (e.g. `swift_throw`).
    public var exceptionFilters: [String] = []
    public var symbolic: [Symbolic] = []

    /// Edits one line breakpoint in place (the line breakpoint when the
    /// line also has column breakpoints).
    public mutating func edit(file: String, line: Int, _ change: (inout Breakpoint) -> Void) {
        guard let i = index(file: file, line: line) else { return }
        change(&all[i])
    }

    /// What `setBreakpoints` sends for each file (active and enabled only).
    public var effectiveBreakpoints: [String: [SourceBreakpoint]] {
        var out: [String: [SourceBreakpoint]] = [:]
        for b in all { out[b.file, default: []] += (isActive && b.isEnabled) ? [b.dap] : [] }
        return out
    }

    public var effectiveFunctionBreakpoints: [FunctionBreakpoint] {
        guard isActive else { return [] }
        // A symbol still being typed in the editor may be empty or padded.
        return symbolic.compactMap { s in
            let name = s.name.trimmingCharacters(in: .whitespaces), condition = s.condition.trimmingCharacters(in: .whitespaces)
            return s.isEnabled && !name.isEmpty ? FunctionBreakpoint(name: name, condition: condition.isEmpty ? nil : condition) : nil
        }
    }

    public private(set) var all: [Breakpoint] = []
    /// ⌘Y turns all breakpoints off without forgetting them.
    public var isActive = true

    public init() {}

    /// Every kind of breakpoint counted together (none: Delete All
    /// Breakpoints is disabled).
    public var isEmpty: Bool { all.isEmpty && symbolic.isEmpty && exceptionFilters.isEmpty }

    /// The line's breakpoint: its line breakpoint, else its first column
    /// breakpoint.
    public func breakpoint(file: String, line: Int) -> Breakpoint? {
        index(file: file, line: line).map { all[$0] }
    }

    private func index(file: String, line: Int) -> Int? {
        all.firstIndex { $0.file == file && $0.line == line && $0.column == nil }
            ?? all.firstIndex { $0.file == file && $0.line == line }
    }

    /// Every breakpoint on a line (line and column breakpoints).
    public func breakpoints(file: String, line: Int) -> [Breakpoint] {
        all.filter { $0.file == file && $0.line == line }
    }

    private mutating func sortAll() {
        all.sort { ($0.file, $0.line, $0.column ?? 0) < ($1.file, $1.line, $1.column ?? 0) }
    }

    /// A click in the gutter: adds a breakpoint, or flips the line's
    /// breakpoints between enabled and disabled.
    public mutating func click(file: String, line: Int) {
        if let i = index(file: file, line: line) {
            let on = !all[i].isEnabled
            for j in all.indices where all[j].file == file && all[j].line == line { all[j].isEnabled = on }
        } else {
            all.append(Breakpoint(file: file, line: line, isEnabled: true))
            sortAll()
        }
    }

    /// ⌘\ (Create Breakpoint at Current Line): adds one, or deletes the
    /// line's breakpoints when it has any (reference-ui-5.md §2.10).
    public mutating func toggleExistence(file: String, line: Int) {
        if breakpoint(file: file, line: line) != nil { remove(file: file, line: line) } else { click(file: file, line: line) }
    }

    /// Dragging a breakpoint out of the gutter deletes it (with the line's
    /// column breakpoints).
    public mutating func remove(file: String, line: Int) {
        all.removeAll { $0.file == file && $0.line == line }
    }

    /// Dragging a breakpoint along the gutter moves it.
    public mutating func move(file: String, from: Int, to: Int) {
        guard from != to, let i = index(file: file, line: from) else { return }
        let enabled = all[i].isEnabled
        all.remove(at: i)
        remove(file: file, line: to)
        all.append(Breakpoint(file: file, line: to, isEnabled: enabled))
        sortAll()
    }

    // MARK: Debug ▸ Breakpoints (reference-ui-5.md §2.10, §10.2)

    /// Whether every breakpoint on the line is enabled (nil: none there).
    /// The menu reads "Disable Breakpoints at Current Line" when true.
    public func lineIsEnabled(file: String, line: Int) -> Bool? {
        let list = breakpoints(file: file, line: line)
        return list.isEmpty ? nil : list.allSatisfy(\.isEnabled)
    }

    /// Enable / Disable Breakpoints at Current Line: disables them when all
    /// are enabled, else enables them all.
    public mutating func toggleEnabled(file: String, line: Int) {
        guard let on = lineIsEnabled(file: file, line: line) else { return }
        for j in all.indices where all[j].file == file && all[j].line == line { all[j].isEnabled = !on }
    }

    /// Create Column Breakpoint: a breakpoint at the caret's column (one
    /// per column).
    public mutating func addColumn(file: String, line: Int, column: Int) {
        guard !all.contains(where: { $0.file == file && $0.line == line && $0.column == column }) else { return }
        all.append(Breakpoint(file: file, line: line, isEnabled: true, column: column))
        sortAll()
    }

    /// Delete Column Breakpoints at Current Line.
    public mutating func removeColumns(file: String, line: Int) {
        all.removeAll { $0.file == file && $0.line == line && $0.column != nil }
    }

    public func hasColumnBreakpoints(file: String, line: Int) -> Bool {
        all.contains { $0.file == file && $0.line == line && $0.column != nil }
    }

    /// Delete All Breakpoints: every line, column, symbolic and exception
    /// breakpoint (the active switch stays).
    public mutating func removeAll() {
        all = []
        symbolic = []
        exceptionFilters = []
    }

    /// Adds a breakpoint as stored (persistence): replaces one at the same
    /// file, line and column.
    public mutating func insert(_ b: Breakpoint) {
        all.removeAll { $0.file == b.file && $0.line == b.line && $0.column == b.column }
        all.append(b)
        sortAll()
    }

    /// The lines to send to the debugger for each file.
    public var effectiveLines: [String: [Int]] {
        var out: [String: [Int]] = [:]
        for b in all { out[b.file, default: []] += (isActive && b.isEnabled) ? [b.line] : [] }
        return out
    }
}

/// What a workspace window shows: the opened container, its navigator tree,
/// schemes and destinations.
public struct WorkspaceModel: Sendable {
    public enum ContainerKind: Sendable, Equatable { case project, workspace, package }

    public var url: URL
    public var kind: ContainerKind
    public var root: NavigatorNode
    public var schemeNames: [String]
    /// Destination pop-up sections; starts with the Mac, filled in from
    /// simctl/devicectl later (`DestinationCatalog.load`).
    public var destinationGroups: [DestinationGroup] = DestinationCatalog.groups(devices: [], simulators: [])
    public var destinations: [Destination] { destinationGroups.flatMap(\.destinations) }
    /// Loaded projects by `.xcodeproj` path, kept for byte-exact saving.
    public var projects: [String: PBXProj] = [:]

    public var displayName: String {
        kind == .package ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    /// Opens a `.xcodeproj`, `.xcworkspace`, a `Package.swift`, or a folder
    /// that contains one.
    public init(url input: URL) throws {
        var url = input.standardizedFileURL
        if url.lastPathComponent == "Package.swift" { url.deleteLastPathComponent() }
        self.url = url
        switch url.pathExtension {
        case "xcodeproj":
            kind = .project
            let proj = try PBXProj(contentsOf: url)
            projects[url.path] = proj
            root = NavigatorTree.project(proj, xcodeprojURL: url)
            schemeNames = Self.schemes(in: [url], projects: [url.path: proj])
        case "xcworkspace":
            kind = .workspace
            let ws = try Workspace(contentsOf: url.path)
            var rows: [NavigatorNode] = []
            var loaded: [String: PBXProj] = [:]
            for p in ws.projectPaths {
                let pu = URL(fileURLWithPath: p)
                guard let proj = try? PBXProj(contentsOf: pu) else { continue }
                loaded[p] = proj
                rows.append(NavigatorTree.project(proj, xcodeprojURL: pu))
            }
            projects = loaded
            root = NavigatorNode(name: url.deletingPathExtension().lastPathComponent, kind: .container, path: url.path, children: rows)
            schemeNames = Self.schemes(in: [url] + ws.projectPaths.map { URL(fileURLWithPath: $0) }, projects: loaded)
        default:
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) else {
                throw CocoaError(.fileReadUnsupportedScheme, userInfo: [
                    NSFilePathErrorKey: url.path,
                    NSLocalizedDescriptionKey: "“\(url.lastPathComponent)” is not a project, workspace or package.",
                    NSLocalizedRecoverySuggestionErrorKey: "Open an .xcodeproj or .xcworkspace, or a folder with a Package.swift in it.",
                ])
            }
            kind = .package
            root = NavigatorTree.package(at: url)
            schemeNames = [url.lastPathComponent]
        }
    }

    /// Shared and user schemes; when a project has none, one per target
    /// (the schemes Xcode would autocreate).
    static func schemes(in containers: [URL], projects: [String: PBXProj]) -> [String] {
        var names: [String] = []
        for c in containers {
            let found = Scheme.discover(in: c).map(\.name)
            if found.isEmpty, let proj = projects[c.path] {
                names += proj.targets.compactMap { $0.string("name") }
            } else {
                names += found
            }
        }
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    public func buildRequest(scheme: String?, destination: Destination?, action: BuildRequest.Action) -> BuildRequest {
        let container: BuildRequest.Container = switch kind {
        case .project: .project(url.path)
        case .workspace: .workspace(url.path)
        case .package: .package(url.path)
        }
        return BuildRequest(container: container, scheme: scheme, destination: destination?.specifier, action: action,
                            settings: diagnostics(scheme: scheme, action: action).buildSettings)
    }

    /// The Diagnostics (sanitizers) of the scheme action that applies to
    /// `action` (`specs/ide/schemes.md` §Diagnostics); none for packages,
    /// clean, or a scheme without a file.
    public func diagnostics(scheme: String?, action: BuildRequest.Action) -> SchemeDiagnostics {
        guard kind != .package, let name = scheme, let element = SchemeDiagnostics.schemeAction(for: action),
              let s = loadSchemes().first(where: { $0.name == name }) else { return SchemeDiagnostics() }
        return s.diagnostics(for: element)
    }

    /// Writes changed projects back through the pbxproj writer.
    public func saveProjects() throws {
        for (path, proj) in projects {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            let file = URL(fileURLWithPath: path).appendingPathComponent("project.pbxproj")
            let text = proj.serialized(projectName: name)
            if (try? String(contentsOf: file, encoding: .utf8)) != text {
                try text.write(to: file, atomically: true, encoding: .utf8)
            }
        }
    }
}
