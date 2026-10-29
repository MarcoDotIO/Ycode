import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Minimal HTTP for the providers: one-shot requests and streamed bodies
/// read as they arrive. Works with swift-corelibs-foundation (Linux), which
/// has no `URLSession.bytes`, so streaming uses a data delegate.
public enum HTTP {
    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var contentType: String?
        public var text: String { String(decoding: body, as: UTF8.self) }
    }

    /// One part of a streamed response: the status first, then body bytes.
    public enum Chunk: Sendable {
        case head(status: Int, contentType: String?)
        case body(Data)
    }

    /// Sends `request` and returns the whole response. Cancelling the
    /// calling task cancels the request.
    public static func send(_ request: URLRequest, timeout: TimeInterval = 30) async throws -> Response {
        var request = request
        request.timeoutInterval = timeout
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let holder = TaskHolder()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { return c.resume(throwing: error) }
                    let http = response as? HTTPURLResponse
                    c.resume(returning: Response(status: http?.statusCode ?? 0, body: data ?? Data(),
                                                 contentType: http?.value(forHTTPHeaderField: "Content-Type")))
                }
                holder.set(task)
                task.resume()
            }
        } onCancel: {
            holder.cancel()
        }
    }

    /// Streams the response to `request`: `.head`, then `.body` chunks as
    /// they arrive. Ending the iteration cancels the request.
    public static func stream(_ request: URLRequest, timeout: TimeInterval = 300) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            var request = request
            request.timeoutInterval = timeout
            let delegate = StreamDelegate(continuation)
            let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    final class TaskHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false
        func set(_ t: URLSessionTask) {
            lock.lock()
            task = t
            let c = cancelled
            lock.unlock()
            if c { t.cancel() }
        }
        func cancel() {
            lock.lock()
            cancelled = true
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }

    final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let continuation: AsyncThrowingStream<Chunk, Error>.Continuation
        private let lock = NSLock()
        private var sentHead = false
        init(_ c: AsyncThrowingStream<Chunk, Error>.Continuation) { continuation = c }

        /// Yields the status once, from whichever callback sees it first
        /// (some Foundation versions do not call the response callback).
        func head(_ response: URLResponse?) {
            lock.lock()
            let first = !sentHead && response != nil
            if first { sentHead = true }
            lock.unlock()
            guard first, let http = response as? HTTPURLResponse else { return }
            continuation.yield(.head(status: http.statusCode, contentType: http.value(forHTTPHeaderField: "Content-Type")))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            head(response)
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            head(dataTask.response)
            continuation.yield(.body(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if error == nil { head(task.response) }
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            session.finishTasksAndInvalidate()
        }
    }

    /// Streams `request` and hands each body line to `line` while the
    /// status is 2xx; `line` returns true to stop early. A non-2xx status
    /// collects the body and throws `error(status, body)`. Throws
    /// `CancellationError` when the calling task is cancelled.
    public static func streamLines(_ request: URLRequest, timeout: TimeInterval = 300,
                                   error makeError: (Int, Data) -> Error, line: (String) throws -> Bool) async throws {
        var status = 0
        var errorBody = Data()
        var splitter = LineSplitter()
        loop: for try await chunk in stream(request, timeout: timeout) {
            switch chunk {
            case .head(let s, _): status = s
            case .body(let d):
                if !(200..<300).contains(status) { errorBody.append(d); continue }
                for l in splitter.push(d) where try line(l) { break loop }
            }
        }
        try Task.checkCancellation()
        if !(200..<300).contains(status) { throw makeError(status, errorBody) }
        if let last = splitter.finish() { _ = try line(last) }
    }

    /// Whether `error` means nothing answered at the address (as opposed to
    /// an HTTP error or a cancelled request).
    public static func isUnreachable(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut,
                .dnsLookupFailed, .badServerResponse].contains(e.code)
    }

    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// A JSON POST request.
    public static func jsonRequest(_ url: URL, body: Any, headers: [String: String] = [:]) throws -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    /// A form-encoded POST request (OAuth token and revocation endpoints).
    public static func formRequest(_ url: URL, fields: [(String, String)]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.httpBody = Data(formEncode(fields).utf8)
        return r
    }

    /// `application/x-www-form-urlencoded` (RFC 6749 §B).
    public static func formEncode(_ fields: [(String, String)]) -> String {
        fields.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
    }

    static func formEscape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// Joins `path` (no leading slash needed) onto a base URL string,
    /// keeping the base's own path ("http://h/v1" + "models").
    public static func url(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return URL(string: b + "/" + p)
    }

    /// The `error` text of a JSON error body, in the shapes the providers
    /// use: `{"error": "…"}`, `{"error": {"message": "…", "code": "…"}}`,
    /// `{"detail": "…"}`, `{"message": "…"}`.
    public static func errorMessage(_ body: Data) -> (message: String, code: String?) {
        guard let o = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return (String(decoding: body.prefix(500), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        if let e = o["error"] as? String { return (e, o["code"] as? String) }
        if let e = o["error"] as? [String: Any] {
            return ((e["message"] as? String) ?? (e["code"] as? String) ?? "", e["code"] as? String)
        }
        if let d = o["detail"] as? String { return (d, nil) }
        if let m = o["message"] as? String { return (m, o["code"] as? String) }
        return ("", nil)
    }
}

/// Splits a byte stream into lines (LF or CRLF).
public struct LineSplitter: Sendable {
    private var buffer = Data()
    public init() {}

    public mutating func push(_ data: Data) -> [String] {
        buffer.append(data)
        var lines: [String] = []
        while let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            var line = buffer[buffer.startIndex..<nl]
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            lines.append(String(decoding: line, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return lines
    }

    /// The last line when the stream ended without a newline.
    public mutating func finish() -> String? {
        defer { buffer = Data() }
        return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
    }
}

/// Server-sent events (the WHATWG event-stream format): `event:` and
/// `data:` fields, one event per blank-line-terminated block.
public struct SSEDecoder: Sendable {
    public struct Event: Sendable, Equatable {
        public var name: String?
        public var data: String
    }
    private var name: String?
    private var data: [String] = []
    public init() {}

    public mutating func push(line: String) -> Event? {
        if line.isEmpty {
            defer { name = nil; data = [] }
            return data.isEmpty ? nil : Event(name: name, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            var v = line[line.index(after: colon)...]
            if v.first == " " { v = v.dropFirst() }
            value = v
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": name = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    /// An event left without its terminating blank line.
    public mutating func finish() -> Event? { push(line: "") }
}

/// Reads JSON objects from text.
enum JSON {
    static func object(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }
    static func object(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let d = v as? Double { return Int(d) }
        return nil
    }
}
