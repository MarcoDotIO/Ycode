import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The readiness pump of host-backed sockets (`specs/simulator/networking-ycode.md`
// §2.4). Every host socket is non-blocking. A guest thread that must block
// on one waits on the socket's `ObjectSignals` with the kernel lock
// released, exactly as on a pipe; kevent and select register readiness
// observers. Neither busy-waits: one host thread waits in `epoll_wait`
// (Linux) or `kevent` (a Darwin host) on every socket that has a waiter or an
// observer ("interest"), edge-triggered, and on an event takes the socket's
// kernel lock and fires its signals, which wakes the waiters and re-checks
// the knotes. A socket without interest is not registered, so traffic
// nobody waits for costs nothing.
//
// Lock order: the poller's own mutex is a leaf. It is taken with or without
// the kernel lock, and never held while the poller thread takes a kernel lock.

/// What the poller calls when a host descriptor's state changed.
protocol HostPolledObject: AnyObject {
    /// Called on the poller thread, with no lock held.
    func hostDescriptorChanged()
}

#if canImport(Darwin)
typealias HostKEvent = Darwin.kevent
#else
/// epoll, reached through the C library's symbols (the Glibc module does not
/// import `sys/epoll.h`). `struct epoll_event` is packed (12 bytes) on
/// x86-64 and naturally aligned (16 bytes) elsewhere.
enum EPoll {
    typealias CreateFunction = @convention(c) (Int32) -> Int32
    typealias ControlFunction = @convention(c) (Int32, Int32, Int32, UnsafeMutableRawPointer?) -> Int32
    typealias WaitFunction = @convention(c) (Int32, UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    nonisolated(unsafe) private static let library = dlopen(nil, RTLD_NOW)
    static let create = unsafeBitCast(dlsym(library, "epoll_create1"), to: CreateFunction.self)
    static let control = unsafeBitCast(dlsym(library, "epoll_ctl"), to: ControlFunction.self)
    static let wait = unsafeBitCast(dlsym(library, "epoll_wait"), to: WaitFunction.self)
    #if arch(x86_64)
    static let eventSize = 12, dataOffset = 4
    #else
    static let eventSize = 16, dataOffset = 8
    #endif
    static let inEvent: UInt32 = 0x001, outEvent: UInt32 = 0x004, rdHup: UInt32 = 0x2000, edgeTriggered: UInt32 = 1 << 31
    static let closeOnExec: Int32 = 0o2000000
    static let add: Int32 = 1, delete: Int32 = 2

    static func event(_ events: UInt32, _ data: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: eventSize)
        b.putLE(events, at: 0)
        b.putLE(data, at: dataOffset)
        return b
    }
}
#endif

final class HostSocketPoller: @unchecked Sendable {
    static let shared = HostSocketPoller()

    private let mutex = NSLock()
    private var objects: [UInt64: WeakPolled] = [:]
    private var nextToken: UInt64 = 1
    private var started = false
    private var pollFD: Int32 = -1
    /// Statistics: events delivered.
    private(set) var events: UInt64 = 0

    private struct WeakPolled {
        weak var object: HostPolledObject?
    }

    private init() {}

    private func startIfNeeded() {
        // mutex held
        guard !started else { return }
        started = true
        #if canImport(Glibc)
        pollFD = EPoll.create(EPoll.closeOnExec)
        #else
        pollFD = kqueue()
        #endif
        guard pollFD >= 0 else {
            FileHandle.standardError.write(Data("ycode-simd: host socket poller: cannot create (errno \(errno))\n".utf8))
            return
        }
        let t = Thread { [self] in run() }
        t.name = "ycode-host-sockets"
        t.start()
    }

    /// Registers `fd` for edge-triggered read/write/hang-up events. Returns
    /// the token for `remove`.
    func add(fd: Int32, object: HostPolledObject) -> UInt64 {
        mutex.lock()
        defer { mutex.unlock() }
        startIfNeeded()
        let token = nextToken
        nextToken += 1
        objects[token] = WeakPolled(object: object)
        guard pollFD >= 0 else { return token }
        #if canImport(Glibc)
        var ev = EPoll.event(EPoll.inEvent | EPoll.outEvent | EPoll.rdHup | EPoll.edgeTriggered, token)
        _ = ev.withUnsafeMutableBytes { EPoll.control(pollFD, EPoll.add, fd, $0.baseAddress) }
        #else
        var changes: [HostKEvent] = [
            HostKEvent(ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0,
                   udata: UnsafeMutableRawPointer(bitPattern: UInt(token))),
            HostKEvent(ident: UInt(fd), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_ADD | EV_CLEAR), fflags: 0, data: 0,
                   udata: UnsafeMutableRawPointer(bitPattern: UInt(token))),
        ]
        _ = kevent(pollFD, &changes, 2, nil, 0, nil)
        #endif
        return token
    }

    /// Unregisters `fd` (before it is closed).
    func remove(fd: Int32, token: UInt64) {
        mutex.lock()
        defer { mutex.unlock() }
        objects[token] = nil
        guard pollFD >= 0 else { return }
        #if canImport(Glibc)
        var ev = EPoll.event(0, 0)
        _ = ev.withUnsafeMutableBytes { EPoll.control(pollFD, EPoll.delete, fd, $0.baseAddress) }
        #else
        var changes: [HostKEvent] = [
            HostKEvent(ident: UInt(fd), filter: Int16(EVFILT_READ), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil),
            HostKEvent(ident: UInt(fd), filter: Int16(EVFILT_WRITE), flags: UInt16(EV_DELETE), fflags: 0, data: 0, udata: nil),
        ]
        _ = kevent(pollFD, &changes, 2, nil, 0, nil)
        #endif
    }

    private func run() {
        let capacity = 64
        #if canImport(Glibc)
        var buffer = [UInt8](repeating: 0, count: capacity * EPoll.eventSize)
        #else
        var buffer = [HostKEvent](repeating: HostKEvent(), count: capacity)
        #endif
        while true {
            #if canImport(Glibc)
            let n = buffer.withUnsafeMutableBytes { EPoll.wait(pollFD, $0.baseAddress, Int32(capacity), -1) }
            #else
            let n = kevent(pollFD, nil, 0, &buffer, Int32(capacity), nil)
            #endif
            if n < 0 {
                if errno == EINTR { continue }
                FileHandle.standardError.write(Data("ycode-simd: host socket poller stopped (errno \(errno))\n".utf8))
                return
            }
            var tokens = Set<UInt64>()
            for i in 0..<Int(n) {
                #if canImport(Glibc)
                tokens.insert(buffer.readLE(UInt64.self, at: i * EPoll.eventSize + EPoll.dataOffset))
                #else
                tokens.insert(UInt64(UInt(bitPattern: buffer[i].udata)))
                #endif
            }
            mutex.lock()
            let targets = tokens.compactMap { objects[$0]?.object }
            events &+= UInt64(targets.count)
            mutex.unlock()
            for o in targets { o.hostDescriptorChanged() }
        }
    }
}

/// Host socket helpers (the host calls are made through these so that the
/// rest of the socket layer stays platform-neutral).
enum HostSocketCalls {
    #if canImport(Glibc)
    static let sockNonBlock = Int32(SOCK_NONBLOCK.rawValue), sockCloexec = Int32(SOCK_CLOEXEC.rawValue)
    #endif

    /// A new non-blocking, close-on-exec host socket.
    static func socket(family: Int32, type: Int32, proto: Int32) -> Int32 {
        #if canImport(Glibc)
        return Glibc.socket(family, type | sockNonBlock | sockCloexec, proto)
        #else
        let fd = Darwin.socket(family, type, proto)
        if fd >= 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var one: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        }
        return fd
        #endif
    }

    /// `poll` with a zero timeout: the host's revents.
    static func revents(_ fd: Int32) -> Int16 {
        var p = pollfd(fd: fd, events: Int16(POLLIN | POLLOUT) | rdHup, revents: 0)
        return Glibc_or_Darwin_poll(&p) > 0 ? p.revents : 0
    }

    #if canImport(Glibc)
    /// POLLRDHUP (Linux; a GNU extension the module does not import).
    static let rdHup: Int16 = 0x2000
    #else
    static let rdHup: Int16 = 0
    #endif

    @inline(__always)
    private static func Glibc_or_Darwin_poll(_ p: UnsafeMutablePointer<pollfd>) -> Int32 {
        poll(p, 1, 0)
    }

    /// Bytes queued for reading (FIONREAD).
    static func bytesReadable(_ fd: Int32) -> Int {
        var n: Int32 = 0
        return ioctl(fd, HostNet.fionread, &n) == 0 ? Int(n) : 0
    }

    /// Bytes not yet sent (SIOCOUTQ); 0 where unknown.
    static func bytesUnsent(_ fd: Int32) -> Int {
        #if canImport(Glibc)
        var n: Int32 = 0
        return ioctl(fd, HostNet.siocOutQ, &n) == 0 ? Int(n) : 0
        #else
        var n: Int32 = 0
        var len = socklen_t(4)
        return getsockopt(fd, SOL_SOCKET, SO_NWRITE, &n, &len) == 0 ? Int(n) : 0
        #endif
    }

    /// SIOCATMARK: 1 when the read pointer is at the urgent mark.
    static func atMark(_ fd: Int32) -> Int32 {
        var mark: Int32 = 0
        #if canImport(Glibc)
        _ = ioctl(fd, UInt(0x8905), &mark)
        #else
        _ = ioctl(fd, UInt(0x4004_7307), &mark)
        #endif
        return mark
    }

    static func setOption(_ fd: Int32, level: Int32, name: Int32, value: [UInt8]) -> Int32 {
        value.withUnsafeBytes { setsockopt(fd, level, name, $0.baseAddress, socklen_t($0.count)) }
    }

    static func setInt(_ fd: Int32, level: Int32, name: Int32, _ v: Int32) -> Int32 {
        var v = v
        return setsockopt(fd, level, name, &v, 4)
    }

    /// getsockopt into a buffer of `size` bytes; nil on failure (errno set).
    static func option(_ fd: Int32, level: Int32, name: Int32, size: Int) -> [UInt8]? {
        var b = [UInt8](repeating: 0, count: max(size, 4))
        var len = socklen_t(b.count)
        let r = b.withUnsafeMutableBytes { getsockopt(fd, level, name, $0.baseAddress, &len) }
        guard r == 0 else { return nil }
        return Array(b.prefix(Int(len)))
    }

    static func intOption(_ fd: Int32, level: Int32, name: Int32) -> Int32? {
        option(fd, level: level, name: name, size: 4).map { $0.readLE(Int32.self, at: 0) }
    }

    /// A host address call (bind, connect) with `addr` as the sockaddr.
    static func withAddress(_ addr: [UInt8], _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var storage = sockaddr_storage()
        return withUnsafeMutableBytes(of: &storage) { raw in
            let n = min(addr.count, raw.count)
            for i in 0..<n { raw[i] = addr[i] }
            return body(raw.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(n))
        }
    }

    /// getsockname / getpeername: the host sockaddr bytes.
    static func name(_ fd: Int32, peer: Bool) -> [UInt8]? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let r = withUnsafeMutableBytes(of: &storage) { raw -> Int32 in
            let p = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            return peer ? getpeername(fd, p, &len) : getsockname(fd, p, &len)
        }
        guard r == 0 else { return nil }
        return withUnsafeBytes(of: &storage) { Array($0.prefix(Int(len))) }
    }

    /// accept: the new non-blocking descriptor and the peer address.
    static func accept(_ fd: Int32) -> (fd: Int32, address: [UInt8])? {
        var storage = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutableBytes(of: &storage) { raw -> Int32 in
            let p = raw.baseAddress!.assumingMemoryBound(to: sockaddr.self)
            let c = hostAccept(fd, p, &len)
            if c >= 0 {
                _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
                _ = fcntl(c, F_SETFD, FD_CLOEXEC)
                #if canImport(Darwin)
                var one: Int32 = 1
                _ = setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
                #endif
            }
            return c
        }
        guard n >= 0 else { return nil }
        return (n, withUnsafeBytes(of: &storage) { Array($0.prefix(Int(len))) })
    }

    /// sendmsg with one buffer, an optional address and control data.
    /// Returns the byte count or -1 (errno set).
    static func send(_ fd: Int32, _ bytes: ArraySlice<UInt8>, to address: [UInt8]?, control: [UInt8], flags: Int32) -> Int {
        var storage = sockaddr_storage()
        let nameLength = address.map { min($0.count, MemoryLayout<sockaddr_storage>.size) } ?? 0
        if let address {
            withUnsafeMutableBytes(of: &storage) { raw in for i in 0..<nameLength { raw[i] = address[i] } }
        }
        var control = control
        return bytes.withUnsafeBytes { data -> Int in
            control.withUnsafeMutableBytes { ctl -> Int in
                withUnsafeMutableBytes(of: &storage) { name -> Int in
                    var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: data.baseAddress ?? UnsafeRawPointer(bitPattern: 1)!),
                                    iov_len: data.count)
                    return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                        var m = msghdr()
                        m.msg_name = address == nil ? nil : name.baseAddress
                        m.msg_namelen = socklen_t(nameLength)
                        m.msg_iov = iovp
                        m.msg_iovlen = 1
                        m.msg_control = ctl.isEmpty ? nil : ctl.baseAddress
                        #if canImport(Glibc)
                        m.msg_controllen = ctl.count
                        #else
                        m.msg_controllen = socklen_t(ctl.count)
                        #endif
                        return sendmsg(fd, &m, flags)
                    }
                }
            }
        }
    }

    /// recvmsg into a buffer of `max` bytes. Returns nil on failure (errno
    /// set); otherwise the bytes (truncated to the buffer), the full length
    /// the call returned, the address, the control data and the host flags.
    static func receive(_ fd: Int32, max: Int, controlRoom: Int, flags: Int32)
        -> (bytes: [UInt8], returned: Int, address: [UInt8], control: [UInt8], flags: Int32)? {
        var buffer = [UInt8](repeating: 0, count: Swift.max(max, 1))
        var control = [UInt8](repeating: 0, count: controlRoom)
        var storage = sockaddr_storage()
        var nameLength = 0, controlLength = 0
        var outFlags: Int32 = 0
        let n = buffer.withUnsafeMutableBytes { data -> Int in
            control.withUnsafeMutableBytes { ctl -> Int in
                withUnsafeMutableBytes(of: &storage) { name -> Int in
                    var iov = iovec(iov_base: data.baseAddress, iov_len: max)
                    return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
                        var m = msghdr()
                        m.msg_name = name.baseAddress
                        m.msg_namelen = socklen_t(name.count)
                        m.msg_iov = iovp
                        m.msg_iovlen = 1
                        m.msg_control = ctl.isEmpty ? nil : ctl.baseAddress
                        #if canImport(Glibc)
                        m.msg_controllen = ctl.count
                        #else
                        m.msg_controllen = socklen_t(ctl.count)
                        #endif
                        let r = recvmsg(fd, &m, flags)
                        nameLength = Int(m.msg_namelen)
                        controlLength = Int(m.msg_controllen)
                        outFlags = m.msg_flags
                        return r
                    }
                }
            }
        }
        guard n >= 0 else { return nil }
        let address = withUnsafeBytes(of: &storage) { Array($0.prefix(Swift.min(nameLength, $0.count))) }
        return (Array(buffer.prefix(Swift.min(n, max))), n, address, Array(control.prefix(controlLength)), outFlags)
    }
}

private func hostAccept(_ fd: Int32, _ p: UnsafeMutablePointer<sockaddr>, _ len: UnsafeMutablePointer<socklen_t>) -> Int32 {
    accept(fd, p, len)
}
