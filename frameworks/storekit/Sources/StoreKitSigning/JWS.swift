// Compact JWS (RFC 7515) with ES256 (RFC 7518 §3.4): the builder used for
// every signed transaction, renewal info and app transaction (formats.md
// §2.1), and a verifier.
import Crypto
import Foundation
import StoreKitConfiguration
import StoreKitEngine

public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ text: Substring) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let rem = s.count % 4
        if rem == 1 { return nil }
        if rem > 0 { s += String(repeating: "=", count: 4 - rem) }
        return Data(base64Encoded: s)
    }
}

/// A decoded compact JWS.
public struct DecodedJWS: Sendable {
    public let header: JSONValue
    public let payload: JSONValue
    public let payloadData: Data
    /// The 64-byte r‖s signature.
    public let signature: Data
    /// `base64url(header).base64url(payload)`.
    public let signingInput: Data
    /// The `x5c` certificates, leaf first.
    public let certificates: [Certificate]
}

public enum JWS {
    /// The `kid` of local-store signatures (formats.md §2.1).
    public static let keyID = "Apple_Xcode_Key"

    /// The protected header: `alg` ES256, `kid`, `typ` JWT, `x5c` with the identity's certificates.
    public static func header(for identity: SigningIdentity, keyID: String = JWS.keyID) -> JSONValue {
        .object([
            "alg": .string("ES256"), "kid": .string(keyID), "typ": .string("JWT"),
            "x5c": .array(identity.certificates.map { .string(Data($0.der).base64EncodedString()) }),
        ])
    }

    /// Signs a payload (written compact with sorted keys).
    /// - Parameter corruptSignature: produce a signature that does not verify
    ///   (the `verification` simulated error `invalidSignature`, testing-session.md §9).
    public static func sign(_ payload: JSONValue, identity: SigningIdentity, keyID: String = JWS.keyID, corruptSignature: Bool = false)
        throws -> String
    {
        try sign(payloadData: Data(JSONWriter.compact(payload).utf8), identity: identity, keyID: keyID, corruptSignature: corruptSignature)
    }

    public static func sign(payloadData: Data, identity: SigningIdentity, keyID: String = JWS.keyID, corruptSignature: Bool = false)
        throws -> String
    {
        let headerText = Base64URL.encode(Data(JSONWriter.compact(header(for: identity, keyID: keyID)).utf8))
        let input = headerText + "." + Base64URL.encode(payloadData)
        var signature = try identity.privateKey.signature(for: Data(input.utf8)).rawRepresentation
        if corruptSignature { signature[signature.startIndex + 31] ^= 0x01 }
        return input + "." + Base64URL.encode(signature)
    }

    /// Splits and decodes a compact JWS without checking the signature.
    public static func decode(_ compact: String) throws(VerificationFailure) -> DecodedJWS {
        let parts = compact.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let h = Base64URL.decode(parts[0]), let p = Base64URL.decode(parts[1]),
              let s = Base64URL.decode(parts[2]) else { throw VerificationFailure(.invalidEncoding, "not a compact JWS") }
        guard let header = try? JSONParser.parse(h), let payload = try? JSONParser.parse(p) else {
            throw VerificationFailure(.invalidEncoding, "header or payload is not JSON")
        }
        var certs: [Certificate] = []
        if let x5c = header["x5c"]?.arrayValue {
            for item in x5c {
                guard let b64 = item.stringValue, let der = Data(base64Encoded: b64) else {
                    throw VerificationFailure(.invalidCertificateChain, "x5c entry is not base64")
                }
                do { certs.append(try Certificate(der: der)) } catch {
                    throw VerificationFailure(.invalidCertificateChain, "x5c entry is not a P-256 certificate (\(error))")
                }
            }
        }
        return DecodedJWS(
            header: header, payload: payload, payloadData: p, signature: s,
            signingInput: Data((parts[0] + "." + parts[1]).utf8), certificates: certs)
    }
}

/// Why a JWS failed verification (`VerificationResult.VerificationError`).
public struct VerificationFailure: Error, Hashable, Sendable, CustomStringConvertible {
    public let reason: VerificationFailureReason
    public let detail: String

    public init(_ reason: VerificationFailureReason, _ detail: String) {
        self.reason = reason
        self.detail = detail
    }

    public var description: String { "\(reason): \(detail)" }
}

/// Verifies compact JWS signatures.
///
/// Like the simulator, it checks the signature against the leaf
/// certificate's key. With `trustedRoots` it also checks that the `x5c`
/// chain leads to one of them (each certificate signed by the next, the
/// last one a trusted root or signed by one) and, with `date`, that every
/// certificate is valid then.
public struct JWSVerifier: Sendable {
    public var trustedRoots: [Certificate]
    public var date: Date?
    /// Payload keys that must be present (`missingRequiredProperties` otherwise).
    public var requiredPayloadKeys: [String]

    public init(trustedRoots: [Certificate] = [], date: Date? = nil, requiredPayloadKeys: [String] = []) {
        self.trustedRoots = trustedRoots
        self.date = date
        self.requiredPayloadKeys = requiredPayloadKeys
    }

    public func verify(_ compact: String) throws(VerificationFailure) -> DecodedJWS {
        let jws = try JWS.decode(compact)
        guard jws.header["alg"]?.stringValue == "ES256" else { throw VerificationFailure(.invalidEncoding, "alg is not ES256") }
        guard let leaf = jws.certificates.first else { throw VerificationFailure(.missingRequiredProperties, "no x5c certificate") }
        guard jws.signature.count == 64, let sig = try? P256.Signing.ECDSASignature(rawRepresentation: jws.signature),
              leaf.publicKey.isValidSignature(sig, for: jws.signingInput) else {
            throw VerificationFailure(.invalidSignature, "the signature does not verify with the leaf certificate's key")
        }
        if let date {
            for c in jws.certificates where !c.isValid(at: date) {
                throw VerificationFailure(.invalidCertificateChain, "certificate \(c.subject) is not valid at \(date)")
            }
        }
        if !trustedRoots.isEmpty {
            let chain = jws.certificates
            for (child, parent) in zip(chain, chain.dropFirst()) where !child.isSigned(by: parent.publicKey) {
                throw VerificationFailure(.invalidCertificateChain, "\(child.subject) is not signed by \(parent.subject)")
            }
            let top = chain.last!
            let anchored = trustedRoots.contains { $0.der == top.der || top.isSigned(by: $0.publicKey) }
            guard anchored else { throw VerificationFailure(.invalidCertificateChain, "the chain does not lead to a trusted root") }
        }
        for key in requiredPayloadKeys where jws.payload[key] == nil {
            throw VerificationFailure(.missingRequiredProperties, "payload has no \(key)")
        }
        return jws
    }
}
