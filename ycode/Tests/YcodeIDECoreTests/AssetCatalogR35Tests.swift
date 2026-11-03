import Foundation
import Testing
@testable import YcodeIDECore

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

    func json(_ u: URL) throws -> String { try String(contentsOf: u.appendingPathComponent("Contents.json"), encoding: .utf8) }

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
}
