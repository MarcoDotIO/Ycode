import AppKit
import Foundation
import Testing
import YcodeWorkspace
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct SchemeEditorTests {
    /// A copy of the Hello project with the App scheme fixture as a shared scheme.
    func project() throws -> (proj: URL, scheme: URL, text: String) {
        let fm = FileManager.default
        let proj = ycodeDir.appendingPathComponent(".build-ide/scheme-ui/Hello.xcodeproj")
        try? fm.removeItem(at: proj.deletingLastPathComponent())
        try fm.createDirectory(at: proj, withIntermediateDirectories: true)
        try fm.copyItem(at: ycodeDir.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj/project.pbxproj"),
                        to: proj.appendingPathComponent("project.pbxproj"))
        let text = try String(contentsOf: ycodeDir.appendingPathComponent(
            "Tests/YcodeWorkspaceTests/Fixtures/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"), encoding: .utf8)
        let scheme = Scheme.fileURL(container: proj, name: "App", shared: true)
        try fm.createDirectory(at: scheme.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: scheme, atomically: true, encoding: .utf8)
        return (proj, scheme, text)
    }

    func render(_ view: NSView, _ name: String) throws {
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        _ = try WindowSnapshotTests().render(view, to: name)
    }

    @Test func editRunArgumentsAndConfiguration() throws {
        _ = NSApplication.shared
        let (proj, schemeFile, original) = try project()
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        #expect(session.model.schemeNames == ["App"])
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        let editor = try #require(wc.editScheme(nil))
        #expect(editor.selectedAction == 1) // Run is selected first
        #expect(session.model.configurationNames == ["Debug", "Release"])
        try render(editor.view, "scheme-editor-run-info.png")
        // The selected action row is drawn light (selection color), never as a
        // dark bar, and its title stays readable.
        let png = ycodeDir.appendingPathComponent(".build-ide/snapshots/scheme-editor-run-info.png")
        let rep = try #require(NSBitmapImageRep(data: try Data(contentsOf: png)))
        let rowRect = editor.view.convert(editor.actionList.rect(ofRow: 1), from: editor.actionList)
        let scale = CGFloat(rep.pixelsWide) / editor.view.bounds.width
        // Sample near the row's right end (background only, no text).
        let px = Int((rowRect.maxX - 12) * scale)
        let py = Int((editor.view.bounds.height - rowRect.midY) * scale) // bitmap rows run top-down
        let color = try #require(rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB))
        #expect(color.brightnessComponent > 0.5, "selected row background is \(color)")
        let cell = try #require(editor.actionList.view(atColumn: 0, row: 1, makeIfNecessary: false) as? SchemeActionCell)
        #expect(cell.title.textColor != .black || color.brightnessComponent > 0.5)

        editor.select(action: 1, tab: 1)
        #expect(editor.arguments.rows.map(\.fields) == [["--verbose \"quoted\" & more"], ["--off"]])
        #expect(editor.environment.rows.first?.fields == ["SCRIPT", "line1\nline2"])
        try render(editor.view, "scheme-editor-run-arguments.png")

        // Close without changes: the file is not rewritten.
        editor.closeSheet()
        #expect(try String(contentsOf: schemeFile, encoding: .utf8) == original)

        editor.setConfiguration("Release", for: "LaunchAction")
        editor.setArguments([.init("-v", enabled: true)])
        editor.closeSheet()
        let saved = try Scheme(contentsOf: schemeFile)
        #expect(saved.configuration(for: "LaunchAction") == "Release")
        #expect(saved.launchArguments.map(\.value) == ["-v"])

        // Restoring the values restores the exact bytes.
        editor.setConfiguration("Debug", for: "LaunchAction")
        editor.setArguments([.init("--verbose \"quoted\" & more", enabled: true), .init("--off", enabled: false)])
        editor.closeSheet()
        #expect(try String(contentsOf: schemeFile, encoding: .utf8) == original)

        // Other actions show their configuration.
        editor.select(action: 5)
        try render(editor.view, "scheme-editor-archive.png")
    }

    @Test func manageSchemesSharedCheckbox() throws {
        _ = NSApplication.shared
        let (proj, schemeFile, original) = try project()
        let session = WorkspaceSession(model: try WorkspaceModel(url: proj))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        let manage = wc.manageSchemesController()
        #expect(manage.schemes.map(\.isShared) == [true])
        try render(manage.view, "manage-schemes.png")
        try manage.setShared(false, at: 0, user: "ycode-test")
        let userFile = proj.appendingPathComponent("xcuserdata/ycode-test.xcuserdatad/xcschemes/App.xcscheme")
        #expect(!FileManager.default.fileExists(atPath: schemeFile.path))
        #expect(try String(contentsOf: userFile, encoding: .utf8) == original)
        try manage.setShared(true, at: 0, user: "ycode-test")
        #expect(try String(contentsOf: schemeFile, encoding: .utf8) == original)
    }

    /// reference-ui-2.md §7: each action's disclosure reveals Pre-actions,
    /// the action and Post-actions; an empty environment list shows its
    /// placeholder.
    @Test func actionDisclosureAndEnvironmentEmptyState() throws {
        _ = NSApplication.shared
        let text = try String(contentsOf: ycodeDir.appendingPathComponent(
            "Tests/YcodeWorkspaceTests/Fixtures/App.xcodeproj/xcshareddata/xcschemes/App.xcscheme"), encoding: .utf8)
        let e = SchemeEditorController(scheme: try Scheme(parsing: text, name: "App"), configurations: ["Debug", "Release"])
        _ = e.view
        #expect(e.actionList.numberOfRows == 6)
        let cell = try #require(e.actionList.view(atColumn: 0, row: 1, makeIfNecessary: true) as? SchemeActionCell)
        #expect(!cell.disclosure.isHidden && cell.disclosure.state == .off)
        cell.disclosure.performClick(nil)
        #expect(e.expandedActions == [1])
        #expect(e.listRows.prefix(5).map { e.title(of: $0) } == ["Build", "Run", "Pre-actions", "Run", "Post-actions"])
        #expect(e.actionList.numberOfRows == 9)
        #expect(e.actionList.selectedRow == 3) // the Run row inside the disclosure
        e.actionList.selectRowIndexes([2], byExtendingSelection: false) // Pre-actions belongs to Run
        #expect(e.selectedAction == 1)
        e.actionList.selectRowIndexes([5], byExtendingSelection: false) // Test
        #expect(e.selectedAction == 2)
        e.setExpanded(false, action: 1)
        #expect(e.actionList.numberOfRows == 6 && e.actionList.selectedRow == 2)

        #expect(e.environment.emptyLabel.stringValue == "No Environment Variables")
        e.environment.rows = []
        #expect(!e.environment.emptyLabel.isHidden)
        e.environment.addRow()
        #expect(e.environment.emptyLabel.isHidden)
        e.environment.table.selectRowIndexes([0], byExtendingSelection: false)
        e.environment.removeRow()
        #expect(!e.environment.emptyLabel.isHidden)
        // reference-ui-5.md §11.3: the arguments list has its own empty state.
        #expect(e.arguments.emptyLabel.stringValue == "No Arguments")
    }
}
