import Foundation

/// An `.icon` package (`specs/formats/icon-format.md` §1): `icon.json` and
/// the flat `Assets/` folder its layers name.
public struct IconPackage: Sendable {
    public var url: URL
    public var document: IconDocument

    /// The icon name the build uses: the package name without `.icon`.
    public var name: String { url.deletingPathExtension().lastPathComponent }
    public var assetsURL: URL { url.appendingPathComponent("Assets") }

    public init(url: URL, document: IconDocument) {
        self.url = url
        self.document = document
    }

    /// Reads `<url>/icon.json`.
    public init(contentsOf url: URL) throws {
        let jsonURL = url.appendingPathComponent("icon.json")
        guard let data = try? Data(contentsOf: jsonURL) else { throw IconError("", "\(url.lastPathComponent) has no icon.json") }
        self.url = url
        self.document = try IconDocument(data: data)
    }

    /// Writes `icon.json` (Icon Composer's layout) and, when `assets` names
    /// a folder, copies its files into `Assets/`.
    public func write(to destination: URL? = nil, copyingAssetsFrom assets: URL? = nil) throws {
        let dest = destination ?? url
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try document.data().write(to: dest.appendingPathComponent("icon.json"), options: .atomic)
        let source = assets ?? (dest.standardizedFileURL == url.standardizedFileURL ? nil : assetsURL)
        if let source, let names = try? fm.contentsOfDirectory(atPath: source.path), !names.isEmpty {
            let out = dest.appendingPathComponent("Assets")
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            for n in names where !n.hasPrefix(".") {
                let target = out.appendingPathComponent(n)
                guard target.standardizedFileURL != source.appendingPathComponent(n).standardizedFileURL else { continue }
                try? fm.removeItem(at: target)
                try fm.copyItem(at: source.appendingPathComponent(n), to: target)
            }
        }
    }

    public func assetURL(_ imageName: String) -> URL { assetsURL.appendingPathComponent(imageName) }

    /// The files in `Assets/`, sorted.
    public var assetNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: assetsURL.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Every image name some layer uses in some appearance or idiom.
    public var referencedImageNames: [String] {
        var names: [String] = []
        for g in document.groups {
            for l in g.layers {
                for n in [l.imageName.value].compactMap({ $0 }) + (l.imageName.specializations ?? []).map(\.value) where !names.contains(n) {
                    names.append(n)
                }
            }
        }
        return names
    }

    /// A layer image's natural size in points (§4.4): an SVG's `width` and
    /// `height` (else its `viewBox`), a PNG's pixel size. Nil when the file
    /// is missing or unreadable.
    public func naturalSize(of imageName: String) -> IconSize? {
        guard let data = try? Data(contentsOf: assetURL(imageName)) else { return nil }
        return IconImageInfo.naturalSize(data)
    }

    /// The frames of every visible layer for an appearance and platform,
    /// front-most group first (layers whose image is missing are left out).
    public func layerFrames(_ a: IconAppearance, _ p: IconPlatform) -> [(group: Int, layer: Int, frame: IconRect)] {
        let r = document.resolved(a, p)
        var out: [(Int, Int, IconRect)] = []
        for (gi, g) in r.groups.enumerated() where !g.hidden {
            for (li, l) in g.layers.enumerated() where !l.hidden {
                guard let n = l.imageName, let size = naturalSize(of: n) else { continue }
                out.append((gi, li, IconGeometry.layerFrame(natural: size, layer: l.position, group: g.position, canvas: p.canvasSize)))
            }
        }
        return out
    }
}

/// Reads image dimensions without decoding pixels.
public enum IconImageInfo {
    public static func naturalSize(_ data: Data) -> IconSize? {
        let b = [UInt8](data.prefix(4096))
        if b.count >= 24, b.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            // The IHDR chunk comes first (after an optional CgBI chunk).
            var i = 8
            while i + 16 <= b.count {
                let len = Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
                if b[i + 4..<i + 8].elementsEqual(Array("IHDR".utf8)) {
                    let p = i + 8
                    guard p + 8 <= b.count else { return nil }
                    let w = Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
                    let h = Int(b[p + 4]) << 24 | Int(b[p + 5]) << 16 | Int(b[p + 6]) << 8 | Int(b[p + 7])
                    return IconSize(width: Double(w), height: Double(h))
                }
                i += 12 + len
            }
            return nil
        }
        return svgSize(String(decoding: data, as: UTF8.self))
    }

    /// The `<svg>` element's `width`/`height` (numbers, optionally with `px`
    /// or `pt`), else the `viewBox` size.
    public static func svgSize(_ text: String) -> IconSize? {
        guard let start = text.range(of: "<svg") else { return nil }
        guard let end = text[start.upperBound...].firstIndex(of: ">") else { return nil }
        let tag = String(text[start.upperBound..<end])
        func attribute(_ name: String) -> String? {
            var search = tag[...]
            while let r = search.range(of: name) {
                let before = r.lowerBound == search.startIndex ? " " : search[search.index(before: r.lowerBound)]
                var rest = search[r.upperBound...].drop { $0 == " " }
                if before.isWhitespace, rest.first == "=" {
                    rest = rest.dropFirst().drop { $0 == " " }
                    guard let q = rest.first, q == "\"" || q == "'" else { return nil }
                    let body = rest.dropFirst()
                    guard let close = body.firstIndex(of: q) else { return nil }
                    return String(body[..<close])
                }
                search = search[r.upperBound...]
            }
            return nil
        }
        func number(_ s: String?) -> Double? {
            guard var s = s?.trimmingCharacters(in: .whitespaces) else { return nil }
            for unit in ["px", "pt"] where s.hasSuffix(unit) { s.removeLast(2) }
            return Double(s)
        }
        if let w = number(attribute("width")), let h = number(attribute("height")) { return IconSize(width: w, height: h) }
        if let vb = attribute("viewBox") {
            let n = vb.split { $0 == " " || $0 == "," }.compactMap { Double($0) }
            if n.count == 4 { return IconSize(width: n[2], height: n[3]) }
        }
        return nil
    }
}

// MARK: Validation

public struct IconIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case warning, error }
    public var severity: Severity
    public var path: String
    public var message: String
    public var description: String { "\(severity.rawValue): \(path.isEmpty ? "" : path + ": ")\(message)" }
}

extension IconPackage {
    /// Problems that do not stop reading (§1, §3, §9): Icon Composer's
    /// too-many-visible-groups warning, missing or unknown image files,
    /// values the spec lists as unrecognized.
    public func validate() -> [IconIssue] {
        var out: [IconIssue] = []
        func warn(_ p: String, _ m: String) { out.append(IconIssue(severity: .warning, path: p, message: m)) }
        let doc = document
        for p in IconPlatform.allCases {
            for a in IconAppearance.allCases {
                let n = doc.resolved(a, p).visibleGroups.count
                if n > 4, !out.contains(where: { $0.message.hasPrefix("too-many-visible-groups") }) {
                    warn("groups", "too-many-visible-groups: \(n) groups are visible (\(a.rawValue), \(p.rawValue)); at most 4 are drawn")
                }
            }
        }
        if let cs = doc.colorSpaceForUntaggedSVGColors, cs != "display-p3" {
            warn("color-space-for-untagged-svg-colors", "\"\(cs)\" is not a known value (display-p3 is)")
        }
        let available = Set(assetNames)
        for (gi, g) in doc.groups.enumerated() {
            let gp = "groups[\(gi)]"
            for s in [g.specularHighlightPlacement.value].compactMap({ $0 }) + (g.specularHighlightPlacement.specializations ?? []).map(\.value) where !s.isKnown {
                warn(gp + ".specular-highlight-placement", "unrecognized value \"\(s.rawValue)\" (ignored)")
            }
            for s in [g.shadow.value].compactMap({ $0 }) + (g.shadow.specializations ?? []).map(\.value) where s.knownKind == nil {
                warn(gp + ".shadow.kind", "unknown shadow kind \"\(s.kind)\"")
            }
            if g.layers.isEmpty { warn(gp, "empty group") }
            for (li, l) in g.layers.enumerated() {
                let lp = gp + ".layers[\(li)]"
                let names = [l.imageName.value].compactMap { $0 } + (l.imageName.specializations ?? []).map(\.value)
                if names.isEmpty { warn(lp, "layer without an image (draws nothing)") }
                for n in names {
                    if !available.contains(n) { warn(lp + ".image-name", "Assets/\(n) is missing (the layer is skipped)") }
                    let ext = (n as NSString).pathExtension.lowercased()
                    if ext != "svg", ext != "png" { warn(lp + ".image-name", "\(n): only SVG and PNG artwork is known") }
                }
            }
        }
        return out
    }
}
