import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore

private let worktreeYcode = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct TokenizerTests {
    func kinds(_ text: String, _ lang: SourceTokenizer.Language) -> [(SourceTokenizer.Kind, String)] {
        let ns = text as NSString
        return SourceTokenizer(language: lang).tokens(in: text).map { ($0.kind, ns.substring(with: $0.range)) }
    }

    @Test func swift() {
        let t = kinds("/// Doc\n@MainActor func f() -> Int { let s = \"a\\\"b\" // c\n return 42 } /* x /* y */ z */", .swift)
        #expect(t.map(\.0) == [.docComment, .attribute, .keyword, .otherDeclaration, .typeName, .keyword, .otherDeclaration, .string, .comment,
                                .keyword, .number, .comment])
        #expect(t[3].1 == "f" && t[6].1 == "s")
        #expect(t[7].1 == "\"a\\\"b\"")
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
