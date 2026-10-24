import Foundation
import YcodeDarwinABI

// AF_UNIX sockets inside the VMM (`specs/simulator/stage4b-contract.md` §2
// item 4 and §6 item 3; semantics `specs/simulator/processes.md` §5 and
// xnu's `uipc_usrreq.c`). Every guest process of a device runs in one host
// process, so a socket is a plain object shared under the kernel lock:
// passing a descriptor passes a reference, and blocking is a `WaitQueue`
// wait. Owner: agent F.
//
// Data lives in the receiver: a stream writer appends to its peer's receive
// queue (back-pressure: at most the writer's SO_SNDBUF bytes in flight), a
// datagram is appended to the target's queue or fails at once (ENOBUFS when
// the target's SO_RCVBUF is full; Darwin never blocks a datagram sender).

/// Darwin socket ABI values (`processes.md` §5.1).
enum SocketABI {
    static let afUnspec: Int32 = 0, afUnix: Int32 = 1, afInet: Int32 = 2, afInet6: Int32 = 30
    static let sockStream: Int32 = 1, sockDgram: Int32 = 2
    static let solSocket: Int32 = 0xFFFF, solLocal: Int32 = 0
    static let scmRights: Int32 = 1
    static let msgOOB: Int32 = 0x1, msgPeek: Int32 = 0x2, msgTrunc: Int32 = 0x10, msgCtrunc: Int32 = 0x20,
               msgWaitAll: Int32 = 0x40, msgDontWait: Int32 = 0x80, msgNoSignal: Int32 = 0x80000
    static let soDebug: Int32 = 0x1, soAcceptConn: Int32 = 0x2, soLinger: Int32 = 0x80,
               soSndBuf: Int32 = 0x1001, soRcvBuf: Int32 = 0x1002, soSndLowat: Int32 = 0x1003,
               soRcvLowat: Int32 = 0x1004, soSndTimeo: Int32 = 0x1005, soRcvTimeo: Int32 = 0x1006,
               soError: Int32 = 0x1007, soType: Int32 = 0x1008, soNRead: Int32 = 0x1020,
               soNoSigPipe: Int32 = 0x1022, soNWrite: Int32 = 0x1024, soLingerSec: Int32 = 0x1080
    static let localPeerCred: Int32 = 1, localPeerPID: Int32 = 2, localPeerEPID: Int32 = 3,
               localPeerUUID: Int32 = 4, localPeerEUUID: Int32 = 5, localPeerToken: Int32 = 6
    /// `SOMAXCONN`.
    static let maxBacklog = 128
    /// `SOCK_MAXADDRLEN`.
    static let maxAddressLength = 255
    /// The unnamed address (`getsockname` of an unbound socket, `accept`
    /// and `recvfrom` of an unbound peer): a 16-byte `struct sockaddr` with
    /// `sa_len` 16, family AF_UNIX, zero data.
    static let unnamed: [UInt8] = [16, 1] + [UInt8](repeating: 0, count: 14)
    /// `net.local.stream.sendspace` / `recvspace`.
    static let streamBuffer = 8192
    /// `net.local.dgram.maxdgram` (the datagram send buffer) and `recvspace`.
    static let datagramMax = 2048
    static let datagramReceiveBuffer = 4096
    /// Default send low-water mark (EVFILT_WRITE fires above it).
    static let sendLowWater = 2048
}

/// A guest `sockaddr_un` (`processes.md` §5.3): the bytes as the kernel
/// stores them (`sun_len` = the length given) and the path, cut at the
/// first NUL.
struct UnixAddress {
    var raw: [UInt8]
    var path: String
}

/// A weak reference to a socket.
struct WeakSocket {
    weak var socket: UnixSocket?
}

/// What one receive call took.
struct SocketReceive {
    var bytes: [UInt8] = []
    /// The sender's address (datagrams).
    var from: [UInt8]?
    /// Descriptions passed with SCM_RIGHTS, now owned by the caller.
    var rights: [DarwinOpenFile]?
    /// With MSG_PEEK: how many rights wait with the data (not taken).
    var peekedRights = 0
    /// The datagram was longer than the buffer.
    var truncated = false
}

final class UnixSocket: KernelDescriptorObject {
    enum Kind: Int32 {
        case stream = 1
        case datagram = 2
    }

    struct Segment {
        var bytes: [UInt8]
        var offset = 0
        var rights: [DarwinOpenFile]?
        var remaining: Int { bytes.count - offset }
    }

    struct Datagram {
        var from: [UInt8]
        var bytes: [UInt8]
        var rights: [DarwinOpenFile]?
    }

    let kind: Kind
    let lock: KernelLock
    let signals = ObjectSignals()
    let inode = DescriptorInodes.make()
    /// The creator's credentials (`so_cred`: fstat's uid/gid).
    let creator: DescriptorUser
    /// The process that last used this socket (`LOCAL_PEERPID` of its peer).
    var lastUser: DescriptorUser

    // Naming and connection.
    /// The bound (or, for an accepted socket, the listener's) address.
    var address: [UInt8]?
    /// The canonical guest path of the socket file `bind` made.
    var boundPath: String?
    /// The connected peer (stream) or the default destination (datagram).
    var peer: UnixSocket?
    /// A datagram socket connected to a log path nobody serves.
    var logSink: String?
    /// The host end of a host-provided stream socket (`HostStreamSockets`):
    /// bytes the peer sends are handed to it instead of being queued.
    var hostSink: ((ArraySlice<UInt8>) -> Void)?
    var isConnected = false
    var cantReceiveMore = false
    var cantSendMore = false
    var closed = false
    /// `so_error`: reported once by the next operation or SO_ERROR.
    var error: Int32 = 0

    // Listening.
    var isListening = false
    var backlog = 0
    var pending: [UnixSocket] = []
    /// The listener's credentials, recorded by `listen` (`unp_listen`).
    var listenUser: DescriptorUser?

    // Receive queue.
    var segments: [Segment] = []
    var datagrams: [Datagram] = []
    var queuedBytes = 0
    /// Datagram sockets whose default destination is this socket.
    var connectedSenders: [WeakSocket] = []

    // Options.
    var sendBufferSize: Int
    var receiveBufferSize: Int
    var sendLowWater = SocketABI.sendLowWater
    var receiveLowWater = 1
    var noSigPipe = false
    var receiveTimeout: UInt64?
    var sendTimeout: UInt64?
    var linger: (onOff: Int32, seconds: Int32) = (0, 0)
    /// Other SOL_SOCKET options, stored as given.
    var otherOptions: [Int32: [UInt8]] = [:]
    /// `LOCAL_PEERCRED`: recorded at connect / socketpair time.
    var peerCredentials: DescriptorUser?

    init(kind: Kind, lock: KernelLock, creator: DescriptorUser) {
        self.kind = kind
        self.lock = lock
        self.creator = creator
        self.lastUser = creator
        sendBufferSize = kind == .stream ? SocketABI.streamBuffer : SocketABI.datagramMax
        receiveBufferSize = kind == .stream ? SocketABI.streamBuffer : SocketABI.datagramReceiveBuffer
    }

    var fileType: UInt16 { DarwinStat.S_IFSOCK }

    func lastReferenceClosed() {
        lock.withLock { close() }
    }

    /// xnu `soo_stat` + `uipc_sense`: `S_IFSOCK`, read bits while data can
    /// still arrive or is queued, write bits while sending is allowed, the
    /// queued byte count, the creator's uid/gid, SO_SNDBUF as the block size.
    func descriptorStat() -> DarwinStat {
        var mode = DarwinStat.S_IFSOCK
        if !cantReceiveMore || queuedBytes > 0 { mode |= 0o444 }
        if !cantSendMore { mode |= 0o222 }
        var blk = sendBufferSize
        if kind == .stream, let p = peer { blk += p.queuedBytes }
        return DarwinStat(mode: mode, nlink: 0, ino: inode, uid: creator.uid, gid: creator.gid,
                          size: Int64(queuedBytes), blksize: Int32(clamping: blk))
    }

    // MARK: Readiness (kevent)

    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        if isListening { return (!pending.isEmpty, Int64(pending.count), closed) }
        let rightsWaiting = segments.first?.rights != nil || datagrams.first?.rights != nil
        switch kind {
        case .stream:
            let ready = queuedBytes >= receiveLowWater || rightsWaiting || cantReceiveMore || error != 0
            return (ready, Int64(queuedBytes), cantReceiveMore)
        case .datagram:
            return (!datagrams.isEmpty || cantReceiveMore || error != 0, Int64(queuedBytes), cantReceiveMore)
        }
    }

    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        if cantSendMore { return (true, 0, true) }
        if error != 0 { return (true, 0, false) }
        switch kind {
        case .stream:
            guard isConnected, peer != nil else { return (false, 0, false) }
            let space = streamSpace
            return (space >= min(sendLowWater, sendBufferSize), Int64(space), false)
        case .datagram:
            return (true, Int64(sendBufferSize), false)
        }
    }

    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int { signals.addObserver(observer) }
    func removeReadinessObserver(_ token: Int) { signals.removeObserver(token) }

    // MARK: State

    /// Bytes this stream socket may still put in flight to its peer.
    var streamSpace: Int {
        guard let p = peer else { return 0 }
        return max(0, sendBufferSize - p.queuedBytes)
    }

    /// The peer's address (`getpeername`, an accepted connection's address).
    var peerAddress: [UInt8]? {
        guard let p = peer else { return nil }
        return p.address ?? SocketABI.unnamed
    }

    /// Wakes this socket's and its peer's waiters and observers.
    func changedWithPeer() {
        signals.fire()
        if let p = peer, p !== self { p.signals.fire() }
    }

    /// Takes (or with `peek` copies) up to `max` stream bytes. Rights travel
    /// with the bytes they were sent with: a call takes the rights of the
    /// first segment it reads and stops before the next segment that
    /// carries rights.
    func takeStream(max: Int, peek: Bool, allowRights: Bool)
        -> (bytes: [UInt8], rights: [DarwinOpenFile]?, peekedRights: Int, stoppedAtRights: Bool) {
        var out: [UInt8] = []
        var rights: [DarwinOpenFile]?
        var peeked = 0
        var i = 0
        while i < segments.count {
            if let r = segments[i].rights {
                guard allowRights, i == 0, out.isEmpty, rights == nil, peeked == 0 else {
                    return (out, rights, peeked, true)
                }
                if peek {
                    peeked = r.count
                } else {
                    rights = r
                    segments[i].rights = nil
                }
            }
            if out.count >= max { break }
            let seg = segments[i]
            let n = min(max - out.count, seg.remaining)
            out += seg.bytes[seg.offset..<(seg.offset + n)]
            if peek {
                if n < seg.remaining { break }
                i += 1
            } else {
                segments[i].offset += n
                queuedBytes -= n
                if segments[i].remaining == 0 {
                    segments.remove(at: i)
                } else {
                    break
                }
            }
        }
        return (out, rights, peeked, false)
    }

    /// Appends stream bytes (and rights) sent by the peer.
    func appendStream(_ bytes: ArraySlice<UInt8>, rights: [DarwinOpenFile]?) {
        guard !cantReceiveMore else { return }  // shut down for reading: dropped
        if let hostSink {
            hostSink(bytes)  // rights are dropped (released with this call)
            return
        }
        segments.append(Segment(bytes: Array(bytes), rights: rights))
        queuedBytes += bytes.count
    }

    /// Drops everything queued (rights are released after the queue is
    /// empty, since releasing one may close another socket).
    func flushReceiveQueue() {
        let dropped = (segments, datagrams)
        segments = []
        datagrams = []
        queuedBytes = 0
        withExtendedLifetime(dropped) {}
    }

    /// A stream connection ends: both sides can neither send nor receive
    /// more (queued data stays readable), and neither is connected.
    func disconnectStream() {
        guard let p = peer else { return }
        peer = nil
        isConnected = false
        if p.peer === self { p.peer = nil }
        p.isConnected = false
        p.cantReceiveMore = true
        p.cantSendMore = true
        p.signals.fire()
    }

    /// The socket's last reference is gone (`uipc_detach`): pending
    /// connections are dropped, the peer is disconnected, datagram senders
    /// connected to it get ECONNRESET, queued data and rights are released.
    /// The socket file stays (a later connect is refused).
    func close() {
        guard !closed else { return }
        closed = true
        isListening = false
        let dropped = pending
        pending = []
        for c in dropped { c.close() }
        switch kind {
        case .stream:
            disconnectStream()
        case .datagram:
            if let p = peer, p !== self { p.connectedSenders.removeAll { $0.socket == nil || $0.socket === self } }
            peer = nil
        }
        for w in connectedSenders {
            guard let s = w.socket, s !== self, s.peer === self else { continue }
            s.peer = nil
            s.isConnected = false
            s.error = DarwinErrnoCode.ECONNRESET
            s.signals.fire()
        }
        connectedSenders = []
        cantReceiveMore = true
        cantSendMore = true
        isConnected = false
        flushReceiveQueue()
        signals.fire()
    }
}

// MARK: - Data transfer

extension DarwinKernel {
    /// The paths a datagram may be sent to while nothing is bound there:
    /// the syslog / ASL input sockets. Such a datagram (or a connect to the
    /// path) is accepted and its text logged as a `note: sendto message:`
    /// line, as stage 4a did for every `sendto`: the runtime's logging must
    /// not fail before a log daemon exists (4c). Once a guest binds the path,
    /// datagrams go to it.
    static let logSinkPaths: Set<String> = ["/var/run/syslog", "/var/run/asl_input", "/dev/log"]

    /// Logs a datagram's text like stage 4a's `sendto` (NUL and newline as
    /// spaces, trimmed, at most 2048 bytes).
    func logDatagramText(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let text = String(decoding: bytes.prefix(2048).map { $0 == 0 || $0 == 10 ? 0x20 : $0 }, as: UTF8.self)
        trace("note: sendto message: \(text.trimmingCharacters(in: .whitespaces))")
    }

    /// The socket bound at `path`, nil when the socket file has no open
    /// socket (ECONNREFUSED for the caller). Lookup errors are thrown (ENOENT,
    /// ENOTSOCK for a file that is no socket).
    func boundSocket(at path: String) throws -> UnixSocket? {
        switch try fileSystem.socketTarget(path) {
        case let .socket(o):
            guard let s = o as? UnixSocket, !s.closed else { return nil }
            return s
        case .noSocket:
            return nil
        }
    }

    /// Whether `path` is a log sink now: a log path with nothing at it.
    func isLogSink(_ path: String) -> Bool {
        let normalized = fileSystem.normalize(path, cwd: fileSystem.cwd)
        guard Self.logSinkPaths.contains(normalized) else { return false }
        do {
            _ = try fileSystem.socketTarget(normalized)
            return false
        } catch {
            return true
        }
    }

    /// Sends on a socket (write, send, sendto, sendmsg). EPIPE raises
    /// SIGPIPE in the calling thread unless SO_NOSIGPIPE, MSG_NOSIGNAL, or
    /// F_SETNOSIGPIPE applies.
    func socketSend(_ s: UnixSocket, _ file: DarwinOpenFile, _ bytes: [UInt8], rights: [DarwinOpenFile]?,
                    to address: UnixAddress?, flags: Int32) throws -> Int {
        guard flags & SocketABI.msgOOB == 0 else { throw fail(Code.EOPNOTSUPP) }
        s.lastUser = descriptorUser
        do {
            switch s.kind {
            case .stream:
                return try streamSend(s, file, bytes, rights: rights, to: address, flags: flags)
            case .datagram:
                return try datagramSend(s, bytes, rights: rights, to: address)
            }
        } catch let e as DarwinErrnoError where e.errno == Code.EPIPE {
            if !s.noSigPipe && !file.noSigPipe && flags & SocketABI.msgNoSignal == 0 {
                postSignal(descriptorSIGPIPE, thread: current)
            }
            throw e
        }
    }

    private func takeError(_ s: UnixSocket) throws {
        if s.error != 0 {
            let e = s.error
            s.error = 0
            throw fail(e)
        }
    }

    private func streamSend(_ s: UnixSocket, _ file: DarwinOpenFile, _ bytes: [UInt8], rights: [DarwinOpenFile]?,
                            to address: UnixAddress?, flags: Int32) throws -> Int {
        if s.cantSendMore { throw fail(Code.EPIPE) }
        try takeError(s)
        if !s.isConnected {
            // xnu `uipc_send`: an address connects first.
            guard let address else { throw fail(Code.ENOTCONN) }
            try connectSocket(s, to: address)
        }
        let nonBlocking = file.isNonBlocking || flags & SocketABI.msgDontWait != 0
        let deadline = s.sendTimeout.map { KernelClock.deadline(afterNanoseconds: $0) }
        var rights = rights
        var written = 0
        while true {
            guard !s.cantSendMore, let p = s.peer else {
                if written > 0 { return written }
                throw fail(Code.EPIPE)
            }
            let remaining = bytes.count - written
            if remaining == 0 && rights == nil { return written }
            let space = s.streamSpace
            if space > 0 || remaining == 0 {
                let n = min(space, remaining)
                p.appendStream(bytes[written..<(written + n)], rights: rights)
                rights = nil
                written += n
                s.changedWithPeer()
                if written == bytes.count { return written }
                continue
            }
            if nonBlocking {
                if written > 0 { return written }
                throw fail(Code.EAGAIN)
            }
            do {
                if try !waitOnObject(s.signals, deadline: deadline) {
                    if written > 0 { return written }
                    throw fail(Code.EAGAIN)
                }
            } catch {
                if written > 0 { return written }
                throw error
            }
        }
    }

    private func datagramSend(_ s: UnixSocket, _ bytes: [UInt8], rights: [DarwinOpenFile]?,
                              to address: UnixAddress?) throws -> Int {
        if s.cantSendMore { throw fail(Code.EPIPE) }
        try takeError(s)
        // sosend: a datagram must fit the send buffer.
        guard bytes.count <= s.sendBufferSize else { throw fail(Code.EMSGSIZE) }
        let target: UnixSocket
        if let address {
            guard s.peer == nil, s.logSink == nil else { throw fail(Code.EISCONN) }
            let found: UnixSocket?
            do {
                found = try boundSocket(at: address.path)
            } catch let e as DarwinErrnoError where e.errno == Code.ENOENT && isLogSink(address.path) {
                logDatagramText(bytes)
                return bytes.count
            }
            guard let found else { throw fail(Code.ECONNREFUSED) }
            guard found.kind == s.kind else { throw fail(Code.EPROTOTYPE) }
            target = found
        } else if s.logSink != nil {
            logDatagramText(bytes)
            return bytes.count
        } else {
            guard let p = s.peer else { throw fail(Code.ENOTCONN) }
            target = p
        }
        guard !target.closed else { throw fail(Code.ECONNREFUSED) }
        guard target.queuedBytes + bytes.count <= target.receiveBufferSize else { throw fail(Code.ENOBUFS) }
        if !target.cantReceiveMore {
            target.datagrams.append(UnixSocket.Datagram(from: s.address ?? SocketABI.unnamed, bytes: bytes, rights: rights))
            target.queuedBytes += bytes.count
        }
        target.signals.fire()
        s.signals.fire()
        return bytes.count
    }

    /// Receives from a socket (read, recv, recvfrom, recvmsg). Blocks for
    /// data unless non-blocking (EAGAIN) or SO_RCVTIMEO passes (EAGAIN).
    func socketReceive(_ s: UnixSocket, _ file: DarwinOpenFile, max: Int, flags: Int32) throws -> SocketReceive {
        guard flags & SocketABI.msgOOB == 0 else { throw fail(Code.EOPNOTSUPP) }
        s.lastUser = descriptorUser
        let peek = flags & SocketABI.msgPeek != 0
        let nonBlocking = file.isNonBlocking || flags & SocketABI.msgDontWait != 0
        let deadline = s.receiveTimeout.map { KernelClock.deadline(afterNanoseconds: $0) }
        switch s.kind {
        case .stream:
            let waitAll = flags & SocketABI.msgWaitAll != 0 && !peek
            var out = SocketReceive()
            while true {
                let nothingYet = out.bytes.isEmpty && out.rights == nil
                if s.error != 0 {
                    if !nothingYet { return out }
                    try takeError(s)
                }
                if !s.segments.isEmpty {
                    let r = s.takeStream(max: max - out.bytes.count, peek: peek, allowRights: nothingYet)
                    out.bytes += r.bytes
                    if let rights = r.rights { out.rights = rights }
                    out.peekedRights = Swift.max(out.peekedRights, r.peekedRights)
                    if !peek { s.changedWithPeer() }
                    if !waitAll || out.bytes.count >= max || r.stoppedAtRights || out.rights != nil || peek {
                        return out
                    }
                    if !s.segments.isEmpty { continue }
                }
                if s.cantReceiveMore { return out }
                if !s.isConnected {
                    if nothingYet { throw fail(Code.ENOTCONN) }
                    return out
                }
                if nonBlocking {
                    if nothingYet { throw fail(Code.EAGAIN) }
                    return out
                }
                do {
                    if try !waitOnObject(s.signals, deadline: deadline) {
                        if nothingYet { throw fail(Code.EAGAIN) }
                        return out
                    }
                } catch {
                    if !nothingYet { return out }
                    throw error
                }
            }
        case .datagram:
            while true {
                try takeError(s)
                if let d = s.datagrams.first {
                    var r = SocketReceive()
                    r.from = d.from
                    r.bytes = Array(d.bytes.prefix(max))
                    r.truncated = d.bytes.count > max
                    if peek {
                        r.peekedRights = d.rights?.count ?? 0
                    } else {
                        s.datagrams.removeFirst()
                        s.queuedBytes -= d.bytes.count
                        r.rights = d.rights
                        s.signals.fire()
                    }
                    return r
                }
                if s.cantReceiveMore { return SocketReceive() }
                if nonBlocking { throw fail(Code.EAGAIN) }
                if try !waitOnObject(s.signals, deadline: deadline) { throw fail(Code.EAGAIN) }
            }
        }
    }

    // MARK: Connection

    /// `connect` (and the implicit connect of a stream `sendto`):
    /// `processes.md` §5.3 and xnu `unp_connect`.
    func connectSocket(_ s: UnixSocket, to address: UnixAddress) throws {
        s.lastUser = descriptorUser
        switch s.kind {
        case .stream:
            if s.isListening { throw fail(Code.EOPNOTSUPP) }
            if s.isConnected || s.peer != nil { throw fail(Code.EISCONN) }
            if let sink = HostStreamSockets.sink(for: fileSystem.normalize(address.path, cwd: fileSystem.cwd),
                                                 from: descriptorUser) {
                // A host-provided socket (no guest listener): connected at
                // once to a host end that consumes what is sent.
                let host = UnixSocket(kind: .stream, lock: lock, creator: descriptorUser)
                host.address = address.raw
                host.hostSink = sink
                host.peer = s
                host.isConnected = true
                host.peerCredentials = descriptorUser
                s.peer = host
                s.isConnected = true
                s.peerCredentials = descriptorUser
                s.signals.fire()
                return
            }
            guard let listener = try boundSocket(at: address.path) else { throw fail(Code.ECONNREFUSED) }
            guard listener.kind == s.kind else { throw fail(Code.EPROTOTYPE) }
            guard listener.isListening, listener !== s else { throw fail(Code.ECONNREFUSED) }
            // sonewconn: refuse once more than 3/2 × backlog are pending.
            guard listener.pending.count <= 3 * listener.backlog / 2 else { throw fail(Code.ECONNREFUSED) }
            let server = UnixSocket(kind: .stream, lock: lock, creator: listener.creator)
            server.address = listener.address
            server.lastUser = listener.lastUser
            server.sendBufferSize = listener.sendBufferSize
            server.receiveBufferSize = listener.receiveBufferSize
            server.noSigPipe = listener.noSigPipe
            server.peer = s
            server.isConnected = true
            server.peerCredentials = descriptorUser
            s.peer = server
            s.isConnected = true
            s.peerCredentials = listener.listenUser ?? listener.creator
            listener.pending.append(server)
            listener.signals.fire()
            s.signals.fire()
        case .datagram:
            let target: UnixSocket
            do {
                guard let found = try boundSocket(at: address.path) else { throw fail(Code.ECONNREFUSED) }
                target = found
            } catch let e as DarwinErrnoError where e.errno == Code.ENOENT && isLogSink(address.path) {
                disconnectDatagram(s)
                s.logSink = fileSystem.normalize(address.path, cwd: fileSystem.cwd)
                s.isConnected = true
                return
            }
            guard target.kind == s.kind else { throw fail(Code.EPROTOTYPE) }
            disconnectDatagram(s)
            s.peer = target
            s.isConnected = true
            target.connectedSenders.removeAll { $0.socket == nil }
            target.connectedSenders.append(WeakSocket(socket: s))
            s.signals.fire()
        }
    }

    /// A datagram socket forgets its default destination.
    func disconnectDatagram(_ s: UnixSocket) {
        if let p = s.peer, p !== s { p.connectedSenders.removeAll { $0.socket == nil || $0.socket === s } }
        s.peer = nil
        s.logSink = nil
        s.isConnected = false
    }
}
