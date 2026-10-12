import Foundation

// The XPC serialization of `bootstrap-wire.md` §3 and the payload placement
// of §2.3. Written from the spec's tables only.

/// A Mach descriptor as this library sees it, independent of any Mach API.
/// On encode, `disposition` is the `MACH_MSG_TYPE_*` to send with; on
/// decode, it is the received type (16 receive, 17 send, 18 send-once).
public enum XPCWireDescriptor: Equatable, Sendable {
    /// A 12-byte port descriptor (type 0).
    case port(name: UInt32, disposition: UInt32)
    /// An out-of-line memory descriptor (type 1) and its bytes.
    case ool(bytes: [UInt8])
    /// An out-of-line ports descriptor (type 2). Not used by XPC payloads;
    /// present so a received message maps totally. Decoding rejects it.
    case oolPorts(names: [UInt32], disposition: UInt32)
    /// A guarded port descriptor (type 4). Not seen in captures; decoding
    /// treats it as a port descriptor.
    case guardedPort(name: UInt32, disposition: UInt32)

    /// Size in a 64-bit user message: 12 for a port, 16 otherwise.
    public var wireSize: Int {
        if case .port = self { 12 } else { 16 }
    }
}

/// The serialized form of an object: inline payload plus port descriptors
/// (in depth-first order of the port-bearing objects).
public struct XPCWireEncoding: Equatable, Sendable {
    public var body: [UInt8]
    public var descriptors: [XPCWireDescriptor]
    public init(body: [UInt8], descriptors: [XPCWireDescriptor]) {
        self.body = body
        self.descriptors = descriptors
    }
}

/// A reason to reject a payload or an object to be encoded.
public enum XPCWireError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Fewer bytes than needed at this payload offset.
    case truncated(offset: Int)
    case badMagic(UInt32)
    case badVersion(UInt32)
    case unknownTag(UInt32, offset: Int)
    /// A dictionary or array byte length that does not fit or does not match its entries.
    case badLength(offset: Int)
    /// A string whose length is 0 or whose last byte is not NUL.
    case badString(offset: Int)
    case invalidUTF8(offset: Int)
    /// A dictionary key without a terminating NUL in bounds.
    case unterminatedKey(offset: Int)
    case nestingTooDeep(offset: Int)
    /// The payload needs a k-th port descriptor that the message lacks.
    case missingPortDescriptor(index: Int)
    /// The message has port descriptors that no object uses.
    case unusedDescriptors(expected: Int, actual: Int)
    /// A descriptor of a kind that cannot stand for a port-bearing object here.
    case unexpectedDescriptor(index: Int)
    /// No inline payload and no OOL descriptor.
    case noPayload
    /// The root is not a dictionary (pipe messages need one).
    case rootNotDictionary
    // Encoding.
    case keyContainsNUL(String)
    case inlineDataTooLarge(Int)
    case largeDataTooSmall(UInt32)
    case tooLarge

    public var description: String {
        switch self {
        case let .truncated(o): "truncated at payload offset \(o)"
        case let .badMagic(m): "bad magic 0x\(String(m, radix: 16))"
        case let .badVersion(v): "bad version \(v)"
        case let .unknownTag(t, o): "unknown tag 0x\(String(t, radix: 16)) at payload offset \(o)"
        case let .badLength(o): "bad container length at payload offset \(o)"
        case let .badString(o): "bad string at payload offset \(o)"
        case let .invalidUTF8(o): "invalid UTF-8 at payload offset \(o)"
        case let .unterminatedKey(o): "unterminated key at payload offset \(o)"
        case let .nestingTooDeep(o): "nesting too deep at payload offset \(o)"
        case let .missingPortDescriptor(i): "missing port descriptor \(i)"
        case let .unusedDescriptors(e, a): "\(a) port descriptors for \(e) port-bearing objects"
        case let .unexpectedDescriptor(i): "unexpected descriptor kind at index \(i)"
        case .noPayload: "no payload"
        case .rootNotDictionary: "root object is not a dictionary"
        case let .keyContainsNUL(k): "dictionary key contains NUL: \(XPCObject.quoted(k))"
        case let .inlineDataTooLarge(n): "inline data of \(n) bytes exceeds \(XPCWire.inlineDataLimit)"
        case let .largeDataTooSmall(n): "large data of \(n) bytes would travel inline"
        case .tooLarge: "object too large to serialize"
        }
    }
}

public enum XPCWire {
    /// `?cpx`, written by Ycode.
    public static let magic: UInt32 = 0x7870_633F
    /// `@cpx`, also accepted.
    public static let alternateMagic: UInt32 = 0x7870_6340
    /// `!CPX`: the magic of connections marked sim2host
    /// (iosurface-remote.md §2.1); accepted, and written on request.
    public static let sim2hostMagic: UInt32 = 0x5850_4321
    public static let version: UInt32 = 5
    /// Data longer than this travels as a memory-object port (§3.2).
    public static let inlineDataLimit = 16384
    /// Containers nested deeper than this are rejected on decode.
    public static let maximumDepth = 64

    public enum Tag {
        public static let null: UInt32 = 0x1000
        public static let bool: UInt32 = 0x2000
        public static let int64: UInt32 = 0x3000
        public static let uint64: UInt32 = 0x4000
        public static let double: UInt32 = 0x5000
        public static let date: UInt32 = 0x7000
        public static let data: UInt32 = 0x8000
        public static let string: UInt32 = 0x9000
        public static let uuid: UInt32 = 0xA000
        public static let fd: UInt32 = 0xB000
        public static let sharedMemory: UInt32 = 0xC000
        public static let sendRight: UInt32 = 0xD000
        public static let array: UInt32 = 0xE000
        public static let dictionary: UInt32 = 0xF000
        public static let receiveRight: UInt32 = 0x15000
    }

    // MARK: Encoding

    /// Serializes `root` (normally a dictionary) with magic `?cpx` and
    /// version 5. The descriptors are the rights of the port-bearing
    /// objects, in the order they are written, with each `XPCPort`'s
    /// disposition.
    public static func encode(_ root: XPCObject, magic: UInt32 = XPCWire.magic) throws -> XPCWireEncoding {
        let body = try encodePayload(root, magic: magic)
        return XPCWireEncoding(body: body, descriptors: root.ports.map { .port(name: $0.name, disposition: $0.disposition) })
    }

    /// The payload bytes only (header and root object).
    public static func encodePayload(_ root: XPCObject, magic: UInt32 = XPCWire.magic) throws -> [UInt8] {
        var w = Writer()
        w.u32(magic)
        w.u32(version)
        try w.object(root)
        return w.bytes
    }

    // MARK: Decoding

    /// Decodes a message's payload. `body` is the inline bytes after the
    /// descriptors. If it is empty, the payload is the first `.ool`
    /// descriptor (§2.3) and the remaining descriptors are the ports.
    /// Otherwise every descriptor must be a port descriptor. The k-th
    /// port-bearing object gets the k-th port descriptor.
    public static func decode(body: [UInt8], descriptors: [XPCWireDescriptor]) throws -> XPCObject {
        var payload = body
        var ports: [XPCPort] = []
        var usedOOL = false
        for (i, d) in descriptors.enumerated() {
            switch d {
            case let .port(name, disposition), let .guardedPort(name, disposition):
                ports.append(XPCPort(name: name, disposition: disposition))
            case let .ool(bytes):
                guard body.isEmpty, !usedOOL else { throw XPCWireError.unexpectedDescriptor(index: i) }
                payload = bytes
                usedOOL = true
            case .oolPorts:
                throw XPCWireError.unexpectedDescriptor(index: i)
            }
        }
        guard !payload.isEmpty else { throw XPCWireError.noPayload }
        return try decodePayload(payload, ports: ports)
    }

    /// Decodes payload bytes (header and root object), binding the k-th
    /// port-bearing object to `ports[k]`. Bytes after the root object are
    /// ignored (an OOL region is rounded up). With `ports == nil`, each
    /// right gets `XPCPort(name: k, disposition: 0)` (its descriptor index).
    public static func decodePayload(_ payload: [UInt8], ports: [XPCPort]?) throws -> XPCObject {
        var r = Reader(bytes: payload, ports: ports)
        let m = try r.u32()
        guard m == magic || m == alternateMagic || m == sim2hostMagic else { throw XPCWireError.badMagic(m) }
        let v = try r.u32()
        guard v == version else { throw XPCWireError.badVersion(v) }
        let root = try r.object(depth: 0)
        if let ports, r.portIndex != ports.count {
            throw XPCWireError.unusedDescriptors(expected: r.portIndex, actual: ports.count)
        }
        return root
    }

    // MARK: Writer

    struct Writer {
        var bytes: [UInt8] = []

        mutating func u32(_ v: UInt32) {
            bytes += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8),
                      UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 24)]
        }

        mutating func u64(_ v: UInt64) {
            u32(UInt32(truncatingIfNeeded: v))
            u32(UInt32(truncatingIfNeeded: v >> 32))
        }

        mutating func pad() {
            while bytes.count % 4 != 0 { bytes.append(0) }
        }

        mutating func patch(_ at: Int, _ v: UInt32) {
            for i in 0..<4 { bytes[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
        }

        func checked(_ n: Int) throws -> UInt32 {
            guard let v = UInt32(exactly: n) else { throw XPCWireError.tooLarge }
            return v
        }

        mutating func object(_ o: XPCObject) throws {
            switch o {
            case .null: u32(Tag.null)
            case let .bool(v): u32(Tag.bool); u32(v ? 1 : 0)
            case let .int64(v): u32(Tag.int64); u64(UInt64(bitPattern: v))
            case let .uint64(v): u32(Tag.uint64); u64(v)
            case let .double(v): u32(Tag.double); u64(v.bitPattern)
            case let .date(v): u32(Tag.date); u64(UInt64(bitPattern: v))
            case let .data(v):
                guard v.count <= XPCWire.inlineDataLimit else { throw XPCWireError.inlineDataTooLarge(v.count) }
                u32(Tag.data); u32(UInt32(v.count)); bytes += v; pad()
            case let .string(v):
                let utf8 = Array(v.utf8)
                u32(Tag.string); u32(try checked(utf8.count + 1)); bytes += utf8; bytes.append(0); pad()
            case let .uuid(v):
                u32(Tag.uuid); bytes += XPCWire.uuidBytes(v)
            case .fd: u32(Tag.fd)
            case let .sharedMemory(size, _): u32(Tag.sharedMemory); u32(size); u32(0)
            case .sendRight: u32(Tag.sendRight)
            case .receiveRight: u32(Tag.receiveRight)
            case let .largeData(length, _):
                guard Int(length) > XPCWire.inlineDataLimit else { throw XPCWireError.largeDataTooSmall(length) }
                u32(Tag.data); u32(length)
            case let .array(items):
                u32(Tag.array)
                let lengthAt = bytes.count
                u32(0)
                u32(try checked(items.count))
                for item in items { try object(item) }
                patch(lengthAt, try checked(bytes.count - lengthAt - 4))
            case let .dictionary(d):
                u32(Tag.dictionary)
                let lengthAt = bytes.count
                u32(0)
                u32(try checked(d.count))
                for e in d.entries {
                    let key = Array(e.key.utf8)
                    guard !key.contains(0) else { throw XPCWireError.keyContainsNUL(e.key) }
                    bytes += key; bytes.append(0); pad()
                    try object(e.value)
                }
                patch(lengthAt, try checked(bytes.count - lengthAt - 4))
            }
        }
    }

    // MARK: Reader

    struct Reader {
        let bytes: [UInt8]
        let ports: [XPCPort]?
        var offset = 0
        /// Bytes at or after `end` are outside the current container.
        var end: Int
        var portIndex = 0

        init(bytes: [UInt8], ports: [XPCPort]?) {
            self.bytes = bytes
            self.ports = ports
            end = bytes.count
        }

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, n <= end - offset else { throw XPCWireError.truncated(offset: offset) }
            defer { offset += n }
            return bytes[offset..<(offset + n)]
        }

        mutating func u32() throws -> UInt32 {
            let s = try take(4)
            var v: UInt32 = 0
            for (i, b) in s.enumerated() { v |= UInt32(b) << (8 * UInt32(i)) }
            return v
        }

        mutating func u64() throws -> UInt64 {
            let lo = UInt64(try u32())
            return lo | UInt64(try u32()) << 32
        }

        /// Skips padding to the next 4-byte boundary (within bounds).
        mutating func align() throws {
            let n = (4 - offset % 4) % 4
            _ = try take(n)
        }

        mutating func nextPort() throws -> XPCPort {
            defer { portIndex += 1 }
            guard let ports else { return XPCPort(name: UInt32(truncatingIfNeeded: portIndex), disposition: 0) }
            guard portIndex < ports.count else { throw XPCWireError.missingPortDescriptor(index: portIndex) }
            return ports[portIndex]
        }

        mutating func key() throws -> String {
            let start = offset
            guard let nul = bytes[offset..<end].firstIndex(of: 0) else {
                throw XPCWireError.unterminatedKey(offset: start)
            }
            guard let k = String(validating: bytes[start..<nul], as: UTF8.self) else {
                throw XPCWireError.invalidUTF8(offset: start)
            }
            offset = nul + 1
            try align()
            return k
        }

        mutating func object(depth: Int) throws -> XPCObject {
            let at = offset
            let tag = try u32()
            switch tag {
            case Tag.null: return .null
            case Tag.bool: return .bool(try u32() != 0)
            case Tag.int64: return .int64(Int64(bitPattern: try u64()))
            case Tag.uint64: return .uint64(try u64())
            case Tag.double: return .double(Double(bitPattern: try u64()))
            case Tag.date: return .date(Int64(bitPattern: try u64()))
            case Tag.data:
                let length = try u32()
                if Int(length) > XPCWire.inlineDataLimit {
                    return .largeData(length: length, port: try nextPort())
                }
                let d = Array(try take(Int(length)))
                try align()
                return .data(d)
            case Tag.string:
                let lengthAt = offset
                let length = Int(try u32())
                guard length >= 1 else { throw XPCWireError.badString(offset: lengthAt) }
                let s = try take(length)
                guard s.last == 0 else { throw XPCWireError.badString(offset: lengthAt) }
                guard let v = String(validating: s.dropLast(), as: UTF8.self) else {
                    throw XPCWireError.invalidUTF8(offset: lengthAt + 4)
                }
                try align()
                return .string(v)
            case Tag.uuid:
                return .uuid(XPCWire.uuid(Array(try take(16))))
            case Tag.fd: return .fd(try nextPort())
            case Tag.sharedMemory:
                let size = try u32()
                _ = try u32()
                return .sharedMemory(size: size, port: try nextPort())
            case Tag.sendRight: return .sendRight(try nextPort())
            case Tag.receiveRight: return .receiveRight(try nextPort())
            case Tag.array, Tag.dictionary:
                guard depth < XPCWire.maximumDepth else { throw XPCWireError.nestingTooDeep(offset: at) }
                let lengthAt = offset
                let length = Int(try u32())
                guard length >= 4, length <= end - offset else { throw XPCWireError.badLength(offset: lengthAt) }
                let outerEnd = end
                end = offset + length
                let count = Int(try u32())
                // Every entry takes at least 4 bytes.
                guard count <= (end - offset) / 4 else { throw XPCWireError.badLength(offset: lengthAt) }
                let result: XPCObject
                if tag == Tag.array {
                    var items: [XPCObject] = []
                    items.reserveCapacity(count)
                    for _ in 0..<count { items.append(try object(depth: depth + 1)) }
                    result = .array(items)
                } else {
                    var d = XPCDict()
                    d.entries.reserveCapacity(count)
                    for _ in 0..<count {
                        let k = try key()
                        d.append(key: k, value: try object(depth: depth + 1))
                    }
                    result = .dictionary(d)
                }
                guard offset == end else { throw XPCWireError.badLength(offset: lengthAt) }
                end = outerEnd
                return result
            default:
                throw XPCWireError.unknownTag(tag, offset: at)
            }
        }
    }

    // MARK: UUID bytes

    static func uuidBytes(_ u: UUID) -> [UInt8] {
        withUnsafeBytes(of: u.uuid) { Array($0) }
    }

    static func uuid(_ b: [UInt8]) -> UUID {
        var t = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)).uuid
        withUnsafeMutableBytes(of: &t) { raw in
            for i in 0..<16 { raw[i] = b[i] }
        }
        return UUID(uuid: t)
    }
}
