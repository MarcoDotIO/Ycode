import AppKit
import Foundation
import Testing
import YcodeDebug
import YcodeLanguage
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized, .heavyIntegration, .timeLimit(.minutes(10))) struct RefactoringTests {
    @Test func workspaceEditModel() {
        let a = URL(fileURLWithPath: "/tmp/a.swift"), b = URL(fileURLWithPath: "/tmp/b.swift")
        let j: JSON = ["changes": [a.absoluteString: [["range": ["start": ["line": 0, "character": 4], "end": ["line": 0, "character": 5]], "newText": "y"]]],
                       "documentChanges": [["textDocument": ["uri": .string(b.absoluteString), "version": 1],
                                            "edits": [["range": ["start": ["line": 1, "character": 0], "end": ["line": 1, "character": 0]], "newText": "// x\n"]]]]]
        let e = WorkspaceEdit(j)
        #expect(e.files == [a, b] && e.changes[a]?.first?.newText == "y")
        #expect(WorkspaceWindowController.apply(e.changes[a]!, to: "let x = 1\n") == "let y = 1\n")
        #expect(WorkspaceWindowController.apply(e.changes[b]!, to: "a\nb\n") == "a\n// x\nb\n")
    }

    func makePackage() throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/refactor")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("Sources/Geo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"Geo\", targets: [.target(name: \"Geo\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        struct Circle {
            var radius: Double
            func area() -> Double { radius * radius * 3 }
        }

        struct Point {
            var x: Int
            var y: Int
        }

        """.write(to: src.appendingPathComponent("Shapes.swift"), atomically: true, encoding: .utf8)
        try """
        func total() -> Double {
            Circle(radius: 2).area() + Circle(radius: 1).area()
        }

        func report() -> String {
            var label = "total"
            return "\\(label) \\(total())"
        }

        """.write(to: src.appendingPathComponent("Use.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    func caret(_ wc: WorkspaceWindowController, at needle: String) throws {
        let r = (wc.editor.text as NSString).range(of: needle)
        try #require(r.location != NSNotFound)
        wc.editor.textView.setSelectedRange(NSRange(location: r.location + 1, length: 0))
    }

    @Test func lspRefactoringEndToEnd() async throws {
        guard SourceKitLSP.locate() != nil else { return }
        let heavy = await InterprocessLock.acquire(path: InterprocessLock.debuggerTestLockPath)
        defer { heavy.unlock() }
        _ = NSApplication.shared
        let dir = try makePackage()
        // Build once so the index has both files.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["swift", "build", "--package-path", dir.path, "-Xswiftc", "-index-store-path", "-Xswiftc", dir.appendingPathComponent(".build/index-store").path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        let shapes = dir.appendingPathComponent("Sources/Geo/Shapes.swift"), use = dir.appendingPathComponent("Sources/Geo/Use.swift")
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: use.path, line: nil)
        await wc.connectLanguageService(transport: nil)
        #expect(session.language != nil)

        // Fix-its arrive with the diagnostics (var never mutated → let).
        #expect(await waitUntil(120) { session.displayedIssues.contains { !$0.fixIts.isEmpty } })
        let fixLine = try #require(session.displayedIssues.first { !$0.fixIts.isEmpty }?.location?.line)
        #expect(wc.editor.gutter.marks.fixable.contains(fixLine))
        #expect(wc.fixAllIssues(nil) >= 1)
        #expect(wc.editor.text.contains("let label = \"total\""))
        wc.editor.textView.undoManager?.undo()
        #expect(wc.editor.text.contains("var label = \"total\""))

        // References of `area` across both files (wait for the index).
        try caret(wc, at: "area()")
        var refs: [Location] = []
        for _ in 0..<40 {
            refs = await wc.findSelectedSymbolInWorkspace()
            if Set(refs.map(\.url.lastPathComponent)).count == 2 { break }
            try await Task.sleep(for: .seconds(2))
        }
        #expect(Set(refs.map(\.url.lastPathComponent)) == ["Shapes.swift", "Use.swift"] && refs.count == 3)
        #expect(wc.navigator.rows(3).first?.title.hasPrefix("area — 3 references") == true)
        #expect(wc.navigator.selectedIndex == 3)

        // Call hierarchy of `total`: report calls it.
        try caret(wc, at: "total() -> Double")
        let calls = await wc.findCallHierarchy()
        #expect(calls.first?.hasPrefix("total") == true && calls.contains { $0.contains("report") })

        // Rename `area` → `surface`: two files → preview, then apply.
        try caret(wc, at: "area()")
        let name = await wc.beginRename()
        #expect(name == "area")
        #expect(wc.editor.highlightedOccurrences.count == 2)
        let edit = try #require(await wc.rename(to: "surface"))
        #expect(edit.files.map(\.lastPathComponent) == ["Shapes.swift", "Use.swift"] && wc.renamePreview != nil)
        #expect(!wc.editor.text.contains("surface"))
        let changed = wc.applyRenamePreview()
        #expect(changed.count == 2)
        #expect(wc.editor.text.contains("Circle(radius: 2).surface() + Circle(radius: 1).surface()"))
        #expect(try String(contentsOf: shapes, encoding: .utf8).contains("func surface() -> Double"))
        #expect(wc.refactoringBackups[shapes.standardizedFileURL.path]?.contains("func area()") == true)
        // Undo in the open file; the closed file can be reverted.
        wc.editor.textView.undoManager?.undo()
        #expect(wc.editor.text.contains("Circle(radius: 2).area()"))
        wc.revertDiskRefactorings()
        #expect(try String(contentsOf: shapes, encoding: .utf8).contains("func area()"))

        // Code actions on a struct: some refactoring is offered and works.
        wc.open(path: shapes.path, line: nil)
        let expr = (wc.editor.text as NSString).range(of: "radius * radius * 3")
        wc.editor.textView.setSelectedRange(expr)
        #expect((await wc.codeActionsAtCaret()).contains { $0.kind == "refactor.extract" && $0.title.contains("Extract") })
        try caret(wc, at: "Point {")
        let actions = await wc.codeActionsAtCaret()
        #expect(!actions.isEmpty, "no code actions")
        if let memberwise = actions.first(where: { $0.title.lowercased().contains("memberwise") || $0.title.lowercased().contains("initializer") }) {
            let before = wc.editor.text
            await wc.perform(memberwise)
            #expect(await waitUntil(30) { wc.editor.text != before })
            #expect(wc.editor.text.contains("init("))
        }
        print("CODE-ACTIONS", actions.map(\.title))
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "refactor-references.png")
        await session.language?.stop()
    }
}
