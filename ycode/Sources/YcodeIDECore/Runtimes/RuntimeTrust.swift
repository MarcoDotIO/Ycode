// Whom route B trusts (`runtime-downloads.md` §4.1): the asset service's TLS
// chain and its signed answer both end at Apple's public root certificates.
// Ycode does not carry those certificates: it fetches them from Apple's
// certificate authority page (served over the public web PKI) for the user,
// checks each against its published SHA-256 fingerprint, and keeps them in
// its own folder. The answer is a JWS (ES256, `x5c` chain); its signature
// and chain are checked with swift-crypto. Portable.

import Crypto
import Foundation

/// A root certificate Ycode pins by fingerprint.
public struct RuntimeTrustRoot: Sendable, Equatable {
    public var name: String
    public var url: URL
    /// SHA-256 of the DER certificate, hex, as Apple publishes it.
    public var sha256: String

    /// The root of the asset service's TLS certificate.
    public static let appleRoot = RuntimeTrustRoot(name: "AppleIncRootCertificate", url: URL(string: "https://www.apple.com/appleca/AppleIncRootCertificate.cer")!,
                                                   sha256: "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024")
    /// The root of the chain in the asset service's signed answer.
    public static let appleRootG3 = RuntimeTrustRoot(name: "AppleRootCA-G3", url: URL(string: "https://www.apple.com/certificateauthority/AppleRootCA-G3.cer")!,
                                                     sha256: "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179")
}

public struct RuntimeTrust: Sendable {
    public var folder: String
    public init(folder: String) { self.folder = folder }

    var directory: String { folder + "/.trust" }

    /// The root's DER bytes: the kept copy when its fingerprint still
    /// matches, else fetched again and checked.
    public func certificate(_ root: RuntimeTrustRoot, transport: any RuntimeTransport) async throws -> [UInt8] {
        let path = directory + "/\(root.name).cer"
        if let d = FileManager.default.contents(atPath: path), Self.hex(SHA256.hash(data: d)) == root.sha256 { return Array(d) }
        let r = try await transport.get(root.url, etag: nil)
        guard r.status == 200, Self.hex(SHA256.hash(data: r.body)) == root.sha256 else {
            throw RuntimeDownloadError.untrusted("\(root.name) from \(root.url.host ?? "apple.com") does not have its published fingerprint")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try r.body.write(to: URL(fileURLWithPath: path), options: .atomic)
        return Array(r.body)
    }

    /// The root as a PEM file for curl's `--cacert`.
    public func pemFile(_ root: RuntimeTrustRoot, transport: any RuntimeTransport) async throws -> String {
        let der = try await certificate(root, transport: transport)
        let path = directory + "/\(root.name).pem"
        let pem = "-----BEGIN CERTIFICATE-----\n" + Data(der).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
            + "\n-----END CERTIFICATE-----\n"
        if (try? String(contentsOfFile: path, encoding: .utf8)) != pem { try pem.write(toFile: path, atomically: true, encoding: .utf8) }
        return path
    }

    static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
}

// MARK: - The signed answer

/// A compact JWS whose header carries the signer's certificate chain.
public struct RuntimeSignedDocument: Sendable {
    public var header: [String: Any] { (try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]) ?? [:] }
    public let headerData: Data
    public let payload: Data
    public let signingInput: Data
    public let signature: [UInt8]

    public init(_ text: String) throws {
        let parts = text.trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Self.base64URL(parts[0]), let p = Self.base64URL(parts[1]), let s = Self.base64URL(parts[2]) else {
            throw RuntimeDownloadError.untrusted("the answer is not a signed document")
        }
        headerData = h
        payload = p
        signingInput = Data((parts[0] + "." + parts[1]).utf8)
        signature = Array(s)
    }

    static func base64URL<S: StringProtocol>(_ s: S) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }

    /// Checks the ES256 signature with the first certificate's key, each
    /// certificate's signature by the next, the last by `root`, and the
    /// dates. Returns the signer's subject common name.
    @discardableResult
    public func verify(root rootDER: [UInt8], at date: Date = Date()) throws -> String {
        guard header["alg"] as? String == "ES256" else { throw RuntimeDownloadError.untrusted("unexpected signature algorithm") }
        let chain = try (header["x5c"] as? [String] ?? []).map { b64 -> RuntimeCertificate in
            guard let d = Data(base64Encoded: b64) else { throw RuntimeDownloadError.untrusted("bad certificate in the chain") }
            return try RuntimeCertificate(der: Array(d))
        }
        guard let leaf = chain.first else { throw RuntimeDownloadError.untrusted("no signing certificate") }
        let root = try RuntimeCertificate(der: rootDER)
        guard leaf.verifies(signature: signature, over: signingInput, hash: .sha256) else {
            throw RuntimeDownloadError.untrusted("the signature does not match the signing certificate")
        }
        for (i, cert) in chain.enumerated() {
            guard cert.isValid(at: date) else { throw RuntimeDownloadError.untrusted("\(cert.commonName ?? "a certificate") is out of date") }
            let issuer = i + 1 < chain.count ? chain[i + 1] : root
            if i + 1 < chain.count, issuer.isCA != true { throw RuntimeDownloadError.untrusted("\(issuer.commonName ?? "a certificate") is not a CA") }
            guard cert.isSigned(by: issuer) else {
                throw RuntimeDownloadError.untrusted("\(cert.commonName ?? "a certificate") is not signed by \(issuer.commonName ?? "its issuer")")
            }
        }
        // A chain that already ends in the root itself: the root signed the last one above.
        return leaf.commonName ?? ""
    }
}

/// Just enough X.509 for the chain: the signed part, the algorithm, the
/// ECDSA key (P-256 or P-384), the dates, the CA flag and the common name.
public struct RuntimeCertificate: Sendable {
    public let tbs: [UInt8]
    public let signatureAlgorithm: String
    public let signature: [UInt8]
    public let curve: String
    public let publicKey: [UInt8]
    public let notBefore: Date
    public let notAfter: Date
    public let isCA: Bool?
    public let commonName: String?

    enum OID {
        static let ecdsaSHA256 = "1.2.840.10045.4.3.2"
        static let ecdsaSHA384 = "1.2.840.10045.4.3.3"
        static let p256 = "1.2.840.10045.3.1.7"
        static let p384 = "1.3.132.0.34"
        static let commonName = "2.5.4.3"
        static let basicConstraints = "2.5.29.19"
    }

    public enum Hash { case sha256, sha384 }

    public init(der: [UInt8]) throws {
        func bad(_ m: String) -> RuntimeDownloadError { .untrusted("certificate: \(m)") }
        let cert = try DERItem.parse(der).children()
        guard cert.count == 3 else { throw bad("not three parts") }
        tbs = cert[0].encoded
        signatureAlgorithm = try cert[1].children().first?.oid ?? ""
        guard cert[2].tag == 0x03, cert[2].content.first == 0 else { throw bad("bad signature") }
        signature = Array(cert[2].content.dropFirst())
        var f = try cert[0].children()
        if f.first?.tag == 0xA0 { f.removeFirst() }
        guard f.count >= 6 else { throw bad("short") }
        let validity = try f[3].children()
        guard validity.count == 2, let nb = validity[0].date, let na = validity[1].date else { throw bad("bad dates") }
        notBefore = nb
        notAfter = na
        var cn: String?
        for rdn in try f[4].children() {
            for atv in try rdn.children() {
                let p = try atv.children()
                if p.count == 2, p[0].oid == OID.commonName { cn = String(decoding: p[1].content, as: UTF8.self) }
            }
        }
        commonName = cn
        let spki = try f[5].children()
        guard spki.count == 2, spki[1].tag == 0x03 else { throw bad("bad key") }
        let alg = try spki[0].children()
        curve = alg.count > 1 ? alg[1].oid ?? "" : ""
        publicKey = Array(spki[1].content.dropFirst())
        var ca: Bool?
        if let ext = f.dropFirst(6).first(where: { $0.tag == 0xA3 }) {
            for e in try ext.children().first?.children() ?? [] {
                let parts = try e.children()
                guard parts.first?.oid == OID.basicConstraints, let value = parts.last else { continue }
                let bc = try DERItem.parse(value.content).children()
                ca = bc.first.map { $0.tag == 0x01 && $0.content == [0xFF] } ?? false
            }
        }
        isCA = ca
    }

    public func isValid(at d: Date) -> Bool { notBefore <= d && d <= notAfter }

    /// An ECDSA signature (DER, or the raw r‖s of a JWS) by this certificate's key.
    public func verifies(signature sig: [UInt8], over data: Data, hash: Hash) -> Bool {
        switch curve {
        case OID.p256:
            guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey) else { return false }
            let s = (try? P256.Signing.ECDSASignature(derRepresentation: sig)) ?? (try? P256.Signing.ECDSASignature(rawRepresentation: sig))
            guard let s else { return false }
            return hash == .sha256 ? key.isValidSignature(s, for: SHA256.hash(data: data)) : key.isValidSignature(s, for: SHA384.hash(data: data))
        case OID.p384:
            guard let key = try? P384.Signing.PublicKey(x963Representation: publicKey) else { return false }
            let s = (try? P384.Signing.ECDSASignature(derRepresentation: sig)) ?? (try? P384.Signing.ECDSASignature(rawRepresentation: sig))
            guard let s else { return false }
            return hash == .sha256 ? key.isValidSignature(s, for: SHA256.hash(data: data)) : key.isValidSignature(s, for: SHA384.hash(data: data))
        default:
            return false
        }
    }

    /// Whether `issuer`'s key made this certificate's signature.
    public func isSigned(by issuer: RuntimeCertificate) -> Bool {
        switch signatureAlgorithm {
        case OID.ecdsaSHA256: issuer.verifies(signature: signature, over: Data(tbs), hash: .sha256)
        case OID.ecdsaSHA384: issuer.verifies(signature: signature, over: Data(tbs), hash: .sha384)
        default: false
        }
    }
}

/// One DER element.
struct DERItem {
    let tag: UInt8
    let content: [UInt8]
    let encoded: [UInt8]

    static func parse(_ b: [UInt8]) throws -> DERItem {
        var i = 0
        return try parse(b, &i)
    }

    static func parse(_ b: [UInt8], _ i: inout Int) throws -> DERItem {
        let bad = RuntimeDownloadError.untrusted("certificate: bad DER")
        let start = i
        guard i + 2 <= b.count else { throw bad }
        let tag = b[i]
        var len = Int(b[i + 1])
        i += 2
        if len & 0x80 != 0 {
            let n = len & 0x7F
            guard n >= 1, n <= 4, i + n <= b.count else { throw bad }
            len = 0
            for k in 0..<n { len = len << 8 | Int(b[i + k]) }
            i += n
        }
        guard len >= 0, i + len <= b.count else { throw bad }
        let item = DERItem(tag: tag, content: Array(b[i..<i + len]), encoded: Array(b[start..<i + len]))
        i += len
        return item
    }

    func children() throws -> [DERItem] {
        var out: [DERItem] = []
        var i = 0
        while i < content.count { out.append(try DERItem.parse(content, &i)) }
        return out
    }

    var oid: String? {
        guard tag == 0x06, let first = content.first else { return nil }
        var parts = [Int(first) / 40, Int(first) % 40]
        var v = 0
        for byte in content.dropFirst() {
            v = v << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { parts.append(v); v = 0 }
        }
        return parts.map(String.init).joined(separator: ".")
    }

    /// UTCTime (0x17) or GeneralizedTime (0x18).
    var date: Date? {
        let s = String(decoding: content, as: UTF8.self)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = tag == 0x17 ? "yyMMddHHmmss'Z'" : "yyyyMMddHHmmss'Z'"
        return f.date(from: s)
    }
}
