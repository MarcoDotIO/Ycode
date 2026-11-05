import Foundation
import Observation
import YcodeBuild
import YcodeEditorKit
import YcodeIDECore
import YcodeSyntax

/// The view model of one workspace window of the SwiftUI shell (L1,
/// `docs/PARITY.md` §5): the navigator, editor, inspector and debug areas'
/// state over the core's `WorkspaceSession`. It has no toolkit types, so it
/// runs and is tested headless on macOS and Linux; the views in `ycode-ide`
/// read it through Observation.
@MainActor
@Observable
public final class WorkspaceShellModel {
    @ObservationIgnored public let session: WorkspaceSession

    // MARK: Areas (workspace-window.md §Areas)

    /// Choosing a navigator leaves the Coding Assistant pane.
    public var navigator: ShellNavigator = .project { didSet { assistant.isShown = false } }
    public var isNavigatorShown = true
    public var isInspectorShown = true
    /// Hidden at first; a build or run shows it (the build log is in it).
    public var isDebugAreaShown = false
    public enum DebugPane: String, CaseIterable, Sendable { case buildLog = "Build Log", console = "Console" }
    public var debugPane: DebugPane = .buildLog

    // MARK: Project navigator

    public private(set) var root: NavigatorItem
    public var expanded: Set<String>
    /// The selected row's id.
    public var selection: String? {
        didSet { if selection != oldValue, let id = selection, let item = root.find(id: id), item.isFile, let p = item.path { open(p) } }
    }

    // MARK: Editor

    /// The open file's name and language, or why it can't be shown. Its
    /// `editor` holds the text.
    public internal(set) var document: SourceDocument?
    /// The open file's editable text (nil for no file, or one that can't be
    /// shown as text).
    public internal(set) var editor: EditorDocument?
    /// Every file opened since the workspace opened: their undo histories and
    /// unsaved text stay while another file is shown.
    @ObservationIgnored var openDocuments: [String: EditorDocument] = [:]
    /// The files with unsaved changes (navigator marks, prompts).
    public internal(set) var editedPaths: Set<String> = []
    /// The open file's property list, asset catalog or String Catalog
    /// editor (StructuredEditors.swift), and the files shown as text instead.
    public internal(set) var structuredEditor: StructuredEditor?
    public internal(set) var sourceViewPaths: Set<String> = []
    /// A save that needs the user: a change on disk, or an error.
    public var saveAlert: SaveAlert?
    /// Asking about the open file's unsaved changes (Close Document).
    public var closeDocumentPrompt = false
    /// The open file's text came back from an earlier session's recovery
    /// copy; the banner offers to give it up.
    public internal(set) var recoveredPaths: Set<String> = []
    /// Where unsaved text is kept against a crash (tests pass their own).
    @ObservationIgnored public var recovery = EditorRecovery.standard
    @ObservationIgnored var recoveryTask: Task<Void, Never>?
    /// Starting sourcekit-lsp, and the pending text updates by file.
    @ObservationIgnored var languageStart: Task<Void, Never>?
    @ObservationIgnored var languageUpdates: [String: Task<Void, Never>] = [:]
    /// Find and Replace in the open file.
    public let findBar = EditorFindBar()
    /// Navigate ▸ Jump to Line…: the sheet is up.
    public var isJumpToLineShown = false
    /// Bumped when the editor should take the keyboard.
    public internal(set) var editorFocusCount = 0
    /// The issues of the open file, by 1-based line.
    public private(set) var editorIssues: [Int: EditorLineIssue] = [:]
    /// The line the editor marks and scrolls to (from Find, an issue, or
    /// Jump), 1-based.
    public private(set) var markedLine: Int?
    /// Bumped on every reveal so the editor scrolls even to the same line.
    public private(set) var revealCount = 0
    @ObservationIgnored public private(set) var history = NavigationHistory()
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false

    // MARK: Find navigator

    public var findText = ""
    public var findIgnoreCase = true
    public private(set) var find = FindNavigatorModel()
    public private(set) var findRows: [FindFileRow] = []
    public private(set) var isSearching = false
    /// The selected result row (a match row's id).
    public var findSelection: String? {
        didSet { if findSelection != oldValue, let id = findSelection { openFindResult(id) } }
    }
    /// Bumped by Find in Workspace so the view focuses its query field.
    public private(set) var findFocusCount = 0
    /// The title of results a language request put there ("greet — 3
    /// references"), in place of the count; a search clears it.
    public private(set) var findResultsTitle: String?
    /// Find ▸ Find Call Hierarchy's tree, shown in place of the results
    /// (CallHierarchyRows.swift).
    public let callHierarchy = CallHierarchyModel()
    @ObservationIgnored private var findTask: Task<Void, Never>?

    // MARK: Issues, activity, logs

    public private(set) var issueGroups: [IssueGroupRow] = []
    public private(set) var issueCounts: (errors: Int, warnings: Int) = (0, 0)
    public var issueSelection: String? {
        didSet { if issueSelection != oldValue, let id = issueSelection { openIssue(id) } }
    }
    public private(set) var activity: WorkspaceSession.Activity = .idle
    public private(set) var activityFinishedAt: Date?
    public private(set) var buildLog: [String] = []
    public private(set) var console = ""
    public private(set) var buildCount = 0
    /// Build results: the bezel or a system notification (ShellBuildNotifier.swift).
    public let notifier = ShellBuildNotifier()
    /// Breakpoints, the debug navigator and the variables view (ShellDebugModel.swift).
    public let debug: ShellDebugModel
    /// Source control (SourceControlShellModel.swift).
    public let sourceControl: SourceControlShellModel
    /// The Test and Report navigators (TestShellModel.swift).
    public let testing: TestShellModel
    /// The Coding Assistant pane (ShellAssistantModel.swift).
    public let assistant = ShellAssistantModel()

    // MARK: Language features (WorkspaceShellModel+Language.swift)

    /// Quick Help, Jump to Definition, rename and their state.
    public let languageFeatures = ShellLanguageFeatures()
    /// The Symbol navigator (SymbolNavigatorModel.swift).
    public let symbols: SymbolNavigatorModel

    // MARK: Toolbar

    public private(set) var schemes: [String]
    public private(set) var destinations: [Destination]
    public var scheme: String? { didSet { session.scheme = scheme } }
    public var destination: Destination? { didSet { session.destination = destination } }

    public init(session: WorkspaceSession) {
        self.session = session
        debug = ShellDebugModel(session: session)
        sourceControl = SourceControlShellModel(folder: SourceControlShellModel.folder(for: session.model.url))
        testing = TestShellModel(session: session)
        symbols = SymbolNavigatorModel()
        let root = NavigatorItem(session.model.root)
        self.root = root
        expanded = Set(NavigatorTree.initiallyExpanded(session.model.root))
        schemes = session.model.schemeNames
        let groups = ShellBuildSetup.destinationGroups(for: session.model) + Self.remoteGroups(for: session.model)
        session.model.destinationGroups = groups
        destinations = groups.flatMap(\.destinations)
        session.destination = destinations.first
        scheme = session.scheme
        destination = session.destination
        session.observe { [weak self] change in self?.sessionChanged(change) }
        syncIssues()
        debug.workspace = self
        assistant.workspace = self
        connectSourceControl()
    }

    /// Opens a workspace: an `.xcodeproj`, `.xcworkspace`, `Package.swift`
    /// or a package folder.
    public convenience init(url: URL, engine: BuildEngine = ShellBuildSetup.engine()) throws {
        let session = WorkspaceSession(model: try WorkspaceModel(url: url))
        session.engine = engine
        self.init(session: session)
    }

    public var workspaceName: String { session.model.displayName }
    public var containerKind: WorkspaceModel.ContainerKind { session.model.kind }

    /// "<workspace> — <document>" (`workspace-window.md` §Areas), with
    /// "Edited" while the file has unsaved changes.
    public var windowTitle: String {
        guard let document else { return workspaceName }
        return "\(workspaceName) — \(document.name)\(editedPaths.contains(document.path) ? " — Edited" : "")"
    }

    /// What dynamic menu titles depend on.
    public var menuContext: MenuContext {
        var c = MenuContext()
        c.containerKind = containerKind
        c.workspaceName = workspaceName
        c.fileName = document?.name
        c.navigatorShown = isNavigatorShown
        c.codingAssistantShown = isAssistantPaneShown
        c.inspectorShown = isInspectorShown
        c.debugAreaShown = isDebugAreaShown
        c.isDebugging = session.debugClient != nil
        c.isPaused = debug.isPaused
        c.breakpointsActive = debug.breakpoints.isActive
        c.caretLineBreakpointsEnabled = debug.caretLineBreakpointsEnabled
        return c
    }

    // MARK: Session changes

    private func sessionChanged(_ change: WorkspaceSession.Change) {
        switch change {
        case .activity:
            activity = session.activity
            if case .finished = activity { activityFinishedAt = Date() }
            noteActivityForNotifications()
            buildLog = session.buildLog
        case .issues:
            syncIssues()
            buildLog = session.buildLog
        case .console:
            console = session.console
            if !console.isEmpty, debugPane == .buildLog, case .running = activity { debugPane = .console }
        case .reports:
            buildLog = session.buildLog
        default:
            break
        }
    }

    private func syncIssues() {
        let shown = session.displayedIssues
        issueGroups = IssueRows.tree(shown, grouping: session.issueGrouping)
        issueCounts = IssueNavigatorModel().capsuleCounts(fresh: shown)
        syncEditorIssues()
    }

    public var allIssues: [IssueRow] { IssueRows.flattened(issueGroups) }

    /// The activity view's text (`workspace-window.md` §Toolbar): nothing
    /// while idle; the build's step; "<Result> • Today at <time>" after it
    /// (`WorkspaceChrome.activityFinishedText`, as the AppKit IDE shows it).
    public var activityText: String {
        switch activity {
        case .idle: return ""
        case .building(let s), .running(let s), .paused(let s): return s
        case .finished(let s):
            guard let at = activityFinishedAt else { return s }
            return WorkspaceChrome.activityFinishedText(s, at: at)
        }
    }

    /// Reads `activity` so views and menus that ask are updated when it changes.
    public var isBusy: Bool { _ = activity; return session.isBusy }

    // MARK: Project navigator

    public func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    public func setExpanded(_ id: String, _ on: Bool) {
        if on { expanded.insert(id) } else { expanded.remove(id) }
    }

    /// Navigate ▸ Reveal in Project Navigator: shows the project navigator
    /// with the open file's row selected and its parents expanded.
    public func revealInProjectNavigator() {
        guard let path = document?.path, let ids = root.idPath(to: path) else { return }
        navigator = .project
        isNavigatorShown = true
        expanded.formUnion(ids.dropLast())
        selection = ids.last
    }

    // MARK: Editor

    /// Opens a file in the editor (it becomes the current history entry).
    public func open(_ path: String, line: Int? = nil) {
        sourceControl.hidePane()
        testing.hideReport()
        if document?.path != path { showFile(path) }
        history.visit(path)
        updateHistoryState()
        reveal(line)
    }

    private func reveal(_ line: Int?) {
        markedLine = line
        if let line, let b = editor?.buffer { b.selectLine(number: line) }
        revealCount += 1
        editorFocusCount += 1
    }

    /// Navigate ▸ Go Back / Go Forward through the opened files.
    public func goBack() {
        guard let p = history.back() else { return }
        showFromHistory(p)
    }

    public func goForward() {
        guard let p = history.forward() else { return }
        showFromHistory(p)
    }

    private func showFromHistory(_ p: String) {
        showFile(p)
        reveal(nil)
        updateHistoryState()
    }

    private func updateHistoryState() {
        canGoBack = history.canGoBack
        canGoForward = history.canGoForward
    }

    // MARK: Find navigator

    /// Find ▸ Find in Workspace (⇧⌘F): shows the Find navigator and focuses
    /// its field.
    public func showFindInWorkspace() {
        navigator = .find
        isNavigatorShown = true
        findFocusCount += 1
    }

    /// Searches every file of the workspace (`FindEngine`), up to 1000
    /// matches; rows fill in as files finish.
    public func runFind() {
        findTask?.cancel()
        findResultsTitle = nil
        callHierarchy.show(nil)
        let text = findText
        find.query = FindQuery(text, ignoreCase: findIgnoreCase)
        find.begin()
        findRows = []
        findSelection = nil
        guard !text.isEmpty else { return }
        find.noteRecent(text)
        let files = FindScopeResolver(root: session.model.root).candidates(for: .workspace)
        let request = FindEngine.Request(query: find.query, files: files)
        isSearching = true
        findTask = Task { [weak self] in
            for await event in FindEngine.stream(request) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .file(let f):
                    self.find.append(f)
                    self.findRows = FindMatchRow.rows(self.find.results)
                case .finished(let s):
                    self.find.finish(s)
                    self.findRows = FindMatchRow.rows(self.find.results)
                    self.isSearching = false
                }
            }
        }
    }

    /// Waits for the running search (tests, drivers).
    public func waitForFind() async { await findTask?.value }

    public var findCountText: String { findResultsTitle ?? find.countText }

    /// Shows what a language request found (references, callers) in the
    /// Find navigator as a search for `query` shows its matches, titled
    /// `title` (`refactoring.md` §Find).
    public func showFindResults(query: String, title: String, _ results: [WorkspaceSearch.FileResult]) {
        findTask?.cancel()
        isSearching = false
        findText = query
        find.query = FindQuery(query, ignoreCase: findIgnoreCase)
        find.begin()
        var summary = FindEngine.Summary()
        summary.files = results
        summary.matchCount = results.reduce(0) { $0 + $1.matches.count }
        find.finish(summary)
        findRows = FindMatchRow.rows(find.results)
        findSelection = nil
        findResultsTitle = title
        callHierarchy.show(nil)
        navigator = .find
        isNavigatorShown = true
    }

    private func openFindResult(_ id: String) {
        for (fi, f) in findRows.enumerated() {
            if let m = f.matches.firstIndex(where: { $0.id == id }) {
                find.select(file: fi, match: m)
                open(f.path, line: f.matches[m].line)
                return
            }
        }
    }

    // MARK: Issues

    private func openIssue(_ id: String) {
        guard let row = allIssues.first(where: { $0.id == id }), let file = row.file else { return }
        open(file, line: row.line)
        if let col = row.column, col > 0, let b = editor?.buffer, let line = row.line {
            let n = min(max(line - 1, 0), b.lineCount - 1)
            let r = b.document.lineRange(n)
            b.setCaret(min(r.lowerBound + max(col - 1, 0), r.upperBound))
        }
    }

    /// The open file's issues for its gutter and line marks.
    func syncEditorIssues() {
        guard let path = document?.path else {
            if !editorIssues.isEmpty { editorIssues = [:] }
            return
        }
        let target = IssueMerge.canonicalPath(path)
        var out: [Int: EditorLineIssue] = [:]
        for row in allIssues {
            guard let f = row.file, let line = row.line, IssueMerge.canonicalPath(f) == target else { continue }
            let isError = row.severity == .error
            if let have = out[line], have.isError || !isError { continue }
            out[line] = EditorLineIssue(isError: isError, message: row.message)
        }
        if out != editorIssues { editorIssues = out }
    }

    /// Navigate ▸ Jump to Next / Previous Issue (⌘', ⇧⌘'): the issue after
    /// (before) the selected one, wrapping; the Issue navigator follows.
    public func stepIssue(forward: Bool) {
        let all = allIssues
        guard !all.isEmpty else { return }
        let at = issueSelection.flatMap { id in all.firstIndex { $0.id == id } }
        var next = forward ? 0 : all.count - 1
        if let at { next = (at + (forward ? 1 : -1) + all.count) % all.count }
        issueSelection = all[next].id
    }

    // MARK: Product

    /// The console's trash button: the console and, under it, the build log.
    public func clearConsole() {
        session.clearConsole()
        console = session.console
        buildLog = []
    }

    /// Product ▸ Build (⌘B), Test (⌘U), Clean Build Folder (⇧⌘K), through
    /// the session's engine.
    @discardableResult
    public func build(_ action: BuildRequest.Action = .build) async -> BuildResult {
        // Builds see the saved files; a save that needs the user stops here.
        guard saveAllBeforeBuilding() else { return BuildResult(status: .failed, exitCode: 1, issues: []) }
        isDebugAreaShown = true
        debugPane = .buildLog
        buildCount += 1
        let result = await session.build(action)
        buildLog = session.buildLog
        syncIssues()
        if action == .build, issueCounts.errors > 0 { navigator = .issues }
        return result
    }

    /// The Ycode simulator hosts' devices (ShellRemoteRun) for projects on
    /// Linux; `YCODE_IDE_REMOTE_DESTINATIONS=0` leaves them out.
    static func remoteGroups(for model: WorkspaceModel) -> [DestinationGroup] {
        #if os(Linux)
        guard model.kind != .package, ProcessInfo.processInfo.environment["YCODE_IDE_REMOTE_DESTINATIONS"] != "0" else { return [] }
        return ShellRemoteRun.destinationGroups()
        #else
        return []
        #endif
    }

    /// The device window of the last remote run (Stop ends it).
    @ObservationIgnored private var remoteViewer: Process?

    /// Run on a Ycode simulator host: build here, then upload, install,
    /// launch and show the device (ShellRemoteRun).
    private func remoteRun(_ d: Destination) async {
        isDebugAreaShown = true
        debugPane = .console
        remoteViewer?.terminate()
        let session = session
        let out: @Sendable (String) -> Void = { text in Task { @MainActor in session.appendConsole(text, kind: .debugger) } }
        let packageRoot = ShellRemoteRun.toolsRoot()
        do {
            remoteViewer = try await ShellRemoteRun.run(project: session.model.url.path, scheme: session.scheme ?? workspaceName,
                                                        destination: d, packageRoot: packageRoot, output: out)
        } catch {
            session.appendConsole("Run on \(d.name) failed: \(error)\n", kind: .debugger)
        }
    }

    /// Product ▸ Run (⌘R): build, then launch the scheme's executable under
    /// the debugger (lldb-dap); its output goes to the console.
    public func run() async {
        guard saveAllBeforeBuilding() else { return }
        if let d = destination, ShellRemoteRun.target(of: d) != nil { await remoteRun(d); return }
        isDebugAreaShown = true
        let request = session.model.buildRequest(scheme: session.scheme, destination: session.destination, action: .build)
        let engine = session.engine
        let program = await Task.detached { engine.executablePath(for: request) }.value
        await session.run(program: program)
        buildLog = session.buildLog
        syncIssues()
    }

    /// Product ▸ Stop (⌘.).
    public func stop() {
        remoteViewer?.terminate()
        remoteViewer = nil
        session.stop()
    }

    // MARK: Commands

    public func isEnabled(_ c: ShellCommand) -> Bool {
        switch c {
        case .revealInProjectNavigator: document != nil
        case .save: editor.map { $0.readOnlyReason == nil && (editedPaths.contains($0.path) || $0.diskChange != nil) } ?? false
        case .saveAll: !editedPaths.isEmpty
        case .closeDocument: document != nil
        case .revertToSaved: editor.map { editedPaths.contains($0.path) } ?? false
        case .find, .findAndReplace, .useSelectionForFind, .jumpToLine: editor != nil
        case .findNext, .findPrevious: editor != nil && !findBar.query.isEmpty
        case .commentSelection, .shiftLeft, .shiftRight, .moveLineUp, .moveLineDown: editor?.readOnlyReason == nil && editor != nil
        case .goBack: canGoBack
        case .goForward: canGoForward
        case .nextIssue, .previousIssue: !issueGroups.isEmpty
        case .stop: isBusy
        case .run, .test, .build, .clean: !isBusy
        case .jumpToDefinition, .jumpToOriginalSource, .renameSymbol, .showQuickHelp, .findSelectedSymbol, .showCallHierarchy:
            isLanguageCommandEnabled(c)
        case .pauseOrContinue, .stepOver, .stepInto, .stepOut, .toggleBreakpointAtCurrentLine, .toggleBreakpointsEnabledAtCurrentLine,
             .deleteAllBreakpoints, .copyConsoleRowWithVisibleMetadata, .copyConsoleRowWithAllMetadata, .copyConsoleRowWithoutMetadata,
             .createSwiftErrorBreakpoint, .viewMemory:
            debug.isEnabled(c)
        case .testAgain: !isBusy && session.lastTestRun != nil
        case _ where c.isAssistant: isAssistantCommandEnabled(c)
        case _ where c.isSourceControl: sourceControl.isEnabled(c.action.selector)
        default: true
        }
    }

    /// Performs a command (menus, toolbar and drivers all come here).
    /// Open, Close and Welcome are the app's (`ShellAppModel.perform`).
    public func perform(_ c: ShellCommand) {
        switch c {
        case .open, .closeWorkspace, .welcome, .newProject, .about, .help, .releaseNotes, .reportBug, .swiftBook, .clone, .downloads: break
        case .showProjectNavigator: show(.project)
        case .showFindNavigator: show(.find)
        case .showIssueNavigator: show(.issues)
        case .showDebugNavigator: show(.debug)
        case .showBreakpointNavigator: show(.breakpoints)
        case .pauseOrContinue, .stepOver, .stepInto, .stepOut, .toggleBreakpointsActive, .toggleBreakpointAtCurrentLine,
             .toggleBreakpointsEnabledAtCurrentLine, .deleteAllBreakpoints, .clearConsole,
             .copyConsoleRowWithVisibleMetadata, .copyConsoleRowWithAllMetadata, .copyConsoleRowWithoutMetadata, .createSwiftErrorBreakpoint,
             .createExceptionBreakpoint, .createSymbolicBreakpoint, .toggleNavigateToSourceOnPause, .toggleAlwaysShowDisassembly, .viewMemory:
            debug.perform(c)
        case .showSourceControlNavigator: show(.sourceControl)
        case .showTestNavigator: show(.tests)
        case .showReportNavigator: show(.reports)
        case .showSymbolNavigator: show(.symbols)
        case .jumpToDefinition, .jumpToOriginalSource, .renameSymbol, .showQuickHelp, .findSelectedSymbol, .showCallHierarchy,
             .showFileInspector, .showQuickHelpInspector:
            performLanguage(c)
        case .toggleNavigator: isNavigatorShown.toggle()
        case .toggleInspector: isInspectorShown.toggle()
        case .toggleDebugArea: isDebugAreaShown.toggle()
        case .activateConsole:
            isDebugAreaShown = true
            debugPane = .console
        case .findInWorkspace: showFindInWorkspace()
        case .revealInProjectNavigator: revealInProjectNavigator()
        case .goBack: goBack()
        case .goForward: goForward()
        case .nextIssue: stepIssue(forward: true)
        case .previousIssue: stepIssue(forward: false)
        case .run: Task { await run() }
        case .test: Task { await runTests() }
        case .testAgain: Task { await testAgain() }
        case .build: Task { await build(.build) }
        case .clean: Task { await build(.clean) }
        case .stop: stop()
        case .save, .saveAll, .closeDocument, .revertToSaved, .find, .findAndReplace, .findNext, .findPrevious, .useSelectionForFind,
             .jumpToLine, .commentSelection, .shiftLeft, .shiftRight, .moveLineUp, .moveLineDown:
            performEditing(c)
        case _ where c.isAssistant: performAssistantCommand(c)
        default:
            if c.isSourceControl { sourceControl.performIntegrate(c.action.selector) }
        }
    }

    private func show(_ n: ShellNavigator) {
        navigator = n
        isNavigatorShown = true
    }
}
