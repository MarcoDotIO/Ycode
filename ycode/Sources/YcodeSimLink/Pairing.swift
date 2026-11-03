// Pairing (sim-link.md §4.1): `ycode-simhost pair` opens a pairing window on
// the host (5 minutes, one attempt) and shows a one-time code of 12
// characters (60 bits) from a 32-letter alphabet without look-alikes. The
// client types it; the handshake then runs as XXpsk3 with
// psk = SHA-256("ycode-sim-link pairing code " ‖ the normalised code), so a
// host that does not know the code cannot complete it, and a client that
// does not know it cannot get its key trusted. Any attempt, right or
// wrong, closes the window. The window lives in the host's link directory
// (`pairing.json`, 0600) so the pairing command and the running service
// share it.

import Crypto
import Foundation

public enum Pairing {
    /// Crockford-style base32 letters (no I, L, O, U).
    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
    public static let window: TimeInterval = 300

    /// A new code, "XXXX-XXXX-XXXX".
    public static func newCode() -> String {
        var rng = SystemRandomNumberGenerator()
        let chars = (0..<12).map { _ in alphabet[Int(rng.next(upperBound: UInt32(alphabet.count)))] }
        return stride(from: 0, to: 12, by: 4).map { String(chars[$0..<($0 + 4)]) }.joined(separator: "-")
    }

    /// Upper case, dashes and spaces removed, look-alikes folded (O→0, I/L→1).
    public static func normalize(_ code: String) -> String {
        String(code.uppercased().compactMap { c -> Character? in
            switch c {
            case "-", " ": return nil
            case "O": return "0"
            case "I", "L": return "1"
            default: return c
            }
        })
    }

    public static func psk(code: String) -> [UInt8] {
        Array(SHA256.hash(data: Array("ycode-sim-link pairing code ".utf8) + Array(normalize(code).utf8)))
    }

    struct WindowFile: Codable {
        var psk: String
        var expires: Double
    }

    static func url(_ store: LinkStore) -> URL { store.directory.appendingPathComponent("pairing.json") }

    /// Opens the window for `code` (replacing an open one).
    public static func open(code: String, store: LinkStore, now: Date = Date()) throws {
        _ = try store.identity()  // makes the directory
        let w = WindowFile(psk: Data(psk(code: code)).base64EncodedString(), expires: now.timeIntervalSince1970 + window)
        let path = url(store).path
        unlink(path)
        guard FileManager.default.createFile(atPath: path, contents: try JSONEncoder().encode(w), attributes: [.posixPermissions: 0o600]) else {
            throw LinkStoreError.corrupt(path)
        }
    }

    /// Takes the open window's key (the window closes: one attempt); nil when none is open.
    public static func take(store: LinkStore, now: Date = Date()) -> [UInt8]? {
        let path = url(store).path
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        unlink(path)
        guard let w = try? JSONDecoder().decode(WindowFile.self, from: d), w.expires > now.timeIntervalSince1970,
              let k = Data(base64Encoded: w.psk) else { return nil }
        return Array(k)
    }

    public static func isOpen(store: LinkStore, now: Date = Date()) -> Bool {
        guard let d = FileManager.default.contents(atPath: url(store).path),
              let w = try? JSONDecoder().decode(WindowFile.self, from: d) else { return false }
        return w.expires > now.timeIntervalSince1970
    }

    public static func close(store: LinkStore) { unlink(url(store).path) }
}

/// A pairing file (sim-link.md §4.2): what one machine prints so the owner
/// can trust it on the other without a code (`ycode-simhost identity`,
/// `ycode sim remote identity`; `… trust <file>`).
public struct PairingFile: Codable, Sendable, Equatable {
    public var name: String
    public var publicKey: String
    public var role: String
    public var address: String?
    public var mediaPort: Int?

    public init(name: String, identity: LinkIdentity, role: String, address: String? = nil, mediaPort: Int? = nil) {
        self.name = name
        publicKey = Data(identity.publicKey).base64EncodedString()
        self.role = role
        self.address = address
        self.mediaPort = mediaPort
    }
}
