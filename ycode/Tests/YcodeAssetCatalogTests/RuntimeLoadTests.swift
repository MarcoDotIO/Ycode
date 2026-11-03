#if os(macOS)
import AppKit
import Foundation
import Testing
@testable import YcodeAssetCatalog

/// The done-criterion of CAR-WRITER phase 1 on macOS: cars that Ycode wrote
/// load through public AppKit API only — `Bundle.image(forResource:)` (the
/// bundle form of `NSImage(named:)`), `NSColor(named:bundle:)`, and
/// `NSWorkspace.icon(forFile:)` for an app bundle whose icon is in the car.
@MainActor
struct RuntimeLoadTests {
    /// Draws an image into a `size` × `size` sRGB bitmap (top-left origin
    /// for `p`) under `appearance` (aqua when nil) and returns RGBA 0–255.
    func sample(_ image: NSImage, at p: (Int, Int), size: Int = 64, appearance: NSAppearance? = nil) -> [Int] {
        var px = [UInt8](repeating: 0, count: size * size * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            (appearance ?? NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
                image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard ok else { return [] }
        let o = (p.1 * size + p.0) * 4
        let a = Int(px[o + 3])
        // Un-premultiply.
        return (0..<3).map { a == 0 ? 0 : min(255, (Int(px[o + $0]) * 255 + a / 2) / a) } + [a]
    }

    func close(_ a: [Int], _ b: [Int], _ tolerance: Int = 6) -> Bool { a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= tolerance } }

    func resourceBundle(_ dir: URL, compression: CARCompression) throws -> Bundle {
        let cat = try Fixture.catalog(in: dir)
        let bundle = dir.appendingPathComponent("Assets-\(compression.rawValue).bundle")
        let res = bundle.appendingPathComponent("Contents/Resources")
        let r = Fixture.compile([cat], platform: "macosx", out: res) { $0.compression = compression }
        #expect(r.succeeded, "\(r.diagnostics)")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.ycode.test.assets.\(UUID().uuidString)", "CFBundlePackageType": "BNDL",
                                                             "CFBundleName": "Assets"], format: .xml, options: 0)
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return try #require(Bundle(url: bundle))
    }

    @Test(arguments: CARCompression.allCases)
    func imagesLoadFromABundle(_ compression: CARCompression) throws {
        let dir = try Fixture.tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try resourceBundle(dir, compression: compression)
        let logo = try #require(bundle.image(forResource: "Logo"))
        #expect(logo.size == NSSize(width: 10, height: 10))
        #expect(Set(logo.representations.map(\.pixelsWide)).isSuperset(of: [10, 20]))
        #expect(close(sample(logo, at: (32, 32)), [255, 0, 0, 255]))
        // The dark variant draws under the dark appearance.
        #expect(close(sample(logo, at: (32, 32), appearance: NSAppearance(named: .darkAqua)), [0, 0, 255, 255]))
        let star = try #require(bundle.image(forResource: "Shapes/Star"))
        #expect(star.size == NSSize(width: 4, height: 4))
        let s = sample(star, at: (32, 32))
        #expect(close(s, [255, 255, 0, 128], 8), "\(s)")
    }

    /// Large images: every pixel of a 1024 × 1024 image (a gradient with
    /// noise, and a flat colour) comes back exactly. CoreUI stopped decoding
    /// a single 1.4 MB LZVN block after 782,336 bytes; `LZFSE.blockSize`
    /// keeps blocks small.
    @Test(arguments: CARCompression.allCases)
    func largeImagesDecodeCompletely(_ compression: CARCompression) throws {
        let dir = try Fixture.tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        var seed: UInt32 = 7
        var noisy = [UInt8](repeating: 255, count: 1024 * 1024 * 4)
        for i in stride(from: 0, to: noisy.count, by: 4) {
            seed = seed &* 1_103_515_245 &+ 12_345
            let p = i / 4
            noisy[i] = UInt8(p % 1024 / 4)
            noisy[i + 1] = UInt8(p / 1024 / 4)
            noisy[i + 2] = UInt8(truncatingIfNeeded: seed >> 16) & 0x1F
        }
        let images = [("Noisy", Bitmap(width: 1024, height: 1024, rgba: noisy)), ("Flat", Bitmap(width: 1024, height: 1024, fill: (0.05, 0.55, 0.6, 1)))]
        var w = CARWriter(platform: .macOS, deploymentTarget: "27.0", compression: compression)
        for (name, b) in images { w.add(CARRendition(name: name, attributes: [.scale: 1], renditionName: name, content: .image(b), flags: 16)) }
        let res = dir.appendingPathComponent("Big.bundle/Contents/Resources")
        try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
        try w.data().write(to: res.appendingPathComponent("Assets.car"))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.ycode.test.big.\(UUID().uuidString)"], format: .xml, options: 0)
            .write(to: res.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: dir.appendingPathComponent("Big.bundle")))
        for (name, b) in images {
            let img = try #require(bundle.image(forResource: name))
            var r = NSRect(x: 0, y: 0, width: 1024, height: 1024)
            let cg = try #require(img.cgImage(forProposedRect: &r, context: nil, hints: nil))
            #expect(cg.width == 1024 && cg.height == 1024)
            var px = [UInt8](repeating: 0, count: 1024 * 1024 * 4)
            px.withUnsafeMutableBytes { buf in
                let ctx = CGContext(data: buf.baseAddress, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 4096,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
            }
            let differing = stride(from: 0, to: px.count, by: 4).filter { px[$0] != b.rgba[$0] || px[$0 + 1] != b.rgba[$0 + 1] || px[$0 + 2] != b.rgba[$0 + 2] }.count
            #expect(differing == 0, "\(name) \(compression): \(differing) pixels differ")
        }
    }

    /// CELM versions 2 and 3 draw as opaque, 0 and 1 keep alpha: Ycode writes
    /// 1 for every bitmap but the opaque iOS-family app icons.
    @Test func celmVersionDecidesWhetherAlphaIsUsed() throws {
        let dir = try Fixture.tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        var seen: [UInt8: [Int]] = [:]
        for version: UInt8 in [1, 3] {
            var w = CARWriter(platform: .macOS, deploymentTarget: "27.0", compression: .none)
            w.add(CARRendition(name: "Half", attributes: [.scale: 1], renditionName: "half.png", content: .image(Bitmap(width: 8, height: 8, fill: (1, 0, 0, 0.5))), flags: 16))
            var data = [UInt8](try w.data())
            let bom = try BOMReader(Data(data))
            for e in try bom.leaves("RENDITIONS")[0].entries {
                let off = Int(bom.table[Int(e.value)].offset)
                guard data.u16le(at: off + 36) == 12 else { continue }
                #expect(data.u32le(at: off + 184 + Int(data.u32le(at: off + 168)) + 4) == 1)
                data[off + 184 + Int(data.u32le(at: off + 168)) + 4] = version
            }
            let res = dir.appendingPathComponent("V\(version).bundle/Contents/Resources")
            try FileManager.default.createDirectory(at: res, withIntermediateDirectories: true)
            try Data(data).write(to: res.appendingPathComponent("Assets.car"))
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "dev.ycode.test.celm.\(UUID().uuidString)"], format: .xml, options: 0)
                .write(to: res.deletingLastPathComponent().appendingPathComponent("Info.plist"))
            let bundle = try #require(Bundle(url: dir.appendingPathComponent("V\(version).bundle")))
            seen[version] = sample(try #require(bundle.image(forResource: "Half")), at: (32, 32))
        }
        #expect(close(seen[1] ?? [], [255, 0, 0, 128]))
        #expect(close(seen[3] ?? [], [128, 0, 0, 255]))
    }

    @Test func colorsLoadFromABundle() throws {
        let dir = try Fixture.tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = try resourceBundle(dir, compression: .lzfse)
        let brand = try #require(NSColor(named: "Brand", bundle: bundle))
        var light: NSColor?, dark: NSColor?
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = brand.usingColorSpace(.sRGB) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = brand.usingColorSpace(.sRGB) }
        #expect(light.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } == [1, 0, 0])
        #expect(dark.map { [$0.redComponent, $0.greenComponent, $0.blueComponent] } == [0, 0, 1])
        let accent = try #require(NSColor(named: "AccentColor", bundle: bundle))
        let p3 = try #require(accent.usingColorSpace(.displayP3))
        #expect(abs(p3.redComponent - 0.2) < 0.002 && abs(p3.greenComponent - 0.5) < 0.002 && abs(p3.blueComponent - 0.25) < 0.002)
    }

    /// `Test.app` with an `Info.plist` naming the icon and the compiled files.
    func app(_ dir: URL, inputs: [URL], icns: Bool) throws -> URL {
        let app = dir.appendingPathComponent("IconTest-\(UUID().uuidString.prefix(8)).app")
        let res = app.appendingPathComponent("Contents/Resources")
        let r = Fixture.compile(inputs, platform: "macosx", out: res) { $0.accentColor = nil }
        #expect(r.succeeded, "\(r.diagnostics)")
        var info: [String: Any] = ["CFBundleIdentifier": "dev.ycode.test.icon.\(UUID().uuidString)", "CFBundlePackageType": "APPL",
                                   "CFBundleName": "IconTest", "CFBundleExecutable": "IconTest"]
        let partial = (NSDictionary(contentsOf: res.appendingPathComponent("partial.plist")) as? [String: Any]) ?? [:]
        info.merge(partial) { _, b in b }
        if !icns {
            info["CFBundleIconFile"] = nil
            try FileManager.default.removeItem(at: res.appendingPathComponent("AppIcon.icns"))
        }
        try FileManager.default.removeItem(at: res.appendingPathComponent("partial.plist"))
        try FileManager.default.removeItem(at: res.appendingPathComponent("deps"))
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        // Launch Services shows the generic icon for a bundle without its executable.
        let exe = app.appendingPathComponent("Contents/MacOS/IconTest")
        try Data("#!/bin/sh\n".utf8).write(to: exe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    @Test(arguments: [true, false])
    func appIconFromAnIconSetShowsThroughWorkspace(_ icns: Bool) throws {
        let dir = try Fixture.tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try app(dir, inputs: [try Fixture.catalog(in: dir)], icns: icns)
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        // The set's green fills the 1024 canvas; the generic app icon is not green.
        let c = sample(icon, at: (32, 32), size: 64)
        #expect(close(c, [0, 204, 51, 255], 10), "\(c) (icns \(icns))")
    }

    @Test(arguments: [true, false])
    func appIconFromADotIconShowsThroughWorkspace(_ icns: Bool) throws {
        let dir = try Fixture.tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = try app(dir, inputs: [try Fixture.icon(in: dir)], icns: icns)
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        // Inside the rounded rectangle, left of the white layer: the fill colour.
        let c = sample(icon, at: (10, 32), size: 64)
        #expect(close(c, [230, 51, 26, 255], 12), "\(c) (icns \(icns))")
        // Outside it, the corner is transparent.
        #expect(sample(icon, at: (1, 62), size: 64).last ?? 255 < 40)
    }
}
#endif
