import Foundation

/// Reads an `Assets.car` (`specs/formats/assets-car.md`): the CoreUI blocks,
/// the facets, appearances and every rendition, decoding the payloads Ycode
/// writes. Other kinds come back as raw records.
public struct CARFile: Sendable {
    public struct FormatError: Error, CustomStringConvertible {
        public var message: String
        public var description: String { "Assets.car: \(message)" }
    }

    public struct Header: Equatable, Sendable {
        public var coreUIVersion: UInt32
        public var storageVersion: UInt32
        public var renditionCount: UInt32
        public var mainVersion: String
        public var versionString: String
        public var schemaVersion: UInt32
        public var colorSpaceID: UInt32
        public var keySemantics: UInt32
    }

    public struct Metadata: Equatable, Sendable {
        public var thinningArguments: String
        public var deploymentTarget: String
        public var platform: String
        public var authoringTool: String
    }

    public struct Facet: Equatable, Sendable {
        public var name: String
        public var attributes: [(CARAttribute?, UInt16)]
        public var part: UInt16? { attributes.first { $0.0 == .part }?.1 }
        public var identifier: UInt16? { attributes.first { $0.0 == .identifier }?.1 }
        public static func == (a: Facet, b: Facet) -> Bool {
            a.name == b.name && a.attributes.map(\.1) == b.attributes.map(\.1) && a.attributes.map(\.0) == b.attributes.map(\.0)
        }
    }

    public enum Payload: Equatable, Sendable {
        case bitmap(Bitmap, compression: UInt32, version: UInt32, chunks: [Int])
        case color(CARColor)
        case multisize([CARMultisizeEntry])
        case rawData(flags: UInt32, bytes: [UInt8])
        case other(tag: String, bytes: Int)
        case empty
    }

    public struct Rendition: Sendable {
        public var key: [CARAttribute: UInt16]
        public var keyValues: [UInt16]
        public var flags: UInt32
        public var width: UInt32
        public var height: UInt32
        public var scale: UInt32
        public var pixelFormat: String
        public var colorSpace: UInt32
        public var layout: UInt16
        public var name: String
        public var tlvs: [(type: UInt32, bytes: [UInt8])]
        public var payload: Payload
        public var payloadLength: Int

        public var part: UInt16 { key[.part] ?? 0 }
        public var identifier: UInt16 { key[.identifier] ?? 0 }
    }

    public var header: Header
    public var metadata: Metadata?
    public var keyFormat: [UInt32]
    public var facets: [Facet]
    public var appearances: [(name: String, number: UInt16)]
    public var renditions: [Rendition]
    /// Problems in the container that a strict reader would trip over (keys
    /// missing from fixed-key leaves, unsorted entries, a count mismatch).
    public var structureIssues: [String]
    public var variables: [String]

    public init(contentsOf url: URL) throws { try self.init(data: try Data(contentsOf: url)) }

    public init(data: Data) throws {
        let bom = try BOMReader(data)
        variables = bom.variables.map(\.name)
        guard let hb = bom.variable("CARHEADER") else { throw FormatError(message: "no CARHEADER") }
        var h = ByteReader(Array(try bom.block(hb)))
        guard try h.tag() == "RATC" else { throw FormatError(message: "CARHEADER tag") }
        let coreUI = try h.u32le(), storage = try h.u32le()
        _ = try h.u32le()
        let count = try h.u32le()
        let main = try h.padded(128), version = try h.padded(256)
        _ = try h.take(16)
        _ = try h.u32le()
        header = Header(coreUIVersion: coreUI, storageVersion: storage, renditionCount: count, mainVersion: main, versionString: version,
                        schemaVersion: try h.u32le(), colorSpaceID: try h.u32le(), keySemantics: try h.u32le())
        if let mb = bom.variable("EXTENDED_METADATA") {
            var m = ByteReader(Array(try bom.block(mb)))
            if try m.tag() == "META" {
                metadata = Metadata(thinningArguments: try m.padded(256), deploymentTarget: try m.padded(256),
                                    platform: try m.padded(256), authoringTool: try m.padded(256))
            }
        }
        guard let kb = bom.variable("KEYFORMAT") else { throw FormatError(message: "no KEYFORMAT") }
        var k = ByteReader(Array(try bom.block(kb)))
        guard try k.tag() == "tmfk" else { throw FormatError(message: "KEYFORMAT tag") }
        _ = try k.u32le()
        let n = Int(try k.u32le())
        keyFormat = try (0..<n).map { _ in try k.u32le() }

        var issues: [String] = []
        facets = []
        if bom.variable("FACETKEYS") != nil {
            for e in try bom.tree("FACETKEYS") {
                var r = ByteReader(e.value)
                _ = try r.u16le()
                _ = try r.u16le()
                let pairs = Int(try r.u16le())
                let attrs = try (0..<pairs).map { _ in (CARAttribute(rawValue: UInt32(try r.u16le())), try r.u16le()) }
                facets.append(Facet(name: String(decoding: e.key, as: UTF8.self), attributes: attrs))
            }
        }
        appearances = []
        if bom.variable("APPEARANCEKEYS") != nil {
            for e in try bom.tree("APPEARANCEKEYS") {
                appearances.append((String(decoding: e.key, as: UTF8.self), e.value.u16le(at: 0)))
            }
        }
        renditions = []
        let format = keyFormat.map { CARAttribute(rawValue: $0) }
        let info = try bom.treeInfo("RENDITIONS")
        let rendEntries = try bom.tree("RENDITIONS")
        if info.pathCount != UInt32(rendEntries.count) { issues.append("RENDITIONS path count \(info.pathCount) but \(rendEntries.count) entries") }
        if info.keyLength != 0xFFFF_FFFF, !info.inlineKeys {
            for leaf in try bom.leaves("RENDITIONS") {
                for (j, e) in leaf.entries.enumerated() {
                    let real = Array(try bom.block(e.key))
                    if j >= leaf.keyCopies.count || leaf.keyCopies[j] != real {
                        issues.append("RENDITIONS leaf \(leaf.block) entry \(j): key copy missing or different")
                        break
                    }
                }
            }
        }
        var previous: [UInt8]?
        for e in rendEntries {
            let values = stride(from: 0, to: e.key.count - 1, by: 2).map { e.key.u16le(at: $0) }
            // Ascending by the stored bytes, the order the runtime searches.
            if let p = previous, !p.lexicographicallyPrecedes(e.key) { issues.append("RENDITIONS keys not ascending (as bytes) at \(values)") }
            previous = e.key
            var key: [CARAttribute: UInt16] = [:]
            for (i, v) in values.enumerated() where i < format.count { if let a = format[i] { key[a] = v } }
            renditions.append(try Self.csi(e.value, key: key, values: values))
        }
        if header.renditionCount != UInt32(renditions.count) { issues.append("CARHEADER rendition count \(header.renditionCount) but \(renditions.count) renditions") }
        let all = renditions
        for f in facets where !all.contains(where: { $0.identifier == f.identifier }) {
            issues.append("facet \(f.name) has no rendition")
        }
        structureIssues = issues
    }

    static func csi(_ b: [UInt8], key: [CARAttribute: UInt16], values: [UInt16]) throws -> Rendition {
        var r = ByteReader(b)
        guard try r.tag() == "ISTC" else { throw FormatError(message: "rendition without an ISTC header") }
        _ = try r.u32le()
        let flags = try r.u32le(), width = try r.u32le(), height = try r.u32le(), scale = try r.u32le()
        let pf = String(decoding: try r.take(4), as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        let cs = try r.u32le()
        _ = try r.u32le()
        let layout = try r.u16le()
        _ = try r.u16le()
        let name = try r.padded(128)
        let tlvLength = Int(try r.u32le())
        _ = try r.u32le()
        _ = try r.u32le()
        let payloadLength = Int(try r.u32le())
        var t = ByteReader(Array(try r.take(tlvLength)))
        var tlvs: [(UInt32, [UInt8])] = []
        while t.remaining >= 8 {
            let type = try t.u32le(), len = Int(try t.u32le())
            tlvs.append((type, Array(try t.take(len))))
        }
        let body = Array(try r.take(payloadLength))
        return Rendition(key: key, keyValues: values, flags: flags, width: width, height: height, scale: scale, pixelFormat: pf,
                         colorSpace: cs, layout: layout, name: name, tlvs: tlvs,
                         payload: try payload(body, width: Int(width), height: Int(height)), payloadLength: payloadLength)
    }

    static func payload(_ b: [UInt8], width: Int, height: Int) throws -> Payload {
        guard b.count >= 4 else { return .empty }
        var r = ByteReader(b)
        let tag = try r.tag()
        switch tag {
        case "MLEC":
            let version = try r.u32le(), comp = try r.u32le(), n = try r.u32le()
            let rowBytes = width * 4
            var pixels: [UInt8] = []
            var chunks: [Int] = []
            switch comp {
            case 0:
                pixels = Array(try r.take(Int(n)))
            case 4:
                for _ in 0..<n {
                    guard try r.tag() == "KCBC" else { throw FormatError(message: "KCBC chunk expected") }
                    _ = try r.u32le()
                    _ = try r.u32le()
                    let rows = Int(try r.u32le()), len = Int(try r.u32le())
                    pixels += try LZFSE.decode(try r.take(len), expectedSize: rows * rowBytes)
                    chunks.append(rows)
                }
            default:
                return .other(tag: "MLEC compression \(comp)", bytes: b.count)
            }
            guard pixels.count == rowBytes * height else { throw FormatError(message: "pixel data is \(pixels.count) bytes, expected \(rowBytes * height)") }
            return .bitmap(Bitmap(width: width, height: height, premultipliedBGRA: pixels), compression: comp, version: version, chunks: chunks)
        case "RLOC":
            _ = try r.u32le()
            let info = try r.u32le(), n = Int(try r.u32le())
            return .color(CARColor(colorSpace: UInt8(info & 0xFF), components: try (0..<n).map { _ in try r.f64le() }))
        case "SISM":
            _ = try r.u32le()
            let n = Int(try r.u32le())
            return .multisize(try (0..<n).map { _ in
                CARMultisizeEntry(width: try r.u32le(), height: try r.u32le(), index: UInt16(truncatingIfNeeded: try r.u32le()))
            })
        case "DWAR":
            let flags = try r.u32le(), n = Int(try r.u32le())
            let raw = Array(try r.take(n))
            return .rawData(flags: flags, bytes: flags == 1 ? try LZFSE.decode(raw[...]) : raw)
        default:
            return .other(tag: tag, bytes: b.count)
        }
    }

    /// The facet (asset) name for a rendition's identifier.
    public func facetName(for r: Rendition) -> String? { facets.first { $0.identifier == r.identifier }?.name }

    /// The appearance name for a number.
    public func appearanceName(_ n: UInt16) -> String? { appearances.first { $0.number == n }?.name }
}
