import Foundation

// Messages (D-Bus Specification 0.43, "Message Format"): the header is
// `yyyyuua(yv)` — byte order ('l' or 'B'), message type, flags, major
// protocol version 1, body length, serial, then header fields (code,
// variant) — padded to 8 bytes; the body follows in the same byte order.
// Header field codes: 1 PATH (o), 2 INTERFACE (s), 3 MEMBER (s),
// 4 ERROR_NAME (s), 5 REPLY_SERIAL (u), 6 DESTINATION (s), 7 SENDER (s),
// 8 SIGNATURE (g), 9 UNIX_FDS (u). Messages are at most 128 MiB.

public enum DBusMessageType: UInt8, Sendable {
    case methodCall = 1
    case methodReturn = 2
    case error = 3
    case signal = 4
}

/// Header flags.
public struct DBusMessageFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let noReplyExpected = DBusMessageFlags(rawValue: 0x1)
    public static let noAutoStart = DBusMessageFlags(rawValue: 0x2)
    public static let allowInteractiveAuthorization = DBusMessageFlags(rawValue: 0x4)
}

/// One message.
public struct DBusMessage: Sendable, Equatable, CustomStringConvertible {
    public var type: DBusMessageType
    public var flags: DBusMessageFlags = []
    /// Set when the message is sent (or read).
    public var serial: UInt32 = 0
    public var path: String?
    public var interface: String?
    public var member: String?
    public var errorName: String?
    public var replySerial: UInt32?
    public var destination: String?
    public var sender: String?
    public var unixFDs: UInt32?
    public var body: [DBusValue] = []

    public init(type: DBusMessageType) { self.type = type }

    /// The body's signature.
    public var signature: String { body.map(\.signature).joined() }

    public static func methodCall(destination: String?, path: String, interface: String?, member: String,
                                  body: [DBusValue] = [], flags: DBusMessageFlags = []) -> DBusMessage {
        var m = DBusMessage(type: .methodCall)
        m.destination = destination
        m.path = path
        m.interface = interface
        m.member = member
        m.body = body
        m.flags = flags
        return m
    }

    public static func signal(path: String, interface: String, member: String, body: [DBusValue] = [],
                              destination: String? = nil) -> DBusMessage {
        var m = DBusMessage(type: .signal)
        m.path = path
        m.interface = interface
        m.member = member
        m.body = body
        m.destination = destination
        return m
    }

    /// A method return for `call`.
    public static func reply(to call: DBusMessage, body: [DBusValue] = []) -> DBusMessage {
        var m = DBusMessage(type: .methodReturn)
        m.replySerial = call.serial
        m.destination = call.sender
        m.body = body
        return m
    }

    /// An error reply for `call` (the message is the body's string).
    public static func error(to call: DBusMessage, name: String, message: String) -> DBusMessage {
        var m = DBusMessage(type: .error)
        m.replySerial = call.serial
        m.destination = call.sender
        m.errorName = name
        m.body = [.string(message)]
        return m
    }

    /// The first string of an error's body.
    public var errorMessage: String { body.first?.stringValue ?? "" }

    public var description: String {
        var parts = ["\(type)", "serial=\(serial)"]
        if let replySerial { parts.append("reply=\(replySerial)") }
        if let sender { parts.append("from=\(sender)") }
        if let destination { parts.append("to=\(destination)") }
        if let path { parts.append(path) }
        if let interface, let member { parts.append("\(interface).\(member)") } else if let member { parts.append(member) }
        if let errorName { parts.append(errorName) }
        parts.append("(\(signature))")
        return parts.joined(separator: " ")
    }

    // MARK: Validation

    func validate() throws {
        func need(_ v: String?, _ what: String) throws {
            guard v != nil else { throw DBusError.malformedMessage("\(type) without \(what)") }
        }
        switch type {
        case .methodCall:
            try need(path, "PATH")
            try need(member, "MEMBER")
        case .signal:
            try need(path, "PATH")
            try need(interface, "INTERFACE")
            try need(member, "MEMBER")
        case .error:
            try need(errorName, "ERROR_NAME")
            guard replySerial != nil else { throw DBusError.malformedMessage("error without REPLY_SERIAL") }
        case .methodReturn:
            guard replySerial != nil else { throw DBusError.malformedMessage("return without REPLY_SERIAL") }
        }
        if let path, !DBusNames.isValidObjectPath(path) { throw DBusError.malformedMessage("path \"\(path)\"") }
        if let interface, !DBusNames.isValidInterfaceName(interface) { throw DBusError.malformedMessage("interface \"\(interface)\"") }
        if let member, !DBusNames.isValidMemberName(member) { throw DBusError.malformedMessage("member \"\(member)\"") }
        if let errorName, !DBusNames.isValidInterfaceName(errorName) { throw DBusError.malformedMessage("error name \"\(errorName)\"") }
        if let destination, !DBusNames.isValidBusName(destination) { throw DBusError.malformedMessage("destination \"\(destination)\"") }
    }

    // MARK: Wire format

    public static let maximumLength = 1 << 27

    /// The message's bytes (serial must be set).
    public func encoded(bigEndian: Bool = false) throws -> [UInt8] {
        guard serial != 0 else { throw DBusError.malformedMessage("serial 0") }
        try validate()
        var body = DBusEncoder(bigEndian: bigEndian)
        try body.write(self.body)
        var fields: [DBusValue] = []
        func field(_ code: UInt8, _ v: DBusValue) { fields.append(.structure([.byte(code), .variant(v)])) }
        if let path { field(1, .objectPath(path)) }
        if let interface { field(2, .string(interface)) }
        if let member { field(3, .string(member)) }
        if let errorName { field(4, .string(errorName)) }
        if let replySerial { field(5, .uint32(replySerial)) }
        if let destination { field(6, .string(destination)) }
        if let sender { field(7, .string(sender)) }
        if !self.body.isEmpty { field(8, .signature(signature)) }
        if let unixFDs { field(9, .uint32(unixFDs)) }
        var h = DBusEncoder(bigEndian: bigEndian)
        try h.write(.byte(bigEndian ? UInt8(ascii: "B") : UInt8(ascii: "l")))
        try h.write(.byte(type.rawValue))
        try h.write(.byte(flags.rawValue))
        try h.write(.byte(1))
        try h.write(.uint32(UInt32(body.count)))
        try h.write(.uint32(serial))
        try h.write(.array(.structure([.byte, .variant]), fields))
        h.pad(to: 8)
        let out = h.bytes + body.bytes
        guard out.count <= Self.maximumLength else { throw DBusError.malformedMessage("longer than 128 MiB") }
        return out
    }

    /// The total length of the message that starts with `prefix` (at least
    /// 16 bytes), or nil when fewer than 16 bytes are there.
    public static func frameLength(_ prefix: ArraySlice<UInt8>) throws -> Int? {
        guard prefix.count >= 16 else { return nil }
        let b = Array(prefix.prefix(16))
        let big: Bool
        switch b[0] {
        case UInt8(ascii: "l"): big = false
        case UInt8(ascii: "B"): big = true
        default: throw DBusError.malformedMessage("byte order \(b[0])")
        }
        guard b[3] == 1 else { throw DBusError.malformedMessage("protocol version \(b[3])") }
        func u32(_ at: Int) -> Int {
            let v = UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
            return Int(big ? v.byteSwapped : v)
        }
        let bodyLength = u32(4), fieldsLength = u32(12)
        let header = (16 + fieldsLength + 7) & ~7
        let total = header + bodyLength
        guard total <= maximumLength else { throw DBusError.malformedMessage("longer than 128 MiB") }
        return total
    }

    /// Decodes one complete message.
    public static func decode(_ bytes: [UInt8]) throws -> DBusMessage {
        guard let total = try frameLength(bytes[...]), total == bytes.count else {
            throw DBusError.malformedMessage("length does not match")
        }
        let big = bytes[0] == UInt8(ascii: "B")
        guard let type = DBusMessageType(rawValue: bytes[1]) else {
            throw DBusError.malformedMessage("unknown message type \(bytes[1])")
        }
        var d = DBusDecoder(bytes, bigEndian: big, start: 4)
        guard let bodyLength = try d.read(.uint32).intValue, let serial = try d.read(.uint32).intValue else {
            throw DBusError.malformedMessage("header")
        }
        let fields = try d.read(.array(.structure([.byte, .variant])))
        try d.skipPadding(to: 8)
        let bodyStart = d.offset
        guard bodyStart + bodyLength == bytes.count else { throw DBusError.malformedMessage("body length") }
        var m = DBusMessage(type: type)
        m.flags = DBusMessageFlags(rawValue: bytes[2])
        m.serial = UInt32(serial)
        guard m.serial != 0 else { throw DBusError.malformedMessage("serial 0") }
        var signature = ""
        for case .structure(let f) in fields.arrayValue ?? [] {
            guard f.count == 2, case .byte(let code) = f[0], let v = f[1].variantValue else { continue }
            func str() throws -> String {
                guard let s = v.stringValue else { throw DBusError.malformedMessage("header field \(code) has type \(v.signature)") }
                return s
            }
            switch code {
            case 1:
                guard case .objectPath(let p) = v else { throw DBusError.malformedMessage("PATH type") }
                m.path = p
            case 2: m.interface = try str()
            case 3: m.member = try str()
            case 4: m.errorName = try str()
            case 5:
                guard case .uint32(let r) = v else { throw DBusError.malformedMessage("REPLY_SERIAL type") }
                m.replySerial = r
            case 6: m.destination = try str()
            case 7: m.sender = try str()
            case 8:
                guard case .signature(let g) = v else { throw DBusError.malformedMessage("SIGNATURE type") }
                signature = g
            case 9:
                guard case .uint32(let n) = v else { throw DBusError.malformedMessage("UNIX_FDS type") }
                m.unixFDs = n
            default: break // unknown fields are ignored (spec)
            }
        }
        var bd = DBusDecoder(bytes, bigEndian: big, start: bodyStart, end: bytes.count, base: -bodyStart)
        m.body = try bd.read(signature: signature)
        guard bd.isAtEnd else { throw DBusError.malformedMessage("body longer than its signature") }
        try m.validate()
        return m
    }
}
