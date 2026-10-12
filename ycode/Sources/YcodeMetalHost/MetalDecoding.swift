// Decoders for the fixed records and keyed descriptors of the Metal host
// protocol (metal-sim-protocol.md §2.4, §4.2, §5, §7). Records are packed:
// fields follow each other with no padding (a u64 may sit at any multiple
// of 4; the 185 892-byte upload of §5.3 = 8 + 84 + pixels confirms it).

import Foundation

/// A malformed record or descriptor.
public enum MetalDecodeError: Error, Equatable, Sendable, CustomStringConvertible {
    case truncated(need: Int, have: Int)
    case badRecordLength(op: UInt32, length: UInt32, available: Int)
    case badPayload(String)

    public var description: String {
        switch self {
        case let .truncated(need, have): "truncated: need \(need) bytes, have \(have)"
        case let .badRecordLength(op, length, available): "record op \(op) length \(length) with \(available) bytes available"
        case let .badPayload(why): "bad payload: \(why)"
        }
    }
}

/// A little-endian reader over a byte slice.
struct ByteReader {
    let bytes: [UInt8]
    var offset: Int
    let end: Int

    init(_ bytes: [UInt8], from: Int = 0, to: Int? = nil) {
        self.bytes = bytes
        offset = from
        end = min(to ?? bytes.count, bytes.count)
    }

    var remaining: Int { end - offset }

    mutating func need(_ n: Int) throws {
        guard n >= 0, n <= end - offset else { throw MetalDecodeError.truncated(need: n, have: max(0, end - offset)) }
    }

    mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        try need(4)
        defer { offset += 4 }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * UInt32(i)) }
        return v
    }

    mutating func u64() throws -> UInt64 {
        let lo = UInt64(try u32())
        return lo | UInt64(try u32()) << 32
    }

    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }
    mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

    /// A u64 as an Int (saturating).
    mutating func int64() throws -> Int { let v = try u64(); return v > UInt64(Int.max) ? Int.max : Int(v) }
    mutating func int32() throws -> Int { Int(try u32()) }
    mutating func int16() throws -> Int { Int(try u16()) }

    mutating func take(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }

    mutating func rest() -> [UInt8] {
        defer { offset = end }
        return offset < end ? Array(bytes[offset..<end]) : []
    }
}

/// A little-endian writer for replies and tests.
struct MetalByteWriter {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { bytes += [UInt8(v & 0xFF), UInt8(v >> 8)] }
    public mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    public mutating func u64(_ v: UInt64) { u32(UInt32(truncatingIfNeeded: v)); u32(UInt32(truncatingIfNeeded: v >> 32)) }
    public mutating func f32(_ v: Float) { u32(v.bitPattern) }
    public mutating func f64(_ v: Double) { u64(v.bitPattern) }
    public mutating func append(_ b: [UInt8]) { bytes += b }
    public mutating func pad(to n: Int) { while bytes.count < n { bytes.append(0) } }

    /// A record: u32 op, u32 total length, body.
    public static func record(_ op: UInt32, _ body: [UInt8]) -> [UInt8] {
        var w = MetalByteWriter()
        w.u32(op)
        w.u32(UInt32(8 + body.count))
        w.append(body)
        return w.bytes
    }
}

/// One record (u32 opcode, u32 total length, body).
public struct MetalRecord: Equatable, Sendable {
    public var op: UInt32
    public var body: [UInt8]
    public init(op: UInt32, body: [UInt8]) { self.op = op; self.body = body }

    /// The single record of a `command` value. Bytes after the record's
    /// length are ignored; a length beyond the data is an error.
    public static func parse(_ data: [UInt8]) throws -> MetalRecord {
        guard data.count >= 8 else { throw MetalDecodeError.truncated(need: 8, have: data.count) }
        var r = ByteReader(data)
        let op = try r.u32()
        let length = try r.u32()
        guard length >= 8, Int(length) <= data.count else {
            throw MetalDecodeError.badRecordLength(op: op, length: length, available: data.count)
        }
        return MetalRecord(op: op, body: Array(data[8..<Int(length)]))
    }
}

// MARK: Fixed descriptors (§5)

enum MetalDescriptorCodec {
    /// Texture descriptor words 0–8 (spec §5.2), from the reader's position.
    static func texture(_ r: inout ByteReader) throws -> MetalTextureDescriptor {
        _ = try r.u32()  // word 0: 0
        let w1 = try r.u32()
        let width = try r.int32(), height = try r.int32(), depth = try r.int32()
        let levels = try r.int16(), samples = try r.int16()
        let arrayLength = try r.int16()
        let options = try r.u16()
        let reserved = try r.u64()
        return MetalTextureDescriptor(textureType: UInt8(w1 & 0xF), pixelFormat: w1 >> 16, width: width, height: height,
                                      depth: depth, mipmapLevelCount: levels, sampleCount: samples, arrayLength: arrayLength,
                                      usage: UInt16((w1 >> 8) & 0xFF), resourceOptions: options,
                                      allowGPUOptimizedContents: w1 & 0x40 != 0, flags: UInt8((w1 >> 4) & 0x3),
                                      reserved: reserved)
    }

    static func encodeTexture(_ d: MetalTextureDescriptor, into w: inout MetalByteWriter) {
        w.u32(0)
        w.u32(UInt32(d.textureType & 0xF) | UInt32(d.flags & 3) << 4 | (d.allowGPUOptimizedContents ? 0x40 : 0)
            | UInt32(d.usage & 0xFF) << 8 | d.pixelFormat << 16)
        w.u32(UInt32(d.width)); w.u32(UInt32(d.height)); w.u32(UInt32(d.depth))
        w.u16(UInt16(d.mipmapLevelCount)); w.u16(UInt16(d.sampleCount))
        w.u16(UInt16(d.arrayLength)); w.u16(d.resourceOptions)
        w.u64(d.reserved)
    }

    /// Sampler body (spec §5.5, 28 bytes).
    static func sampler(_ body: [UInt8]) throws -> MetalSamplerDescriptor {
        var r = ByteReader(body)
        _ = try r.u32()
        let p = try r.u32()
        let flags = try r.u32()
        var d = MetalSamplerDescriptor()
        d.minFilter = UInt8(p & 3)
        d.magFilter = UInt8((p >> 2) & 3)
        d.bit4 = p & 0x10 != 0
        d.compareFunction = UInt8((p >> 5) & 7)
        d.sAddressMode = UInt8((p >> 8) & 0xF)
        d.tAddressMode = UInt8((p >> 12) & 0xF)
        d.rAddressMode = UInt8((p >> 16) & 0xF)
        d.borderColor = UInt8((p >> 20) & 0xF)
        d.mipFilter = UInt8((p >> 24) & 3)
        d.maxAnisotropy = UInt8((p >> 26) & 0x1F)
        d.normalizedCoordinates = p & 0x8000_0000 != 0
        d.supportArgumentBuffers = flags & 1 != 0
        d.lodMinClamp = try r.f32()
        d.lodMaxClamp = try r.f32()
        return d
    }

    static func encodeSampler(_ d: MetalSamplerDescriptor) -> [UInt8] {
        var w = MetalByteWriter()
        w.u32(0)
        var p = UInt32(d.minFilter & 3) | UInt32(d.magFilter & 3) << 2 | (d.bit4 ? 0x10 : 0) | UInt32(d.compareFunction & 7) << 5
        p |= UInt32(d.sAddressMode & 0xF) << 8 | UInt32(d.tAddressMode & 0xF) << 12 | UInt32(d.rAddressMode & 0xF) << 16
        p |= UInt32(d.borderColor & 0xF) << 20 | UInt32(d.mipFilter & 3) << 24 | UInt32(d.maxAnisotropy & 0x1F) << 26
        p |= d.normalizedCoordinates ? 0x8000_0000 : 0
        w.u32(p)
        w.u32(d.supportArgumentBuffers ? 1 : 0)
        w.f32(d.lodMinClamp)
        w.f32(d.lodMaxClamp)
        w.u64(0)
        return w.bytes
    }

    /// Depth-stencil body (spec §5.6, 32 bytes).
    static func depthStencil(_ body: [UInt8]) throws -> MetalDepthStencilDescriptor {
        var r = ByteReader(body)
        _ = try r.u32()
        let bits = try r.u32()
        func stencil() throws -> MetalStencilDescriptor {
            let s = try r.u32()
            let read = try r.u32(), write = try r.u32()
            return MetalStencilDescriptor(compareFunction: UInt8(s & 7), stencilFailureOperation: UInt8((s >> 3) & 7),
                                          depthFailureOperation: UInt8((s >> 6) & 7),
                                          depthStencilPassOperation: UInt8((s >> 9) & 7), readMask: read, writeMask: write)
        }
        var d = MetalDepthStencilDescriptor()
        d.depthCompareFunction = UInt8(bits & 7)
        d.depthWriteEnabled = bits & 8 != 0
        let front = try stencil(), back = try stencil()
        if bits & 0x10 != 0 { d.frontFaceStencil = front }
        if bits & 0x20 != 0 { d.backFaceStencil = back }
        return d
    }

    static func encodeDepthStencil(_ d: MetalDepthStencilDescriptor) -> [UInt8] {
        var w = MetalByteWriter()
        w.u32(0)
        w.u32(UInt32(d.depthCompareFunction & 7) | (d.depthWriteEnabled ? 8 : 0) | (d.frontFaceStencil != nil ? 0x10 : 0)
            | (d.backFaceStencil != nil ? 0x20 : 0))
        for s in [d.frontFaceStencil, d.backFaceStencil] {
            if let s {
                w.u32(UInt32(s.compareFunction & 7) | UInt32(s.stencilFailureOperation & 7) << 3
                    | UInt32(s.depthFailureOperation & 7) << 6 | UInt32(s.depthStencilPassOperation & 7) << 9)
                w.u32(s.readMask); w.u32(s.writeMask)
            } else {
                w.u32(0); w.u32(0); w.u32(0)
            }
        }
        return w.bytes
    }

    /// The region/level/slice/rows head of ops 2 and 5 (spec §5.3): u32
    /// texture ref, u64 × 3 origin, u64 × 3 size, u64 level, u64 slice,
    /// u64 bytes per row, u64 bytes per image (84 bytes).
    struct RegionHead: Equatable {
        var texture: UInt32
        var region: MetalRegion
        var level: Int, slice: Int, bytesPerRow: Int, bytesPerImage: Int
    }

    static func regionHead(_ r: inout ByteReader) throws -> RegionHead {
        let t = try r.u32()
        let x = try r.int64(), y = try r.int64(), z = try r.int64()
        let w = try r.int64(), h = try r.int64(), d = try r.int64()
        let level = try r.int64(), slice = try r.int64(), bpr = try r.int64(), bpi = try r.int64()
        return RegionHead(texture: t, region: MetalRegion(x: x, y: y, z: z, width: w, height: h, depth: d), level: level,
                          slice: slice, bytesPerRow: bpr, bytesPerImage: bpi)
    }

    static func encodeRegionHead(_ h: RegionHead, into w: inout MetalByteWriter) {
        w.u32(h.texture)
        for v in [h.region.x, h.region.y, h.region.z, h.region.width, h.region.height, h.region.depth, h.level, h.slice,
                  h.bytesPerRow, h.bytesPerImage] { w.u64(UInt64(v)) }
    }
}

// MARK: Keyed descriptors (§7)

/// One object of a keyed payload: u8 field count, then (u8 key, u8 type,
/// value) fields; the type is the value's size in bytes (4 is the only one
/// seen; 1, 2 and 8 are accepted).
struct KeyedObject {
    var fields: [(key: UInt8, value: UInt64)] = []
    /// The offset just after the fields.
    var end: Int

    subscript(key: UInt8) -> UInt64? { fields.first { $0.key == key }?.value }

    static func parse(_ p: [UInt8], at offset: Int) throws -> KeyedObject {
        var r = ByteReader(p, from: offset)
        let n = Int(try r.u8())
        var fields: [(UInt8, UInt64)] = []
        for _ in 0..<n {
            let key = try r.u8(), type = try r.u8()
            let value: UInt64
            switch type {
            case 1: value = UInt64(try r.u8())
            case 2: value = UInt64(try r.u16())
            case 4: value = UInt64(try r.u32())
            case 8: value = try r.u64()
            default: throw MetalDecodeError.badPayload("key \(key) has unknown type \(type) at \(r.offset - 2)")
            }
            fields.append((key, value))
        }
        return KeyedObject(fields: fields, end: r.offset)
    }

    /// An array at `offset`: u32 count, u32 element offsets relative to
    /// the array, the elements (objects).
    static func array(_ p: [UInt8], at offset: Int) throws -> [(object: KeyedObject, offset: Int)] {
        var r = ByteReader(p, from: offset)
        let count = Int(try r.u32())
        guard count <= 256 else { throw MetalDecodeError.badPayload("array of \(count) elements at \(offset)") }
        var out: [(KeyedObject, Int)] = []
        for _ in 0..<count {
            let at = offset + Int(try r.u32())
            guard at < p.count else { throw MetalDecodeError.badPayload("array element offset \(at) beyond payload") }
            out.append((try parse(p, at: at), at))
        }
        return out
    }
}

enum MetalPipelineCodec {
    /// The keyed payload of ops 11 and 14: u32 0, u32 payload length, payload.
    static func payload(_ body: [UInt8]) throws -> [UInt8] {
        var r = ByteReader(body)
        _ = try r.u32()
        let length = Int(try r.u32())
        return try r.take(length)
    }

    /// Op 14 (spec §7.2). `function` maps a guest function ref to a handle.
    static func renderPipeline(_ p: [UInt8], function: (UInt32) -> MetalHandle?) throws -> MetalRenderPipelineDescriptor {
        let top = try KeyedObject.parse(p, at: 0)
        var d = MetalRenderPipelineDescriptor()
        for (key, v) in top.fields {
            switch key {
            case 0:
                let at = Int(v)
                guard at < p.count else { throw MetalDecodeError.badPayload("label offset \(at)") }
                let end = p[at...].firstIndex(of: 0) ?? p.count
                d.label = String(decoding: p[at..<end], as: UTF8.self)
            case 1: d.fragmentFunction = v == 0 ? nil : function(UInt32(truncatingIfNeeded: v))
            case 2: d.vertexFunction = v == 0 ? nil : function(UInt32(truncatingIfNeeded: v))
            case 3: d.vertexDescriptor = try vertexDescriptor(p, at: Int(v))
            case 4: d.rasterSampleCount = Int(v)
            case 5: d.alphaToCoverageEnabled = v != 0
            case 8:
                for (o, _) in try KeyedObject.array(p, at: Int(v)) {
                    var c = MetalColorAttachmentDescriptor(index: Int(o[0] ?? 0))
                    if let x = o[1] { c.pixelFormat = UInt32(truncatingIfNeeded: x) }
                    if let x = o[2] { c.blendingEnabled = x != 0 }
                    if let x = o[3] { c.sourceRGBBlendFactor = UInt32(truncatingIfNeeded: x) }
                    if let x = o[4] { c.destinationRGBBlendFactor = UInt32(truncatingIfNeeded: x) }
                    if let x = o[5] { c.rgbBlendOperation = UInt32(truncatingIfNeeded: x) }
                    if let x = o[6] { c.sourceAlphaBlendFactor = UInt32(truncatingIfNeeded: x) }
                    if let x = o[7] { c.destinationAlphaBlendFactor = UInt32(truncatingIfNeeded: x) }
                    if let x = o[8] { c.alphaBlendOperation = UInt32(truncatingIfNeeded: x) }
                    if let x = o[9] { c.writeMask = UInt32(truncatingIfNeeded: x) }
                    d.colorAttachments.append(c)
                }
            case 9: d.depthAttachmentPixelFormat = UInt32(truncatingIfNeeded: v)
            case 10: d.stencilAttachmentPixelFormat = UInt32(truncatingIfNeeded: v)
            case 11: d.inputPrimitiveTopology = UInt32(truncatingIfNeeded: v)
            default: d.unknownKeys[key] = v
            }
        }
        return d
    }

    /// The vertex descriptor object at `offset`: key 0 attribute array, key
    /// 1 layout array, both relative to the object.
    static func vertexDescriptor(_ p: [UInt8], at offset: Int) throws -> MetalVertexDescriptor {
        guard offset < p.count else { throw MetalDecodeError.badPayload("vertex descriptor offset \(offset)") }
        let o = try KeyedObject.parse(p, at: offset)
        var vd = MetalVertexDescriptor()
        if let a = o[0] {
            for (e, _) in try KeyedObject.array(p, at: offset + Int(a)) {
                var attr = MetalVertexDescriptor.Attribute(index: Int(e[0] ?? 0))
                if let x = e[1] { attr.format = UInt32(truncatingIfNeeded: x) }
                if let x = e[2] { attr.offset = Int(x) }
                if let x = e[3] { attr.bufferIndex = Int(x) }
                vd.attributes.append(attr)
            }
        }
        if let l = o[1] {
            for (e, _) in try KeyedObject.array(p, at: offset + Int(l)) {
                var layout = MetalVertexDescriptor.Layout(bufferIndex: Int(e[0] ?? 0))
                if let x = e[1] { layout.stepFunction = UInt32(truncatingIfNeeded: x) }
                if let x = e[2] { layout.stepRate = Int(x) }
                if let x = e[3] { layout.stride = Int(x) }
                vd.layouts.append(layout)
            }
        }
        return vd
    }

    /// Op 11 (spec §7.3): key 0 = function ref.
    static func computeFunctionRef(_ p: [UInt8]) throws -> UInt32 {
        let o = try KeyedObject.parse(p, at: 0)
        guard let f = o[0] else { throw MetalDecodeError.badPayload("compute pipeline without a function") }
        return UInt32(truncatingIfNeeded: f)
    }
}

/// Builds keyed payloads (tests, and a reference for the layout).
struct MetalKeyedPayloadBuilder {
    public init() {}

    /// An object: u8 count, (key, 4, u32) fields.
    public static func object(_ fields: [(UInt8, UInt32)]) -> [UInt8] {
        var w = MetalByteWriter()
        w.u8(UInt8(fields.count))
        for (k, v) in fields { w.u8(k); w.u8(4); w.u32(v) }
        return w.bytes
    }

    static func align4(_ b: inout [UInt8]) { while b.count % 4 != 0 { b.append(0) } }

    /// An array of objects: u32 count, u32 offsets (relative to the array), elements at 4-aligned offsets.
    public static func array(_ elements: [[UInt8]]) -> [UInt8] {
        var head = MetalByteWriter()
        head.u32(UInt32(elements.count))
        let offset = 4 + 4 * elements.count
        var body: [UInt8] = []
        for e in elements {
            head.u32(UInt32(offset + body.count))
            body += e
            align4(&body)
        }
        return head.bytes + body
    }

    /// A render pipeline payload. `nested` is placed after the top-level
    /// object and label at 4-aligned offsets; each closure gets the offset
    /// its element will have and returns the top-level (key, value) to add.
    public static func renderPipeline(top: [(UInt8, UInt32)], label: String? = nil,
                                      colorAttachments: [[(UInt8, UInt32)]] = [],
                                      vertexAttributes: [[(UInt8, UInt32)]]? = nil,
                                      vertexLayouts: [[(UInt8, UInt32)]]? = nil) -> [UInt8] {
        // Field count is known in advance: top + label + color array + vertex descriptor.
        let extra = (label != nil ? 1 : 0) + (colorAttachments.isEmpty ? 0 : 1) + (vertexAttributes != nil ? 1 : 0)
        let topSize = 1 + 6 * (top.count + extra)
        var tail: [UInt8] = []
        var fields = top
        // The label (or a single NUL) follows the top-level fields.
        let labelBytes = Array((label ?? "").utf8) + [0]
        let labelOffset = topSize
        tail += labelBytes
        func place(_ b: [UInt8]) -> Int {
            align4(&tail)
            let at = topSize + tail.count
            tail += b
            return at
        }
        if label != nil { fields.insert((0, UInt32(labelOffset)), at: 0) }
        if let attrs = vertexAttributes {
            // Vertex descriptor object, then its arrays (offsets relative to it).
            let vdHeader = 1 + 6 * 2
            var vdTail: [UInt8] = []
            func vdPlace(_ b: [UInt8]) -> Int {
                while (vdHeader + vdTail.count) % 4 != 0 { vdTail.append(0) }
                let at = vdHeader + vdTail.count
                vdTail += b
                return at
            }
            let a = vdPlace(array(attrs.map(object)))
            let l = vdPlace(array((vertexLayouts ?? []).map(object)))
            let vd = object([(0, UInt32(a)), (1, UInt32(l))]) + vdTail
            fields.append((3, UInt32(place(vd))))
        }
        if !colorAttachments.isEmpty {
            fields.append((8, UInt32(place(array(colorAttachments.map(object))))))
        }
        return object(fields.sorted { $0.0 < $1.0 }) + tail
    }
}
