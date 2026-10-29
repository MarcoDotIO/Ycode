import Foundation
import YcodeDarwinABI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

// The socket system calls on AF_INET / AF_INET6 sockets
// (`specs/simulator/networking-ycode.md` §2). `socketCall` sends a call
// here when its descriptor is an `InetSocket` (or, for `socket`, when the
// domain is an IP one). Blocking calls wait on the socket's signals with
// the kernel lock released; the host socket itself never blocks.

extension DarwinKernel {
    /// The IP socket behind `fd`, or nil when it is another kind of object.
    func inetSocket(_ fd: Int32) -> (InetSocket, DarwinOpenFile)? {
        guard let file = try? fileSystem.openFile(for: fd), let s = file.object as? InetSocket else { return nil }
        return (s, file)
    }

    /// `socket(AF_INET/AF_INET6, type, protocol)`.
    func makeInetSocket(domain: Int32, type: Int32, proto: Int32) throws -> InetSocket {
        switch type {
        case InetABI.sockStream:
            guard proto == 0 || proto == InetABI.ipprotoTCP else { throw fail(Code.EPROTONOSUPPORT) }
        case InetABI.sockDgram:
            guard proto == 0 || proto == InetABI.ipprotoUDP || proto == InetABI.ipprotoICMP || proto == InetABI.ipprotoICMPv6
            else { throw fail(Code.EPROTONOSUPPORT) }
        case InetABI.sockRaw:
            break  // the host decides (unprivileged: EPERM/EACCES)
        default:
            throw fail(Code.EPROTOTYPE)
        }
        if InetSocketPolicy.disabled { throw fail(Code.EAFNOSUPPORT) }
        let fd = try InetSocket.makeHost(domain: domain, type: type, proto: proto)
        return InetSocket(domain: domain, type: type, proto: proto, hostFD: fd, lock: lock, creator: descriptorUser)
    }

    /// Reads a guest sockaddr for an IP socket (length 2…255).
    func readInetAddress(_ va: UInt64, length: UInt64, for s: InetSocket, _ mem: any KernelGuestMemory) throws -> InetAddress? {
        guard length >= 2, length <= UInt64(SocketABI.maxAddressLength) else { throw fail(Code.EINVAL) }
        var raw = try mem.read(va: va, count: Int(length))
        // An AF_UNSPEC address: a datagram disconnect (connect), or the
        // socket's own family (old binaries that leave sa_family 0).
        if raw[1] == 0 {
            if s.domain == InetABI.afInet, raw.count >= 16 { raw[1] = UInt8(InetABI.afInet) } else { return nil }
        }
        return try InetAddress.fromDarwin(raw, domain: s.domain)
    }

    func hostAddress(_ a: InetAddress) -> [UInt8] {
        a.hostBytes(hostScope: NetworkInterfaces.hostIndex(a.scope))
    }

    func guestAddress(fromHost b: [UInt8]) -> InetAddress? {
        InetAddress.fromHost(b, guestScope: NetworkInterfaces.guestIndex)
    }

    // MARK: Calls

    func inetSocketCall(_ n: Int, _ a: [UInt64], _ s: InetSocket, _ file: DarwinOpenFile, _ call: inout CallText,
                        _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        s.lastUser = descriptorUser
        switch n {
        case DescriptorBSD.bind:
            let address = try readInetAddress(a[1], length: UInt64(UInt32(truncatingIfNeeded: a[2])), for: s, mem)
            guard let address else { throw fail(Code.EAFNOSUPPORT) }
            call += " [\(address)]"
            try inetBind(s, address)
            return .value(0)

        case DescriptorBSD.listen:
            guard s.isStream else { throw fail(Code.EOPNOTSUPP) }
            guard s.hostFD >= 0, !s.isReset else { throw fail(Code.EINVAL) }
            let backlog = int(1) <= 0 || int(1) > Int32(SocketABI.maxBacklog) ? Int32(SocketABI.maxBacklog) : int(1)
            guard hostListen(s.hostFD, backlog) == 0 else { throw SocketErrno.last() }
            s.state = .listening
            s.bound = true
            s.backlog = backlog
            s.signals.fire()
            return .value(0)

        case DescriptorBSD.accept:
            return try inetAccept(s, file, a, &call, mem)

        case DescriptorBSD.connect:
            let address = try readInetAddress(a[1], length: UInt64(UInt32(truncatingIfNeeded: a[2])), for: s, mem)
            call += " [\(address.map { "\($0)" } ?? "AF_UNSPEC")]"
            try inetConnect(s, file, to: address)
            return .value(0)

        case DescriptorBSD.shutdown:
            let how = int(1)
            guard (0...2).contains(how) else { throw fail(Code.EINVAL) }
            if s.isReset { throw fail(Code.ENOTCONN) }
            if s.isStream, s.state != .connected { throw fail(Code.ENOTCONN) }
            if !s.isStream, !s.datagramConnected { throw fail(Code.ENOTCONN) }
            if hostShutdown(s.hostFD, how) != 0 { throw SocketErrno.last() }
            if how != 1 { s.shutRead = true }
            if how != 0 { s.shutWrite = true }
            s.signals.fire()
            return .value(0)

        case DescriptorBSD.getsockname, DescriptorBSD.getpeername:
            let peer = n == DescriptorBSD.getpeername
            if s.isReset {
                if peer { throw fail(Code.ENOTCONN) }
                try copyOutAddress((s.boundAddress ?? InetAddress.unspecified(s.domain)).darwinBytes, to: a[1], lengthPointer: a[2], mem)
                return .value(0)
            }
            if peer, s.isStream, s.state != .connected { throw fail(Code.ENOTCONN) }
            guard let raw = HostSocketCalls.name(s.hostFD, peer: peer) else { throw SocketErrno.last() }
            let address = guestAddress(fromHost: raw) ?? InetAddress.unspecified(s.domain)
            call += " [\(address)]"
            try copyOutAddress(address.darwinBytes, to: a[1], lengthPointer: a[2], mem)
            return .value(0)

        case DescriptorBSD.sendto:
            guard file.isWritable else { throw fail(Code.EBADF) }
            guard a[2] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
            var to: InetAddress?
            if a[4] != 0 {
                to = try readInetAddress(a[4], length: UInt64(UInt32(truncatingIfNeeded: a[5])), for: s, mem)
                if let to { call += " [\(to)]" }
            }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return .value(UInt64(try inetSend(s, file, bytes, to: to, control: [], flags: int(3))))

        case DescriptorBSD.recvfrom:
            guard file.isReadable else { throw fail(Code.EBADF) }
            guard a[2] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
            let r = try inetReceive(s, file, max: Int(a[2]), flags: int(3), controlRoom: 0)
            if !r.bytes.isEmpty { try mem.write(va: a[1], bytes: r.bytes) }
            if a[4] != 0 { try copyOutAddress(r.from?.darwinBytes, to: a[4], lengthPointer: a[5], mem) }
            return .value(UInt64(r.bytes.count))

        case DescriptorBSD.sendmsg:
            guard file.isWritable else { throw fail(Code.EBADF) }
            let h = try mem.read(va: a[1], count: 48)
            let m = try readMessage(h, for: s, mem)
            if let to = m.to { call += " [\(to)]" }
            let bytes = try gather(m.iov, mem)
            return .value(UInt64(try inetSend(s, file, bytes, to: m.to, control: m.control, flags: int(2))))

        case DescriptorBSD.recvmsg:
            guard file.isReadable else { throw fail(Code.EBADF) }
            let h = try mem.read(va: a[1], count: 48)
            let count = try receiveMessage(s, file, header: h, at: a[1], flags: int(2), datalenField: nil, mem)
            return .value(UInt64(count))

        case DescriptorBSD.setsockopt:
            let size = Int(UInt32(truncatingIfNeeded: a[4]))
            let value = a[3] == 0 || size == 0 ? [] : try mem.read(va: a[3], count: min(size, 1024))
            try setInetOption(s, level: int(1), name: int(2), value: value)
            return .value(0)

        case DescriptorBSD.getsockopt:
            guard a[4] != 0 else { throw fail(Code.EFAULT) }
            let room = Int(try mem.read(va: a[4], count: 4).readLE(UInt32.self, at: 0))
            let value = try inetOption(s, level: int(1), name: int(2), room: room)
            let n = min(room, value.count)
            if a[3] != 0, n > 0 { try mem.write(va: a[3], bytes: Array(value.prefix(n))) }
            try writeU32(a[4], UInt32(n), mem)
            return .value(0)

        default:
            throw fail(Code.ENOSYS)
        }
    }

    func inetBind(_ s: InetSocket, _ address: InetAddress) throws {
        guard s.hostFD >= 0, !s.isReset else { throw fail(Code.EINVAL) }
        let r = HostSocketCalls.withAddress(hostAddress(address)) { hostBind(s.hostFD, $0, $1) }
        guard r == 0 else { throw SocketErrno.last() }
        s.bound = true
        // The bound address with the port the host chose (for a restore).
        if let raw = HostSocketCalls.name(s.hostFD, peer: false), let actual = guestAddress(fromHost: raw) {
            s.boundAddress = actual
        } else {
            s.boundAddress = address
        }
    }

    private func inetAccept(_ s: InetSocket, _ file: DarwinOpenFile, _ a: [UInt64], _ call: inout CallText,
                            _ mem: any KernelGuestMemory) throws -> BSDResult {
        guard s.state == .listening, !s.isReset else { throw fail(Code.EINVAL) }
        let deadline = s.receiveTimeout.map { KernelClock.deadline(afterNanoseconds: $0) }
        while true {
            guard fileSystem.freeDescriptorCount >= 1 else { throw fail(Code.EMFILE) }
            if let (fd, raw) = HostSocketCalls.accept(s.hostFD) {
                let c = InetSocket(domain: s.domain, type: s.type, proto: s.proto, hostFD: fd, lock: lock,
                                   creator: s.creator)
                c.state = .connected
                c.bound = true
                c.noSigPipe = s.noSigPipe
                // The new descriptor inherits the listener's O_NONBLOCK (xnu accept).
                let flags = DarwinOpen.O_RDWR | (file.statusFlags & DarwinOpen.O_NONBLOCK)
                let newFD = try fileSystem.installObject(c, statusFlags: flags, closeOnExec: false)
                let peer = guestAddress(fromHost: raw)
                if a[1] != 0 { try copyOutAddress(peer?.darwinBytes, to: a[1], lengthPointer: a[2], mem) }
                call += " [fd \(newFD) from \(peer.map { "\($0)" } ?? "?")]"
                s.signals.fire()
                return .value(UInt64(newFD))
            }
            let e = hostErrnoValue
            if e == hostEINTR { continue }
            // A connection that went away before accept: try again (xnu).
            if e == hostECONNABORTED { continue }
            guard e == hostEAGAIN || e == hostEWOULDBLOCK else { throw DarwinErrnoError(SocketErrno.fromHost(e)) }
            if file.isNonBlocking { throw fail(Code.EAGAIN) }
            if try !s.wait(self, deadline: deadline) { throw fail(Code.EAGAIN) }
            guard s.state == .listening, !s.closed else { throw fail(Code.ECONNABORTED) }
        }
    }

    /// connect (and connectx): a datagram socket sets or clears its default
    /// destination; a stream socket starts a host connect and, if the
    /// descriptor blocks, waits for it.
    func inetConnect(_ s: InetSocket, _ file: DarwinOpenFile, to address: InetAddress?, wait: Bool = true) throws {
        guard s.hostFD >= 0 else { throw fail(Code.EINVAL) }
        if s.isReset {
            try s.takeError()
            throw fail(s.isStream ? Code.EISCONN : Code.EINVAL)
        }
        guard let address else {
            // AF_UNSPEC: a datagram socket forgets its destination.
            guard !s.isStream else { throw fail(Code.EAFNOSUPPORT) }
            var unspec = [UInt8](repeating: 0, count: 16)
            #if canImport(Darwin)
            unspec[0] = 16
            #endif
            _ = HostSocketCalls.withAddress(unspec) { hostConnect(s.hostFD, $0, $1) }
            s.datagramConnected = false
            return
        }
        if s.isStream {
            switch s.state {
            case .listening: throw fail(Code.EOPNOTSUPP)
            case .connected: throw fail(Code.EISCONN)
            case .connecting:
                s.refreshConnecting()
                if s.state == .connecting { throw fail(SocketErrno.EALREADY) }
                if s.state == .connected { throw fail(Code.EISCONN) }
            case .idle: break
            }
        }
        let r = HostSocketCalls.withAddress(hostAddress(address)) { hostConnect(s.hostFD, $0, $1) }
        if r == 0 {
            if s.isStream { s.state = .connected } else { s.datagramConnected = true }
            s.bound = true
            s.signals.fire()
            return
        }
        let e = hostErrnoValue
        guard s.isStream, e == hostEINPROGRESS || e == hostEINTR else { throw DarwinErrnoError(SocketErrno.fromHost(e)) }
        s.state = .connecting
        s.bound = true
        if file.isNonBlocking || !wait { throw fail(SocketErrno.EINPROGRESS) }
        while true {
            s.refreshConnecting()
            if s.state != .connecting { break }
            _ = try s.wait(self, deadline: nil)
        }
        try s.takeError()
    }

    // MARK: connectx, disconnectx, socket_delegate, recvmsg_x, sendmsg_x

    /// The Darwin-only socket calls (xnu `uipc_syscalls.c`; layouts from the
    /// public `sys/socket.h`): `connectx` (447), `disconnectx` (448),
    /// `socket_delegate` (450), `recvmsg_x` (480), `sendmsg_x` (481).
    func extendedSocketCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case DescriptorBSD.socketDelegate:
            call.set("socket_delegate(domain=\(int(0)), type=\(int(1)), protocol=\(int(2)), epid=\(int(3)))")
            var inner = CallText(call.enabled)
            return try socketCall(DescriptorBSD.socket, [a[0], a[1], a[2], 0, 0, 0], &inner, mem)

        case DescriptorBSD.connectx:
            call.set("connectx(s=\(int(0)), endpoints=\(hx(a[1])), associd=\(hx(a[2])), flags=\(hx(a[3])), iov=\(hx(a[4])), "
                + "iovcnt=\(int(5)), len=\(hx(a[6])), connid=\(hx(a[7])))")
            guard let (s, file) = inetSocket(int(0)) else {
                _ = try fileSystem.openFile(for: int(0))
                throw fail(Code.EOPNOTSUPP)
            }
            // sa_endpoints_t: srcif u32 @0, srcaddr @8, srcaddrlen u32 @16, dstaddr @24, dstaddrlen u32 @32.
            let e = try mem.read(va: a[1], count: 40)
            let srcIF = e.readLE(UInt32.self, at: 0)
            let src = e.readLE(UInt64.self, at: 8), srcLength = e.readLE(UInt32.self, at: 16)
            let dst = e.readLE(UInt64.self, at: 24), dstLength = e.readLE(UInt32.self, at: 32)
            guard dst != 0 else { throw fail(Code.EINVAL) }
            if srcIF != 0 {
                var v: [UInt8] = []
                v.appendLE(srcIF)
                try setInetOption(s, level: s.domain == InetABI.afInet ? InetABI.ipprotoIP : InetABI.ipprotoIPv6,
                                  name: s.domain == InetABI.afInet ? InetABI.ipBoundIF : InetABI.ipv6BoundIF, value: v)
            }
            if src != 0, srcLength != 0, let from = try readInetAddress(src, length: UInt64(srcLength), for: s, mem) {
                try inetBind(s, from)
            }
            guard let to = try readInetAddress(dst, length: UInt64(dstLength), for: s, mem) else { throw fail(Code.EINVAL) }
            call += " [\(to)]"
            let flags = UInt32(truncatingIfNeeded: a[3])
            let resumeOnReadWrite = flags & 0x1 != 0  // CONNECT_RESUME_ON_READ_WRITE
            var sent = 0
            do {
                // With CONNECT_RESUME_ON_READ_WRITE, xnu completes the call at
                // once and connects on the first read or write; Ycode starts
                // the host connect now and reports success.
                try inetConnect(s, file, to: to, wait: !resumeOnReadWrite)
            } catch let e as DarwinErrnoError where e.errno == SocketErrno.EINPROGRESS && resumeOnReadWrite {
            }
            if a[4] != 0, int(5) > 0 {
                let data = try gather(try readIOVec(a[4], count: int(5), mem, limitError: Code.EINVAL), mem)
                if !data.isEmpty {
                    s.refreshConnecting()
                    if s.state == .connected {
                        sent = (try? inetSend(s, file, data, to: nil, control: [], flags: InetABI.msgDontWait)) ?? 0
                    }
                }
            }
            if a[6] != 0 { try writeU64(a[6], UInt64(sent), mem) }
            if a[7] != 0 { try writeU32(a[7], 1, mem) }  // SAE_CONNID: one connection
            return .value(0)

        case DescriptorBSD.disconnectx:
            call.set("disconnectx(s=\(int(0)), associd=\(hx(a[1])), connid=\(hx(a[2])))")
            guard let (s, _) = inetSocket(int(0)) else {
                _ = try fileSystem.openFile(for: int(0))
                throw fail(Code.EOPNOTSUPP)
            }
            guard s.isStream, s.state == .connected || s.state == .connecting, s.hostFD >= 0 else { throw fail(Code.ENOTCONN) }
            _ = hostShutdown(s.hostFD, 2)
            s.shutRead = true
            s.shutWrite = true
            s.signals.fire()
            return .value(0)

        case DescriptorBSD.recvmsgX, DescriptorBSD.sendmsgX:
            let isSend = n == DescriptorBSD.sendmsgX
            call.set("\(isSend ? "sendmsg_x" : "recvmsg_x")(s=\(int(0)), msgp=\(hx(a[1])), cnt=\(int(2)), flags=\(hx(a[3])))")
            guard let (s, file) = inetSocket(int(0)) else {
                _ = try fileSystem.openFile(for: int(0))
                throw fail(Code.EOPNOTSUPP)
            }
            let count = Int(UInt32(truncatingIfNeeded: a[2]))
            guard count > 0, count <= 1024 else { throw fail(Code.EINVAL) }
            // struct msghdr_x: a msghdr (48 bytes) + size_t msg_datalen.
            var done = 0
            for i in 0..<count {
                let va = a[1] + UInt64(56 * i)
                let h = try mem.read(va: va, count: 56)
                do {
                    if isSend {
                        let m = try readMessage(h, for: s, mem)
                        let bytes = try gather(m.iov, mem)
                        let flags = int(3) | (done > 0 ? InetABI.msgDontWait : 0)
                        let sent = try inetSend(s, file, bytes, to: m.to, control: m.control, flags: flags)
                        try writeU64(va + 48, UInt64(sent), mem)
                    } else {
                        // After the first message, take only what is queued.
                        let flags = int(3) | (done > 0 ? InetABI.msgDontWait : 0)
                        _ = try receiveMessage(s, file, header: h, at: va, flags: flags, datalenField: va + 48, mem)
                    }
                    done += 1
                } catch let e as DarwinErrnoError where done > 0 && (e.errno == Code.EAGAIN || e.errno == Code.EINTR) {
                    break
                }
                if !isSend && !s.isStream && s.hostFD >= 0 && HostSocketCalls.revents(s.hostFD) & Int16(POLLIN) == 0 { break }
            }
            call += " [\(done)]"
            return .value(UInt64(done))

        default:
            throw fail(Code.ENOSYS)
        }
    }

    // MARK: Data

    /// Sends on an IP socket (write, send, sendto, sendmsg, sendmsg_x).
    func inetSend(_ s: InetSocket, _ file: DarwinOpenFile, _ bytes: [UInt8], to address: InetAddress?,
                  control: [ControlMessage], flags: Int32) throws -> Int {
        s.lastUser = descriptorUser
        do {
            return try inetSendBody(s, file, bytes, to: address, control: control, flags: flags)
        } catch let e as DarwinErrnoError where e.errno == Code.EPIPE {
            if !s.noSigPipe && !file.noSigPipe && flags & InetABI.msgNoSignal == 0 {
                postSignal(descriptorSIGPIPE, thread: current)
            }
            throw e
        }
    }

    private func inetSendBody(_ s: InetSocket, _ file: DarwinOpenFile, _ bytes: [UInt8], to address: InetAddress?,
                              control: [ControlMessage], flags: Int32) throws -> Int {
        try s.takeError()
        if s.isReset || s.shutWrite || s.hostFD < 0 { throw fail(Code.EPIPE) }
        let nonBlocking = file.isNonBlocking || flags & InetABI.msgDontWait != 0
        let deadline = s.sendTimeout.map { KernelClock.deadline(afterNanoseconds: $0) }
        if s.isStream {
            switch s.state {
            case .listening, .idle:
                throw fail(Code.ENOTCONN)
            case .connecting:
                s.refreshConnecting()
                while s.state == .connecting {
                    if nonBlocking { throw fail(Code.EAGAIN) }
                    if try !s.wait(self, deadline: deadline) { throw fail(Code.EAGAIN) }
                    s.refreshConnecting()
                }
                try s.takeError()
                guard s.state == .connected else { throw fail(Code.ENOTCONN) }
            case .connected:
                break
            }
        } else if address == nil, !s.datagramConnected {
            throw fail(Code.EDESTADDRREQ)
        }
        let hostTo = (s.isStream ? nil : address).map { hostAddress($0) }
        var hostControl = ControlMessages.encodeHost(try ControlMessages.hostSent(control, hostIndex: NetworkInterfaces.hostIndex))
        let hostFlags = SocketFlags.hostCallFlags(flags)
        var written = 0
        while true {
            let n = HostSocketCalls.send(s.hostFD, bytes[written...], to: hostTo, control: hostControl, flags: hostFlags)
            if n >= 0 {
                written += n
                hostControl = []
                if !s.isStream || written == bytes.count { return written }
                continue
            }
            let e = hostErrnoValue
            if e == hostEINTR { continue }
            if e == hostEAGAIN || e == hostEWOULDBLOCK {
                if nonBlocking {
                    if written > 0 { return written }
                    throw fail(Code.EAGAIN)
                }
                do {
                    if try !s.wait(self, deadline: deadline) {
                        if written > 0 { return written }
                        throw fail(Code.EAGAIN)
                    }
                } catch {
                    if written > 0 { return written }
                    throw error
                }
                if s.hostFD < 0 { throw fail(Code.EPIPE) }
                continue
            }
            if written > 0 { return written }
            throw DarwinErrnoError(SocketErrno.fromHost(e))
        }
    }

    struct InetReceive {
        var bytes: [UInt8] = []
        /// The datagram's full length (MSG_TRUNC) or the bytes taken.
        var length = 0
        var from: InetAddress?
        var control: [ControlMessage] = []
        var flags: Int32 = 0
    }

    /// Receives from an IP socket (read, recv, recvfrom, recvmsg, recvmsg_x).
    func inetReceive(_ s: InetSocket, _ file: DarwinOpenFile, max: Int, flags: Int32, controlRoom: Int) throws -> InetReceive {
        s.lastUser = descriptorUser
        if s.isReset {
            if s.pendingError != 0 { try s.takeError() }
            return InetReceive()
        }
        guard s.hostFD >= 0 else { throw fail(Code.EBADF) }
        let nonBlocking = file.isNonBlocking || flags & InetABI.msgDontWait != 0
        let deadline = s.receiveTimeout.map { KernelClock.deadline(afterNanoseconds: $0) }
        if s.isStream {
            switch s.state {
            case .listening:
                throw fail(Code.ENOTCONN)
            case .idle:
                if s.pendingError != 0 { try s.takeError() }
                if s.shutRead { return InetReceive() }
                throw fail(Code.ENOTCONN)
            case .connecting:
                s.refreshConnecting()
                while s.state == .connecting {
                    if nonBlocking { throw fail(Code.EAGAIN) }
                    if try !s.wait(self, deadline: deadline) { throw fail(Code.EAGAIN) }
                    s.refreshConnecting()
                }
                try s.takeError()
            case .connected:
                break
            }
            if max == 0 { return InetReceive() }
        }
        let peek = flags & InetABI.msgPeek != 0
        let waitAll = s.isStream && flags & InetABI.msgWaitAll != 0 && !peek
        var hostFlags = SocketFlags.hostCallFlags(flags)
        if !s.isStream { hostFlags |= HostNet.msgTrunc }  // the full datagram length
        let room = controlRoom > 0 || s.wants != ControlMessages.ReceiveWants() ? 512 : 0
        var out = InetReceive()
        while true {
            if let r = HostSocketCalls.receive(s.hostFD, max: max - out.bytes.count, controlRoom: room, flags: hostFlags) {
                if !s.isStream {
                    out.bytes = r.bytes
                    out.length = r.returned
                    out.from = guestAddress(fromHost: r.address)
                    out.control = ControlMessages.darwinReceived(ControlMessages.parseHost(r.control), wants: s.wants,
                                                                 guestIndex: NetworkInterfaces.guestIndex,
                                                                 interfaceName: { NetworkInterfaces.interface(index: $0)?.name })
                    out.flags = SocketFlags.darwinReceivedFlags(r.flags)
                    if r.returned > r.bytes.count { out.flags |= InetABI.msgTrunc }
                    if !peek { s.signals.fire() }
                    return out
                }
                out.bytes += r.bytes
                out.length = out.bytes.count
                if out.control.isEmpty, !r.control.isEmpty {
                    out.control = ControlMessages.darwinReceived(ControlMessages.parseHost(r.control), wants: s.wants,
                                                                 guestIndex: NetworkInterfaces.guestIndex,
                                                                 interfaceName: { NetworkInterfaces.interface(index: $0)?.name })
                }
                out.flags |= SocketFlags.darwinReceivedFlags(r.flags)
                if r.returned == 0 {
                    // End of stream.
                    s.shutRead = true
                    return out
                }
                if !waitAll || out.bytes.count >= max { return out }
                continue
            }
            let e = hostErrnoValue
            if e == hostEINTR { continue }
            if e == hostEAGAIN || e == hostEWOULDBLOCK {
                if !out.bytes.isEmpty && !waitAll { return out }
                if nonBlocking {
                    if !out.bytes.isEmpty { return out }
                    throw fail(Code.EAGAIN)
                }
                do {
                    if try !s.wait(self, deadline: deadline) {
                        if !out.bytes.isEmpty { return out }
                        throw fail(Code.EAGAIN)
                    }
                } catch {
                    if !out.bytes.isEmpty { return out }
                    throw error
                }
                if s.hostFD < 0 || s.isReset { return out }
                continue
            }
            if !out.bytes.isEmpty { return out }
            throw DarwinErrnoError(SocketErrno.fromHost(e))
        }
    }

    // MARK: msghdr

    struct ParsedMessage {
        var to: InetAddress?
        var iov: [(base: UInt64, length: UInt64)]
        var control: [ControlMessage]
    }

    /// A Darwin `msghdr` (or the first 48 bytes of a `msghdr_x`) of a send.
    func readMessage(_ h: [UInt8], for s: InetSocket, _ mem: any KernelGuestMemory) throws -> ParsedMessage {
        let name = h.readLE(UInt64.self, at: 0), nameLength = h.readLE(UInt32.self, at: 8)
        let iovBase = h.readLE(UInt64.self, at: 16), iovCount = h.readLE(Int32.self, at: 24)
        let control = h.readLE(UInt64.self, at: 32), controlLength = h.readLE(UInt32.self, at: 40)
        guard iovCount >= 0, iovCount <= 1024 else { throw fail(Code.EMSGSIZE) }
        let iov = iovCount == 0 ? [] : try readIOVec(iovBase, count: iovCount, mem, limitError: Code.EMSGSIZE)
        var to: InetAddress?
        if name != 0, nameLength != 0 { to = try readInetAddress(name, length: UInt64(nameLength), for: s, mem) }
        var controls: [ControlMessage] = []
        if control != 0, controlLength >= 12 {
            guard controlLength <= 4096 else { throw fail(Code.EINVAL) }
            controls = try ControlMessages.parseDarwin(try mem.read(va: control, count: Int(controlLength)))
        }
        return ParsedMessage(to: to, iov: iov, control: controls)
    }

    /// recvmsg into the guest `msghdr` at `va` (`h` = its bytes). With
    /// `datalenField` (recvmsg_x), the byte count is also stored there.
    func receiveMessage(_ s: InetSocket, _ file: DarwinOpenFile, header h: [UInt8], at va: UInt64, flags: Int32,
                        datalenField: UInt64?, _ mem: any KernelGuestMemory) throws -> Int {
        let name = h.readLE(UInt64.self, at: 0), nameRoom = h.readLE(UInt32.self, at: 8)
        let iovBase = h.readLE(UInt64.self, at: 16), iovCount = h.readLE(Int32.self, at: 24)
        let control = h.readLE(UInt64.self, at: 32), controlRoom = h.readLE(UInt32.self, at: 40)
        guard iovCount >= 0, iovCount <= 1024 else { throw fail(Code.EMSGSIZE) }
        let iov = iovCount == 0 ? [] : try readIOVec(iovBase, count: iovCount, mem, limitError: Code.EMSGSIZE)
        let total = iov.reduce(0) { $0 + Int($1.length) }
        let r = try inetReceive(s, file, max: total, flags: flags, controlRoom: control == 0 ? 0 : Int(controlRoom))
        try scatter(r.bytes, into: iov, mem)
        var nameLength: UInt32 = 0
        if name != 0, let from = r.from {
            let bytes = from.darwinBytes
            let n = min(Int(nameRoom), bytes.count)
            if n > 0 { try mem.write(va: name, bytes: Array(bytes.prefix(n))) }
            nameLength = UInt32(bytes.count)
        }
        var outFlags = r.flags
        var controlOut: [UInt8] = []
        if !r.control.isEmpty {
            if control != 0 {
                let enc = ControlMessages.encodeDarwin(r.control, room: Int(controlRoom))
                controlOut = enc.bytes
                if enc.truncated { outFlags |= InetABI.msgCtrunc }
                if !controlOut.isEmpty { try mem.write(va: control, bytes: controlOut) }
            } else {
                outFlags |= InetABI.msgCtrunc
            }
        }
        try writeU32(va + 8, nameLength, mem)
        try writeU32(va + 40, UInt32(controlOut.count), mem)
        try writeU32(va + 44, UInt32(bitPattern: outFlags), mem)
        if let datalenField { try writeU64(datalenField, UInt64(r.bytes.count), mem) }
        return r.bytes.count
    }

    // MARK: Options

    func setInetOption(_ s: InetSocket, level: Int32, name: Int32, value: [UInt8]) throws {
        let key = InetSocket.OptionKey(level: level, name: name)
        func intValue() throws -> Int32 {
            guard value.count >= 4 else {
                if value.count >= 1 { return Int32(value[0]) }
                throw fail(Code.EINVAL)
            }
            return value.readLE(Int32.self, at: 0)
        }
        func timeval() throws -> UInt64? {
            guard value.count >= 16 else { throw fail(Code.EINVAL) }
            let sec = value.readLE(Int64.self, at: 0), usec = Int64(value.readLE(Int32.self, at: 8))
            guard sec >= 0, (0..<1_000_000).contains(usec) else { throw fail(Code.EDOM) }
            if sec == 0 && usec == 0 { return nil }
            let (ns, overflow) = sec.multipliedReportingOverflow(by: 1_000_000_000)
            return overflow ? UInt64.max : UInt64(ns + usec * 1000)
        }
        switch (level, name) {
        case (InetABI.solSocket, InetABI.soNoSigPipe):
            s.noSigPipe = try intValue() != 0
            return
        case (InetABI.solSocket, InetABI.soSndTimeo):
            s.sendTimeout = try timeval()
            return
        case (InetABI.solSocket, InetABI.soRcvTimeo):
            s.receiveTimeout = try timeval()
            return
        case (InetABI.solSocket, InetABI.soType), (InetABI.solSocket, InetABI.soError), (InetABI.solSocket, InetABI.soNRead),
             (InetABI.solSocket, InetABI.soNWrite), (InetABI.solSocket, InetABI.soAcceptConn):
            throw fail(Code.ENOPROTOOPT)
        case (InetABI.solSocket, InetABI.soSndBuf), (InetABI.solSocket, InetABI.soRcvBuf):
            let v = try intValue()
            guard v > 0 else { throw fail(Code.EINVAL) }
            if name == InetABI.soSndBuf { s.requestedSendBuffer = v } else { s.requestedReceiveBuffer = v }
        case (InetABI.ipprotoIP, InetABI.ipRecvDstAddr), (InetABI.ipprotoIP, InetABI.ipPktInfo),
             (InetABI.ipprotoIP, InetABI.ipRecvIF):
            let on = try intValue() != 0
            switch name {
            case InetABI.ipRecvDstAddr: s.wants.dstAddr = on
            case InetABI.ipRecvIF: s.wants.recvIF = on
            default: s.wants.pktInfo = on
            }
        case (InetABI.ipprotoIP, InetABI.ipBoundIF), (InetABI.ipprotoIPv6, InetABI.ipv6BoundIF):
            s.boundInterface = UInt32(bitPattern: try intValue())
        default:
            if case .local = SocketOptions.route(level: level, name: name) {
                guard !value.isEmpty else { throw fail(Code.EINVAL) }
                if level == InetABI.solSocket, value.count < 4 { throw fail(Code.EINVAL) }
            }
        }
        if try !s.applyHostOption(level: level, name: name, value: value) || s.keepsLocally(level: level, name: name) {
            s.localOptions[key] = value
        }
        s.appliedOptions.removeAll { $0.key == key }
        s.appliedOptions.append((key, value))
        s.signals.fire()
    }

    func inetOption(_ s: InetSocket, level: Int32, name: Int32, room: Int) throws -> [UInt8] {
        let key = InetSocket.OptionKey(level: level, name: name)
        func int(_ v: Int) -> [UInt8] {
            var b: [UInt8] = []
            b.appendLE(Int32(truncatingIfNeeded: v))
            return b
        }
        func timevalBytes(_ ns: UInt64?) -> [UInt8] {
            var b: [UInt8] = []
            let v = ns ?? 0
            b.appendLE(Int64(v / 1_000_000_000))
            b.appendLE(Int32(v % 1_000_000_000 / 1000))
            b.appendLE(Int32(0))
            return b
        }
        switch (level, name) {
        case (InetABI.solSocket, InetABI.soType): return int(Int(s.type))
        case (InetABI.solSocket, InetABI.soError):
            s.refreshConnecting()
            if s.pendingError != 0 {
                let e = s.pendingError
                s.pendingError = 0
                return int(Int(e))
            }
            guard s.hostFD >= 0 else { return int(0) }
            let e = HostSocketCalls.intOption(s.hostFD, level: HostNet.solSocket, name: hostSOError) ?? 0
            return int(Int(e == 0 ? 0 : SocketErrno.fromHost(e)))
        case (InetABI.solSocket, InetABI.soNoSigPipe): return int(s.noSigPipe ? 1 : 0)
        case (InetABI.solSocket, InetABI.soSndTimeo): return timevalBytes(s.sendTimeout)
        case (InetABI.solSocket, InetABI.soRcvTimeo): return timevalBytes(s.receiveTimeout)
        case (InetABI.solSocket, InetABI.soNRead):
            return int(s.hostFD >= 0 ? HostSocketCalls.bytesReadable(s.hostFD) : 0)
        case (InetABI.solSocket, InetABI.soNWrite):
            return int(s.hostFD >= 0 ? HostSocketCalls.bytesUnsent(s.hostFD) : 0)
        case (InetABI.solSocket, InetABI.soAcceptConn): return int(s.state == .listening ? 1 : 0)
        case (InetABI.solSocket, InetABI.soSndBuf): return int(Int(s.sendBufferSize))
        case (InetABI.solSocket, InetABI.soRcvBuf): return int(Int(s.receiveBufferSize))
        case (InetABI.solSocket, InetABI.soSndLowat):
            return s.localOptions[key] ?? int(SocketABI.sendLowWater)
        case (InetABI.ipprotoIP, InetABI.ipRecvDstAddr): return int(s.wants.dstAddr ? 1 : 0)
        case (InetABI.ipprotoIP, InetABI.ipPktInfo): return int(s.wants.pktInfo ? 1 : 0)
        case (InetABI.ipprotoIP, InetABI.ipRecvIF): return int(s.wants.recvIF ? 1 : 0)
        case (InetABI.ipprotoIP, InetABI.ipBoundIF), (InetABI.ipprotoIPv6, InetABI.ipv6BoundIF):
            return int(Int(s.boundInterface))
        case (InetABI.ipprotoTCP, InetABI.tcpConnectionInfo):
            guard s.isStream else { throw fail(Code.ENOPROTOOPT) }
            return tcpConnectionInfo(s)
        default:
            break
        }
        if let v = s.localOptions[key] { return v }
        switch SocketOptions.route(level: level, name: name) {
        case .local:
            return int(0)
        case let .host(hl, hn, kind):
            guard s.hostFD >= 0 else { return int(0) }
            guard let v = HostSocketCalls.option(s.hostFD, level: hl, name: hn, size: max(room, 4)) else {
                let e = hostErrnoValue
                if e == hostENOPROTOOPT || e == hostEOPNOTSUPP { return int(0) }
                throw DarwinErrnoError(SocketErrno.fromHost(e))
            }
            return SocketOptions.guestValue(v, kind: kind, guestIndex: NetworkInterfaces.guestIndex)
        }
    }

    /// TCP_CONNECTION_INFO (`struct tcp_connection_info`, 112 bytes) from the
    /// host's TCP_INFO (Linux) where it is known; zero otherwise.
    func tcpConnectionInfo(_ s: InetSocket) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: InetABI.tcpConnectionInfoLength)
        var state: UInt8
        switch s.state {
        case .listening: state = InetABI.tcpsListen
        case .connecting: state = InetABI.tcpsSynSent
        case .connected: state = InetABI.tcpsEstablished
        case .idle: state = InetABI.tcpsClosed
        }
        #if canImport(Glibc)
        if s.hostFD >= 0, let t = HostSocketCalls.option(s.hostFD, level: InetABI.ipprotoTCP, name: HostNet.tcpInfo, size: 232),
           t.count >= 104 {
            let linuxStates: [UInt8: UInt8] = [1: InetABI.tcpsEstablished, 2: InetABI.tcpsSynSent, 3: InetABI.tcpsSynReceived,
                                               4: InetABI.tcpsFinWait1, 5: InetABI.tcpsFinWait2, 6: InetABI.tcpsTimeWait,
                                               7: InetABI.tcpsClosed, 8: InetABI.tcpsCloseWait, 9: InetABI.tcpsLastAck,
                                               10: InetABI.tcpsListen, 11: InetABI.tcpsClosing]
            state = linuxStates[t[0]] ?? state
            b[1] = t[6] & 0x0F                                      // snd_wscale
            b[2] = t[6] >> 4                                        // rcv_wscale
            b.putLE(UInt32(t[5] & 0x0F), at: 4)                     // options (same bits)
            let mss = t.readLE(UInt32.self, at: 16)
            b.putLE(t.readLE(UInt32.self, at: 8) / 1000, at: 12)    // rto (ms)
            b.putLE(mss, at: 16)                                    // maxseg
            b.putLE(t.readLE(UInt32.self, at: 76), at: 20)          // snd_ssthresh
            b.putLE(t.readLE(UInt32.self, at: 80) &* mss, at: 24)   // snd_cwnd (bytes)
            b.putLE(t.readLE(UInt32.self, at: 68) / 1000, at: 40)   // rttcur
            b.putLE(t.readLE(UInt32.self, at: 68) / 1000, at: 44)   // srtt
            b.putLE(t.readLE(UInt32.self, at: 72) / 1000, at: 48)   // rttvar
            if t.count >= 144 {
                b.putLE(t.readLE(UInt32.self, at: 136).toU64, at: 56)  // txpackets (segs_out)
                b.putLE(t.readLE(UInt64.self, at: 120), at: 64)        // txbytes (bytes_acked)
                b.putLE(t.readLE(UInt32.self, at: 140).toU64, at: 80)  // rxpackets (segs_in)
                b.putLE(t.readLE(UInt64.self, at: 128), at: 88)        // rxbytes
            }
            b.putLE(UInt32(t.readLE(UInt32.self, at: 100)).toU64, at: 104)  // txretransmitpackets
        }
        #endif
        b[0] = state
        return b
    }
}

private extension UInt32 {
    var toU64: UInt64 { UInt64(self) }
}

/// `YCODE_NO_NETWORK=1`: no IP sockets (EAFNOSUPPORT, the behavior before
/// host networking).
enum InetSocketPolicy {
    static let disabled = getenv("YCODE_NO_NETWORK").map { String(cString: $0) == "1" } ?? false
}

// The C library's names, which the kernel's own (`DarwinKernel.EINTR`,
// `errno(of:)`, `shutdown`) would otherwise shadow inside its extensions.
private var hostErrnoValue: Int32 { errno }
private let hostEINTR = EINTR, hostEAGAIN = EAGAIN, hostEWOULDBLOCK = EWOULDBLOCK, hostEINPROGRESS = EINPROGRESS,
            hostECONNABORTED = ECONNABORTED, hostENOPROTOOPT = ENOPROTOOPT, hostEOPNOTSUPP = EOPNOTSUPP
private let hostSOError = Int32(SO_ERROR)
private func hostShutdown(_ fd: Int32, _ how: Int32) -> Int32 { shutdown(fd, how) }
private func hostListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func hostBind(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ n: socklen_t) -> Int32 { bind(fd, a, n) }
private func hostConnect(_ fd: Int32, _ a: UnsafePointer<sockaddr>, _ n: socklen_t) -> Int32 { connect(fd, a, n) }
