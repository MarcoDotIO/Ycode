import AppKit
import Foundation
import Testing
import YcodeBuild
@testable import YcodeUI

private let worktreeYcode = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct TokenizerTests {
    func kinds(_ text: String, _ lang: SourceTokenizer.Language) -> [(SourceTokenizer.Kind, String)] {
        let ns = text as NSString
        return SourceTokenizer(language: lang).tokens(in: text).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    @Test func swift() {
        let t = kinds("/// Doc\n@MainActor func f() -> Int { let s = \"a\\\"b\" // c\n return 42 } /* x /* y */ z */", .swift)
        #expect(t.map(\.0) == [.docComment, .attribute, .keyword, .typeName, .keyword, .string, .comment, .keyword, .number, .comment])
        #expect(t[5].1 == "\"a\\\"b\"")
        #expect(t.last?.1 == "/* x /* y */ z */") // Swift block comments nest
    }

    @Test func objcAndC() {
        let t = kinds("#import <Foundation/Foundation.h>\n@interface A : NSObject\n- (id)x { return @\"s\"; } 'c'", .objc)
        #expect(t.map(\.0) == [.preprocessor, .keyword, .typeName, .typeName, .keyword, .keyword, .string, .string])
        #expect(SourceTokenizer.Language(fileName: "a.mm") == .objc)
        #expect(SourceTokenizer(language: .plain).tokens(in: "int x").isEmpty)
    }
}

@Suite struct ModelTests {
    @Test func lineIndex() {
        let idx = LineIndex("ab\ncd\n\nx")
        #expect(idx.lineCount == 4)
        #expect(idx.line(at: 0) == 1 && idx.line(at: 3) == 2 && idx.line(at: 6) == 3 && idx.line(at: 7) == 4)
        #expect(idx.range(ofLine: 2) == NSRange(location: 3, length: 2))
        #expect(idx.range(ofLine: 5) == nil)
    }

    @Test func breakpointGutterGestures() {
        var s = BreakpointStore()
        s.click(file: "/a", line: 3)               // add
        #expect(s.breakpoint(file: "/a", line: 3)?.isEnabled == true)
        s.click(file: "/a", line: 3)               // disable
        #expect(s.breakpoint(file: "/a", line: 3)?.isEnabled == false)
        s.click(file: "/a", line: 7)
        s.move(file: "/a", from: 3, to: 5)         // drag along the gutter
        #expect(s.all.map(\.line) == [5, 7])
        #expect(s.effectiveLines == ["/a": [7]])
        s.isActive = false
        #expect(s.effectiveLines == ["/a": []])
        s.remove(file: "/a", line: 7)              // drag out
        s.toggleExistence(file: "/a", line: 5)
        #expect(s.all.isEmpty)
    }

    @Test func commandTableHasNoShortcutConflicts() {
        var seen: [String: String] = [:]
        for c in CommandTable.allCommands where !c.key.isEmpty {
            let key = c.shortcutText
            // performFindPanelAction: shares a selector but differs by key.
            // The same command listed in two menus (View ▸ Editor and Editor) is not a conflict.
            #expect(seen[key] == nil || seen[key] == c.title, "\(key) used by \(seen[key] ?? "") and \(c.title)")
            seen[key] = c.title
        }
        #expect(CommandTable.command(titled: "Build")?.shortcutText == "⌘B")
        #expect(CommandTable.command(titled: "Clean Build Folder…")?.shortcutText == "⇧⌘K")
        #expect(CommandTable.command(titled: "Step Over")?.shortcutText == "F6")
        // reference-ui-5.md §2.0: Show/Hide Inspector has no shortcut; ⌥⌘0 is Show Coding Tools….
        #expect(CommandTable.command(titled: "Show Inspector")?.shortcutText == "")
        #expect(CommandTable.command(titled: "Show Coding Tools…")?.shortcutText == "⌥⌘0")
        #expect(CommandTable.command(titled: "Breakpoints")?.shortcutText == "⌘8")
        #expect(CommandTable.menus.map(\.0) == ["Ycode", "File", "Edit", "View", "Find", "Navigate", "Editor", "Product", "Debug", "Integrate", "Window", "Help"])
    }

    /// CLAUDE.md rule 5: no trademark-shaped symbols (the Swift bird, the
    /// Apple logo, Xcode's hammer) anywhere in Ycode's UI.
    @MainActor @Test func noTrademarkSymbols() throws {
        let forbidden = ["swift", "applelogo", "hammer", "hammer.fill", "xcode", "applewatch", "visionpro", "iphone", "ipad"]
        for p in ["macOS", "iOS", "watchOS", "tvOS", "visionOS"] {
            for k in [Destination.Kind.device, .simulator, .generic] {
                let s = WorkspaceWindowController.symbol(for: Destination(name: "", specifier: "", platform: p, kind: k))
                #expect(!forbidden.contains(s))
            }
        }
        for name in ["main.swift", "Package.swift", "a.m", "x.xcodeproj"] {
            let sym = OutlineItem.symbol(for: NavigatorNode(name: name, kind: .file, path: nil))
            #expect(!forbidden.contains(sym), "\(name) → \(sym)")
        }
        let all = NavigatorAreaController.symbols + InspectorAreaController.symbols + DebugAreaController.barButtons.map(\.0)
        #expect(all.allSatisfy { !forbidden.contains($0) })
        let dir = worktreeYcode.appendingPathComponent("Sources/YcodeUI")
        for case let f as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)! where f.pathExtension == "swift" {
            let text = try String(contentsOf: f, encoding: .utf8)
            for bad in forbidden { #expect(!text.contains("return \"\(bad)\"") && !text.contains("SymbolName: \"\(bad)\""), "\(f.lastPathComponent): \(bad)") }
        }
    }

    @Test func projectNavigatorTree() throws {
        let proj = worktreeYcode.appendingPathComponent("Tests/YcodeProjectTests/Fixtures/Hello.xcodeproj")
        let model = try WorkspaceModel(url: proj)
        #expect(model.kind == .project)
        #expect(model.root.name == "Hello")
        #expect(!model.root.children.isEmpty)
        #expect(model.schemeNames.contains("Hello"))
        let req = model.buildRequest(scheme: "Hello", destination: .myMac, action: .build)
        #expect(XcodebuildEngine.arguments(for: req) == ["-project", proj.path, "-scheme", "Hello", "-destination", "platform=macOS", "build"])
    }
}

/// A build engine that reports fixed issues.
struct FakeEngine: BuildEngine {
    var issues: [Diagnostic]
    var name: String { "fake" }
    func start(_ request: BuildRequest) -> BuildOperation {
        let (s, c) = AsyncStream<BuildEvent>.makeStream()
        for d in issues { c.yield(.issue(d)) }
        c.yield(.finished(BuildResult(status: .failed, exitCode: 65, issues: issues)))
        c.finish()
        return BuildOperation(events: s, cancel: {})
    }
}

@MainActor
@Suite(.serialized) struct WindowSnapshotTests {
    static let out = worktreeYcode.appendingPathComponent(".build-ide/snapshots")

    func samplePackage() throws -> URL {
        let dir = worktreeYcode.appendingPathComponent(".build-ide/Sample")
        let src = dir.appendingPathComponent("Sources/Sample")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Sample\", targets: [.executableTarget(name: \"Sample\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try """
        /// A greeting printer.
        struct Greeter {
            let name: String

            func greet(times: Int) -> String {
                var lines: [String] = []
                for i in 0..<times {
                    lines.append("Hello, \\(name) #\\(i)")
                }
                return lines.joined(separator: "\\n")
            }
        }

        let g = Greeter(name: "Ycode")
        print(g.greet(times: 3))
        print(missing)
        """.write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        return dir
    }

    func render(_ view: NSView, to name: String) throws -> URL {
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: Self.out, withIntermediateDirectories: true)
        let url = Self.out.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test func workspaceWindow() async throws {
        _ = NSApplication.shared
        let dir = try samplePackage()
        let main = dir.appendingPathComponent("Sources/Sample/main.swift").path
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        session.engine = FakeEngine(issues: [
            Diagnostic(severity: .error, message: "cannot find 'missing' in scope", location: .init(file: main, line: 16, column: 7)),
            Diagnostic(severity: .warning, message: "variable 'i' was never mutated", location: .init(file: main, line: 7, column: 13)),
        ])
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        let window = try #require(wc.window)
        window.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        #expect(wc.editor.fileURL?.path == main)
        #expect(wc.editor.pathComponents.map(\.0) == ["Sample", "Sources", "Sample", "main.swift"])

        session.breakpoints.click(file: main, line: 8)
        session.breakpoints.click(file: main, line: 14)
        session.breakpoints.click(file: main, line: 14) // disabled
        let result = await session.build()
        #expect(result.errorCount == 1)
        #expect(wc.activityView.errors == 1 && wc.activityView.warnings == 1)
        #expect(wc.editor.textView.issues.keys.sorted() == [7, 16])
        #expect(wc.editor.gutter.marks.breakpoints == [8: true, 14: false])
        session.appendConsole("Hello, Ycode #0\nHello, Ycode #1\nHello, Ycode #2\nProgram ended with exit code: 0\n")
        wc.showDebugArea(true)
        wc.editor.showsMinimap = true
        let png = try render(window.contentView!.superview ?? window.contentView!, to: "workspace-window.png")
        #expect(FileManager.default.fileExists(atPath: png.path))

        // The issue navigator.
        wc.navigator.select(4)
        _ = try render(window.contentView!.superview ?? window.contentView!, to: "issue-navigator.png")

        // Area toggles (⌘0, ⌥⌘0, ⇧⌘Y).
        wc.toggleNavigator(nil)
        #expect(wc.navigatorItem.isCollapsed)
        wc.toggleDebugArea(nil)
        #expect(wc.debugItem.isCollapsed)

        // ⌘/ comments the current line.
        wc.editor.reveal(line: 14)
        wc.editor.commentSelection(nil)
        #expect(wc.editor.text.contains("// let g = Greeter"))
        wc.editor.commentSelection(nil)
        #expect(!wc.editor.text.contains("// let g"))
    }

    @Test func menuBarMatchesTable() {
        _ = NSApplication.shared
        let bar = MainMenu.make()
        #expect(bar.items.map(\.title) == CommandTable.menus.map(\.0))
        let product = bar.item(withTitle: "Product")!.submenu!
        let build = product.item(withTitle: "Build")!
        #expect(build.keyEquivalent == "b" && build.keyEquivalentModifierMask == .command)
        #expect(build.action == NSSelectorFromString("buildProduct:"))
        #expect(WorkspaceWindowController.instancesRespond(to: build.action!))
    }
}
