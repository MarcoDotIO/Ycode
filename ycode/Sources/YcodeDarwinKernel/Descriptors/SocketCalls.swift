import Foundation
import YcodeDarwinABI

// The socket system calls (`specs/simulator/stage4b-contract.md` §6 item 3,
// `specs/simulator/processes.md` §5): argument decoding with the Darwin
// layouts (`sockaddr_un`, `msghdr`, `cmsghdr`, `xucred`), then the
// `UnixSocket` model. Owner: agent F.
//
// SCM_RIGHTS receive, when `msg_control` is too short or NULL
// (`processes.md` §5.5 allows this choice): only the descriptors whose
// 4-byte slot is copied out completely are installed; the others are
// closed (xnu would leave them open in the receiver).

extension DarwinKernel {
    /// The socket behind `fd` (EBADF, ENOTSOCK).
    func socketObject(_ fd: Int32) throws -> (UnixSocket, DarwinOpenFile) {
        let file = try fileSystem.openFile(for: fd)
        guard let s = file.object as? UnixSocket else { throw fail(Code.ENOTSOCK) }
        return (s, file)
    }

    /// Reads a guest `sockaddr_un` of `length` bytes (`processes.md` §5.3):
    /// `sun_len` becomes `length`; the family must be 0 or AF_UNIX
    /// (EAFNOSUPPORT); the path (cut at the first NUL) must not be empty
    /// by length (EINVAL). A length outside 2…255 is EINVAL.
    func readUnixAddress(_ va: UInt64, length: UInt64, _ mem: any KernelGuestMemory) throws -> UnixAddress {
        guard length >= 2, length <= UInt64(SocketABI.maxAddressLength) else { throw fail(Code.EINVAL) }
        var raw = try mem.read(va: va, count: Int(length))
        raw[0] = UInt8(length)
        let family = Int32(raw[1])
        guard family == SocketABI.afUnix || family == SocketABI.afUnspec else { throw fail(Code.EAFNOSUPPORT) }
        guard length > 2 else { throw fail(Code.EINVAL) }
        let path = String(decoding: raw[2...].prefix { $0 != 0 }, as: UTF8.self)
        return UnixAddress(raw: raw, path: path)
    }

    /// Copies `address` out the BSD way: at most `*lengthPointer` bytes to
    /// `va`, then the untruncated length to `*lengthPointer` (0 when there
    /// is no address).
    func copyOutAddress(_ address: [UInt8]?, to va: UInt64, lengthPointer: UInt64, _ mem: any KernelGuestMemory) throws {
        guard lengthPointer != 0 else { return }
        let room = Int(try mem.read(va: lengthPointer, count: 4).readLE(UInt32.self, at: 0))
        guard let address else {
            try writeU32(lengthPointer, 0, mem)
            return
        }
        let n = min(room, address.count)
        if va != 0, n > 0 { try mem.write(va: va, bytes: Array(address.prefix(n))) }
        try writeU32(lengthPointer, UInt32(address.count), mem)
    }

    func socketCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        // An IP socket (networking-ycode.md §2): its own layer.
        if n != DescriptorBSD.socket, n != DescriptorBSD.socketpair, let file = try? fileSystem.openFile(for: int(0)) {
            if let s = file.object as? InetSocket {
                call.set(Self.socketCallText(n, a))
                return try inetSocketCall(n, a, s, file, &call, mem)
            }
            if let s = file.object as? RouteSocket {
                call.set(Self.socketCallText(n, a) + " [PF_ROUTE]")
                return try routeSocketCall(n, a, s, file, &call, mem)
            }
            if let s = file.object as? KernelControlSocket {
                call.set(Self.socketCallText(n, a) + " [kernel control]")
                return try kernelControlCall(n, a, s, file, &call, mem)
            }
        }
        switch n {
        case DescriptorBSD.socket:
            call.set("socket(domain=\(int(0)), type=\(int(1)), protocol=\(int(2)))")
            if int(0) == InetABI.afInet || int(0) == InetABI.afInet6 {
                let s = try makeInetSocket(domain: int(0), type: int(1), proto: int(2))
                let fd = try fileSystem.installObject(s, statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
                call += " [IP socket, fd \(fd)]"
                return .value(UInt64(fd))
            }
            if int(0) == KernelControlSocket.afSystem, int(2) == KernelControlSocket.sysprotoControl, !InetSocketPolicy.disabled {
                guard int(1) == InetABI.sockDgram || int(1) == InetABI.sockStream else { throw fail(Code.EPROTOTYPE) }
                let fd = try fileSystem.installObject(KernelControlSocket(lock: lock), statusFlags: DarwinOpen.O_RDWR,
                                                      closeOnExec: false)
                call += " [kernel control, fd \(fd)]"
                return .value(UInt64(fd))
            }
            if int(0) == InetABI.afRoute, !InetSocketPolicy.disabled {
                guard int(1) == InetABI.sockRaw else { throw fail(Code.EPROTOTYPE) }
                let fd = try fileSystem.installObject(RouteSocket(proto: int(2), lock: lock), statusFlags: DarwinOpen.O_RDWR,
                                                      closeOnExec: false)
                call += " [PF_ROUTE, fd \(fd)]"
                return .value(UInt64(fd))
            }
            let s = try makeSocket(domain: int(0), type: int(1), proto: int(2))
            let fd = try fileSystem.installObject(s, statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
            return .value(UInt64(fd))

        case DescriptorBSD.socketpair:
            call.set("socketpair(domain=\(int(0)), type=\(int(1)), protocol=\(int(2)), sv=\(hx(a[3])))")
            if int(0) == InetABI.afInet || int(0) == InetABI.afInet6 { throw fail(Code.EOPNOTSUPP) }
            let a1 = try makeSocket(domain: int(0), type: int(1), proto: int(2))
            let b1 = try makeSocket(domain: int(0), type: int(1), proto: int(2))
            guard fileSystem.freeDescriptorCount >= 2 else { throw fail(Code.EMFILE) }
            a1.peer = b1
            b1.peer = a1
            a1.isConnected = true
            b1.isConnected = true
            a1.peerCredentials = descriptorUser
            b1.peerCredentials = descriptorUser
            if a1.kind == .datagram {
                a1.connectedSenders = [WeakSocket(socket: b1)]
                b1.connectedSenders = [WeakSocket(socket: a1)]
            }
            let fd0 = try fileSystem.installObject(a1, statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
            let fd1 = try fileSystem.installObject(b1, statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
            var sv: [UInt8] = []
            sv.appendLE(fd0)
            sv.appendLE(fd1)
            do {
                try mem.write(va: a[3], bytes: sv)
            } catch {
                try? fileSystem.close(fd0)
                try? fileSystem.close(fd1)
                throw error
            }
            call += " [\(fd0), \(fd1)]"
            return .value(0)

        case DescriptorBSD.bind:
            call.set("bind(s=\(int(0)), name=\(hx(a[1])), namelen=\(int(2)))")
            let (s, _) = try socketObject(int(0))
            let address = try readUnixAddress(a[1], length: UInt64(UInt32(truncatingIfNeeded: a[2])), mem)
            call += " [\"\(address.path)\"]"
            guard s.address == nil, !(s.cantSendMore && s.cantReceiveMore) else { throw fail(Code.EINVAL) }
            s.boundPath = try fileSystem.bindSocket(s, path: address.path, umask: extended.umask)
            s.address = address.raw
            s.lastUser = descriptorUser
            return .value(0)

        case DescriptorBSD.listen:
            call.set("listen(s=\(int(0)), backlog=\(int(1)))")
            let (s, _) = try socketObject(int(0))
            guard s.kind == .stream else { throw fail(Code.EOPNOTSUPP) }
            guard !s.isConnected, s.peer == nil else { throw fail(Code.EINVAL) }
            guard s.address != nil else { throw fail(Code.EINVAL) }  // uipc_listen: unbound
            let backlog = int(1)
            s.backlog = backlog <= 0 || backlog > Int32(SocketABI.maxBacklog) ? SocketABI.maxBacklog : Int(backlog)
            s.isListening = true
            s.listenUser = descriptorUser
            s.lastUser = descriptorUser
            s.signals.fire()
            return .value(0)

        case DescriptorBSD.accept:
            call.set("accept(s=\(int(0)), name=\(hx(a[1])), anamelen=\(hx(a[2])))")
            let (s, file) = try socketObject(int(0))
            guard s.isListening else { throw fail(Code.EINVAL) }
            s.lastUser = descriptorUser
            let deadline = s.receiveTimeout.map { KernelClock.deadline(afterNanoseconds: $0) }
            while s.pending.isEmpty {
                if s.closed { throw fail(Code.ECONNABORTED) }
                if file.isNonBlocking { throw fail(Code.EAGAIN) }
                if try !waitOnObject(s.signals, deadline: deadline) { throw fail(Code.EAGAIN) }
                guard s.isListening else { throw fail(Code.EINVAL) }
            }
            guard fileSystem.freeDescriptorCount >= 1 else { throw fail(Code.EMFILE) }
            let c = s.pending.removeFirst()
            c.lastUser = descriptorUser
            // The new descriptor inherits the listener's O_NONBLOCK (xnu accept).
            let flags = DarwinOpen.O_RDWR | (file.statusFlags & DarwinOpen.O_NONBLOCK)
            let fd = try fileSystem.installObject(c, statusFlags: flags, closeOnExec: false)
            if a[1] != 0 {
                try copyOutAddress(c.peerAddress ?? SocketABI.unnamed, to: a[1], lengthPointer: a[2], mem)
            }
            s.signals.fire()
            call += " [fd \(fd)]"
            return .value(UInt64(fd))

        case DescriptorBSD.connect:
            call.set("connect(s=\(int(0)), name=\(hx(a[1])), namelen=\(int(2)))")
            let (s, _) = try socketObject(int(0))
            let address = try readUnixAddress(a[1], length: UInt64(UInt32(truncatingIfNeeded: a[2])), mem)
            call += " [\"\(address.path)\"]"
            try connectSocket(s, to: address)
            return .value(0)

        case DescriptorBSD.shutdown:
            call.set("shutdown(s=\(int(0)), how=\(int(1)))")
            let (s, _) = try socketObject(int(0))
            let how = int(1)
            guard (0...2).contains(how) else { throw fail(Code.EINVAL) }
            guard s.isConnected else { throw fail(Code.ENOTCONN) }
            if how != 1 {
                s.cantReceiveMore = true
                s.flushReceiveQueue()
            }
            if how != 0 {
                s.cantSendMore = true
                if s.kind == .stream, let p = s.peer { p.cantReceiveMore = true }
            }
            s.changedWithPeer()
            return .value(0)

        case DescriptorBSD.getsockname, DescriptorBSD.getpeername:
            let peer = n == DescriptorBSD.getpeername
            call.set("\(peer ? "getpeername" : "getsockname")(fdes=\(int(0)), asa=\(hx(a[1])), alen=\(hx(a[2])))")
            let (s, _) = try socketObject(int(0))
            let address: [UInt8]
            if peer {
                guard s.isConnected, let p = s.peerAddress else { throw fail(Code.ENOTCONN) }
                address = p
            } else {
                address = s.address ?? SocketABI.unnamed
            }
            try copyOutAddress(address, to: a[1], lengthPointer: a[2], mem)
            return .value(0)

        case DescriptorBSD.sendto:
            return try sendtoCall(a, &call, mem)

        case DescriptorBSD.recvfrom:
            call.set("recvfrom(s=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])), flags=\(hx(a[3])), from=\(hx(a[4])), "
                + "fromlenaddr=\(hx(a[5])))")
            let (s, file) = try socketObject(int(0))
            guard file.isReadable else { throw fail(Code.EBADF) }
            guard a[2] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
            let r = try socketReceive(s, file, max: Int(a[2]), flags: int(3))
            if !r.bytes.isEmpty { try mem.write(va: a[1], bytes: r.bytes) }
            if a[4] != 0 { try copyOutAddress(r.from, to: a[4], lengthPointer: a[5], mem) }
            return .value(UInt64(r.bytes.count))

        case DescriptorBSD.sendmsg:
            return try sendmsgCall(a, &call, mem)

        case DescriptorBSD.recvmsg:
            return try recvmsgCall(a, &call, mem)

        case DescriptorBSD.setsockopt:
            call.set("setsockopt(s=\(int(0)), level=\(hx(UInt32(bitPattern: int(1)))), name=\(hx(UInt32(bitPattern: int(2)))), "
                + "val=\(hx(a[3])), valsize=\(int(4)))")
            let (s, _) = try socketObject(int(0))
            let size = Int(UInt32(truncatingIfNeeded: a[4]))
            let value = a[3] == 0 || size == 0 ? [] : try mem.read(va: a[3], count: min(size, 256))
            try setSocketOption(s, level: int(1), name: int(2), value: value)
            return .value(0)

        case DescriptorBSD.getsockopt:
            call.set("getsockopt(s=\(int(0)), level=\(hx(UInt32(bitPattern: int(1)))), name=\(hx(UInt32(bitPattern: int(2)))), "
                + "val=\(hx(a[3])), avalsize=\(hx(a[4])))")
            let (s, _) = try socketObject(int(0))
            let value = try socketOption(s, level: int(1), name: int(2))
            guard a[4] != 0 else { throw fail(Code.EFAULT) }
            let room = Int(try mem.read(va: a[4], count: 4).readLE(UInt32.self, at: 0))
            let n = min(room, value.count)
            if a[3] != 0, n > 0 { try mem.write(va: a[3], bytes: Array(value.prefix(n))) }
            try writeU32(a[4], UInt32(n), mem)
            return .value(0)

        default:
            throw fail(Code.ENOSYS)
        }
    }

    /// The trace text of a socket call on a descriptor.
    static func socketCallText(_ n: Int, _ a: [UInt64]) -> String {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case DescriptorBSD.bind: return "bind(s=\(int(0)), name=\(hx(a[1])), namelen=\(int(2)))"
        case DescriptorBSD.listen: return "listen(s=\(int(0)), backlog=\(int(1)))"
        case DescriptorBSD.accept: return "accept(s=\(int(0)), name=\(hx(a[1])), anamelen=\(hx(a[2])))"
        case DescriptorBSD.connect: return "connect(s=\(int(0)), name=\(hx(a[1])), namelen=\(int(2)))"
        case DescriptorBSD.shutdown: return "shutdown(s=\(int(0)), how=\(int(1)))"
        case DescriptorBSD.getsockname: return "getsockname(fdes=\(int(0)), asa=\(hx(a[1])), alen=\(hx(a[2])))"
        case DescriptorBSD.getpeername: return "getpeername(fdes=\(int(0)), asa=\(hx(a[1])), alen=\(hx(a[2])))"
        case DescriptorBSD.sendto:
            return "sendto(s=\(int(0)), buf=\(hx(a[1])), len=\(a[2]), flags=\(hx(UInt32(bitPattern: int(3)))), to=\(hx(a[4])), tolen=\(int(5)))"
        case DescriptorBSD.recvfrom:
            return "recvfrom(s=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])), flags=\(hx(a[3])), from=\(hx(a[4])), fromlenaddr=\(hx(a[5])))"
        case DescriptorBSD.sendmsg: return "sendmsg(s=\(int(0)), msg=\(hx(a[1])), flags=\(hx(UInt32(bitPattern: int(2)))))"
        case DescriptorBSD.recvmsg: return "recvmsg(s=\(int(0)), msg=\(hx(a[1])), flags=\(hx(UInt32(bitPattern: int(2)))))"
        case DescriptorBSD.setsockopt:
            return "setsockopt(s=\(int(0)), level=\(hx(UInt32(bitPattern: int(1)))), name=\(hx(UInt32(bitPattern: int(2)))), val=\(hx(a[3])), valsize=\(int(4)))"
        case DescriptorBSD.getsockopt:
            return "getsockopt(s=\(int(0)), level=\(hx(UInt32(bitPattern: int(1)))), name=\(hx(UInt32(bitPattern: int(2)))), val=\(hx(a[3])), avalsize=\(hx(a[4])))"
        default: return "socket call \(n)(\(int(0)))"
        }
    }

    /// `socket(domain, type, protocol)`: AF_UNIX STREAM and DGRAM (AF_INET
    /// and AF_INET6 are `makeInetSocket`); other domains are EAFNOSUPPORT;
    /// another type is EPROTONOSUPPORT, a protocol other than 0 too.
    func makeSocket(domain: Int32, type: Int32, proto: Int32) throws -> UnixSocket {
        guard domain == SocketABI.afUnix else { throw fail(Code.EAFNOSUPPORT) }
        guard proto == 0 else { throw fail(Code.EPROTONOSUPPORT) }
        guard let kind = UnixSocket.Kind(rawValue: type) else { throw fail(Code.EPROTONOSUPPORT) }
        return UnixSocket(kind: kind, lock: lock, creator: descriptorUser)
    }

    // MARK: sendto / sendmsg / recvmsg

    /// `sendto`. A descriptor that is not a socket keeps stage 4a's
    /// behavior: the text is logged and the call fails with ENOTSOCK (the
    /// simulator runtime's logging calls `sendto` on descriptor 0 today).
    private func sendtoCall(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let fd = Int32(truncatingIfNeeded: a[0])
        let flags = Int32(truncatingIfNeeded: a[3])
        call.set("sendto(s=\(fd), buf=\(hx(a[1])), len=\(a[2]), flags=\(hx(UInt32(bitPattern: flags))), to=\(hx(a[4])), "
            + "tolen=\(Int32(truncatingIfNeeded: a[5])))")
        let file = try fileSystem.openFile(for: fd)
        guard let s = file.object as? UnixSocket else {
            if a[2] > 0, let bytes = try? mem.read(va: a[1], count: Int(min(a[2], 2048))) { logDatagramText(bytes) }
            throw fail(Code.ENOTSOCK)
        }
        guard file.isWritable else { throw fail(Code.EBADF) }
        guard a[2] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
        var address: UnixAddress?
        if a[4] != 0 {
            address = try readUnixAddress(a[4], length: UInt64(UInt32(truncatingIfNeeded: a[5])), mem)
            call += " [\"\(address!.path)\"]"
        }
        let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
        return .value(UInt64(try socketSend(s, file, bytes, rights: nil, to: address, flags: flags)))
    }

    /// A Darwin `struct msghdr` (48 bytes, `processes.md` §5.1).
    private struct MessageHeader {
        var name: UInt64
        var nameLength: UInt32
        var iov: UInt64
        var iovCount: Int32
        var control: UInt64
        var controlLength: UInt32

        init(_ b: [UInt8]) {
            name = b.readLE(UInt64.self, at: 0)
            nameLength = b.readLE(UInt32.self, at: 8)
            iov = b.readLE(UInt64.self, at: 16)
            iovCount = b.readLE(Int32.self, at: 24)
            control = b.readLE(UInt64.self, at: 32)
            controlLength = b.readLE(UInt32.self, at: 40)
        }
    }

    private func sendmsgCall(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let fd = Int32(truncatingIfNeeded: a[0])
        let flags = Int32(truncatingIfNeeded: a[2])
        call.set("sendmsg(s=\(fd), msg=\(hx(a[1])), flags=\(hx(UInt32(bitPattern: flags))))")
        let (s, file) = try socketObject(fd)
        guard file.isWritable else { throw fail(Code.EBADF) }
        let h = MessageHeader(try mem.read(va: a[1], count: 48))
        guard h.iovCount > 0, h.iovCount <= 1024 else { throw fail(Code.EMSGSIZE) }
        let iov = try readIOVec(h.iov, count: h.iovCount, mem, limitError: Code.EMSGSIZE)
        var address: UnixAddress?
        if h.name != 0 {
            address = try readUnixAddress(h.name, length: UInt64(h.nameLength), mem)
            call += " [to \"\(address!.path)\"]"
        }
        var rights: [DarwinOpenFile]?
        if h.control != 0 {
            rights = try internalizeRights(h.control, length: h.controlLength, mem)
            call += " [SCM_RIGHTS \(rights!.count)]"
        }
        let bytes = try gather(iov, mem)
        return .value(UInt64(try socketSend(s, file, bytes, rights: rights, to: address, flags: flags)))
    }

    /// The control data of `sendmsg` (`processes.md` §5.5 send side, xnu
    /// `unp_internalize`): exactly one SOL_SOCKET / SCM_RIGHTS message whose
    /// `cmsg_len` equals `msg_controllen` (else EINVAL); each fd open (EBADF)
    /// and not confined (EINVAL). The descriptions are captured now.
    func internalizeRights(_ va: UInt64, length: UInt32, _ mem: any KernelGuestMemory) throws -> [DarwinOpenFile] {
        guard length >= 12 else { throw fail(Code.EINVAL) }
        // sockargs: the in-kernel copy (fds widened to pointers) must fit a
        // 2048-byte cluster.
        guard (Int(length) - 12) * 2 + 12 <= 2048 else { throw fail(Code.EINVAL) }
        let c = try mem.read(va: va, count: Int(length))
        let cmsgLength = c.readLE(UInt32.self, at: 0)
        guard c.readLE(Int32.self, at: 4) == SocketABI.solSocket, c.readLE(Int32.self, at: 8) == SocketABI.scmRights,
              cmsgLength == length else { throw fail(Code.EINVAL) }
        let count = (Int(cmsgLength) - 12) / 4
        var files: [DarwinOpenFile] = []
        for i in 0..<count {
            let fd = c.readLE(Int32.self, at: 12 + 4 * i)
            let file = try fileSystem.openFile(for: fd)
            try fileSystem.checkGuard(fd, DarwinGuard.socketIPC, flavor: DarwinGuard.exceptionSocketIPC)
            if file.object?.isConfined ?? false { throw fail(Code.EINVAL) }
            files.append(file)
        }
        return files
    }

    private func recvmsgCall(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        let fd = Int32(truncatingIfNeeded: a[0])
        let flags = Int32(truncatingIfNeeded: a[2])
        call.set("recvmsg(s=\(fd), msg=\(hx(a[1])), flags=\(hx(UInt32(bitPattern: flags))))")
        let (s, file) = try socketObject(fd)
        guard file.isReadable else { throw fail(Code.EBADF) }
        let h = MessageHeader(try mem.read(va: a[1], count: 48))
        guard h.iovCount > 0, h.iovCount <= 1024 else { throw fail(Code.EMSGSIZE) }
        let iov = try readIOVec(h.iov, count: h.iovCount, mem, limitError: Code.EMSGSIZE)
        let total = iov.reduce(0) { $0 + Int($1.length) }
        let r = try socketReceive(s, file, max: total, flags: flags)

        var outFlags: Int32 = r.truncated ? SocketABI.msgTrunc : 0
        var controlOut: [UInt8] = []
        let rightsCount = r.rights?.count ?? r.peekedRights
        if rightsCount > 0, h.control != 0 {
            let room = Int(h.controlLength)
            let full = 12 + 4 * rightsCount
            let slots = room >= 12 ? min(rightsCount, (room - 12) / 4) : 0
            var fds: [Int32] = []
            if let rights = r.rights {
                // Install what fits before copying out (all or none: EMSGSIZE).
                guard fileSystem.freeDescriptorCount >= slots else { throw fail(Code.EMSGSIZE) }
                for f in rights.prefix(slots) { fds.append(try fileSystem.install(f, closeOnExec: false)) }
            }
            var cmsg: [UInt8] = []
            cmsg.appendLE(UInt32(full))
            cmsg.appendLE(SocketABI.solSocket)
            cmsg.appendLE(SocketABI.scmRights)
            for i in 0..<rightsCount { cmsg.appendLE(i < fds.count ? fds[i] : Int32(0)) }
            controlOut = Array(cmsg.prefix(room))
            if controlOut.count < full { outFlags |= SocketABI.msgCtrunc }
            call += " [SCM_RIGHTS \(fds.map(String.init).joined(separator: ","))\(r.peekedRights > 0 ? " (peek)" : "")]"
        } else if rightsCount > 0 {
            outFlags |= SocketABI.msgCtrunc
        }
        // Rights that were not installed are released here (closed).

        try scatter(r.bytes, into: iov, mem)
        var nameLength: UInt32 = 0
        if h.name != 0, let from = r.from {
            let n = min(Int(h.nameLength), from.count)
            if n > 0 { try mem.write(va: h.name, bytes: Array(from.prefix(n))) }
            nameLength = UInt32(from.count)
        }
        if !controlOut.isEmpty { try mem.write(va: h.control, bytes: controlOut) }
        try writeU32(a[1] + 8, nameLength, mem)
        try writeU32(a[1] + 40, UInt32(controlOut.count), mem)
        try writeU32(a[1] + 44, UInt32(bitPattern: outFlags), mem)
        return .value(UInt64(r.bytes.count))
    }

    // MARK: Options

    /// A `struct timeval` (16 bytes on arm64) as nanoseconds; 0 = none.
    private func timeval(_ v: [UInt8]) throws -> UInt64? {
        guard v.count >= 16 else { throw fail(Code.EINVAL) }
        let sec = v.readLE(Int64.self, at: 0), usec = Int64(v.readLE(Int32.self, at: 8))
        guard sec >= 0, (0..<1_000_000).contains(usec) else { throw fail(Code.EDOM) }
        if sec == 0 && usec == 0 { return nil }
        let (ns, overflow) = sec.multipliedReportingOverflow(by: 1_000_000_000)
        return overflow ? UInt64.max : UInt64(ns + usec * 1000)
    }

    private func timevalBytes(_ ns: UInt64?) -> [UInt8] {
        var b: [UInt8] = []
        let v = ns ?? 0
        b.appendLE(Int64(v / 1_000_000_000))
        b.appendLE(Int32(v % 1_000_000_000 / 1000))
        b.appendLE(Int32(0))
        return b
    }

    /// `setsockopt`. SOL_SOCKET options Ycode does not model are stored and
    /// read back; any SOL_LOCAL option (and any other level) is EOPNOTSUPP
    /// (`processes.md` §5.6).
    func setSocketOption(_ s: UnixSocket, level: Int32, name: Int32, value: [UInt8]) throws {
        guard level == SocketABI.solSocket else { throw fail(Code.EOPNOTSUPP) }
        func intValue() throws -> Int32 {
            guard value.count >= 4 else { throw fail(Code.EINVAL) }
            return value.readLE(Int32.self, at: 0)
        }
        switch name {
        case SocketABI.soNoSigPipe:
            s.noSigPipe = try intValue() != 0
        case SocketABI.soSndBuf, SocketABI.soRcvBuf:
            let v = try intValue()
            guard v > 0 else { throw fail(Code.EINVAL) }
            guard v <= 8 << 20 else { throw fail(Code.ENOBUFS) }
            if name == SocketABI.soSndBuf { s.sendBufferSize = Int(v) } else { s.receiveBufferSize = Int(v) }
        case SocketABI.soSndLowat:
            s.sendLowWater = max(1, Int(try intValue()))
        case SocketABI.soRcvLowat:
            s.receiveLowWater = max(1, Int(try intValue()))
        case SocketABI.soSndTimeo:
            s.sendTimeout = try timeval(value)
        case SocketABI.soRcvTimeo:
            s.receiveTimeout = try timeval(value)
        case SocketABI.soLinger, SocketABI.soLingerSec:
            guard value.count >= 8 else { throw fail(Code.EINVAL) }
            s.linger = (value.readLE(Int32.self, at: 0), value.readLE(Int32.self, at: 4))
        case SocketABI.soType, SocketABI.soError, SocketABI.soNRead, SocketABI.soNWrite, SocketABI.soAcceptConn:
            throw fail(Code.ENOPROTOOPT)
        default:
            guard value.count >= 4 else { throw fail(Code.EINVAL) }
            s.otherOptions[name] = value
        }
        s.signals.fire()
    }

    /// `getsockopt` value bytes.
    func socketOption(_ s: UnixSocket, level: Int32, name: Int32) throws -> [UInt8] {
        func int(_ v: Int) -> [UInt8] {
            var b: [UInt8] = []
            b.appendLE(Int32(truncatingIfNeeded: v))
            return b
        }
        if level == SocketABI.solLocal {
            return try localPeerOption(s, name: name)
        }
        guard level == SocketABI.solSocket else { throw fail(Code.ENOPROTOOPT) }
        switch name {
        case SocketABI.soType: return int(Int(s.kind.rawValue))
        case SocketABI.soError:
            let e = s.error
            s.error = 0
            return int(Int(e))
        case SocketABI.soNoSigPipe: return int(s.noSigPipe ? 1 : 0)
        case SocketABI.soSndBuf: return int(s.sendBufferSize)
        case SocketABI.soRcvBuf: return int(s.receiveBufferSize)
        case SocketABI.soSndLowat: return int(s.sendLowWater)
        case SocketABI.soRcvLowat: return int(s.receiveLowWater)
        case SocketABI.soAcceptConn: return int(s.isListening ? 1 : 0)
        case SocketABI.soNRead:
            if s.kind == .datagram { return int(s.datagrams.first?.bytes.count ?? 0) }
            return int(s.queuedBytes)
        case SocketABI.soNWrite: return int(0)
        case SocketABI.soSndTimeo: return timevalBytes(s.sendTimeout)
        case SocketABI.soRcvTimeo: return timevalBytes(s.receiveTimeout)
        case SocketABI.soLinger, SocketABI.soLingerSec:
            var b: [UInt8] = []
            b.appendLE(s.linger.onOff)
            b.appendLE(s.linger.seconds)
            return b
        default:
            return s.otherOptions[name] ?? int(0)
        }
    }

    /// `LOCAL_PEER*` (`processes.md` §5.6).
    private func localPeerOption(_ s: UnixSocket, name: Int32) throws -> [UInt8] {
        switch name {
        case SocketABI.localPeerCred:
            guard let c = s.peerCredentials else {
                throw fail(s.kind == .stream ? Code.ENOTCONN : Code.EINVAL)
            }
            return c.xucred
        case SocketABI.localPeerPID, SocketABI.localPeerEPID:
            guard let p = s.peer else { throw fail(Code.ENOTCONN) }
            var b: [UInt8] = []
            b.appendLE(p.lastUser.pid)
            return b
        case SocketABI.localPeerUUID, SocketABI.localPeerEUUID:
            guard let p = s.peer else { throw fail(Code.ENOTCONN) }
            // The peer process's main-executable UUID (zero if it is gone).
            return system.processes[p.lastUser.pid]?.executableUUID ?? [UInt8](repeating: 0, count: 16)
        case SocketABI.localPeerToken:
            guard let p = s.peer else { throw fail(Code.ENOTCONN) }
            let user = p.lastUser
            // The process must still exist; the token describes it now.
            if let k = system.kernel(forPID: user.pid) { return k.descriptorAuditToken }
            if let k = user.kernel, !k.isTerminating { return k.descriptorAuditToken }
            throw fail(Code.EINVAL)
        default:
            throw fail(Code.EOPNOTSUPP)
        }
    }
}
