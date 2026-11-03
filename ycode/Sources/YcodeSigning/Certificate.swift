import Foundation

/// SHA-1 (FIPS 180-4). Signing identities and the certificates in a
/// provisioning profile are compared by the SHA-1 of the certificate's DER
/// bytes, which is also the hash `codesign --sign` and
/// `security find-identity` use. Not used for security.
public enum SHA1 {
    public static func digest(_ bytes: [UInt8]) -> [UInt8] {
        var message = bytes
        let bitLength = UInt64(bytes.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for i in (0..<8).reversed() { message.append(UInt8(truncatingIfNeeded: bitLength >> (8 * UInt64(i)))) }
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: message.count, by: 64) {
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(message[j]) << 24 | UInt32(message[j + 1]) << 16 | UInt32(message[j + 2]) << 8 | UInt32(message[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: f = (b & c) | (~b & d); k = 0x5A827999
                case 20..<40: f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60: f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default: f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = rotl(b, 30); b = a; a = t
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8(truncatingIfNeeded: v >> (8 * UInt32($0))) } }
    }

    /// Upper-case hexadecimal, as `security find-identity` prints it.
    public static func hex(_ bytes: [UInt8]) -> String {
        digest(bytes).map { String(format: "%02X", $0) }.joined()
    }
}

/// The few fields of an X.509 certificate signing needs: the subject's
/// common name and organizational unit (the team identifier of Apple's
/// developer certificates) and the end of the validity period. Read from
/// the DER encoding (ITU-T X.690; certificate layout RFC 5280 §4.1).
public struct CertificateSummary: Equatable, Sendable {
    public var commonName: String?
    public var organizationalUnit: String?
    public var notAfter: Date?

    public init(commonName: String? = nil, organizationalUnit: String? = nil, notAfter: Date? = nil) {
        self.commonName = commonName
        self.organizationalUnit = organizationalUnit
        self.notAfter = notAfter
    }

    /// One DER element: tag, and the range of its contents.
    struct Element {
        var tag: UInt8
        var contents: Range<Int>
        var end: Int
    }

    static func element(_ b: [UInt8], at i: Int) -> Element? {
        guard i + 1 < b.count else { return nil }
        let tag = b[i]
        var p = i + 1
        var length = Int(b[p])
        p += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n > 0, n <= 4, p + n <= b.count else { return nil }
            length = 0
            for k in 0..<n { length = length << 8 | Int(b[p + k]) }
            p += n
        }
        guard p + length <= b.count else { return nil }
        return Element(tag: tag, contents: p..<(p + length), end: p + length)
    }

    static func children(_ b: [UInt8], _ e: Element) -> [Element] {
        var out: [Element] = []
        var i = e.contents.lowerBound
        while i < e.contents.upperBound, let c = element(b, at: i) {
            out.append(c)
            i = c.end
        }
        return out
    }

    static func time(_ b: [UInt8], _ e: Element) -> Date? {
        let s = String(decoding: b[e.contents], as: UTF8.self)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        // UTCTime (0x17) has a two-digit year; GeneralizedTime (0x18) four.
        f.dateFormat = e.tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }

    /// Parses a DER certificate; nil when it is not one.
    public init?(der: [UInt8]) {
        guard let cert = Self.element(der, at: 0), cert.tag == 0x30,
              let tbs = Self.children(der, cert).first, tbs.tag == 0x30 else { return nil }
        var fields = Self.children(der, tbs)
        // An explicit version ([0]) comes first when present.
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        // serialNumber, signature, issuer, validity, subject, …
        guard fields.count >= 5 else { return nil }
        let validity = Self.children(der, fields[3])
        notAfter = validity.count == 2 ? Self.time(der, validity[1]) : nil
        for rdn in Self.children(der, fields[4]) {
            for attribute in Self.children(der, rdn) {
                let parts = Self.children(der, attribute)
                guard parts.count == 2, parts[0].tag == 0x06 else { continue }
                let oid = Array(der[parts[0].contents])
                let value = String(decoding: der[parts[1].contents], as: UTF8.self)
                // 2.5.4.3 commonName, 2.5.4.11 organizationalUnitName.
                if oid == [0x55, 0x04, 0x03] { commonName = value }
                if oid == [0x55, 0x04, 0x0B] { organizationalUnit = value }
            }
        }
    }

    /// The DER bytes of each certificate in PEM text, with the SHA-1 hash
    /// `security find-certificate -Z` prints before it when present.
    public static func pemBlocks(_ text: String) -> [(sha1: String?, der: [UInt8])] {
        var out: [(String?, [UInt8])] = []
        var hash: String?
        var body: String?
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("SHA-1 hash:") {
                hash = line.dropFirst("SHA-1 hash:".count).trimmingCharacters(in: .whitespaces).uppercased()
            } else if line == "-----BEGIN CERTIFICATE-----" {
                body = ""
            } else if line == "-----END CERTIFICATE-----" {
                if let b = body, let d = Data(base64Encoded: b) { out.append((hash, [UInt8](d))) }
                body = nil
                hash = nil
            } else if let b = body {
                body = b + line
            }
        }
        return out
    }
}
