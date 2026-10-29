import AppKit
import Foundation
import Testing
import YcodeProject
@testable import YcodeUI

/// R38 (`specs/ide/reference-ui-6.md` §1.1–§1.3): the window title, the
/// Welcome window at launch, opening loose files, the editor at first open.
@MainActor
@Suite(.serialized) struct WindowIdentityR38Tests {
    let r32 = WindowChromeR32Tests()

    // MARK: W1 — window title

    /// The title survives the document machinery: attaching the controller
    /// to its document renamed the window after the document ("Untitled"
    /// or the container), which is how the title regressed.
    @Test func titleSurvivesTheDocumentMachinery() throws {
        let dir = try LaunchWelcomeR31Tests().tempDir("r38-title")
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try LaunchWelcomeR31Tests().iosApp(in: dir)
        let wc = try LaunchWelcomeR31Tests().window(proj)
        let doc = WorkspaceDocument()
        doc.addWindowController(wc)   // AppKit renames the window here
        #expect(wc.window?.title == "Tour \u{2014} Tour.xcodeproj")
        wc.synchronizeWindowTitleWithDocumentName()   // any later rename
        #expect(wc.window?.title == "Tour \u{2014} Tour.xcodeproj")

        let file = try #require(wc.session.model.root.allFiles.first { $0.name == "ContentView.swift" }?.path)
        wc.open(path: file, line: nil)
        #expect(wc.window?.title == "Tour \u{2014} ContentView.swift")
        wc.synchronizeWindowTitleWithDocumentName()
        #expect(wc.window?.title == "Tour \u{2014} ContentView.swift")
        // Saving keeps it.
        wc.editor.textView.insertText("// edit\n", replacementRange: NSRange(location: 0, length: 0))
        wc.saveDocument(nil)
        #expect(wc.window?.title == "Tour \u{2014} ContentView.swift")
        // Switching tabs follows the focused editor.
        wc.newTab(nil)
        #expect(wc.window?.title == "Tour \u{2014} Tour.xcodeproj")
        wc.selectPreviousTab(nil)
        #expect(wc.window?.title == "Tour \u{2014} ContentView.swift")
        wc.selectNextTab(nil)
        wc.closeTab(nil)
        #expect(wc.window?.title == "Tour \u{2014} ContentView.swift")
        // Closing the file: back to the container's name.
        wc.closeDocument(nil)
        #expect(wc.window?.title == "Tour \u{2014} Tour.xcodeproj")
        doc.removeWindowController(wc)
    }

    @Test func packageTitleAndOtherEditorsNameTheFileWithItsExtension() throws {
        let dir = try r32.package("r38-pkg-title")
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist = dir.appendingPathComponent("Sources/Chrome/Data.plist")
        try "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n<dict/>\n</plist>\n".write(to: plist, atomically: true, encoding: .utf8)
        let wc = try r32.window(dir)
        let doc = WorkspaceDocument()
        doc.addWindowController(wc)
        let name = dir.lastPathComponent   // the package's name
        #expect(wc.window?.title == "\(name) \u{2014} \(name)")
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Model.swift").path, line: nil)
        #expect(wc.window?.title == "\(name) \u{2014} Model.swift")
        // The property-list editor: the title names the file with its extension.
        wc.open(path: plist.path, line: nil)
        #expect(wc.editor.auxiliary != nil && wc.editor.auxiliaryFile?.lastPathComponent == "Data.plist")
        #expect(wc.window?.title == "\(name) \u{2014} Data.plist")
        doc.removeWindowController(wc)
    }

    // MARK: W2 — no Welcome window when launched with a document

    @Test func welcomeGateWaitsForOpensRequestedAtLaunch() {
        // Each step returns whether to show the Welcome window now.
        func run(_ steps: [(inout WelcomeLaunchGate) -> Bool]) -> [Bool] {
            var g = WelcomeLaunchGate()
            return steps.map { $0(&g) }
        }
        let request: (inout WelcomeLaunchGate) -> Bool = { $0.openRequested(); return false }
        func check(_ n: Int) -> (inout WelcomeLaunchGate) -> Bool { { $0.launchCheck(openDocuments: n) } }
        func finish(_ n: Int) -> (inout WelcomeLaunchGate) -> Bool { { $0.openFinished(openDocuments: n) } }
        // Launched by opening a document: the open is in flight at the
        // check; it opens, so no Welcome; later opens never show it.
        #expect(run([request, check(0), finish(1), request, finish(0)]) == [false, false, false, false, false])
        // The open fails: nothing is open in the end, so Welcome shows.
        #expect(run([request, check(0), finish(0)]) == [false, false, true])
        // The open finished before the check.
        #expect(run([request, finish(1), check(1)]) == [false, false, false])
        // Plain launch; a launch with restored windows.
        #expect(run([check(0)]) == [true])
        #expect(run([check(2)]) == [false])
    }

    // MARK: W3 — opening loose files

    @Test func looseFilesOpenAsSingleFilesOrInTheirWorkspace() throws {
        let dir = try r32.package("r38-loose")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = dir.appendingPathComponent("Sources/Chrome/Model.swift")
        let loose = try LaunchWelcomeR31Tests().tempDir("r38-loose-file").appendingPathComponent("Notes.swift")
        try "let note = 1\n\tlet tabbed = 2\n".write(to: loose, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: loose.deletingLastPathComponent()) }

        // Types: containers are workspaces; everything else a single file.
        _ = NSApplication.shared
        let dc = YcodeDocumentController()
        #expect(try dc.typeForContents(of: dir) == WorkspaceDocument.typeName)
        #expect(try dc.typeForContents(of: dir.appendingPathComponent("Package.swift")) == WorkspaceDocument.typeName)
        #expect(try dc.typeForContents(of: URL(fileURLWithPath: "/p/App.xcodeproj")) == WorkspaceDocument.typeName)
        #expect(try dc.typeForContents(of: loose) == SourceFileDocument.typeName)
        #expect(dc.documentClass(forType: SourceFileDocument.typeName) == SourceFileDocument.self)
        #expect(dc.documentClass(forType: WorkspaceDocument.typeName) == WorkspaceDocument.self)

        // A file an open workspace contains goes to that workspace.
        let wc = try r32.window(dir)
        #expect(YcodeDocumentController.workspaceWindow(containing: model, among: [wc]) === wc)
        #expect(YcodeDocumentController.workspaceWindow(containing: loose, among: [wc]) == nil)

        // Otherwise a window of its own with the editor only — no alert.
        let doc = try SourceFileDocument(contentsOf: loose, ofType: SourceFileDocument.typeName)
        doc.makeWindowControllers()
        let fw = try #require(doc.fileWindowController)
        #expect(fw.window?.title == "Notes.swift")
        #expect(fw.editor.fileURL?.path == loose.path && fw.editor.text.hasPrefix("let note"))
        #expect(fw.editor.jumpBarTitles.contains("Notes") && !fw.editor.showsNoDocument)
        #expect(fw.window?.contentViewController === fw.editor)
        // Editing and closing writes the file.
        fw.editor.textView.insertText("// x\n", replacementRange: NSRange(location: 0, length: 0))
        fw.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(try String(contentsOf: loose, encoding: .utf8).hasPrefix("// x\n"))
        doc.close()

        // A binary file fails as a document (not as "URL type isn't supported").
        let bin = loose.deletingLastPathComponent().appendingPathComponent("blob.bin")
        try Data([0xff, 0xfe, 0x00, 0xd8, 0x00]).write(to: bin)
        #expect(throws: CocoaError.self) { _ = try SourceFileDocument(contentsOf: bin, ofType: SourceFileDocument.typeName) }
    }

    // MARK: W4 — the editor at first open

    @Test func firstOpenShowsAnEmptyEditorUnderNoSelection() throws {
        let dir = try r32.package("r38-first")
        defer { try? FileManager.default.removeItem(at: dir) }
        let wc = try r32.window(dir)
        let win = try #require(wc.window)
        win.contentView?.layoutSubtreeIfNeeded()
        let e = wc.editor
        // Related Items and "No Selection"; no Start Page; an empty editor.
        #expect(e.jumpBarTitles == ["Navigate to Related Items", "No Selection"])
        #expect(e.emptyView == nil && e.fileURL == nil && e.showsNoDocument)
        #expect(!e.scrollView.rulersVisible && !e.textView.isEditable)
        // Nothing above the jump bar: it starts at the editor area's top.
        let area = wc.editorArea.view.convert(wc.editorArea.view.bounds, to: nil)
        let bar = e.jumpBar.convert(e.jumpBar.bounds, to: nil)
        #expect(abs(bar.maxY - area.maxY) < 0.5)
        // The gutter no longer draws a gutter-wide cell into the jump bar's
        // row: the bar's top strip is one colour across the gutter's edge.
        e.scrollView.rulersVisible = true   // as when a file is shown
        win.contentView?.layoutSubtreeIfNeeded()
        #expect(e.gutter.clipsToBounds && e.scrollView.clipsToBounds)
        let frame = try #require(win.contentView?.superview)
        let rep = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / frame.bounds.width
        let gutterEdge = e.gutter.convert(e.gutter.bounds, to: nil).maxX
        func pixel(_ x: CGFloat) -> NSColor? {
            // Bitmap rows run top-down; window coordinates bottom-up.
            rep.colorAt(x: Int(x * scale), y: Int((frame.bounds.height - (bar.maxY - 3)) * scale))
        }
        let edge = try #require(pixel(gutterEdge - 0.5)), plain = try #require(pixel(gutterEdge + 12))
        #expect(edge.isClose(to: plain))

        // Opening a file shows the editor; the Start Page still opens in a
        // new tab (Settings ▸ Navigation, pass 5 §9.2).
        wc.open(path: dir.appendingPathComponent("Sources/Chrome/Model.swift").path, line: nil)
        #expect(!e.showsNoDocument && e.scrollView.rulersVisible && e.textView.isEditable)
        wc.newTab(nil)
        #expect(wc.editor.emptyView != nil)
        let tabEmpty = try #require(wc.editor.emptyView)
        wc.window?.contentView?.layoutSubtreeIfNeeded()
        #expect(tabEmpty.frame.maxY <= wc.editor.jumpBar.frame.minY + 0.5)
    }
}

extension NSColor {
    /// Same colour within a small tolerance (device RGB).
    func isClose(to o: NSColor, tolerance: CGFloat = 0.02) -> Bool {
        guard let a = usingColorSpace(.deviceRGB), let b = o.usingColorSpace(.deviceRGB) else { return false }
        return abs(a.redComponent - b.redComponent) <= tolerance && abs(a.greenComponent - b.greenComponent) <= tolerance
            && abs(a.blueComponent - b.blueComponent) <= tolerance
    }
}
