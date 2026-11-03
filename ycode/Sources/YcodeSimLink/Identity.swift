// Identities and trust (sim-link.md §2, §4): each machine has one Ed25519
// identity key, made on first use and kept in its link directory
// ($YCODE_SIM_LINK_HOME, else ~/.config/ycode/sim-link, mode 0700; the key
// file 0600). Peers are trusted by their public key only: pairing (a
// one-time code, §4.1) or a pairing file the owner copies (§4.2) adds
// them to `trusted-peers.json`. Nothing else is ever accepted.

import Crypto
import Foundation

public struct LinkIdentity: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public var publicKey: [UInt8] { Array(signing.publicKey.rawRepresentation) }

    public init(signing: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) { self.signing = signing }

    /// The key's short fingerprint people compare: the first 10 bytes of
    /// SHA-256 of the public key, as five groups of four hex digits.
    public static func fingerprint(_ publicKey: [UInt8]) -> String {
        let d = Array(SHA256.hash(data: publicKey)).prefix(10)
        let hex = d.map { String(format: "%02x", $0) }.joined()
        return stride(from: 0, to: hex.count, by: 4).map { i -> String in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[s..<hex.index(s, offsetBy: 4)])
        }.joined(separator: "-")
    }

    public var fingerprint: String { Self.fingerprint(publicKey) }

    public func sign(_ data: [UInt8]) throws -> [UInt8] { Array(try signing.signature(for: data)) }

    public static func verify(_ signature: [UInt8], _ data: [UInt8], publicKey: [UInt8]) -> Bool {
        guard let k = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return k.isValidSignature(signature, for: data)
    }
}

public struct TrustedPeer: Codable, Sendable, Equatable {
    public var name: String
    /// Base64 of the Ed25519 public key.
    public var publicKey: String
    /// "host" (a simulator host this machine connects to) or "client".
    public var role: String
    /// A host's address ("<host>:<control port>"), for clients.
    public var address: String?
    /// The media (UDP) port, for clients (nil: control port + 1).
    public var mediaPort: Int?
    public var added: String

    public init(name: String, publicKey: [UInt8], role: String, address: String? = nil, mediaPort: Int? = nil, added: Date = Date()) {
        self.name = name
        self.publicKey = Data(publicKey).base64EncodedString()
        self.role = role
        self.address = address
        self.mediaPort = mediaPort
        self.added = ISO8601DateFormatter().string(from: added)
    }

    public var keyBytes: [UInt8]? { Data(base64Encoded: publicKey).map { Array($0) } }
}

public enum LinkStoreError: Error, CustomStringConvertible {
    case unsafePermissions(String)
    case corrupt(String)
    public var description: String {
        switch self {
        case .unsafePermissions(let p): "\(p) is readable by others; fix with chmod 600 (and 700 for its directory)"
        case .corrupt(let p): "\(p) is not a valid link file"
        }
    }
}

/// A machine's link directory: its identity and the peers it trusts.
public final class LinkStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()

    public static var defaultDirectory: URL {
        if let d = ProcessInfo.processInfo.environment["YCODE_SIM_LINK_HOME"], !d.isEmpty { return URL(fileURLWithPath: d, isDirectory: true) }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".config/ycode/sim-link", isDirectory: true)
    }

    public init(directory: URL = LinkStore.defaultDirectory) { self.directory = directory }

    var identityURL: URL { directory.appendingPathComponent("identity.key") }
    var peersURL: URL { directory.appendingPathComponent("trusted-peers.json") }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// The identity (made and saved on first use).
    public func identity() throws -> LinkIdentity {
        try lock.withLock {
            try ensureDirectory()
            if let d = FileManager.default.contents(atPath: identityURL.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: identityURL.path)
                if let mode = attrs[.posixPermissions] as? Int, mode & 0o077 != 0 { throw LinkStoreError.unsafePermissions(identityURL.path) }
                guard d.count == 32, let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else { throw LinkStoreError.corrupt(identityURL.path) }
                return LinkIdentity(signing: k)
            }
            let id = LinkIdentity()
            let fd = open(identityURL.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { throw LinkStoreError.corrupt(identityURL.path) }
            let raw = Array(id.signing.rawRepresentation)
            _ = raw.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
            return id
        }
    }

    public func peers() -> [TrustedPeer] {
        lock.withLock {
            guard let d = FileManager.default.contents(atPath: peersURL.path) else { return [] }
            return (try? JSONDecoder().decode([TrustedPeer].self, from: d)) ?? []
        }
    }

    public func trusted(_ publicKey: [UInt8], role: String) -> TrustedPeer? {
        let b = Data(publicKey).base64EncodedString()
        return peers().first { $0.publicKey == b && $0.role == role }
    }

    /// Adds (or replaces, by key and role) a peer.
    public func addPeer(_ p: TrustedPeer) throws {
        var all = peers().filter { !($0.publicKey == p.publicKey && $0.role == p.role) }
        // A host name names one host: re-pairing replaces the old key.
        if p.role == "host" { all.removeAll { $0.role == "host" && $0.name == p.name } }
        all.append(p)
        try save(all)
    }

    public func removePeer(named name: String) throws -> Bool {
        let all = peers()
        let kept = all.filter { $0.name != name }
        try save(kept)
        return kept.count != all.count
    }

    private func save(_ all: [TrustedPeer]) throws {
        try lock.withLock {
            try ensureDirectory()
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let tmp = peersURL.appendingPathExtension("tmp")
            FileManager.default.createFile(atPath: tmp.path, contents: try enc.encode(all), attributes: [.posixPermissions: 0o600])
            guard rename(tmp.path, peersURL.path) == 0 else { throw LinkStoreError.corrupt(peersURL.path) }
        }
    }

    /// A host: the one named, else the only one.
    public func host(named name: String?) -> TrustedPeer? {
        let hosts = peers().filter { $0.role == "host" }
        if let name { return hosts.first { $0.name == name } }
        return hosts.count == 1 ? hosts[0] : nil
    }
}
