import Foundation
@testable import YcodeAssetCatalog
import YcodeIcon

/// Our own sample catalogs and icons, written into a temporary folder.
enum Fixture {
    static func tempDir(_ tag: String = "car") throws -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func writePNG(_ url: URL, _ w: Int, _ h: Int, _ c: (r: Double, g: Double, b: Double, a: Double)) throws {
        try PNG.encode(Bitmap(width: w, height: h, fill: c)).write(to: url)
    }

    static func json(_ o: Any, to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("Contents.json"))
    }

    static let red = (r: 1.0, g: 0.0, b: 0.0, a: 1.0)
    static let blue = (r: 0.0, g: 0.0, b: 1.0, a: 1.0)
    static let green = (r: 0.0, g: 0.8, b: 0.2, a: 1.0)
    static var info: [String: Any] { ["author": "ycode", "version": 1] }

    /// `Assets.xcassets` with an image set (1x, 2x, dark 2x), a colour set
    /// (any, dark), `AccentColor`, a namespaced folder, an iOS single-size
    /// app icon, a macOS app icon and a watchOS app icon.
    static func catalog(in dir: URL) throws -> URL {
        let cat = dir.appendingPathComponent("Assets.xcassets")
        try json(["info": info], to: cat)
        let logo = cat.appendingPathComponent("Logo.imageset")
        try json(["images": [
            ["idiom": "universal", "scale": "1x", "filename": "logo.png"],
            ["idiom": "universal", "scale": "2x", "filename": "logo@2x.png"],
            ["idiom": "universal", "scale": "3x"],
            ["idiom": "universal", "scale": "2x", "filename": "logo-dark@2x.png", "appearances": [["appearance": "luminosity", "value": "dark"]]],
        ], "info": info], to: logo)
        try writePNG(logo.appendingPathComponent("logo.png"), 10, 10, red)
        try writePNG(logo.appendingPathComponent("logo@2x.png"), 20, 20, red)
        try writePNG(logo.appendingPathComponent("logo-dark@2x.png"), 20, 20, blue)
        try json(["colors": [
            ["idiom": "universal", "color": ["color-space": "srgb", "components": ["red": "1.000", "green": "0.000", "blue": "0.000", "alpha": "1.000"]]],
            ["idiom": "universal", "appearances": [["appearance": "luminosity", "value": "dark"]],
             "color": ["color-space": "srgb", "components": ["red": "0", "green": "0", "blue": "255", "alpha": "1.000"]]],
        ], "info": info], to: cat.appendingPathComponent("Brand.colorset"))
        try json(["colors": [["idiom": "universal", "color": ["color-space": "display-p3", "components": ["red": "0x33", "green": "0.5", "blue": "0.25", "alpha": "1"]]]],
                  "info": info], to: cat.appendingPathComponent("AccentColor.colorset"))
        let folder = cat.appendingPathComponent("Shapes")
        try json(["info": info, "properties": ["provides-namespace": true]], to: folder)
        let star = folder.appendingPathComponent("Star.imageset")
        try json(["images": [["idiom": "universal", "scale": "1x", "filename": "star.png"]], "info": info], to: star)
        try writePNG(star.appendingPathComponent("star.png"), 4, 4, (1, 1, 0, 0.5))
        let icon = cat.appendingPathComponent("AppIcon.appiconset")
        try json(["images": [
            ["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "icon.png"],
            ["idiom": "universal", "platform": "ios", "size": "1024x1024", "appearances": [["appearance": "luminosity", "value": "dark"]]],
            ["idiom": "universal", "platform": "watchos", "size": "1024x1024", "filename": "icon.png"],
        ] + [16, 32, 128, 256, 512].flatMap { s in ["1x", "2x"].map { sc -> [String: Any] in
            ["idiom": "mac", "size": "\(s)x\(s)", "scale": sc, "filename": "mac\(s)\(sc).png"] } },
                  "info": info], to: icon)
        try writePNG(icon.appendingPathComponent("icon.png"), 1024, 1024, green)
        for s in [16, 32, 128, 256, 512] {
            for (sc, k) in [("1x", 1), ("2x", 2)] { try writePNG(icon.appendingPathComponent("mac\(s)\(sc).png"), s * k, s * k, green) }
        }
        return cat
    }

    /// An `.icon` with a solid fill (and a dark fill), one group with a PNG layer.
    static func icon(in dir: URL, name: String = "AppIcon") throws -> URL {
        let assets = dir.appendingPathComponent("icon-src")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try writePNG(assets.appendingPathComponent("dot.png"), 256, 256, (1, 1, 1, 1))
        var doc = IconDocument(fill: .solid(.srgb(0.9, 0.2, 0.1)), groups: [IconGroup(name: "Front", layers: [IconLayer(name: "dot", imageName: "dot.png")])],
                               supportedPlatforms: .multiplatform)
        doc.fill.specializations = [IconSpecialization(value: .solid(.srgb(0.9, 0.2, 0.1))),
                                    IconSpecialization(appearance: .dark, value: .solid(.srgb(0.1, 0.1, 0.4)))]
        doc.fill.value = nil
        let pkg = IconPackage(url: dir.appendingPathComponent("\(name).icon"), document: doc)
        try pkg.write(copyingAssetsFrom: assets)
        return pkg.url
    }

    static func compile(_ inputs: [URL], platform: String, out: URL, appIcon: String? = "AppIcon", devices: [String] = [],
                        configure: (inout AssetCompiler.Options) -> Void = { _ in }) -> AssetCompiler.Result {
        var o = AssetCompiler.Options(outputDirectory: out)
        o.inputs = inputs
        o.platformName = platform
        o.appIcon = appIcon
        o.targetDevices = devices
        o.accentColor = "AccentColor"
        o.minimumDeploymentTarget = "27.0"
        o.partialInfoPlist = out.appendingPathComponent("partial.plist")
        o.dependencyInfo = out.appendingPathComponent("deps")
        configure(&o)
        return AssetCompiler(options: o).compile()
    }
}
