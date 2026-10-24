import AppKit
import Foundation
import Testing
@testable import YcodeUI

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@MainActor
@Suite(.serialized) struct AssetCatalogTests {
    func png(_ color: NSColor, size: Int, to url: URL) throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
    }

    @Test func contentsJSONLayout() throws {
        let text = "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n"
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        #expect(String(decoding: try AssetCatalog.json(obj), as: UTF8.self) == text)
        // 8-bit and float components both read as 0…1.
        #expect(AssetCatalog.component("0x33") == 0.2 && AssetCatalog.component("51") == 0.2 && AssetCatalog.component("0.200") == 0.2)
    }

    @Test func editorEditsSets() throws {
        _ = NSApplication.shared
        let dir = try WindowSnapshotTests().samplePackage()
        let catalogURL = dir.appendingPathComponent("Sources/Sample/Assets.xcassets")
        try? FileManager.default.removeItem(at: catalogURL)
        let accent = catalogURL.appendingPathComponent("Brand/Accent.colorset")
        try FileManager.default.createDirectory(at: accent, withIntermediateDirectories: true)
        try "{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".write(to: catalogURL.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        try """
        {"colors":[{"color":{"color-space":"srgb","components":{"alpha":"1.000","blue":"0xCC","green":"0x66","red":"0x33"}},"idiom":"universal"}],"info":{"author":"xcode","version":1}}
        """.write(to: accent.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let wc = WorkspaceWindowController(session: session, loadDestinations: false, startLanguageService: false)
        wc.window?.appearance = NSAppearance(named: .aqua)
        wc.applyDefaultLayout()
        wc.open(path: catalogURL.path, line: nil)
        let ae = try #require(wc.assetEditor)
        #expect(ae.sets.map { "\($0.group)/\($0.name)" } == ["Brand/Accent"])
        let c = try #require(AssetCatalog.colors(of: ae.sets[0]).first)
        #expect(abs(c.red - 0.2) < 0.001 && abs(c.blue - 0.8) < 0.001 && c.space == .sRGB)

        // Color edit in Display P3.
        try ae.setColor(.init(space: .displayP3, red: 1, green: 0.5, blue: 0, alpha: 1), at: 0)
        let json = try String(contentsOf: accent.appendingPathComponent("Contents.json"), encoding: .utf8)
        #expect(json.contains("\"color-space\" : \"display-p3\"") && json.contains("\"green\" : \"0.500\""))

        // A new image set gets three slots; images go into slots.
        let set = try ae.addSet(kind: 0, name: "Logo")
        #expect(AssetCatalog.slots(of: set).map(\.title) == ["1x", "2x", "3x"])
        let src = ycodeDir.appendingPathComponent(".build-ide/logo@2x.png")
        try png(.systemOrange, size: 64, to: src)
        try ae.setImage(src, slot: 1)
        #expect(AssetCatalog.slots(of: set)[1].filename == "logo@2x.png")
        #expect(FileManager.default.fileExists(atPath: set.url.appendingPathComponent("logo@2x.png").path))
        ae.addDark()
        #expect(AssetCatalog.slots(of: set).map(\.title) == ["1x", "2x", "3x", "1x Dark", "2x Dark", "3x Dark"])
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "asset-catalog-imageset.png")
        try ae.clearImage(slot: 1)
        #expect(AssetCatalog.slots(of: set)[1].filename == nil && !FileManager.default.fileExists(atPath: set.url.appendingPathComponent("logo@2x.png").path))

        // A macOS app icon has ten slots.
        let icon = try ae.addSet(kind: 2)
        #expect(AssetCatalog.slots(of: icon).count == 10 && AssetCatalog.slots(of: icon).first?.title == "16x16pt 1x")
        ae.select("Accent")
        _ = try WindowSnapshotTests().render(wc.window!.contentView!.superview!, to: "asset-catalog-colorset.png")
    }
}
