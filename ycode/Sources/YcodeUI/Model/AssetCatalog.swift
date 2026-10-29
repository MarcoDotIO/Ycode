import Foundation

/// An asset catalog folder (`.xcassets`) and its sets, read and written as
/// `Contents.json` files. See `specs/ide/asset-catalog.md`.
public struct AssetCatalog {
    public enum Kind: String, Sendable, CaseIterable {
        case imageSet = "imageset", colorSet = "colorset", appIconSet = "appiconset"
        case symbolSet = "symbolset", dataSet = "dataset"
        case textureSet = "textureset", spriteAtlas = "spriteatlas", cubeTextureSet = "cubetextureset"
        case arResourceGroup = "arresourcegroup", arReferenceImage = "arreferenceimage", arReferenceObject = "arobject"
        case launchImage = "launchimage", stickerPack = "stickerpack", sticker = "sticker", stickerSequence = "stickersequence"
        case brandAssets = "brandassets", imageStack = "imagestack", imageStackLayer = "imagestacklayer"
        case solidImageStack = "solidimagestack", solidImageStackLayer = "solidimagestacklayer", stickersIconSet = "stickersiconset"

        /// The Contents.json array whose entries are file slots, nil for
        /// sets without file slots.
        public var slotKey: String? {
            switch self {
            case .imageSet, .appIconSet, .arReferenceImage, .launchImage, .stickersIconSet: "images"
            case .symbolSet: "symbols"
            case .dataSet: "data"
            case .arReferenceObject: "objects"
            default: nil
            }
        }

        /// Sets that hold other sets (their children are listed too).
        public var isContainer: Bool {
            [.spriteAtlas, .arResourceGroup, .stickerPack, .brandAssets, .imageStack, .imageStackLayer, .solidImageStack, .solidImageStackLayer].contains(self)
        }
    }

    public struct AssetSet: Equatable, Sendable {
        public var name: String
        public var kind: Kind
        public var url: URL
        /// Folder path inside the catalog ("" at the top level).
        public var group: String
    }

    /// The `.xcassets` folder.
    public let url: URL
    /// Wraps the catalog at `url`; nothing is read until asked.
    public init(url: URL) { self.url = url }

    /// All sets, depth-first in name order; plain folders are groups.
    public func sets() -> [AssetSet] {
        func walk(_ dir: URL, _ group: String) -> [AssetSet] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            return names.flatMap { n -> [AssetSet] in
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return [] }
                if let k = Kind(rawValue: u.pathExtension) {
                    let name = u.deletingPathExtension().lastPathComponent
                    let me = AssetSet(name: name, kind: k, url: u, group: group)
                    return k.isContainer ? [me] + walk(u, group.isEmpty ? name : group + "/" + name) : [me]
                }
                return walk(u, group.isEmpty ? n : group + "/" + n)
            }
        }
        return walk(url, "")
    }

    // MARK: Contents.json

    /// The parsed `Contents.json` of folder `dir`; empty when missing or not
    /// a JSON object.
    public static func readContents(_ dir: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("Contents.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Two-space indentation, `"key" : value`, keys sorted, newline at end.
    public static func json(_ obj: [String: Any]) throws -> Data {
        var d = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        d.append(0x0A)
        return d
    }

    static func writeContents(_ obj: [String: Any], to dir: URL) throws {
        try json(obj).write(to: dir.appendingPathComponent("Contents.json"), options: .atomic)
    }

    static var info: [String: Any] { ["author": "ycode", "version": 1] }

    // MARK: Image sets

    /// One image slot: scale and appearance (nil = any).
    public struct Slot: Equatable, Sendable, Hashable {
        public var idiom: String
        public var scale: String?
        public var size: String?
        public var appearance: String?
        public var filename: String?
        /// App icon platform ("ios", "watchos", …) for single-size icons.
        public var platform: String?

        /// The label drawn inside an empty slot: "1024x1024px" for a
        /// single-size app icon, nil otherwise.
        public var boxLabel: String? {
            guard platform != nil, let size, scale == nil else { return nil }
            return size + "px"
        }

        /// Caption lines under the slot (reference-ui-3 §3): a single-size
        /// icon shows the platform and "1,024pt"; other slots show the
        /// idiom ("Universal") then size/scale/appearance.
        public var captions: [String] {
            if let platform, scale == nil, let size {
                let w = Int(size.split(separator: "x").first ?? "") ?? 0
                let f = NumberFormatter()
                f.numberStyle = .decimal
                f.locale = Locale(identifier: "en_US")
                return [AssetCatalog.platformName(platform), (f.string(from: NSNumber(value: w)) ?? "\(w)") + "pt"]
            }
            return [AssetCatalog.idiomName(idiom), title].filter { !$0.isEmpty }
        }

        public var title: String {
            [size.map { "\($0)pt" }, scale, appearance.map { $0.capitalized }].compactMap { $0 }.joined(separator: " ")
        }
    }

    static func slot(_ d: [String: Any]) -> Slot {
        let appearance = (d["appearances"] as? [[String: String]])?.first { $0["appearance"] == "luminosity" }?["value"]
        return Slot(idiom: d["idiom"] as? String ?? "universal", scale: d["scale"] as? String, size: d["size"] as? String,
                    appearance: appearance, filename: d["filename"] as? String, platform: d["platform"] as? String)
    }

    static func entry(_ s: Slot) -> [String: Any] {
        var d: [String: Any] = ["idiom": s.idiom]
        if let x = s.scale { d["scale"] = x }
        if let x = s.size { d["size"] = x }
        if let x = s.filename { d["filename"] = x }
        if let x = s.platform { d["platform"] = x }
        if let a = s.appearance { d["appearances"] = [["appearance": "luminosity", "value": a]] }
        return d
    }

    /// The image (or icon) slots of a set, in file order; empty for kinds
    /// without slots.
    public static func slots(of set: AssetSet) -> [Slot] {
        guard let key = set.kind.slotKey else { return [] }
        return (readContents(set.url)[key] as? [[String: Any]] ?? []).map(slot)
    }

    /// Creates `<name>.imageset` with universal 1x, 2x and 3x slots.
    @discardableResult
    public func addImageSet(named name: String, in group: String = "") throws -> AssetSet {
        let dir = url.appendingPathComponent(group).appendingPathComponent("\(name).imageset")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let images = ["1x", "2x", "3x"].map { Self.entry(Slot(idiom: "universal", scale: $0)) }
        try Self.writeContents(["images": images, "info": Self.info], to: dir)
        return AssetSet(name: name, kind: .imageSet, url: dir, group: group)
    }

    /// Copies an image file into the set and puts it in the slot with this
    /// index (replacing what was there).
    public static func setImage(_ file: URL, slot index: Int, in set: AssetSet) throws {
        var obj = readContents(set.url)
        let key = set.kind.slotKey ?? "images"
        var images = obj[key] as? [[String: Any]] ?? []
        guard images.indices.contains(index) else { return }
        let name = file.lastPathComponent
        let dest = set.url.appendingPathComponent(name)
        if dest.standardizedFileURL != file.standardizedFileURL {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
        }
        if let old = images[index]["filename"] as? String, old != name,
           !images.enumerated().contains(where: { $0.offset != index && $0.element["filename"] as? String == old }) {
            try? FileManager.default.removeItem(at: set.url.appendingPathComponent(old))
        }
        images[index]["filename"] = name
        obj[key] = images
        try writeContents(obj, to: set.url)
    }

    /// Empties a slot and deletes its file from the set folder.
    public static func clearImage(slot index: Int, in set: AssetSet) throws {
        var obj = readContents(set.url)
        let key = set.kind.slotKey ?? "images"
        var images = obj[key] as? [[String: Any]] ?? []
        guard images.indices.contains(index), let old = images[index]["filename"] as? String else { return }
        images[index]["filename"] = nil
        obj[key] = images
        try writeContents(obj, to: set.url)
        try? FileManager.default.removeItem(at: set.url.appendingPathComponent(old))
    }

    /// Adds Dark-appearance slots for each scale (Appearances: Any, Dark).
    public static func addDarkAppearance(to set: AssetSet) throws {
        var obj = readContents(set.url)
        var images = obj["images"] as? [[String: Any]] ?? []
        let any = images.map(slot).filter { $0.appearance == nil }
        guard !images.map(slot).contains(where: { $0.appearance == "dark" }) else { return }
        for s in any { images.append(entry(Slot(idiom: s.idiom, scale: s.scale, size: s.size, appearance: "dark"))) }
        obj["images"] = images
        try writeContents(obj, to: set.url)
    }

    // MARK: Color sets

    public struct ColorValue: Equatable, Sendable {
        public enum Space: String, CaseIterable, Sendable { case sRGB = "srgb", displayP3 = "display-p3" }
        public var space: Space
        public var red: Double, green: Double, blue: Double, alpha: Double
        public var appearance: String?
        public init(space: Space, red: Double, green: Double, blue: Double, alpha: Double, appearance: String? = nil) {
            self.space = space
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
            self.appearance = appearance
        }
    }

    /// Components may be written as floats ("0.200") or 8-bit values
    /// ("51" or "0x33"); both read as 0…1.
    static func component(_ v: Any?) -> Double {
        let s = (v as? String) ?? (v as? NSNumber)?.stringValue ?? "0"
        if s.hasPrefix("0x"), let i = Int(s.dropFirst(2), radix: 16) { return Double(i) / 255 }
        if !s.contains("."), let i = Int(s), i > 1 { return Double(i) / 255 }
        return Double(s) ?? 0
    }

    /// The color values of a color set, one per appearance, in file order.
    public static func colors(of set: AssetSet) -> [ColorValue] {
        (readContents(set.url)["colors"] as? [[String: Any]] ?? []).map { d in
            let c = d["color"] as? [String: Any] ?? [:]
            let comp = c["components"] as? [String: Any] ?? [:]
            let appearance = (d["appearances"] as? [[String: String]])?.first { $0["appearance"] == "luminosity" }?["value"]
            return ColorValue(space: ColorValue.Space(rawValue: c["color-space"] as? String ?? "srgb") ?? .sRGB,
                              red: component(comp["red"]), green: component(comp["green"]), blue: component(comp["blue"]),
                              alpha: comp["alpha"] == nil ? 1 : component(comp["alpha"]), appearance: appearance)
        }
    }

    static func format(_ x: Double) -> String { String(format: "%.3f", min(max(x, 0), 1)) }

    /// Writes one color of a set (index in `colors`), as float components.
    public static func setColor(_ v: ColorValue, at index: Int, in set: AssetSet) throws {
        var obj = readContents(set.url)
        var colors = obj["colors"] as? [[String: Any]] ?? []
        var entry: [String: Any] = ["idiom": "universal", "color": [
            "color-space": v.space.rawValue,
            "components": ["red": format(v.red), "green": format(v.green), "blue": format(v.blue), "alpha": format(v.alpha)],
        ]]
        if let a = v.appearance { entry["appearances"] = [["appearance": "luminosity", "value": a]] }
        if colors.indices.contains(index) { colors[index] = entry } else { colors.append(entry) }
        obj["colors"] = colors
        if obj["info"] == nil { obj["info"] = info }
        try writeContents(obj, to: set.url)
    }

    /// Creates `<name>.colorset` in `group` with one white sRGB color. Throws
    /// if the folder exists or cannot be written.
    @discardableResult
    public func addColorSet(named name: String, in group: String = "") throws -> AssetSet {
        let dir = url.appendingPathComponent(group).appendingPathComponent("\(name).colorset")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let set = AssetSet(name: name, kind: .colorSet, url: dir, group: group)
        try Self.writeContents(["colors": [[String: Any]](), "info": Self.info], to: dir)
        try Self.setColor(ColorValue(space: .sRGB, red: 1, green: 1, blue: 1, alpha: 1), at: 0, in: set)
        return set
    }

    // MARK: App icon

    /// The macOS app icon slots: 16, 32, 128, 256 and 512 points at 1x and 2x.
    @discardableResult
    public func addMacAppIconSet(named name: String = "AppIcon", in parent: URL? = nil) throws -> AssetSet {
        let dir = (parent ?? url).appendingPathComponent("\(name).appiconset")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let images = ["16x16", "32x32", "128x128", "256x256", "512x512"].flatMap { size in
            ["1x", "2x"].map { Self.entry(Slot(idiom: "mac", scale: $0, size: size)) }
        }
        try Self.writeContents(["images": images, "info": Self.info], to: dir)
        return AssetSet(name: name, kind: .appIconSet, url: dir, group: "")
    }

    /// The iOS single-size app icon: one universal 1024x1024 slot.
    @discardableResult
    public func addIOSAppIconSet(named name: String = "AppIcon") throws -> AssetSet {
        let dir = url.appendingPathComponent("\(name).appiconset")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let images = [Self.entry(Slot(idiom: "universal", size: "1024x1024", platform: "ios"))]
        try Self.writeContents(["images": images, "info": Self.info], to: dir)
        return AssetSet(name: name, kind: .appIconSet, url: dir, group: "")
    }

    // MARK: Other set types (public Asset Catalog Format Reference)

    /// The "+" menu titles of the other set types, with their kinds.
    public static let otherSetTitles: [(title: String, kind: Kind, defaultName: String)] = [
        ("Symbol Image Set", .symbolSet, "Symbol"), ("Data Set", .dataSet, "Data"),
        ("Texture Set", .textureSet, "Texture"), ("Sprite Atlas", .spriteAtlas, "Sprites"),
        ("Cube Texture Set", .cubeTextureSet, "Cube Texture"), ("AR Resource Group", .arResourceGroup, "AR Resources"),
        ("AR Reference Image", .arReferenceImage, "AR Reference Image"), ("AR Reference Object", .arReferenceObject, "AR Reference Object"),
        ("iOS Launch Image (Deprecated)", .launchImage, "LaunchImage"), ("Sticker Pack", .stickerPack, "Sticker Pack"),
        ("Sticker", .sticker, "Sticker"), ("Sticker Sequence", .stickerSequence, "Sticker Sequence"),
    ]

    /// The initial Contents.json of a new set of a kind: `info` plus one
    /// universal slot for file-slot sets (symbol, data, AR image/object,
    /// launch image) and nothing else for the rest.
    static func initialContents(_ kind: Kind) -> [String: Any] {
        var obj: [String: Any] = ["info": info]
        switch kind {
        case .imageSet: obj["images"] = ["1x", "2x", "3x"].map { entry(Slot(idiom: "universal", scale: $0)) }
        case .symbolSet, .dataSet, .arReferenceImage, .arReferenceObject: obj[kind.slotKey!] = [["idiom": "universal"]]
        case .launchImage: obj["images"] = [[String: Any]]()
        case .textureSet, .cubeTextureSet: obj["textures"] = [[String: Any]]()
        default: break
        }
        return obj
    }

    /// Creates `<name>.<extension>` of any kind except color sets and app
    /// icons (they have their own initial slots).
    @discardableResult
    public func addSet(_ kind: Kind, named name: String, in group: String = "") throws -> AssetSet {
        switch kind {
        case .colorSet: return try addColorSet(named: name, in: group)
        case .appIconSet: return try addMacAppIconSet(named: name)
        default: break
        }
        let dir = url.appendingPathComponent(group).appendingPathComponent("\(name).\(kind.rawValue)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Self.writeContents(Self.initialContents(kind), to: dir)
        return AssetSet(name: name, kind: kind, url: dir, group: group)
    }

    /// A plain folder (a group); "Folder with Namespace" sets
    /// `properties.provides-namespace`.
    @discardableResult
    public func addFolder(named name: String, namespace: Bool = false, in group: String = "") throws -> URL {
        let dir = url.appendingPathComponent(group).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        var obj: [String: Any] = ["info": Self.info]
        if namespace { obj["properties"] = ["provides-namespace": true] }
        try Self.writeContents(obj, to: dir)
        return dir
    }

    /// Removes the set's folder from disk (not to the Trash).
    public func remove(_ set: AssetSet) throws { try FileManager.default.removeItem(at: set.url) }
}

// MARK: Presentation model (specs/ide/reference-ui-3.md §3)

extension AssetCatalog.Kind {
    /// The type label at the top right of the set header.
    public var typeLabel: String {
        switch self {
        case .imageSet: "Image Set"; case .colorSet: "Color"; case .appIconSet: "App Icon"
        case .symbolSet: "Symbol Image Set"; case .dataSet: "Data Set"; case .textureSet: "Texture Set"
        case .spriteAtlas: "Sprite Atlas"; case .cubeTextureSet: "Cube Texture Set"; case .arResourceGroup: "AR Resource Group"
        case .arReferenceImage: "AR Reference Image"; case .arReferenceObject: "AR Reference Object"
        case .launchImage: "Launch Image"; case .stickerPack: "Sticker Pack"; case .sticker: "Sticker"
        case .stickerSequence: "Sticker Sequence"
        case .brandAssets: "App Icon & Top Shelf Image"; case .imageStack: "Image Stack"; case .imageStackLayer: "Image Stack Layer"
        case .solidImageStack: "Solid Image Stack"; case .solidImageStackLayer: "Solid Image Stack Layer"
        case .stickersIconSet: "Messages Extension Icon"
        }
    }
}

extension AssetCatalog {
    static func idiomName(_ idiom: String) -> String {
        switch idiom {
        case "universal": "Universal"; case "iphone": "iPhone"; case "ipad": "iPad"; case "mac": "Mac"
        case "watch": "Apple Watch"; case "tv": "Apple TV"; case "vision": "Apple Vision"; case "car": "CarPlay"
        default: idiom.capitalized
        }
    }

    static func platformName(_ p: String) -> String {
        switch p { case "ios": "iOS"; case "macos": "macOS"; case "watchos": "watchOS"; case "tvos": "tvOS"; case "xros", "visionos": "visionOS"; default: p }
    }

    /// One inspector row: a label and either a value or a checkbox.
    public struct InspectorRow: Equatable, Sendable {
        public var label: String
        public var value: String?
        public var checked: Bool?
        public init(_ label: String, value: String? = nil, checked: Bool? = nil) {
            self.label = label; self.value = value; self.checked = checked
        }
    }

    public struct InspectorSection: Equatable, Sendable {
        public var title: String
        public var rows: [InspectorRow]
    }

    /// The attributes-inspector section for a set.
    public static func inspector(for set: AssetSet) -> InspectorSection {
        let obj = readContents(set.url)
        switch set.kind {
        case .appIconSet:
            let slots = (obj["images"] as? [[String: Any]] ?? []).map(slot)
            func mode(_ platform: String, idiom: String) -> String {
                if slots.contains(where: { $0.platform == platform && $0.scale == nil }) { return "Single Size" }
                if slots.contains(where: { $0.idiom == idiom }) { return "All Sizes" }
                return "None"
            }
            let dark = slots.contains { $0.appearance != nil }
            return InspectorSection(title: "App Icon", rows: [
                InspectorRow("Name", value: set.name),
                InspectorRow("iOS", value: mode("ios", idiom: "iphone")),
                InspectorRow("macOS", value: mode("macos", idiom: "mac")),
                InspectorRow("watchOS", value: mode("watchos", idiom: "watch")),
                InspectorRow("Appearances", value: dark ? "Any, Dark" : "None"),
                InspectorRow("Gamut", value: "Any"),
            ])
        case .colorSet:
            let entries = obj["colors"] as? [[String: Any]] ?? []
            let idioms = Set(entries.map { $0["idiom"] as? String ?? "universal" })
            let devices: [(String, String)] = [("Universal", "universal"), ("iPhone", "iphone"), ("iPad (and Mac Catalyst)", "ipad"),
                                               ("Mac Catalyst Scaled", "mac-catalyst"), ("CarPlay", "car"), ("Mac", "mac"),
                                               ("Apple Vision", "vision"), ("Apple Watch", "watch"), ("Apple TV", "tv")]
            let dark = colors(of: set).contains { $0.appearance != nil }
            let hc = entries.contains { (($0["appearances"] as? [[String: String]]) ?? []).contains { $0["appearance"] == "contrast" } }
            return InspectorSection(title: "Color Set", rows: [InspectorRow("Name", value: set.name)]
                + devices.map { InspectorRow($0.0, checked: idioms.contains($0.1)) }
                + [InspectorRow("Appearances", value: dark ? "Any, Dark" : "None"), InspectorRow("High Contrast", checked: hc),
                   InspectorRow("Gamut", value: "Any"), InspectorRow("Localization", value: "Localize…")])
        default:
            return InspectorSection(title: set.kind.typeLabel, rows: [InspectorRow("Name", value: set.name)])
        }
    }

    /// One entry of the editor's "+" menu: an item, a separator ("-"), or
    /// a submenu. `enabled` is false for sticker items outside a pack.
    public indirect enum AddMenuEntry: Equatable, Sendable {
        case item(String, enabled: Bool)
        case separator
        case submenu(String, [AddMenuEntry])

        public var title: String? {
            switch self { case let .item(t, _), let .submenu(t, _): t; case .separator: nil }
        }
    }

    /// The "+" menu structure (reference-ui-3 §3.5).
    public static func addMenu(insideStickerPack: Bool = false) -> [AddMenuEntry] {
        func items(_ ts: [String], enabled: Bool = true) -> [AddMenuEntry] { ts.map { .item($0, enabled: enabled) } }
        return items(["Image Set", "Color Set", "Symbol Image Set", "Data Set"]) + [
            .submenu("AR and Textures", items(["Texture Set", "Sprite Atlas", "Cube Texture Set"]) + [.separator]
                + items(["AR Resource Group", "AR Reference Image", "AR Reference Object"])),
            .submenu("iOS", items(["iOS App Icon", "iOS Launch Image (Deprecated)", "Messages Extension Icon"]) + [.separator]
                + items(["Sticker Pack"]) + items(["Sticker", "Sticker Sequence", "Sticker Sequence Frame"], enabled: insideStickerPack)),
            .submenu("macOS", items(["macOS App Icon"])),
            .submenu("watchOS", items(["watchOS App Icon"])),
            .submenu("tvOS", items(["tvOS App Icon and Top Shelf Image"])),
            .submenu("visionOS", items(["visionOS App Icon"])),
            .separator,
        ] + items(["Folder", "Folder with Namespace", "Folder from Selection"]) + [.separator] + items(["Import…"])
    }
}

// MARK: Outline filter and Color Set inspector edits (reference-ui-3 §3)

extension AssetCatalog {
    /// The sets whose name (or group path) contains `filter`, ignoring
    /// case. An empty filter keeps every set.
    public static func filtered(_ sets: [AssetSet], by filter: String) -> [AssetSet] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return sets }
        return sets.filter { ($0.group.isEmpty ? $0.name : $0.group + "/" + $0.name).localizedCaseInsensitiveContains(f) }
    }

    /// Device rows of the Color Set inspector: (label, idiom).
    public static let colorDevices: [(label: String, idiom: String)] = [
        ("Universal", "universal"), ("iPhone", "iphone"), ("iPad (and Mac Catalyst)", "ipad"),
        ("Mac Catalyst Scaled", "mac-catalyst"), ("CarPlay", "car"), ("Mac", "mac"),
        ("Apple Vision", "vision"), ("Apple Watch", "watch"), ("Apple TV", "tv"),
    ]

    static func appearances(_ e: [String: Any]) -> [[String: String]] { e["appearances"] as? [[String: String]] ?? [] }
    static func isDark(_ e: [String: Any]) -> Bool { appearances(e).contains { $0["appearance"] == "luminosity" && $0["value"] == "dark" } }
    static func isHighContrast(_ e: [String: Any]) -> Bool { appearances(e).contains { $0["appearance"] == "contrast" } }

    static func editColors(_ set: AssetSet, _ body: (inout [[String: Any]]) -> Void) throws {
        var obj = readContents(set.url)
        var colors = obj["colors"] as? [[String: Any]] ?? []
        body(&colors)
        obj["colors"] = colors
        if obj["info"] == nil { obj["info"] = info }
        try writeContents(obj, to: set.url)
    }

    /// Turns a device checkbox on (copies the universal, or first, idiom's
    /// entries with this idiom) or off (removes the idiom's entries; the
    /// last idiom stays).
    public static func setColorIdiom(_ idiom: String, included: Bool, in set: AssetSet) throws {
        try editColors(set) { colors in
            let idiomOf = { (e: [String: Any]) in e["idiom"] as? String ?? "universal" }
            let present = colors.contains { idiomOf($0) == idiom }
            if included, !present {
                let source = colors.contains { idiomOf($0) == "universal" } ? "universal" : (colors.first.map(idiomOf) ?? "universal")
                var copies = colors.filter { idiomOf($0) == source }.map { e -> [String: Any] in var e = e; e["idiom"] = idiom; return e }
                if copies.isEmpty {
                    copies = [["idiom": idiom, "color": ["color-space": "srgb", "components": ["red": "1.000", "green": "1.000", "blue": "1.000", "alpha": "1.000"]]]]
                }
                colors += copies
            } else if !included, present, Set(colors.map(idiomOf)).count > 1 {
                colors.removeAll { idiomOf($0) == idiom }
            }
        }
    }

    /// Appearances popup: "None" removes Dark entries; "Any, Dark" adds a
    /// Dark entry after each Any entry (same color).
    public static func setColorDarkAppearance(_ dark: Bool, in set: AssetSet) throws {
        try editColors(set) { colors in
            if !dark { colors.removeAll(where: isDark); return }
            guard !colors.contains(where: isDark) else { return }
            colors = colors.flatMap { e -> [[String: Any]] in
                guard appearances(e).isEmpty else { return [e] }
                var d = e
                d["appearances"] = [["appearance": "luminosity", "value": "dark"]]
                return [e, d]
            }
        }
    }

    /// High Contrast checkbox: adds a high-contrast copy of each entry, or
    /// removes them.
    public static func setColorHighContrast(_ on: Bool, in set: AssetSet) throws {
        try editColors(set) { colors in
            if !on { colors.removeAll(where: isHighContrast); return }
            guard !colors.contains(where: isHighContrast) else { return }
            colors += colors.map { e in
                var h = e
                h["appearances"] = appearances(e) + [["appearance": "contrast", "value": "high"]]
                return h
            }
        }
    }
}
