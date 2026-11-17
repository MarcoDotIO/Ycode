import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
import YcodeWorkspace
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Beta 4 scheme fixes (parity inventory P-108, P-109, P-110). No window
/// reaches a display (the offscreen guard).
@MainActor
@Suite(.serialized) struct WorkflowsSchemesB4Tests {
    /// A copy of the Hello project without scheme files: its scheme is
    /// autocreated.
    func helloWithoutSchemes(_ name: String) throws -> URL {
        let proj = ycodeDir.appendingPathComponent(".build-ide/b4-workflows-\(name)/Hello.xcodeproj")
        try? FileManager.default.removeItem(at: proj.deletingLastPathComponent())
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                                         to: proj.appendingPathComponent("project.pbxproj"))
        return proj
    }

    func window(_ proj: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        return WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: proj)),
                                         loadDestinations: false, startLanguageService: false)
    }

    func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
    func control<T: NSView>(_ e: SchemeEditorController, _ id: String, as: T.Type = NSView.self) -> T? {
        all(e.view).first { $0.accessibilityIdentifier() == id } as? T
    }

    // MARK: P-108

    @Test func editSchemeOpensAnAutocreatedSchemeAndManageSchemesListsIt() throws {
        let proj = try helloWithoutSchemes("autocreated")
        let wc = try window(proj)
        #expect(wc.session.model.loadSchemes().isEmpty)
        let name = try #require(wc.session.scheme)
        let editor = try #require(wc.editScheme(nil), "Edit Scheme… opens the autocreated scheme")
        #expect(editor.isAutocreated && editor.scheme.name == name)
        #expect(editor.scheme.launchTarget?.blueprintName == name)
        let manage = wc.manageSchemesController()
        #expect(manage.schemes.map(\.name).contains(name))
        _ = manage.view
        let table = try #require(all(manage.view).compactMap { $0 as? NSTableView }.first)
        #expect(table.numberOfRows >= 1)
        let container = manage.tableView(table, viewFor: table.tableColumns.first { $0.identifier.rawValue == "container" }, row: 0) as? NSTextField
        #expect(container?.stringValue == "Hello.xcodeproj")

        // Closing unchanged writes nothing: the scheme stays autocreated.
        editor.closeSheet()
        #expect(wc.session.model.loadSchemes().isEmpty)

        // A change writes the user scheme (and its siblings), which then
        // opens from its file.
        let again = try #require(wc.editScheme(nil))
        _ = again.view
        again.setArguments([.init("-verbose", enabled: true)])
        again.closeSheet()
        let file = Scheme.fileURL(container: proj, name: name, shared: false)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let reopened = try #require(wc.editScheme(nil))
        #expect(!reopened.isAutocreated && reopened.scheme.launchArguments.map(\.value) == ["-verbose"])
        #expect(wc.session.model.schemeNames.contains(name))
    }

    /// Product ▸ Run… / Test… (⌥ alternates, `editSchemeThenPerform`)
    /// open an autocreated scheme on their action too, and the action
    /// runs when the editor closes; closing unchanged writes no file.
    @Test func ellipsisVariantOpensAnAutocreatedScheme() throws {
        let proj = try helloWithoutSchemes("ellipsis")
        let wc = try window(proj)
        #expect(wc.session.model.loadSchemes().isEmpty)
        let name = try #require(wc.session.scheme)
        var ran = 0
        let editor = try #require(wc.editSchemeThenPerform(action: 2) { ran += 1 }, "Test… opens the autocreated scheme")
        _ = editor.view
        #expect(editor.isAutocreated && editor.scheme.name == name)
        #expect(editor.selectedAction == 2 && ran == 0)
        editor.closeSheet()
        #expect(ran == 1)
        #expect(wc.session.model.loadSchemes().isEmpty)
    }

    @Test func sharingAnAutocreatedSchemeWritesItFirst() throws {
        let proj = try helloWithoutSchemes("autocreated-shared")
        let wc = try window(proj)
        let manage = wc.manageSchemesController()
        let i = try #require(manage.schemes.indices.first)
        try manage.setShared(true, at: i)
        #expect(FileManager.default.fileExists(atPath: Scheme.fileURL(container: proj, name: manage.schemes[i].name, shared: true).path))
    }

    // MARK: P-109

    func editor(_ name: String) throws -> (SchemeEditorController, WorkspaceWindowController) {
        let proj = try helloWithoutSchemes(name)
        let wc = try window(proj)
        let e = try #require(wc.editScheme(nil))
        _ = e.view
        return (e, wc)
    }

    @Test func runInfoOptionsAreEditable() throws {
        let (e, _) = try editor("run-info")
        e.select(action: 1, tab: 0)
        let debug = try #require(control(e, "LaunchAction.debugExecutable", as: NSButton.self))
        #expect(debug.isEnabled && debug.state == .on)
        debug.performClick(nil)
        #expect(e.scheme.attribute("selectedDebuggerIdentifier", of: "LaunchAction") == "")
        #expect(e.scheme.attribute("selectedLauncherIdentifier", of: "LaunchAction") == Scheme.posixSpawnLauncher)
        let root = try #require(control(e, "LaunchAction.debugAsWhichUser.1", as: NSButton.self))
        #expect(root.isEnabled)
        root.performClick(nil)
        #expect(e.scheme.attribute("debugAsWhichUser", of: "LaunchAction") == "root")
        let wait = try #require(control(e, "LaunchAction.launchStyle.1", as: NSButton.self))
        wait.performClick(nil)
        #expect(e.scheme.attribute("launchStyle", of: "LaunchAction") == "1")
        let lldb = try #require(control(e, "LaunchAction.customLLDBInitFile", as: SchemeOptionField.self))
        #expect(lldb.isEnabled)
        lldb.stringValue = "$(SRCROOT)/.lldbinit"
        lldb.onCommit?(lldb.stringValue)
        #expect(e.scheme.attribute("customLLDBInitFile", of: "LaunchAction") == "$(SRCROOT)/.lldbinit")
        let exe = try #require(control(e, "LaunchAction.executable", as: NSPopUpButton.self))
        #expect(exe.isEnabled && exe.itemTitles.last == "Ask on Launch")
        exe.selectItem(at: exe.numberOfItems - 1)
        _ = exe.target?.perform(exe.action, with: exe)
        #expect(e.scheme.attribute("askForAppToLaunch", of: "LaunchAction") == "YES")
        WorkflowsB4Shots.save(e.view, "mac-p109-scheme-run-info")
    }

    @Test func runOptionsDiagnosticsBuildAndArchiveOptionsAreEditable() throws {
        let (e, _) = try editor("run-options")
        e.select(action: 1, tab: 2)
        let location = try #require(control(e, "LaunchAction.allowLocationSimulation", as: NSButton.self))
        #expect(location.isEnabled && location.state == .on)
        location.performClick(nil)
        #expect(e.scheme.attribute("allowLocationSimulation", of: "LaunchAction") == "NO")
        let gpu = try #require(control(e, "LaunchAction.enableGPUFrameCaptureMode", as: NSPopUpButton.self))
        gpu.selectItem(withTitle: "Disabled")
        _ = gpu.target?.perform(gpu.action, with: gpu)
        #expect(e.scheme.attribute("enableGPUFrameCaptureMode", of: "LaunchAction") == "3")
        let language = try #require(control(e, "LaunchAction.language", as: NSPopUpButton.self))
        language.selectItem(withTitle: "French")
        _ = language.target?.perform(language.action, with: language)
        #expect(e.scheme.attribute("language", of: "LaunchAction") == "fr")
        WorkflowsB4Shots.save(e.view, "mac-p109-scheme-run-options")

        e.select(action: 1, tab: 3)
        let mtc = try #require(control(e, "LaunchAction.disableMainThreadChecker", as: NSButton.self))
        #expect(mtc.isEnabled && mtc.state == .on)
        mtc.performClick(nil)
        #expect(e.scheme.attribute("disableMainThreadChecker", of: "LaunchAction") == "YES")

        e.select(action: 0)
        let arch = try #require(control(e, "BuildAction.buildArchitectures", as: NSPopUpButton.self))
        #expect(arch.isEnabled && arch.titleOfSelectedItem == "Use Target Settings")
        arch.selectItem(withTitle: "Match Run Destination")
        _ = arch.target?.perform(arch.action, with: arch)
        #expect(e.scheme.attribute("buildArchitectures", of: "BuildAction") == "Automatic")
        let manual = try #require(control(e, "BuildAction.parallelizeBuildables.1", as: NSButton.self))
        manual.performClick(nil)
        #expect(e.scheme.attribute("parallelizeBuildables", of: "BuildAction") == "NO")

        e.select(action: 5)
        let reveal = try #require(control(e, "ArchiveAction.revealArchiveInOrganizer", as: NSButton.self))
        reveal.performClick(nil)
        #expect(e.scheme.attribute("revealArchiveInOrganizer", of: "ArchiveAction") == "NO")

        // The test action has its own debugger rows.
        e.select(action: 2)
        let testDebug = try #require(control(e, "TestAction.debugExecutable", as: NSButton.self))
        #expect(testDebug.isEnabled)
    }

    @Test func duplicateSchemeWritesACopy() throws {
        let (e, wc) = try editor("duplicate")
        let copy = try #require(e.duplicateScheme())
        #expect(copy.name == "\(e.scheme.name) Copy")
        #expect(FileManager.default.fileExists(atPath: try #require(copy.url).path))
        #expect(wc.session.model.schemeNames.contains(copy.name))
    }

    // MARK: P-110

    func escape() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    }

    @Test func firstEscapeEndsEditingSecondClosesTheSheet() throws {
        let (e, _) = try editor("escape")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = e
        w.orderFront(nil)
        defer { w.orderOut(nil) }
        var closed = 0
        e.onClose = { _ in closed += 1 }
        e.select(action: 1, tab: 0)
        let lldb = try #require(control(e, "LaunchAction.customLLDBInitFile", as: SchemeOptionField.self))
        #expect(w.makeFirstResponder(lldb))
        let fieldEditor = try #require(lldb.currentEditor() as? NSTextView)
        fieldEditor.insertText("typed", replacementRange: fieldEditor.selectedRange())
        // First Escape: editing ends, the typed value is discarded.
        #expect(w.contentView?.performKeyEquivalent(with: escape()) == true)
        #expect(lldb.currentEditor() == nil && closed == 0)
        #expect(e.scheme.attribute("customLLDBInitFile", of: "LaunchAction") == nil)
        // Second Escape: the sheet closes.
        #expect(w.contentView?.performKeyEquivalent(with: escape()) == true)
        #expect(closed == 1)
    }
}
