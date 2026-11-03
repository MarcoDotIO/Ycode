// The gdb-remote serial protocol's framing (`specs/simulator/debug-stub.md`
// §3): `$<body>#<two hex digits>`, where the digits are the sum of the body's
// bytes modulo 256; `+` and `-` acknowledge a packet until `QStartNoAckMode`
// turns acknowledgements off; a lone 0x03 byte outside a packet is an
// interrupt request. Inside a body, `}` escapes the next byte (XOR 0x20); a
// body sent with binary data (`x` replies) escapes `$`, `#`, `}` and `*`.
// Sources: GDB's "Overview" and "Packets" chapters of the remote protocol
// documentation, and LLDB's `lldbgdbremote.md` (level 1).

/// One unit read from the client.
public enum GDBRemoteInput: Equatable, Sendable {
    /// A packet whose checksum was right: its body, unescaped.
    case packet([UInt8])
    /// A packet whose checksum was wrong (the reply is `-`).
    case badChecksum
    /// The interrupt byte (0x03) between packets.
    case interrupt
    case ack
    case nack
}

/// Splits a byte stream into packets, acknowledgements and interrupts.
public struct GDBRemoteDecoder: Sendable {
    private enum State: Sendable { case idle, body, escape, braceThenHash, checksum1, checksum2 }
    private var state = State.idle
    /// After `}#`: the two bytes that follow (a checksum, or escaped body).
    private var afterHash: [UInt8] = []
    private var body: [UInt8] = []
    private var sum: UInt8 = 0
    private var high: UInt8 = 0
    /// Bodies longer than this are dropped (a stream that lost its framing).
    public var maximumBodyLength = 1 << 22

    public init() {}

    /// Feeds bytes and returns every complete unit they finish, in order.
    public mutating func append<S: Sequence>(_ bytes: S) -> [GDBRemoteInput] where S.Element == UInt8 {
        var out: [GDBRemoteInput] = []
        for b in bytes {
            switch state {
            case .idle:
                switch b {
                case UInt8(ascii: "$"):
                    state = .body
                    body.removeAll(keepingCapacity: true)
                    sum = 0
                case UInt8(ascii: "+"): out.append(.ack)
                case UInt8(ascii: "-"): out.append(.nack)
                case 0x03: out.append(.interrupt)
                default: break   // noise between packets
                }
            case .body:
                switch b {
                case UInt8(ascii: "#"): state = .checksum1
                case UInt8(ascii: "}"):
                    sum &+= b
                    state = .escape
                case UInt8(ascii: "$"):
                    // A new packet before the old one ended: start over.
                    body.removeAll(keepingCapacity: true)
                    sum = 0
                default:
                    sum &+= b
                    body.append(b)
                    if body.count > maximumBodyLength { state = .idle }
                }
            case .escape where b == UInt8(ascii: "#"):
                // LLDB sends JSON packets (`jGetSharedCacheInfo:{}`) with
                // the closing brace unescaped: `}#` then ends the packet
                // when the two bytes after it are the checksum of the body
                // up to and including the brace; else `}#` is an escaped byte.
                afterHash.removeAll(keepingCapacity: true)
                state = .braceThenHash
            case .escape:
                sum &+= b
                body.append(b ^ 0x20)
                state = .body
            case .braceThenHash:
                afterHash.append(b)
                guard afterHash.count == 2 else { continue }
                if let h = GDBRemoteHex.nibble(afterHash[0]), let l = GDBRemoteHex.nibble(afterHash[1]), h << 4 | l == sum {
                    state = .idle
                    out.append(.packet(body + [UInt8(ascii: "}")]))
                } else {
                    sum &+= UInt8(ascii: "#")
                    body.append(UInt8(ascii: "#") ^ 0x20)
                    state = .body
                    out += append(afterHash)
                }
            case .checksum1:
                guard let v = GDBRemoteHex.nibble(b) else { state = .idle; out.append(.badChecksum); continue }
                high = v
                state = .checksum2
            case .checksum2:
                state = .idle
                guard let v = GDBRemoteHex.nibble(b), high << 4 | v == sum else { out.append(.badChecksum); continue }
                out.append(.packet(body))
            }
        }
        return out
    }
}

public enum GDBRemoteFraming {
    /// The checksum of `bytes` (already escaped).
    public static func checksum<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    /// Escapes the bytes a body may not carry as they are: `$`, `#`, `}`
    /// and `*` (the run-length marker).
    public static func escape(_ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(body.count)
        for b in body {
            switch b {
            case UInt8(ascii: "$"), UInt8(ascii: "#"), UInt8(ascii: "}"), UInt8(ascii: "*"):
                out.append(UInt8(ascii: "}"))
                out.append(b ^ 0x20)
            default:
                out.append(b)
            }
        }
        return out
    }

    /// `$<escaped body>#<checksum>`.
    public static func frame(_ body: [UInt8]) -> [UInt8] {
        let escaped = escape(body)
        let c = checksum(escaped)
        return [UInt8(ascii: "$")] + escaped + [UInt8(ascii: "#"), GDBRemoteHex.digit(c >> 4), GDBRemoteHex.digit(c & 0xF)]
    }

    public static func frame(_ body: String) -> [UInt8] { frame(Array(body.utf8)) }
}

/// Hex text as the protocol writes it: lowercase digits, bytes in memory
/// order (registers in target byte order, little-endian here).
public enum GDBRemoteHex {
    private static let digits = Array("0123456789abcdef".utf8)

    @inline(__always) public static func digit(_ v: UInt8) -> UInt8 { digits[Int(v & 0xF)] }

    @inline(__always) public static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Two digits per byte.
    public static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        var out: [UInt8] = []
        for b in bytes {
            out.append(digit(b >> 4))
            out.append(digit(b & 0xF))
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `text` as hex-encoded UTF-8 (names in `qHostInfo`, `jThreadsInfo`).
    public static func encode(text: String) -> String { encode(Array(text.utf8)) }

    /// Bytes from pairs of digits; nil on an odd count or a non-digit.
    public static func decode<S: Collection>(_ text: S) -> [UInt8]? where S.Element == UInt8 {
        guard text.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(text.count / 2)
        var it = text.makeIterator()
        while let a = it.next(), let b = it.next() {
            guard let h = nibble(a), let l = nibble(b) else { return nil }
            out.append(h << 4 | l)
        }
        return out
    }

    public static func decode(_ text: String) -> [UInt8]? { decode(Array(text.utf8)) }

    /// A hex-encoded UTF-8 string (`vAttachName;<hex>`).
    public static func decodeText(_ text: String) -> String? { decode(text).map { String(decoding: $0, as: UTF8.self) } }

    /// A number written in hex with no prefix (addresses, lengths, thread
    /// ids). "-1" is all ones (every thread).
    public static func number<S: StringProtocol>(_ text: S) -> UInt64? {
        if text == "-1" { return UInt64.max }
        guard !text.isEmpty, text.count <= 16 else { return nil }
        return UInt64(text, radix: 16)
    }

    /// `value`'s `size` bytes, little-endian, as hex.
    public static func littleEndian(_ value: UInt64, size: Int) -> String {
        encode((0..<size).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }

    /// Up to eight little-endian bytes as a number.
    public static func littleEndianValue<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var v: UInt64 = 0
        for (i, b) in bytes.prefix(8).enumerated() { v |= UInt64(b) << (8 * UInt64(i)) }
        return v
    }
}
