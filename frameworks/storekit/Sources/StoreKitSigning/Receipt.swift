// The StoreKit 1 receipt (formats.md §3): the documented receipt ASN.1
// payload in a CMS SignedData envelope (RFC 5652) signed with the device's
// receipt identity.
import Crypto
import Foundation
import StoreKitEngine

public enum Receipt {
    /// `YYYY-MM-DDTHH:MM:SSZ`.
    public static func rfc3339(_ date: Date) -> String {
        let c = DER.utcComponents(date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func attribute(_ type: Int, _ value: [UInt8]) -> [UInt8] {
        DER.sequence([DER.integer(type), DER.integer(1), DER.octetString(value)])
    }

    /// The SHA-1 of attribute 5: device identifier bytes, then the opaque
    /// value, then the bundle identifier attribute's value bytes (the
    /// documented receipt-validation hash, level 1).
    public static func deviceHash(vendorID: UUID, opaque: [UInt8], bundleIDValue: [UInt8]) -> [UInt8] {
        let u = vendorID.uuid
        let uuidBytes: [UInt8] = [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
        return Array(Insecure.SHA1.hash(data: uuidBytes + opaque + bundleIDValue))
    }

    /// The transactions a receipt lists: purchased or restored, not finished consumables.
    public static func listed(_ records: [TransactionRecord]) -> [TransactionRecord] {
        records.filter { r in
            (r.state == .purchased || r.state == .restored) && !(r.productType == .consumable && r.isFinished)
        }.sorted { $0.id < $1.id }
    }

    /// The receipt payload: a SET of { type, version 1, value } with
    /// attributes 0, 1, 2, 3, 4, 5, 8, 12, 17 × n, 21 (formats.md §3).
    public static func payload(
        bundleID: String, appVersion: String, vendorID: UUID, opaque: [UInt8], creationDate: Date, purchases: [TransactionRecord]
    ) -> [UInt8] {
        precondition(opaque.count == 8)
        let bundleValue = DER.utf8String(bundleID)
        var attrs: [[UInt8]] = [
            attribute(0, DER.utf8String("Xcode")),
            attribute(1, DER.integer(0)),
            attribute(2, bundleValue),
            attribute(3, DER.utf8String(appVersion)),
            attribute(4, opaque),
            attribute(5, deviceHash(vendorID: vendorID, opaque: opaque, bundleIDValue: bundleValue)),
            attribute(8, DER.ia5String("")),
            attribute(12, DER.ia5String(rfc3339(creationDate))),
        ]
        for r in listed(purchases) {
            var fields: [[UInt8]] = [
                attribute(1701, DER.integer(r.quantity)),
                attribute(1702, DER.utf8String(r.productID)),
                attribute(1703, DER.utf8String(String(r.id))),
                attribute(1704, DER.ia5String(rfc3339(Date(storeMilliseconds: r.purchaseDate)))),
            ]
            if r.productType == .autoRenewable {
                if let e = r.expiresDate { fields.append(attribute(1708, DER.ia5String(rfc3339(Date(storeMilliseconds: e))))) }
                fields.append(attribute(1719, DER.integer(r.offer?.type == .introductory ? 1 : 0)))
            }
            attrs.append(attribute(17, DER.set(fields)))
        }
        attrs.append(attribute(21, DER.ia5String("4001-01-01T00:00:00Z")))
        return DER.set(attrs)
    }

    /// Wraps a payload in CMS SignedData (no signed attributes; the signature
    /// covers the content's SHA-256).
    public static func signedData(payload: [UInt8], identity: SigningIdentity) throws -> [UInt8] {
        let sha256 = DER.sequence([DER.oid(OID.sha256)])
        let ecdsa = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])
        let signature = try identity.privateKey.signature(for: SHA256.hash(data: payload))
        let signer = DER.sequence([
            DER.integer(1),
            DER.sequence([identity.certificate.issuerDER, DER.unsignedInteger(identity.certificate.serialNumber)]),
            sha256,
            ecdsa,
            DER.octetString(Array(signature.derRepresentation)),
        ])
        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([sha256]),
            DER.sequence([DER.oid(OID.cmsData), DER.explicit(0, DER.octetString(payload))]),
            DER.implicitConstructed(0, contentsOf: identity.certificates.map(\.der)),
            DER.set([signer]),
        ])
        return DER.sequence([DER.oid(OID.cmsSignedData), DER.explicit(0, signedData)])
    }

    /// Builds the whole receipt file.
    public static func build(
        bundleID: String, appVersion: String, vendorID: UUID, opaque: [UInt8], creationDate: Date, purchases: [TransactionRecord],
        identity: SigningIdentity
    ) throws -> Data {
        Data(try signedData(
            payload: payload(bundleID: bundleID, appVersion: appVersion, vendorID: vendorID, opaque: opaque, creationDate: creationDate,
                             purchases: purchases),
            identity: identity))
    }
}

/// A receipt read back: the payload attributes and the signer, verified.
public struct DecodedReceipt: Sendable {
    public struct Attribute: Hashable, Sendable {
        public let type: Int
        public let version: Int
        public let value: [UInt8]
    }

    public let attributes: [Attribute]
    public let certificate: Certificate

    /// Parses a receipt and checks its signature with the embedded certificate
    /// (and, if given, that the certificate is the expected one).
    public init(data: Data, expectedCertificate: Certificate? = nil) throws {
        let ci = try DERElement.parse(Array(data)).expect(0x30).children()
        guard ci.count == 2, ci[0].oidValue == OID.cmsSignedData else { throw DERError("not CMS SignedData") }
        let sd = try ci[1].expect(0xA0).children()[0].expect(0x30).children()
        guard sd.count >= 4 else { throw DERError("short SignedData") }
        let encap = try sd[2].children()
        guard encap.first?.oidValue == OID.cmsData, encap.count == 2 else { throw DERError("no data content") }
        let payload = try encap[1].children()[0].expect(0x04).content
        guard let certSet = sd.first(where: { $0.tag == 0xA0 }), let certElement = try certSet.children().first else {
            throw DERError("no certificate")
        }
        let cert = try Certificate(der: certElement.encoded)
        if let expectedCertificate, expectedCertificate.der != cert.der { throw DERError("unexpected signer") }
        guard let signer = try sd.last?.expect(0x31).children().first?.children(), signer.count >= 5 else { throw DERError("no signer") }
        let sig = try signer[4].expect(0x04).content
        guard let ecdsa = try? P256.Signing.ECDSASignature(derRepresentation: sig),
              cert.publicKey.isValidSignature(ecdsa, for: SHA256.hash(data: payload)) else { throw DERError("bad signature") }
        certificate = cert
        attributes = try Self.attributes(payload)
    }

    static func attributes(_ set: [UInt8]) throws -> [Attribute] {
        try DERElement.parse(set).expect(0x31).children().map { e in
            let parts = try e.children()
            guard parts.count == 3, let t = parts[0].intValue, let v = parts[1].intValue else { throw DERError("bad attribute") }
            return Attribute(type: t, version: v, value: try parts[2].expect(0x04).content)
        }
    }

    public func values(_ type: Int) -> [[UInt8]] { attributes.filter { $0.type == type }.map(\.value) }

    /// The in-app purchase entries (type 17), each as its own attributes.
    public func inAppPurchases() throws -> [[Attribute]] { try values(17).map(Self.attributes) }
}
