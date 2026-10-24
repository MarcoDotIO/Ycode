// A minimal ASN.1 DER encoder and decoder (ITU-T X.690) for certificates,
// the StoreKit 1 receipt and its CMS envelope. Definite lengths and
// low tag numbers only, which is all these structures use.
import Foundation

/// DER encoding helpers. Each function returns one complete TLV.
public enum DER {
    public static func tlv(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] { [tag] + length(content.count) + content }

    static func length(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return [0x80 | UInt8(bytes.count)] + bytes
    }

    public static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    public static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    /// A SET OF with its elements in DER order (sorted by their encodings).
    public static func setOf(_ items: [[UInt8]]) -> [UInt8] {
        tlv(0x31, items.sorted { $0.lexicographicallyPrecedes($1) }.flatMap { $0 })
    }

    public static func boolean(_ v: Bool) -> [UInt8] { tlv(0x01, [v ? 0xFF : 0x00]) }

    public static func integer(_ v: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var x = v
        repeat {
            bytes.insert(UInt8(truncatingIfNeeded: x & 0xFF), at: 0)
            x >>= 8
        } while x != 0 && x != -1
        // Keep the sign bit right.
        if v >= 0, bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        if v < 0, bytes[0] & 0x80 == 0 { bytes.insert(0xFF, at: 0) }
        return tlv(0x02, bytes)
    }

    /// A non-negative integer from big-endian magnitude bytes.
    public static func unsignedInteger(_ magnitude: [UInt8]) -> [UInt8] {
        var bytes = Array(magnitude.drop { $0 == 0 })
        if bytes.isEmpty { bytes = [0] }
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return tlv(0x02, bytes)
    }

    public static func null() -> [UInt8] { [0x05, 0x00] }

    public static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { UInt64($0)! }
        var content: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            content += chunk
        }
        return tlv(0x06, content)
    }

    public static func bitString(_ bytes: [UInt8], unusedBits: UInt8 = 0) -> [UInt8] { tlv(0x03, [unusedBits] + bytes) }

    /// A named-bit BIT STRING (RFC 5280 key usage) with trailing zero bits removed.
    public static func namedBits(_ bits: [Int]) -> [UInt8] {
        guard let maxBit = bits.max() else { return bitString([]) }
        var bytes = [UInt8](repeating: 0, count: maxBit / 8 + 1)
        for b in bits { bytes[b / 8] |= 0x80 >> UInt8(b % 8) }
        return bitString(bytes, unusedBits: UInt8(7 - maxBit % 8))
    }

    public static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    public static func utf8String(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    public static func printableString(_ s: String) -> [UInt8] { tlv(0x13, Array(s.utf8)) }
    public static func ia5String(_ s: String) -> [UInt8] { tlv(0x16, Array(s.utf8)) }

    /// UTCTime `YYMMDDHHMMSSZ` (years 1950–2049) or GeneralizedTime otherwise (RFC 5280 §4.1.2.5).
    public static func time(_ date: Date) -> [UInt8] {
        let c = utcComponents(date)
        if (1950...2049).contains(c.year!) {
            return tlv(0x17, Array(String(format: "%02d%02d%02d%02d%02d%02dZ", c.year! % 100, c.month!, c.day!, c.hour!, c.minute!, c.second!).utf8))
        }
        return tlv(0x18, Array(String(format: "%04d%02d%02d%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!).utf8))
    }

    /// `[n]` EXPLICIT (constructed, context-specific).
    public static func explicit(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0xA0 | n, content) }

    /// `[n]` IMPLICIT constructed (replaces the tag of a constructed value).
    public static func implicitConstructed(_ n: UInt8, contentsOf items: [[UInt8]]) -> [UInt8] { tlv(0xA0 | n, items.flatMap { $0 }) }

    /// `[n]` IMPLICIT primitive.
    public static func implicitPrimitive(_ n: UInt8, _ content: [UInt8]) -> [UInt8] { tlv(0x80 | n, content) }

    static func utcComponents(_ date: Date) -> DateComponents {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }
}

/// A DER decoding error.
public struct DERError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { "DER: \(message)" }
}

/// One decoded TLV.
public struct DERElement: Equatable, Sendable {
    public let tag: UInt8
    /// The content octets.
    public let content: [UInt8]
    /// The whole TLV as encoded.
    public let encoded: [UInt8]

    public var isConstructed: Bool { tag & 0x20 != 0 }

    /// Decodes exactly one element covering all of `bytes`.
    public static func parse(_ bytes: [UInt8]) throws(DERError) -> DERElement {
        var i = 0
        let e = try parse(bytes, at: &i)
        guard i == bytes.count else { throw DERError("trailing bytes") }
        return e
    }

    static func parse(_ bytes: [UInt8], at i: inout Int) throws(DERError) -> DERElement {
        let start = i
        guard i + 2 <= bytes.count else { throw DERError("truncated header") }
        let tag = bytes[i]
        guard tag & 0x1F != 0x1F else { throw DERError("high tag numbers are not supported") }
        i += 1
        var len = Int(bytes[i])
        i += 1
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n >= 1, n <= 4, i + n <= bytes.count else { throw DERError("bad length") }
            len = 0
            for _ in 0..<n { len = (len << 8) | Int(bytes[i]); i += 1 }
            guard len >= 0x80 else { throw DERError("non-minimal length") }
        }
        guard len <= bytes.count - i else { throw DERError("truncated content") }
        let content = Array(bytes[i..<i + len])
        i += len
        return DERElement(tag: tag, content: content, encoded: Array(bytes[start..<i]))
    }

    /// The elements inside a constructed value.
    public func children() throws(DERError) -> [DERElement] {
        guard isConstructed else { throw DERError("not constructed (tag \(tag))") }
        var out: [DERElement] = []
        var i = 0
        while i < content.count { out.append(try DERElement.parse(content, at: &i)) }
        return out
    }

    public func expect(_ tag: UInt8) throws(DERError) -> DERElement {
        guard self.tag == tag else { throw DERError("expected tag \(tag), found \(self.tag)") }
        return self
    }

    /// INTEGER as Int (small values).
    public var intValue: Int? {
        guard tag == 0x02, !content.isEmpty, content.count <= 8 else { return nil }
        var v = Int(Int8(bitPattern: content[0]))
        for b in content.dropFirst() { v = (v << 8) | Int(b) }
        return v
    }

    /// OBJECT IDENTIFIER as dotted text.
    public var oidValue: String? {
        guard tag == 0x06, let first = content.first else { return nil }
        var arcs = [UInt64(first / 40), UInt64(first % 40)]
        var v: UInt64 = 0
        for b in content.dropFirst() {
            v = (v << 7) | UInt64(b & 0x7F)
            if b & 0x80 == 0 { arcs.append(v); v = 0 }
        }
        return arcs.map(String.init).joined(separator: ".")
    }

    /// The text of a string type.
    public var stringValue: String? {
        guard [0x0C, 0x13, 0x16, 0x14, 0x1E].contains(tag) else { return nil }
        return String(decoding: content, as: UTF8.self)
    }

    /// UTCTime or GeneralizedTime.
    public var dateValue: Date? {
        guard tag == 0x17 || tag == 0x18, let s = stringValue ?? String(validating: content, as: UTF8.self) else { return nil }
        let digits = s.dropLast()
        guard s.last == "Z", digits.allSatisfy(\.isNumber) else { return nil }
        var c = DateComponents()
        var rest = Substring(digits)
        func take(_ n: Int) -> Int? {
            guard rest.count >= n, let v = Int(rest.prefix(n)) else { return nil }
            rest = rest.dropFirst(n)
            return v
        }
        if tag == 0x17 {
            guard let yy = take(2) else { return nil }
            c.year = yy < 50 ? 2000 + yy : 1900 + yy
        } else {
            c.year = take(4)
        }
        c.month = take(2); c.day = take(2); c.hour = take(2); c.minute = take(2); c.second = take(2)
        guard rest.isEmpty else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)
    }
}
