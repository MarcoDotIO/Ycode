import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

// Addresses, the Unix socket transport and authentication (D-Bus
// Specification 0.43, "Server Addresses", "Unix Domain Sockets",
// "Authentication Protocol"). Only what a client of a local bus needs:
// `unix:path=…` and `unix:abstract=…` (Linux), the credentials nul byte,
// SASL EXTERNAL with the decimal Unix user ID hex-encoded, then BEGIN.

/// One entry of an address list (`transport:key=value,…`).
public struct DBusAddress: Equatable, Sendable {
    public var transport: String
    public var parameters: [String: String]

    /// Parses `a;b;c`, unescaping `%xx` values. Throws on malformed
    /// entries (no colon, a key without `=`, a bad escape).
    public static func parse(_ text: String) throws -> [DBusAddress] {
        try text.split(separator: ";").map { entry in
            guard let colon = entry.firstIndex(of: ":") else { throw DBusError.noAddress("no transport in \"\(entry)\"") }
            var a = DBusAddress(transport: String(entry[..<colon]), parameters: [:])
            let rest = entry[entry.index(after: colon)...]
            for pair in rest.split(separator: ",") {
                guard let eq = pair.firstIndex(of: "=") else { throw DBusError.noAddress("no value in \"\(pair)\"") }
                a.parameters[String(pair[..<eq])] = try unescape(pair[pair.index(after: eq)...])
            }
            return a
        }
    }

    /// Value unescaping: `%` and two hex digits stand for a byte.
    public static func unescape(_ s: Substring) throws -> String {
        var out: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            if c == UInt8(ascii: "%") {
                guard it.count >= 2, let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) else {
                    throw DBusError.noAddress("bad escape in \"\(s)\"")
                }
                out.append(v)
                it = it.dropFirst(2)
            } else {
                out.append(c)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Value escaping: bytes outside `[-0-9A-Za-z_/.\*]` become `%xx`.
    public static func escape(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let keep = DBusNames.isElementByte(b) || b == UInt8(ascii: "-") || b == UInt8(ascii: "/")
                || b == UInt8(ascii: ".") || b == UInt8(ascii: "\\") || b == UInt8(ascii: "*")
            out += keep ? String(UnicodeScalar(b)) : String(format: "%%%02x", b)
        }
        return out
    }
}

/// The SASL lines of the client side.
public enum DBusAuth {
    /// `AUTH EXTERNAL <hex of the decimal uid>\r\n` (spec figure 1:
    /// uid 1000 → `31303030`).
    public static func externalCommand(uid: UInt32) -> String {
        let id = String(uid).utf8.map { String(format: "%02x", $0) }.joined()
        return "AUTH EXTERNAL \(id)\r\n"
    }

    /// The server GUID of an `OK <guid>` line, or nil for any other line.
    public static func guid(fromReply line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("OK ") else { return nil }
        return String(t.dropFirst(3))
    }
}

/// A connected, authenticated stream socket.
public final class DBusSocket: @unchecked Sendable {
    public private(set) var fd: Int32
    public private(set) var serverGUID = ""

    init(fd: Int32) { self.fd = fd }

    deinit { close() }

    public func close() {
        if fd >= 0 {
            _ = systemClose(fd)
            fd = -1
        }
    }

    /// Connects to the first entry of `address` that works and
    /// authenticates.
    public static func connect(address: String, timeout: Double = 5) throws -> DBusSocket {
        var reasons: [String] = []
        for a in try DBusAddress.parse(address) {
            guard a.transport == "unix" else {
                reasons.append("transport \(a.transport) is not supported")
                continue
            }
            do {
                let s: DBusSocket
                if let p = a.parameters["path"] {
                    s = try openUnix(Array(p.utf8), abstract: false)
                } else if let p = a.parameters["abstract"] {
                    s = try openUnix(Array(p.utf8), abstract: true)
                } else {
                    reasons.append("unix address without path or abstract")
                    continue
                }
                try s.authenticate(timeout: timeout)
                return s
            } catch {
                reasons.append("\(error)")
            }
        }
        throw DBusError.noAddress(reasons.joined(separator: "; "))
    }

    private static func openUnix(_ name: [UInt8], abstract: Bool) throws -> DBusSocket {
        #if canImport(Darwin)
        if abstract { throw DBusError.io("abstract sockets need Linux") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw DBusError.io("socket: \(errnoText())") }
        let s = DBusSocket(fd: fd)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = (abstract ? [0] : []) + name
        guard bytes.count < capacity else { throw DBusError.io("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 2
        // Abstract names are exactly their bytes; paths get their nul.
        let length = pathOffset + bytes.count + (abstract ? 0 : 1)
        #if canImport(Darwin)
        addr.sun_len = UInt8(length)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let r = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemConnect(fd, $0, socklen_t(length)) }
        }
        guard r == 0 else { throw DBusError.io("connect: \(errnoText())") }
        return s
    }

    // MARK: Authentication

    func authenticate(timeout: Double) throws {
        // The credentials-passing nul byte, then EXTERNAL.
        try write([0] + Array(DBusAuth.externalCommand(uid: UInt32(getuid())).utf8))
        let line = try readLine(timeout: timeout)
        guard let guid = DBusAuth.guid(fromReply: line) else {
            throw DBusError.authenticationFailed(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        serverGUID = guid
        try write(Array("BEGIN\r\n".utf8))
    }

    /// Reads one `\r\n`-terminated line byte by byte (nothing after it is
    /// consumed: the server sends no message before BEGIN anyway).
    private func readLine(timeout: Double) throws -> String {
        var line: [UInt8] = []
        let deadline = Date().addingTimeInterval(timeout)
        while !(line.count >= 2 && line[line.count - 2] == 13 && line[line.count - 1] == 10) {
            guard line.count < 16_384 else { throw DBusError.authenticationFailed("line too long") }
            let left = deadline.timeIntervalSinceNow
            guard left > 0, waitReadable(timeout: left) else { throw DBusError.timeout("authentication") }
            var b: UInt8 = 0
            let n = systemRead(fd, &b, 1)
            guard n == 1 else { throw n == 0 ? DBusError.disconnected : DBusError.io("read: \(errnoText())") }
            line.append(b)
        }
        return String(decoding: line, as: UTF8.self)
    }

    // MARK: I/O

    /// Writes all of `bytes` (blocking).
    public func write(_ bytes: [UInt8]) throws {
        guard fd >= 0 else { throw DBusError.disconnected }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { raw -> Int in
                #if canImport(Darwin)
                return send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                #else
                return send(fd, raw.baseAddress! + sent, raw.count - sent, Int32(MSG_NOSIGNAL))
                #endif
            }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    _ = waitWritable(timeout: 1)
                    continue
                }
                throw errno == EPIPE ? DBusError.disconnected : DBusError.io("send: \(errnoText())")
            }
            sent += n
        }
    }

    /// Reads what is available (blocking until at least one byte or EOF);
    /// an empty result means the peer closed the connection, nil that
    /// nothing was there.
    public func readAvailable(max: Int = 65_536) throws -> [UInt8]? {
        guard fd >= 0 else { throw DBusError.disconnected }
        var buffer = [UInt8](repeating: 0, count: max)
        while true {
            let n = buffer.withUnsafeMutableBytes { systemRead(fd, $0.baseAddress!, max) }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return nil }
                throw DBusError.io("read: \(errnoText())")
            }
            return Array(buffer[0..<n])
        }
    }

    /// Waits until the socket is readable (or closed) for up to `timeout`
    /// seconds.
    public func waitReadable(timeout: Double) -> Bool { poll(events: Int16(POLLIN), timeout: timeout) }

    func waitWritable(timeout: Double) -> Bool { poll(events: Int16(POLLOUT), timeout: timeout) }

    private func poll(events: Int16, timeout: Double) -> Bool {
        guard fd >= 0 else { return false }
        var p = pollfd(fd: fd, events: events, revents: 0)
        let ms = Int32(max(0, min(timeout, 86_400)) * 1_000)
        while true {
            let r = systemPoll(&p, 1, ms)
            if r < 0 && errno == EINTR { continue }
            return r > 0
        }
    }
}

// The C functions under names that do not clash with our methods.
private func systemClose(_ fd: Int32) -> Int32 { close(fd) }
private func systemRead(_ fd: Int32, _ p: UnsafeMutableRawPointer, _ n: Int) -> Int { read(fd, p, n) }
private func systemConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ l: socklen_t) -> Int32 { connect(fd, a, l) }
private func systemPoll(_ p: UnsafeMutablePointer<pollfd>, _ n: Int, _ ms: Int32) -> Int32 { poll(p, nfds_t(n), ms) }
func errnoText() -> String { String(cString: strerror(errno)) }
