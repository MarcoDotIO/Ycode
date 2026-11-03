import Foundation

/// The on-disk USD formats.
public enum LayerFormat: String, Sendable, CaseIterable {
    case usda, usdc, usdz

    /// The format named by a path's extension (`.usd` is sniffed when read).
    public init?(path: String) {
        switch path.fileExtension {
        case "usda": self = .usda
        case "usdc", "usd": self = .usdc
        case "usdz": self = .usdz
        default: return nil
        }
    }
}

/// Reading and writing layers from files and bytes.
public enum LayerIO {
    /// Reads a layer from bytes. `.usd` data may be text or crate; a USDZ
    /// archive yields its root layer.
    public static func read(_ bytes: [UInt8], identifier: String) throws -> Layer {
        if USDCReader.isCrate(bytes) { return try USDCReader.read(bytes, identifier: identifier) }
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04]) {
            let archive = try USDZArchive.read(bytes)
            guard let root = archive.rootLayer else { throw USDError("usdz: the first entry is not a USD layer") }
            return try read(root.data, identifier: identifier + "[" + root.name + "]")
        }
        guard bytes.starts(with: Array("#usda".utf8)) else { throw USDError("\(identifier): not a USD file") }
        return try USDAReader.read(String(decoding: bytes, as: UTF8.self), identifier: identifier)
    }

    public static func read(contentsOf path: String) throws -> Layer {
        guard let data = FileManager.default.contents(atPath: path) else { throw USDError("cannot read \(path)") }
        return try read([UInt8](data), identifier: path)
    }

    /// Serializes a layer. For `.usdz` the archive holds just the root layer
    /// (as crate data, named `rootName`); use `package` to add assets.
    public static func data(for layer: Layer, format: LayerFormat, rootName: String = "root.usdc") throws -> [UInt8] {
        switch format {
        case .usda: return Array(USDAWriter.write(layer).utf8)
        case .usdc: return try USDCWriter.write(layer)
        case .usdz: return try package(root: layer, rootName: rootName, assets: []).write()
        }
    }

    public static func write(_ layer: Layer, to path: String, format: LayerFormat? = nil) throws {
        guard let format = format ?? LayerFormat(path: path) else { throw USDError("unknown USD format for \(path)") }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".usdc"
        let bytes = try data(for: layer, format: format, rootName: name)
        guard FileManager.default.createFile(atPath: path, contents: Data(bytes)) else { throw USDError("cannot write \(path)") }
    }

    /// Builds a USDZ archive: the root layer first, then the assets in order.
    public static func package(root: Layer, rootName: String, assets: [USDZArchive.Entry]) throws -> USDZArchive {
        let format = LayerFormat(path: rootName) ?? .usdc
        let rootData = format == .usda ? Array(USDAWriter.write(root).utf8) : try USDCWriter.write(root)
        return USDZArchive(entries: [USDZArchive.Entry(name: rootName, data: rootData)] + assets)
    }

    /// Relative asset paths a layer depends on: sublayers, references,
    /// payloads and asset-valued attributes (including time samples).
    public static func assetDependencies(of layer: Layer) -> [String] {
        var found: [String] = []
        func add(_ s: String) {
            if !s.isEmpty, !found.contains(s) { found.append(s) }
        }
        func scan(_ v: Value) {
            switch v {
            case .scalar(.asset, .strings(let a)), .array(.asset, .strings(let a)): a.forEach(add)
            case .referenceListOp(let op): op.allItems.forEach { add($0.assetPath) }
            case .payloadListOp(let op): op.allItems.forEach { add($0.assetPath) }
            case .payload(let p): add(p.assetPath)
            case .timeSamples(let samples): samples.forEach { scan($0.value) }
            case .dictionary(let d): d.values.forEach(scan)
            default: break
            }
        }
        layer.subLayers.forEach(add)
        for path in layer.allPaths {
            for value in Array(layer.spec(at: path)?.fields.values ?? [:].values) { scan(value) }
        }
        return found
    }
}
