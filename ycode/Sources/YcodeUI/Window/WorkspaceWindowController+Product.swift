import AppKit
import YcodeBuild

/// Product menu commands (`specs/ide/reference-ui-5.md` §2.9, R36): Build
/// For, Perform Action, Clean Build Folder (with and without confirmation),
/// the "…" variants that open the scheme editor first, the Destination and
/// Test Plan submenus.
extension WorkspaceWindowController {
    // MARK: Run

    /// Run (`building`) or Run Without Building (⌃⌘R) on the destination:
    /// the Mac under the debugger, a Mac simulator, or Ycode's remote
    /// simulator (`specs/ide/run.md`). Without building, the product of
    /// the last build is launched; when there is none the console says so.
    /// (`runProduct` keeps its own copy of the dispatch for now, so the
    /// remote-simulator run path stays where its owners edit it.)
    func runScheme(building: Bool) {
        let request = session.model.buildRequest(scheme: session.scheme, destination: session.destination, action: .build)
        let engine = session.engine
        if let d = session.destination, d.isYcodeRemoteSimulator || (d.kind == .simulator && d.platform != "macOS") {
            Task {
                if building {
                    let result = await session.build(.build)
                    guard result.status == .succeeded else { return }
                }
                guard let exe = await Task.detached(operation: { engine.executablePath(for: request) }).value else { return }
                let app = URL(fileURLWithPath: Self.simulatorAppPath(fromExecutablePath: exe))
                guard building || FileManager.default.fileExists(atPath: app.path) else {
                    session.reportMissingProduct(app.path)
                    return
                }
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
            await session.run(program: program, building: building)
        }
    }

    /// Perform Action ▸ Run Without Building (⌃⌘R).
    @objc public func runWithoutBuilding(_ sender: Any?) { runScheme(building: false) }

    // MARK: Build For

    @objc public func buildForRunning(_ sender: Any?) { Task { await session.buildFor(.running) } }
    @objc public func buildForTesting(_ sender: Any?) { Task { await session.buildFor(.testing) } }
    @objc public func buildForProfiling(_ sender: Any?) { Task { await session.buildFor(.profiling) } }

    // MARK: Test

    /// Perform Action ▸ Test Without Building (⌃⌘U): every test, as built
    /// by Build For ▸ Testing.
    @objc public func testWithoutBuilding(_ sender: Any?) { Task { await session.runTests(withoutBuilding: true) } }
    /// Perform Action ▸ Test Again (⌃⌥⌘G).
    @objc public func testAgain(_ sender: Any?) { Task { await session.testAgain() } }
    /// Perform Action ▸ Test Without Building Again.
    @objc public func testWithoutBuildingAgain(_ sender: Any?) { Task { await session.testAgain(withoutBuilding: true) } }
    /// Product ▸ Clear Test Results (⌃⌥⌘K).
    @objc public func clearTestResults(_ sender: Any?) { session.clearTestResults() }

    /// Perform Action ▸ Test (⌃⌥⌘U): the tests selected in the Test
    /// navigator, or the test at the caret.
    @objc public func testSelectedTests(_ sender: Any?) {
        let tests = selectedTests
        guard !tests.isEmpty else { NSSound.beep(); return }
        Task { await session.runTests(only: tests) }
    }

    /// The tests Perform Action ▸ Test runs: with a row selected in the
    /// Test navigator, that test, suite or target (the plan: all tests);
    /// otherwise the test or suite declared at or above the caret.
    public var selectedTests: [DiscoveredTest] {
        if navigator.selectedIndex == 5, let item = navigator.selectedItem {
            if let path = item.path, let line = item.line {
                if let t = session.tests.first(where: { $0.file == path && $0.line == line }) { return [t] }
                let suite = session.testsForDiamond(file: path, line: line)
                if !suite.isEmpty { return suite }
            }
            // A target or the plan: the tests of its leaves.
            func leaves(_ i: OutlineItem) -> [OutlineItem] { i.children.isEmpty ? [i] : i.children.flatMap(leaves) }
            let rows = leaves(item)
            let found = session.tests.filter { t in rows.contains { $0.path == t.file && $0.line == t.line } }
            if !found.isEmpty { return found }
        }
        guard let file = editor.fileURL?.path, editor.auxiliary == nil else { return [] }
        return session.tests(atCaret: file, line: editor.currentLine)
    }

    // MARK: Single-file actions

    @objc public func compileFile(_ sender: Any?) { performFileAction(.compile) }
    @objc public func analyzeFile(_ sender: Any?) { performFileAction(.analyze) }
    @objc public func preprocessFile(_ sender: Any?) { performFileAction(.preprocess) }
    @objc public func assembleFile(_ sender: Any?) { performFileAction(.assemble) }

    /// Perform Action ▸ Compile / Analyze / Preprocess / Assemble
    /// “<file>”: saves the file, processes it in its module's context, and
    /// shows the preprocessed source or the assembly in the editor.
    @discardableResult
    public func performFileAction(_ action: FileAction) -> Task<(result: BuildResult, output: String?), Never>? {
        guard let file = editor.fileURL?.path, WorkspaceSession.canPerform(action, file: file) else { NSSound.beep(); return nil }
        try? editor.save()
        let request = session.model.buildRequest(scheme: session.scheme, destination: session.destination, action: .build)
        let engine = session.engine
        let isProject = session.model.kind != .package
        return Task { @MainActor in
            // The products folder of the scheme's other targets (for imports).
            let products: String? = isProject ? await Task.detached {
                engine.executablePath(for: request).flatMap { exe -> String? in
                    guard let r = exe.range(of: "/Products/") else { return nil }
                    let rest = exe[r.upperBound...]
                    return String(exe[..<r.upperBound]) + String(rest.prefix { $0 != "/" })
                }
            }.value : nil
            let r = await session.perform(action, file: file, productsDirectory: products)
            if let out = r.output, action == .preprocess || action == .assemble { open(path: out, line: nil) }
            return r
        }
    }

    // MARK: Clean

    /// Clean Build Folder… (⇧⌘K): asks before cleaning. Returns the alert
    /// (shown as a sheet while the window is on screen).
    @discardableResult
    public func confirmCleanBuildFolder() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Clean the build folder of \u{201C}\(session.scheme ?? session.model.displayName)\u{201D}?"
        alert.informativeText = "All products and intermediate files in the build folder are deleted. The next build builds everything again."
        alert.addButton(withTitle: "Clean")
        alert.addButton(withTitle: "Cancel")
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { [weak self] r in
                if r == .alertFirstButtonReturn { self?.cleanProductImmediately(nil) }
            }
        }
        return alert
    }

    /// Clean Build Folder Immediately (⌥⇧⌘K): no confirmation.
    @objc public func cleanProductImmediately(_ sender: Any?) { Task { await session.build(.clean) } }

    // MARK: "…" variants

    /// Run… / Test… / Analyze… / Archive…: the scheme editor on that
    /// action; the action runs when the editor closes (§2.9). A scheme
    /// without a file (autocreated) runs at once.
    @discardableResult
    public func editSchemeThenPerform(action index: Int, _ perform: @escaping @MainActor () -> Void) -> SchemeEditorController? {
        guard let scheme = session.model.loadSchemes().first(where: { $0.name == session.scheme }) else {
            perform()
            return nil
        }
        let editor = SchemeEditorController(scheme: scheme, configurations: session.model.configurationNames)
        editor.startSelection = (index, 0)
        editor.onSelect = { [weak self] a, t in self?.schemeEditorState.selection = (a, t) }
        editor.onManage = { [weak self, weak editor] in
            guard let self else { return }
            editor?.presentAsSheet(self.manageSchemesController())
        }
        editor.onClose = { _ in perform() }
        if window?.isVisible == true { contentViewController?.presentAsSheet(editor) }
        return editor
    }

    @objc public func runProductEditingScheme(_ sender: Any?) { editSchemeThenPerform(action: 1) { [weak self] in self?.runProduct(nil) } }
    @objc public func testProductEditingScheme(_ sender: Any?) { editSchemeThenPerform(action: 2) { [weak self] in self?.testProduct(nil) } }
    @objc public func analyzeProductEditingScheme(_ sender: Any?) { editSchemeThenPerform(action: 4) { [weak self] in self?.analyzeProduct(nil) } }
    @objc public func archiveProductEditingScheme(_ sender: Any?) { editSchemeThenPerform(action: 5) { [weak self] in self?.archiveProduct(nil) } }

    // MARK: Destination (§2.9 item 20)

    /// Product ▸ Destination ▸ <row>.
    @objc public func selectDestinationRow(_ sender: Any?) {
        guard let key = (sender as? NSMenuItem)?.representedObject as? String ?? sender as? String else { return }
        let all = session.model.destinations + destinationMenuModel().sections.flatMap(\.destinations)
        guard let d = Self.destination(forKey: key, in: all) else { return }
        session.destination = d
        rememberDestination()
        rebuildDestinationMenu()
    }

    /// Select Next / Previous Destination (⌃⌥⌘] / ⌃⌥⌘[): the next row of
    /// Devices, Simulators and Build, wrapping.
    @objc public func selectNextDestination(_ sender: Any?) { stepDestination(1) }
    @objc public func selectPreviousDestination(_ sender: Any?) { stepDestination(-1) }

    func stepDestination(_ delta: Int) {
        let rows = destinationMenuModel().selectable
        guard !rows.isEmpty else { NSSound.beep(); return }
        let current = session.destination.map(Self.menuKey(for:))
        let i = rows.firstIndex { Self.menuKey(for: $0) == current }
        let next = i.map { ($0 + delta + rows.count) % rows.count } ?? (delta > 0 ? 0 : rows.count - 1)
        selectDestinationRow(Self.menuKey(for: rows[next]))
    }

    /// Show All Run Destinations: the toolbar's destination menu with the
    /// incompatible destinations listed in it (§11.4 item 5).
    @objc public func showAllRunDestinations(_ sender: Any?) {
        guard window?.isVisible == true else { return }
        rebuildDestinationMenu(expandIncompatible: true)
        destinationPopUp.performClick(nil)
        rebuildDestinationMenu()
    }

    // MARK: Test Plan (§2.9 item 21)

    @objc public func selectNextTestPlan(_ sender: Any?) { session.stepTestPlan(1) }
    @objc public func selectPreviousTestPlan(_ sender: Any?) { session.stepTestPlan(-1) }

    /// Product ▸ Test Plan ▸ <plan>.
    @objc public func selectTestPlanRow(_ sender: Any?) {
        guard let name = (sender as? NSMenuItem)?.representedObject as? String, session.testPlanNames.contains(name) else { return }
        session.activeTestPlan = name
    }

    // MARK: Validation

    /// Enablement of the Product commands of this file; nil = not one of them.
    func validateProductMenuItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(testAgain(_:)), #selector(testWithoutBuildingAgain(_:)): return session.lastTestRun != nil
        case #selector(testSelectedTests(_:)): return !selectedTests.isEmpty
        case #selector(clearTestResults(_:)): return !session.testResults.isEmpty || session.failedTestCount > 0
        case #selector(compileFile(_:)): return WorkspaceSession.canPerform(.compile, file: editor.fileURL?.path)
        case #selector(analyzeFile(_:)): return WorkspaceSession.canPerform(.analyze, file: editor.fileURL?.path)
        case #selector(preprocessFile(_:)): return WorkspaceSession.canPerform(.preprocess, file: editor.fileURL?.path)
        case #selector(assembleFile(_:)): return WorkspaceSession.canPerform(.assemble, file: editor.fileURL?.path)
        case #selector(archiveProductEditingScheme(_:)): return session.model.kind != .package
        case #selector(selectNextDestination(_:)), #selector(selectPreviousDestination(_:)):
            return destinationMenuModel().selectable.count > 1
        case #selector(selectDestinationRow(_:)):
            let key = item.representedObject as? String
            item.state = key != nil && key == session.destination.map(Self.menuKey(for:)) ? .on : .off
            return key != nil
        case #selector(selectNextTestPlan(_:)), #selector(selectPreviousTestPlan(_:)): return session.testPlanNames.count > 1
        case #selector(selectTestPlanRow(_:)):
            item.state = (item.representedObject as? String ?? item.title) == session.effectiveTestPlan ? .on : .off
            // The autocreated plan is the only row and always the active one.
            return item.representedObject == nil || session.testPlanNames.contains(item.representedObject as? String ?? "")
        default: return nil
        }
    }
}

extension DynamicMenus {
    /// §2.9 item 20: the rows under "Devices", "Simulators" and "Build",
    /// "<name> <OS version>" with the active one checked, and the
    /// Incompatible submenu (§11.4).
    static func fillDestinations(_ m: NSMenu, model: DestinationMenuModel, current: Destination?, target: AnyObject?) {
        removeDynamic(m)
        let currentKey = current.map(WorkspaceWindowController.menuKey(for:))
        func row(_ d: Destination, enabled: Bool = true) -> NSMenuItem {
            let i = NSMenuItem(title: DestinationMenuModel.submenuTitle(d), action: enabled ? #selector(WorkspaceWindowController.selectDestinationRow(_:)) : nil,
                               keyEquivalent: "")
            i.target = enabled ? target : nil
            i.representedObject = enabled ? WorkspaceWindowController.menuKey(for: d) : nil
            i.tag = MenuBarDelegate.dynamicTag
            i.state = enabled && WorkspaceWindowController.menuKey(for: d) == currentKey ? .on : .off
            i.isEnabled = enabled
            return i
        }
        for label in ["Devices", "Simulators", "Build"] {
            guard let at = m.items.firstIndex(where: { $0.isSectionHeader && $0.title == label }) else { continue }
            // Ycode's remote simulator is among the Simulators rows (§11.5).
            let rows = model.rows(label)
            for (n, d) in rows.enumerated() { m.insertItem(row(d), at: at + 1 + n) }
        }
        if let sub = m.items.first(where: { $0.title == DestinationMenuModel.incompatibleTitle })?.submenu {
            sub.removeAllItems()
            sub.autoenablesItems = false
            for d in model.incompatible { sub.addItem(row(d, enabled: false)) }
        }
    }

    /// §2.9 item 21: one row per test plan of the scheme, the active one
    /// checked; "<scheme> (Autocreated)" when it has none.
    static func fillTestPlans(_ m: NSMenu, rows: [String], plans: [String], active: String, target: AnyObject?) {
        removeDynamic(m)
        let sep = NSMenuItem.separator()
        sep.tag = MenuBarDelegate.dynamicTag
        m.addItem(sep)
        for name in rows {
            let i = NSMenuItem(title: name, action: #selector(WorkspaceWindowController.selectTestPlanRow(_:)), keyEquivalent: "")
            i.target = target
            i.representedObject = plans.contains(name) ? name : nil
            i.tag = MenuBarDelegate.dynamicTag
            i.state = name == active ? .on : .off
            m.addItem(i)
        }
    }
}
