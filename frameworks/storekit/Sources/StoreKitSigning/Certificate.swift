// X.509 certificates (RFC 5280) with P-256 keys: building self-signed and
// CA-issued certificates, and reading the parts a verifier needs
// (formats.md §2.1: one self-signed P-256 certificate per device).
import Crypto
import Foundation

enum OID {
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let commonName = "2.5.4.3"
    static let country = "2.5.4.6"
    static let organization = "2.5.4.10"
    static let organizationalUnit = "2.5.4.11"
    static let basicConstraints = "2.5.29.19"
    static let keyUsage = "2.5.29.15"
    static let subjectAltName = "2.5.29.17"
    static let subjectKeyIdentifier = "2.5.29.14"
    static let cmsData = "1.2.840.113549.1.7.1"
    static let cmsSignedData = "1.2.840.113549.1.7.2"
}

/// A distinguished name as an ordered list of attributes (one per RDN).
public struct DistinguishedName: Hashable, Sendable, CustomStringConvertible {
    public enum Attribute: String, Hashable, Sendable {
        case commonName = "CN", organization = "O", organizationalUnit = "OU", country = "C"

        var oid: String {
            switch self {
            case .commonName: return OID.commonName
            case .organization: return OID.organization
            case .organizationalUnit: return OID.organizationalUnit
            case .country: return OID.country
            }
        }

        init?(oid: String) {
            switch oid {
            case OID.commonName: self = .commonName
            case OID.organization: self = .organization
            case OID.organizationalUnit: self = .organizationalUnit
            case OID.country: self = .country
            default: return nil
            }
        }
    }

    /// Attributes in encoding order.
    public var attributes: [(Attribute, String)]

    public init(_ attributes: [(Attribute, String)]) { self.attributes = attributes }

    /// "CN=…, O=…" in encoding order.
    public var description: String { attributes.map { "\($0.0.rawValue)=\($0.1)" }.joined(separator: ", ") }

    public func value(_ a: Attribute) -> String? { attributes.first { $0.0 == a }?.1 }

    var der: [UInt8] {
        DER.sequence(attributes.map { attr, value in
            DER.set([DER.sequence([DER.oid(attr.oid), attr == .country ? DER.printableString(value) : DER.utf8String(value)])])
        })
    }

    public static func == (a: DistinguishedName, b: DistinguishedName) -> Bool { a.description == b.description }
    public func hash(into h: inout Hasher) { h.combine(description) }

    /// The subject and issuer of the JWS signing certificate (formats.md §2.1).
    public static let storeKitTesting = DistinguishedName([
        (.commonName, "StoreKit Testing in Xcode"), (.organization, "StoreKit Testing in Xcode"),
    ])

    /// The subject of the receipt signing certificate (formats.md §3).
    public static let receiptSigner = DistinguishedName([
        (.commonName, "StoreKit"), (.organization, "StoreKit"), (.organizationalUnit, "StoreKit"), (.country, "US"),
    ])
}

/// A parsed X.509 certificate with a P-256 key.
public struct Certificate: Hashable, Sendable {
    public let der: [UInt8]
    /// The encoded TBSCertificate (what the issuer signed).
    public let tbs: [UInt8]
    public let serialNumber: [UInt8]
    public let issuer: DistinguishedName
    /// The encoded issuer name (for CMS IssuerAndSerialNumber).
    public let issuerDER: [UInt8]
    public let subject: DistinguishedName
    public let notBefore: Date
    public let notAfter: Date
    public let publicKeyDER: [UInt8]
    public let signatureAlgorithm: String
    /// DER ECDSA signature.
    public let signature: [UInt8]
    /// Basic constraints cA, when the extension is present.
    public let isCA: Bool?
    /// OIDs of the critical extensions.
    public let criticalExtensions: [String]
    /// OIDs of all extensions in order.
    public let extensions: [String]

    public var publicKey: P256.Signing.PublicKey {
        // Validated in init.
        // swiftlint:disable:next force_try - validated in init
        try! P256.Signing.PublicKey(derRepresentation: publicKeyDER)
    }

    public init(der: [UInt8]) throws(DERError) {
        self.der = der
        let cert = try DERElement.parse(der).expect(0x30).children()
        guard cert.count == 3 else { throw DERError("certificate must have 3 parts") }
        tbs = cert[0].encoded
        let alg = try cert[1].expect(0x30).children()
        signatureAlgorithm = alg.first?.oidValue ?? ""
        let sig = try cert[2].expect(0x03)
        guard sig.content.first == 0 else { throw DERError("signature has unused bits") }
        signature = Array(sig.content.dropFirst())
        var fields = try cert[0].expect(0x30).children()
        if fields.first?.tag == 0xA0 { fields.removeFirst() }
        guard fields.count >= 6 else { throw DERError("short TBSCertificate") }
        serialNumber = try fields[0].expect(0x02).content
        issuerDER = fields[2].encoded
        issuer = try Certificate.name(fields[2])
        let validity = try fields[3].expect(0x30).children()
        guard validity.count == 2, let nb = validity[0].dateValue, let na = validity[1].dateValue else { throw DERError("bad validity") }
        notBefore = nb
        notAfter = na
        subject = try Certificate.name(fields[4])
        publicKeyDER = fields[5].encoded
        do { _ = try P256.Signing.PublicKey(derRepresentation: publicKeyDER) } catch { throw DERError("not a P-256 public key") }
        var ca: Bool?
        var critical: [String] = []
        var all: [String] = []
        if let extWrapper = fields.dropFirst(6).first(where: { $0.tag == 0xA3 }) {
            for ext in try extWrapper.children().first?.children() ?? [] {
                let parts = try ext.children()
                guard let oid = parts.first?.oidValue else { continue }
                all.append(oid)
                if parts.count == 3, parts[1].tag == 0x01, parts[1].content == [0xFF] { critical.append(oid) }
                if oid == OID.basicConstraints, let value = parts.last {
                    let bc = try DERElement.parse(value.content).children()
                    ca = bc.first.map { $0.tag == 0x01 && $0.content == [0xFF] } ?? false
                }
            }
        }
        isCA = ca
        criticalExtensions = critical
        extensions = all
    }

    public init(der: Data) throws(DERError) { try self.init(der: Array(der)) }

    static func name(_ e: DERElement) throws(DERError) -> DistinguishedName {
        var attrs: [(DistinguishedName.Attribute, String)] = []
        for rdn in try e.expect(0x30).children() {
            for atv in try rdn.children() {
                let parts = try atv.children()
                guard parts.count == 2, let oid = parts[0].oidValue, let value = parts[1].stringValue else { continue }
                if let a = DistinguishedName.Attribute(oid: oid) { attrs.append((a, value)) }
            }
        }
        return DistinguishedName(attrs)
    }

    /// Whether `issuerKey` made this certificate's signature.
    public func isSigned(by issuerKey: P256.Signing.PublicKey) -> Bool {
        guard signatureAlgorithm == OID.ecdsaWithSHA256,
              let sig = try? P256.Signing.ECDSASignature(derRepresentation: signature) else { return false }
        return issuerKey.isValidSignature(sig, for: SHA256.hash(data: tbs))
    }

    public func isValid(at date: Date) -> Bool { notBefore <= date && date <= notAfter }

    /// PEM text.
    public var pem: String {
        let b64 = Data(der).base64EncodedString()
        var lines: [String] = []
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: 64, limitedBy: b64.endIndex) ?? b64.endIndex
            lines.append(String(b64[i..<j]))
            i = j
        }
        return "-----BEGIN CERTIFICATE-----\n" + lines.joined(separator: "\n") + "\n-----END CERTIFICATE-----\n"
    }

    // MARK: Building

    /// Who signs a new certificate.
    public enum Signer {
        /// The subject's own key (a self-signed certificate).
        case selfSigned(P256.Signing.PrivateKey)
        /// An issuing certificate and its key.
        case issuer(Certificate, P256.Signing.PrivateKey)
    }

    /// Builds and signs a certificate.
    /// - Parameters:
    ///   - isCA: basic constraints cA (critical); a leaf gets an empty basic-constraints value.
    ///   - subjectAltDNSName: the subject alternative name (Ycode's choice; README spec question 8).
    public static func make(
        subject: DistinguishedName, publicKey: P256.Signing.PublicKey, notBefore: Date, notAfter: Date,
        isCA: Bool = false, subjectAltDNSName: String? = "storekit-testing.invalid", signer: Signer,
        serialNumber: [UInt8]? = nil
    ) throws -> Certificate {
        var serial = serialNumber ?? (0..<16).map { _ in UInt8.random(in: 0...255) }
        serial[0] &= 0x7F
        if serial[0] == 0 { serial[0] = 0x01 }
        let algorithm = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])
        var extensions: [[UInt8]] = [
            DER.sequence([
                DER.oid(OID.basicConstraints), DER.boolean(true),
                DER.octetString(DER.sequence(isCA ? [DER.boolean(true)] : [])),
            ]),
        ]
        if let name = subjectAltDNSName {
            extensions.append(DER.sequence([DER.oid(OID.subjectAltName), DER.octetString(DER.sequence([DER.implicitPrimitive(2, Array(name.utf8))]))]))
        }
        // Key usage: digitalSignature (0); a CA also keyCertSign (5) and cRLSign (6).
        extensions.append(DER.sequence([
            DER.oid(OID.keyUsage), DER.boolean(true), DER.octetString(DER.namedBits(isCA ? [0, 5, 6] : [0])),
        ]))
        let spki = Array(publicKey.derRepresentation)
        extensions.append(DER.sequence([
            DER.oid(OID.subjectKeyIdentifier), DER.octetString(DER.octetString(Array(Insecure.SHA1.hash(data: spki)))),
        ]))
        let issuerName: [UInt8]
        let signingKey: P256.Signing.PrivateKey
        switch signer {
        case .selfSigned(let key): issuerName = subject.der; signingKey = key
        case .issuer(let cert, let key): issuerName = cert.issuerDERForChildren; signingKey = key
        }
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.unsignedInteger(serial),
            algorithm,
            issuerName,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            subject.der,
            spki,
            DER.explicit(3, DER.sequence(extensions)),
        ])
        let signature = try signingKey.signature(for: SHA256.hash(data: tbs))
        let der = DER.sequence([tbs, algorithm, DER.bitString(Array(signature.derRepresentation))])
        return try Certificate(der: der)
    }

    /// This certificate's subject as encoded (the issuer name of certificates it signs).
    var issuerDERForChildren: [UInt8] {
        // The subject is the 6th field (index 5 with the version, 4 without) of the TBS.
        guard let fields = try? DERElement.parse(tbs).children() else { return subject.der }
        let f = fields.first?.tag == 0xA0 ? Array(fields.dropFirst()) : fields
        return f.count > 4 ? f[4].encoded : subject.der
    }
}
