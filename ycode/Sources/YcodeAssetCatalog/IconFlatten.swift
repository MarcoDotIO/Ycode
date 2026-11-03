import Foundation
import YcodeIcon

/// The flattened bitmaps of an `.icon` (`icon-compile.md` §5) until the
/// ICON-RENDER round exists: pre-rendered PNGs from a folder, or Ycode's
/// placeholder render (the background fill with the PNG layers drawn flat;
/// SVG layers and the Liquid Glass look are not drawn).
///
/// Folder naming (Ycode's own): `<appearance>[-<platform>][-<pixels>].png`,
/// appearance `default` (also `light`, `any`), `dark` or `tinted`, platform
/// `ios`, `macos` or `watchos`. The most specific file wins and is resized
/// when its size differs. A missing dark image falls back to the default
/// one, a missing tinted image to a grey version of it. An opaque macOS
/// image is taken as the square design and gets the macOS shape; one with
/// transparency is used as the finished icon.
public struct IconBitmapSource: Sendable {
    public var package: IconPackage?
    public var folder: URL?

    public init(package: IconPackage?, folder: URL?) {
        self.package = package
        self.folder = folder
    }

    public struct Missing: Error, CustomStringConvertible {
        public var description: String
    }

    static func aliases(_ a: IconAppearance) -> [String] {
        switch a {
        case .light: ["default", "light", "any"]
        case .dark: ["dark"]
        case .tinted: ["tinted", "tintedlight"]
        }
    }

    func file(_ p: IconPlatform, _ a: IconAppearance, _ px: Int) -> URL? {
        guard let folder else { return nil }
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".png") }
        let lower = Dictionary(names.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let plat = p.rawValue.lowercased()
        for alias in Self.aliases(a) {
            for candidate in ["\(alias)-\(plat)-\(px)", "\(alias)-\(plat)", "\(alias)-\(px)", alias] {
                if let real = lower[candidate + ".png"] { return folder.appendingPathComponent(real) }
            }
        }
        return nil
    }

    /// The flattened icon for a platform and appearance at `pixels` square:
    /// iOS and watchOS an opaque full-bleed square, macOS the finished icon
    /// (rounded rectangle with a shadow, on transparency).
    public func bitmap(_ p: IconPlatform, _ a: IconAppearance, pixels: Int) throws -> Bitmap {
        if folder != nil {
            if let u = file(p, a, pixels) {
                let bmp = try PNG.decode(try Data(contentsOf: u))
                return finish(bmp, p, pixels: pixels)
            }
            if a == .dark, file(p, .light, pixels) != nil { return try bitmap(p, .light, pixels: pixels) }
            if a == .tinted, file(p, .light, pixels) != nil { return IconPlaceholder.tinted(try bitmap(p, .light, pixels: pixels)) }
            if package == nil { throw Missing(description: "no flattened icon image for \(p.rawValue) \(a.rawValue) in \(folder!.lastPathComponent)") }
        }
        guard let package else { throw Missing(description: "no icon document") }
        return IconPlaceholder.render(package, p, a, pixels: pixels)
    }

    func finish(_ bmp: Bitmap, _ p: IconPlatform, pixels: Int) -> Bitmap {
        if p == .macOS, bmp.isOpaque { return IconPlaceholder.macOSShape(bmp, pixels: pixels) }
        let sized = bmp.resized(width: pixels, height: pixels)
        return p == .macOS ? sized : (sized.isOpaque ? sized : sized.flattened(onto: (1, 1, 1)))
    }
}

/// Ycode's placeholder icon render.
public enum IconPlaceholder {
    /// The square design: background, then visible groups and layers bottom
    /// first (PNG artwork only), at `pixels` square.
    public static func square(_ package: IconPackage, _ p: IconPlatform, _ a: IconAppearance, pixels: Int) -> Bitmap {
        let doc = package.document.resolved(a, p)
        let bg = IconBackground(doc.background, appearance: a)
        var px = [UInt8](repeating: 255, count: pixels * pixels * 4)
        for y in 0..<pixels {
            for x in 0..<pixels {
                let c = bg.color(atX: (Double(x) + 0.5) / Double(pixels), y: (Double(y) + 0.5) / Double(pixels))
                let o = (y * pixels + x) * 4
                px[o] = to8(c.r)
                px[o + 1] = to8(c.g)
                px[o + 2] = to8(c.b)
            }
        }
        let k = Double(pixels) / p.canvasSize
        for g in doc.groupsBottomFirst {
            for l in g.visibleLayers.reversed() {
                guard let name = l.imageName, name.lowercased().hasSuffix(".png"),
                      let data = try? Data(contentsOf: package.assetURL(name)), let art = try? PNG.decode(data) else { continue }
                let f = IconGeometry.layerFrame(natural: IconSize(width: Double(art.width), height: Double(art.height)),
                                                layer: l.position, group: g.position, canvas: p.canvasSize)
                let w = Int((f.width * k).rounded()), h = Int((f.height * k).rounded())
                guard w > 0, h > 0 else { continue }
                let scaled = art.resized(width: w, height: h)
                let ox = Int((f.x * k).rounded()), oy = Int((f.y * k).rounded())
                let alpha = l.opacity * g.opacity
                let mode = l.blendMode == .normal ? g.blendMode : l.blendMode
                let fill: IconBackground? = l.fill.keepsArtworkColors ? nil : IconBackground(l.fill, appearance: a)
                for yy in max(0, oy)..<min(pixels, oy + h) {
                    for xx in max(0, ox)..<min(pixels, ox + w) {
                        let s = ((yy - oy) * w + (xx - ox)) * 4
                        var sr = Double(scaled.rgba[s]) / 255, sg = Double(scaled.rgba[s + 1]) / 255, sb = Double(scaled.rgba[s + 2]) / 255
                        if let fill {
                            let c = fill.color(atX: (Double(xx) + 0.5) / Double(pixels), y: (Double(yy) + 0.5) / Double(pixels))
                            (sr, sg, sb) = (c.r, c.g, c.b)
                        }
                        let sa = Double(scaled.rgba[s + 3]) / 255 * alpha
                        guard sa > 0 else { continue }
                        let o = (yy * pixels + xx) * 4
                        let d = (Double(px[o]) / 255, Double(px[o + 1]) / 255, Double(px[o + 2]) / 255)
                        let b = blend(mode, (sr, sg, sb), d)
                        px[o] = to8(d.0 + (b.0 - d.0) * sa)
                        px[o + 1] = to8(d.1 + (b.1 - d.1) * sa)
                        px[o + 2] = to8(d.2 + (b.2 - d.2) * sa)
                    }
                }
            }
        }
        return Bitmap(width: pixels, height: pixels, rgba: px)
    }

    static func to8(_ v: Double) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }

    static func blend(_ m: IconBlendMode, _ s: (Double, Double, Double), _ d: (Double, Double, Double)) -> (Double, Double, Double) {
        func each(_ f: (Double, Double) -> Double) -> (Double, Double, Double) { (f(s.0, d.0), f(s.1, d.1), f(s.2, d.2)) }
        switch m {
        case .multiply: return each { $0 * $1 }
        case .screen: return each { 1 - (1 - $0) * (1 - $1) }
        case .darken: return each { min($0, $1) }
        case .lighten: return each { max($0, $1) }
        case .plusLighter: return each { min(1, $0 + $1) }
        case .plusDarker: return each { max(0, $0 + $1 - 1) }
        case .overlay: return each { s, d in d < 0.5 ? 2 * s * d : 1 - 2 * (1 - s) * (1 - d) }
        case .hardLight: return each { s, d in s < 0.5 ? 2 * s * d : 1 - 2 * (1 - s) * (1 - d) }
        case .softLight: return each { s, d in (1 - 2 * s) * d * d + 2 * s * d }
        case .normal: return s
        }
    }

    /// A grey version (luminance), standing in for the tinted look.
    public static func tinted(_ b: Bitmap) -> Bitmap {
        var out = b.rgba
        for i in stride(from: 0, to: out.count, by: 4) {
            let l = 0.2126 * Double(out[i]) + 0.7152 * Double(out[i + 1]) + 0.0722 * Double(out[i + 2])
            let v = UInt8(min(255, l.rounded()))
            out[i] = v
            out[i + 1] = v
            out[i + 2] = v
        }
        return Bitmap(width: b.width, height: b.height, rgba: out)
    }

    /// The finished macOS icon: the square design in an 824-pt rounded
    /// rectangle at (100, 100) of the 1024-pt canvas, with a soft shadow
    /// below it, on transparency (`icon-compile.md` §5). The corner radius
    /// (22.5 % of the edge) and the shadow are Ycode's approximation.
    public static func macOSShape(_ design: Bitmap, pixels: Int) -> Bitmap {
        let k = Double(pixels) / 1024
        let inner = max(1, Int((824 * k).rounded()))
        let art = design.resized(width: inner, height: inner)
        let x0 = 100 * k, size = 824 * k, r = size * 0.225
        var out = [UInt8](repeating: 0, count: pixels * pixels * 4)
        func distance(_ x: Double, _ y: Double, dy: Double = 0) -> Double {
            let cx = x0 + size / 2, cy = x0 + size / 2 + dy
            let qx = abs(x - cx) - (size / 2 - r), qy = abs(y - cy) - (size / 2 - r)
            return (max(qx, 0) * max(qx, 0) + max(qy, 0) * max(qy, 0)).squareRoot() + min(max(qx, qy), 0) - r
        }
        let blur = max(1, 18 * k), offset = 10 * k
        for y in 0..<pixels {
            for x in 0..<pixels {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let cover = min(max(0.5 - distance(px, py), 0), 1)
                let sd = distance(px, py, dy: offset)
                let shadow = 0.3 * min(max(1 - (sd + blur * 0.25) / blur, 0), 1)
                let o = (y * pixels + x) * 4
                var r8 = 0.0, g8 = 0.0, b8 = 0.0
                if cover > 0 {
                    let ax = min(max(x - Int(x0.rounded()), 0), inner - 1), ay = min(max(y - Int(x0.rounded()), 0), inner - 1)
                    let s = (ay * inner + ax) * 4
                    r8 = Double(art.rgba[s]); g8 = Double(art.rgba[s + 1]); b8 = Double(art.rgba[s + 2])
                }
                // The shape over its shadow (black), straight alpha out.
                let a = cover + shadow * (1 - cover)
                if a > 0 {
                    out[o] = UInt8((r8 * cover / a).rounded())
                    out[o + 1] = UInt8((g8 * cover / a).rounded())
                    out[o + 2] = UInt8((b8 * cover / a).rounded())
                    out[o + 3] = UInt8((a * 255).rounded())
                }
            }
        }
        return Bitmap(width: pixels, height: pixels, rgba: out)
    }

    /// The placeholder for a platform: the design square (watchOS: its
    /// 1088-pt canvas scaled into the square), with the macOS shape on macOS
    /// and a grey version for the tinted appearance.
    public static func render(_ package: IconPackage, _ p: IconPlatform, _ a: IconAppearance, pixels: Int) -> Bitmap {
        let design = p == .macOS ? square(package, .macOS, a, pixels: max(1, Int((824 * Double(pixels) / 1024).rounded())))
            : square(package, p, a, pixels: pixels)
        let looked = a == .tinted ? tinted(design) : design
        return p == .macOS ? macOSShape(looked, pixels: pixels) : looked
    }
}
