import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

/// RSA public keys of a JSON Web Key Set (RFC 7517), as DER.
public enum JWKS {
    public struct Key: Sendable, Equatable {
        public var kid: String?
        /// PKCS #1 `RSAPublicKey` DER.
        public var der: Data
    }

    public static func rsaKeys(_ body: Data) -> [Key] {
        guard let o = JSON.object(body), let keys = o["keys"] as? [[String: Any]] else { return [] }
        return keys.compactMap { k in
            guard (k["kty"] as? String) == "RSA", (k["use"] as? String).map({ $0 == "sig" }) ?? true,
                  let n = (k["n"] as? String).flatMap(Base64URL.decode), let e = (k["e"] as? String).flatMap(Base64URL.decode) else { return nil }
            return Key(kid: k["kid"] as? String, der: rsaPublicKeyDER(modulus: n, exponent: e))
        }
    }

    /// `SEQUENCE { INTEGER n, INTEGER e }`.
    public static func rsaPublicKeyDER(modulus: Data, exponent: Data) -> Data {
        func integer(_ d: Data) -> Data {
            var v = Data(d.drop { $0 == 0 })
            if v.isEmpty { v = Data([0]) }
            if v.first! & 0x80 != 0 { v.insert(0, at: 0) }
            return Data([0x02]) + length(v.count) + v
        }
        let body = integer(modulus) + integer(exponent)
        return Data([0x30]) + length(body.count) + body
    }

    static func length(_ n: Int) -> Data {
        if n < 0x80 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xff), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

#if canImport(Security)
/// Verifies RS256 ID-token signatures with the keys at the issuer's
/// `jwks_uri` (from OpenID discovery), using the Security framework.
public struct JWKSSignatureVerifier: IDTokenSignatureVerifier {
    public init() {}

    public func verify(_ jwt: String, discoveryURL: URL) async throws {
        guard let (header, _, input, signature) = IDToken.decode(jwt) else { throw AssistantError.signIn("The ID token is malformed.") }
        guard (header["alg"] as? String) == "RS256" else { throw AssistantError.signIn("The ID token uses an unexpected signature algorithm.") }
        let d = try await HTTP.send(URLRequest(url: discoveryURL), timeout: 15)
        guard d.status == 200, let s = JSON.object(d.body)?["jwks_uri"] as? String, let jwksURL = URL(string: s) else {
            throw AssistantError.signIn("OpenAI's signing keys could not be found.")
        }
        let k = try await HTTP.send(URLRequest(url: jwksURL), timeout: 15)
        let keys = JWKS.rsaKeys(k.body)
        let kid = header["kid"] as? String
        let candidates = kid.map { id in keys.filter { $0.kid == id } } ?? keys
        for key in candidates where Self.verify(input: Data(input.utf8), signature: signature, publicKeyDER: key.der) { return }
        throw AssistantError.signIn("The ID token's signature does not verify.")
    }

    public static func verify(input: Data, signature: Data, publicKeyDER: Data) -> Bool {
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
        guard let key = SecKeyCreateWithData(publicKeyDER as CFData, attrs as CFDictionary, nil) else { return false }
        return SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, signature as CFData, nil)
    }
}
#endif
