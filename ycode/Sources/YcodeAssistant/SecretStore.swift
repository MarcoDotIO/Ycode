import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Where the assistant keeps secrets (API keys, OAuth tokens). Values never
/// go to user defaults, logs or the workspace (coding-assistant.md §6).
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, for account: String) throws
    func delete(_ account: String) throws
}

extension SecretStore {
    public func readString(_ account: String) -> String? {
        (try? read(account)).flatMap { $0 }.map { String(decoding: $0, as: UTF8.self) }
    }

    public func readJSON<T: Decodable>(_ type: T.Type, _ account: String) -> T? {
        guard let d = try? read(account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    public func writeJSON<T: Encodable>(_ value: T, for account: String) throws {
        try write(JSONEncoder().encode(value), for: account)
    }
}

/// The accounts (item names) the assistant uses.
public enum SecretAccount {
    public static let openAIKey = "openai.api-key"
    public static let openAITokens = "openai.chatgpt-tokens"
    /// The issued client registration and host ID, kept after sign-out.
    public static let openAIRegistration = "openai.chatgpt-registration"
    public static let llamaCppKey = "llamacpp.api-key"
}

public enum SecretStoreError: Error, Equatable, LocalizedError {
    case keychain(Int32)
    case file(String)
    public var errorDescription: String? {
        switch self {
        case .keychain(let s): "The keychain refused the operation (status \(s))."
        case .file(let m): m
        }
    }
}

/// The platform's store: the login keychain on macOS, a 0600 file on Linux.
public func defaultSecretStore() -> SecretStore {
    #if canImport(Security)
    KeychainSecretStore()
    #else
    FileSecretStore()
    #endif
}

/// Secrets in memory only (tests, or when nothing may be stored).
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public init() {}
    public func read(_ account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return items[account] }
    public func write(_ data: Data, for account: String) throws { lock.lock(); items[account] = data; lock.unlock() }
    public func delete(_ account: String) throws { lock.lock(); items[account] = nil; lock.unlock() }
    public var accounts: [String] { lock.lock(); defer { lock.unlock() }; return items.keys.sorted() }
}

#if canImport(Security)
/// Generic-password items in the user's keychain, one per account, under
/// one service name.
public struct KeychainSecretStore: SecretStore {
    public var service: String
    public static let defaultService = "Ycode Coding Assistant"
    public init(service: String = Self.defaultService) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(_ account: String) throws -> Data? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let s = SecItemCopyMatching(q as CFDictionary, &out)
        if s == errSecItemNotFound { return nil }
        guard s == errSecSuccess else { throw SecretStoreError.keychain(s) }
        return out as? Data
    }

    public func write(_ data: Data, for account: String) throws {
        let q = query(account)
        let update: [String: Any] = [kSecValueData as String: data]
        var s = SecItemUpdate(q as CFDictionary, update as CFDictionary)
        if s == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "\(service) (\(account))"
            s = SecItemAdd(add as CFDictionary, nil)
        }
        guard s == errSecSuccess else { throw SecretStoreError.keychain(s) }
    }

    public func delete(_ account: String) throws {
        let s = SecItemDelete(query(account) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw SecretStoreError.keychain(s) }
    }
}
#endif

/// One file per account in a directory only the user can read (0700, files
/// 0600), written atomically. Used where there is no keychain (Linux):
/// `$XDG_CONFIG_HOME/ycode/secrets` or `~/.config/ycode/secrets`.
public struct FileSecretStore: SecretStore {
    public var directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let env = ProcessInfo.processInfo.environment
            let config = env["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
            self.directory = config.appendingPathComponent("ycode/secrets")
        }
    }

    func fileURL(_ account: String) -> URL {
        let safe = account.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent(String(safe))
    }

    public func read(_ account: String) throws -> Data? {
        let url = fileURL(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data, for account: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        let url = fileURL(account)
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        // Create with 0600 before any byte is written, then rename over.
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw SecretStoreError.file("Cannot create \(tmp.path): \(String(cString: strerror(errno)))") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        h.write(data)
        try? h.synchronize()
        try? h.close()
        guard rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw SecretStoreError.file("Cannot save \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    public func delete(_ account: String) throws {
        let url = fileURL(account)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
