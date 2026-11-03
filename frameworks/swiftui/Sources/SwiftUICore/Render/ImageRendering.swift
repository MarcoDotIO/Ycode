import Foundation
import OVRender
import Synchronization

// Images (round R5): symbols drawn from Ycode's own set (OVRender
// SymbolArtwork), raster images (PNG, JPEG) from bundles and asset catalogs,
// and images given as pixels. Sizes follow 07 §3 and 04 §2.

// MARK: - Symbol provider

/// Ycode's symbol provider: metrics derived from each symbol's body-size box
/// (SymbolArtwork), scaled with the font size and weight; `imageScale` is
/// applied by the image leaf. Names outside the set get a visible
/// placeholder of the default size (Ycode's choice, so missing artwork is
/// noticed); with `missingSymbolsLayOutEmpty` they lay out 0 × 0 and draw
/// nothing, as the reference does for unknown names (07 §3).
package struct OpenSymbolProvider: SymbolProvider {
    package static let shared = OpenSymbolProvider()
    package var missingSymbolsLayOutEmpty = false
    package var displayScale: CGFloat = 3
    // Image edges toward neighbours (golden "Default spacing", image rows).
    package var spacingAbove = SpacingPreference(kind: .image, towardStandard: 7.0 / 3, towardText: 0)
    package var spacingBelow = SpacingPreference(kind: .image, towardStandard: 10.0 / 3, towardText: 0)

    package init(missingSymbolsLayOutEmpty: Bool = false) {
        self.missingSymbolsLayOutEmpty = missingSymbolsLayOutEmpty
    }

    package func artwork(named name: String) -> SymbolArtwork? {
        SymbolArtwork.all[name] ?? (missingSymbolsLayOutEmpty ? nil : .placeholder(name: name))
    }

    /// Weight factor on the symbol box: ultraLight 34.33 and black 38.67
    /// against regular 36.33 at `.title` (07 §3), linear in between.
    static func weightFactor(_ w: Font.Weight) -> Double {
        let v = w.value
        return v >= 0 ? 1 + v / 0.62 * (38.67 / 36.33 - 1) : 1 + v / 0.8 * (1 - 34.33 / 36.33)
    }

    package func symbol(named name: String, font: TextFont) -> SymbolMetrics? {
        guard let art = artwork(named: name) else { return nil }
        let k = Double(font.size) / 17 * Self.weightFactor(font.weight)
        let px = Double(displayScale)
        func ceilPx(_ v: Double) -> CGFloat { CGFloat((v * px - 1e-6).rounded(.up) / px) }
        let w = Double(art.bodySize.width) * k, h = Double(art.bodySize.height) * k
        // Natural (resizable) size: the artwork without the box's margins,
        // in the proportions measured for star.fill (18.67 × 18 of 22 × 20.67).
        return SymbolMetrics(size: CGSize(width: ceilPx(w), height: ceilPx(h)),
                             baselineOffset: CGFloat((art.bodyBaselineOffset * k * px).rounded() / px),
                             naturalSize: CGSize(width: ceilPx(w * (56.0 / 66)), height: ceilPx(h * (54.0 / 62))))
    }
}

extension Image.Scale {
    /// Size factors (width, height) relative to `.medium`, from star.fill:
    /// small 17.67 × 16.33, large 28 × 26.67 against 22 × 20.67 (07 §3).
    package var factors: (CGFloat, CGFloat) {
        switch self {
        case .small: return (53.0 / 66, 49.0 / 62)
        case .medium: return (1, 1)
        case .large: return (84.0 / 66, 80.0 / 62)
        }
    }
}

// MARK: - Raster images

/// Where named images come from: images registered in code, then the
/// bundle's resources (`name.png`, `name@2x.png`, …) and asset catalogs
/// (`*.xcassets/name.imageset/Contents.json`, the variant whose scale is
/// closest to the display scale, preferring larger).
package enum ImageAssets {
    package struct Loaded {
        package let image: RenderImage
        package let scale: CGFloat
        package var pointSize: CGSize {
            CGSize(width: CGFloat(image.pixelSize.width) / scale, height: CGFloat(image.pixelSize.height) / scale)
        }
    }

    private static let registry = Mutex<[String: Loaded]>([:])
    private static let cache = Mutex<[String: Loaded?]>([:])

    /// Registers an image under `name` (tests, hosts with their own assets).
    package static func register(name: String, data: Data, scale: CGFloat = 1) {
        if let img = image(from: data) { registry.withLock { $0[name] = Loaded(image: img, scale: scale) } }
    }

    package static func image(from data: Data) -> RenderImage? {
        guard let (format, size) = ImageHeader.inspect(data), !size.isEmpty else { return nil }
        return RenderImage(source: format == .png ? .png(data) : .jpeg(data), pixelSize: size)
    }

    package static func lookup(_ name: String, bundle: Bundle?, displayScale: CGFloat) -> Loaded? {
        if let r = registry.withLock({ $0[name] }) { return r }
        let b = bundle ?? Bundle.main
        let key = "\(b.bundlePath)|\(name)|\(displayScale)"
        if let c = cache.withLock({ $0[key] }) { return c }
        let found = search(name, bundle: b, displayScale: displayScale)
        cache.withLock { $0[key] = .some(found) }
        return found
    }

    private static func load(_ url: URL, scale: CGFloat) -> Loaded? {
        guard let data = try? Data(contentsOf: url), let img = image(from: data) else { return nil }
        return Loaded(image: img, scale: scale)
    }

    private static func search(_ name: String, bundle: Bundle, displayScale: CGFloat) -> Loaded? {
        let fm = FileManager.default
        guard let root = bundle.resourceURL else { return nil }
        // Plain files with optional @2x/@3x variants.
        let scales: [CGFloat] = [3, 2, 1].sorted { abs($0 - displayScale) < abs($1 - displayScale) }
        for s in scales {
            for ext in ["png", "jpg", "jpeg"] {
                let file = s == 1 ? "\(name).\(ext)" : "\(name)@\(Int(s))x.\(ext)"
                let url = root.appendingPathComponent(file)
                if fm.fileExists(atPath: url.path), let l = load(url, scale: s) { return l }
            }
        }
        // Asset catalogs.
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for cat in items where cat.pathExtension == "xcassets" {
            if let l = imageSet(named: name, in: cat, displayScale: displayScale) { return l }
        }
        return nil
    }

    private static func imageSet(named name: String, in dir: URL, displayScale: CGFloat) -> Loaded? {
        let fm = FileManager.default
        let set = dir.appendingPathComponent(name + ".imageset")
        if fm.fileExists(atPath: set.path) {
            guard let data = try? Data(contentsOf: set.appendingPathComponent("Contents.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let images = json["images"] as? [[String: Any]] else { return nil }
            let candidates: [(CGFloat, String)] = images.compactMap { e in
                guard let f = e["filename"] as? String else { return nil }
                let s = (e["scale"] as? String).flatMap { Double($0.replacingOccurrences(of: "x", with: "")) } ?? 1
                return (CGFloat(s), f)
            }
            let ordered = candidates.sorted { a, b in
                let da = a.0 >= displayScale ? a.0 - displayScale : 100 + displayScale - a.0
                let db = b.0 >= displayScale ? b.0 - displayScale : 100 + displayScale - b.0
                return da < db
            }
            for (s, f) in ordered { if let l = load(set.appendingPathComponent(f), scale: s) { return l } }
            return nil
        }
        // Folders (namespaces) inside the catalog.
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for sub in items where sub.pathExtension.isEmpty {
            if let l = imageSet(named: name, in: sub, displayScale: displayScale) { return l }
        }
        return nil
    }
}

// MARK: - Drawing

extension Image {
    /// How an image's pixels are sampled when scaled.
    public enum Interpolation: Hashable, Sendable {
        case none, low, medium, high
    }

    /// Whether an image is drawn as is or as a template filled with the
    /// foreground style.
    public enum TemplateRenderingMode: Hashable, Sendable {
        case template, original
    }

    public func renderingMode(_ mode: TemplateRenderingMode?) -> Image {
        var i = self
        i.renderingModeValue = mode
        return i
    }

    public func interpolation(_ interpolation: Interpolation) -> Image {
        var i = self
        i.interpolationValue = interpolation
        return i
    }

    public func antialiased(_ isAntialiased: Bool) -> Image { self }

    /// The drawing of this image in a node of `size`.
    package func draw(environment: EnvironmentValues, symbols: (any SymbolProvider)?) -> NodeDraw {
        let image = self
        return { rec, size in
            let rect = CGRect(origin: .zero, size: size)
            switch image.source {
            case .system(let name):
                let provider = (rec.symbols as? OpenSymbolProvider) ?? OpenSymbolProvider.shared
                guard let art = provider.artwork(named: name),
                      let paint = environment.foregroundPaint(bounds: rect, level: 0) else { return }
                rec.addUnmirrored(width: size.width, art.contents(in: rect, paint: paint))
            case .named(let name, let bundle):
                guard let l = ImageAssets.lookup(name, bundle: bundle?.bundle, displayScale: environment.displayScale) else { return }
                image.drawRaster(l.image, natural: l.pointSize, size: size, environment: environment, into: &rec)
            case .raster(let img, let scale):
                let natural = CGSize(width: CGFloat(img.pixelSize.width) / scale, height: CGFloat(img.pixelSize.height) / scale)
                image.drawRaster(img, natural: natural, size: size, environment: environment, into: &rec)
            case .natural:
                break
            }
        }
    }

    private func drawRaster(_ img: RenderImage, natural: CGSize, size: CGSize, environment: EnvironmentValues, into rec: inout DrawRecorder) {
        let rect = isResizable ? CGRect(origin: .zero, size: size) : CGRect(origin: .zero, size: natural)
        let interp: RenderInterpolation
        switch interpolationValue ?? .high {
        case .none: interp = .none
        case .low: interp = .low
        case .medium: interp = .medium
        case .high: interp = .high
        }
        if renderingModeValue == .template, let paint = environment.foregroundPaint(bounds: rect, level: 0) {
            let id = rec.nextID()
            let fill = DisplayItem(id: id.child(1), .fill(RenderPath(rect: rect), paint, .nonZero))
            let mask = DisplayList([DisplayItem(id: id.child(2), .image(img, rect: rect, interpolation: interp, opacity: 1))])
            rec.addUnmirrored(width: size.width, [.group(DisplayGroup(mask: mask, children: [fill]))])
        } else {
            rec.addUnmirrored(width: size.width, [.image(img, rect: rect, interpolation: interp, opacity: 1)])
        }
    }
}
