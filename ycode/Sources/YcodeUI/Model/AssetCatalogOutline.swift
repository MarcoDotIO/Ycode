import Foundation

// The asset catalog outline with folders as rows of their own and the
// remaining "+" items (reference-ui-5.md §11.2, P7; reference-ui-3.md
// §3.5). Contents.json layouts follow Apple's public Asset Catalog Format
// Reference.

extension AssetCatalog {
    /// One outline row: a folder (`set == nil`) or a set, with its depth.
    public struct OutlineRow: Equatable, Sendable {
        /// The path inside the catalog (unique).
        public var id: String
        public var name: String
        public var depth: Int
        public var url: URL
        public var set: AssetSet?
        public var hasChildren: Bool
        public var isFolder: Bool { self.set == nil }
    }

    /// The outline: folders and sets depth-first in name order; sets that
    /// hold others (sticker packs, image stacks…) list them as children.
    /// A filter keeps matching rows and their ancestors, all expanded.
    public func outline(collapsed: Set<String> = [], filter: String = "") -> [OutlineRow] {
        let f = filter.trimmingCharacters(in: .whitespaces)
        func walk(_ dir: URL, _ prefix: String, _ group: String, _ depth: Int) -> [OutlineRow] {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            var out: [OutlineRow] = []
            for n in names {
                let u = dir.appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let id = prefix.isEmpty ? n : prefix + "/" + n
                let kind = Kind(rawValue: u.pathExtension)
                let name = kind == nil ? n : u.deletingPathExtension().lastPathComponent
                let set = kind.map { AssetSet(name: name, kind: $0, url: u, group: group) }
                let childGroup = group.isEmpty ? name : group + "/" + name
                let children = kind == nil || kind!.isContainer ? walk(u, id, childGroup, depth + 1) : []
                let matches = f.isEmpty || (group.isEmpty ? name : group + "/" + name).localizedCaseInsensitiveContains(f)
                guard matches || !children.isEmpty else { continue }
                out.append(OutlineRow(id: id, name: name, depth: depth, url: u, set: set, hasChildren: !children.isEmpty))
                if !collapsed.contains(id) || !f.isEmpty { out += children }
            }
            return out
        }
        return walk(url, "", "", 0)
    }

    /// Two file URLs name the same item (trailing slashes and `..` aside).
    public static func same(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b else { return false }
        return a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// The path of a URL inside the catalog ("" for the catalog itself).
    func relativePath(_ u: URL) -> String {
        let base = url.standardizedFileURL.path
        let p = u.standardizedFileURL.path
        return p.hasPrefix(base + "/") ? String(p.dropFirst(base.count + 1)) : ""
    }

    /// A unique name in a directory: "Name", then "Name 1", "Name 2" …
    static func uniqueName(_ base: String, ext: String?, in dir: URL) -> String {
        var n = base, i = 1
        func exists(_ n: String) -> Bool {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent(ext.map { "\(n).\($0)" } ?? n).path)
        }
        while exists(n) { n = "\(base) \(i)"; i += 1 }
        return n
    }

    // MARK: Folder properties

    /// "Provides Namespace" of a folder (`properties.provides-namespace`).
    public static func providesNamespace(_ folder: URL) -> Bool {
        (readContents(folder)["properties"] as? [String: Any])?["provides-namespace"] as? Bool ?? false
    }

    /// Turns "Provides Namespace" on or off for `folder`; off removes the key
    /// (and an emptied `properties`). Throws if `Contents.json` cannot be written.
    public static func setProvidesNamespace(_ on: Bool, folder: URL) throws {
        var obj = readContents(folder)
        var props = obj["properties"] as? [String: Any] ?? [:]
        props["provides-namespace"] = on ? true : nil
        obj["properties"] = props.isEmpty ? nil : props
        if obj["info"] == nil { obj["info"] = info }
        try writeContents(obj, to: folder)
    }

    // MARK: Platform app icons and the Messages icon

    /// `<name>.appiconset` with one single-size 1024 slot for a platform
    /// ("watchos", "ios").
    @discardableResult
    public func addSingleSizeAppIcon(platform: String, named name: String, in dir: URL) throws -> AssetSet {
        let u = dir.appendingPathComponent("\(name).appiconset")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        try Self.writeContents(["images": [Self.entry(Slot(idiom: "universal", size: "1024x1024", platform: platform))], "info": Self.info], to: u)
        return AssetSet(name: name, kind: .appIconSet, url: u, group: "")
    }

    /// Writes an image stack (`imagestack` or `solidimagestack`) with
    /// Front, Middle and Back layers, each holding a Content image set.
    static func writeImageStack(at u: URL, solid: Bool, idiom: String, scales: [String]) throws {
        let layerExt = solid ? "solidimagestacklayer" : "imagestacklayer"
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        let layers = ["Front", "Middle", "Back"]
        try writeContents(["info": info, "layers": layers.map { ["filename": "\($0).\(layerExt)"] }], to: u)
        for l in layers {
            let layer = u.appendingPathComponent("\(l).\(layerExt)")
            try FileManager.default.createDirectory(at: layer, withIntermediateDirectories: false)
            try writeContents(["info": info], to: layer)
            let content = layer.appendingPathComponent("Content.imageset")
            try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
            try writeContents(["images": scales.map { entry(Slot(idiom: idiom, scale: $0)) }, "info": info], to: content)
        }
    }

    /// visionOS App Icon: a solid image stack with three layers.
    @discardableResult
    public func addVisionOSAppIcon(named name: String, in dir: URL) throws -> AssetSet {
        let u = dir.appendingPathComponent("\(name).solidimagestack")
        try Self.writeImageStack(at: u, solid: true, idiom: "vision", scales: ["2x"])
        return AssetSet(name: name, kind: .solidImageStack, url: u, group: "")
    }

    /// The tvOS brand assets: App Icon (and its App Store version) as
    /// image stacks, and the two Top Shelf images.
    static let tvBrandAssets: [(file: String, role: String, size: String)] = [
        ("App Icon - App Store.imagestack", "primary-app-icon", "1280x768"), ("App Icon.imagestack", "primary-app-icon", "400x240"),
        ("Top Shelf Image Wide.imageset", "top-shelf-image-wide", "2320x720"), ("Top Shelf Image.imageset", "top-shelf-image", "1920x720"),
    ]

    /// Creates `<name>.brandassets` in `dir` with the tvOS App Icon image
    /// stacks and the two Top Shelf image sets, all empty. Throws if the
    /// folder exists or cannot be written.
    @discardableResult
    public func addTVBrandAssets(named name: String, in dir: URL) throws -> AssetSet {
        let u = dir.appendingPathComponent("\(name).brandassets")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        try Self.writeContents(["assets": Self.tvBrandAssets.map { ["filename": $0.file, "idiom": "tv", "role": $0.role, "size": $0.size] },
                                "info": Self.info], to: u)
        for a in Self.tvBrandAssets {
            let part = u.appendingPathComponent(a.file)
            if a.file.hasSuffix(".imagestack") {
                try Self.writeImageStack(at: part, solid: false, idiom: "tv", scales: a.file.contains("App Store") ? ["1x"] : ["1x", "2x"])
            } else {
                try FileManager.default.createDirectory(at: part, withIntermediateDirectories: false)
                try Self.writeContents(["images": ["1x", "2x"].map { Self.entry(Slot(idiom: "tv", scale: $0)) }, "info": Self.info], to: part)
            }
        }
        return AssetSet(name: name, kind: .brandAssets, url: u, group: "")
    }

    /// The Messages extension icon slots: (idiom, size, scales).
    static let messagesIconSlots: [(idiom: String, size: String, scales: [String])] = [
        ("iphone", "29x29", ["2x", "3x"]), ("iphone", "60x45", ["2x", "3x"]), ("ipad", "29x29", ["2x"]), ("ipad", "67x50", ["2x"]),
        ("ipad", "74x55", ["2x"]), ("universal", "27x20", ["2x", "3x"]), ("universal", "32x24", ["2x", "3x"]), ("ios-marketing", "1024x768", ["1x"]),
    ]

    /// Creates `<name>.stickersiconset` in `dir` with the Messages icon slots,
    /// all empty. Throws if the folder exists or cannot be written.
    @discardableResult
    public func addMessagesIcon(named name: String, in dir: URL) throws -> AssetSet {
        let u = dir.appendingPathComponent("\(name).stickersiconset")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false)
        let images = Self.messagesIconSlots.flatMap { s in s.scales.map { Self.entry(Slot(idiom: s.idiom, scale: $0, size: s.size)) } }
        try Self.writeContents(["images": images, "info": Self.info], to: u)
        return AssetSet(name: name, kind: .stickersIconSet, url: u, group: "")
    }

    // MARK: Sticker sequence frames, Folder from Selection, Import

    /// Copies an image into a sticker sequence and appends it as a frame.
    public static func addStickerSequenceFrame(_ file: URL, to set: AssetSet) throws {
        guard set.kind == .stickerSequence else { return }
        var obj = readContents(set.url)
        var frames = obj["frames"] as? [[String: Any]] ?? []
        let dest = set.url.appendingPathComponent(file.lastPathComponent)
        if !same(dest, file) {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
        }
        frames.append(["filename": file.lastPathComponent])
        obj["frames"] = frames
        if obj["info"] == nil { obj["info"] = info }
        try writeContents(obj, to: set.url)
    }

    /// Moves items into a new folder ("Folder", made unique) next to the
    /// first of them. Returns the folder.
    @discardableResult
    public func folder(fromSelection items: [URL]) throws -> URL {
        guard let first = items.first else { return try addFolder(named: Self.uniqueName("Folder", ext: nil, in: url)) }
        let parent = first.deletingLastPathComponent()
        let name = Self.uniqueName("Folder", ext: nil, in: parent)
        let dir = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Self.writeContents(["info": Self.info], to: dir)
        for u in items { try FileManager.default.moveItem(at: u, to: dir.appendingPathComponent(u.lastPathComponent)) }
        return dir
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "pdf", "heic", "gif", "tif", "tiff", "svg", "webp"]

    /// Import…: images become image sets (`name@2x.png` and `name@3x.png`
    /// join `name`'s set at their scale, the others are 1x); other files
    /// become data sets. Returns the new sets.
    @discardableResult
    public func importFiles(_ files: [URL], into dir: URL) throws -> [AssetSet] {
        var out: [AssetSet] = []
        var byBase: [String: [(scale: String, url: URL)]] = [:]
        var order: [String] = []
        for f in files {
            let ext = f.pathExtension.lowercased()
            let stem = f.deletingPathExtension().lastPathComponent
            if Self.imageExtensions.contains(ext) {
                var base = stem, scale = "1x"
                for s in ["@2x", "@3x"] where stem.hasSuffix(s) { base = String(stem.dropLast(3)); scale = String(s.dropFirst()) }
                if byBase[base] == nil { order.append(base) }
                byBase[base, default: []].append((scale, f))
            } else {
                let name = Self.uniqueName(stem, ext: "dataset", in: dir)
                let set = try addSet(.dataSet, named: name, in: relativePath(dir))
                try Self.setImage(f, slot: 0, in: set)
                out.append(set)
            }
        }
        for base in order {
            let name = Self.uniqueName(base, ext: "imageset", in: dir)
            let set = try addImageSet(named: name, in: relativePath(dir))
            for (scale, f) in byBase[base] ?? [] {
                if let i = Self.slots(of: set).firstIndex(where: { $0.scale == scale && $0.appearance == nil }) { try Self.setImage(f, slot: i, in: set) }
            }
            out.append(set)
        }
        return out
    }
}
