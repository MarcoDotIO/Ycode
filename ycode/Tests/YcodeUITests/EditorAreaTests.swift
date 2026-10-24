import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct EditorAreaTests {
    @Test func historyModel() {
        var h = NavigationHistory()
        h.visit("a"); h.visit("b"); h.visit("b"); h.visit("c")
        #expect(h.items == ["a", "b", "c"])
        #expect(h.back() == "b" && h.back() == "a" && h.back() == nil)
        #expect(h.forward() == "b")
        h.visit("d")
        #expect(h.items == ["a", "b", "d"] && !h.canGoForward)
    }

    @Test func counterpartRules() {
        let files = ["/p/A/Foo.h", "/p/A/Foo.m", "/p/B/Foo.c", "/p/App/View.swift", "/p/Tests/ViewTests.swift",
                     "/p/App/Main.storyboard", "/p/App/Other.swift"]
        let docs = ["/p/App/Main.storyboard": "<viewController customClass=\"View\" id=\"a\"/>"]
        let read = { (p: String) in docs[p] }
        #expect(Counterparts.of("/p/A/Foo.h", in: files, readFile: read) == ["/p/A/Foo.m", "/p/B/Foo.c"])
        #expect(Counterparts.of("/p/A/Foo.m", in: files, readFile: read) == ["/p/A/Foo.h"])
        #expect(Counterparts.of("/p/App/View.swift", in: files, readFile: read) == ["/p/Tests/ViewTests.swift", "/p/App/Main.storyboard"])
        #expect(Counterparts.of("/p/Tests/ViewTests.swift", in: files, readFile: read) == ["/p/App/View.swift"])
        #expect(Counterparts.of("/p/App/Main.storyboard", in: files, readFile: read) == ["/p/App/View.swift"])
        #expect(Counterparts.of("/p/App/Other.swift", in: files, readFile: read).isEmpty)
    }

    @Test func assistantModeRules() {
        let files = ["/p/a.c", "/p/a.h", "/p/util.h", "/p/Model.swift", "/p/ModelTests.swift", "/p/OtherTests.swift", "/p/Main.storyboard", "/p/VC.swift"]
        let texts = ["/p/a.c": "#include \"a.h\"\n#include \"util.h\"\n#include <stdio.h>\n",
                     "/p/Model.swift": "import Foundation\nstruct Thing {}\n",
                     "/p/OtherTests.swift": "let t = Thing()\n", "/p/ModelTests.swift": "// none\n",
                     "/p/Main.storyboard": "<document><scenes><scene sceneID=\"s\"><objects><viewController id=\"v\" customClass=\"VC\"/></objects></scene></scenes></document>"]
        let read = { (p: String) in texts[p] }
        #expect(AssistantMode.available(for: "/p/a.c") == [.counterparts, .manual, .includes, .tests])
        #expect(AssistantMode.available(for: "/p/Main.storyboard") == [.counterparts, .manual, .topLevelObjects])
        #expect(AssistantMode.includes.files(for: "/p/a.c", in: files, readFile: read) == ["/p/a.h", "/p/util.h"])
        #expect(AssistantMode.tests.files(for: "/p/Model.swift", in: files, readFile: read) == ["/p/ModelTests.swift", "/p/OtherTests.swift"])
        #expect(AssistantMode.topLevelObjects.files(for: "/p/Main.storyboard", in: files, readFile: read) == ["/p/VC.swift"])
        #expect(AssistantMode.manual.files(for: "/p/a.c", in: files, readFile: read).isEmpty)
    }

    @Test func assistantModesInWindow() throws {
        let (wc, src) = try makeWorkspace()
        try "#include \"c.h\"\nint d(void);\n".write(to: src.appendingPathComponent("d.c"), atomically: true, encoding: .utf8)
        wc.session.model.root = NavigatorTree.package(at: src.deletingLastPathComponent().deletingLastPathComponent())
        wc.open(path: src.appendingPathComponent("d.c").path, line: nil)
        wc.toggleAssistant(nil)
        let a = try #require(wc.editorArea.tab.assistant)
        #expect(a.assistantModeTitles == AssistantModeCatalog.titles)
        #expect(!a.disabledAssistantModes.contains("Includes") && a.disabledAssistantModes.contains("Disassembly"))
        #expect(a.fileURL == nil) // no counterpart for d.c
        wc.setAssistantMode(.includes)
        #expect(a.fileURL?.lastPathComponent == "c.h" && a.counterpartTitles == ["c.h"])
        wc.setAssistantMode(.manual)
        wc.open(path: src.appendingPathComponent("A.swift").path, line: nil)
        #expect(a.fileURL?.lastPathComponent == "c.h") // manual: unchanged
        wc.setAssistantMode(.counterparts)
        #expect(a.fileURL?.lastPathComponent == "ATests.swift")
    }

    func makeWorkspace() throws -> (WorkspaceWindowController, URL) {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/editor-area")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("Sources/E")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"E\", targets: [.target(name: \"E\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        for (n, t) in [("A.swift", "let a = 1\n"), ("B.swift", "let b = 2\n"), ("ATests.swift", "// tests of A\n"), ("c.h", "int c(void);\n"), ("c.c", "int c(void) { return 0; }\n")] {
            try t.write(to: src.appendingPathComponent(n), atomically: true, encoding: .utf8)
        }
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return (wc, src)
    }

    @Test func tabsSplitsAndHistory() throws {
        let (wc, src) = try makeWorkspace()
        let a = src.appendingPathComponent("A.swift").path, b = src.appendingPathComponent("B.swift").path
        wc.open(path: a, line: nil)
        wc.open(path: b, line: nil)
        let first = wc.editor
        wc.goBack(nil)
        #expect(first.fileURL?.path == a)
        wc.goForward(nil)
        #expect(first.fileURL?.path == b)

        // ⌘T: a new tab showing the Start Page (Settings ▸ Navigation ▸ New
        // Editor Tabs Open With, reference-ui-5.md §9.2); ⇧⌘[ / ⇧⌘] switch.
        wc.newTab(nil)
        #expect(wc.editorArea.tabs.count == 2 && wc.editor !== first && wc.editor.fileURL == nil && wc.editor.emptyView != nil)
        wc.open(path: a, line: nil)
        #expect(wc.editorArea.tabTitles == ["B", "A"])
        wc.selectPreviousTab(nil)
        #expect(wc.editor === first)
        wc.selectNextTab(nil)
        #expect(wc.editor.fileURL?.path == a)
        wc.closeTab(nil)
        #expect(wc.editorArea.tabs.count == 1 && wc.editor === first)

        // ⌃⌘T split side by side; each split has its own history.
        wc.splitEditor(nil)
        let right = wc.editor
        #expect(wc.editorArea.tab.editors.count == 2 && wc.editorArea.tab.sideBySide && right.fileURL?.path == b)
        wc.open(path: a, line: nil)
        #expect(right.fileURL?.path == a && first.fileURL?.path == b)
        wc.goBack(nil)
        #expect(right.fileURL?.path == b)
        #expect(first.history.items == [a, b])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "editor-split.png")
        wc.closeEditor(nil)
        #expect(wc.editorArea.tab.editors.count == 1)
        wc.splitEditorBelow(nil)
        #expect(!wc.editorArea.tab.sideBySide)
        wc.closeEditor(nil)
    }

    @Test func assistantFollowsCounterparts() throws {
        let (wc, src) = try makeWorkspace()
        wc.open(path: src.appendingPathComponent("A.swift").path, line: nil)
        #expect(wc.editor.counterpartTitles == ["ATests.swift"])
        wc.toggleAssistant(nil)
        let assistant = try #require(wc.editorArea.tab.assistant)
        #expect(assistant.fileURL?.lastPathComponent == "ATests.swift")
        wc.open(path: src.appendingPathComponent("c.h").path, line: nil)
        #expect(assistant.fileURL?.lastPathComponent == "c.c")
        #expect(wc.editor.counterpartTitles == ["c.c"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "editor-assistant.png")
        wc.toggleAssistant(nil)
        #expect(wc.editorArea.tab.assistant == nil && wc.editorArea.tab.editors.count == 1)
    }
}
