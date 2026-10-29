import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A tiny HTTP/1.1 server on 127.0.0.1 for the OAuth redirect (RFC 8252
/// §7.3 loopback redirect). One request per connection; the handler gets
/// the request and returns the response. Tests also use it as a stand-in
/// for model servers and token endpoints.
public final class LoopbackServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        /// The request target, e.g. `/auth/callback?code=…`.
        public var target: String
        public var headers: [String: String]
        public var body: Data
        public var path: String { String(target.split(separator: "?", maxSplits: 1).first ?? "") }
        public var query: [String: String] {
            guard let q = URLComponents(string: "http://h" + target)?.queryItems else { return [:] }
            var out: [String: String] = [:]
            for i in q { out[i.name] = i.value ?? "" }
            return out
        }
        /// The fields of a form-encoded body.
        public var form: [String: String] {
            guard let q = URLComponents(string: "http://h/?" + String(decoding: body, as: UTF8.self).replacingOccurrences(of: "+", with: "%20"))?.queryItems
            else { return [:] }
            var out: [String: String] = [:]
            for i in q { out[i.name] = i.value ?? "" }
            return out
        }
        public func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    public struct Response: Sendable {
        public var status: Int
        public var headers: [String: String]
        /// Body parts, written one after another (with `delay` seconds
        /// between them) so tests can stream.
        public var chunks: [Data]
        public var delay: TimeInterval
        public init(status: Int = 200, contentType: String = "text/plain; charset=utf-8", body: Data = Data(), chunks: [Data]? = nil,
                    delay: TimeInterval = 0, headers: [String: String] = [:]) {
            self.status = status
            var h = headers
            h["Content-Type"] = contentType
            self.headers = h
            self.chunks = chunks ?? [body]
            self.delay = delay
        }
        public static func json(_ object: Any, status: Int = 200) -> Response {
            Response(status: status, contentType: "application/json",
                     body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        public static func text(_ s: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> Response {
            Response(status: status, contentType: contentType, body: Data(s.utf8))
        }
    }

    public typealias Handler = @Sendable (Request) -> Response

    private let fd: Int32
    public let port: UInt16
    private let handler: Handler
    private let lock = NSLock()
    private var stopped = false

    /// Binds 127.0.0.1:`port` (0 = any free port) and starts accepting.
    public init(port: UInt16 = 0, handler: @escaping Handler) throws {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard s >= 0 else { throw AssistantError.signIn("Cannot open a local socket.") }
        var yes: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(s, 16) == 0 else {
            close(s)
            throw AssistantError.signIn("Cannot listen on 127.0.0.1:\(port).")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
        fd = s
        self.port = UInt16(bigEndian: got.sin_port)
        self.handler = handler
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    /// `http://127.0.0.1:<port>`.
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    public func stop() {
        lock.lock()
        let was = stopped
        stopped = true
        lock.unlock()
        guard !was else { return }
        shutdown(fd, Int32(SHUT_RDWR))
        // Wake a blocked accept() (close alone does not on every system).
        #if canImport(Glibc)
        let w = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let w = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        if w >= 0 {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(w, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            close(w)
        }
        close(fd)
    }

    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }

    private func acceptLoop() {
        while !isStopped {
            let c = accept(fd, nil, nil)
            if c < 0 {
                if errno == EINTR { continue }
                return
            }
            #if canImport(Darwin)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            #endif
            Thread.detachNewThread { [self] in serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        guard let request = readRequest(c) else { return }
        let r = handler(request)
        let reason = [200: "OK", 201: "Created", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden",
                      404: "Not Found", 429: "Too Many Requests", 500: "Internal Server Error", 503: "Service Unavailable"][r.status] ?? "Status"
        var head = "HTTP/1.1 \(r.status) \(reason)\r\nConnection: close\r\n"
        for (k, v) in r.headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        guard sendAll(c, Data(head.utf8)) else { return }
        for (i, chunk) in r.chunks.enumerated() {
            if i > 0 && r.delay > 0 { Thread.sleep(forTimeInterval: r.delay) }
            if isStopped || !sendAll(c, chunk) { return }
        }
    }

    private func sendAll(_ c: Int32, _ d: Data) -> Bool {
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                #if canImport(Glibc)
                let n = send(c, p, left, Int32(MSG_NOSIGNAL))
                #else
                let n = send(c, p, left, 0)
                #endif
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                p += n
            }
            return true
        }
    }

    private func readRequest(_ c: Int32) -> Request? {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { return nil }
            data.append(contentsOf: buf[0..<n])
            headerEnd = data.range(of: Data("\r\n\r\n".utf8))
            if data.count > 1 << 20 { return nil }
        }
        guard let end = headerEnd else { return nil }
        let headText = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data(data[end.upperBound...])
        let length = Int(headers["content-length"] ?? "") ?? 0
        while body.count < length {
            let n = recv(c, &buf, buf.count, 0)
            if n <= 0 { break }
            body.append(contentsOf: buf[0..<n])
        }
        return Request(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
}
