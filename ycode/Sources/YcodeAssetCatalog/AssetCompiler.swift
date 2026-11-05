import Foundation
import YcodeIcon

/// Ycode's asset catalog compiler (`specs/formats/icon-compile.md` §3, §7;
/// `assets-car.md` §9 tier 1): `.xcassets` folders and `.icon` packages in,
/// `Assets.car`, the loose iOS icon PNGs or the macOS `.icns`, and the
/// partial `Info.plist` out.
public struct AssetCompiler {
    public struct Options: Sendable {
        public var inputs: [URL] = []
        public var outputDirectory: URL
        /// `--platform` (`iphonesimulator`, `macosx`, …).
        public var platformName = "iphoneos"
        /// `--target-device` values (`iphone`, `ipad`, `mac`, `watch`, `tv`, `vision`).
        public var targetDevices: [String] = []
        public var appIcon: String?
        public var alternateAppIcons: [String] = []
        public var accentColor: String?
        public var minimumDeploymentTarget = ""
        public var partialInfoPlist: URL?
        public var dependencyInfo: URL?
        public var compression: CARCompression = .lzfse
        /// Pre-flattened `.icon` bitmaps (see `IconBitmapSource`): a folder
        /// of PNGs, or a folder of such folders named like the icons.
        public var iconImages: URL?
        /// `--standalone-icon-behavior`: `default`, `all` or `none`.
        public var standaloneIconBehavior = "default"

        public init(outputDirectory: URL) { self.outputDirectory = outputDirectory }

        public var platform: CARPlatform? { CARPlatform(platformName: platformName) }

        /// Device families: the targeted ones, else the platform's own.
        var families: [String] {
            if !targetDevices.isEmpty { return targetDevices }
            switch platform {
            case .iOS: return ["iphone", "ipad"]
            case .macOS: return ["mac"]
            case .watchOS: return ["watch"]
            case .tvOS: return ["tv"]
            case .visionOS: return ["vision"]
            case nil: return []
            }
        }
    }

    public struct Diagnostic: Equatable, Sendable, CustomStringConvertible {
        public enum Kind: String, Sendable { case error, warning, note }
        public var kind: Kind
        public var path: String?
        public var message: String
        public var description: String { (path.map { "\($0): " } ?? "") + "\(kind.rawValue): \(message)" }
    }

    public struct Result: Sendable {
        public var diagnostics: [Diagnostic] = []
        public var outputs: [URL] = []
        public var inputs: [URL] = []
        public var partialInfoPlist: [String: Any] { infoPlist.mapValues { $0.value } }
        var infoPlist: [String: PlistBox] = [:]
        public var renditionCount = 0
        public var errors: [Diagnostic] { diagnostics.filter { $0.kind == .error } }
        public var succeeded: Bool { errors.isEmpty }
    }

    /// A property-list value that is Sendable.
    struct PlistBox: @unchecked Sendable {
        var value: Any
    }

    public var options: Options

    public init(options: Options) { self.options = options }

    public func compile() -> Result {
        var result = Result()
        func diag(_ k: Diagnostic.Kind, _ p: URL?, _ m: String) { result.diagnostics.append(Diagnostic(kind: k, path: p?.path, message: m)) }
        guard let platform = options.platform else {
            diag(.error, nil, "unknown platform \"\(options.platformName)\"")
            return result
        }
        var catalogs: [CatalogInput] = []
        var icons: [IconPackage] = []
        for u in options.inputs {
            switch u.pathExtension {
            case "xcassets":
                guard FileManager.default.fileExists(atPath: u.path) else { diag(.error, u, "no such catalog"); continue }
                let c = CatalogInput(contentsOf: u)
                for s in c.skipped {
                    diag(.warning, s, s.pathExtension == "icon"
                         ? "an .icon inside an asset catalog is ignored; add it to the target as its own input"
                         : "\(s.pathExtension) sets are not compiled by Ycode yet")
                }
                result.inputs += [u] + c.inputFiles
                catalogs.append(c)
            case "icon":
                do {
                    let p = try IconPackage(contentsOf: u)
                    icons.append(p)
                    result.inputs += [u, u.appendingPathComponent("icon.json")] + p.assetNames.map { p.assetURL($0) }
                } catch {
                    diag(.error, u, "\(error)")
                }
            default:
                diag(.error, u, "not an asset catalog or .icon package")
            }
        }
        guard result.errors.isEmpty else { return result }

        var writer = CARWriter(platform: platform, deploymentTarget: options.minimumDeploymentTarget, compression: options.compression)
        let fm = FileManager.default
        do { try fm.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true) } catch {
            diag(.error, options.outputDirectory, "cannot create the output folder: \(error)")
            return result
        }

        // Image and colour sets.
        var assetNames = Set<String>()
        for c in catalogs {
            for s in c.imageSets {
                guard assetNames.insert(s.name).inserted else { diag(.warning, s.url, "duplicate asset name \(s.name); the first is kept"); continue }
                addImageSet(s, platform: platform, to: &writer, diag: diag)
            }
            for s in c.colorSets {
                guard assetNames.insert(s.name).inserted else { diag(.warning, s.url, "duplicate asset name \(s.name); the first is kept"); continue }
                addColorSet(s, platform: platform, to: &writer, diag: diag)
            }
        }

        // App icons.
        var infoPlist: [String: Any] = [:]
        let wanted = [options.appIcon].compactMap { $0 } + options.alternateAppIcons
        let iconPlatform: IconPlatform? = switch platform {
        case .iOS: .iOS
        case .macOS: .macOS
        case .watchOS: .watchOS
        default: nil
        }
        var compiledIcons: [String] = []
        for name in wanted {
            let primary = name == options.appIcon
            if let pkg = icons.first(where: { $0.name == name }) {
                guard let ip = iconPlatform else {
                    if platform == .tvOS {
                        diag(.warning, nil, "None of the input catalogs contained a matching App Icon & Top Shelf Image brand assets collection named \"\(name)\"")
                    }
                    continue
                }
                let folder = options.iconImages.map { f -> URL in
                    let sub = f.appendingPathComponent(name)
                    var d: ObjCBool = false
                    return fm.fileExists(atPath: sub.path, isDirectory: &d) && d.boolValue ? sub : f
                }
                let src = IconBitmapSource(package: pkg, folder: folder)
                if folder == nil { diag(.note, pkg.url, "drawn with Ycode's placeholder render (background and PNG layers); pass flattened images for the final look") }
                // The files go into their own Result: `diag` appends to `result`,
                // which an inout access of `result` would overlap (exclusivity).
                var written = Result()
                addIcon(name: name, primary: primary, platform: platform, iconPlatform: ip, writer: &writer, diag: diag, result: &written) { a, px in
                    try src.bitmap(ip, a, pixels: px)
                }
                result.outputs += written.outputs
                compiledIcons.append(name)
            } else if let set = catalogs.lazy.flatMap(\.appIconSets).first(where: { $0.name == name }) {
                guard platform != .tvOS, platform != .visionOS else {
                    diag(.warning, set.url, "\(platform.rawValue) app icons (brand assets, image stacks) are not compiled by Ycode yet")
                    continue
                }
                var written = Result()
                addIconSet(set, primary: primary, platform: platform, writer: &writer, diag: diag, result: &written)
                result.outputs += written.outputs
                compiledIcons.append(name)
            } else if platform == .visionOS || platform == .tvOS {
                continue
            } else {
                diag(.error, nil, "None of the input catalogs contained a matching stickers icon set, app icon set, or icon stack named \"\(name)\"")
            }
        }
        guard result.errors.isEmpty else { return result }
        infoPlist.merge(iconPlist(compiled: compiledIcons, platform: platform)) { _, b in b }
        if let accent = options.accentColor, catalogs.contains(where: { $0.colorSets.contains { $0.name == accent } }) {
            infoPlist["NSAccentColorName"] = accent
        }

        // Write.
        if !writer.renditions.isEmpty {
            let car = options.outputDirectory.appendingPathComponent("Assets.car")
            do {
                try writer.data().write(to: car, options: .atomic)
                result.outputs.insert(car, at: 0)
                result.renditionCount = writer.renditions.count
            } catch {
                diag(.error, car, "\(error)")
            }
        }
        result.infoPlist = infoPlist.mapValues { PlistBox(value: $0) }
        if let p = options.partialInfoPlist {
            do {
                try fm.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0).write(to: p, options: .atomic)
            } catch {
                diag(.error, p, "cannot write the partial Info.plist: \(error)")
            }
        }
        if let d = options.dependencyInfo {
            do { try DependencyInfo.write(inputs: result.inputs, outputs: result.outputs, to: d) } catch {
                diag(.error, d, "cannot write the dependency info: \(error)")
            }
        }
        return result
    }

    // MARK: Image sets

    func addImageSet(_ s: CatalogInput.ImageSet, platform: CARPlatform, to w: inout CARWriter, diag: (Diagnostic.Kind, URL?, String) -> Void) {
        if let t = s.templateIntent, t != "automatic" {
            diag(.warning, s.url, "template rendering intent \"\(t)\" is not written yet (the image renders as automatic)")
        }
        var seen = Set<[CARAttribute: UInt16]>()
        for e in s.entries {
            guard let file = e.file else { continue }
            guard !e.highContrast else { diag(.note, file, "high-contrast variants are not compiled yet"); continue }
            guard file.pathExtension.lowercased() == "png" else {
                diag(.warning, file, "only PNG images are compiled by Ycode yet (\(file.pathExtension))")
                continue
            }
            guard let idiom = CARIdiom(catalogName: e.idiom) else { diag(.warning, file, "unknown idiom \(e.idiom)"); continue }
            if !Self.idiomApplies(idiom, platform) { continue }
            let bmp: Bitmap
            do { bmp = try PNG.decode(try Data(contentsOf: file)) } catch {
                diag(.error, file, "\(error)")
                continue
            }
            var a: [CARAttribute: UInt16] = [.scale: UInt16(e.scale)]
            if platform != .macOS { a[.idiom] = idiom.rawValue }
            if let ap = e.appearance { a[.appearance] = platform.appearanceNumber(ap == "dark" ? .dark : .light) }
            guard seen.insert(a).inserted else { continue }
            w.add(CARRendition(name: s.name, attributes: a, renditionName: file.lastPathComponent, content: .image(bmp), flags: 1 << 4))
        }
    }

    /// Whether an image of `idiom` belongs in a car for `platform`.
    static func idiomApplies(_ idiom: CARIdiom, _ platform: CARPlatform) -> Bool {
        switch platform {
        case .iOS: [.universal, .phone, .pad, .car, .marketing].contains(idiom)
        case .macOS: idiom == .universal || idiom == .mac
        case .watchOS: idiom == .universal || idiom == .watch
        case .tvOS: idiom == .universal || idiom == .tv
        case .visionOS: idiom == .universal || idiom == .vision
        }
    }

    // MARK: Colour sets

    func addColorSet(_ s: CatalogInput.ColorSet, platform: CARPlatform, to w: inout CARWriter, diag: (Diagnostic.Kind, URL?, String) -> Void) {
        var seen = Set<[CARAttribute: UInt16]>()
        for e in s.entries {
            guard !e.highContrast else { continue }
            guard let idiom = CARIdiom(catalogName: e.idiom), Self.idiomApplies(idiom, platform) else { continue }
            // Colours have scale 1 (`assets-car.md` §4.1); lookups miss them with 0.
            var a: [CARAttribute: UInt16] = [.scale: 1]
            if platform != .macOS { a[.idiom] = idiom.rawValue }
            if let ap = e.appearance { a[.appearance] = platform.appearanceNumber(ap == "dark" ? .dark : .light) }
            guard seen.insert(a).inserted else { continue }
            w.add(CARRendition(name: s.name, attributes: a, renditionName: s.name, content: .color(e.color)))
        }
    }

    // MARK: App icons

    /// The flattened tier of an `.icon` (§4 MultiSized Image + Icon Image,
    /// sizes of §5) and the loose files of §3.
    func addIcon(name: String, primary: Bool, platform: CARPlatform, iconPlatform: IconPlatform, writer w: inout CARWriter,
                 diag: (Diagnostic.Kind, URL?, String) -> Void, result: inout Result,
                 image: (IconAppearance, Int) throws -> Bitmap) {
        do {
            switch platform {
            case .macOS:
                let master = try image(.light, 1024)
                let sizes: [(pt: UInt32, scale: UInt16, index: UInt16)] = [(16, 2, 1), (32, 2, 2), (64, 2, 3), (128, 2, 4), (256, 2, 5), (512, 2, 6), (1024, 1, 7)]
                w.add(CARRendition(name: name, renditionName: name, content: .multisize(sizes.map { CARMultisizeEntry(width: $0.pt, height: $0.pt, index: $0.index) })))
                for s in sizes {
                    let px = Int(s.pt) * Int(s.scale)
                    w.add(CARRendition(name: name, attributes: [.dimension2: s.index, .scale: s.scale],
                                       renditionName: "\(name)\(s.pt)x\(s.pt)@\(s.scale)x.png", content: .iconImage(master.resized(width: px, height: px))))
                }
                if primary { try writeICNS(name: name, result: &result) { px in master.resized(width: px, height: px) } }
            case .watchOS:
                let bmp = try image(.light, 1024)
                w.add(CARRendition(name: name, attributes: [.idiom: CARIdiom.watch.rawValue], renditionName: name,
                                   content: .multisize([CARMultisizeEntry(width: 1024, height: 1024, index: 1)])))
                w.add(CARRendition(name: name, attributes: [.idiom: CARIdiom.watch.rawValue, .dimension2: 1, .scale: 1],
                                   renditionName: "\(name)1024x1024.png", content: .iconImage(opaque(bmp))))
            default:
                let idioms = iosIdioms()
                var looks: [(CARAppearance, Bitmap)] = []
                for (ca, ia) in [(CARAppearance.any, IconAppearance.light), (.dark, .dark), (.tinted, .tinted)] {
                    looks.append((ca, opaque(try image(ia, 1024))))
                }
                for idiom in idioms {
                    w.add(CARRendition(name: name, attributes: [.idiom: idiom.rawValue], renditionName: name,
                                       content: .multisize([CARMultisizeEntry(width: 1024, height: 1024, index: 1)])))
                    for (ca, bmp) in looks {
                        w.add(CARRendition(name: name, attributes: [.idiom: idiom.rawValue, .dimension2: 1, .scale: 1, .appearance: platform.appearanceNumber(ca)],
                                           renditionName: "\(name)1024x1024_\(platform.appearanceName(ca)).png", content: .iconImage(bmp)))
                    }
                }
                if primary { try writeLooseIOSPNGs(name: name, master: looks[0].1, result: &result) }
            }
        } catch {
            diag(.error, nil, "\(name): \(error)")
        }
    }

    func opaque(_ b: Bitmap) -> Bitmap { b.isOpaque ? b : b.flattened(onto: (1, 1, 1)) }

    /// iOS writes phone and pad renditions for the targeted families (both
    /// when none is named).
    func iosIdioms() -> [CARIdiom] {
        let f = options.families
        var out: [CARIdiom] = []
        if f.contains("iphone") || !f.contains("ipad") { out.append(.phone) }
        if f.contains("ipad") || !f.contains("iphone") { out.append(.pad) }
        return out
    }

    /// `AppIcon60x60@2x.png` (120 px) and `AppIcon76x76@2x~ipad.png` (152 px).
    func writeLooseIOSPNGs(name: String, master: Bitmap, result: inout Result) throws {
        for (file, px) in [("\(name)60x60@2x.png", 120), ("\(name)76x76@2x~ipad.png", 152)] {
            let u = options.outputDirectory.appendingPathComponent(file)
            try PNG.encode(opaque(master.resized(width: px, height: px)), dropAlpha: true).write(to: u, options: .atomic)
            result.outputs.append(u)
        }
    }

    func writeICNS(name: String, result: inout Result, image: (Int) -> Bitmap) throws {
        let set = options.standaloneIconBehavior == "all" ? ICNS.fullSet : ICNS.defaultSet
        let u = options.outputDirectory.appendingPathComponent("\(name).icns")
        try ICNS.write(set, image: image).write(to: u, options: .atomic)
        result.outputs.append(u)
    }

    /// An `.appiconset`: one MultiSized Image per idiom listing its sizes,
    /// one Icon Image per idiom, size, scale and appearance (§6).
    func addIconSet(_ set: CatalogInput.AppIconSet, primary: Bool, platform: CARPlatform, writer w: inout CARWriter,
                    diag: (Diagnostic.Kind, URL?, String) -> Void, result: inout Result) {
        struct Image { var idiom: CARIdiom; var size: Double; var scale: Int; var appearance: CARAppearance; var bitmap: Bitmap; var file: URL }
        var images: [Image] = []
        for e in set.entries {
            guard let file = e.file else { continue }
            if let p = e.platform, CARPlatform(platformName: p) != platform { continue }
            var idiom = CARIdiom(catalogName: e.idiom) ?? .universal
            if e.idiom == "ios-marketing" || e.idiom == "watch-marketing" { continue }
            if idiom == .universal || idiom == .marketing {
                idiom = switch platform {
                case .macOS: .mac
                case .watchOS: .watch
                default: .universal
                }
            }
            guard Self.idiomApplies(idiom, platform) || idiom == .mac && platform == .macOS else { continue }
            guard let bmp = try? PNG.decode(try Data(contentsOf: file)) else {
                diag(.error, file, "cannot read the icon image (only PNG is compiled)")
                continue
            }
            let size = e.size ?? Double(bmp.width / max(e.scale, 1))
            let ap: CARAppearance = e.appearance == "dark" ? .dark : e.appearance == "tinted" ? .tinted : .any
            if platform != .iOS, ap != .any { continue }
            images.append(Image(idiom: idiom, size: size, scale: e.scale, appearance: ap, bitmap: bmp, file: file))
        }
        guard !images.isEmpty else {
            diag(.warning, set.url, "the app icon set \(set.name) has no images")
            return
        }
        // A single-size universal iOS icon becomes phone and pad (§6).
        var expanded: [Image] = []
        for i in images {
            if platform == .iOS, i.idiom == .universal {
                for id in iosIdioms() { expanded.append(Image(idiom: id, size: i.size, scale: i.scale, appearance: i.appearance, bitmap: i.bitmap, file: i.file)) }
            } else {
                expanded.append(i)
            }
        }
        let byIdiom = Dictionary(grouping: expanded) { $0.idiom }
        for idiom in byIdiom.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            let list = byIdiom[idiom]!
            let sizes = Array(Set(list.map(\.size))).sorted()
            var a: [CARAttribute: UInt16] = [:]
            if platform != .macOS { a[.idiom] = idiom.rawValue }
            w.add(CARRendition(name: set.name, attributes: a, renditionName: set.name, content: .multisize(sizes.enumerated().map {
                CARMultisizeEntry(width: UInt32($0.element), height: UInt32($0.element), index: UInt16($0.offset + 1))
            })))
            var seen = Set<[CARAttribute: UInt16]>()
            for i in list {
                var k = a
                k[.dimension2] = UInt16(sizes.firstIndex(of: i.size)! + 1)
                k[.scale] = UInt16(i.scale)
                k[.appearance] = platform.appearanceNumber(i.appearance)
                guard seen.insert(k).inserted else { continue }
                let bmp = platform == .macOS ? i.bitmap : opaque(i.bitmap)
                w.add(CARRendition(name: set.name, attributes: k, renditionName: i.file.lastPathComponent, content: .iconImage(bmp)))
            }
        }
        guard primary else { return }
        let largest = images.filter { $0.appearance == .any }.max { $0.bitmap.width < $1.bitmap.width }?.bitmap ?? images[0].bitmap
        do {
            switch platform {
            case .iOS:
                try writeLooseIOSPNGs(name: set.name, master: largest, result: &result)
            case .macOS:
                try writeICNS(name: set.name, result: &result) { px in
                    images.first { Int($0.size) * $0.scale == px && $0.appearance == .any }?.bitmap ?? largest.resized(width: px, height: px)
                }
            default: break
            }
        } catch {
            diag(.error, set.url, "\(error)")
        }
    }

    /// The partial `Info.plist` of §3.
    func iconPlist(compiled: [String], platform: CARPlatform) -> [String: Any] {
        guard let primary = options.appIcon, compiled.contains(primary) else {
            return [:]
        }
        let alternates = options.alternateAppIcons.filter { compiled.contains($0) }
        let alt: [String: Any] = Dictionary(uniqueKeysWithValues: alternates.map { ($0, ["CFBundleIconName": $0] as [String: Any]) })
        switch platform {
        case .iOS:
            let f = options.families
            let phoneTargeted = f.contains("iphone") || !f.contains("ipad")
            let padTargeted = f.contains("ipad") || !f.contains("iphone")
            var phone: [String: Any] = ["CFBundleIconFiles": ["\(primary)60x60"]]
            var pad: [String: Any] = ["CFBundleIconFiles": ["\(primary)60x60", "\(primary)76x76"]]
            if phoneTargeted { phone["CFBundleIconName"] = primary }
            if padTargeted { pad["CFBundleIconName"] = primary }
            var icons: [String: Any] = ["CFBundlePrimaryIcon": phone]
            var padIcons: [String: Any] = ["CFBundlePrimaryIcon": pad]
            if !alt.isEmpty {
                icons["CFBundleAlternateIcons"] = alt
                padIcons["CFBundleAlternateIcons"] = alt
            }
            return ["CFBundleIcons": icons, "CFBundleIcons~ipad": padIcons]
        case .macOS:
            return ["CFBundleIconFile": primary, "CFBundleIconName": primary]
        case .watchOS:
            return ["CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconName": primary]]]
        default:
            return [:]
        }
    }
}

/// The ld-style dependency file swift-build reads (`--export-dependency-info`):
/// a version record, then input (0x10) and output (0x40) records, each an
/// opcode byte and a NUL-terminated string.
public enum DependencyInfo {
    public static func data(inputs: [URL], outputs: [URL], version: String = "ycode-assets") -> Data {
        var b: [UInt8] = [0x00] + Array(version.utf8) + [0]
        for u in inputs { b += [0x10] + Array(u.path.utf8) + [0] }
        for u in outputs { b += [0x40] + Array(u.path.utf8) + [0] }
        return Data(b)
    }

    public static func write(inputs: [URL], outputs: [URL], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data(inputs: inputs, outputs: outputs).write(to: url, options: .atomic)
    }
}
