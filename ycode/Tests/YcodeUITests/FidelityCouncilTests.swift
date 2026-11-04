import AppKit
import Foundation
import Testing
@testable import YcodeIDECore
@testable import YcodeUI
import YcodeSyntax

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The council's round-1 checklist (`specs/ide/fidelity-council.md` rows
/// 2–9, 11, 12, 19, 20, 22–24, 27, 28): open routing, the navigator's
/// order and geometry, the editor's metrics, the minimap rule, the
/// inspector slide and the File inspector.
@MainActor
@Suite(.serialized) struct FidelityCouncilTests {
    /// A project with one synchronized root folder, like the council's
    /// GlassScroll: Models/ (two files), ContentView, Long, Stripes.png.
    func project(_ name: String, editorConfig: String? = nil) throws -> URL {
        let dir = ycodeDir.appendingPathComponent(".build-ide/fc-\(name)")
        try? FileManager.default.removeItem(at: dir)
        let src = dir.appendingPathComponent("GlassScroll")
        try FileManager.default.createDirectory(at: src.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("GlassScroll.xcodeproj"), withIntermediateDirectories: true)
        try Self.pbxproj.write(to: dir.appendingPathComponent("GlassScroll.xcodeproj/project.pbxproj"), atomically: true, encoding: .utf8)
        try "import SwiftUI\n".write(to: src.appendingPathComponent("ContentView.swift"), atomically: true, encoding: .utf8)
        var long = "import Foundation\n\n"
        for i in 0..<20 {
            long += "// Section \(i): a comment block that is long enough to wrap in a narrow editor width so that the wrapped-line indentation shows.\n"
            long += "struct Section\(i) {\n    let value: Int = \(i)\n    func describe() -> String {\n        return \"\\(value)\"\n    }\n}\n\n"
        }
        try long.write(to: src.appendingPathComponent("Long.swift"), atomically: true, encoding: .utf8)
        for m in ["Model01", "Model02"] { try "struct \(m) {}\n".write(to: src.appendingPathComponent("Models/\(m).swift"), atomically: true, encoding: .utf8) }
        let png = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try png.representation(using: .png, properties: [:])!.write(to: src.appendingPathComponent("Stripes.png"))
        if let editorConfig { try editorConfig.write(to: dir.appendingPathComponent(".editorconfig"), atomically: true, encoding: .utf8) }
        return dir
    }

    func window(_ dir: URL) throws -> WorkspaceWindowController {
        _ = NSApplication.shared
        let model = try WorkspaceModel(url: dir.appendingPathComponent("GlassScroll.xcodeproj"))
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: model), loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        return wc
    }

    // MARK: Row 2 / #71: open routing

    @Test func openRequestsRouteToTheirWorkspace() throws {
        let dir = try project("route")
        let wc = try window(dir)
        let root = wc.session.model.root
        let src = dir.appendingPathComponent("GlassScroll")
        #expect(root.containsForOpening(src.appendingPathComponent("Long.swift")))
        #expect(root.containsForOpening(src.appendingPathComponent("Stripes.png")))
        // A file added to the synchronized folder since it was listed.
        #expect(root.containsForOpening(src.appendingPathComponent("Models/New.swift")))
        #expect(!root.containsForOpening(dir.deletingLastPathComponent().appendingPathComponent("elsewhere.swift")))
        #expect(YcodeDocumentController.workspaceWindow(containing: src.appendingPathComponent("Long.swift"), among: [wc]) === wc)
        // The same file named two ways is one request.
        #expect(OpenRequestKey.path(src.appendingPathComponent("Models/../Long.swift")) == OpenRequestKey.path(src.appendingPathComponent("Long.swift")))
    }

    @Test func openingAFileSelectsItsRowJumpBarAndInspector() throws {
        let dir = try project("select")
        let wc = try window(dir)
        let long = dir.appendingPathComponent("GlassScroll/Long.swift").path
        wc.open(path: long, line: nil)
        #expect(wc.navigator.selectedPath.map { OpenRequestKey.path(URL(fileURLWithPath: $0)) } == OpenRequestKey.path(URL(fileURLWithPath: long)))
        #expect(wc.editor.jumpBarTitles.contains("Long"))
        let stripes = dir.appendingPathComponent("GlassScroll/Stripes.png").path
        wc.open(path: stripes, line: nil)
        // Image: the viewer, the row, the jump bar and the image's inspector, in one pass.
        #expect(wc.imageViewer?.url.path == stripes)
        #expect(wc.navigator.selectedPath.map { OpenRequestKey.path(URL(fileURLWithPath: $0)) } == OpenRequestKey.path(URL(fileURLWithPath: stripes)))
        #expect(wc.editor.jumpBarTitles.contains("Stripes"))
        #expect(wc.inspector.sectionTitles.contains("Image Properties") && wc.inspector.sectionTitles.contains("Localization"))
        #expect(!wc.inspector.sectionTitles.contains("Text Settings"))
    }

    // MARK: Row 3: image viewer

    @Test func imageFitsAndCentres() {
        let box = NSRect(x: 20, y: 20, width: 810, height: 678)
        let r = ImageViewerLayout.fittedRect(imageSize: NSSize(width: 800, height: 1800), in: box)
        #expect(abs(r.height - 678) < 0.01 && abs(r.midX - box.midX) < 0.01 && abs(r.minY - 20) < 0.01)
        // Small images are not scaled up.
        let small = ImageViewerLayout.fittedRect(imageSize: NSSize(width: 40, height: 30), in: box)
        #expect(small.size == NSSize(width: 40, height: 30) && abs(small.midY - box.midY) < 0.01)
        #expect(ImageViewerLayout.topMargin == 20 && ImageViewerLayout.bottomMargin == 60 && ImageViewerLayout.buttonHeight == 20)
        #expect(ImageViewerController.handles(URL(fileURLWithPath: "/a/Stripes.png")))
        #expect(!ImageViewerController.handles(URL(fileURLWithPath: "/a/Long.swift")))
    }

    // MARK: Rows 11, 19, 20: navigator

    @Test func synchronizedFoldersListFoldersFirst() throws {
        let dir = try project("order")
        let wc = try window(dir)
        let folder = wc.session.model.root.children.first { $0.name == "GlassScroll" }
        #expect(folder?.children.map(\.name) == ["Models", "ContentView.swift", "Long.swift", "Stripes.png"])
        #expect(NavigatorAreaController.indentation == 14)
        #expect(wc.navigator.outlineView.indentationPerLevel == 14)
        #expect(WorkspaceChrome.iconTint(kind: .file, name: "Long.swift") == .orange)
        #expect(WorkspaceChrome.iconTint(kind: .folder, name: "Models") == .lightBlue)
        #expect(WorkspaceChrome.iconTint(kind: .file, name: "Stripes.png") == .blue)
        #expect(WorkspaceChrome.iconTint(kind: .container, name: "GlassScroll") == .blue)
    }

    // MARK: Rows 4, 21, 27: editor metrics

    @Test func editorTextMetrics() throws {
        #expect(EditorMetrics.lineHeight(fontSize: 13) == 18)
        #expect(EditorMetrics.advance(fontAdvance: 7.8) == 8)
        #expect(EditorMetrics.wrappedIndent(of: "    let x", tabWidth: 4) == 8)
        #expect(EditorMetrics.wrappedIndent(of: "\tlet x", tabWidth: 4) == 8)
        #expect(EditorMetrics.wrappedIndent(of: " // c", tabWidth: 4) == 5)
        let dir = try project("metrics")
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let e = wc.editor
        e.view.layoutSubtreeIfNeeded()
        #expect(abs(Theme.advance - 8) < 0.01)
        #expect(Theme.lineHeight == 18)
        // The code column at the editor's edge + 51; numbers end at + 38.
        let codeX = e.textView.convert(NSPoint(x: e.textView.textContainerOrigin.x, y: 0), to: e.view).x
        #expect(abs(codeX - 51) < 0.5)
        #expect(e.gutter.lineNumberEnd == 38)
        #expect(e.textView.textContainerOrigin.y == 7)
    }

    // MARK: Row 8: minimap

    @Test func minimapWidthRule() {
        #expect(EditorMetrics.minimapWidth(editorWidth: 850) == 127)
        #expect(EditorMetrics.minimapWidth(editorWidth: 962) == 128)
        #expect(EditorMetrics.minimapWidth(editorWidth: 480) == 72)
        #expect(MinimapView.width(forEditorWidth: 850) == 128)   // with its 1-point separator
        #expect(EditorMetrics.minimapOffset(contentHeight: 900, viewHeight: 700, fraction: 0.5) == 100)
        #expect(EditorMetrics.minimapOffset(contentHeight: 300, viewHeight: 700, fraction: 0.5) == 0)
        let storage = NSAttributedString(string: "let a = 1\n\tlet b\n", attributes: [.foregroundColor: NSColor.black])
        let rows = MinimapView.rows(of: storage, columns: 80, tabWidth: 4, wraps: true)
        #expect(rows.count == 3)
        #expect(rows[0].map(\.column) == [0, 4, 6, 8] && rows[1].first?.column == 4)
    }

    @Test func minimapSitsLeftOfTheScrollBarLane() throws {
        let dir = try project("minimap")
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let e = wc.editor
        e.view.layoutSubtreeIfNeeded()
        guard e.showsMinimap else { return }
        #expect(abs(e.minimap.frame.maxX - (e.view.bounds.maxX - e.scrollerLaneWidth)) < 0.5)
        #expect(e.minimapWidthValue == MinimapView.width(forEditorWidth: e.view.bounds.width))
    }

    // MARK: Row 9: inspector slide

    @Test func inspectorSlideParameters() {
        #expect(abs(EditorMetrics.inspectorSlideDuration - 0.215) <= 0.011)
        #expect(EditorMetrics.inspectorSlideProgress(0) == 0 && EditorMetrics.inspectorSlideProgress(1) == 1)
        // Slow start, settles over the last 15 %.
        #expect(EditorMetrics.inspectorSlideProgress(0.2) < 0.2)
        #expect(EditorMetrics.inspectorSlideProgress(0.85) > 0.9)
        var last = 0.0
        for i in 0...20 {
            let p = EditorMetrics.inspectorSlideProgress(Double(i) / 20)
            #expect(p >= last - 1e-9)
            last = p
        }
        // The measured points, exactly.
        for (ms, progress) in EditorMetrics.inspectorSlideTable {
            #expect(abs(EditorMetrics.inspectorSlideProgress(ms / (EditorMetrics.inspectorSlideDuration * 1000)) - progress) < 1e-9)
        }
        // The Bézier fit stays near the table.
        for i in 0...10 {
            let t = Double(i) / 10
            #expect(abs(EditorMetrics.inspectorSlideBezierProgress(t) - EditorMetrics.inspectorSlideProgress(t)) < 0.13)
        }
    }

    // MARK: Rows 22–24, 28: File inspector

    @Test func editorConfigIndentationDisablesTextSettings() throws {
        let dir = try project("editorconfig", editorConfig: "root = true\n\n[*]\nindent_style = space\nindent_size = 4\ncharset = utf-8\n")
        let file = dir.appendingPathComponent("GlassScroll/Long.swift")
        let c = EditorConfig.settings(for: file)
        #expect(c.indentStyle == .space && c.indentSize == 4 && c.tabWidth == 4 && c.providesIndentation)
        #expect(EditorConfig.matches("*.{swift,m}", "a/b.swift") && !EditorConfig.matches("*.md", "b.swift"))
        let wc = try window(dir)
        wc.open(path: file.path, line: nil)
        let insp = wc.inspector
        insp.select(0)
        #expect((insp.fileControls["Indent Using"] as? NSControl)?.isEnabled == false)
        #expect((insp.fileControls["Tab"] as? NSControl)?.isEnabled == false)
        #expect((insp.fileControls["Text Encoding"] as? NSControl)?.isEnabled == true)
        #expect((insp.fileControls["EditorConfig Note"] as? NSTextField)?.stringValue == EditorConfig.indentationNote)
        #expect((insp.fileControls["Location"] as? NSPopUpButton)?.titleOfSelectedItem == "Relative to Group")
    }

    @Test func noEditorConfigLeavesTextSettingsEnabled() throws {
        let c = EditorConfig.settings(for: URL(fileURLWithPath: "/nowhere/x.swift")) { _ in nil }
        #expect(!c.providesIndentation)
        let nested = EditorConfig.settings(for: URL(fileURLWithPath: "/r/a/x.swift")) { path in
            switch path {
            case "/r/a/.editorconfig": "[*.swift]\nindent_style = tab\n"
            case "/r/.editorconfig": "root = true\n[*]\nindent_size = 2\n"
            default: nil
            }
        }
        #expect(nested.indentStyle == .tab && nested.indentSize == 2)
        #expect(InspectorStyle.breakable("a/b-c") == "a/\u{200B}b-\u{200B}c")
    }

    // MARK: Row 5: the text shows under the bars' veil and is not covered

    /// The text draws in the editor (nothing opaque over it: views do not
    /// clip to their bounds, so a fill must stay inside its own view), and
    /// the scroll view runs up under the jump bar and the toolbar.
    @Test func editorTextIsVisibleAndRunsUnderTheBars() throws {
        let dir = try project("visible")
        let wc = try window(dir)
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        let e = wc.editor
        wc.window?.layoutIfNeeded()
        #expect(e.gutter.visibleLines().count > 10)
        #expect(e.scrollView.frame.maxY == e.view.bounds.maxY || e.scrollView.frame.minY == 0)
        #expect(e.scrollView.contentInsets.top == e.view.safeAreaInsets.top + JumpBar.height)
        guard let rep = e.view.bitmapImageRepForCachingDisplay(in: e.view.bounds) else { return }
        e.view.cacheDisplay(in: e.view.bounds, to: rep)
        // Dark pixels in the text column, below the bars.
        var dark = 0
        let top = Int(e.scrollView.contentInsets.top * rep.size.height / max(1, e.view.bounds.height)) + 10
        for x in stride(from: 60, to: min(500, rep.pixelsWide), by: 2) {
            for y in stride(from: top, to: rep.pixelsHigh - 60, by: 2) where (rep.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.6 { dark += 1 }
        }
        #expect(dark > 200)
        // The bars' veil: a black glyph pixel changes by at most about 8 levels.
        #expect((1 - EditorVeil.fill.alphaComponent) * 230 <= 8.5)
    }

    // MARK: Row 10: the default light theme

    func withPreferences(_ body: (Preferences) throws -> Void) rethrows {
        let t = TestDefaults("fc")
        let old = Preferences.shared
        let p = Preferences(defaults: t.defaults, themesDirectory: ycodeDir.appendingPathComponent(".build-ide/fc-themes"))
        Preferences.shared = p
        defer { Preferences.shared = old; t.remove() }
        try body(p)
    }

    func hex(_ c: NSColor, dark: Bool = false) -> String {
        var out = ""
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { out = EditorTheme.hex(c) }
        return out
    }

    @Test func defaultLightThemeUsesTheMeasuredColours() throws {
        try withPreferences { p in
            #expect(p.theme.name == "Ycode Default")
            #expect(hex(Theme.color(for: .keyword)) == "#C4246E")
            #expect(hex(Theme.color(for: .string)) == "#CA2B1C")
            #expect(hex(Theme.color(for: .comment)) == "#6A7084")
            #expect(hex(Theme.color(for: .number)) == "#0178B8")
            #expect(hex(Theme.color(for: .typeName)) == "#9D31CF")
            #expect(hex(Theme.textColor) == "#322529")
            #expect(hex(Theme.lineNumberColor) == "#B8B3B4")
            // The dark appearance keeps the system colours.
            #expect(hex(Theme.color(for: .keyword), dark: true) == hex(NSColor.systemPink, dark: true))
            // The same colour each time (attributes compare equal).
            #expect(Theme.color(for: .keyword) === Theme.color(for: .keyword))
            // Declaration names.
            let storage = NSTextStorage(string: "struct Section00 {\n    let value00: Int = 0\n}\n")
            let doc = SyntaxDocument(text: storage.string, language: .swift)
            Theme.apply(doc, to: storage)
            let ns = storage.string as NSString
            let typeDecl = storage.attribute(.foregroundColor, at: ns.range(of: "Section00").location, effectiveRange: nil) as? NSColor
            let otherDecl = storage.attribute(.foregroundColor, at: ns.range(of: "value00").location, effectiveRange: nil) as? NSColor
            #expect(typeDecl.map { hex($0) } == "#007D9E")
            #expect(otherDecl.map { hex($0) } == "#006178")
        }
    }

    // MARK: Selection by any route opens the file; the inspector scrolls

    @Test func selectingARowWithoutAClickOpensItsFile() throws {
        let dir = try project("axselect")
        let wc = try window(dir)
        let o = wc.navigator.outlineView
        let before = wc.editor.fileURL
        wc.navigator.selectProjectRows { $0.path?.hasSuffix("Long.swift") == true }
        // The window's own selection (selectProjectRows) opens nothing.
        #expect(wc.editor.fileURL == before, "opened \(wc.editor.fileURL?.path ?? "nothing")")
        let row = (0..<o.numberOfRows).first { (o.item(atRow: $0) as? OutlineItem)?.path?.hasSuffix("ContentView.swift") == true }
        let r = try #require(row)
        o.selectRowIndexes([r], byExtendingSelection: false)   // as the keyboard or AXSelectedRows does
        #expect(wc.editor.fileURL?.lastPathComponent == "ContentView.swift")
    }

    @Test func inspectorContentsScroll() throws {
        let dir = try project("inspscroll", editorConfig: "root = true\n[*]\nindent_size = 2\n")
        let wc = try window(dir)
        wc.window?.setContentSize(NSSize(width: 1200, height: 420))
        wc.open(path: dir.appendingPathComponent("GlassScroll/Long.swift").path, line: nil)
        wc.window?.layoutIfNeeded()
        let scroll = wc.inspector.contentScroll
        let doc = try #require(scroll.documentView)
        #expect(doc.frame.height > scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        #expect(scroll.contentView.bounds.minY == 100)
    }

    @Test func editorConfigFollowsSymbolicLinks() throws {
        let dir = try project("symlink", editorConfig: "root = true\n[*]\nindent_style = tab\n")
        let link = ycodeDir.appendingPathComponent(".build-ide/fc-symlink-link")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent("GlassScroll"))
        #expect(EditorConfig.settings(for: link.appendingPathComponent("Long.swift")).indentStyle == .tab)
    }

    static let pbxproj = """
    // !$*UTF8*$!
    {
    \tarchiveVersion = 1;
    \tclasses = {
    \t};
    \tobjectVersion = 77;
    \tobjects = {
    \t\t0B0000000000000000000001 /* GlassScroll.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = GlassScroll.app; sourceTree = BUILT_PRODUCTS_DIR; };
    \t\t0D0000000000000000000010 /* GlassScroll */ = {isa = PBXFileSystemSynchronizedRootGroup; path = GlassScroll; sourceTree = "<group>"; };
    \t\t0D0000000000000000000001 = {isa = PBXGroup; children = (0D0000000000000000000010 /* GlassScroll */, 0D0000000000000000000003 /* Products */, ); sourceTree = "<group>"; };
    \t\t0D0000000000000000000003 /* Products */ = {isa = PBXGroup; children = (0B0000000000000000000001 /* GlassScroll.app */, ); name = Products; sourceTree = "<group>"; };
    \t\t0E0000000000000000000001 /* GlassScroll */ = {isa = PBXNativeTarget; buildConfigurationList = 0F0000000000000000000011; buildPhases = (); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (0D0000000000000000000010 /* GlassScroll */, ); name = GlassScroll; productName = GlassScroll; productReference = 0B0000000000000000000001 /* GlassScroll.app */; productType = "com.apple.product-type.application"; };
    \t\t0A0000000000000000000001 /* Project object */ = {isa = PBXProject; buildConfigurationList = 0F0000000000000000000001; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base, ); mainGroup = 0D0000000000000000000001; productRefGroup = 0D0000000000000000000003 /* Products */; projectDirPath = ""; projectRoot = ""; targets = (0E0000000000000000000001 /* GlassScroll */, ); };
    \t\t0F0000000000000000000002 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; }; name = Debug; };
    \t\t0F0000000000000000000012 /* Debug */ = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
    \t\t0F0000000000000000000001 = {isa = XCConfigurationList; buildConfigurations = (0F0000000000000000000002 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    \t\t0F0000000000000000000011 = {isa = XCConfigurationList; buildConfigurations = (0F0000000000000000000012 /* Debug */, ); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug; };
    \t};
    \trootObject = 0A0000000000000000000001 /* Project object */;
    }

    """
}
