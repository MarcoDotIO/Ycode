import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// One end of a JSON-RPC connection: it sends requests and waits for their
/// responses, answers the other end's requests, and receives notifications.
/// Used for the MCP stdio server and both ends of ACP.
///
/// Ordering: notifications and the synchronous part of request handling
/// run on the reading thread in arrival order (so an agent's `session/update`
/// chunks stay in order); the asynchronous work a request handler returns
/// runs in its own task, which `cancelIncoming(_:)` cancels.
public final class JSONRPCPeer: @unchecked Sendable {
    /// The work that answers a request: its result, or a thrown
    /// `JSONRPCError` (any other error becomes an internal error).
    public typealias Work = @Sendable () async throws -> AnyJSON
    public typealias RequestHandler = @Sendable (_ id: JSONRPCID, _ method: String, _ params: AnyJSON?) -> Work
    public typealias NotificationHandler = @Sendable (_ method: String, _ params: AnyJSON?) -> Void

    private let lock = NSLock()
    private let send: @Sendable (Data) -> Void
    private var nextID = 0
    private var pending: [JSONRPCID: CheckedContinuation<AnyJSON, Error>] = [:]
    private var incoming: [JSONRPCID: Task<Void, Never>] = [:]
    private var finished = Set<JSONRPCID>()
    private var cancelled = Set<JSONRPCID>()
    private var closedError: Error?
    private var requestHandler: RequestHandler?
    private var notificationHandler: NotificationHandler?

    /// `send` writes one framed message (it is called from any thread,
    /// one message at a time).
    public init(send: @escaping @Sendable (Data) -> Void) {
        let writeLock = NSLock()
        self.send = { data in writeLock.withLock { send(data) } }
    }

    public func onRequest(_ h: @escaping RequestHandler) { lock.withLock { requestHandler = h } }
    public func onNotification(_ h: @escaping NotificationHandler) { lock.withLock { notificationHandler = h } }

    public func write(_ m: JSONRPCMessage) { send(m.line) }

    /// Sends a request and waits for its result. Throws the peer's
    /// `JSONRPCError`, or the close error when the connection ends first.
    public func request(_ method: String, _ params: AnyJSON? = nil) async throws -> AnyJSON {
        let id: JSONRPCID = lock.withLock {
            defer { nextID += 1 }
            return .int(nextID)
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<AnyJSON, Error>) in
            let closed: Error? = lock.withLock {
                if let e = closedError { return e }
                pending[id] = c
                return nil
            }
            if let closed { c.resume(throwing: closed); return }
            write(.request(id: id, method: method, params: params))
        }
    }

    public func notify(_ method: String, _ params: AnyJSON? = nil) {
        write(.notification(method: method, params: params))
    }

    /// Handles one received line.
    public func receive(_ line: Data) {
        let message: JSONRPCMessage
        do {
            message = try JSONRPCMessage.parse(line)
        } catch let e as JSONRPCError {
            write(.error(id: nil, error: e))
            return
        } catch {
            write(.error(id: nil, error: .parseError()))
            return
        }
        receive(message)
    }

    public func receive(_ message: JSONRPCMessage) {
        switch message {
        case .result(let id, let result):
            lock.withLock { pending.removeValue(forKey: id) }?.resume(returning: result)
        case .error(let id, let error):
            guard let id else { return }
            lock.withLock { pending.removeValue(forKey: id) }?.resume(throwing: error)
        case .notification(let method, let params):
            lock.withLock { notificationHandler }?(method, params)
        case .request(let id, let method, let params):
            guard let handler = lock.withLock({ requestHandler }) else {
                write(.error(id: id, error: .methodNotFound(method)))
                return
            }
            let work = handler(id, method, params)
            let task = Task { [weak self] in
                let reply: JSONRPCMessage
                do {
                    reply = .result(id: id, result: try await work())
                } catch let e as JSONRPCError {
                    reply = .error(id: id, error: e)
                } catch is CancellationError {
                    reply = .error(id: id, error: .init(code: -32800, message: "Request cancelled"))
                } catch {
                    reply = .error(id: id, error: .internalError(String(describing: error)))
                }
                guard let self else { return }
                let suppressed = self.lock.withLock { () -> Bool in
                    // Finished before it was registered: registration skips it.
                    let wasCancelled = self.cancelled.remove(id) != nil
                    if self.incoming.removeValue(forKey: id) == nil && !wasCancelled { self.finished.insert(id) }
                    return wasCancelled
                }
                // A cancelled request (MCP: notifications/cancelled) gets no reply.
                if !suppressed { self.write(reply) }
            }
            lock.withLock { if finished.remove(id) == nil { incoming[id] = task } }
        }
    }

    /// Cancels the work answering one of the other end's requests; no
    /// response is sent for it.
    public func cancelIncoming(_ id: JSONRPCID) {
        // Requests are registered on the reading thread before a later
        // cancellation is read, so only a running request is marked.
        lock.withLock { () -> Task<Void, Never>? in
            guard let t = incoming.removeValue(forKey: id) else { return nil }
            cancelled.insert(id)
            return t
        }?.cancel()
    }

    /// Ends the connection: waiting requests fail with `error`.
    public func close(_ error: Error = JSONRPCError(code: -32000, message: "connection closed")) {
        let waiting: [CheckedContinuation<AnyJSON, Error>] = lock.withLock {
            closedError = error
            defer { pending = [:] }
            return Array(pending.values)
        }
        waiting.forEach { $0.resume(throwing: error) }
    }

    /// Requests still being answered (tests, shutdown).
    public var incomingCount: Int { lock.withLock { incoming.count } }
}

/// Reads newline-framed messages from a file descriptor on a thread of its
/// own until end of file.
public final class LineReader: @unchecked Sendable {
    private let fd: Int32
    private let onLine: @Sendable (Data) -> Void
    private let onEnd: @Sendable () -> Void

    public init(fileDescriptor fd: Int32, onLine: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.onLine = onLine
        self.onEnd = onEnd
    }

    public func start() {
        let t = Thread { [self] in run() }
        t.name = "ycode.jsonrpc.reader"
        t.start()
    }

    private func run() {
        var framer = LineFramer()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            for line in framer.append(Data(buf[0..<n])) { onLine(line) }
        }
        if let last = framer.flush() { onLine(last) }
        onEnd()
    }
}

/// Writes whole buffers to a file descriptor (retrying short writes).
public enum FDWriter {
    @discardableResult
    public static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                #if canImport(Glibc)
                let n = Glibc.write(fd, p, left)
                #else
                let n = Darwin.write(fd, p, left)
                #endif
                if n < 0 { if errno == EINTR { continue }; return false }
                left -= n
                p += n
            }
            return true
        }
    }
}
