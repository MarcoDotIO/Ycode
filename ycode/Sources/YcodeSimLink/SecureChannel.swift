// One authenticated, encrypted TCP connection of the simulator link
// (sim-link.md §3): a 5-byte preamble ("YSL1" and the mode, X or P), the
// Noise XX handshake (XXpsk3 when pairing) with each side's Ed25519
// identity signing the handshake hash, then transport records. Every
// message on the wire is length-prefixed (u16, big-endian, as the Noise
// spec suggests) and at most 65 535 bytes; a record carries up to 65 519
// bytes of the byte stream. Both directions rekey every 2^20 records.
//
// The responder (the host) reads nothing but the preamble and the three
// bounded handshake messages before the initiator has proved a trusted
// identity (or, while pairing is open, knowledge of the code); anything
// else closes the connection.

import Crypto
import Foundation
import YcodeDisplayStream

public enum LinkError: Error, CustomStringConvertible, Equatable {
    case closed
    case protocolViolation(String)
    case untrustedHost(fingerprint: String)
    case refused(String)
    case timeout

    public var description: String {
        switch self {
        case .closed: "the connection closed"
        case .protocolViolation(let s): "protocol error: \(s)"
        case .untrustedHost(let f): "the host's identity \(f) is not the one paired (pair again if the host was reinstalled)"
        case .refused(let s): "refused: \(s)"
        case .timeout: "timed out"
        }
    }
}

/// What the initiator wants from the connection (in message 3's payload).
public struct LinkHello: Codable, Sendable, Equatable {
    /// "control", "display" or "pair".
    public var purpose: String
    /// The device, for display connections.
    public var device: String?
    /// The client's name (logs; the peer's name when pairing).
    public var client: String
    /// Ask for the media channel (UDP) on a display connection (§5).
    public var media: Bool?

    public init(purpose: String, device: String? = nil, client: String, media: Bool? = nil) {
        (self.purpose, self.device, self.client, self.media) = (purpose, device, client, media)
    }
}

/// The host's answer: the first transport record after the handshake.
public struct LinkWelcome: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public var host: String?
    public var version: String?
    /// The media session's id and the host's UDP port (when media was asked and is available).
    public var mediaSession: UInt32?
    public var mediaPort: Int?

    public init(ok: Bool, error: String? = nil, host: String? = nil, version: String? = nil, mediaSession: UInt32? = nil, mediaPort: Int? = nil) {
        (self.ok, self.error, self.host, self.version, self.mediaSession, self.mediaPort) = (ok, error, host, version, mediaSession, mediaPort)
    }
}

public final class SecureChannel: DisplayTransport, @unchecked Sendable {
    public static let preamble: [UInt8] = Array("YSL1".utf8)
    public static let prologue: [UInt8] = Array("ycode-sim-link/1".utf8)
    public static let maxRecord = 65535
    public static let maxPlaintext = 65535 - 16
    public static let rekeyInterval: UInt64 = 1 << 20
    static let maxHandshakeMessage = 2048

    let raw: DisplayConnection
    private var reader: ExactReader
    private var sendCipher: NoiseCipherState
    private var receiveCipher: NoiseCipherState
    private let sendLock = NSLock()
    private let receiveLock = NSLock()
    private var sentRecords: UInt64 = 0, receivedRecords: UInt64 = 0
    /// The peer's Ed25519 identity, its name (host info or hello), the handshake hash.
    public let peerKey: [UInt8]
    public let handshakeHash: [UInt8]
    /// Keys for the media channel (§5): initiator → responder and back.
    public let mediaKeys: (initiatorToResponder: SymmetricKey, responderToInitiator: SymmetricKey)
    public let isInitiator: Bool

    init(raw: DisplayConnection, reader: ExactReader, handshake: NoiseXX, peerKey: [UInt8]) throws {
        self.raw = raw
        self.reader = reader
        let (s, r) = try handshake.transportCiphers()
        sendCipher = s
        receiveCipher = r
        self.peerKey = peerKey
        handshakeHash = handshake.handshakeHash
        isInitiator = handshake.initiator
        let (a, b) = handshake.symmetric.split()
        let ikm = SymmetricKey(data: a + b)
        let salt = handshake.handshakeHash
        mediaKeys = (HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Array("ycode-sim-link media i2r".utf8), outputByteCount: 32),
                     HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Array("ycode-sim-link media r2i".utf8), outputByteCount: 32))
    }

    public var fd: Int32 { raw.fd }

    // MARK: Records

    static func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 0xFF)] }

    /// Writes bytes of the stream (split into records).
    public func send(_ bytes: [UInt8]) throws {
        try sendLock.withLock {
            var at = 0
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count + (bytes.count / Self.maxPlaintext + 1) * 18)
            repeat {
                let n = min(Self.maxPlaintext, bytes.count - at)
                let c = try sendCipher.encrypt(ad: [], Array(bytes[at..<(at + n)]))
                out += Self.u16(c.count) + c
                at += n
                sentRecords += 1
                if sentRecords % Self.rekeyInterval == 0 { try sendCipher.rekey() }
            } while at < bytes.count
            try raw.send(out)
        }
    }

    /// The next record's bytes; nil at the end or on an authentication failure.
    public func receive(max: Int = 1 << 20) -> [UInt8]? {
        receiveLock.withLock {
            guard let len = reader.read(2, from: raw) else { return nil }
            let n = Int(len[0]) << 8 | Int(len[1])
            guard n >= 16, let c = reader.read(n, from: raw) else { return nil }
            guard let p = try? receiveCipher.decrypt(ad: [], c) else { raw.close(); return nil }
            receivedRecords += 1
            if receivedRecords % Self.rekeyInterval == 0 { try? receiveCipher.rekey() }
            return p
        }
    }

    /// Sends one JSON value as a line (the control protocol, §6).
    public func sendJSON<T: Encodable>(_ v: T) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        try send(Array(try enc.encode(v)) + [0x0A])
    }

    public func close() { raw.close() }

    // MARK: Handshake: the initiator (a client)

    public enum HostCheck: Sendable {
        /// The host must have this identity key.
        case pinned([UInt8])
        /// Pairing with a one-time code: any host, confirmed by the code.
        case pairing(code: String)
    }

    /// Connects to a host and runs the handshake; returns the channel and
    /// the host's welcome. Throws `untrustedHost` before revealing this
    /// machine's identity when the host's key is not the pinned one.
    public static func connect(host: String, port: Int, identity: LinkIdentity, check: HostCheck, hello: LinkHello,
                               timeout: TimeInterval = 10) throws -> (SecureChannel, LinkWelcome) {
        let raw = try DisplayConnection.connect(to: .tcp(host: host, port: UInt16(port)))
        LinkSockets.setTimeouts(raw.fd, seconds: timeout)
        do {
            var reader = ExactReader()
            var psk: [UInt8]?
            if case .pairing(let code) = check { psk = Pairing.psk(code: code) }
            try raw.send(preamble + [psk == nil ? UInt8(ascii: "X") : UInt8(ascii: "P")])
            var hs = NoiseXX(initiator: true, staticKey: Curve25519.KeyAgreement.PrivateKey(), prologue: prologue, psk: psk)
            let m1 = try hs.writeMessage { _ in [] }
            try raw.send(u16(m1.count) + m1)
            guard let l2 = reader.read(2, from: raw) else { throw LinkError.closed }
            let n2 = Int(l2[0]) << 8 | Int(l2[1])
            guard n2 <= maxHandshakeMessage, let m2 = reader.read(n2, from: raw) else { throw LinkError.protocolViolation("message 2") }
            var h2: [UInt8] = []
            let p2 = try hs.readMessage(m2, hashBeforePayload: &h2)
            guard p2.count >= 96 else { throw LinkError.protocolViolation("host identity") }
            let hostKey = Array(p2[0..<32]), sig = Array(p2[32..<96])
            guard LinkIdentity.verify(sig, Array("YSL1 responder".utf8) + h2, publicKey: hostKey) else {
                throw LinkError.protocolViolation("the host's identity signature is invalid")
            }
            if case .pinned(let expected) = check, expected != hostKey {
                throw LinkError.untrustedHost(fingerprint: LinkIdentity.fingerprint(hostKey))
            }
            let helloJSON = try JSONEncoder().encode(hello)
            let m3 = try hs.writeMessage { h in
                identity.publicKey + (try identity.sign(Array("YSL1 initiator".utf8) + h)) + Array(helloJSON)
            }
            try raw.send(u16(m3.count) + m3)
            let channel = try SecureChannel(raw: raw, reader: reader, handshake: hs, peerKey: hostKey)
            // The welcome proves the host completed the handshake (and, when pairing, knew the code).
            guard let w = channel.receiveLine(), let welcome = try? JSONDecoder().decode(LinkWelcome.self, from: Data(w)) else {
                throw psk != nil ? LinkError.refused("the host did not accept the pairing code") : LinkError.refused("the host closed the connection (this machine is not trusted there?)")
            }
            guard welcome.ok else { throw LinkError.refused(welcome.error ?? "refused") }
            LinkSockets.setTimeouts(raw.fd, seconds: 0)
            return (channel, welcome)
        } catch {
            raw.close()
            throw error
        }
    }

    // MARK: Handshake: the responder (the host)

    public struct Accepted: Sendable {
        public let channel: SecureChannel
        public let hello: LinkHello
        public let pairing: Bool
    }

    /// Runs the responder's handshake on an accepted socket. `authorize`
    /// sees the client's key and hello (and whether it is a pairing) and
    /// says whether it may continue; `pairingPSK` is the open pairing's key
    /// (nil: pairing is closed). The welcome is the caller's to send.
    public static func accept(_ raw: DisplayConnection, identity: LinkIdentity, pairingPSK: () -> [UInt8]?,
                              authorize: ([UInt8], LinkHello, Bool) -> Bool, timeout: TimeInterval = 5) throws -> Accepted {
        LinkSockets.setTimeouts(raw.fd, seconds: timeout)
        var reader = ExactReader()
        guard let pre = reader.read(5, from: raw), Array(pre[0..<4]) == preamble else { throw LinkError.protocolViolation("preamble") }
        let pairing: Bool
        switch pre[4] {
        case UInt8(ascii: "X"): pairing = false
        case UInt8(ascii: "P"): pairing = true
        default: throw LinkError.protocolViolation("mode")
        }
        var psk: [UInt8]?
        if pairing {
            guard let p = pairingPSK() else { throw LinkError.refused("pairing is not open") }
            psk = p
        }
        var hs = NoiseXX(initiator: false, staticKey: Curve25519.KeyAgreement.PrivateKey(), prologue: prologue, psk: psk)
        func message() throws -> [UInt8] {
            guard let l = reader.read(2, from: raw) else { throw LinkError.closed }
            let n = Int(l[0]) << 8 | Int(l[1])
            guard n <= maxHandshakeMessage, let m = reader.read(n, from: raw) else { throw LinkError.protocolViolation("handshake length") }
            return m
        }
        var h: [UInt8] = []
        let p1 = try hs.readMessage(try message(), hashBeforePayload: &h)
        guard p1.isEmpty else { throw LinkError.protocolViolation("message 1 payload") }
        let m2 = try hs.writeMessage { h in identity.publicKey + (try identity.sign(Array("YSL1 responder".utf8) + h)) }
        try raw.send(u16(m2.count) + m2)
        // A wrong pairing code fails here (the payload does not decrypt).
        let p3 = try hs.readMessage(try message(), hashBeforePayload: &h)
        guard p3.count >= 96 else { throw LinkError.protocolViolation("client identity") }
        let clientKey = Array(p3[0..<32]), sig = Array(p3[32..<96])
        guard LinkIdentity.verify(sig, Array("YSL1 initiator".utf8) + h, publicKey: clientKey) else {
            throw LinkError.protocolViolation("the client's identity signature is invalid")
        }
        guard let hello = try? JSONDecoder().decode(LinkHello.self, from: Data(p3[96...])) else { throw LinkError.protocolViolation("hello") }
        guard authorize(clientKey, hello, pairing) else { throw LinkError.refused("not trusted") }
        LinkSockets.setTimeouts(raw.fd, seconds: 0)
        return Accepted(channel: try SecureChannel(raw: raw, reader: reader, handshake: hs, peerKey: clientKey), hello: hello, pairing: pairing)
    }

    // MARK: Lines (control protocol)

    private var lineBuffer: [UInt8] = []

    /// The next newline-terminated line (without the newline); nil at the end.
    public func receiveLine(limit: Int = 1 << 20) -> [UInt8]? {
        while true {
            if let i = lineBuffer.firstIndex(of: 0x0A) {
                let line = Array(lineBuffer[..<i])
                lineBuffer.removeFirst(i + 1)
                return line
            }
            guard lineBuffer.count < limit, let more = receive() else { return nil }
            lineBuffer += more
        }
    }

    /// Bytes buffered after the last line (a binary body that follows it).
    public func takeBuffered(max: Int) -> [UInt8] {
        let n = min(max, lineBuffer.count)
        defer { lineBuffer.removeFirst(n) }
        return Array(lineBuffer.prefix(n))
    }
}

/// Reads exact byte counts from a connection.
struct ExactReader {
    var buffer: [UInt8] = []

    mutating func read(_ n: Int, from c: DisplayConnection) -> [UInt8]? {
        while buffer.count < n {
            guard let more = c.receive(max: max(n - buffer.count, 64 << 10)) else { return nil }
            buffer += more
        }
        let out = Array(buffer.prefix(n))
        buffer.removeFirst(n)
        return out
    }
}
