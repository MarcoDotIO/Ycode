// Argument-buffer layouts (metal-sim-protocol.md §4.3): the description that
// device op 16 carries, parsed into a table from argument index to the
// member's byte offset, kind and size, plus the encoder's encoded length and
// alignment (op 17's reply). Argument ids are names, not positions: the
// description gives every member's offset within its enclosing struct, and
// nested structs and arrays add their own offsets and indices (§4.3.2).

import Foundation

/// One argument-buffer layout: argument index → member, the encoded length
/// and the alignment.
struct MetalArgumentLayout: Equatable, Sendable {
    /// A member's kind (the argument record's low five bits, §4.3.1).
    enum Kind: UInt8, Sendable {
        case constantBuffer = 1, deviceBuffer = 2, texture = 4, sampler = 5, inlineData = 8

        var isResource: Bool { self != .inlineData }
    }

    struct Member: Equatable, Sendable {
        /// Byte offset from the start of the encoded argument buffer.
        var offset: Int
        var kind: Kind
        /// Bytes the member takes (8 for a buffer, texture or sampler).
        var size: Int
        var alignment: Int
    }

    var members: [UInt32: Member]
    var encodedLength: Int
    var alignment: Int
    /// Top-level buffer members whose pointee struct could not be read and
    /// was skipped (see `Parser.resync`).
    var skippedPointees = 0

    /// The member at `index`, nil when the layout has none there.
    func member(_ index: UInt32) -> Member? { members[index] }

    /// Whether every member sits where the old 8 × index rule put it
    /// (diagnostics: false for sparse ids, inline data, nesting).
    var isDense: Bool {
        members.allSatisfy { $0.value.offset == 8 * Int($0.key) && $0.value.size == 8 }
    }

    // MARK: Parsing

    /// Bounds on what one description may make (a malformed one must not
    /// make the host allocate without limit).
    static let maxMembers = 1 << 16
    static let maxDepth = 16

    /// Parses an op-16 record body: u32 0, u32 payload length, u32 0, the
    /// payload (§4.3.1).
    static func parse(recordBody body: [UInt8]) throws -> MetalArgumentLayout {
        var r = ByteReader(body)
        _ = try r.u32()
        let length = Int(try r.u32())
        _ = try r.u32()
        let payload = try r.take(length)
        return try parse(payload: payload)
    }

    /// Parses the payload: magic `MTLPSBIN`, u32 version, the top-level struct.
    static func parse(payload: [UInt8]) throws -> MetalArgumentLayout {
        var p = Parser(r: ByteReader(payload))
        guard try p.r.take(8) == Array("MTLPSBIN".utf8) else { throw MetalDecodeError.badPayload("argument layout: no MTLPSBIN magic") }
        _ = try p.r.u32()
        do {
            try p.structBody(offset: 0, index: 0, depth: 0, collect: true)
        } catch {
            // Where it stopped (diagnostics): the members placed so far, and
            // the member whose pointee struct was being read, if any.
            let placed = p.members.sorted { $0.key < $1.key }.map { "\($0.key)@\($0.value.offset)" }.joined(separator: " ")
            let inside = p.pointeeOf.map { " in the pointee struct of member \($0.index) at \($0.offset)" } ?? ""
            throw MetalDecodeError.badPayload("\(error)\(inside); \(p.members.count) members placed before it (\(placed.prefix(200)))")
        }
        var alignment = 1, end = 0
        for m in p.members.values {
            alignment = max(alignment, m.alignment)
            end = max(end, m.offset + m.size)
        }
        end = max(end, p.extent)
        let length = (end + alignment - 1) / alignment * alignment
        return MetalArgumentLayout(members: p.members, encodedLength: length, alignment: alignment, skippedPointees: p.skippedPointees)
    }

    /// A buffer member's pointee struct held something the grammar does not
    /// describe; the member itself is placed.
    private struct UnreadablePointee: Error, CustomStringConvertible {
        let underlying: Error
        var description: String { "\(underlying)" }
    }

    private struct Parser {
        var r: ByteReader
        var members: [UInt32: Member] = [:]
        /// The end of the furthest array seen (offset + count × stride).
        var extent = 0
        /// Diagnostics: the member whose pointee struct is being read.
        var pointeeOf: (index: UInt32, offset: Int)?
        var skippedPointees = 0

        /// u32 serial, u32 member count, then the members.
        mutating func structBody(offset: Int, index: UInt32, depth: Int, collect: Bool) throws {
            guard depth < MetalArgumentLayout.maxDepth else { throw MetalDecodeError.badPayload("argument layout nested too deep") }
            _ = try r.u32()
            let count = try r.u32()
            try memberList(count: count, offset: offset, index: index, depth: depth, collect: collect)
        }

        mutating func memberList(count: UInt32, offset: Int, index: UInt32, depth: Int, collect: Bool) throws {
            guard Int(count) <= r.remaining else { throw MetalDecodeError.badPayload("argument layout: \(count) members") }
            for k in 0..<count {
                do {
                    try member(offset: offset, index: index, depth: depth, collect: collect)
                } catch let e as UnreadablePointee where depth == 0 && collect {
                    try resync(remaining: count - k - 1, underlying: e.underlying)
                    return
                }
            }
        }

        /// After a top-level buffer member whose pointee struct could not be
        /// read (its contents do not affect the argument buffer's layout):
        /// the next member starts after an argument record's terminator
        /// (u64 all ones). The first such position from which the remaining
        /// top-level members parse and end exactly at the end of the payload
        /// is taken; none: the description fails as before.
        mutating func resync(remaining: UInt32, underlying: Error) throws {
            let bytes = r.bytes, end = r.end
            var p = r.offset
            while p + 8 <= end {
                if bytes[p..<(p + 8)].allSatisfy({ $0 == 0xFF }) {
                    var trial = self
                    trial.r.offset = p + 8
                    trial.pointeeOf = nil
                    trial.skippedPointees += 1
                    if (try? trial.memberList(count: remaining, offset: 0, index: 0, depth: 0, collect: true)) != nil,
                       trial.r.remaining == 0 {
                        self = trial
                        return
                    }
                }
                p += 1
            }
            throw underlying
        }

        /// Name, u32 offset, u32 argument index, u32 type code, u64 0, type body.
        mutating func member(offset base: Int, index baseIndex: UInt32, depth: Int, collect: Bool) throws {
            try skipName()
            let offset = base + Int(try r.u32())
            let index = baseIndex &+ (try r.u32())
            let code = try r.u32()
            _ = try r.u64()
            try typeBody(code: code, offset: offset, index: index, depth: depth, collect: collect)
        }

        mutating func typeBody(code: UInt32, offset: Int, index: UInt32, depth: Int, collect: Bool) throws {
            switch code {
            case 57:
                let n = try r.u32()
                guard Int(n) <= r.remaining else { throw MetalDecodeError.badPayload("argument layout: \(n) arguments") }
                for _ in 0..<n { try argument(offset: offset, index: index, depth: depth, collect: collect) }
            case 1:
                try structBody(offset: offset, index: index, depth: depth + 1, collect: collect)
                _ = try r.u64()
            case 2:
                let count = Int(try r.u32())
                let elementCode = try r.u32()
                let stride = Int(try r.u32())
                // Descriptor-built arrays say index stride 0 and still take
                // consecutive indices (§4.3.2 rule 3).
                let indexStride = max(try r.u32(), 1)
                _ = try r.u64()
                guard elementCode == 57 || elementCode == 1 else {
                    throw MetalDecodeError.badPayload("argument layout: array of type \(elementCode)")
                }
                guard count <= MetalArgumentLayout.maxMembers else { throw MetalDecodeError.badPayload("argument layout: array of \(count)") }
                // The element's body is written once (for the first element);
                // element e sits at + e × stride, its indices at + e × the index stride.
                var sub = Parser(r: r)
                try sub.typeBody(code: elementCode, offset: 0, index: 0, depth: depth + 1, collect: collect)
                r.offset = sub.r.offset
                guard collect, count > 0 else { return }
                guard count * max(sub.members.count, 1) + members.count <= MetalArgumentLayout.maxMembers else {
                    throw MetalDecodeError.badPayload("argument layout: too many members")
                }
                for e in 0..<count {
                    for (i, m) in sub.members {
                        var placed = m
                        placed.offset += offset + e * stride
                        try add(index &+ UInt32(truncatingIfNeeded: e) &* indexStride &+ i, placed)
                    }
                }
                extent = max(extent, offset + count * stride, offset + (count - 1) * stride + sub.extent)
            default:
                throw MetalDecodeError.badPayload("argument layout: type code \(code) before byte \(r.offset)")
            }
        }

        /// The argument record (§4.3.1).
        mutating func argument(offset: Int, index: UInt32, depth: Int, collect: Bool) throws {
            try skipName()
            let kindAccess = try r.u8()
            _ = try r.u8()
            _ = try r.u16()
            _ = try r.u32()  // the argument index, as the member's
            let arrayLength = Int(max(try r.u32(), 1))
            guard let kind = Kind(rawValue: kindAccess & 0x1F) else {
                throw MetalDecodeError.badPayload("argument layout: argument kind \(kindAccess & 0x1F) before byte \(r.offset)")
            }
            switch kind {
            case .constantBuffer, .deviceBuffer, .inlineData:
                _ = try r.u32()  // data type
                _ = try r.u32()
                _ = try r.u32()
                let a = Int(try r.u32())
                let s = Int(try r.u32())
                // Buffers take 8 bytes (the size and alignment describe the pointee).
                try place(kind, size: kind == .inlineData ? max(s, 1) : 8, alignment: kind == .inlineData ? max(a, 1) : 8,
                          arrayLength: arrayLength, offset: offset, index: index, collect: collect)
                let pointee = try r.u32()
                if pointee != 0 {
                    // The pointee struct's members (no terminator): they
                    // describe the buffer's contents, not the argument buffer.
                    let n = try r.u32()
                    let outer = pointeeOf
                    if collect { pointeeOf = (index, offset) }
                    do {
                        try memberList(count: n, offset: 0, index: 0, depth: depth + 1, collect: false)
                    } catch {
                        throw UnreadablePointee(underlying: error)
                    }
                    pointeeOf = outer
                }
            case .texture:
                _ = try r.u32(); _ = try r.u32(); _ = try r.u32()
                try place(kind, size: 8, alignment: 8, arrayLength: arrayLength, offset: offset, index: index, collect: collect)
            case .sampler:
                _ = try r.u32()
                try place(kind, size: 8, alignment: 8, arrayLength: arrayLength, offset: offset, index: index, collect: collect)
            }
            _ = try r.u64()
        }

        /// Places an argument's members: a resource array of the
        /// array<…, n> form has element k at +8k, index +k.
        mutating func place(_ kind: Kind, size: Int, alignment: Int, arrayLength: Int, offset: Int, index: UInt32, collect: Bool) throws {
            guard collect else { return }
            guard arrayLength <= MetalArgumentLayout.maxMembers else { throw MetalDecodeError.badPayload("argument layout: array of \(arrayLength)") }
            let step = kind.isResource ? 8 : size
            for k in 0..<arrayLength {
                try add(index &+ UInt32(k), Member(offset: offset + k * step, kind: kind, size: size, alignment: alignment))
            }
        }

        mutating func add(_ index: UInt32, _ m: Member) throws {
            guard members.count < MetalArgumentLayout.maxMembers else { throw MetalDecodeError.badPayload("argument layout: too many members") }
            members[index] = m
        }

        mutating func skipName() throws {
            while try r.u8() != 0 {}
        }
    }
}

/// Builds layout descriptions in the format of metal-sim-protocol.md
/// §4.3.1 (tests and diagnostics; written from the spec's grammar).
struct MetalArgumentLayoutBuilder {
    private(set) var bytes: [UInt8] = []
    private var serial: UInt32 = 0

    enum Argument: Sendable {
        /// kind: 1 constant buffer, 2 device buffer.
        case buffer(kind: UInt8 = 2, arrayLength: UInt32 = 1)
        case texture(type: UInt32 = 2, arrayLength: UInt32 = 1)
        case sampler(arrayLength: UInt32 = 1)
        case inline(dataType: UInt32, size: UInt32, alignment: UInt32)
        /// A buffer pointing to a struct (its members are described inline).
        case bufferTo([Member])
    }

    indirect enum MemberType: Sendable {
        case argument(Argument)
        case structure([Member])
        case array(count: UInt32, stride: UInt32, indexStride: UInt32, element: MemberType)
        /// A type code the grammar does not describe, with arbitrary bytes
        /// after its u64 (tests of the parser's recovery).
        case unknown(code: UInt32, bytes: [UInt8])
    }

    struct Member: Sendable {
        var name: String
        var offset: UInt32
        var index: UInt32
        var type: MemberType
        init(_ name: String = "", offset: UInt32, index: UInt32, _ type: MemberType) {
            self.name = name; self.offset = offset; self.index = index; self.type = type
        }
    }

    /// The payload for a top-level struct of `members`.
    static func payload(_ members: [Member]) -> [UInt8] {
        var b = MetalArgumentLayoutBuilder()
        b.bytes += Array("MTLPSBIN".utf8)
        b.u32(2)
        b.structure(members)
        return b.bytes
    }

    /// An op-16 record body around the payload (padded to a multiple of 4).
    static func recordBody(_ members: [Member]) -> [UInt8] {
        let p = payload(members)
        var w = MetalByteWriter()
        w.u32(0); w.u32(UInt32(p.count)); w.u32(0)
        w.append(p)
        w.pad(to: (w.bytes.count + 3) / 4 * 4)
        return w.bytes
    }

    private mutating func u32(_ v: UInt32) { for i in 0..<4 { bytes.append(UInt8(truncatingIfNeeded: v >> (8 * UInt32(i)))) } }
    private mutating func u64(_ v: UInt64) { u32(UInt32(truncatingIfNeeded: v)); u32(UInt32(truncatingIfNeeded: v >> 32)) }
    private mutating func name(_ s: String) { bytes += Array(s.utf8) + [0] }

    private mutating func structure(_ members: [Member]) {
        serial += 1
        u32(serial)
        u32(UInt32(members.count))
        for m in members { member(m) }
    }

    private mutating func member(_ m: Member) {
        name(m.name)
        u32(m.offset)
        u32(m.index)
        typeBody(m.type, name: m.name, index: m.index, withCode: true)
    }

    private mutating func typeBody(_ t: MemberType, name n: String, index: UInt32, withCode: Bool) {
        switch t {
        case let .argument(a):
            if withCode { u32(57); u64(0) }
            u32(1)
            argument(a, name: n, index: index)
        case let .structure(ms):
            if withCode { u32(1); u64(0) }
            structure(ms)
            u64(.max)
        case let .unknown(code, raw):
            u32(code); u64(0)
            bytes += raw
        case let .array(count, stride, indexStride, element):
            if withCode { u32(2); u64(0) }
            u32(count)
            switch element {
            case .argument: u32(57)
            case .structure: u32(1)
            case .array: u32(2)
            case let .unknown(code, _): u32(code)
            }
            u32(stride)
            u32(indexStride)
            u64(0)
            typeBody(element, name: n, index: index, withCode: false)
        }
    }

    private mutating func argument(_ a: Argument, name n: String, index: UInt32) {
        name(n)
        switch a {
        case let .buffer(kind, arrayLength):
            bytes += [kind, 2, 0, 0]; u32(index); u32(arrayLength)
            u32(0); u32(0); u32(0); u32(16); u32(16); u32(0)
        case let .bufferTo(ms):
            bytes += [0x22, 2, 0, 0]; u32(index); u32(1)
            u32(1); u32(0); u32(0); u32(16); u32(32)
            serial += 1
            u32(serial)
            u32(UInt32(ms.count))
            for m in ms { member(m) }
        case let .texture(type, arrayLength):
            bytes += [4, 2, 0, 0]; u32(index); u32(arrayLength)
            u32(0); u32(type); u32(0)
        case let .sampler(arrayLength):
            bytes += [5, 2, 0, 0]; u32(index); u32(arrayLength)
            u32(0)
        case let .inline(dataType, size, alignment):
            bytes += [8, 2, 0, 0]; u32(index); u32(1)
            u32(dataType); u32(0); u32(0); u32(alignment); u32(size); u32(0)
        }
        u64(.max)
    }
}
