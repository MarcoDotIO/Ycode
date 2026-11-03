// The Noise Protocol Framework (revision 34, Trevor Perrin, public domain;
// noiseprotocol.org/noise.html), the parts Ycode's simulator link uses
// (specs/simulator/sim-link.md §3): the XX handshake pattern and its psk3
// variant, with Curve25519, ChaCha20-Poly1305 and SHA-256
// ("Noise_XX_25519_ChaChaPoly_SHA256", "Noise_XXpsk3_25519_ChaChaPoly_SHA256").
// The primitives come from swift-crypto (Apache-2.0; CryptoKit on Apple
// platforms, BoringSSL elsewhere). Section numbers below are the spec's.

import Crypto
import Foundation

public enum NoiseError: Error, Equatable, CustomStringConvertible {
    case decryptFailed
    case malformed(String)
    case nonceExhausted
    case wrongState

    public var description: String {
        switch self {
        case .decryptFailed: "authentication failed (wrong key or tampered message)"
        case .malformed(let s): "malformed handshake message: \(s)"
        case .nonceExhausted: "nonce exhausted"
        case .wrongState: "handshake message out of order"
        }
    }
}

/// §5.1 CipherState: a key and a 64-bit nonce.
public struct NoiseCipherState: Sendable {
    public private(set) var key: SymmetricKey?
    public private(set) var nonce: UInt64 = 0

    public init(key: SymmetricKey? = nil) { self.key = key }

    public var hasKey: Bool { key != nil }

    /// The 96-bit ChaChaPoly nonce: 32 bits of zeros, then n little-endian (§12.3).
    static func nonceBytes(_ n: UInt64) -> [UInt8] {
        [0, 0, 0, 0] + (0..<8).map { UInt8(truncatingIfNeeded: n >> (8 * UInt64($0))) }
    }

    static func seal(_ k: SymmetricKey, _ n: UInt64, ad: [UInt8], _ plaintext: [UInt8]) throws -> [UInt8] {
        let box = try ChaChaPoly.seal(plaintext, using: k, nonce: try ChaChaPoly.Nonce(data: nonceBytes(n)), authenticating: ad)
        return Array(box.ciphertext) + Array(box.tag)
    }

    static func open(_ k: SymmetricKey, _ n: UInt64, ad: [UInt8], _ ciphertext: [UInt8]) throws -> [UInt8] {
        guard ciphertext.count >= 16 else { throw NoiseError.decryptFailed }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try ChaChaPoly.Nonce(data: nonceBytes(n)),
                                               ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            return Array(try ChaChaPoly.open(box, using: k, authenticating: ad))
        } catch {
            throw NoiseError.decryptFailed
        }
    }

    public mutating func encrypt(ad: [UInt8], _ plaintext: [UInt8]) throws -> [UInt8] {
        guard let key else { return plaintext }
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        let out = try Self.seal(key, nonce, ad: ad, plaintext)
        nonce += 1
        return out
    }

    public mutating func decrypt(ad: [UInt8], _ ciphertext: [UInt8]) throws -> [UInt8] {
        guard let key else { return ciphertext }
        guard nonce < UInt64.max else { throw NoiseError.nonceExhausted }
        let out = try Self.open(key, nonce, ad: ad, ciphertext)
        nonce += 1
        return out
    }

    /// §4.2 Rekey(): k = the first 32 bytes of ENCRYPT(k, maxnonce, zerolen, zeros).
    public mutating func rekey() throws {
        guard let key else { return }
        let out = try Self.seal(key, UInt64.max, ad: [], [UInt8](repeating: 0, count: 32))
        self.key = SymmetricKey(data: out.prefix(32))
    }
}

/// §5.2 SymmetricState.
public struct NoiseSymmetricState: Sendable {
    public private(set) var ck: [UInt8]
    public private(set) var h: [UInt8]
    public var cipher = NoiseCipherState()

    public init(protocolName: String) {
        let name = Array(protocolName.utf8)
        h = name.count <= 32 ? name + [UInt8](repeating: 0, count: 32 - name.count) : Array(SHA256.hash(data: name))
        ck = h
    }

    static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// §4.3 HKDF(chaining_key, input_key_material, num_outputs).
    public static func hkdf(_ ck: [UInt8], _ ikm: [UInt8], _ outputs: Int) -> [[UInt8]] {
        let temp = hmac(ck, ikm)
        let o1 = hmac(temp, [1])
        let o2 = hmac(temp, o1 + [2])
        if outputs == 2 { return [o1, o2] }
        return [o1, o2, hmac(temp, o2 + [3])]
    }

    public mutating func mixKey(_ ikm: [UInt8]) {
        let o = Self.hkdf(ck, ikm, 2)
        ck = o[0]
        cipher = NoiseCipherState(key: SymmetricKey(data: o[1]))
    }

    public mutating func mixHash(_ data: [UInt8]) { h = Array(SHA256.hash(data: h + data)) }

    public mutating func mixKeyAndHash(_ ikm: [UInt8]) {
        let o = Self.hkdf(ck, ikm, 3)
        ck = o[0]
        mixHash(o[1])
        cipher = NoiseCipherState(key: SymmetricKey(data: o[2]))
    }

    public mutating func encryptAndHash(_ plaintext: [UInt8]) throws -> [UInt8] {
        let c = try cipher.encrypt(ad: h, plaintext)
        mixHash(c)
        return c
    }

    public mutating func decryptAndHash(_ ciphertext: [UInt8]) throws -> [UInt8] {
        let p = try cipher.decrypt(ad: h, ciphertext)
        mixHash(ciphertext)
        return p
    }

    /// §5.2 Split(): the initiator's sending and receiving ciphers' keys.
    public func split() -> (initiatorToResponder: [UInt8], responderToInitiator: [UInt8]) {
        let o = Self.hkdf(ck, [], 2)
        return (o[0], o[1])
    }
}

/// §5.3 HandshakeState for XX (and XXpsk3):
///   -> e
///   <- e, ee, s, es
///   -> s, se            (psk3: then psk)
public struct NoiseXX: Sendable {
    public let initiator: Bool
    public let psk: [UInt8]?
    public private(set) var symmetric: NoiseSymmetricState
    let s: Curve25519.KeyAgreement.PrivateKey
    var e: Curve25519.KeyAgreement.PrivateKey?
    public private(set) var remoteStatic: [UInt8]?
    var re: [UInt8]?
    public private(set) var step = 0

    public static func protocolName(psk: Bool) -> String {
        psk ? "Noise_XXpsk3_25519_ChaChaPoly_SHA256" : "Noise_XX_25519_ChaChaPoly_SHA256"
    }

    /// `ephemeral`: a fixed ephemeral key (test vectors only).
    public init(initiator: Bool, staticKey: Curve25519.KeyAgreement.PrivateKey, prologue: [UInt8], psk: [UInt8]? = nil,
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        self.initiator = initiator
        self.psk = psk
        s = staticKey
        e = ephemeral
        symmetric = NoiseSymmetricState(protocolName: Self.protocolName(psk: psk != nil))
        symmetric.mixHash(prologue)
    }

    static func dh(_ k: Curve25519.KeyAgreement.PrivateKey, _ pub: [UInt8]) throws -> [UInt8] {
        guard pub.count == 32 else { throw NoiseError.malformed("public key length \(pub.count)") }
        do {
            let shared = try k.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: pub))
            return shared.withUnsafeBytes { Array($0) }
        } catch {
            throw NoiseError.malformed("bad public key")
        }
    }

    /// The handshake hash (§5.2 GetHandshakeHash), valid during and after the handshake.
    public var handshakeHash: [UInt8] { symmetric.h }

    public var isComplete: Bool { step == 3 }

    private mutating func writeE(_ out: inout [UInt8]) {
        let key = e ?? Curve25519.KeyAgreement.PrivateKey()
        e = key
        let pub = Array(key.publicKey.rawRepresentation)
        out += pub
        symmetric.mixHash(pub)
        if psk != nil { symmetric.mixKey(pub) }
    }

    private mutating func readE(_ msg: [UInt8], _ at: inout Int) throws {
        guard msg.count - at >= 32 else { throw NoiseError.malformed("short e") }
        let pub = Array(msg[at..<(at + 32)])
        at += 32
        re = pub
        symmetric.mixHash(pub)
        if psk != nil { symmetric.mixKey(pub) }
    }

    private mutating func writeS(_ out: inout [UInt8]) throws {
        out += try symmetric.encryptAndHash(Array(s.publicKey.rawRepresentation))
    }

    private mutating func readS(_ msg: [UInt8], _ at: inout Int) throws {
        let n = symmetric.cipher.hasKey ? 48 : 32
        guard msg.count - at >= n else { throw NoiseError.malformed("short s") }
        remoteStatic = try symmetric.decryptAndHash(Array(msg[at..<(at + n)]))
        at += n
    }

    /// Writes the next handshake message (1 for the initiator, 2 for the
    /// responder, 3 for the initiator). `beforePayload` sees the handshake
    /// hash just before the payload is encrypted (identity signatures).
    public mutating func writeMessage(payload: ([UInt8]) throws -> [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = []
        switch (step, initiator) {
        case (0, true):
            writeE(&out)
        case (1, false):
            writeE(&out)
            symmetric.mixKey(try Self.dh(e!, re!))  // ee
            try writeS(&out)
            symmetric.mixKey(try Self.dh(s, re!))   // es
        case (2, true):
            try writeS(&out)
            symmetric.mixKey(try Self.dh(s, re!))   // se
            if let psk { symmetric.mixKeyAndHash(psk) }
        default:
            throw NoiseError.wrongState
        }
        out += try symmetric.encryptAndHash(try payload(symmetric.h))
        step += 1
        return out
    }

    /// Reads the next handshake message; returns its payload. `hashBeforePayload`
    /// gets the handshake hash just before the payload was decrypted.
    public mutating func readMessage(_ msg: [UInt8], hashBeforePayload: inout [UInt8]) throws -> [UInt8] {
        var at = 0
        switch (step, initiator) {
        case (0, false):
            try readE(msg, &at)
        case (1, true):
            try readE(msg, &at)
            symmetric.mixKey(try Self.dh(e!, re!))  // ee
            try readS(msg, &at)
            symmetric.mixKey(try Self.dh(e!, remoteStatic!))  // es
        case (2, false):
            try readS(msg, &at)
            symmetric.mixKey(try Self.dh(e!, remoteStatic!))  // se
            if let psk { symmetric.mixKeyAndHash(psk) }
        default:
            throw NoiseError.wrongState
        }
        hashBeforePayload = symmetric.h
        let payload = try symmetric.decryptAndHash(Array(msg[at...]))
        step += 1
        return payload
    }

    /// After message 3: (send, receive) ciphers for this side.
    public func transportCiphers() throws -> (send: NoiseCipherState, receive: NoiseCipherState) {
        guard isComplete else { throw NoiseError.wrongState }
        let (a, b) = symmetric.split()
        let i2r = NoiseCipherState(key: SymmetricKey(data: a)), r2i = NoiseCipherState(key: SymmetricKey(data: b))
        return initiator ? (i2r, r2i) : (r2i, i2r)
    }
}
