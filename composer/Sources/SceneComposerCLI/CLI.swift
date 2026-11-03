import Foundation
import SceneComposerCore
import USDCore
import USDShade
import USDStage

/// `ycode-scene`: the Scene Composer's command-line tool.
public enum SceneComposerCLI {
    public static let version = "0.1.0"

    public static let usage = """
    ycode-scene \(version) — Ycode Scene Composer command-line tool

    Usage:
      ycode-scene info <file>
      ycode-scene tree <file> [--layer] [--all] [--components]
      ycode-scene cat <file> [--flatten] [--sorted]
      ycode-scene convert <input> <output> [--flatten] [--format usda|usdc|usdz]
      ycode-scene validate <file> [--strict]
      ycode-scene edit <file> [-o <output>] <operation>...
      ycode-scene components

    Edit operations (applied in order, one undo step each):
      --add-prim <path> [<type>]            define a prim (missing parents become overs)
      --remove <path>                       delete (or deactivate a referenced prim)
      --rename <path> <name>
      --move <path> <new-parent>
      --set <path.attr> <type> <value>      e.g. --set /Root/Cube.size double 0.5
      --set-sample <path.attr> <type> <time> <value>
      --meta <path> <key> <value>           e.g. --meta /Root kind '"component"'
      --translate <path> <x> <y> <z>        writes translate/orient/scale ops
      --reference <parent> <name> <asset>   add a prim referencing another file
      --add-component <path> <id>           e.g. RealityKit.Collider
      --bind <path> <material>
      --default-prim <name>

    Formats follow the file extension; .usd is read as either text or crate.
    Exit status: 0 success, 1 validation errors, 2 usage or I/O errors.
    """

    public static func main() {
        var out = FileHandleOutput(handle: .standardOutput)
        var err = FileHandleOutput(handle: .standardError)
        exit(run(Array(CommandLine.arguments.dropFirst()), out: &out, err: &err))
    }

    public static func run(_ args: [String], out: inout some TextOutputStream, err: inout some TextOutputStream) -> Int32 {
        guard let command = args.first else {
            print(usage, to: &err)
            return 2
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "info": return try info(rest, out: &out)
            case "tree": return try tree(rest, out: &out)
            case "cat": return try cat(rest, out: &out)
            case "convert": return try convert(rest, out: &out)
            case "validate": return try validate(rest, out: &out)
            case "edit": return try edit(rest, out: &out)
            case "components":
                for kind in ComponentCatalogue.realityKit.components {
                    print("\(kind.id)\t\(kind.runtime)\(kind.openFields == true ? "\t(fields in \(kind.fieldsSpec ?? "other specs"))" : "")", to: &out)
                }
                return 0
            case "--version", "version":
                print(version, to: &out)
                return 0
            case "--help", "-h", "help":
                print(usage, to: &out)
                return 0
            default:
                print("ycode-scene: unknown command '\(command)'\n\n\(usage)", to: &err)
                return 2
            }
        } catch let e as UsageError {
            print("ycode-scene \(command): \(e.message)", to: &err)
            return 2
        } catch {
            print("ycode-scene \(command): \(error)", to: &err)
            return 2
        }
    }

    struct UsageError: Error { var message: String }

    /// Splits flags (`--x`) from positional arguments.
    static func split(_ args: [String], flags: Set<String>, options: Set<String> = []) throws -> (positional: [String], flags: Set<String>, options: [String: String]) {
        var positional: [String] = []
        var set: Set<String> = []
        var opts: [String: String] = [:]
        var i = 0
        while i < args.count {
            let a = args[i]
            if flags.contains(a) {
                set.insert(a)
            } else if options.contains(a) {
                guard i + 1 < args.count else { throw UsageError(message: "\(a) needs a value") }
                opts[a] = args[i + 1]
                i += 1
            } else if a.hasPrefix("--") {
                throw UsageError(message: "unknown option \(a)")
            } else {
                positional.append(a)
            }
            i += 1
        }
        return (positional, set, opts)
    }

    static func absolute(_ path: String) -> String {
        path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
    }

    static func open(_ file: String) throws -> (Layer, Stage) {
        let resolver = FileLayerResolver()
        let layer = try resolver.layer(for: AssetPaths.normalize(absolute(file)))
        return (layer, Stage(rootLayer: layer, resolver: resolver))
    }

    // MARK: info

    static func info(_ args: [String], out: inout some TextOutputStream) throws -> Int32 {
        let (pos, _, _) = try split(args, flags: [])
        guard pos.count == 1 else { throw UsageError(message: "info takes one file") }
        let file = pos[0]
        guard let data = FileManager.default.contents(atPath: file) else { throw USDError("cannot read \(file)") }
        let bytes = [UInt8](data)
        let format = USDCReader.isCrate(bytes) ? "usdc (crate \(bytes[8]).\(bytes[9]).\(bytes[10]))"
            : bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) ? "usdz" : "usda"
        print("file: \(file)", to: &out)
        print("format: \(format), \(bytes.count) bytes", to: &out)
        if format == "usdz" {
            let archive = try USDZArchive.read(bytes)
            let offsets = try USDZArchive.dataOffsets(bytes)
            print("package entries:", to: &out)
            for e in archive.entries {
                print("  \(e.name)  \(e.data.count) bytes\(offsets[e.name].map { $0 % 64 == 0 ? "" : "  (data not 64-byte aligned)" } ?? "")", to: &out)
            }
        }
        let (layer, stage) = try open(file)
        print("defaultPrim: \(layer.defaultPrim ?? "(none)")", to: &out)
        print("upAxis: \(layer.upAxis ?? "(unset, Y)")", to: &out)
        print("metersPerUnit: \(layer.metersPerUnit.map(NumberFormat.format) ?? "(unset, 0.01)")", to: &out)
        if let tcps = layer.timeCodesPerSecond { print("timeCodesPerSecond: \(NumberFormat.format(tcps))", to: &out) }
        if let s = layer.startTimeCode, let e = layer.endTimeCode {
            print("timeCodes: \(NumberFormat.format(s))…\(NumberFormat.format(e))", to: &out)
        }
        if let doc = layer.documentation { print("doc: \(doc)", to: &out) }
        let primSpecs = layer.allPaths.filter(\.isPrimPath).count
        let propSpecs = layer.allPaths.filter(\.isPropertyPath).count
        print("layer: \(layer.specs.count) specs (\(primSpecs) prims, \(propSpecs) properties)", to: &out)
        let prims = stage.traverse(.all)
        var types: [String: Int] = [:]
        for p in prims { types[p.typeName.isEmpty ? "(typeless)" : p.typeName, default: 0] += 1 }
        print("stage: \(prims.count) prims", to: &out)
        for (t, n) in types.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            print("  \(t): \(n)", to: &out)
        }
        if !layer.subLayers.isEmpty { print("subLayers: \(layer.subLayers.joined(separator: ", "))", to: &out) }
        let deps = LayerIO.assetDependencies(of: layer)
        if !deps.isEmpty {
            print("dependencies:", to: &out)
            for d in deps { print("  \(d)", to: &out) }
        }
        for e in stage.errors { print("composition: \(e)", to: &out) }
        return 0
    }

    // MARK: tree

    static func tree(_ args: [String], out: inout some TextOutputStream) throws -> Int32 {
        let (pos, flags, _) = try split(args, flags: ["--layer", "--all", "--components"])
        guard pos.count == 1 else { throw UsageError(message: "tree takes one file") }
        let (layer, stage) = try open(pos[0])
        let showComponents = flags.contains("--components")
        func describe(_ specifier: Specifier, _ type: String, _ name: String, _ extra: String) -> String {
            specifier.keyword + (type.isEmpty ? "" : " " + type) + " \"" + name + "\"" + extra
        }
        if flags.contains("--layer") {
            func visit(_ path: Path, _ depth: Int) {
                for name in layer.primChildren(of: path) {
                    let p = path.appendingChild(name)
                    let type = layer.field(FieldKey.typeName, at: p)?.stringValue ?? ""
                    if !showComponents, type.hasPrefix("RealityKit") { continue }
                    var specifier = Specifier.over
                    if case .specifier(let s)? = layer.field(FieldKey.specifier, at: p) { specifier = s }
                    print(String(repeating: "  ", count: depth) + describe(specifier, type, name, ""), to: &out)
                    visit(p, depth + 1)
                }
                for set in layer.variantSetNames(of: path) {
                    for v in layer.variantNames(of: path, set: set) {
                        print(String(repeating: "  ", count: depth) + "{\(set)=\(v)}", to: &out)
                        visit(path.appendingVariantSelection(set: set, variant: v), depth + 1)
                    }
                }
            }
            visit(.root, 0)
            return 0
        }
        let options: Stage.TraversalOptions = flags.contains("--all") ? .all : .init()
        func visit(_ prim: Prim, _ depth: Int) {
            for child in prim.children {
                if !options.includeInactive && !child.isActive { continue }
                if !options.includeAbstract && child.specifier == .class { continue }
                if !options.includeUndefined && !child.isDefined { continue }
                if !showComponents, child.typeName.hasPrefix("RealityKit") { continue }
                var extra = ""
                let arcs = Set(child.arcs.dropFirst().map(\.arc))
                if !arcs.isEmpty {
                    extra += "  [" + arcs.sorted().map { String(describing: $0) }.joined(separator: ", ") + "]"
                }
                for set in child.variantSets { extra += "  {\(set.name)=\(set.selection ?? "")}" }
                if !child.isActive { extra += "  (inactive)" }
                let comps = child.children.filter { $0.typeName == RealityKitComponentStorage.componentType }
                    .compactMap { $0.attribute("info:id")?.value()?.stringValue }
                if !comps.isEmpty, !showComponents { extra += "  components: " + comps.joined(separator: ", ") }
                print(String(repeating: "  ", count: depth) + describe(child.specifier, child.typeName, child.name, extra), to: &out)
                visit(child, depth + 1)
            }
        }
        visit(stage.pseudoRoot, 0)
        for e in stage.errors { print("composition: \(e)", to: &out) }
        return 0
    }

    // MARK: cat and convert

    static func cat(_ args: [String], out: inout some TextOutputStream) throws -> Int32 {
        let (pos, flags, _) = try split(args, flags: ["--flatten", "--sorted"])
        guard pos.count == 1 else { throw UsageError(message: "cat takes one file") }
        let (layer, stage) = try open(pos[0])
        let result = flags.contains("--flatten") ? stage.flatten() : layer
        out.write(USDAWriter.write(result, options: .init(sortPropertiesAndVariants: flags.contains("--sorted"))))
        return 0
    }

    static func convert(_ args: [String], out: inout some TextOutputStream) throws -> Int32 {
        let (pos, flags, opts) = try split(args, flags: ["--flatten"], options: ["--format"])
        guard pos.count == 2 else { throw UsageError(message: "convert takes an input and an output") }
        let input = AssetPaths.normalize(absolute(pos[0]))
        let output = pos[1]
        guard let format = opts["--format"].map({ LayerFormat(rawValue: $0) }) ?? LayerFormat(path: output) else {
            throw UsageError(message: "cannot tell the output format; use --format usda|usdc|usdz")
        }
        let (layer, stage) = try open(input)
        var result = flags.contains("--flatten") ? stage.flatten() : layer
        if format == .usdz {
            let rootName = URL(fileURLWithPath: output).deletingPathExtension().lastPathComponent + ".usdc"
            result.identifier = rootName
            var missing: [String] = []
            let assets = try collectAssets(of: result, anchor: input, missing: &missing)
            let bytes = try LayerIO.package(root: result, rootName: rootName, assets: assets).write()
            guard FileManager.default.createFile(atPath: output, contents: Data(bytes)) else { throw USDError("cannot write \(output)") }
            print("wrote \(output) (\(assets.count + 1) entries)", to: &out)
            for m in missing { print("warning: dependency @\(m)@ not found; not packaged", to: &out) }
        } else {
            try LayerIO.write(result, to: output, format: format)
            print("wrote \(output)", to: &out)
        }
        return 0
    }

    /// Files a package needs: relative dependencies of the root layer and,
    /// recursively, of USD layers it references. Paths keep their relative form.
    static func collectAssets(of layer: Layer, anchor: String, missing: inout [String]) throws -> [USDZArchive.Entry] {
        var entries: [USDZArchive.Entry] = []
        var seen: Set<String> = []
        var missingFiles: [String] = []
        func visit(_ l: Layer, anchorFile: String, prefix: String) throws {
            for dep in LayerIO.assetDependencies(of: l) where !dep.hasPrefix("/") && !dep.contains("://") {
                let file = AssetPaths.join(AssetPaths.directory(of: anchorFile), dep)
                let name = AssetPaths.normalize(prefix.isEmpty ? dep : prefix + "/" + dep)
                guard !seen.contains(name), !name.hasPrefix(".."), file != anchor else { continue }
                guard let data = FileManager.default.contents(atPath: file) else {
                    if !missingFiles.contains(dep) { missingFiles.append(dep) }
                    continue
                }
                seen.insert(name)
                entries.append(.init(name: name, data: [UInt8](data)))
                if LayerFormat(path: file) != nil, file.fileExtensionLowercased != "usdz", let inner = try? LayerIO.read([UInt8](data), identifier: file) {
                    try visit(inner, anchorFile: file, prefix: AssetPaths.directory(of: name))
                }
            }
        }
        try visit(layer, anchorFile: anchor, prefix: "")
        missing = missingFiles
        return entries
    }

    // MARK: validate

    static func validate(_ args: [String], out: inout some TextOutputStream) throws -> Int32 {
        let (pos, flags, _) = try split(args, flags: ["--strict"])
        guard pos.count == 1 else { throw UsageError(message: "validate takes one file") }
        let file = pos[0]
        var diagnostics: [SceneDiagnostic] = []
        if let data = FileManager.default.contents(atPath: file), data.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let bytes = [UInt8](data)
            let archive = try USDZArchive.read(bytes)
            if archive.rootLayer == nil {
                diagnostics.append(.init(.error, "usdz", .root, "the first entry is not a USD layer"))
            }
            for (name, offset) in try USDZArchive.dataOffsets(bytes).sorted(by: { $0.key < $1.key }) where offset % 64 != 0 {
                diagnostics.append(.init(.error, "usdz", .root, "entry \(name) data is not 64-byte aligned"))
            }
        }
        let layer: Layer
        let stage: Stage
        do {
            (layer, stage) = try open(file)
        } catch {
            print("error: [load] \(file): \(error)", to: &out)
            return 1
        }
        diagnostics += SceneValidator.validate(layer, stage: stage)
        for d in diagnostics { print(d.description, to: &out) }
        let errors = diagnostics.filter { $0.severity == .error }.count
        let warnings = diagnostics.count - errors
        print("\(errors) error\(errors == 1 ? "" : "s"), \(warnings) warning\(warnings == 1 ? "" : "s")", to: &out)
        return errors > 0 || (flags.contains("--strict") && warnings > 0) ? 1 : 0
    }

    // MARK: edit

    static func edit(_ args: [String], out: inout some TextOutputStream) throws -> Int32 {
        guard let file = args.first, !file.hasPrefix("-") else { throw UsageError(message: "edit takes a file first") }
        let resolver = FileLayerResolver()
        let doc = SceneDocument(layer: try resolver.layer(for: AssetPaths.normalize(absolute(file))), resolver: resolver)
        var output = file
        var i = 1
        func take(_ n: Int, _ op: String) throws -> [String] {
            guard i + n < args.count + 1, i + n <= args.count else { throw UsageError(message: "\(op) needs \(n) argument\(n == 1 ? "" : "s")") }
            defer { i += n }
            return Array(args[i..<(i + n)])
        }
        func path(_ text: String) throws -> Path {
            guard let p = Path(parsing: text), p.isAbsolute else { throw UsageError(message: "'\(text)' is not an absolute path") }
            return p
        }
        func type(_ text: String) throws -> TypeName {
            guard let t = TypeName(text) else { throw UsageError(message: "unknown type '\(text)'") }
            return t
        }
        var operations = 0
        while i < args.count {
            let op = args[i]
            i += 1
            switch op {
            case "-o", "--output":
                output = try take(1, op)[0]
                continue
            case "--add-prim":
                let p = try path(try take(1, op)[0])
                var typeName: String?
                if i < args.count, !args[i].hasPrefix("-") {
                    typeName = args[i]
                    i += 1
                }
                try doc.perform("Add \(p.name)") { layer in try layer.createPrim(at: p, typeName: typeName) }
            case "--remove":
                try doc.delete([try path(try take(1, op)[0])])
            case "--rename":
                let a = try take(2, op)
                try doc.rename(try path(a[0]), to: a[1])
            case "--move":
                let a = try take(2, op)
                try doc.reparent(try path(a[0]), to: try path(a[1]))
            case "--set":
                let a = try take(3, op)
                let t = try type(a[1])
                try doc.setAttribute(try path(a[0]), try USDAReader.parseValue(a[2], type: t), type: t)
            case "--set-sample":
                let a = try take(4, op)
                let t = try type(a[1])
                guard let time = Double(a[2]) else { throw UsageError(message: "bad time '\(a[2])'") }
                try doc.setAttribute(try path(a[0]), try USDAReader.parseValue(a[3], type: t), type: t, time: time)
            case "--meta":
                let a = try take(3, op)
                try doc.setMetadata(try path(a[0]), a[1], try USDAReader.parseMetadataValue(a[2], field: a[1]))
            case "--translate":
                let a = try take(4, op)
                let p = try path(a[0])
                let v = a[1...].compactMap(Double.init)
                guard v.count == 3 else { throw UsageError(message: "--translate needs three numbers") }
                var trs = TRS(matrix: doc.localTransform(p))
                trs.translation = Vec3(v[0], v[1], v[2])
                try doc.setTransform(p, trs)
            case "--reference":
                let a = try take(3, op)
                try doc.addReference(named: a[1], asset: a[2], under: try path(a[0]))
            case "--add-component":
                let a = try take(2, op)
                try doc.addComponent(a[1], to: try path(a[0]))
            case "--bind":
                let a = try take(2, op)
                try doc.bindMaterial(try path(a[0]), to: try path(a[1]))
            case "--default-prim":
                let name = try take(1, op)[0]
                try doc.perform("Default Prim") { layer in layer.defaultPrim = name }
            default:
                throw UsageError(message: "unknown edit operation '\(op)'")
            }
            operations += 1
        }
        guard operations > 0 else { throw UsageError(message: "no edit operations given") }
        try doc.save(to: output)
        print("\(operations) edit\(operations == 1 ? "" : "s") written to \(output)", to: &out)
        return 0
    }
}

/// Writes to a file handle as a text stream.
struct FileHandleOutput: TextOutputStream {
    let handle: FileHandle

    mutating func write(_ string: String) {
        handle.write(Data(string.utf8))
    }
}

extension String {
    var fileExtensionLowercased: String {
        URL(fileURLWithPath: self).pathExtension.lowercased()
    }
}
