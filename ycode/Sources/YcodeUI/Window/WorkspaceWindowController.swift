import AppKit
import YcodeBuild
import YcodeDebug
import YcodeLanguage
import YcodeWorkspace
import YcodeProject
import YcodeXcodebuild

/// The workspace window: toolbar; navigator | editor over debug area |
/// inspector. Handles the menu commands of `CommandTable` through the
/// responder chain. See `specs/ide/workspace-window.md`.
@MainActor
public final class WorkspaceWindowController: NSWindowController, NSToolbarDelegate, NSMenuItemValidation {
    /// The default window frame, toolbar included (reference-ui-5.md §3.3, L5).
    public static let defaultSize = NSSize(width: 1400, height: 900)
    /// Running inside a test process (swift test / xctest).
    public static let isTestProcess: Bool = {
        let name = ProcessInfo.processInfo.processName
        return name.contains("xctest") || name.contains("swiftpm-testing-helper") || name.hasSuffix("PackageTests")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }()
    public static let navigatorWidth: CGFloat = 290  // reference-ui.md §2
    public static let inspectorWidth: CGFloat = 265  // reference-ui.md §6
    public static let debugAreaHeight: CGFloat = 135  // reference-ui.md §5

    public let session: WorkspaceSession
    public let navigator = NavigatorAreaController()
    /// The editor area: tabs and splits of source editors.
    public let editorArea = EditorAreaController(first: SourceEditorController())
    final class RefactoringStore {
        var backups: [String: String] = [:]
        var rename: (URL, Position, String)?
        var preview: WorkspaceEdit?
        var actions: [CodeAction] = []
    }
    let refactoringStore = RefactoringStore()
    @MainActor final class ToolbarControls {
        let leftPanes = NSSegmentedControl(images: [NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Navigators")!,
                                                    NSImage(systemSymbolName: "text.bubble", accessibilityDescription: "Coding Assistant")!],
                                           trackingMode: .selectAny, target: nil, action: nil)
        let editorModes = NSSegmentedControl(images: [NSImage(systemSymbolName: "rectangle.righthalf.inset.filled", accessibilityDescription: "Canvas")!,
                                                      NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Assistant")!,
                                                      NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Code Review")!],
                                             trackingMode: .selectAny, target: nil, action: nil)
        /// The editor modes folded into one pull-down when the toolbar is
        /// short of room (reference-ui-6.md §2.2).
        let editorModesPullDown = NSPopUpButton(frame: .zero, pullsDown: true)
        /// The scheme pop-up's width cap while room is short (§2.2.2).
        var schemeCap: NSLayoutConstraint?
        /// The fitting state (`ToolbarFit`) and its guards.
        var fit = ToolbarFit()
        var fitting = false
        var fitScheduled = false
        init() {
            // reference-ui-5.md §4.1.4, §4.2.3.
            // liquid-glass.md §2.2: the drawn capsules are 78 and 125
            // points wide (the system adds its padding to the segments).
            for (c, tips, w) in [(leftPanes, ["Navigators", "Coding Assistant"], ToolbarGlass.leftPanesSegment),
                                 (editorModes, ["Show Canvas", "Show Assistant", "Show Code Review"], ToolbarGlass.editorModesSegment)] {
                for (i, t) in tips.enumerated() { c.setToolTip(t, forSegment: i); c.setWidth(w, forSegment: i) }
            }
        }
    }
    let toolbarControls = ToolbarControls()
    /// Observers keeping the left segments in step (`observeLeftArea`).
    final class LeftAreaObservation {
        var tokens: [Any] = []
        deinit { for t in tokens where !(t is NSKeyValueObservation) { NotificationCenter.default.removeObserver(t) } }
    }
    let leftAreaObservation = LeftAreaObservation()
    /// The coding assistant (WorkspaceWindowController+CodingAssistant.swift).
    let codingAssistantHolder = CodingAssistantHolder()
    final class BehaviorStore {
        var previous: WorkspaceSession.Activity?
        var last: (event: Preferences.Event, behavior: Preferences.Behavior)?
        /// Program output seen since the run started.
        var runOutput = false
        var seenEntries = 0
    }
    let behaviorStore = BehaviorStore()
    final class SchemeEditorState { var selection: (Int, Int) = (1, 0) }
    let schemeEditorState = SchemeEditorState()
    /// The toolbar's issue counts (reference-ui-2.md §2).
    public let issueCapsule: IssueCapsuleView = {
        let v = IssueCapsuleView()
        v.isHidden = true
        return v
    }()
    final class SourceControlCache { var enabled: Bool? }
    let sourceControlCache = SourceControlCache()
    final class SimctlStore { var simctl = Simctl() }
    final class BookmarkStoreHolder { var store: BookmarkStore? }
    let bookmarkStoreHolder = BookmarkStoreHolder()
    let simctlStore = SimctlStore()
    var prefsObserver: NSObjectProtocol?
    var showsRegistersCache = false
    var appearanceFromSettings = false
    /// The focused editor of the selected tab.
    public var editor: SourceEditorController { editorArea.focusedEditor }
    public let inspector = InspectorAreaController()
    public let debugArea = DebugAreaController()
    public let activityView = ActivityView()

    let mainSplit = NSSplitViewController()
    let centerSplit = NSSplitViewController()
    var navigatorItem: NSSplitViewItem!
    var inspectorItem: NSSplitViewItem!
    var debugItem: NSSplitViewItem!
    let schemePopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let destinationPopUp: NSPopUpButton = DestinationPopUpButton(frame: .zero, pullsDown: false)
    private var issueCursor = -1
    /// Per-workspace user data (`WorkspaceUserState`): Recent Files, the
    /// navigator's expansion, destinations per scheme. Kept in memory
    /// only when `userStateURL` is nil (test runs).
    public internal(set) var userState: WorkspaceUserState
    public let userStateURL: URL?
    final class DestinationDefaultState { var applied: Destination? }
    /// The destination last chosen by default, so a later reload can
    /// replace it (and never an explicit choice).
    let destinationDefault = DestinationDefaultState()

    /// `openFirstFile`: open the first source file at once. The window
    /// opens with nothing selected (reference-ui.md §2); the test suite's
    /// older fixtures ask for the file (the default inside test runs).
    /// `userStateURL`: where the workspace's user data lives; by default
    /// next to the workspace (`WorkspaceUserState.fileURL`), none in tests.
    public init(session: WorkspaceSession, loadDestinations: Bool = true, startLanguageService: Bool = true,
                openFirstFile: Bool = WorkspaceWindowController.isTestProcess, userStateURL: URL? = nil) {
        self.session = session
        self.opensFirstFile = openFirstFile
        let stateURL = userStateURL ?? (Self.isTestProcess ? nil
            : WorkspaceUserState.fileURL(container: session.model.url, isPackage: session.model.kind == .package))
        self.userStateURL = stateURL
        self.userState = stateURL.map(WorkspaceUserState.load(from:)) ?? WorkspaceUserState()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = session.model.displayName
        window.titleVisibility = .hidden  // the name shows in the activity view
        window.toolbarStyle = .unified
        if #available(macOS 26, *) {
            // No hard line under the glass toolbar (liquid-glass-ycode.md §1).
            window.titlebarSeparatorStyle = .none
        }
        window.minSize = NSSize(width: 700, height: 400)
        window.isRestorable = !Self.isTestProcess
        super.init(window: window)
        build()
        // Breakpoints persist per user with the container (§10.1); test
        // runs attach the file themselves.
        if !Self.isTestProcess { session.attachBreakpointFile() }
        // Session-side settings for a new window (later changes arrive
        // through applyPreferences).
        let prefs = Preferences.shared
        if session.includeLiveIssues != prefs.showLiveIssues { session.includeLiveIssues = prefs.showLiveIssues }
        session.stopOnFirstError = prefs.stopBuildOnFirstError
        session.reportHistoryLimit = prefs.reportHistoryLimit
        // Frame autosave and state restoration write to the user's
        // preferences; test runs skip both. A saved frame replaces the
        // default one.
        if !Self.isTestProcess { window.setFrameAutosaveName("YcodeWorkspace \(session.model.url.path)") }
        if startLanguageService {
            Task { await self.connectLanguageService(transport: nil) }
        }
        if loadDestinations {
            Task {
                let groups = await Task.detached { DestinationCatalog.load() }.value
                self.setDestinationGroups(groups)
                self.refreshRemoteRuntimeVersion()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    /// Connects an editor (every tab and split has its own) to the session.
    func wire(_ e: SourceEditorController) {
        e.onBreakpointClick = { [weak self] f, l in self?.session.breakpoints.click(file: f, line: l) }
        e.onBreakpointMove = { [weak self] f, a, b in self?.session.breakpoints.move(file: f, from: a, to: b) }
        e.onBreakpointRemove = { [weak self] f, l in self?.session.breakpoints.remove(file: f, line: l) }
        e.onBreakpointEdit = { [weak self] f, l in self?.editBreakpoint(file: f, line: l) }
        e.onRunTest = { [weak self] f, l in
            guard let self else { return }
            let only = self.session.testsForDiamond(file: f, line: l)
            if !only.isEmpty { Task { await self.session.runTests(only: only) } }
        }
        e.onQuickHelp = { [weak self] url, p, rect in self?.showQuickHelp(url: url, at: p, anchor: rect) }
        e.onJumpToDefinition = { [weak self] url, p in self?.jumpToDefinition(url: url, at: p) }
        wireEditorExtras(e)
        e.onSelectionChange = { [weak self] url, p in
            self?.debugArea.setPosition(line: p.line + 1, column: p.character + 1)
            guard let self, self.inspector.selectedIndex == 2, self.session.language != nil else { return }
            Task {
                let text = await self.session.hover(url, at: p)
                self.inspector.showQuickHelp(text, file: text == nil ? nil : await self.session.definition(url, at: p)?.url.path)
            }
        }
        e.onDocumentOpened = { [weak self] url, text in self?.session.language?.open(url, text: text) }
        e.onDocumentChanged = { [weak self, weak e] url, text in
            self?.session.language?.change(url, text: text)
            if let e { self?.noteDocumentEdited(e) }
        }
        e.completionProvider = { [weak self] url, p in await self?.session.completions(url, at: p) ?? [] }
        e.onSave = { [weak self] url in
            self?.session.language?.saved(url)
            self?.scheduleCanvasRefresh(url)
        }
        e.onDocumentClosed = { [weak self] url in
            // Closed for the server only when no other editor still shows it.
            guard let self, !self.editorArea.allEditors.contains(where: { $0.fileURL == url }) else { return }
            self.session.language?.close(url)
        }
        e.gutter.onFixIt = { [weak self] line in self?.applyFixIt(line: line) }
        // Jump bar (reference-ui-5.md §6.1): Related Items opens ⌃1's
        // menu; the assistant's close button; the issue arrows.
        e.onRelatedItems = { [weak self, weak e] in
            guard let self, let e else { return }
            self.editorArea.withFocus(e) { _ = self.popUpJumpBarMenu(.relatedItems) }
        }
        e.onClosePane = { [weak self, weak e] in
            guard let self, let e else { return }
            if e === self.editorArea.tab.assistant { self.editorArea.hideAssistant() } else { self.editorArea.withFocus(e) { _ = self.editorArea.closeFocusedEditor() } }
            self.updateToolbarState()
        }
        e.onPreviousIssue = { [weak self, weak e] in if let self, let e { self.editorArea.withFocus(e) { self.stepIssue(-1) } } }
        e.onNextIssue = { [weak self, weak e] in if let self, let e { self.editorArea.withFocus(e) { self.stepIssue(+1) } } }
        e.onPickIssue = { [weak e] line in e?.reveal(line: line) }
    }

    private func build() {
        // Center: editor above the debug area.
        centerSplit.splitView.isVertical = false
        centerSplit.splitView.dividerStyle = .thin
        // The editor with the debug bar under it: the bar stays when the
        // debug area is hidden.
        let editorColumn = NSViewController()
        let column = NSView()
        editorColumn.view = column
        editorColumn.addChild(editorArea)
        let bar = debugArea.debugBar
        _ = debugArea.view
        debugArea.setDebugging(false)
        for v in [editorArea.view, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(v)
        }
        // liquid-glass.md §2.6, §3.2 (macOS 26+): the editor runs under
        // the debug bar, a translucent bar with a hard edge; the editor's
        // safe area ends at the bar, so its text scrolls clear of it.
        let overlayBar = DebugAreaController.translucentBar
        if overlayBar { editorArea.view.additionalSafeAreaInsets = NSEdgeInsets(top: 0, left: 0, bottom: DebugAreaController.debugBarHeight, right: 0) }
        NSLayoutConstraint.activate([
            editorArea.view.topAnchor.constraint(equalTo: column.topAnchor),
            editorArea.view.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            editorArea.view.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            overlayBar ? editorArea.view.bottomAnchor.constraint(equalTo: column.bottomAnchor)
                : bar.topAnchor.constraint(equalTo: editorArea.view.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: column.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: column.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        let editorItem = NSSplitViewItem(viewController: editorColumn)
        debugItem = NSSplitViewItem(viewController: debugArea)
        debugItem.canCollapse = true
        debugItem.minimumThickness = 80
        debugItem.isCollapsed = true
        centerSplit.addSplitViewItem(editorItem)
        centerSplit.addSplitViewItem(debugItem)

        navigatorItem = NSSplitViewItem(sidebarWithViewController: navigator)
        navigatorItem.minimumThickness = 180
        navigatorItem.preferredThicknessFraction = Self.navigatorWidth / Self.defaultSize.width
        // The window's content runs under the toolbar (`.fullSizeContentView`,
        // liquid-glass-ycode.md §1); the editor and debug area split starts
        // below it, at the center column's safe area, so its heights are
        // the ones the specs measure.
        let centerColumn = NSViewController()
        centerColumn.view = NSView()
        centerColumn.addChild(centerSplit)
        let centerView = centerSplit.view
        centerView.translatesAutoresizingMaskIntoConstraints = false
        centerColumn.view.addSubview(centerView)
        NSLayoutConstraint.activate([
            centerView.topAnchor.constraint(equalTo: centerColumn.view.safeAreaLayoutGuide.topAnchor),
            centerView.leadingAnchor.constraint(equalTo: centerColumn.view.leadingAnchor),
            centerView.trailingAnchor.constraint(equalTo: centerColumn.view.trailingAnchor),
            centerView.bottomAnchor.constraint(equalTo: centerColumn.view.bottomAnchor),
        ])
        let centerItem = NSSplitViewItem(viewController: centerColumn)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 220
        mainSplit.addSplitViewItem(navigatorItem)
        mainSplit.addSplitViewItem(centerItem)
        mainSplit.addSplitViewItem(inspectorItem)
        window?.contentViewController = mainSplit

        let toolbar = NSToolbar(identifier: "YcodeWorkspaceToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
        labelSchemePill()
        observeLeftArea()
        // A divider drag sets the debug area's remembered height (§8.2).
        leftAreaObservation.tokens.append(NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
                                                                                object: centerSplit.splitView, queue: .main) { [weak self] n in
            guard n.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
            MainActor.assumeIsolated {
                guard let self, !self.debugItem.isCollapsed, self.debugArea.view.frame.height >= self.debugItem.minimumThickness else { return }
                self.userState.debugAreaHeight = Double(self.debugArea.view.frame.height)
            }
        })
        // 1400 × 900 including the toolbar (reference-ui-5.md §3.3, L5).
        if let w = window { w.setFrame(NSRect(origin: w.frame.origin, size: Self.defaultSize), display: false) }

        // Wiring.
        // Saved user data first: the tree expands from it (N4), the Start
        // Page lists the recent files (L9).
        navigator.recentFiles = userState.existingRecentFiles
        navigator.savedProjectExpansion = userState.expandedRows
        navigator.onProjectExpansionChange = { [weak self] keys in self?.updateUserState { $0.expandedRows = keys } }
        navigator.setProjectTree(session.model.root, packages: packageSection())
        navigator.addMenuItems = { [weak self] in self?.navigatorAddMenu($0) ?? [] }
        inspector.onRename = { [weak self] u, n in self?.renameFromInspector(u, to: n) }
        wireInspector()
        _ = bookmarks
        navigator.onOpen = { [weak self] path, line in self?.openFromNavigator(path: path, line: line) }
        prefsObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPreferences() }
        }
        wire(editor)
        editorArea.configure = { [weak self] e in self?.wire(e) }
        editorArea.onFocusChange = { [weak self] e in self?.editorFocused(e) }
        navigator.onAddBreakpoint = { [weak self] kind in
            switch kind {
            case .exception: self?.addExceptionBreakpoint(swift: false)
            case .swiftError: self?.addExceptionBreakpoint(swift: true)
            case .symbolic: self?.askSymbolicBreakpoint()
            default: self?.addSpecialBreakpoint(kind)
            }
        }
        navigator.onOpenReport = { [weak self] i in
            guard let self, i < self.session.reports.count else { return }
            self.inspector.show(file: nil)
            self.openReportPage(i, ReportNavigatorModel.defaultPage(self.session.reports[i]))
        }
        navigator.onOpenReportPage = { [weak self] i, page in self?.openReportPage(i, page) }
        navigator.onSelectFrame = { [weak self] id in Task { await self?.session.selectFrame(id) } }
        wireDebuggerUI()
        debugArea.onConsoleLine = { [weak self] line in await self?.session.evaluateInConsole(line) }
        debugArea.onFilterChange = { [weak self] in
            guard let self else { return }
            self.debugArea.setConsole(self.session.consoleText(self.debugArea.consoleFilter, metadata: self.debugArea.metadata))
        }
        debugArea.onVariableAction = { [weak self] action, v in self?.variableAction(action, v) }
        debugArea.loadChildren = { [weak self] ref in await self?.session.children(of: ref) ?? [] }
        session.observe { [weak self] change in self?.sessionChanged(change) }
        session.discoverTests()
        session.refreshProjectIssues()
        refreshFileStatus(nil)
        activityView.workspaceName = session.model.displayName
        activityView.isPackage = session.model.kind == .package
        navigator.workspaceName = session.model.displayName
        navigator.isPackage = session.model.kind == .package
        navigator.issueGrouping = { [weak self] in self?.session.issueGrouping ?? IssueGrouping(projectName: "") }   // reference-ui-6.md §5.1
        navigator.isWorkspace = session.model.kind == .workspace
        navigator.testPlanName = "\(session.scheme ?? session.model.displayName) (Autocreated)"
        navigator.testTarget = { [weak self] file in
            guard let self else { return "" }
            if self.session.model.kind == .package {
                // Tests/<Target>/…
                let parts = file.components(separatedBy: "/Tests/")
                if parts.count > 1, let t = parts.last?.split(separator: "/").first { return String(t) }
            }
            return self.session.model.targetName(compiling: file) ?? URL(fileURLWithPath: file).deletingLastPathComponent().lastPathComponent
        }
        navigator.containingGroups = { [weak self] in
            guard let self, let file = self.navigator.selectedPath ?? self.editor.fileURL?.path else { return [] }
            return Self.containingGroups(of: file, in: self.session.model.root)
        }
        reloadSchemes()
        // Opens with nothing selected: an empty editor whose jump bar reads
        // "No Selection" (reference-ui.md §2).
        if opensFirstFile { openFirstSourceFile() }
        updateWindowTitle()
        updateToolbarState()
    }

    /// Changes the workspace's user data and writes it (when it has a file).
    func updateUserState(_ change: (inout WorkspaceUserState) -> Void) {
        change(&userState)
        if let u = userStateURL { userState.save(to: u) }
    }

    // MARK: Window title (reference-ui-5.md §3.4, L4)

    /// "<workspace> — <document>".
    public static func windowTitle(workspace: String, document: String) -> String { "\(workspace) \u{2014} \(document)" }

    /// The focused editor's file name with extension; with no document,
    /// the container's file name.
    public var windowDocumentName: String {
        let e = editor
        if e.emptyView == nil {
            if let u = e.fileURL { return u.lastPathComponent }
            if e.auxiliary != nil {
                // A file shown in another editor (plist, catalog, project):
                // its file name with extension, not the jump bar's title.
                if let u = e.auxiliaryFile { return u.lastPathComponent }
                if let shown = e.pathComponents.last?.0, !shown.isEmpty { return shown }
            }
        }
        return session.model.url.lastPathComponent
    }

    public var windowTitle: String { Self.windowTitle(workspace: session.model.displayName, document: windowDocumentName) }

    func updateWindowTitle() {
        // Through the document machinery when there is a document, so its
        // own renames (adding the controller, saving, display-name
        // changes) and ours give the same title (reference-ui-6.md §1.1.3).
        if document != nil { synchronizeWindowTitleWithDocumentName() } else { window?.title = windowTitle }
    }

    /// NSDocument renames the window after its display name whenever the
    /// controller is attached or the document changes; the composed title
    /// replaces that name (reference-ui-6.md §1.1, W1).
    public override func windowTitle(forDocumentDisplayName displayName: String) -> String { windowTitle }

    let opensFirstFile: Bool

    /// The groups that contain `file` in the project tree, outermost
    /// first (folders with a path on disk).
    static func containingGroups(of file: String, in root: NavigatorNode) -> [(name: String, path: String)] {
        func walk(_ n: NavigatorNode, _ trail: [(String, String)]) -> [(String, String)]? {
            if n.path == file { return trail }
            for c in n.children {
                let next = c.children.isEmpty ? trail : trail + (c.path.map { [(c.name, $0)] } ?? [])
                if let t = walk(c, next) { return t }
            }
            return nil
        }
        return (walk(root, []) ?? []).map { (name: $0.0, path: $0.1) }
    }

    /// Opens the workspace's first Swift, Objective-C or C source file.
    public func openFirstSourceFile() {
        if let first = session.model.root.allFiles.first(where: { $0.name != "Package.swift" && ["swift", "m", "c"].contains(URL(fileURLWithPath: $0.name).pathExtension) }),
           let p = first.path {
            open(path: p, line: nil)
        }
    }

    /// Sets the split positions to the default proportions.
    public func applyDefaultLayout() {
        guard let w = window, let content = w.contentView else { return }
        mainSplit.view.frame = content.bounds
        mainSplit.view.layoutSubtreeIfNeeded()
        let total = mainSplit.splitView.bounds.width
        mainSplit.splitView.setPosition(Self.navigatorWidth, ofDividerAt: 0)
        mainSplit.splitView.setPosition(total - Self.inspectorWidth, ofDividerAt: 1)
        if !debugItem.isCollapsed {
            centerSplit.splitView.setPosition(centerSplit.splitView.bounds.height - debugAreaOpeningHeight, ofDividerAt: 0)
        }
    }

    private func reloadSchemes() {
        schemePopUp.removeAllItems()
        schemePopUp.addItems(withTitles: session.model.schemeNames)
        schemePopUp.selectItem(withTitle: session.scheme ?? "")
        chooseDefaultDestination()
        rebuildDestinationMenu()
    }

    // MARK: Opening files

    // MARK: New File / New Project

    /// The folder new files go to: the open file's folder, else the
    /// project directory (projects) or `Sources/<first>` (packages).
    public var newFileDirectory: URL {
        if let f = editor.fileURL { return f.deletingLastPathComponent() }
        switch session.model.kind {
        case .package:
            let sources = session.model.url.appendingPathComponent("Sources")
            let first = (try? FileManager.default.contentsOfDirectory(atPath: sources.path))?.sorted().first
            return first.map { sources.appendingPathComponent($0) } ?? session.model.url
        default:
            let projPath = session.model.projects.keys.sorted().first
            return projPath.flatMap { p in session.model.projects[p].map { $0.projectDirectory(xcodeprojURL: URL(fileURLWithPath: p)) } }
                ?? session.model.url.deletingLastPathComponent()
        }
    }

    /// Creates files from a template in `newFileDirectory`, updates the
    /// project, refreshes the navigator and opens the first new file.
    @discardableResult
    public func createFile(_ template: FileTemplate, name: String) throws -> [URL] {
        let projPath = session.model.kind == .package ? nil : session.model.projects.keys.sorted().first {
            newFileDirectory.path.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path)
        }
        var proj = projPath.flatMap { session.model.projects[$0] }
        let urls = try FileCreator.create(template, name: name, in: newFileDirectory, project: &proj,
                                          xcodeprojURL: projPath.map { URL(fileURLWithPath: $0) })
        if let projPath, let proj, proj.objects != session.model.projects[projPath]?.objects {
            projectChanged(path: projPath, proj)
        } else if session.model.kind == .package {
            session.model.root = NavigatorTree.package(at: session.model.url)
            navigator.setProjectTree(session.model.root, packages: packageSection())
        } else if let projPath, let proj {
            // Synchronized folder: the tree re-reads the directory.
            session.model.root = NavigatorTree.project(proj, xcodeprojURL: URL(fileURLWithPath: projPath))
            navigator.setProjectTree(session.model.root, packages: packageSection())
        }
        if let first = urls.first { open(path: first.path, line: nil) }
        return urls
    }

    /// Creates files from a sheet template in `directory` (default
    /// `newFileDirectory`), as `createFile(_:name:)` does.
    @discardableResult
    public func createFile(entry: TemplateEntry, name: String, in directory: URL? = nil, targets: [String]? = nil,
                           platform: String? = nil) throws -> [URL] {
        let dir = (directory ?? newFileDirectory).standardizedFileURL
        let projPath = session.model.kind == .package ? nil : session.model.projects.keys.sorted().first {
            dir.path.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path)
        }
        var proj = projPath.flatMap { session.model.projects[$0] }
        let urls = try FileTemplateCatalog.create(entry, name: name, in: dir, platform: platform ?? preferredTemplatePlatform, project: &proj,
                                                  xcodeprojURL: projPath.map { URL(fileURLWithPath: $0) }, targets: targets)
        if let projPath, let proj, proj.objects != session.model.projects[projPath]?.objects {
            projectChanged(path: projPath, proj)
        } else if session.model.kind == .package {
            session.model.root = NavigatorTree.package(at: session.model.url)
            navigator.setProjectTree(session.model.root, packages: packageSection())
        } else if let projPath, let proj {
            session.model.root = NavigatorTree.project(proj, xcodeprojURL: URL(fileURLWithPath: projPath))
            navigator.setProjectTree(session.model.root, packages: packageSection())
        }
        if let first = urls.first { open(path: first.path, line: nil) }
        return urls
    }

    /// The platform tab the sheets open on: the product's platform.
    var preferredTemplatePlatform: String {
        let proj = session.model.projects.keys.sorted().first.flatMap { session.model.projects[$0] }
        let p = proj.map { DestinationMenuModel.platforms(of: $0).platforms } ?? []
        return ["iOS", "macOS", "watchOS", "tvOS", "visionOS"].first { p.contains($0) } ?? (session.model.kind == .package ? "macOS" : "iOS")
    }

    /// File ▸ New ▸ File from Template… (⌘N): the template sheet, then
    /// the save step; Cancel in the save step returns to the sheet.
    @discardableResult
    @objc public func newFile(_ sender: Any?) -> NewFileSheetController {
        let sheet = NewFileSheetController(platform: preferredTemplatePlatform)
        sheet.onNext = { [weak self, weak sheet] entry in
            guard let self, let sheet else { return }
            if sheet.presentingViewController != nil { sheet.dismiss(nil) }
            self.runSaveStep(entry, sheet: sheet)
        }
        if window?.isVisible == true { contentViewController?.presentAsSheet(sheet) }
        return sheet
    }

    /// Group pop-up and Targets checkboxes for the save step.
    func saveAccessory() -> SaveStepAccessory {
        let projPath = session.model.kind == .package ? nil : session.model.projects.keys.sorted().first
        return SaveStepAccessory(proj: projPath.flatMap { session.model.projects[$0] }, xcodeprojURL: projPath.map { URL(fileURLWithPath: $0) },
                                 selectedFile: editor.fileURL, directory: newFileDirectory)
    }

    func runSaveStep(_ entry: TemplateEntry, sheet: NewFileSheetController) {
        guard let window, window.isVisible else { return }
        let panel = NSSavePanel()
        panel.nameFieldLabel = "Save As:"
        panel.nameFieldStringValue = entry.defaultName
        panel.directoryURL = newFileDirectory
        panel.showsTagField = true
        panel.prompt = "Create"
        let accessory = saveAccessory()
        accessory.onGroupChange = { [weak panel] in panel?.directoryURL = $0 }
        panel.accessoryView = accessory.view
        panel.beginSheetModal(for: window) { [weak self] r in
            guard let self else { return }
            guard r == .OK, let url = panel.url else {
                self.contentViewController?.presentAsSheet(sheet)
                return
            }
            do {
                try self.createFile(entry: entry, name: url.lastPathComponent, in: url.deletingLastPathComponent(),
                                    targets: accessory.targets.isEmpty ? nil : accessory.checkedTargets, platform: sheet.platform)
            } catch { NSApp.presentError(error) }
        }
    }

    /// File ▸ New ▸ Empty File: an empty "File" (or "File 2", …) next to
    /// the open file.
    @discardableResult
    @objc public func newEmptyFile(_ sender: Any?) -> URL? {
        let dir = newFileDirectory
        var name = "File", n = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { n += 1; name = "File \(n)" }
        return try? createFile(entry: TemplateEntry("Empty"), name: name, in: dir).first
    }

    /// File ▸ New ▸ Folder (⌥⌘N): "New Folder" (or "New Folder 2", …).
    @discardableResult
    @objc public func newFolder(_ sender: Any?) -> URL? {
        let dir = newFileDirectory
        var name = "New Folder", n = 1
        while FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { n += 1; name = "New Folder \(n)" }
        let u = dir.appendingPathComponent(name)
        guard (try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)) != nil else { return nil }
        if session.model.kind == .package {
            session.model.root = NavigatorTree.package(at: session.model.url)
            navigator.setProjectTree(session.model.root, packages: packageSection())
        }
        return u
    }

    /// File ▸ New ▸ Project… (⇧⌘N): the compact picker. Choose Template…
    /// opens an empty window with the template sheet.
    @discardableResult
    @objc public func newProject(_ sender: Any?) -> NewProjectPickerController {
        let picker = NewProjectPickerController()
        picker.onChoose = { [weak self] i in self?.projectPickerChose(i) }
        if window?.isVisible == true { contentViewController?.presentAsSheet(picker) }
        return picker
    }

    /// Remembers the last project template (tests pass their own).
    public var templateDefaults: UserDefaults = Preferences.shared.defaults
    /// The last New Project failure (shown as an alert when visible).
    public private(set) var lastNewProjectError: String?

    /// Where new projects go when no save step runs (tests, headless).
    public var newProjectLocation = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")

    func reportNewProjectError(_ text: String) {
        lastNewProjectError = text
        if window?.isVisible == true {
            NSApp.presentError(NSError(domain: "Ycode", code: 1, userInfo: [NSLocalizedDescriptionKey: text]))
        }
    }

    @discardableResult
    func projectPickerChose(_ i: Int) -> NewProjectSheetController {
        NewProjectFlow.start(row: i, defaults: templateDefaults, location: newProjectLocation, parent: window,
                             interactive: window?.isVisible == true,
                             onCreated: { [weak self] url in
                                 guard let self else { return }
                                 self.lastCreatedProject = url
                                 if self.window?.isVisible == true {
                                     NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                                 }
                             },
                             onError: { [weak self] in self?.reportNewProjectError($0) })
    }

    // MARK: Package dependencies

    /// Where remote packages are checked out; nil = the per-project cache
    /// (`PackageDependencyModel.defaultCheckouts`). Tests set a temporary folder.
    public var packageCheckoutsDirectory: URL?

    /// The project packages are added to: the first project.
    var packageProjectPath: String? { session.model.kind == .package ? nil : session.model.projects.keys.sorted().first }

    public func packageModel() -> PackageDependencyModel? {
        guard let path = packageProjectPath, let proj = session.model.projects[path] else { return nil }
        return PackageDependencyModel(proj: proj, xcodeprojURL: URL(fileURLWithPath: path), checkoutsDirectory: packageCheckoutsDirectory)
    }

    /// The navigator's Package Dependencies section for the project.
    func packageSection() -> NavigatorNode? {
        session.model.kind == .project ? packageModel()?.navigatorSection() : nil
    }

    /// File ▸ Add Package Dependencies…: fetches the package, then links
    /// the chosen products, writes the project and `Package.resolved`.
    @discardableResult
    @objc public func addPackageDependencies(_ sender: Any?) -> AddPackageController? {
        guard var pm = packageModel(), let path = packageProjectPath else { NSSound.beep(); return nil }
        let sheet = AddPackageController(targets: pm.proj.targets.compactMap { $0.string("name") })
        var packageID: String?
        sheet.onFetch = { location, requirement in
            // Resolving clones and reads the manifest: off the main thread.
            let start = pm
            let (next, result) = await Task.detached { () -> (PackageDependencyModel, Result<(id: String, products: [String]), Error>) in
                var model = start
                let r = Result { try model.addPackage(location, requirement: requirement) }
                return (model, r)
            }.value
            pm = next
            return result.map { added in
                packageID = added.id
                return added.products
            }
        }
        sheet.onLink = { [weak self] products, target in
            guard let self, let packageID else { return }
            pm.link(products, package: packageID, target: target)
            self.projectChanged(path: path, pm.proj)
            self.resolvePackages()
            self.projectEditor?.reload(proj: pm.proj)
        }
        if window?.isVisible == true { contentViewController?.presentAsSheet(sheet) }
        return sheet
    }

    /// Shows a report's page (reference-ui-2.md §4.4): Insights, Coverage
    /// and Tests are test report pages; Log and Build the build log.
    func openReportPage(_ i: Int, _ page: String) {
        guard i < session.reports.count else { return }
        let r = session.reports[i]
        editor.showText(r.log.joined(separator: "\n"), title: r.title)
        let v: NSView = switch page {
        case "Tests": TestReportView(report: r, page: .tests)
        case "Coverage": TestReportView(report: r, page: .coverage)
        case "Insights": TestReportView(report: r, page: .summary)
        default: BuildLogView(report: r)
        }
        editor.showAuxiliary(v, path: [(r.schemeName, "square.stack.3d.up"), (r.kind == .test ? page : r.title, "doc.plaintext")])
    }

    /// The last resolution failure (also an issue in the issue navigator).
    public private(set) var lastPackageError: String?

    /// File > Resolve Package Versions: resolves every package (and their
    /// dependencies) in the background, writes `Package.resolved`, and
    /// reports a failure as an error in the issue navigator.
    @objc public func resolvePackages(_ sender: Any? = nil) {
        let previous = packageWork
        packageWork = Task { [weak self] in
            await previous?.value
            _ = await self?.resolvePackageVersions()
        }
    }

    /// The package resolution started by `resolvePackages(_:)`, if any.
    public private(set) var packageWork: Task<Void, Never>?

    /// Resolves the packages off the main thread; whether it succeeded.
    @discardableResult
    public func resolvePackageVersions() async -> Bool {
        guard let start = packageModel() else { return false }
        let failure = await Task.detached { () -> String? in
            var pm = start
            do { try pm.resolveAll(); return nil } catch { return "\(error)" }
        }.value
        if let failure {
            lastPackageError = failure
            session.packageIssues = [Diagnostic(severity: .error, message: "Package resolution failed: \(failure)")]
        } else {
            lastPackageError = nil
            session.packageIssues = []
        }
        // The Report navigator's Package group (reference-ui-2.md §4.2).
        var c = ReportContext()
        c.action = "Resolve Packages"
        c.containerKind = session.model.kind == .package ? "Package" : "Project"
        c.containerName = session.model.displayName
        c.issues = session.packageIssues
        session.recordReport(BuildReport(title: "Resolve Packages", date: Date(), succeeded: lastPackageError == nil,
                                         log: lastPackageError.map { [$0] } ?? [], errorCount: lastPackageError == nil ? 0 : 1, warningCount: 0, context: c))
        if session.model.kind == .project {
            navigator.setProjectTree(session.model.root, packages: packageSection())
        }
        return lastPackageError == nil
    }

    /// Adds a language to the knownRegions of the project that holds a file
    /// (the first project when none contains it).
    func addKnownRegion(_ code: String, forFileAt file: String) {
        let paths = session.model.projects.keys.sorted()
        guard let path = paths.first(where: { file.hasPrefix(URL(fileURLWithPath: $0).deletingLastPathComponent().path + "/") }) ?? paths.first,
              var proj = session.model.projects[path] else { return }
        let before = proj.objects
        proj.addKnownRegion(code)
        if proj.objects != before { projectChanged(path: path, proj) }
    }

    /// What the last New Project created (for tests and scripting).
    public private(set) var lastCreatedProject: URL?

    /// The asset catalog editor, while it is shown.
    public private(set) var assetEditor: AssetCatalogEditorController? { didSet { updateAssetInspector(previous: oldValue) } }

    /// The Interface Builder document editor (read-only), while it is shown.
    public private(set) var interfaceEditor: InterfaceBuilderController? { didSet { updateInterfaceInspectors() } }

    /// While an Interface Builder document is shown, the inspector area
    /// adds its Identity, Attributes, Size and Connections inspectors.
    func updateInterfaceInspectors() {
        guard let ib = interfaceEditor else {
            inspector.setExtraInspectors([], provider: nil)
            library?.objectsAvailable = false
            return
        }
        let tabs = InterfaceBuilderController.InspectorTab.allCases
        inspector.setExtraInspectors(tabs.map { ($0.title, $0.symbol) }, provider: { [weak ib] i in
            ib?.inspectorView(tabs[i]) ?? NSView()
        }, select: CommandTable.inspectors.count + InterfaceBuilderController.InspectorTab.attributes.rawValue)
        ib.onChange = { [weak self] in self?.inspector.refresh() }
        library?.objectsAvailable = true
    }

    /// The String Catalog editor, while it is shown.
    public private(set) var stringCatalogEditor: StringCatalogEditorController?

    /// The property-list editor, while it is shown.
    public private(set) var plistEditor: PlistEditorController?

    /// The project editor, while it is shown.
    public private(set) var projectEditor: ProjectEditorController?

    /// Opens a project in the project editor (selecting its row does this).
    @discardableResult
    public func openProjectEditor(_ path: String) -> ProjectEditorController? {
        guard let proj = session.model.projects[path] else { return nil }
        let url = URL(fileURLWithPath: path)
        var model = ProjectEditorModel(proj: proj, xcodeprojURL: url)
        if let helper = SwiftBuildSettingsSource.locate() {
            // Defaults from swift-build's specifications, cached per
            // (target, configuration). The helper runs in the background;
            // until it answers the editor shows the levels without them,
            // then reloads.
            final class Cache { var values: [String: [String: String]] = [:]; var pending: Set<String> = [] }
            let cache = Cache()
            model.defaultsProvider = { [weak self] target, configuration in
                let key = "\(target ?? "")|\(configuration)"
                if let hit = cache.values[key] { return hit }
                guard let self, let current = self.session.model.projects[path] else { return [:] }
                guard cache.pending.insert(key).inserted else { return nil }
                Task { [weak self] in
                    let d = await Task.detached {
                        (try? DefaultsLevel.swiftBuildDefaults(proj: current, xcodeprojURL: url, target: target,
                                                               configuration: configuration, helper: helper)) ?? [:]
                    }.value
                    cache.values[key] = d
                    cache.pending.remove(key)
                    guard let self, let editor = self.projectEditor, let proj = self.session.model.projects[path] else { return }
                    editor.reload(proj: proj)
                }
                return nil
            }
        }
        let c = ProjectEditorController(model: model)
        c.onChange = { [weak self] edited in self?.projectChanged(path: path, edited) }
        c.onAddPackage = { [weak self] in self?.addPackageDependencies(nil) }
        projectEditor = c
        editor.showAuxiliary(c.view, path: [(url.deletingPathExtension().lastPathComponent, "folder.badge.gearshape")], file: url)
        inspector.show(file: nil)
        return c
    }

    /// Project edits are written at once, through the pbxproj writer.
    func projectChanged(path: String, _ proj: PBXProj) {
        session.model.projects[path] = proj
        do { try session.model.saveProjects() } catch { presentError(error) }
        session.refreshProjectIssues()
        if session.model.kind == .project {
            session.model.root = NavigatorTree.project(proj, xcodeprojURL: URL(fileURLWithPath: path))
            navigator.setProjectTree(session.model.root, packages: packageSection())
        }
        refreshFileStatus(nil)
    }

    /// Opens a file in the focused editor, recording it in that editor's
    /// history; the assistant (if shown) follows with a counterpart.
    public func open(path: String, line: Int?) {
        var recent = navigator.recentFiles
        recent.removeAll { $0 == path }
        navigator.recentFiles = recent + [path]
        updateUserState { $0.noteRecentFile(path) }
        editor.history.visit(path)
        display(path: path, line: line)
        updateCounterparts()
        updateWindowTitle()
    }

    // MARK: Tabs, splits, history, assistant

    /// The workspace's files (absolute paths), for counterparts.
    var workspaceFiles: [String] { session.model.root.allFiles.compactMap(\.path) }

    /// Counterparts of the focused editor's file: shown in its jump bar,
    /// and the first one in the assistant editor when it is shown.
    /// What the assistant follows (Editor ▸ Assistant Mode, or its jump-bar pop-up).
    public private(set) var assistantMode: AssistantMode = .counterparts
    /// The §16 modes that are not file-list modes (Callers, …).
    let assistantExtra = AssistantExtraState()
    /// Debug ▸ Debug Workflow toggles (reference-ui-5.md §2.10): open the
    /// stop's file when the process pauses (on), move the caret to the
    /// program counter (off). `lastShownLocation` is the stop and frame
    /// last shown.
    public var navigatesToSourceOnPause = true
    public var synchronizesInsertionPoint = false
    var lastShownLocation: String?

    public func setAssistantMode(_ m: AssistantMode) {
        assistantMode = m
        assistantExtra.customMode = nil
        updateCounterparts()
    }

    /// Editor ▸ Assistant Mode ▸ …: the item's tag is the mode's index.
    @objc public func chooseAssistantMode(_ sender: Any?) {
        let i = (sender as? NSMenuItem)?.tag ?? 0
        if AssistantMode.allCases.indices.contains(i) { setAssistantMode(AssistantMode.allCases[i]) }
    }

    func updateCounterparts() {
        let e = editor
        guard e !== editorArea.tab.assistant else { return }
        let current = e.fileURL?.path ?? e.history.current
        // The focused editor's menu lists counterparts; the assistant follows its mode.
        let list = current.map { Counterparts.of($0, in: workspaceFiles) } ?? []
        let modeList = current.map { assistantMode.files(for: $0, in: workspaceFiles) } ?? []
        if let a = editorArea.tab.assistant, let current {
            let modes = AssistantMode.available(for: current)
            if !modes.contains(assistantMode) { assistantMode = .counterparts }
            configureAssistantModes(a, current: current)  // +Assistant.swift (reference-ui-4.md §16)
            a.setCounterparts(modeList.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }) { [weak self, weak a] path in
                if let self, let a { self.open(path: path, line: nil, in: a) }
            }
        }
        e.setCounterparts(list.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }) { [weak self, weak e] path in
            guard let self else { return }
            if let a = self.editorArea.tab.assistant { self.open(path: path, line: nil, in: a) } else if let e { self.open(path: path, line: nil, in: e) }
        }
        if let a = editorArea.tab.assistant, let current, assistantExtra.customMode != nil {
            showCustomAssistantMode(a, current: current)
        } else if let a = editorArea.tab.assistant, assistantMode != .manual {
            if let first = (assistantMode == .counterparts ? list : modeList).first {
                if a.fileURL?.path != first { open(path: first, line: nil, in: a) }
            } else {
                a.showText("No Editor", title: "No Editor")
            }
        }
    }

    func editorFocused(_ e: SourceEditorController) {
        if let url = e.fileURL { inspector.show(file: url) }
        editorArea.reloadTabBar()
        updateWindowTitle()
        updateToolbarState()
    }

    func goBack(in e: SourceEditorController) {
        guard let p = e.history.back() else { return }
        editorArea.withFocus(e) { display(path: p, line: nil); updateCounterparts() }
        updateWindowTitle()
    }

    func goForward(in e: SourceEditorController) {
        guard let p = e.history.forward() else { return }
        editorArea.withFocus(e) { display(path: p, line: nil); updateCounterparts() }
        updateWindowTitle()
    }

    /// Navigate ▸ Go Back (⌃⌘←) / Go Forward (⌃⌘→), in the focused editor.
    @objc public func goBack(_ sender: Any?) { goBack(in: editor) }
    @objc public func goForward(_ sender: Any?) { goForward(in: editor) }

    /// File ▸ New ▸ Tab (⌘T): a new editor tab showing the Start Page, or
    /// the same file (Settings ▸ Navigation ▸ New Editor Tabs Open With).
    @objc public func newTab(_ sender: Any?) {
        let current = editor.history.current
        let e = editorArea.newTab()
        if Preferences.shared.newEditorTabsOpenWith == .sameDocument, let current { open(path: current, line: nil) } else { showEmptyEditor(e); updateWindowTitle() }
        editorArea.reloadTabBar()
    }

    /// File ▸ Close Tab (⌘W): closes the tab; with one tab, the window.
    @objc public func closeTab(_ sender: Any?) {
        if !editorArea.closeTab() { window?.performClose(sender) }
    }

    /// Window ▸ Show Next / Previous Tab (⇧⌘] / ⇧⌘[).
    @objc public func selectNextTab(_ sender: Any?) { editorArea.selectNextTab() }
    @objc public func selectPreviousTab(_ sender: Any?) { editorArea.selectPreviousTab() }

    /// Editor ▸ Split Editor (⌃⌘T, side by side) / Split Editor Below
    /// (⌥⌃⌘T): a new editor showing the same file.
    @objc public func splitEditor(_ sender: Any?) { split(sideBySide: true) }
    @objc public func splitEditorBelow(_ sender: Any?) { split(sideBySide: false) }

    /// The new pane shows the focused pane's file, or the Start Page
    /// (Settings ▸ Navigation ▸ New Editor Panes Open With).
    func split(sideBySide: Bool) {
        let current = editor.history.current
        let e = editorArea.split(sideBySide: sideBySide)
        if Preferences.shared.newEditorPanesOpenWith == .sameDocument, let current { open(path: current, line: nil, in: e) } else { showEmptyEditor(e); updateWindowTitle() }
    }

    /// View ▸ Show / Hide Editor Tab Bar.
    @objc public func toggleEditorTabBar(_ sender: Any?) { editorArea.showsTabBar.toggle() }

    /// View ▸ Pin Editor Tab (⇧⌘P).
    @objc public func togglePinEditorTab(_ sender: Any?) { editorArea.togglePin() }

    /// File ▸ Close "<file>" (⌃⌘W): the focused editor stops showing its
    /// file (it becomes empty, "No Selection").
    @objc public func closeDocument(_ sender: Any?) {
        guard editor.fileURL != nil else { NSSound.beep(); return }
        try? editor.save()
        editor.closeFile()
        inspector.show(file: nil)
        editorArea.reloadTabBar()
    }

    /// File ▸ Close Workspace (⌃⌥⌘W): closes the workspace document.
    @objc public func closeWorkspace(_ sender: Any?) {
        if let d = document as? NSDocument { d.close() } else { window?.performClose(sender) }
    }

    /// File ▸ Duplicate Editor Tab: a new tab showing the same file.
    @objc public func duplicateEditorTab(_ sender: Any?) {
        let current = editor.fileURL?.path
        editorArea.newTab()
        if let current { open(path: current, line: nil) }
    }

    /// File ▸ Open in New Tab (⌥⌘O): the navigator's selected file (or
    /// the current one) in a new tab.
    @objc public func openInNewTab(_ sender: Any?) {
        guard let path = navigator.selectedPath ?? editor.fileURL?.path else { NSSound.beep(); return }
        editorArea.newTab()
        open(path: path, line: nil)
    }

    /// File ▸ Open with External Editor: the file's default application.
    @objc public func openWithExternalEditor(_ sender: Any?) {
        guard let url = editor.fileURL, window?.isVisible == true else { return }
        NSWorkspace.shared.open(url)
    }

    /// File ▸ Close Editor Pane (⌃⇧⌘W): closes the focused split.
    @objc public func closeEditor(_ sender: Any?) {
        if editor === editorArea.tab.assistant { editorArea.hideAssistant() } else { editorArea.closeFocusedEditor() }
        updateToolbarState()
    }

    /// Editor ▸ Assistant (⌃⌥⌘↩): shows or hides the assistant editor,
    /// which follows the focused editor's first counterpart.
    @objc public func toggleAssistant(_ sender: Any?) {
        defer { updateToolbarState() }
        if editorArea.tab.assistant != nil { editorArea.hideAssistant(); return }
        endEditorModes(except: .assistant)   // reference-ui-5.md §4.2
        editorArea.showAssistant()
        updateCounterparts()
    }

    // MARK: Refactoring state (see WorkspaceWindowController+Refactoring.swift)

    /// Previous text of files a refactoring rewrote on disk (not open).
    public internal(set) var refactoringBackups: [String: String] {
        get { refactoringStore.backups }
        set { refactoringStore.backups = newValue }
    }
    /// The rename in progress: file, position and current name.
    var renameState: (URL, Position, String)? {
        get { refactoringStore.rename }
        set { refactoringStore.rename = newValue }
    }
    /// A multi-file rename waiting for confirmation.
    public internal(set) var renamePreview: WorkspaceEdit? {
        get { refactoringStore.preview }
        set { refactoringStore.preview = newValue }
    }
    /// The last code actions fetched at the caret (the Refactor menu).
    public internal(set) var cachedCodeActions: [CodeAction] {
        get { refactoringStore.actions }
        set { refactoringStore.actions = newValue }
    }

    // MARK: Previews canvas

    /// The canvas, while shown (Editor ▸ Canvas, ⌥⌘↩).
    public private(set) var canvas: PreviewCanvasController?
    /// Where preview hosts are generated.
    public var previewWorkDirectory = PreviewRenderer.defaultWorkDirectory
    /// Seconds to wait after a save before refreshing.
    public var canvasRefreshDelay: TimeInterval = 0.8
    /// The refresh in flight (tests await it).
    public private(set) var previewTask: Task<Void, Never>?
    private var canvasDebounce: Task<Void, Never>?
    /// The preview build's activity text while it is shown (P15) and what
    /// the activity view showed before it.
    var previewActivityState: PreviewActivityState?
    var previewActivityGeneration = 0

    /// Canvas mode (`CanvasAutoShow`, reference-ui-6.md §4.4, E7 / E10).
    let canvasAuto = CanvasAutoState()

    /// Editor ▸ Canvas (⌥⌘↩) and the toolbar's Canvas segment: turns canvas
    /// mode off or on (`setCanvasMode`).
    @objc public func toggleCanvas(_ sender: Any?) {
        setCanvasMode(!canvasAuto.modeOn)
    }

    /// Shows or hides the canvas (the toggle and the automatic show).
    func setCanvasShown(_ show: Bool) {
        defer { updateToolbarState() }
        guard show != (canvas != nil) else { return }
        if !show {
            canvas = nil
            editorArea.hideCanvas()
            return
        }
        endEditorModes(except: .canvas)   // reference-ui-5.md §4.2
        let c = PreviewCanvasController()
        c.devices.automatic = session.destination?.name ?? "My Mac"
        c.onRefresh = { [weak self] in self?.refreshPreviews() }
        canvas = c
        editorArea.showCanvas(c)
        refreshPreviews()
    }

    /// Discovers the focused Swift file's previews, builds the preview host
    /// in the background and shows the result.
    @discardableResult
    public func refreshPreviews() -> Task<Void, Never>? {
        guard let c = canvas else { return nil }
        guard let url = editor.fileURL, url.pathExtension == "swift" else {
            c.setNames([])
            c.setState(.empty("No Previews"))
            return nil
        }
        try? editor.save()
        let text = editor.text
        let previews = PreviewDiscovery.previews(in: text)
        c.setNames(previews.map(\.name))
        c.tabTitles = previews.map(\.tabTitle)
        guard !previews.isEmpty else { c.setState(.empty("No Previews")); return nil }
        // Paused until the first build is asked for (reference-ui-4.md §10).
        guard !c.isPaused else { return nil }
        // The module is found in the background too: a package's needs
        // `swift package dump-package`.
        let kind = session.model.kind, packageDirectory = session.model.url, projects = session.model.projects
        c.setState(.building)
        let activity = beginPreviewActivity()
        let renderer = PreviewRenderer(workDirectory: previewWorkDirectory)
        let tool = PreviewRenderer.engine(for: kind == .package ? .package : .project, swiftBuild: SwiftBuildEngine.locate())
        previewTask?.cancel()
        let task = Task { [weak self, weak c] in
            let result = await Task.detached { () -> Result<[PreviewRenderer.Rendered], PreviewRenderer.Failure> in
                let module: PreviewRenderer.Module
                do throws(PreviewRenderer.Failure) {
                    switch kind {
                    case .package: module = try PreviewRenderer.packageModule(for: url, packageDirectory: packageDirectory)
                    default:
                        guard let (path, proj) = projects.first(where: { url.path.hasPrefix(URL(fileURLWithPath: $0.key).deletingLastPathComponent().path + "/") })
                            ?? projects.first.map({ ($0.key, $0.value) }) else {
                            throw PreviewRenderer.Failure.unsupportedTarget("no project")
                        }
                        module = try PreviewRenderer.projectModule(for: url, project: proj, xcodeprojURL: URL(fileURLWithPath: path))
                    }
                } catch { return .failure(error) }
                do throws(PreviewRenderer.Failure) { return .success(try renderer.render(module: module, file: url, previews: previews, schemes: [.light, .dark], swiftBuild: tool)) } catch { return .failure(error) }
            }.value
            self?.endPreviewActivity(activity)
            guard !Task.isCancelled, let c, self?.canvas === c else { return }
            switch result {
            case .success(let r): c.setState(.rendered(r))
            case .failure(let e): c.setState(.failed(e.description))
            }
        }
        previewTask = task
        return task
    }

    /// After a save: refresh once edits pause.
    func scheduleCanvasRefresh(_ url: URL) {
        guard url == editor.fileURL else { return }
        // Canvas mode with no canvas drawn: a saved preview brings it up (E10).
        guard canvas != nil else { if canvasAuto.modeOn { updateCanvasForOpenedFile() }; return }
        canvasDebounce?.cancel()
        let delay = canvasRefreshDelay
        canvasDebounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.refreshPreviews()
        }
    }

    /// The debounced refresh in flight, if any (tests await it).
    public var pendingCanvasRefresh: Task<Void, Never>? { canvasDebounce }

    // MARK: Settings applied to the window

    /// Appearance, live issues, file extensions in the navigator.
    public func applyPreferences() {
        let p = Preferences.shared
        // An explicit choice overrides; System restores the window's own.
        if let ap = p.nsAppearance { window?.appearance = ap; appearanceFromSettings = true }
        else if appearanceFromSettings { window?.appearance = nil; appearanceFromSettings = false }
        if session.includeLiveIssues != p.showLiveIssues { session.includeLiveIssues = p.showLiveIssues }
        session.stopOnFirstError = p.stopBuildOnFirstError
        if session.reportHistoryLimit != p.reportHistoryLimit { session.reportHistoryLimit = p.reportHistoryLimit }
        navigator.applyDisplayPreferences()
        if session.model.kind != .package || true { navigator.setProjectTree(session.model.root, packages: packageSection()) }
        // The jump bars follow the file-extension setting too (§4.1, E1).
        for e in editorArea.allEditors {
            if let u = e.fileURL { let path = jumpPath(for: u); if path.map(\.0) != e.pathComponents.map(\.0) { e.pathComponents = path } }
        }
        if sourceControlCache.enabled != p.sourceControlEnabled {
            sourceControlCache.enabled = p.sourceControlEnabled
            refreshFileStatus(nil)
        }
        if showsRegistersCache != p.showRegisters {
            showsRegistersCache = p.showRegisters
            session.showRegisters = p.showRegisters
        }
    }

    /// A navigator row was clicked: Settings ▸ Navigation routes it by the
    /// click's modifiers and count (reference-ui-5.md §9.2).
    func openFromNavigator(path: String, line: Int?) {
        var mods: NSEvent.ModifierFlags = []
        var clicks = 1
        if let e = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(e.type) {
            mods = e.modifierFlags
            clicks = e.clickCount
        }
        openFromNavigator(path: path, line: line, modifiers: mods, clickCount: clicks)
    }

    /// Opens a navigator selection: in the focused editor pane (a pinned
    /// tab is not replaced: the file opens in a new tab to its right,
    /// reference-ui-2.md §8), in a new unpinned tab (⌥-click by default),
    /// or in the next editor pane, created when there is none (⌥⇧-click).
    public func openFromNavigator(path: String, line: Int?, modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) {
        sourceControl.hideEditor()
        switch Preferences.shared.navigationTarget(modifiers: modifiers, clickCount: clickCount) {
        case .newUnpinnedTab:
            editorArea.newTab()
            open(path: path, line: line)
            editorArea.reloadTabBar()
            return
        case .nextPane:
            let t = editorArea.tab
            let panes = t.editors.filter { $0 !== t.assistant }
            let next: SourceEditorController
            if panes.count > 1, let i = panes.firstIndex(where: { $0 === t.focusedEditor }) {
                next = panes[(i + 1) % panes.count]
            } else {
                next = editorArea.split(sideBySide: true)
            }
            editorArea.focus(next)
            open(path: path, line: line)
            return
        case .focusedPane, .sameAsClick: break
        }
        switch EditorTabPolicy.openTarget(path: path, currentPath: editor.fileURL?.path, currentPinned: editorArea.tab.isPinned,
                                          openInTabs: false,
                                          tabPaths: editorArea.tabs.map { $0.editors.compactMap { $0.fileURL?.path } }) {
        case .current: break
        case .select(let i): editorArea.selectTab(i)
        case .newTab: editorArea.newTab()
        }
        open(path: path, line: line)
    }

    /// Pin Editor Tabs ▸ Automatically: editing a document pins its tab.
    func noteDocumentEdited(_ e: SourceEditorController) {
        guard Preferences.shared.pinEditorTabs == .automatically,
              let t = editorArea.tabs.first(where: { $0.editors.contains { $0 === e } }), !t.isPinned else { return }
        t.isPinned = true
        editorArea.reloadTabBar()
    }

    /// The last behavior run (event and what it did), for tests and the spec.
    public private(set) var lastBehavior: (event: Preferences.Event, behavior: Preferences.Behavior)? {
        get { behaviorStore.last }
        set { behaviorStore.last = newValue }
    }

    /// Settings ▸ Behaviors on Ycode's own build and run events.
    func applyBehaviors(for a: WorkspaceSession.Activity) {
        let event: Preferences.Event?
        switch a {
        case .building: event = behaviorStore.previous.map { if case .building = $0 { return true }; return false } == true ? nil : .buildStarts
        case .finished(let s) where s.contains("Build Succeeded") || s.contains("Clean Succeeded"): event = .buildSucceeds
        case .finished(let s) where s.contains("Run failed") || s.contains("exited unexpectedly"): event = .runExitsUnexpectedly
        case .finished(let s) where s.hasPrefix("Test"): event = nil
        case .finished(let s) where s.contains("Failed"):
            if session.displayedIssues.contains(where: { $0.severity == .error }) { perform(.buildErrors) }
            event = .buildFails
        case .running where !(behaviorStore.previous.map { if case .running = $0 { return true }; if case .paused = $0 { return true }; return false } ?? false):
            behaviorStore.runOutput = false
            behaviorStore.seenEntries = session.consoleEntries.count
            event = .runStarts
        case .running: event = behaviorStore.previous.map { if case .running = $0 { return true }; if case .paused = $0 { return true }; return false } == true ? nil : .runStarts
        case .paused: event = .runPauses
        case .finished(let s) where s.contains("Finished running"): event = .runEnds
        default: event = nil
        }
        behaviorStore.previous = a
        if case .finished(let s) = a, s.contains("Succeeded"), session.displayedIssues.contains(where: { $0.severity == .warning }) { perform(.buildWarnings) }
        guard let event else { return }
        perform(event)
    }

    /// The program's first output during a run: Running generates output.
    func noteConsoleOutput() {
        guard behaviorStore.previous.map({ if case .running = $0 { return true }; if case .paused = $0 { return true }; return false }) == true,
              !behaviorStore.runOutput else { return }
        let new = session.consoleEntries.dropFirst(behaviorStore.seenEntries)
        guard new.contains(where: { $0.kind == .target }) else { return }
        behaviorStore.runOutput = true
        perform(.runOutput)
    }

    func perform(_ event: Preferences.Event) {
        let b = Preferences.shared.behavior(event)
        lastBehavior = (event, b)
        if let n = b.showNavigator {
            navigatorItem.isCollapsed = false
            navigator.showsCodingAssistant = false
            navigator.select(n)
            updateToolbarState()
        }
        // reference-ui-5.md §8.2: opened at the remembered height.
        if let d = b.showDebugArea { showDebugArea(d) }
        if b.hideDebugAreaIfNoOutput && !behaviorStore.runOutput { showDebugArea(false) }
        // Sounds and notifications only for a window on screen.
        guard window?.isVisible == true else { return }
        if let s = b.sound { NSSound(named: NSSound.Name(s))?.play() }
        if b.notify { NSApp.requestUserAttention(.informationalRequest) }
    }

    // MARK: Debugger depth

    /// The disassembly in the editor (read-only text), the PC line marked.
    func showDisassembly() {
        let lines = session.disassembly.map { i in
            "\(i.address)  \(i.instruction)" + (i.symbol.map { "    ; \($0)" } ?? "")
        }
        let frame = session.frames.first { $0.id == session.selectedFrameID } ?? session.frames.first
        editor.showText(lines.joined(separator: "\n") + "\n", title: "\(frame?.name ?? "Disassembly") (disassembly)")
        if let pc = session.disassemblyPCIndex { editor.setCurrentLine(pc + 1); editor.reveal(line: pc + 1) }
    }

    /// Debug ▸ Debug Workflow ▸ Always Show Disassembly.
    @objc public func toggleAlwaysShowDisassembly(_ sender: Any?) {
        session.alwaysShowDisassembly.toggle()
        if !session.alwaysShowDisassembly, let loc = session.currentLocation { open(path: loc.file, line: loc.line) }
    }

    /// Debug ▸ Debug Workflow ▸ View Process by Queue / by Thread.
    @objc public func toggleThreadsByQueue(_ sender: Any?) {
        navigator.showThreadsByQueue.toggle()
        navigator.setDebugState(threads: session.threads, stoppedThread: session.stoppedThread, frames: session.frames)
    }

    /// Debug ▸ Attach to Process by PID or Name…: asks for a pid or name.
    @objc public func attachToProcess(_ sender: Any?) {
        guard let window, window.isVisible else { return }
        let alert = NSAlert()
        alert.messageText = "Attach to Process"
        alert.informativeText = "Enter a process identifier or a process name. With a name, Ycode waits for the process to launch."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Attach")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn, !field.stringValue.isEmpty else { return }
            let target = field.stringValue
            Task { await self?.session.attach(to: target, waitFor: Int(target) == nil) }
        }
    }

    /// The variables view's context menu and double-click.
    func variableAction(_ action: DebugAreaController.VariableAction, _ v: Variable) {
        switch action {
        case .printDescription: Task { await session.printDescription(of: v.name) }
        case .copyValue: DebugAreaController.copy(v)
        case .watch: Task { await session.watch(v.name, access: "write") }
        case .watchRead: Task { await session.watch(v.name, access: "read") }
        case .watchReadWrite: Task { await session.watch(v.name, access: "readWrite") }
        case .editValue, .addExpression:
            guard let window, window.isVisible else { return }
            let alert = NSAlert()
            alert.messageText = action == .editValue ? "Edit Value of \(v.name)" : "Add Expression"
            let field = NSTextField(string: action == .editValue ? v.value : "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: action == .editValue ? "Set" : "Add")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] r in
                guard r == .alertFirstButtonReturn, let self else { return }
                if action == .editValue { Task { await self.session.setValue(field.stringValue, of: v.name) } }
                else { self.session.watchExpressions.append(field.stringValue) }
            }
        }
    }

    // MARK: Organizer, Archive, Devices

    /// Where the Organizer looks (tests use a temporary folder).
    public var archivesDirectory = Organizer.defaultArchivesDirectory
    /// Runs the archive action (default: ycodebuild's archive path).
    public var archiveRunner: (URL, String) -> (status: Int32, output: String) = { Organizer.archive(container: $0, scheme: $1) }
    public private(set) var organizer: OrganizerController?
    private var organizerWindow: NSWindow?
    public private(set) var devices: DevicesController?
    private var devicesWindow: NSWindow?
    /// The devices window's close observer (one at a time; removed when
    /// that window closes or a new one replaces it).
    private var devicesWindowCloseObserver: NSObjectProtocol?

    isolated deinit {
        if let o = devicesWindowCloseObserver { NotificationCenter.default.removeObserver(o) }
    }
    /// The last Product ▸ Archive output.
    public private(set) var lastArchiveOutput: String?

    /// Window ▸ Organizer (⌥⇧⌘O).
    @discardableResult
    @objc public func showOrganizer(_ sender: Any?) -> OrganizerController {
        let c = organizer ?? OrganizerController(archivesDirectory: archivesDirectory)
        organizer = c
        c.reload()
        present(c, title: "Organizer", in: &organizerWindow)
        c.installToolbar()
        return c
    }

    /// Device Hub (`device-hub.md`), from the destination menu's Manage
    /// Devices… and Product ▸ Destination ▸ Manage Devices… (⇧⌘2;
    /// reference-ui-4.md §14.3: not in the Window menu).
    @objc public func showDevices(_ sender: Any?) {
        Task { await presentDevices() }
    }

    /// Lists devices and simulators (simctl, devicectl) off the main
    /// thread, then shows the hub window (an open one comes forward with
    /// fresh lists).
    @discardableResult
    public func presentDevices() async -> DevicesController {
        let lists = await Task.detached { DevicesList.load() }.value
        if let c = devices, let w = devicesWindow, w.isVisible {
            configureYcodeRemoteDevice(c)
            w.makeKeyAndOrderFront(nil)
            return c
        }
        devices?.closeLinks()
        let c = DevicesController(devices: lists.devices, simulators: lists.simulators)
        configureYcodeRemoteDevice(c)
        devices = c
        guard window?.isVisible == true else { _ = c.view; return c }
        let w = c.makeWindow()
        c.restoreState()
        devicesWindow = w
        if let old = devicesWindowCloseObserver { NotificationCenter.default.removeObserver(old) }
        devicesWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: .main
        ) { [weak self, weak c] _ in
            MainActor.assumeIsolated {
                c?.closeLinks()
                if let self, let token = self.devicesWindowCloseObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.devicesWindowCloseObserver = nil
                }
            }
        }
        w.makeKeyAndOrderFront(nil)
        return c
    }

    /// Shows a controller in its own window, only when this window is on screen.
    private func present(_ c: NSViewController, title: String, in slot: inout NSWindow?) {
        guard window?.isVisible == true else { _ = c.view; return }
        let w = slot ?? NSWindow(contentViewController: c)
        w.contentViewController = c
        w.title = title
        slot = w
        w.makeKeyAndOrderFront(nil)
    }

    /// Product ▸ Archive: archives the scheme through ycodebuild and opens
    /// the Organizer on the new archive. Returns whether it succeeded.
    @discardableResult
    @objc public func archiveProduct(_ sender: Any?) -> Bool {
        guard session.model.kind != .package, let scheme = session.scheme else { NSSound.beep(); return false }
        let before = Set(Organizer.archives(in: archivesDirectory).map(\.url))
        let result = archiveRunner(session.model.url, scheme)
        lastArchiveOutput = result.output
        guard result.status == 0 else {
            session.packageIssues = [Diagnostic(severity: .error, message: "Archive failed: \(result.output.split(separator: "\n").last ?? "")")]
            return false
        }
        let org = showOrganizer(sender)
        if let new = Organizer.archives(in: archivesDirectory).first(where: { !before.contains($0.url) }) { org.select(archiveAt: new.url) }
        return true
    }

    /// Editor ▸ Add New Constraints… (Interface Builder documents).
    @objc public func showAddConstraints(_ sender: Any?) { interfaceEditor?.showAddConstraints(sender) }

    /// Opens a file in a given editor (a split or the assistant).
    public func open(path: String, line: Int?, in e: SourceEditorController) {
        editorArea.withFocus(e) {
            e.history.visit(path)
            display(path: path, line: line)
            updateCounterparts()
        }
    }

    func display(path: String, line: Int?) {
        if path.hasSuffix(".xcodeproj") {
            openProjectEditor(path)
            return
        }
        if path.hasSuffix(".xcassets") {
            let c = AssetCatalogEditorController(url: URL(fileURLWithPath: path))
            projectEditor = nil
            plistEditor = nil
            assetEditor = c
            editor.showAuxiliary(c.view, path: jumpPath(for: URL(fileURLWithPath: path)), file: URL(fileURLWithPath: path))
            inspector.show(file: nil)
            return
        }
        assetEditor = nil
        stringCatalogEditor = nil
        interfaceEditor = nil
        if path.hasSuffix(".storyboard") || path.hasSuffix(".xib"), let c = try? InterfaceBuilderController(url: URL(fileURLWithPath: path)) {
            projectEditor = nil
            plistEditor = nil
            interfaceEditor = c
            editor.showAuxiliary(c.view, path: jumpPath(for: URL(fileURLWithPath: path)), file: URL(fileURLWithPath: path))
            inspector.show(file: URL(fileURLWithPath: path))
            return
        }
        if path.hasSuffix(".xcstrings"), let c = try? StringCatalogEditorController(url: URL(fileURLWithPath: path)) {
            projectEditor = nil
            plistEditor = nil
            stringCatalogEditor = c
            c.onAddLanguage = { [weak self] code in self?.addKnownRegion(code, forFileAt: path) }
            editor.showAuxiliary(c.view, path: jumpPath(for: URL(fileURLWithPath: path)), file: URL(fileURLWithPath: path))
            inspector.show(file: URL(fileURLWithPath: path))
            return
        }
        if path.hasSuffix(".plist") || path.hasSuffix(".entitlements"), let c = try? PlistEditorController(url: URL(fileURLWithPath: path)) {
            projectEditor = nil
            plistEditor = c
            editor.showAuxiliary(c.view, path: jumpPath(for: URL(fileURLWithPath: path)), file: URL(fileURLWithPath: path))
            inspector.show(file: URL(fileURLWithPath: path))
            return
        }
        plistEditor = nil
        projectEditor = nil
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }
        if editor.fileURL?.path != url.path {
            try? editor.save()
            do { try editor.open(url) } catch { return }
            updateCanvasForOpenedFile()   // reference-ui-6.md §4.4, E7
        }
        editor.pathComponents = jumpPath(for: url)
        refreshEditorMarks()
        inspector.show(file: url)
        if let line { editor.reveal(line: line) }
    }

    /// Workspace › groups › file, from the navigator tree.
    func jumpPath(for url: URL) -> [(String, String)] {
        var trail: [NavigatorNode] = []
        func search(_ n: NavigatorNode, _ path: [NavigatorNode]) -> Bool {
            if n.path == url.path && n.kind == .file { trail = path + [n]; return true }
            return n.children.contains { search($0, path + [n]) }
        }
        _ = search(session.model.root, [])
        // File components follow Settings ▸ General ▸ File Extensions, like
        // the navigator: "Model", not "Model.swift" (reference-ui-6.md §4.1, E1).
        let hide = Preferences.shared.fileExtensions == .hide
        if trail.isEmpty { return [(session.model.displayName, "folder.badge.gearshape"), (Self.jumpBarFileTitle(url.lastPathComponent, hideExtension: hide), "doc.text")] }
        return trail.map { ($0.kind == .file ? Self.jumpBarFileTitle($0.name, hideExtension: hide) : $0.name, OutlineItem.symbol(for: $0)) }
    }

    /// A file's jump-bar title: without its extension when extensions are hidden.
    public static func jumpBarFileTitle(_ name: String, hideExtension: Bool) -> String {
        guard hideExtension else { return name }
        let bare = (name as NSString).deletingPathExtension
        return bare.isEmpty ? name : bare
    }

    private func refreshEditorMarks() {
        refreshJumpBarIssues()
        guard let path = editor.fileURL?.path else { return }
        var lines: [Int: Bool] = [:]
        var customized = Set<Int>()
        for b in session.breakpoints.all where b.file == path {
            lines[b.line] = b.isEnabled
            if b.isCustomized { customized.insert(b.line) }
        }
        editor.setBreakpoints(lines, active: session.breakpoints.isActive, customized: customized)
        editor.setIssues(session.displayedIssues)
        var testMarks: [Int: GutterView.TestStatusMark] = [:]
        func mark(_ s: TestOutcome.Status?) -> GutterView.TestStatusMark {
            switch s { case .passed?: .passed; case .failed?: .failed; default: .notRun }
        }
        for t in session.tests where t.file == path {
            testMarks[t.line] = mark(session.testResults[t])
        }
        // Suite lines: red if any member failed, green if all passed.
        for (line, members) in Dictionary(grouping: session.tests.filter { $0.file == path && $0.suiteLine != nil }, by: { $0.suiteLine! }) {
            let s = members.map { session.testResults[$0] }
            testMarks[line] = s.contains(.failed) ? .failed : (s.allSatisfy { $0 == .passed } ? .passed : .notRun)
        }
        editor.setTests(testMarks)
        if let loc = session.currentLocation, loc.file == path { editor.setCurrentLine(loc.line) } else { editor.setCurrentLine(nil) }
        applyStopAnnotation(path: path)
    }

    private func sessionChanged(_ change: WorkspaceSession.Change) {
        switch change {
        case .activity:
            applyBehaviors(for: session.activity)
            switch session.activity {
            case .idle: activityView.status = ""
            case .building(let s), .running(let s), .paused(let s):
                // A build starts (reference-ui-5.md §5.3.2): earlier issues stay, stale, until it ends.
                // A test run's build texts (reference-ui-6.md §3.4) are not a
                // build of the Issue navigator's: the run ends with its failures.
                if WorkspaceSession.BuildActivityText.isBuild(s), session.testActivityProgress == nil, !navigator.issueModel.isBuilding {
                    navigator.issuesBuildStarted()
                }
                activityView.status = s
            case .finished(let s):
                if s.contains("Build") || s.contains("Clean") {
                    navigator.issuesBuildFinished(session.displayedIssues, full: s.contains("Clean"),
                                                  compiledFiles: IssueNavigatorModel.compiledFiles(inLog: session.buildLog, isPackage: session.model.kind == .package))
                }
                activityView.status = "\(s) • Today at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short))"
            }
            activityView.isBusy = session.isBusy
            if case .paused = session.activity { debugArea.setPaused(true) } else { debugArea.setPaused(false) }
            debugArea.setDebugging(session.debugClient != nil)
            refreshDebugChrome()
        case .process:
            navigator.setDebugProcess(session.debugProcessInfo)
        case .issues:
            let shown = session.displayedIssues
            activityView.errors = shown.filter { $0.severity == .error }.count
            activityView.warnings = shown.filter { $0.severity == .warning }.count
            let counts = navigator.issueModel.capsuleCounts(fresh: shown)
            issueCapsule.errors = counts.errors
            issueCapsule.warnings = counts.warnings
            issueCapsule.failedTests = session.failedTestCount
            navigator.setIssues(shown)
            refreshEditorMarks()
        case .breakpoints:
            navigator.setWatchpoints(session.watchpoints)
            navigator.breakpointIDs = session.breakpointIDs
            navigator.setBreakpoints(session.breakpoints)
            refreshEditorMarks()
        case .reports:
            navigator.setReports(session.reports)
        case .tests:
            navigator.setTests(session.tests, results: session.testResults)
            refreshEditorMarks()
        case .console:
            noteConsoleOutput()
            debugArea.setConsole(session.consoleText(debugArea.consoleFilter, metadata: debugArea.metadata))
        case .debugState:
            debugArea.setVariables(session.watchValues + session.variables)
            let frame = session.frames.first { $0.id == session.selectedFrameID } ?? session.frames.first
            debugArea.setFrame(frame.map { "\($0.name)  line \($0.line)" } ?? "")
            navigator.setDebugState(threads: session.threads, stoppedThread: session.stoppedThread, frames: session.frames)
            refreshDebugChrome()
            if session.alwaysShowDisassembly && !session.disassembly.isEmpty {
                showDisassembly()
                lastShownLocation = nil
            } else if let loc = session.currentLocation { showDebugLocation(loc) }
            refreshEditorMarks()
            if session.debugClient != nil { showDebugArea(true) }
        }
    }

    // MARK: Toolbar

    static let runID = NSToolbarItem.Identifier("run")
    static let stopID = NSToolbarItem.Identifier("stop")
    static let schemeID = NSToolbarItem.Identifier("scheme")
    static let activityID = NSToolbarItem.Identifier("activity")
    static let libraryID = NSToolbarItem.Identifier("library")
    static let inspectorToggleID = NSToolbarItem.Identifier("inspectorToggle")
    static let leftPanesID = NSToolbarItem.Identifier("leftPanes")
    static let historyID = NSToolbarItem.Identifier("history")
    static let editorModesID = NSToolbarItem.Identifier("editorModes")
    static let issuesID = NSToolbarItem.Identifier("issues")
    static let newConversationID = NSToolbarItem.Identifier("newConversation")

    /// reference-ui-6.md §2.1: Navigators / Coding Assistant, Run and
    /// Stop, Back and Forward, the activity view, New Conversation, the
    /// scheme › destination pill, the issue capsule, Add Editor and Editor
    /// Options, Canvas / Assistant / Code Review, and Show Inspector at the
    /// far right (no Account item, no flexible space after it).
    ///
    /// liquid-glass.md §2.2: Run | Stop ends the navigator's section of the
    /// toolbar (a flexible space before it, the sidebar tracking separator
    /// after it), Back | Forward starts the editor's; a fixed space keeps
    /// New Conversation's circle out of the scheme's capsule (adjacent
    /// bordered items otherwise share one glass shape); Show Inspector sits
    /// in the inspector's section.
    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.leftPanesID, .flexibleSpace, Self.runID, .sidebarTrackingSeparator, Self.historyID, Self.activityID, .flexibleSpace,
         Self.newConversationID, .space, Self.schemeID, Self.issuesID,
         .flexibleSpace, EditorOptionsMenu.addEditorID, EditorOptionsMenu.editorOptionsID, Self.editorModesID,
         .inspectorTrackingSeparator, .flexibleSpace, Self.inspectorToggleID]
    }

    /// The toolbar's segmented controls (tests).
    public var leftPanesControl: NSSegmentedControl { toolbarControls.leftPanes }
    public var editorModesControl: NSSegmentedControl { toolbarControls.editorModes }

    @objc func leftPaneChosen(_ c: NSSegmentedControl) {
        setLeftPane(codingAssistant: c.selectedSegment == 1)
    }

    /// Shows the navigators or the Coding Assistant pane in the left area; choosing the shown one
    /// again hides the area (reference-ui-5.md §4.1).
    public func setLeftPane(codingAssistant: Bool) {
        let wasAssistant = navigator.showsCodingAssistant
        if !navigatorItem.isCollapsed && wasAssistant == codingAssistant {
            navigatorItem.isCollapsed = true
        } else {
            navigatorItem.isCollapsed = false
            navigator.showsCodingAssistant = codingAssistant
        }
        updateToolbarState()
    }

    /// The left area's content as the toolbar shows it: nil when hidden.
    public enum LeftPane: Equatable { case navigators, codingAssistant }
    public var shownLeftPane: LeftPane? {
        navigatorItem.isCollapsed ? nil : (navigator.showsCodingAssistant ? .codingAssistant : .navigators)
    }

    /// The editor modes of reference-ui-5.md §4.2; at most one is on.
    public enum EditorMode: Int, CaseIterable { case canvas, assistant, codeReview }
    public var activeEditorMode: EditorMode? {
        if editorArea.tab.assistant != nil { return .assistant }
        if editor.isShowingComparison || editor.isShowingInlineComparison { return .codeReview }
        // Canvas mode is on even while no canvas is drawn (reference-ui-6.md §4.4, E10).
        if canvasAuto.modeOn || canvas != nil { return .canvas }
        return nil
    }

    /// Turns `mode` on (the others off) or, when it is on, off. Used by the
    /// segments and the Editor menu items alike.
    public func setEditorMode(_ mode: EditorMode) {
        switch mode {
        case .canvas: toggleCanvas(nil)
        case .assistant: toggleAssistant(nil)
        case .codeReview: toggleComparison(nil)
        }
    }

    /// Turns off every mode other than `keep` (before turning `keep` on).
    func endEditorModes(except keep: EditorMode) {
        if keep != .canvas {
            canvasAuto.modeOn = false
            if canvas != nil { canvas = nil; editorArea.hideCanvas() }
        }
        if keep != .assistant, editorArea.tab.assistant != nil { editorArea.hideAssistant() }
        if keep != .codeReview { for e in editorArea.tab.editors where e.isShowingComparison || e.isShowingInlineComparison { endCodeReview(in: e) } }
    }

    @objc func editorModeChosen(_ c: NSSegmentedControl) {
        if let m = EditorMode(rawValue: c.selectedSegment) { setEditorMode(m) }
        updateToolbarState()
    }

    @objc func historyChosen(_ c: NSSegmentedControl) {
        if c.selectedSegment == 0 { goBack(nil) } else { goForward(nil) }
    }

    /// Segment highlights follow the shown panes and editor modes.
    public func updateToolbarState() {
        let l = toolbarControls.leftPanes
        let left = shownLeftPane
        l.setSelected(left == .navigators, forSegment: 0)
        l.setSelected(left == .codingAssistant, forSegment: 1)
        let r = toolbarControls.editorModes
        let mode = activeEditorMode
        for m in EditorMode.allCases { r.setSelected(m == mode, forSegment: m.rawValue) }
        updateEditorModesPullDown()
        updateAreaToggleTitles()
    }

    /// The left segments follow every way the left area changes: menu
    /// items, ⌘0–⌘9, the divider, window restoration (§4.1.3).
    func observeLeftArea() {
        navigator.onContentChange = { [weak self] in self?.updateToolbarState() }
        navigator.onShowCodingAssistant = { [weak self] in _ = self?.codingAssistant }
        let token = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: mainSplit.splitView,
                                                           queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateToolbarState() }
        }
        let kvo = navigatorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateToolbarState() }
        }
        leftAreaObservation.tokens = [token, kvo]
        observeToolbarRoom()
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = rightGroupToolbarItem(id) { return item }  // reference-ui-4.md §14
        func button(_ symbol: String, _ label: String, _ action: Selector) -> NSToolbarItem {
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            item.label = label
            item.toolTip = label
            item.action = action
            item.isBordered = true
            return item
        }
        switch id {
        case Self.runID:
            // Run and Stop as one joined pair.
            let c = NSSegmentedControl(images: [NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Run")!,
                                                NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop")!],
                                       trackingMode: .momentary, target: self, action: #selector(runStopChosen(_:)))
            for (i, t) in Self.runStopToolTips.enumerated() { c.setToolTip(t, forSegment: i); c.setWidth(ToolbarGlass.pairSegment, forSegment: i) }
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = c
            item.label = "Run"
            return item
        case Self.historyID:
            let c = NSSegmentedControl(images: [NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Go Back")!,
                                                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Go Forward")!],
                                       trackingMode: .momentary, target: self, action: #selector(historyChosen(_:)))
            for (i, t) in Self.historyToolTips.enumerated() { c.setToolTip(t, forSegment: i); c.setWidth(ToolbarGlass.pairSegment, forSegment: i) }
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = c
            item.label = "Back/Forward"
            return item
        case Self.newConversationID:
            // §4.3.3: a new conversation in the Coding Assistant pane
            // (coding-assistant.md §4).
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "plus.bubble", accessibilityDescription: "New Conversation")
            item.label = "New Conversation"
            item.toolTip = "New Conversation"
            item.isBordered = true
            item.target = self
            item.action = #selector(toggleNewConversationPrompt(_:))   // reference-ui-6.md §9.4
            return item
        case Self.leftPanesID:
            let c = toolbarControls.leftPanes
            c.target = self
            c.action = #selector(leftPaneChosen(_:))
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = c
            item.label = "Navigators"
            return item
        case Self.editorModesID:
            let c = toolbarControls.editorModes
            c.target = self
            c.action = #selector(editorModeChosen(_:))
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = toolbarControls.fit.editorModesCollapsed ? toolbarControls.editorModesPullDown : c
            item.label = "Editor Modes"
            item.visibilityPriority = .high
            return item
        case Self.stopID: return button("stop.fill", "Stop", #selector(stopProduct(_:)))
        case Self.libraryID: return button("plus", "Library", #selector(showLibrary(_:)))
        case Self.inspectorToggleID:
            // reference-ui-6.md §2.5: the title follows the inspector's state.
            let item = button("sidebar.right", Self.inspectorToggleTitle(shown: inspectorItem.map { !$0.isCollapsed } ?? true), #selector(toggleInspector(_:)))
            item.visibilityPriority = .user   // §2.2.3: never hidden
            return item
        case Self.schemeID:
            schemePopUp.target = self
            schemePopUp.action = #selector(schemeChosen(_:))
            schemePopUp.isBordered = false
            schemePopUp.controlSize = .small
            destinationPopUp.target = self
            destinationPopUp.action = #selector(destinationChosen(_:))
            destinationPopUp.isBordered = false
            destinationPopUp.controlSize = .small
            let chevron = NSTextField(labelWithString: "›")
            chevron.textColor = .tertiaryLabelColor
            let stack = NSStackView(views: [schemePopUp, chevron, destinationPopUp])
            stack.spacing = 0
            // The titles keep clear of the glass capsule's rounded ends.
            if #available(macOS 26, *) { stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8) }
            // §2.2.2: the scheme name truncates before the destination does.
            schemePopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            destinationPopUp.setContentCompressionResistancePriority(.defaultHigh + 1, for: .horizontal)
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = stack
            item.label = "Scheme"
            item.visibilityPriority = .high
            item.isBordered = true   // its own glass capsule (liquid-glass.md §2.2)
            return item
        case Self.issuesID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = issueCapsule
            item.label = "Issues"
            item.visibilityPriority = .high
            item.isBordered = true   // its own glass capsule (liquid-glass.md §2.2)
            item.isHidden = issueCapsule.isHidden   // no empty capsule
            // §2.3: each button opens the Issue navigator.
            issueCapsule.onClick = { [weak self] _ in self?.showNavigator(4) }
            issueCapsule.onPartsChange = { [weak self] in
                guard let self else { return }
                self.window?.toolbar?.items.first { $0.itemIdentifier == Self.issuesID }.map { $0.isHidden = self.issueCapsule.isHidden }
                self.scheduleToolbarFit()
            }
            return item
        case Self.activityID:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = activityView
            item.label = "Activity"
            item.isBordered = false   // no glass shape (liquid-glass.md §2.2)
            activityView.onNaturalWidthChange = { [weak self] in self?.scheduleToolbarFit() }
            return item
        default: return nil
        }
    }

    /// reference-ui-5.md §4.3.2.
    public static let runStopToolTips = ["Build and then run the current scheme", "Stop the running scheme or application"]
    public static let historyToolTips = ["Show Previous Location in History", "Show Next Location in History"]

    /// §4.3.4, reference-ui-6.md §2.1 (T6): the pill's pop-ups carry these
    /// accessibility titles (and names).
    func labelSchemePill() {
        schemePopUp.setAccessibilityLabel("Active Scheme")
        schemePopUp.setAccessibilityTitle("Active Scheme")
        destinationPopUp.setAccessibilityLabel("Active Run Destination")
        destinationPopUp.setAccessibilityTitle("Active Run Destination")
    }

    @objc func runStopChosen(_ c: NSSegmentedControl) {
        if c.selectedSegment == 0 { runProduct(nil) } else { stopProduct(nil) }
    }

    @objc func schemeChosen(_ p: NSPopUpButton) {
        session.scheme = p.titleOfSelectedItem
        // Each scheme has its own remembered destination.
        destinationDefault.applied = session.destination
        chooseDefaultDestination()
        rebuildDestinationMenu()
        scheduleToolbarFit()
    }
    @objc func destinationChosen(_ p: NSPopUpButton) {
        guard let key = p.selectedItem?.representedObject as? String else { return }
        let all = session.model.destinations + destinationMenuModel().sections.flatMap(\.destinations)
        // By identifier first: specifiers are shared (Ycode's remote simulator
        // and Any iOS Simulator Device both build for the generic simulator).
        session.destination = Self.destination(forKey: key, in: all)
        rememberDestination()
        rebuildDestinationMenu()
    }

    public func setDestinationGroups(_ groups: [DestinationGroup]) {
        var groups = groups.filter { $0.title != "Ycode" }
        // The remote Ycode simulator, once it is set up in Settings, with
        // its runtime version (the menu lists it with the simulators,
        // reference-ui-5.md §11.5).
        let settings = RemoteSimulatorSettings.load(Preferences.shared.defaults)
        if settings.isConfigured {
            // One row per runtime root and device type (run.md §Runtimes and device types).
            let rows = RemoteSimulator.destinations(settings)
            groups.append(DestinationGroup(title: "Ycode", destinations: rows))
            if let d = session.destination, d.isYcodeRemoteSimulator {
                session.destination = rows.first { $0.identifier == d.identifier } ?? rows.first
                // A default stays a default when its row is relisted (with
                // its runtime version, for example).
                if destinationDefault.applied == d { destinationDefault.applied = session.destination }
            }
        }
        session.model.destinationGroups = groups
        reloadSchemes()
    }

    static func symbol(for d: Destination) -> String {
        switch (d.kind, d.platform) {
        case (.mac, _), (.generic, "macOS"): "desktopcomputer"
        case _ where d.isYcodeRemoteSimulator: "candybarphone"
        // Neutral glyphs only: no product-shaped symbols (CLAUDE.md rule 5).
        case (_, "watchOS"): "clock"
        case (_, "tvOS"): "tv"
        case (_, "visionOS"): "eyeglasses"
        case (.generic, _): "square.dashed"
        default: "candybarphone"
        }
    }

    // MARK: Area commands

    @objc public func toggleNavigator(_ sender: Any?) {
        if window?.isVisible == true { navigatorItem.animator().isCollapsed.toggle() } else { navigatorItem.isCollapsed.toggle() }
        updateToolbarState()
    }
    @objc public func toggleInspector(_ sender: Any?) { inspectorItem.animator().isCollapsed.toggle() }
    @objc public func toggleDebugArea(_ sender: Any?) { showDebugArea(debugItem.isCollapsed) }
    /// The Library (⇧⌘L), created on first use.
    public private(set) var library: LibraryController?
    private var libraryPanel: NSPanel?

    /// View ▸ Show Library (⇧⌘L) / the toolbar's + button: shows the
    /// Library in a floating panel; its items insert into the source editor.
    @discardableResult
    @objc public func showLibrary(_ sender: Any?) -> LibraryController {
        let lib = library ?? LibraryController()
        library = lib
        lib.objectsAvailable = interfaceEditor != nil
        lib.onInsertObject = { [weak self] kind in
            guard self?.interfaceEditor?.insert(kind) != nil else { NSSound.beep(); return }
        }
        lib.onInsert = { [weak self] text in
            guard let self, self.editor.insertLibraryText(text) else { NSSound.beep(); return }
            self.window?.makeFirstResponder(self.editor.textView)
        }
        if window?.isVisible == true {
            let panel = libraryPanel ?? {
                let p = NSPanel(contentViewController: lib)
                p.styleMask = [.titled, .closable, .resizable, .utilityWindow]
                p.title = "Library"
                p.isFloatingPanel = true
                p.hidesOnDeactivate = true
                return p
            }()
            libraryPanel = panel
            if let w = window { panel.setFrameTopLeftPoint(NSPoint(x: w.frame.midX - 210, y: w.frame.maxY - 60)) }
            panel.makeKeyAndOrderFront(nil)
        }
        return lib
    }

    /// Shows or hides the debug area. It opens at the height it had when
    /// last shown (saved per workspace), or 135 points the first time
    /// (reference-ui-5.md §8.2).
    public func showDebugArea(_ show: Bool) {
        guard debugItem.isCollapsed == show else { return }
        if !show { rememberDebugAreaHeight() }
        // The split view restores a pane at its view's last size: give it
        // the opening height first.
        if show { debugArea.view.setFrameSize(NSSize(width: debugArea.view.frame.width, height: debugAreaOpeningHeight)) }
        debugItem.isCollapsed = !show
        if show {
            let split = centerSplit.splitView
            centerSplit.view.layoutSubtreeIfNeeded()
            split.setPosition(split.bounds.height - debugAreaOpeningHeight - split.dividerThickness, ofDividerAt: 0)
            centerSplit.view.layoutSubtreeIfNeeded()
        }
    }

    /// The height the debug area opens at.
    public var debugAreaOpeningHeight: CGFloat { userState.debugAreaHeight.map { CGFloat($0) } ?? Self.debugAreaHeight }

    /// The debug area's current height while shown.
    public var debugAreaHeightShown: CGFloat? { debugItem.isCollapsed ? nil : debugArea.view.frame.height }

    /// Records the shown debug area's height (on hide and divider drags).
    func rememberDebugAreaHeight() {
        guard !debugItem.isCollapsed else { return }
        let h = debugArea.view.frame.height
        guard h >= debugItem.minimumThickness else { return }
        updateUserState { $0.debugAreaHeight = Double(h) }
    }

    /// View ▸ Navigators ▸ <navigator> (⌘1–⌘9): shows the navigators in
    /// the left area (replacing the Coding Assistant pane).
    @objc public func showNavigator(_ sender: Any?) {
        navigatorItem.isCollapsed = false
        navigator.showsCodingAssistant = false
        navigator.select((sender as? NSMenuItem)?.tag ?? (sender as? Int) ?? 0)
        updateToolbarState()
    }

    @objc public func showInspector(_ sender: Any?) {
        inspectorItem.isCollapsed = false
        inspector.select((sender as? NSMenuItem)?.tag ?? 0)
    }

    @objc public func activateConsole(_ sender: Any?) { showDebugArea(true) }

    // MARK: Product commands

    @objc public func buildProduct(_ sender: Any?) { Task { await session.build(.build) } }
    /// Clean Build Folder… (⇧⌘K) asks first; see `confirmCleanBuildFolder`.
    @objc public func cleanProduct(_ sender: Any?) { confirmCleanBuildFolder() }
    @objc public func testProduct(_ sender: Any?) { Task { await session.runTests() } }
    @objc public func analyzeProduct(_ sender: Any?) { Task { await session.build(.analyze) } }
    @objc public func stopProduct(_ sender: Any?) {
        if session.simulatorRun != nil {
            session.stopSimulatorRun(simctl: simctl, remote: RemoteSimulator(settings: RemoteSimulatorSettings.load(Preferences.shared.defaults)))
        }
        session.stop()
    }

    /// The simctl used for Mac simulators (tests substitute a recorder).
    public var simctl: Simctl {
        get { simctlStore.simctl }
        set { simctlStore.simctl = newValue }
    }

    /// The `.app` a simulator build produces: the macOS product path with
    /// the configuration folder suffixed `-iphonesimulator` (the
    /// platform's products folder) and without `Contents/MacOS/<exe>`.
    public static func simulatorAppPath(fromExecutablePath p: String) -> String {
        var path = p
        if let r = path.range(of: "/Contents/MacOS/") { path = String(path[..<r.lowerBound]) }
        if let r = path.range(of: "/Products/") {
            let rest = path[r.upperBound...]
            if let slash = rest.firstIndex(of: "/") {
                let config = rest[..<slash]
                if !config.hasSuffix("-iphonesimulator") {
                    path = String(path[..<r.upperBound]) + config + "-iphonesimulator" + String(rest[slash...])
                }
            }
        }
        return path
    }

    @objc public func runProduct(_ sender: Any?) {
        let request = session.model.buildRequest(scheme: session.scheme, destination: session.destination, action: .build)
        let engine = session.engine
        if let d = session.destination, d.isYcodeRemoteSimulator || (d.kind == .simulator && d.platform != "macOS") {
            Task {
                let result = await session.build(.build)
                guard result.status == .succeeded, let exe = await Task.detached(operation: { engine.executablePath(for: request) }).value else { return }
                let app = URL(fileURLWithPath: Self.simulatorAppPath(fromExecutablePath: exe))
                if d.isYcodeRemoteSimulator {
                    await session.runOnRemoteSimulator(app: app, remote: RemoteSimulator(settings: RemoteSimulatorSettings.load(Preferences.shared.defaults), destination: d))
                } else if let udid = d.identifier {
                    await session.runOnSimulator(app: app, udid: udid, debug: true, simctl: simctl)
                }
            }
            return
        }
        Task {
            let program = await Task.detached { engine.executablePath(for: request) }.value
            await session.run(program: program)
        }
    }

    @objc public func saveDocument(_ sender: Any?) {
        do {
            try editor.save()
            try session.model.saveProjects()
            refreshFileStatus(nil)
        } catch {
            presentError(error)
        }
    }

    // MARK: Debug commands

    @objc public func pauseOrContinue(_ sender: Any?) { Task { await session.continueOrPause() } }
    @objc public func stepOver(_ sender: Any?) { Task { await session.step("over") } }
    @objc public func stepInto(_ sender: Any?) { Task { await session.step("in") } }
    @objc public func stepOut(_ sender: Any?) { Task { await session.step("out") } }
    @objc public func toggleBreakpointsActive(_ sender: Any?) { session.breakpoints.isActive.toggle() }

    @objc public func toggleBreakpointAtCurrentLine(_ sender: Any?) {
        guard let path = editor.fileURL?.path else { return }
        session.breakpoints.toggleExistence(file: path, line: editor.currentLine)
    }

    // MARK: Navigation

    @objc public func jumpToNextIssue(_ sender: Any?) { stepIssue(+1) }
    @objc public func jumpToPreviousIssue(_ sender: Any?) { stepIssue(-1) }

    /// The workspace's issues with a location, in navigation order: files
    /// in the order their first issue appears, then by line.
    var navigableIssues: [Diagnostic] {
        let located = session.displayedIssues.filter { $0.location != nil && ($0.severity == .error || $0.severity == .warning) }
        var fileOrder: [String: Int] = [:]
        for d in located where fileOrder[d.location!.file] == nil { fileOrder[d.location!.file] = fileOrder.count }
        return located.enumerated().sorted { a, b in
            let (fa, fb) = (fileOrder[a.element.location!.file]!, fileOrder[b.element.location!.file]!)
            if fa != fb { return fa < fb }
            if a.element.location!.line != b.element.location!.line { return a.element.location!.line < b.element.location!.line }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Navigate ▸ Jump to Next / Previous Issue and the jump bar's arrows:
    /// the next issue after the caret in the file, then the next files'
    /// issues, wrapping around (reference-ui-5.md §6.1.2).
    func stepIssue(_ delta: Int) {
        let list = navigableIssues
        guard !list.isEmpty else { return NSSound.beep() }
        let file = editor.fileURL.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
        let line = editor.fileURL == nil ? 0 : editor.currentLine
        let fileIndex = Dictionary(list.enumerated().map { ($0.element.location!.file, $0.offset) }, uniquingKeysWith: { a, _ in a })
        // The position of the caret in the issue order.
        func key(_ d: Diagnostic) -> (Int, Int) { (fileIndex[d.location!.file] ?? 0, d.location!.line) }
        let here: (Int, Int)? = file.flatMap { f in list.first { URL(fileURLWithPath: $0.location!.file).standardizedFileURL.path == f } }
            .map { (fileIndex[$0.location!.file] ?? 0, line) }
        var target: Int
        if let here {
            if delta > 0 {
                target = list.firstIndex { key($0) > here } ?? 0
            } else {
                target = list.lastIndex { key($0) < here } ?? list.count - 1
            }
        } else {
            issueCursor = ((issueCursor + delta) % list.count + list.count) % list.count
            target = issueCursor
        }
        issueCursor = target
        let d = list[target]
        open(path: d.location!.file, line: d.location!.line)
    }

    /// The jump bars' issue controls: present while the workspace has
    /// issues, each listing its file's issues.
    func refreshJumpBarIssues() {
        let list = navigableIssues
        for e in editorArea.allEditors {
            guard !list.isEmpty else { e.setJumpBarIssues(nil); continue }
            let path = e.fileURL.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
            let mine = list.filter { URL(fileURLWithPath: $0.location!.file).standardizedFileURL.path == path }
            e.setJumpBarIssues(mine.map { (message: $0.message, line: $0.location!.line, isError: $0.severity == .error) })
        }
    }

    @objc public func jumpToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Jump to Line"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "Jump")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn, let n = Int(field.stringValue) { self?.editor.reveal(line: n) }
        }
    }

    /// Shift-Command-F: shows the Find navigator with the editor's selection as query.
    @objc public func findInWorkspace(_ sender: Any?) {
        navigatorItem.isCollapsed = false
        navigator.select(3)
        let sel = editor.textView.selectedRange()
        if sel.length > 0 { navigator.find((editor.text as NSString).substring(with: sel)) }
        window?.makeFirstResponder(navigator.findField)
    }

    /// Product > Scheme > Edit Scheme (Command-<): the editor sheet for the
    /// selected scheme. Returns the controller (nil when the scheme has no
    /// file yet, e.g. an autocreated one).
    @discardableResult
    @objc public func editScheme(_ sender: Any?) -> SchemeEditorController? {
        guard let scheme = session.model.loadSchemes().first(where: { $0.name == session.scheme }) else {
            NSSound.beep()
            return nil
        }
        let editor = SchemeEditorController(scheme: scheme, configurations: session.model.configurationNames)
        editor.startSelection = schemeEditorState.selection
        editor.availableTargets = SchemeEditorController.buildableTargets(projects: session.model.projects, container: session.model.url)
        editor.onOpenFile = { [weak self] in self?.open(path: $0.path, line: nil) }
        editor.onSelect = { [weak self] a, t in self?.schemeEditorState.selection = (a, t) }
        editor.onManage = { [weak self, weak editor] in
            guard let self else { return }
            let manage = self.manageSchemesController()
            editor?.presentAsSheet(manage)
        }
        if window?.isVisible == true { contentViewController?.presentAsSheet(editor) }
        return editor
    }

    /// Product ▸ Scheme ▸ Choose Scheme (⌃0): opens the toolbar's scheme pop-up.
    @objc public func chooseScheme(_ sender: Any?) {
        guard window?.isVisible == true else { return }
        schemePopUp.performClick(nil)
    }

    /// Product ▸ Scheme ▸ Select Next / Previous Scheme (⌃⌘] / ⌃⌘[).
    @objc public func selectNextScheme(_ sender: Any?) { stepScheme(1) }
    @objc public func selectPreviousScheme(_ sender: Any?) { stepScheme(-1) }

    func stepScheme(_ d: Int) {
        let names = session.model.schemeNames
        guard !names.isEmpty else { NSSound.beep(); return }
        let i = names.firstIndex(of: session.scheme ?? "") ?? 0
        session.scheme = names[(i + d + names.count) % names.count]
        schemePopUp.selectItem(withTitle: session.scheme ?? "")
    }

    /// Product ▸ Scheme ▸ Manage Schemes…
    @objc public func manageSchemes(_ sender: Any?) {
        let c = manageSchemesController()
        if window?.isVisible == true { contentViewController?.presentAsSheet(c) }
    }

    /// The Manage Schemes list for this workspace.
    public func manageSchemesController() -> ManageSchemesController {
        let c = ManageSchemesController(schemes: session.model.loadSchemes())
        c.onClose = { [weak self] in self?.reloadSchemesFromDisk() }
        return c
    }

    private func reloadSchemesFromDisk() {
        let names = session.model.loadSchemes().map(\.name)
        if !names.isEmpty { session.model.schemeNames = names }
        reloadSchemes()
    }

    /// The Open Quickly panel's corner radius (liquid-glass-ycode.md §7).
    static let openQuicklyCornerRadius: CGFloat = 20

    /// File ▸ Open Quickly… (Shift-Command-O): fuzzy search over the
    /// workspace's files and symbols.
    @discardableResult
    @objc public func openQuickly(_ sender: Any?) -> OpenQuicklyController {
        // The index is read in the background; the list updates when it arrives.
        let c = OpenQuicklyController(candidates: candidateIndex.value ?? [])
        withWorkspaceCandidates { [weak c] candidates in c?.update(candidates: candidates) }
        c.onOpen = { [weak self] r in self?.open(path: r.path, line: r.line) }
        guard let window, window.isVisible else { return c }
        if #available(macOS 26, *) {
            // A floating glass panel over the window (liquid-glass-ycode.md §7).
            let panel = GlassPanel(content: c, cornerRadius: Self.openQuicklyCornerRadius)
            c.onClose = { [weak panel] in panel?.close() }
            panel.show(over: window)
        } else {
            contentViewController?.presentAsSheet(c)
        }
        return c
    }

    // MARK: Breakpoint editing

    /// The breakpoint editor for a line; shown in a popover beside the
    /// gutter when the window is on screen.
    @discardableResult
    public func editBreakpoint(file: String, line: Int) -> BreakpointEditorController? {
        guard let bp = session.breakpoints.breakpoint(file: file, line: line) else { return nil }
        let c = BreakpointEditorController(breakpoint: bp)
        c.onChange = { [weak self] edited in self?.session.breakpoints.edit(file: file, line: line) { $0 = edited } }
        if window?.isVisible == true, let row = editor.gutter.visibleLines().first(where: { $0.line == line }) {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = c
            popover.show(relativeTo: NSRect(x: 0, y: row.rect.minY, width: editor.gutter.ruleThickness, height: max(row.rect.height, 14)),
                         of: editor.gutter, preferredEdge: .maxX)
        }
        return c
    }

    /// Breakpoint navigator ▸ + ▸ Exception Breakpoint (Objective-C and C++
    /// throws) or Swift Error Breakpoint.
    public func addExceptionBreakpoint(swift: Bool) {
        let filters = swift ? ["swift_throw"] : ["objc_throw", "cpp_throw"]
        for f in filters where !session.breakpoints.exceptionFilters.contains(f) { session.breakpoints.exceptionFilters.append(f) }
    }

    /// Breakpoint navigator ▸ + ▸ Symbolic Breakpoint….
    public func addSymbolicBreakpoint(name: String, condition: String = "") {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !session.breakpoints.symbolic.contains(where: { $0.name == n }) else { return }
        session.breakpoints.symbolic.append(.init(name: n, condition: condition))
    }

    func askSymbolicBreakpoint() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Symbolic Breakpoint"
        alert.informativeText = "Symbol (function or method name)"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] r in
            if r == .alertFirstButtonReturn { self?.addSymbolicBreakpoint(name: field.stringValue) }
        }
    }

    /// Editor ▸ Code Review (⌥⇧⌘↩): the focused file's working copy beside
    /// its HEAD version. Returns whether the comparison is now shown.
    @discardableResult
    @objc public func toggleComparison(_ sender: Any?) -> Bool {
        defer { updateToolbarState() }
        if editor.isShowingComparison || editor.isShowingInlineComparison {
            endCodeReview()
            return false
        }
        endEditorModes(except: .codeReview)   // reference-ui-5.md §4.2
        return startCodeReview()  // WorkspaceWindowController+CodeReview.swift
    }

    /// The repository holding the workspace once a background read has
    /// looked for it (`.some(nil)`: not in git); nil before that.
    var knownRepository: GitRepository??
    /// The git repository holding the workspace, if any. Found off the main
    /// thread by the first source-control refresh; a command that needs it
    /// before then looks it up at once.
    public var repository: GitRepository? {
        if let known = knownRepository { return known }
        let r = GitRepository(containing: session.model.url)
        knownRepository = .some(r)
        return r
    }
    /// Re-finds the repository (after New Git Repository…) on the next refresh.
    func resetRepository() { knownRepository = nil }
    /// Source Control navigator, commit editor, history and Integrate menu.
    public private(set) lazy var sourceControl = SourceControlCoordinator(owner: self)
    /// Open Quickly's and the empty editor's candidates.
    let candidateIndex = WorkspaceCandidateIndex()

    /// Integrate ▸ Refresh File Status: badges, the Source Control
    /// navigator, the Integrate menu and the debug bar's branch, read from
    /// git in the background (`SourceControlCoordinator.scheduleRefresh`).
    @objc public func refreshFileStatus(_ sender: Any?) {
        sourceControl.scheduleRefresh()
    }

    /// Integrate ▸ Commit… (Option-Command-C): the commit sheet for the
    /// changed files of this workspace's repository, once their status has
    /// been read in the background.
    @objc public func showCommitSheet(_ sender: Any?) {
        Task { await presentCommitSheet() }
    }

    /// The commit sheet (presented when the window is on screen).
    @discardableResult
    public func presentCommitSheet() async -> CommitController? {
        guard let repo = repository else { NSSound.beep(); return nil }
        try? editor.save()
        let status = await Task.detached { (try? repo.status()) ?? [:] }.value
        let sheet = CommitController(repository: repo, status: status)
        sheet.onCommitted = { [weak self] _ in self?.refreshFileStatus(nil) }
        if window?.isVisible == true { contentViewController?.presentAsSheet(sheet) }
        return sheet
    }

    /// Starts the language server and opens the current file in it.
    public func connectLanguageService(transport: DAPTransport?) async {
        await session.startLanguageService(transport: transport)
        session.language?.onApplyEdit = { [weak self] edit in self?.applyWorkspaceEdit(edit) }
        if let url = editor.fileURL { session.language?.open(url, text: editor.text) }
    }

    /// Control-Command-J: asks the language server where the symbol at the
    /// insertion point is defined and goes there.
    @objc public func jumpToDefinition(_ sender: Any?) {
        guard let url = editor.fileURL else { return }
        jumpToDefinition(url: url, at: editor.caretPosition)
    }

    /// Asks for the hover text; shows it in a popover at `anchor` (when on
    /// screen) and in the Quick Help inspector. Returns the text.
    @discardableResult
    public func showQuickHelp(url: URL, at p: Position, anchor: NSRect) async -> String? {
        let text = await session.hover(url, at: p)
        inspector.showQuickHelp(text, file: text == nil ? nil : await session.definition(url, at: p)?.url.path)
        if let text, window?.isVisible == true {
            let popover = NSPopover()
            popover.behavior = .transient
            let vc = NSViewController()
            let label = NSTextField(wrappingLabelWithString: QuickHelpFormatter.plain(text))
            label.font = .systemFont(ofSize: 12)
            label.preferredMaxLayoutWidth = 420
            label.frame.size = label.fittingSize
            let box = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 24, height: label.frame.height + 20))
            label.frame.origin = NSPoint(x: 12, y: 10)
            box.addSubview(label)
            vc.view = box
            popover.contentViewController = vc
            popover.show(relativeTo: anchor, of: editor.textView, preferredEdge: .maxY)
        }
        return text
    }

    func showQuickHelp(url: URL, at p: Position, anchor: NSRect) {
        Task { await showQuickHelp(url: url, at: p, anchor: anchor) }
    }

    func jumpToDefinition(url: URL, at p: Position) {
        Task {
            guard let loc = await session.definition(url, at: p) else { return NSSound.beep() }
            open(path: loc.url.standardizedFileURL.path, line: nil)
            editor.reveal(position: loc.start)
        }
    }

    @objc public func revealInProjectNavigator(_ sender: Any?) {
        navigatorItem.isCollapsed = false
        navigator.select(0)
    }

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Titles in context (reference-ui-5.md §1.3; WorkspaceWindowController+MenuBar.swift).
        if let generic = Self.menuBarGenericTitle(item) { item.title = MenuTitles.title(generic: generic, in: menuContext) }
        if let r = validateMenuBarItem(item) { return r }
        if let r = validateDebugMenuItem(item) { return r }
        if let r = validateCodingAssistantItem(item) { return r }
        switch item.action {
        case #selector(closeDocument(_:)): return editor.fileURL != nil
        case #selector(closeEditor(_:)): return EditorCloseCommand.editorPane.isEnabled(paneCount: editorArea.tab.editors.count)
        case #selector(pauseOrContinue(_:)): return session.debugClient != nil
        case #selector(stepOver(_:)), #selector(stepInto(_:)), #selector(stepOut(_:)):
            return session.stoppedThread != nil
        case #selector(stopProduct(_:)): return session.isBusy
        case let a? where IntegrateMenuState.actions.contains(NSStringFromSelector(a)):
            return sourceControl.menuState().isEnabled(NSStringFromSelector(a))
        default: if let r = validateEditorMenuItem(item) { return r }
        }
        return true
    }
}
