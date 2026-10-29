import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-4.md §14 (toolbar right group, editor options) and §16 (assistant modes).
@MainActor
@Suite(.serialized) struct ReferenceUI4ToolbarAssistantTests {
    @Test func toolbarRightGroupAndOptionsMenu() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/toolbar-right")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"App\", targets: [.executableTarget(name: \"App\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        let ids = wc.toolbarDefaultItemIdentifiers(NSToolbar()).map(\.rawValue)
        // reference-ui-6.md §2.1: no Account item; short labels, long tooltips.
        #expect(!ids.contains("account"))
        let start = try #require(ids.firstIndex(of: "addEditor"))
        #expect(Array(ids[start..<(start + 3)]) == EditorOptionsMenu.rightGroup)
        let opts = try #require(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("editorOptions"), willBeInsertedIntoToolbar: false) as? NSMenuToolbarItem)
        #expect(opts.label == "Editor Options" && opts.toolTip == "Adjust Editor Options")
        #expect(opts.menu.items.map { $0.isSeparatorItem ? "|" : $0.title } == [
            "Layout", "|", "Inline Comparison", "Side By Side Comparison", "|", "Minimap", "Authors", "Code Coverage", "|",
            "Invisibles", "Scope Guides", "Wrap Lines", "|", "Choose Workspace Theme…"])
        #expect(wc.toolbar(NSToolbar(), itemForItemIdentifier: .init("addEditor"), willBeInsertedIntoToolbar: false)?.toolTip == "Add Editor Tabs or Editor Panes")
        // §14.3: no Devices and Simulators in the Window menu.
        let window = try #require(CommandTable.menus.first { $0.0 == "Window" }?.1)
        #expect(!window.contains { if case .command(let c) = $0 { c.title == "Devices and Simulators" } else { false } })
    }

    @Test func catalogOrderAndEnablement() {
        #expect(AssistantModeCatalog.titles.prefix(19) == ["Counterparts", "Superclasses", "Subclasses", "Siblings", "Extensions", "Categories",
            "Protocols", "User Interfaces", "Includes", "Included By", "Callers", "Callees", "Test Classes", "Test Callers",
            "Preprocess", "Assembly", "Disassembly", "Generated Interface", "Documentation Preview"])
        let swift = AssistantModeCatalog.enabled(for: "/p/A.swift", hasLanguageService: true)
        #expect(swift.isSuperset(of: ["Counterparts", "Callers", "Callees", "Generated Interface", "Documentation Preview", "Extensions"]))
        #expect(!swift.contains("Disassembly") && !swift.contains("Superclasses"))
        #expect(!AssistantModeCatalog.enabled(for: "/p/A.swift", hasLanguageService: false).contains("Callers"))
        #expect(AssistantModeCatalog.enabled(for: "/p/a.h", hasLanguageService: false).contains("Included By"))
    }

    @Test func fileModes() {
        let texts = ["/p/a.c": "#include \"a.h\"\n", "/p/a.h": "int a(void);\n", "/p/b.m": "#import \"a.h\"\n",
                     "/p/Model.swift": "struct Model {}\n", "/p/Model+X.swift": "extension Model {\n}\n", "/p/Other.swift": "extension Other {}\n",
                     "/p/Main.storyboard": "<document><objects><viewController customClass=\"Model\"/></objects></document>"]
        let files = Array(texts.keys)
        let read = { (p: String) in texts[p] }
        #expect(AssistantModeCatalog.includedBy("/p/a.h", in: files, readFile: read) == ["/p/a.c", "/p/b.m"])
        #expect(AssistantModeCatalog.extensions(of: "/p/Model.swift", in: files, readFile: read) == ["/p/Model+X.swift"])
        #expect(AssistantModeCatalog.userInterfaces(of: "/p/Model.swift", in: files, readFile: read) == ["/p/Main.storyboard"])
    }

    @Test func generatedInterfaceAndDocumentationPreview() {
        let src = """
        import Foundation

        /// A shape.
        public struct Circle {
            /// The radius.
            public var radius: Double = 1
            private var cache = 0

            /// Area.
            /// - Returns: The area.
            public func area() -> Double {
                let r = radius
                return r * r * .pi
            }
        }
        """
        let i = AssistantModeCatalog.generatedInterface(src)
        #expect(i == """
        import Foundation
        /// A shape.
        public struct Circle {
            /// The radius.
            public var radius: Double
            /// Area.
            /// - Returns: The area.
            public func area() -> Double
        }
        """)
        let d = AssistantModeCatalog.documentationPreview(src)
        #expect(d.contains("Circle\n======\nA shape."))
        #expect(d.contains("Return Value\n  The area."))
    }

    @Test func customModesInWindow() throws {
        _ = NSApplication.shared
        let dir = ycodeDir.appendingPathComponent(".build-ide/assistant-modes")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("Sources/E")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"E\", targets: [.target(name: \"E\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "/// Doc.\npublic struct Model {\n    public func f() {}\n}\n".write(to: src.appendingPathComponent("Model.swift"), atomically: true, encoding: .utf8)
        try "extension Model {\n}\n".write(to: src.appendingPathComponent("Model+More.swift"), atomically: true, encoding: .utf8)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: src.appendingPathComponent("Model.swift").path, line: nil)
        wc.toggleAssistant(nil)
        let a = try #require(wc.editorArea.tab.assistant)
        #expect(a.disabledAssistantModes.contains("Callers"))   // no language service
        wc.setAssistantModeTitle("Extensions")
        #expect(a.fileURL?.lastPathComponent == "Model+More.swift")
        #expect(wc.assistantModeTitle == "Extensions")
        wc.setAssistantModeTitle("Generated Interface")
        #expect(a.textView.string.contains("public func f()") && !a.textView.string.contains("{}\n}"))
        wc.setAssistantModeTitle("Documentation Preview")
        #expect(a.textView.string.hasPrefix("Model"))
        wc.setAssistantModeTitle("Superclasses")
        #expect(a.textView.string == "No Editor")
        wc.setAssistantModeTitle("Counterparts")
        #expect(wc.assistantMode == .counterparts && wc.assistantModeTitle == "Counterparts")
    }
}
