import Foundation
import YcodeIcon

/// `ycode assets` (`specs/formats/assets-car.md` and `icon-format.md`,
/// "Ycode implementation"): compile catalogs and icons, dump a car, and
/// read, check and convert `.icon` documents.
public enum AssetsCLI {
    public static let usage = """
    usage: ycode assets compile <inputs (.xcassets, .icon)…> --output <dir> [--platform P] [--target-device D]…
                                [--app-icon NAME] [--alternate-app-icon NAME]… [--accent-color NAME]
                                [--minimum-deployment-target V] [--output-partial-info-plist F] [--export-dependency-info F]
                                [--icon-images <dir>] [--compression lzfse|none] [--output-format human-readable-text|xml1]
                                (actool's flags are accepted: --compile is --output; other flags are read and ignored)
           ycode assets info <Assets.car> [--json]
           ycode assets icon info <x.icon> [--appearance light|dark|tinted] [--platform iOS|macOS|watchOS]
           ycode assets icon validate <x.icon>
           ycode assets icon to-json <x.icon> [--resolved --appearance A --platform P] [-o file]
           ycode assets icon from-json <file.json> -o <out.icon> [--assets <dir>]
           ycode assets icon render <x.icon> -o <out.png> [--platform P] [--appearance A] [--size PX] [--icon-images <dir>]

    """

    /// Ycode's compiler version, reported to swift-build by `--version`.
    public static let version = (bundle: "1", short: "1.0")

    static func err(_ s: String) { FileHandle.standardError.write(Data((s.hasSuffix("\n") ? s : s + "\n").utf8)) }

    public static func run(_ args: [String]) -> Int32 {
        guard let sub = args.first else { err(usage); return 2 }
        let rest = Array(args.dropFirst())
        switch sub {
        case "compile": return compile(rest)
        case "info": return info(rest)
        case "icon": return icon(rest)
        default:
            err(usage)
            return 2
        }
    }

    // MARK: compile

    /// actool flags that take a value and that Ycode reads but does not use.
    static let ignoredWithValue: Set<String> = [
        "--output-format", "--enable-on-demand-resources", "--development-region", "--bundle-identifier",
        "--generate-swift-asset-symbol-extensions", "--generate-asset-symbol-framework-support",
        "--generate-asset-symbol-backwards-deployment-support", "--filter-for-thinning-device-configuration",
        "--filter-for-device-model", "--filter-for-device-os-version", "--sticker-pack-identifier-prefix",
        "--sticker-pack-strings-file", "--include-language", "--lightweight-asset-runtime-mode", "--widget-background-color",
        "--product-type", "--target-name", "--asset-pack-output-specifications", "--leaderboard-identifier-prefix",
        "--leaderboard-set-identifier-prefix", "--app-icon-group", "--skip-app-store-deployment", "--optimization",
    ]
    static let ignoredFlags: Set<String> = ["--notices", "--warnings", "--errors", "--compress-pngs", "--include-all-app-icons",
                                            "--skip-app-store-deployment", "--enable-incremental-distill"]

    static func compile(_ args: [String]) -> Int32 {
        var opts = AssetCompiler.Options(outputDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        var haveOutput = false
        var format = "human-readable-text"
        var swiftSymbols: URL?, objcSymbols: URL?, symbolIndex: URL?
        var printTags = false
        var printVersion = false
        var i = 0
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        func url(_ s: String) -> URL { URL(fileURLWithPath: s, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL }
        while i < args.count {
            let a = args[i]
            switch a {
            case "--output", "--compile", "-o":
                guard let v = value() else { err("ycode assets: \(a) needs a folder"); return 2 }
                opts.outputDirectory = url(v)
                haveOutput = true
            case "--platform": opts.platformName = value() ?? opts.platformName
            case "--target-device": if let v = value() { opts.targetDevices.append(v) }
            case "--app-icon": opts.appIcon = value()
            case "--alternate-app-icon": if let v = value() { opts.alternateAppIcons.append(v) }
            case "--accent-color": opts.accentColor = value()
            case "--minimum-deployment-target": opts.minimumDeploymentTarget = value() ?? ""
            case "--output-partial-info-plist": opts.partialInfoPlist = value().map(url)
            case "--export-dependency-info": opts.dependencyInfo = value().map(url)
            case "--icon-images": opts.iconImages = value().map(url)
            case "--standalone-icon-behavior": opts.standaloneIconBehavior = value() ?? "default"
            case "--compression":
                guard let v = value(), let c = CARCompression(rawValue: v) else { err("ycode assets: --compression lzfse|none"); return 2 }
                opts.compression = c
            case "--generate-swift-asset-symbols": swiftSymbols = value().map(url)
            case "--generate-objc-asset-symbols": objcSymbols = value().map(url)
            case "--generate-asset-symbol-index": symbolIndex = value().map(url)
            case "--print-asset-tag-combinations": printTags = true
            case "--version": printVersion = true
            case "--output-format": format = value() ?? format
            case _ where ignoredWithValue.contains(a): _ = value()
            case _ where ignoredFlags.contains(a): break
            case _ where a.hasPrefix("-"):
                err("ycode assets: unknown option \(a)")
                return 2
            default:
                opts.inputs.append(url(a))
            }
            i += 1
        }
        if printVersion {
            // swift-build reads `com.apple.<tool file name>.version`; the build
            // hook names its wrapper `actool`. The numbers are Ycode's own.
            let v = ["bundle-version": version.bundle, "short-bundle-version": version.short]
            if format == "xml1" { emitPlist(["com.apple.actool.version": v]) } else {
                print("/* com.apple.actool.version */\n    bundle-version: \(version.bundle)\n    short-bundle-version: \(version.short)")
            }
            return 0
        }
        if printTags {
            // swift-build asks which asset tags the catalogs use (on-demand
            // resources); Ycode writes none.
            emitPlist(["com.apple.actool.asset-tag-combinations": [Any]()])
            return 0
        }
        if swiftSymbols != nil || objcSymbols != nil || symbolIndex != nil {
            return writeSymbolStubs(swift: swiftSymbols, objc: objcSymbols, index: symbolIndex, format: format)
        }
        guard haveOutput else { err("ycode assets compile: --output <dir> is required"); return 2 }
        guard !opts.inputs.isEmpty else { err("ycode assets compile: no inputs"); return 2 }
        let result = AssetCompiler(options: opts).compile()
        report(result, format: format)
        return result.succeeded ? 0 : 1
    }

    static func emitPlist(_ obj: [String: Any]) {
        if let d = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) { FileHandle.standardOutput.write(d) }
    }

    /// Prints actool's three sections (`icon-compile.md` §1).
    static func report(_ r: AssetCompiler.Result, format: String) {
        let errors = r.diagnostics.filter { $0.kind == .error }
        let notices = r.diagnostics.filter { $0.kind != .error }
        if format == "xml1" {
            var o: [String: Any] = ["com.apple.actool.compilation-results": ["output-files": r.outputs.map(\.path)]]
            if !errors.isEmpty { o["com.apple.actool.errors"] = errors.map { ["description": $0.message] } }
            if !notices.isEmpty { o["com.apple.actool.notices"] = notices.map { ["description": $0.message] } }
            emitPlist(o)
            return
        }
        var out = ""
        if !errors.isEmpty {
            out += "/* com.apple.actool.errors */\n"
            for e in errors { out += e.description + "\n" }
        }
        if !notices.isEmpty {
            out += "/* com.apple.actool.notices */\n"
            for n in notices { out += n.description + "\n" }
        }
        out += "/* com.apple.actool.compilation-results */\n"
        for o in r.outputs { out += o.path + "\n" }
        FileHandle.standardOutput.write(Data(out.utf8))
    }

    /// The symbol-generation step (`GenerateAssetSymbols`): Ycode does not
    /// generate asset symbols yet; it writes valid, empty files.
    static func writeSymbolStubs(swift: URL?, objc: URL?, index: URL?, format: String) -> Int32 {
        let fm = FileManager.default
        var outs: [URL] = []
        do {
            for (u, text) in [(swift, "// Asset symbols: not generated by Ycode yet.\n"), (objc, "// Asset symbols: not generated by Ycode yet.\n")] {
                guard let u else { continue }
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: u, options: .atomic)
                outs.append(u)
            }
            if let index {
                try fm.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0).write(to: index, options: .atomic)
                outs.append(index)
            }
        } catch {
            err("ycode assets: \(error)")
            return 1
        }
        var r = AssetCompiler.Result()
        r.outputs = outs
        report(r, format: format)
        return 0
    }

    // MARK: info

    static func info(_ args: [String]) -> Int32 {
        guard let path = args.first(where: { !$0.hasPrefix("-") }) else { err(usage); return 2 }
        do {
            let car = try CARFile(contentsOf: URL(fileURLWithPath: path))
            let text = describe(car)
            if args.contains("--json") {
                FileHandle.standardOutput.write(text.json.formattedData())
                print()
            } else {
                print(text.lines.joined(separator: "\n"))
            }
            return car.structureIssues.isEmpty ? 0 : 1
        } catch {
            err("ycode assets: \(error)")
            return 1
        }
    }

    /// A car as JSON and as text lines.
    public static func describe(_ car: CARFile) -> (json: IconJSON, lines: [String]) {
        var lines: [String] = []
        let h = car.header
        lines.append("CoreUI version \(h.coreUIVersion), storage version \(h.storageVersion), schema \(h.schemaVersion), key semantics \(h.keySemantics)")
        lines.append("main version: \(h.mainVersion)")
        lines.append("version: \(h.versionString)")
        if let m = car.metadata { lines.append("platform: \(m.platform) \(m.deploymentTarget), authoring tool: \(m.authoringTool)") }
        let kf = car.keyFormat.map { CARAttribute(rawValue: $0)?.name ?? "\($0)" }
        lines.append("key format: \(kf.joined(separator: ", "))")
        lines.append("variables: \(car.variables.joined(separator: ", "))")
        lines.append("appearances: " + car.appearances.map { "\($0.name)=\($0.number)" }.joined(separator: ", "))
        var facets: [IconJSON] = []
        for f in car.facets {
            lines.append("facet \(f.name): \(CARPart.name(f.part ?? 0)), identifier \(f.identifier ?? 0)")
            facets.append(.object(["name": .string(f.name), "part": .number(Double(f.part ?? 0)), "identifier": .number(Double(f.identifier ?? 0))]))
        }
        var rends: [IconJSON] = []
        for r in car.renditions {
            var o: [String: IconJSON] = [
                "asset": .string(car.facetName(for: r) ?? "?"), "type": .string(CARPart.name(r.part)), "rendition-name": .string(r.name),
                "layout": .number(Double(r.layout)), "flags": .number(Double(r.flags)),
            ]
            var keyParts: [String] = []
            for (a, v) in r.key.sorted(by: { $0.key < $1.key }) where v != 0 || a == .appearance {
                o[a.name] = .number(Double(v))
                keyParts.append("\(a.name)=\(v)")
            }
            if let an = car.appearanceName(r.key[.appearance] ?? 0) { o["appearance-name"] = .string(an) }
            var detail = ""
            switch r.payload {
            case .bitmap(let b, let comp, let version, let chunks):
                o["pixel-width"] = .number(Double(b.width))
                o["pixel-height"] = .number(Double(b.height))
                o["compression"] = .string(comp == 4 ? "lzfse" : comp == 0 ? "none" : "\(comp)")
                o["opaque"] = .bool(b.isOpaque)
                detail = "\(b.width)x\(b.height) scale \(r.scale / 100) CELM v\(version) \(comp == 4 ? "lzfse \(chunks)" : "uncompressed") \(r.payloadLength) bytes"
            case .color(let c):
                o["color-space"] = .string(CARColor.spaceName(c.colorSpace))
                o["components"] = .array(c.components.map { .number($0) })
                detail = "\(CARColor.spaceName(c.colorSpace)) " + c.components.map { String(format: "%.3f", $0) }.joined(separator: " ")
            case .multisize(let s):
                o["sizes"] = .array(s.map { .object(["width": .number(Double($0.width)), "height": .number(Double($0.height)), "index": .number(Double($0.index))]) })
                detail = s.map { "\($0.width)x\($0.height)#\($0.index)" }.joined(separator: " ")
            case .rawData(let fl, let bytes):
                detail = "data \(bytes.count) bytes\(fl == 1 ? " (lzfse)" : "")"
            case .other(let tag, let n):
                detail = "\(tag) \(n) bytes"
            case .empty:
                detail = "empty"
            }
            rends.append(.object(o))
            lines.append("  \(car.facetName(for: r) ?? "?") [\(CARPart.name(r.part))] \(keyParts.joined(separator: " ")) — \(detail)")
        }
        for issue in car.structureIssues { lines.append("issue: \(issue)") }
        let json: IconJSON = .object([
            "core-ui-version": .number(Double(h.coreUIVersion)), "storage-version": .number(Double(h.storageVersion)),
            "key-semantics": .number(Double(h.keySemantics)), "main-version": .string(h.mainVersion), "version": .string(h.versionString),
            "platform": .string(car.metadata?.platform ?? ""), "deployment-target": .string(car.metadata?.deploymentTarget ?? ""),
            "key-format": .array(kf.map { .string($0) }),
            "appearances": .object(Dictionary(uniqueKeysWithValues: car.appearances.map { ($0.name, IconJSON.number(Double($0.number))) })),
            "facets": .array(facets), "renditions": .array(rends), "issues": .array(car.structureIssues.map { .string($0) }),
        ])
        return (json, lines)
    }

    // MARK: icon

    static func option(_ args: [String], _ name: String) -> String? {
        guard let k = args.firstIndex(of: name), k + 1 < args.count else { return nil }
        return args[k + 1]
    }

    static func icon(_ args: [String]) -> Int32 {
        guard let sub = args.first else { err(usage); return 2 }
        let rest = Array(args.dropFirst())
        let valued: Set<String> = ["-o", "--appearance", "--platform", "--size", "--assets", "--icon-images"]
        var positional: [String] = []
        var k = 0
        while k < rest.count {
            if valued.contains(rest[k]) { k += 2; continue }
            if !rest[k].hasPrefix("-") { positional.append(rest[k]) }
            k += 1
        }
        guard let input = positional.first else { err(usage); return 2 }
        let appearance = IconAppearance(rawValue: option(rest, "--appearance") ?? "light")
        let platform = IconPlatform(rawValue: option(rest, "--platform") ?? "iOS")
        guard let appearance, let platform else { err("ycode assets icon: --appearance light|dark|tinted, --platform iOS|macOS|watchOS"); return 2 }
        do {
            switch sub {
            case "info":
                let p = try IconPackage(contentsOf: URL(fileURLWithPath: input))
                print(iconSummary(p, appearance, platform).joined(separator: "\n"))
            case "validate":
                let p = try IconPackage(contentsOf: URL(fileURLWithPath: input))
                let issues = p.validate()
                for i in issues { print(i) }
                print(issues.isEmpty ? "\(p.name).icon: no problems" : "\(p.name).icon: \(issues.count) warning(s)")
            case "to-json":
                let p = try IconPackage(contentsOf: URL(fileURLWithPath: input))
                let json = rest.contains("--resolved") ? p.document.resolved(appearance, platform).json : p.document.json
                let data = json.formattedData()
                if let o = option(rest, "-o") { try data.write(to: URL(fileURLWithPath: o), options: .atomic) } else {
                    FileHandle.standardOutput.write(data)
                    print()
                }
            case "from-json":
                guard let o = option(rest, "-o") else { err("ycode assets icon from-json: -o <out.icon> is required"); return 2 }
                let doc = try IconDocument(data: try Data(contentsOf: URL(fileURLWithPath: input)))
                let pkg = IconPackage(url: URL(fileURLWithPath: o), document: doc)
                try pkg.write(copyingAssetsFrom: option(rest, "--assets").map { URL(fileURLWithPath: $0) })
                print(o)
            case "render":
                guard let o = option(rest, "-o") else { err("ycode assets icon render: -o <out.png> is required"); return 2 }
                let p = try IconPackage(contentsOf: URL(fileURLWithPath: input))
                let px = Int(option(rest, "--size") ?? "1024") ?? 1024
                let src = IconBitmapSource(package: p, folder: option(rest, "--icon-images").map { URL(fileURLWithPath: $0) })
                try PNG.encode(try src.bitmap(platform, appearance, pixels: px)).write(to: URL(fileURLWithPath: o), options: .atomic)
                print(o)
            default:
                err(usage)
                return 2
            }
        } catch {
            err("ycode assets: \(error)")
            return 1
        }
        return 0
    }

    static func iconSummary(_ p: IconPackage, _ a: IconAppearance, _ pl: IconPlatform) -> [String] {
        let r = p.document.resolved(a, pl)
        var out = ["\(p.name).icon — \(p.document.groups.count) group(s), assets: \(p.assetNames.joined(separator: ", "))"]
        if let sp = p.document.supportedPlatforms { out.append("platforms: " + sp.platforms.map(\.rawValue).joined(separator: ", ")) }
        out.append("\(a.rawValue), \(pl.rawValue): background \(r.background.json.formatted().replacingOccurrences(of: "\n", with: " "))")
        let frames = p.layerFrames(a, pl)
        for (gi, g) in r.groups.enumerated() {
            out.append("  group \(gi) \(g.name ?? "Group")\(g.hidden ? " (hidden)" : ""): opacity \(IconJSON.format(g.opacity)), \(g.blendMode.rawValue), "
                       + "lighting \(g.lighting.rawValue), shadow \(g.shadow.kind) \(IconJSON.format(g.shadow.opacity)), "
                       + "translucency \(IconJSON.format(g.translucency.effectiveValue)), specular \(g.specular)")
            for (li, l) in g.layers.enumerated() {
                let f = frames.first { $0.group == gi && $0.layer == li }?.frame
                out.append("    layer \(li) \(l.name ?? "-")\(l.hidden ? " (hidden)" : ""): \(l.imageName ?? "no image"), opacity \(IconJSON.format(l.opacity)), "
                           + "\(l.blendMode.rawValue), glass \(l.glass), fill \(l.fill.json.formatted().replacingOccurrences(of: "\n", with: " "))"
                           + (f.map { ", frame \($0)" } ?? ""))
            }
        }
        return out
    }
}
