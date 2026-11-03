import Foundation

/// The sets of an `.xcassets` folder that the compiler reads
/// (`specs/ide/asset-catalog.md`; Apple's public "Asset Catalog Format
/// Reference"): image sets, colour sets and app icon sets. Other set kinds
/// are listed as skipped.
public struct CatalogInput: Sendable {
    public struct ImageEntry: Equatable, Sendable {
        public var file: URL?
        public var idiom: String
        public var scale: Int
        /// `dark`, `light` or nil (any).
        public var appearance: String?
        public var highContrast: Bool
    }

    public struct ImageSet: Equatable, Sendable {
        /// The asset name, with the namespace folders (`Folder/Name`).
        public var name: String
        public var url: URL
        public var entries: [ImageEntry]
        public var templateIntent: String?
    }

    public struct ColorEntry: Equatable, Sendable {
        public var idiom: String
        public var appearance: String?
        public var highContrast: Bool
        public var color: CARColor
    }

    public struct ColorSet: Equatable, Sendable {
        public var name: String
        public var url: URL
        public var entries: [ColorEntry]
    }

    public struct IconEntry: Equatable, Sendable {
        public var file: URL?
        public var idiom: String
        /// Points, e.g. 60 for `60x60`.
        public var size: Double?
        public var scale: Int
        public var platform: String?
        /// `dark`, `tinted` or nil (any).
        public var appearance: String?
    }

    public struct AppIconSet: Equatable, Sendable {
        public var name: String
        public var url: URL
        public var entries: [IconEntry]
    }

    public var url: URL
    public var imageSets: [ImageSet] = []
    public var colorSets: [ColorSet] = []
    public var appIconSets: [AppIconSet] = []
    /// Sets of other kinds, and `.icon` packages placed inside the catalog
    /// (ignored, `icon-compile.md` §2).
    public var skipped: [URL] = []
    /// Every file read (for the dependency list).
    public var inputFiles: [URL] = []

    public init(contentsOf url: URL) {
        self.url = url
        walk(url, namespace: "")
    }

    static func contents(_ dir: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("Contents.json")),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    static func appearance(_ e: [String: Any]) -> (luminosity: String?, highContrast: Bool) {
        let list = e["appearances"] as? [[String: Any]] ?? []
        let lum = list.first { $0["appearance"] as? String == "luminosity" }?["value"] as? String
        let hc = list.contains { $0["appearance"] as? String == "contrast" && $0["value"] as? String == "high" }
        return (lum == "any" ? nil : lum, hc)
    }

    static func scale(_ s: Any?) -> Int {
        guard let s = s as? String, s.hasSuffix("x"), let n = Int(s.dropLast()) else { return 1 }
        return n
    }

    /// Components as floats ("0.200", 0.2) or 8-bit values ("51", "0x33").
    static func component(_ v: Any?) -> Double {
        if let n = v as? NSNumber, !(v is String) {
            let d = n.doubleValue
            return d > 1 && d == d.rounded() ? d / 255 : d
        }
        let s = (v as? String ?? "0").trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x"), let i = Int(s.dropFirst(2), radix: 16) { return Double(i) / 255 }
        if !s.contains("."), let i = Int(s), i > 1 { return Double(i) / 255 }
        return Double(s) ?? 0
    }

    static func color(_ c: [String: Any]) -> CARColor {
        let spaceName = c["color-space"] as? String ?? "srgb"
        let comps = c["components"] as? [String: Any] ?? [:]
        let alpha = comps["alpha"].map { component($0) } ?? 1
        if let white = comps["white"] {
            return CARColor(colorSpace: CARColor.space(named: spaceName) ?? 6, components: [component(white), alpha])
        }
        return CARColor(colorSpace: CARColor.space(named: spaceName) ?? 1,
                        components: [component(comps["red"]), component(comps["green"]), component(comps["blue"]), alpha])
    }

    /// Set kinds phase 1 does not compile (and `.icon`, ignored inside a catalog).
    static let otherSetKinds: Set<String> = [
        "symbolset", "dataset", "textureset", "spriteatlas", "cubetextureset", "arresourcegroup", "arreferenceimage", "arobject",
        "launchimage", "stickerpack", "sticker", "stickersequence", "brandassets", "imagestack", "imagestacklayer",
        "solidimagestack", "solidimagestacklayer", "stickersiconset", "icon", "complicationset", "watchfaceset",
    ]

    mutating func walk(_ dir: URL, namespace: String) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        for n in names {
            let u = dir.appendingPathComponent(n)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let base = u.deletingPathExtension().lastPathComponent
            let name = namespace + base
            let c = Self.contents(u)
            if FileManager.default.fileExists(atPath: u.appendingPathComponent("Contents.json").path) {
                inputFiles.append(u.appendingPathComponent("Contents.json"))
            }
            func file(_ e: [String: Any]) -> URL? {
                guard let f = e["filename"] as? String else { return nil }
                let p = u.appendingPathComponent(f)
                inputFiles.append(p)
                return p
            }
            switch u.pathExtension {
            case "imageset":
                let entries = (c["images"] as? [[String: Any]] ?? []).map { e -> ImageEntry in
                    let a = Self.appearance(e)
                    return ImageEntry(file: file(e), idiom: e["idiom"] as? String ?? "universal", scale: Self.scale(e["scale"]),
                                      appearance: a.luminosity, highContrast: a.highContrast)
                }
                let intent = (c["properties"] as? [String: Any])?["template-rendering-intent"] as? String
                imageSets.append(ImageSet(name: name, url: u, entries: entries, templateIntent: intent))
            case "colorset":
                let entries = (c["colors"] as? [[String: Any]] ?? []).map { e -> ColorEntry in
                    let a = Self.appearance(e)
                    return ColorEntry(idiom: e["idiom"] as? String ?? "universal", appearance: a.luminosity, highContrast: a.highContrast,
                                      color: Self.color(e["color"] as? [String: Any] ?? [:]))
                }
                colorSets.append(ColorSet(name: name, url: u, entries: entries))
            case "appiconset":
                let entries = (c["images"] as? [[String: Any]] ?? []).map { e -> IconEntry in
                    let size = (e["size"] as? String).flatMap { Double($0.split(separator: "x").first ?? "") }
                    return IconEntry(file: file(e), idiom: e["idiom"] as? String ?? "universal", size: size, scale: Self.scale(e["scale"]),
                                     platform: e["platform"] as? String, appearance: Self.appearance(e).luminosity)
                }
                appIconSets.append(AppIconSet(name: base, url: u, entries: entries))
            case let ext where Self.otherSetKinds.contains(ext):
                skipped.append(u)
            default:
                let ns = (c["properties"] as? [String: Any])?["provides-namespace"] as? Bool == true
                walk(u, namespace: ns ? namespace + n + "/" : namespace)
            }
        }
    }
}
