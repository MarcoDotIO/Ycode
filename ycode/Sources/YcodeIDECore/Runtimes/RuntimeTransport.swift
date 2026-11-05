// HTTP for route B (`runtime-downloads.md` §1, §4, §6.2): the index GET with
// its ETag, the asset query POST, and the payload download, resumable with an
// HTTP range. `CurlTransport` runs the system's curl as a separate program on
// macOS and Linux alike: it resumes into the partial file, its TLS store is
// the system's, and the asset service's Apple root is given to it explicitly
// (`RuntimeTrust`). Tests answer with stand-ins. Errors, keys and the
// key-scrubbing rule live here too.

import Foundation

/// What went wrong, in words for the user (already scrubbed of keys).
public enum RuntimeDownloadError: Error, Equatable, Sendable, CustomStringConvertible {
    case badIndex(String)
    case noRuntime(String)
    /// A legacy entry behind Apple's developer sign-in (§6.4: never automated).
    case needsSignIn(String)
    case network(String)
    /// The asset service would not answer this computer (§4.1 O1).
    case refused(String)
    case noAsset(String)
    case untrusted(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case verificationFailed(String)
    case notEnoughSpace(String)
    case decryptor(String)
    case expansion(String)
    case image(String)
    case install(String)
    case cancelled
    case tool(String)

    public var description: String {
        switch self {
        case .badIndex(let s): "Apple's runtime index could not be read: \(s)."
        case .noRuntime(let s): s
        case .needsSignIn(let s): "\(s) is only offered behind an Apple developer sign-in, which Ycode does not automate. Use Xcode on a Mac, or a runtime you have."
        case .network(let s): s
        case .refused(let s): "Apple's asset service did not answer this computer: \(s). Get the runtime with Xcode on a Mac instead (xcodebuild -downloadPlatform with -exportPath), then add it here."
        case .noAsset(let s): "Apple's asset service has no download for \(s)."
        case .untrusted(let s): "The asset service's answer could not be trusted: \(s)."
        case .sizeMismatch(let e, let a): "The download is \(a) bytes; Apple said \(e). It was removed; download it again."
        case .verificationFailed(let s): "The download did not match Apple's checksum (\(s)). It was removed; download it again."
        case .notEnoughSpace(let s): s
        case .decryptor(let s): s
        case .expansion(let s): "The archive could not be unpacked: \(s)."
        case .image(let s): "The runtime disk image could not be read: \(s)."
        case .install(let s): "The runtime could not be put in place: \(s)."
        case .cancelled: "Cancelled. What was downloaded is kept; download again to resume."
        case .tool(let s): s
        }
    }

    /// Whether Retry can help.
    public var isRetryable: Bool {
        switch self {
        case .noRuntime, .needsSignIn, .refused, .noAsset, .decryptor: false
        default: true
        }
    }
}

/// The archive's decryption key from the asset record (§4.2). It prints as
/// "<redacted>" everywhere; `RuntimeSecrets` scrubs its text forms from
/// anything shown or logged. Never written to disk, never on a command line.
public struct RuntimeArchiveKey: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let bytes: [UInt8]

    public init?(base64: String) {
        guard let d = Data(base64Encoded: base64), !d.isEmpty else { return nil }
        bytes = Array(d)
    }

    public init(bytes: [UInt8]) { self.bytes = bytes }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    /// The forms the key can take in text.
    var textForms: [String] {
        let b64 = Data(bytes).base64EncodedString()
        let url = b64.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        var forms = [b64, url, hex, hex.uppercased()]
        for f in [b64, url] {
            let bare = f.replacingOccurrences(of: "=", with: "")
            if bare != f { forms.append(bare) }
        }
        // JSON escapes a slash as "\/".
        if b64.contains("/") { forms.append(b64.replacingOccurrences(of: "/", with: "\\/")) }
        return forms
    }

    /// The key as hex, for the decryptor's standard input only.
    var hexForStandardInput: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

/// Removes every key Ycode holds from text before it is shown or logged.
public enum RuntimeSecrets {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: [RuntimeArchiveKey] = []

    /// A key in use; scrubbed from all text until `forget`.
    public static func register(_ k: RuntimeArchiveKey) { lock.withLock { if !keys.contains(k) { keys.append(k) } } }
    public static func forget(_ k: RuntimeArchiveKey) { lock.withLock { keys.removeAll { $0 == k } } }

    public static func scrub(_ text: String, extra: [RuntimeArchiveKey] = []) -> String {
        var out = text
        for k in lock.withLock({ keys }) + extra {
            for form in k.textForms.sorted(by: { $0.count > $1.count }) where !form.isEmpty {
                out = out.replacingOccurrences(of: form, with: "<redacted>")
            }
        }
        // A key field whatever its value (a JSON or plist line that names it).
        out = out.replacingOccurrences(of: #"("?ArchiveDecryptionKey"?\s*[:=]\s*"?)[^",\s<}]+"#, with: "$1<redacted>", options: .regularExpression)
        return out
    }
}

/// One HTTP answer.
public struct RuntimeHTTPResponse: Sendable {
    public var status: Int
    public var body: Data
    public var etag: String?
    public init(status: Int, body: Data, etag: String? = nil) {
        self.status = status
        self.body = body
        self.etag = etag
    }
}

/// Stops a long step: the download, the decryption, the disk-image reader.
public final class RuntimeCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: @Sendable () -> Void] = [:]
    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let hs: [@Sendable () -> Void] = lock.withLock {
            cancelled = true
            return Array(handlers.values)
        }
        for h in hs { h() }
    }

    /// Runs `h` on cancel (at once when already cancelled); the token removes it.
    @discardableResult
    func onCancel(_ h: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        let now: Bool = lock.withLock {
            if cancelled { return true }
            handlers[id] = h
            return false
        }
        if now { h() }
        return id
    }

    func remove(_ id: UUID) { _ = lock.withLock { handlers.removeValue(forKey: id) } }

    func check() throws { if isCancelled { throw RuntimeDownloadError.cancelled } }
}

public protocol RuntimeTransport: Sendable {
    /// A GET (conditional when `etag` is given: 304 means unchanged).
    func get(_ url: URL, etag: String?) async throws -> RuntimeHTTPResponse
    /// A JSON POST; `caFile` is the one root certificate (PEM) the server must chain to.
    func post(_ url: URL, json: Data, headers: [String: String], caFile: String?) async throws -> RuntimeHTTPResponse
    /// Appends the bytes from `offset` to the file (an HTTP range when
    /// `offset` > 0). Returns when the transfer ends; the file keeps what
    /// arrived, so a later call resumes.
    func download(_ url: URL, to file: String, from offset: Int64, cancel: RuntimeCancellation) async throws
}

/// The system's curl, as a separate program.
public struct CurlTransport: RuntimeTransport {
    public var curl: String
    public var userAgent: String

    public init(curl: String = CurlTransport.defaultPath, userAgent: String = RuntimeHostDescription.current().userAgent) {
        self.curl = curl
        self.userAgent = userAgent
    }

    public static var defaultPath: String {
        if let c = ProcessInfo.processInfo.environment["YCODE_CURL"], !c.isEmpty { return c }
        return FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") ? "/usr/bin/curl" : "curl"
    }

    func tempFile(_ name: String) -> String {
        NSTemporaryDirectory() + "ycode-\(name)-\(UUID().uuidString)"
    }

    public func get(_ url: URL, etag: String?) async throws -> RuntimeHTTPResponse {
        let headers = tempFile("h"), body = tempFile("b")
        defer { try? FileManager.default.removeItem(atPath: headers); try? FileManager.default.removeItem(atPath: body) }
        var args = [curl, "-sS", "-L", "--max-time", "120", "-A", userAgent, "-D", headers, "-o", body, "-w", "%{http_code}"]
        if let etag { args += ["-H", "If-None-Match: \(etag)"] }
        args.append(url.absoluteString)
        let p = SetupProcess(args)
        let status = await p.run()
        guard status == 0, let code = Int(p.text.trimmed.suffix(3)) else {
            throw RuntimeDownloadError.network("Could not reach \(url.host ?? "the server"): \(RuntimeSecrets.scrub(p.text.trimmed)) (curl \(status)).")
        }
        let head = (try? String(contentsOfFile: headers, encoding: .utf8)) ?? ""
        return RuntimeHTTPResponse(status: code, body: FileManager.default.contents(atPath: body) ?? Data(), etag: Self.header("etag", in: head))
    }

    public func post(_ url: URL, json: Data, headers h: [String: String], caFile: String?) async throws -> RuntimeHTTPResponse {
        let body = tempFile("b")
        defer { try? FileManager.default.removeItem(atPath: body) }
        var args = [curl, "-sS", "--max-time", "60", "-A", userAgent, "-X", "POST", "-H", "Content-Type: application/json", "--data-binary", "@-",
                    "-o", body, "-w", "%{http_code}"]
        for (k, v) in h.sorted(by: { $0.key < $1.key }) { args += ["-H", "\(k): \(v)"] }
        if let caFile { args += ["--cacert", caFile] }
        args.append(url.absoluteString)
        let p = SetupProcess(args, stdin: String(decoding: json, as: UTF8.self))
        let status = await p.run()
        guard status == 0, let code = Int(p.text.trimmed.suffix(3)) else {
            if status == 60 || status == 35 {
                throw RuntimeDownloadError.untrusted("\(url.host ?? "the server") did not present a certificate from Apple's root (curl \(status))")
            }
            throw RuntimeDownloadError.network("Could not reach \(url.host ?? "the server"): \(RuntimeSecrets.scrub(p.text.trimmed)) (curl \(status)).")
        }
        return RuntimeHTTPResponse(status: code, body: FileManager.default.contents(atPath: body) ?? Data())
    }

    public func download(_ url: URL, to file: String, from offset: Int64, cancel: RuntimeCancellation) async throws {
        try cancel.check()
        if offset == 0 { FileManager.default.createFile(atPath: file, contents: nil) }
        // -C appends to the file from `offset`; -f fails on an HTTP error; a
        // server that ignores the range makes curl stop (33) rather than
        // append the whole file again.
        let args = [curl, "-sS", "-f", "-L", "-A", userAgent, "--retry", "2", "--speed-limit", "1024", "--speed-time", "60",
                    "-C", String(offset), "-o", file, url.absoluteString]
        let p = SetupProcess(args)
        let token = cancel.onCancel { p.terminate() }
        defer { cancel.remove(token) }
        let status = await p.run()
        try cancel.check()
        guard status == 0 else {
            if status == 33 { throw RuntimeDownloadError.network("The server would not resume the download (no byte ranges).") }
            throw RuntimeDownloadError.network("The download from \(url.host ?? "the server") stopped: \(RuntimeSecrets.scrub(p.text.trimmed)) (curl \(status)). Download again to resume.")
        }
    }

    /// The last value of a header in a dump (redirects leave several blocks).
    static func header(_ name: String, in dump: String) -> String? {
        var found: String?
        for line in dump.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == name else { continue }
            found = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return found
    }
}
