import AppKit
import Foundation
import Testing
@testable import YcodeUI

/// reference-ui-5.md §11.2 (P7) and §7.6 (I6): folders as outline rows,
/// every "+" item creatable, and the attributes inspector as a fourth
/// inspector tab.
@MainActor
@Suite struct AssetCatalogR35Tests {
    func catalog() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-assets-r35-\(UUID().uuidString)/Assets.xcassets")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Brand/Icons/Star.imageset"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Brand/Accent.colorset"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Logo.imageset"), withIntermediateDirectories: true)
        let info = "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
        for p in ["", "Brand", "Brand/Icons", "Brand/Icons/Star.imageset", "Brand/Accent.colorset", "Logo.imageset"] {
            try info.write(to: dir.appendingPathComponent(p).appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func png(to url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    func json(_ u: URL) throws -> String { try String(contentsOf: u.appendingPathComponent("Contents.json"), encoding: .utf8) }

    @Test func foldersAreRowsWithTheirSetsAsChildren() throws {
        let e = AssetCatalogEditorController(url: try catalog())
        _ = e.view
        #expect(e.rows.map { String(repeating: "  ", count: $0.depth) + $0.name } == ["Brand", "  Accent", "  Icons", "    Star", "Logo"])
        #expect(e.rows.map(\.isFolder) == [true, false, true, false, false])
        #expect(e.rows[0].hasChildren && !e.rows[1].hasChildren)
        e.toggleRow(id: "Brand")
        #expect(e.rows.map(\.name) == ["Brand", "Logo"])
        e.toggleRow(id: "Brand")
        // A filter keeps the matches and their folders.
        e.setFilter("star")
        #expect(e.rows.map(\.name) == ["Brand", "Icons", "Star"])
        e.setFilter("")
        // A folder row selects the folder; its inspector edits the namespace.
        #expect(e.selectRow(id: "Brand/Icons"))
        #expect(e.selected == nil && e.selectedFolder?.lastPathComponent == "Icons")
        let ns = try #require(e.inspectorControls["Provides Namespace"] as? NSButton)
        #expect(ns.state == .off)
        try e.setProvidesNamespace(true)
        #expect(try json(e.selectedFolder!).contains("\"provides-namespace\" : true"))
        #expect((e.inspectorControls["Provides Namespace"] as? NSButton)?.state == .on)
        // New items go into the selected folder.
        let set = try e.addSet(kind: 1)
        #expect(set.url.deletingLastPathComponent().lastPathComponent == "Icons" && e.selected?.name == "Color")
        #expect(e.rows.contains { $0.id == "Brand/Icons/Color.colorset" && $0.depth == 2 })
    }

    @Test func everyPlusItemIsCreatable() throws {
        let e = AssetCatalogEditorController(url: try catalog())
        _ = e.view
        func titles(_ entries: [AssetCatalog.AddMenuEntry]) -> [String] {
            entries.flatMap { e -> [String] in
                switch e {
                case .separator: []
                case let .item(t, _): [t]
                case let .submenu(_, c): titles(c)
                }
            }
        }
        let all = titles(AssetCatalog.addMenu())
        #expect(all.count == 25)
        for t in all { #expect(AssetCatalogEditorController.creatable[t] != nil, "\(t)") }
        // Sticker items are enabled only inside a sticker pack.
        #expect(e.addMenuItems["Sticker"]?.isEnabled == false && e.addMenuItems["Image Set"]?.isEnabled == true)
        e.select("Logo")
        let pack = try e.addSet(kind: AssetCatalogEditorController.creatable["Sticker Pack"]!)
        #expect(AssetCatalog.same(e.selected?.url, pack.url) && e.isInsideStickerPack)
        #expect(e.addMenuItems["Sticker"]?.isEnabled == true && e.addMenuItems["Sticker Sequence Frame"]?.isEnabled == true)
        let frame = pack.url.deletingLastPathComponent().appendingPathComponent("frame1.png")
        try png(to: frame)
        e.chooseFiles = { _ in [frame] }
        e.addAsset(tag: AssetCatalogEditorController.creatable["Sticker Sequence Frame"]!)
        let seq = try #require(e.selected)
        #expect(seq.kind == .stickerSequence && seq.url.deletingLastPathComponent().pathExtension == "stickerpack")
        #expect(try json(seq.url).contains("\"filename\" : \"frame1.png\""))
        // Run every other item from the top level.
        e.select("Logo")
        for t in all where !["Sticker", "Sticker Sequence", "Sticker Sequence Frame", "Import…", "Folder from Selection"].contains(t) {
            let before = e.catalog.outline().count
            e.select("Logo")
            e.addAsset(tag: AssetCatalogEditorController.creatable[t]!)
            #expect(e.catalog.outline().count > before, "\(t)")
        }
        // Folder from Selection moves the selected set into a new folder.
        e.select("Logo")
        let folder = try #require(try e.folderFromSelection())
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Logo.imageset").path))
        #expect(e.rows.contains { $0.id == folder.lastPathComponent + "/Logo.imageset" })
    }

    @Test func platformIconContents() throws {
        let url = try catalog()
        let c = AssetCatalog(url: url)
        let watch = try c.addSingleSizeAppIcon(platform: "watchos", named: "AppIcon", in: url)
        #expect(try json(watch.url) == """
        {
          "images" : [
            {
              "idiom" : "universal",
              "platform" : "watchos",
              "size" : "1024x1024"
            }
          ],
          "info" : {
            "author" : "ycode",
            "version" : 1
          }
        }

        """)
        let vision = try c.addVisionOSAppIcon(named: "Vision", in: url)
        #expect(try json(vision.url).contains("\"filename\" : \"Front.solidimagestacklayer\""))
        #expect(try json(vision.url.appendingPathComponent("Back.solidimagestacklayer/Content.imageset")).contains("\"idiom\" : \"vision\""))
        let tv = try c.addTVBrandAssets(named: "App Icon & Top Shelf Image", in: url)
        let tvJSON = try json(tv.url)
        #expect(tvJSON.contains("\"role\" : \"primary-app-icon\"") && tvJSON.contains("\"size\" : \"1920x720\""))
        #expect(FileManager.default.fileExists(atPath: tv.url.appendingPathComponent("App Icon.imagestack/Middle.imagestacklayer/Content.imageset/Contents.json").path))
        let msg = try c.addMessagesIcon(named: "iMessage App Icon", in: url)
        #expect(AssetCatalog.slots(of: msg).count == 12 && AssetCatalog.slots(of: msg).last?.idiom == "ios-marketing")
        // The new containers list their parts as children.
        let ids = c.outline().map(\.id)
        #expect(ids.contains("App Icon & Top Shelf Image.brandassets/App Icon.imagestack/Front.imagestacklayer/Content.imageset"))
    }

    @Test func importMakesImageAndDataSets() throws {
        let url = try catalog()
        let src = url.deletingLastPathComponent()
        try png(to: src.appendingPathComponent("badge.png"))
        try png(to: src.appendingPathComponent("badge@2x.png"))
        try Data("{}".utf8).write(to: src.appendingPathComponent("levels.json"))
        let e = AssetCatalogEditorController(url: url)
        _ = e.view
        e.select("Logo")
        let made = try e.importFiles([src.appendingPathComponent("badge.png"), src.appendingPathComponent("badge@2x.png"),
                                      src.appendingPathComponent("levels.json")])
        #expect(made.map(\.name).sorted() == ["badge", "levels"])
        let badge = try #require(made.first { $0.kind == .imageSet })
        #expect(AssetCatalog.slots(of: badge).map(\.filename) == ["badge.png", "badge@2x.png", nil])
        let data = try #require(made.first { $0.kind == .dataSet })
        #expect(AssetCatalog.slots(of: data).first?.filename == "levels.json")
    }

    @Test func attributesInspectorIsAFourthTab() throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-assets-r35-pkg-\(UUID().uuidString)")
        let src = dir.appendingPathComponent("Sources/Demo")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\")])\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "print(1)\n".write(to: src.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        let assets = src.appendingPathComponent("Assets.xcassets")
        try FileManager.default.copyItem(at: try catalog(), to: assets)
        let wc = WorkspaceWindowController(session: WorkspaceSession(model: try WorkspaceModel(url: dir)), loadDestinations: false, startLanguageService: false)
        wc.applyDefaultLayout()
        wc.open(path: assets.path, line: nil)
        let ae = try #require(wc.assetEditor)
        #expect(wc.inspector.tabNames == CommandTable.inspectors + ["Attributes"])
        #expect(wc.inspector.selectedIndex == CommandTable.inspectors.count)
        // The inspector no longer sits inside the editor.
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        #expect(!all(ae.view).contains { $0.identifier?.rawValue == "inspector" })
        ae.select("Accent")
        let attrs = try #require(ae.attributesView)
        #expect(all(wc.inspector.view).contains { $0 === attrs })
        #expect(all(attrs).contains { ($0 as? NSTextField)?.stringValue == "Color Set" })
        // Leaving the catalog removes the tab.
        wc.open(path: src.appendingPathComponent("main.swift").path, line: nil)
        #expect(wc.assetEditor == nil && wc.inspector.tabNames == CommandTable.inspectors)
    }
}
