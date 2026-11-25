import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// Beta 5's menu items on macOS (B5-MENUS2; the Linux half is
/// `ShellMenusB5Tests`): Save All as Save's ⌥ alternate and the File
/// commands the reference enables (P-001), Product's and Debug's glyphs
/// (P-013), Integrate's Stage title (P-016), the Editor menu at Welcome
/// (P-006) and the menu test hygiene of beta 4's candidates. Offscreen: no
/// window is shown, no panel opens (the save panel's answer is given).
@MainActor
@Suite(.serialized) struct MenusB5Tests {
    func withWindow(_ body: @MainActor (WorkspaceWindowController, URL) throws -> Void) throws {
        let prefs = IsolatedPreferences("menus-b5")
        defer { prefs.restore() }
        let dir = ycodeDir.appendingPathComponent(".build-ide/menus-b5/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("Pkg/Sources/Demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\")])\n"
            .write(to: dir.appendingPathComponent("Pkg/Package.swift"), atomically: true, encoding: .utf8)
        try "let greeting = \"hi\"\n".write(to: src.appendingPathComponent("Demo.swift"), atomically: true, encoding: .utf8)
        _ = NSApplication.shared
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir.appendingPathComponent("Pkg"))),
                                           loadDestinations: false, startLanguageService: false, openFirstFile: false)
        wc.applyDefaultLayout()
        defer { wc.window?.close() }
        try body(wc, dir)
    }

    func item(_ action: String) -> NSMenuItem { NSMenuItem(title: action, action: NSSelectorFromString(action), keyEquivalent: "") }

    func menu(_ bar: NSMenu, _ title: String) throws -> NSMenu { try #require(bar.item(withTitle: title)?.submenu) }

    /// P-001: ⌥ turns Save into Save All (one row; Save All is its alternate).
    @Test func saveAllIsTheOptionAlternateOfSave() throws {
        let file = try menu(MainMenu.make(), "File")
        let i = try #require(file.items.firstIndex { $0.action == NSSelectorFromString("saveDocument:") })
        let next = file.items[i + 1]
        #expect(next.action == NSSelectorFromString("saveAllDocuments:") && next.isAlternate)
        #expect(MainMenu.canonicalShortcut(next) == "⌥⌘S" && MainMenu.canonicalShortcut(file.items[i]) == "⌘S")
        #expect(!file.items[i].isAlternate)
    }

    /// P-001: Save As…, Export…, Open in New Window and Save As
    /// Workspace… are enabled where the reference enables them, and write
    /// what they say.
    @Test func fileCommandsAreEnabledAndWrite() throws {
        try withWindow { wc, dir in
            // A package has no document of its own: Save As… and Export…
            // need a file; Save As Workspace… does not.
            #expect(!wc.validateMenuItem(item("saveFileAs:")) && !wc.validateMenuItem(item("exportFile:")))
            #expect(wc.validateMenuItem(item("saveAsWorkspace:")))
            #expect(!wc.validateMenuItem(item("openInNewWindow:")))
            let demo = dir.appendingPathComponent("Pkg/Sources/Demo/Demo.swift")
            wc.open(path: demo.path, line: nil)
            for a in ["saveFileAs:", "exportFile:", "openInNewWindow:", "saveAsWorkspace:"] { #expect(wc.validateMenuItem(item(a)), "\(a)") }

            var answer: URL?
            WorkspaceWindowController.chooseSaveURL = { _, _ in answer }
            defer { WorkspaceWindowController.chooseSaveURL = nil }
            wc.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
            wc.editor.textView.insertText("// edited\n", replacementRange: NSRange(location: 0, length: 0))
            // Export…: a copy with the edit; the editor keeps the original.
            answer = dir.appendingPathComponent("Copy.swift")
            wc.exportFile(nil)
            #expect(try String(contentsOf: dir.appendingPathComponent("Copy.swift"), encoding: .utf8).hasPrefix("// edited"))
            #expect(wc.editor.fileURL?.standardizedFileURL == demo.standardizedFileURL)
            // Save As…: the edit goes to the new file, which the editor shows.
            let moved = dir.appendingPathComponent("Pkg/Sources/Demo/Moved.swift")
            answer = moved
            wc.saveFileAs(nil)
            #expect(try String(contentsOf: moved, encoding: .utf8).hasPrefix("// edited"))
            #expect(try String(contentsOf: demo, encoding: .utf8) == "let greeting = \"hi\"\n")
            #expect(wc.editor.fileURL?.standardizedFileURL == moved.standardizedFileURL && !wc.editor.isDirty)
            // Save As Workspace…: a workspace beside the package holding it.
            answer = dir.appendingPathComponent("Pkg")
            wc.saveAsWorkspace(nil)
            let data = try String(contentsOf: dir.appendingPathComponent("Pkg.xcworkspace/contents.xcworkspacedata"), encoding: .utf8)
            #expect(data.contains("location = \"group:Pkg\""))
        }
    }

    /// P-001 (Linux's counterpart reads the same): Save As Workspace…'s
    /// references are relative to the workspace's folder.
    @Test func workspaceDataIsRelative() {
        let text = FileMenuCommands.workspaceData(referencing: [URL(fileURLWithPath: "/a/b/App.xcodeproj")], base: "/a/c")
        #expect(text.contains("location = \"group:../b/App.xcodeproj\""))
        #expect(FileMenuCommands.isEnabled("saveFileAs:", hasDocument: false, containerKind: .project) == true)
        #expect(FileMenuCommands.isEnabled("saveFileAs:", hasDocument: false, containerKind: .package) == false)
        #expect(FileMenuCommands.isEnabled("saveAsWorkspace:", hasDocument: true, containerKind: .workspace) == false)
    }

    /// P-013: Product's Run, Test, Profile, Analyze, Archive and Stop and
    /// Debug's steps carry their glyph from the moment the menu bar is
    /// built (no menu update needed); alternates and other items none.
    @Test func productAndDebugItemsHaveGlyphs() throws {
        let bar = MainMenu.make()
        let product = try menu(bar, "Product"), debug = try menu(bar, "Debug")
        for a in ["runProduct:", "testProduct:", "profileProduct:", "analyzeProduct:", "archiveProduct:", "stopProduct:"] {
            let i = try #require(product.items.first { $0.action == NSSelectorFromString(a) && !$0.isAlternate })
            #expect(i.image != nil, "\(a)")
        }
        for a in ["stepOver:", "stepInto:", "stepOut:"] {
            #expect(debug.items.first { $0.action == NSSelectorFromString(a) }?.image != nil, "\(a)")
        }
        #expect(product.items.first { $0.action == NSSelectorFromString("buildProduct:") }?.image == nil)
        #expect(product.items.filter(\.isAlternate).allSatisfy { $0.image == nil })
    }

    /// P-016 and P-006: Integrate's Stage title in a workspace; Preview is
    /// unchecked with only Welcome.
    @Test func stageTitleAndWelcomePreview() throws {
        try withWindow { wc, _ in
            let bar = MainMenu.make()
            let integrate = try menu(bar, "Integrate")
            MenuBarDelegate.shared.update(integrate, controller: nil)
            #expect(integrate.items.contains { $0.title == "Stage Selected Files" })
            MenuBarDelegate.shared.update(integrate, controller: wc)
            #expect(integrate.items.contains { $0.title == "Stage Changes in Selected Files" })
            let editor = try menu(bar, "Editor")
            MenuBarDelegate.shared.update(editor, controller: nil)
            let preview = try #require(editor.items.first { $0.action == NSSelectorFromString("toggleCanvas:") })
            #expect(preview.title == "Preview" && preview.state == .off)
        }
    }

    func visible(_ m: NSMenu) -> [String] {
        m.items.filter { !$0.isHidden && !$0.isAlternate }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// AppKit's enabling: the item's target or the window's chain (here the
    /// controller), else nothing performs it.
    func enabled(_ i: NSMenuItem, _ wc: WorkspaceWindowController?) -> Bool {
        guard let a = i.action else { return false }
        if let t = i.target as? NSObject { return t.responds(to: a) && ((t as? NSMenuItemValidation)?.validateMenuItem(i) ?? true) }
        guard let wc, wc.responds(to: a) else { return false }
        return wc.validateMenuItem(i)
    }

    /// P-006 (council round 11, B02): with only Welcome, View ▸ Inspectors
    /// holds Show Inspector alone, disabled, and Editor ▸ Layout lists
    /// Automatic, Editor on Left, Editor on Top, all disabled; in a
    /// workspace with no file open, Inspectors lists File ⌥⌘1, History ⌥⌘2,
    /// Quick Help ⌥⌘3 and Hide Inspector.
    @Test func inspectorsAndLayoutAtWelcomeAndInAnEmptyWorkspace() throws {
        try withWindow { wc, _ in
            let bar = MainMenu.make()
            let view = try menu(bar, "View")
            let inspectors = try #require(view.items.first { $0.title == "Inspectors" }?.submenu)
            MenuBarDelegate.shared.update(inspectors, controller: nil)
            #expect(visible(inspectors) == ["Show Inspector"])
            #expect(inspectors.items.filter { !$0.isHidden && !$0.isSeparatorItem }.allSatisfy { !enabled($0, nil) })

            let editor = try menu(bar, "Editor")
            MenuBarDelegate.shared.update(editor, controller: nil)
            let layout = try #require(editor.items.first { $0.title == "Layout" }?.submenu)
            #expect(visible(layout) == ["Automatic", "—", "Editor on Left", "Editor on Top"])
            #expect(layout.items.filter { !$0.isSeparatorItem }.allSatisfy { !enabled($0, nil) && $0.state == .off })

            #expect(wc.editor.fileURL == nil)
            MenuBarDelegate.shared.update(inspectors, controller: wc)
            #expect(visible(inspectors) == ["File", "History", "Quick Help", "—", "Hide Inspector"])
            #expect(inspectors.items.prefix(3).map { MainMenu.canonicalShortcut($0) } == ["⌥⌘1", "⌥⌘2", "⌥⌘3"])
            // The workspace's Editor menu keeps its own Layout items.
            MenuBarDelegate.shared.update(editor, controller: wc)
            let layout2 = try #require(editor.items.first { $0.title == "Layout" }?.submenu)
            #expect(visible(layout2) == ["Automatic", "—", "Preview on Right", "Preview on Bottom"])
        }
    }

    /// Menu test hygiene: Duplicate Editor Tab is enabled with any
    /// workspace (its one validation is `validateMenuParityItem`'s).
    @Test func duplicateEditorTabWithoutADocument() throws {
        try withWindow { wc, _ in
            #expect(wc.editor.fileURL == nil)
            #expect(wc.validateMenuItem(item("duplicateEditorTab:")))
        }
    }
}
