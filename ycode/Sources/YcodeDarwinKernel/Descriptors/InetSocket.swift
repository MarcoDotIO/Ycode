import Foundation
import YcodeDarwinABI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// AF_INET / AF_INET6 sockets backed by host sockets
// (`specs/simulator/networking-ycode.md` §2). A guest IP socket is a
// non-blocking host socket of the same family, type and protocol in the
// ycode-simd process: the guest's traffic is the host's traffic, as the
// processes of Apple's simulator use the Mac's own network stack. The
// kernel keeps what the host cannot express in Darwin terms (blocking and
// timeouts, SO_NOSIGPIPE, Darwin-only options, the connect state machine,
// interface indexes) and translates the rest (`InetSocketABI.swift`).
//
// Every field is guarded by the kernel lock `lock`, except `hostFD` reads by
// `hostDescriptorChanged` (which only uses `self`).

final class InetSocket: KernelDescriptorObject, HostPolledObject {
    enum State: UInt8 {
        /// Fresh, bound, or a datagram socket (connected or not).
        case idle = 0
        /// A stream connect is in progress on the host.
        case connecting = 1
        /// A stream socket is connected (or was: see `shutRead`).
        case connected = 2
        case listening = 3
    }

    struct OptionKey: Hashable {
        var level: Int32
        var name: Int32
    }

    /// Darwin domain, type and protocol.
    let domain: Int32
    let type: Int32
    let proto: Int32
    let lock: KernelLock
    let signals = ObjectSignals()
    let inode = DescriptorInodes.make()
    let creator: DescriptorUser
    var lastUser: DescriptorUser

    /// The host socket; -1 once closed or after a restore that could not
    /// recreate it.
    private(set) var hostFD: Int32
    var state: State = .idle
    /// The guest connected a datagram socket.
    var datagramConnected = false
    /// The guest bound the socket (bind, or implicitly by connect/listen).
    var bound = false
    /// An error the next operation or SO_ERROR reports once (a failed
    /// non-blocking connect, a connection reset by a snapshot restore).
    var pendingError: Int32 = 0
    /// The host connection is gone (snapshot restore): reads end at EOF,
    /// writes fail with EPIPE.
    var isReset = false
    var shutRead = false
    var shutWrite = false
    var closed = false

    // Kernel-kept options.
    var noSigPipe = false
    var receiveTimeout: UInt64?
    var sendTimeout: UInt64?
    var localOptions: [OptionKey: [UInt8]] = [:]
    /// Options set on the host, in guest form, in order (re-applied when a
    /// socket is recreated at restore).
    var appliedOptions: [(key: OptionKey, value: [UInt8])] = []
    var requestedSendBuffer: Int32?
    var requestedReceiveBuffer: Int32?
    var wants = ControlMessages.ReceiveWants()
    /// IP_BOUND_IF / IPV6_BOUND_IF (a guest index; 0 = none).
    var boundInterface: UInt32 = 0
    /// The guest's bound address (for a restore).
    var boundAddress: InetAddress?
    /// The listen backlog (for a restore).
    var backlog: Int32 = 0

    // Poller registration (lazy: made at the first wait or observer).
    private var pollToken: UInt64?

    init(domain: Int32, type: Int32, proto: Int32, hostFD: Int32, lock: KernelLock, creator: DescriptorUser) {
        self.domain = domain
        self.type = type
        self.proto = proto
        self.hostFD = hostFD
        self.lock = lock
        self.creator = creator
        self.lastUser = creator
        if hostFD >= 0 { InetSocketStats.add(1) }
    }

    deinit {
        if hostFD >= 0 { closeHostSocket() }
    }

    var isStream: Bool { type == InetABI.sockStream }
    var fileType: UInt16 { DarwinStat.S_IFSOCK }

    /// Creates the host socket for a Darwin (domain, type, protocol).
    static func makeHost(domain: Int32, type: Int32, proto: Int32) throws -> Int32 {
        let family = domain == InetABI.afInet ? HostNet.afInet : HostNet.afInet6
        let fd = HostSocketCalls.socket(family: family, type: type, proto: proto)
        guard fd >= 0 else { throw SocketErrno.last() }
        if domain == InetABI.afInet6 {
            // Darwin's default is a dual-stack socket (IPV6_V6ONLY off).
            #if canImport(Glibc)
            _ = HostSocketCalls.setInt(fd, level: InetABI.ipprotoIPv6, name: HostNet.ipv6V6Only, 0)
            #endif
        }
        return fd
    }

    func lastReferenceClosed() {
        lock.withLock {
            closed = true
            closeHostSocket()
            signals.fire()
        }
    }

    /// Closes the host socket (lock held, or the object is unreachable).
    func closeHostSocket() {
        let fd = hostFD
        guard fd >= 0 else { return }
        hostFD = -1
        if let t = pollToken { HostSocketPoller.shared.remove(fd: fd, token: t) }
        pollToken = nil
        InetSocketStats.add(-1)
        // A lingering close may block on the host: close it elsewhere.
        if let l = localOptions[OptionKey(level: InetABI.solSocket, name: InetABI.soLinger)] ?? lingerOption,
           l.readLE(Int32.self, at: 0) != 0, l.readLE(Int32.self, at: 4) > 0 {
            DispatchQueue.global().async { _ = close(fd) }
        } else {
            _ = close(fd)
        }
    }

    private var lingerOption: [UInt8]? {
        appliedOptions.last { $0.key.level == InetABI.solSocket
            && ($0.key.name == InetABI.soLinger || $0.key.name == InetABI.soLingerSec) }?.value
    }

    /// Replaces the host socket (restore).
    func replaceHost(_ fd: Int32) {
        guard hostFD < 0, fd >= 0 else { return }
        hostFD = fd
        pollToken = nil
        InetSocketStats.add(1)
    }

    func descriptorStat() -> DarwinStat {
        var mode = DarwinStat.S_IFSOCK
        if !shutRead { mode |= 0o444 }
        if !shutWrite { mode |= 0o222 }
        let n = hostFD >= 0 ? HostSocketCalls.bytesReadable(hostFD) : 0
        return DarwinStat(mode: mode, nlink: 0, ino: inode, uid: creator.uid, gid: creator.gid,
                          size: Int64(n), blksize: 131_072)
    }

    // MARK: Poller and waiting

    /// Called on the poller thread: the host socket's state changed.
    func hostDescriptorChanged() {
        lock.withLock {
            guard !closed else { return }
            signals.fire()
        }
    }

    /// Registers the host socket with the poller (once).
    func arm() {
        guard pollToken == nil, hostFD >= 0 else { return }
        pollToken = HostSocketPoller.shared.add(fd: hostFD, object: self)
    }

    /// Blocks until the socket's state may have changed, `deadline` passes
    /// (false), or the thread is interrupted (EINTR).
    func wait(_ kernel: DarwinKernel, deadline: UInt64?) throws -> Bool {
        arm()
        return try kernel.waitOnObject(signals, deadline: deadline)
    }

    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int {
        arm()
        return signals.addObserver(observer)
    }

    func removeReadinessObserver(_ token: Int) { signals.removeObserver(token) }

    // MARK: State

    /// A pending connect finished? Moves `.connecting` on (lock held).
    func refreshConnecting() {
        guard state == .connecting, hostFD >= 0 else { return }
        let r = HostSocketCalls.revents(hostFD)
        guard r & Int16(POLLOUT | POLLERR | POLLHUP) != 0 else { return }
        let e = HostSocketCalls.intOption(hostFD, level: HostNet.solSocket, name: Int32(SO_ERROR)) ?? 0
        if e == 0 {
            state = .connected
            bound = true
        } else {
            pendingError = SocketErrno.fromHost(e)
            state = .idle
        }
    }

    func takeError() throws {
        if pendingError != 0 {
            let e = pendingError
            pendingError = 0
            throw DarwinErrnoError(e)
        }
    }

    // MARK: Options

    /// Options whose value the kernel keeps for getsockopt even though the
    /// host applies them (their host form differs).
    func keepsLocally(level: Int32, name: Int32) -> Bool {
        switch (level, name) {
        case (InetABI.ipprotoIP, InetABI.ipRecvDstAddr), (InetABI.ipprotoIP, InetABI.ipPktInfo),
             (InetABI.ipprotoIP, InetABI.ipRecvIF), (InetABI.ipprotoIP, InetABI.ipBoundIF),
             (InetABI.ipprotoIPv6, InetABI.ipv6BoundIF), (InetABI.ipprotoIP, InetABI.ipMulticastIfIndex):
            return true
        default:
            return false
        }
    }

    /// Applies the host part of a guest option (`wants` and
    /// `boundInterface` already updated). False: the host has no such
    /// option (the kernel keeps it). Throws when the host refuses the value.
    func applyHostOption(level: Int32, name: Int32, value: [UInt8]) throws -> Bool {
        guard hostFD >= 0 else { return false }
        func setHost(_ l: Int32, _ n: Int32, _ v: [UInt8]) -> Bool {
            HostSocketCalls.setOption(hostFD, level: l, name: n, value: v) == 0
        }
        switch (level, name) {
        case (InetABI.ipprotoIP, InetABI.ipRecvDstAddr), (InetABI.ipprotoIP, InetABI.ipPktInfo),
             (InetABI.ipprotoIP, InetABI.ipRecvIF):
            #if canImport(Glibc)
            let any: Int32 = wants.dstAddr || wants.pktInfo || wants.recvIF ? 1 : 0
            _ = HostSocketCalls.setInt(hostFD, level: InetABI.ipprotoIP, name: HostNet.ipPktInfo, any)
            #else
            _ = setHost(level, name, value)
            #endif
            return true
        case (InetABI.ipprotoIP, InetABI.ipBoundIF), (InetABI.ipprotoIPv6, InetABI.ipv6BoundIF):
            #if canImport(Glibc)
            // SO_BINDTOIFINDEX. Without the privilege to change a binding it
            // fails; the option is kept (the host routes by its own table).
            _ = HostSocketCalls.setInt(hostFD, level: HostNet.solSocket, name: HostNet.soBindToIfIndex,
                                       Int32(bitPattern: NetworkInterfaces.hostIndex(boundInterface)))
            #endif
            return true
        case (InetABI.ipprotoIP, InetABI.ipMulticastIfIndex):
            guard value.count >= 4 else { throw DarwinErrnoError(DarwinErrnoCode.EINVAL) }
            #if canImport(Glibc)
            var mreqn = [UInt8](repeating: 0, count: 8)
            mreqn.appendLE(NetworkInterfaces.hostIndex(value.readLE(UInt32.self, at: 0)))
            guard setHost(InetABI.ipprotoIP, HostNet.ipMulticastIF, mreqn) else { throw SocketErrno.last() }
            #else
            guard setHost(level, name, value) else { throw SocketErrno.last() }
            #endif
            return true
        default:
            break
        }
        switch SocketOptions.route(level: level, name: name) {
        case .local:
            return false
        case let .host(hl, hn, kind):
            let v = try SocketOptions.hostValue(value, kind: kind, hostIndex: NetworkInterfaces.hostIndex)
            if setHost(hl, hn, v) { return true }
            let e = errno
            // An option the host lacks or refuses for this kind of socket
            // (ENOPROTOOPT, EOPNOTSUPP): kept by the kernel, as Darwin accepts it.
            if e == ENOPROTOOPT || e == EOPNOTSUPP { return false }
            throw DarwinErrnoError(SocketErrno.fromHost(e))
        }
    }

    // MARK: Readiness

    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        if isReset || closed || hostFD < 0 { return (true, 0, true) }
        if pendingError != 0 { return (true, 0, false) }
        switch state {
        case .listening:
            let r = HostSocketCalls.revents(hostFD)
            let ready = r & Int16(POLLIN) != 0
            return (ready, ready ? 1 : 0, false)
        case .connecting:
            refreshConnecting()
            if state == .connecting { return (false, 0, false) }
            if pendingError != 0 { return (true, 0, false) }
        case .idle where isStream:
            return (shutRead, 0, shutRead)
        default:
            break
        }
        let r = HostSocketCalls.revents(hostFD)
        let n = HostSocketCalls.bytesReadable(hostFD)
        let error = r & Int16(POLLERR) != 0
        if isStream {
            let eof = shutRead || r & (Int16(POLLHUP) | HostSocketCalls.rdHup) != 0 || (r & Int16(POLLIN) != 0 && n == 0)
            let lowat = Int(localOptions[OptionKey(level: InetABI.solSocket, name: InetABI.soRcvLowat)]?
                .readLE(Int32.self, at: 0) ?? 1)
            return (n >= max(1, lowat) || eof || error, Int64(n), eof)
        }
        return (r & Int16(POLLIN) != 0 || error || shutRead, Int64(n), shutRead)
    }

    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        if isReset || closed || hostFD < 0 || shutWrite { return (true, 0, true) }
        if pendingError != 0 { return (true, 0, false) }
        switch state {
        case .listening: return (false, 0, false)
        case .connecting:
            refreshConnecting()
            if state == .connecting { return (false, 0, false) }
            if pendingError != 0 { return (true, 0, false) }
        case .idle where isStream:
            return (false, 0, false)
        default:
            break
        }
        let r = HostSocketCalls.revents(hostFD)
        let hup = r & Int16(POLLHUP) != 0
        let space = max(0, Int(sendBufferSize) - HostSocketCalls.bytesUnsent(hostFD))
        return (r & Int16(POLLOUT) != 0 || hup || r & Int16(POLLERR) != 0, Int64(space), hup)
    }

    /// SO_SNDBUF as the guest sees it.
    var sendBufferSize: Int32 {
        if let r = requestedSendBuffer { return r }
        let v = hostFD >= 0 ? HostSocketCalls.intOption(hostFD, level: HostNet.solSocket, name: Int32(SO_SNDBUF)) ?? 0 : 0
        return HostNet.isLinux ? v / 2 : v
    }

    var receiveBufferSize: Int32 {
        if let r = requestedReceiveBuffer { return r }
        let v = hostFD >= 0 ? HostSocketCalls.intOption(hostFD, level: HostNet.solSocket, name: Int32(SO_RCVBUF)) ?? 0 : 0
        return HostNet.isLinux ? v / 2 : v
    }
}

/// Counts of open host sockets (diagnostics, tests).
enum InetSocketStats {
    private static let mutex = NSLock()
    nonisolated(unsafe) private static var openCount = 0
    nonisolated(unsafe) private(set) static var created = 0

    static func add(_ n: Int) {
        mutex.lock()
        openCount += n
        if n > 0 { created += n }
        mutex.unlock()
    }

    static var open: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return openCount
    }
}
