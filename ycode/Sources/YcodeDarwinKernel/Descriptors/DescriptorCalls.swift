import Foundation
import YcodeDarwinABI

// Descriptors of stage 4b (`specs/simulator/stage4b-contract.md` §6): pipes,
// AF_UNIX sockets, dup/dup2, SCM_RIGHTS. Owner: agent F.
//
// `descriptorCall` runs before `bsdCall`'s own switch. It owns:
// - pipe (42), dup (41), dup2 (90), the socket calls (§6 item 3), lseek
//   (199), pwrite (154), unlink (10) / unlinkat (472, without
//   AT_REMOVEDIR), chdir (12) / fchdir (13) / __pthread_chdir (348) /
//   __pthread_fchdir (349);
// - read/write/readv/writev/pread on object descriptors (pipes, sockets,
//   kqueues), fcntl F_DUPFD / F_DUPFD_CLOEXEC / F_SETFL / F_SETNOSIGPIPE /
//   F_GETNOSIGPIPE, ioctl FIONBIO / FIONREAD / FIOASYNC / FIOCLEX / FIONCLEX
//   on objects (FIOCLEX/FIONCLEX on any descriptor);
// - sendto (133) on any descriptor: a non-socket keeps stage 4a's behavior
//   (the text is logged, ENOTSOCK), which `hello` relies on.
// Everything else (close, fstat, F_GETFL, …) stays with `bsdCall`, which
// reaches the shared open file descriptions through `DarwinFileSystem`.

/// A descriptor object with kernel behavior (readiness for kevent/select).
/// Contract-pinned.
public protocol KernelDescriptorObject: DarwinDescriptorObject {
    /// EVFILT_READ state: readable now, the `data` value, and EOF.
    func readReadiness() -> (ready: Bool, data: Int64, eof: Bool)
    /// EVFILT_WRITE state.
    func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool)
    /// Calls `observer` (lock held) whenever readiness may have changed,
    /// until `removeReadinessObserver(token)`.
    func addReadinessObserver(_ observer: @escaping () -> Void) -> Int
    func removeReadinessObserver(_ token: Int)
}

/// BSD numbers the descriptor layer handles.
enum DescriptorBSD {
    static let read = 3, write = 4, unlink = 10, chdir = 12, fchdir = 13, recvmsg = 27, sendmsg = 28,
               recvfrom = 29, accept = 30, getpeername = 31, getsockname = 32, dup = 41, pipe = 42, ioctl = 54,
               dup2 = 90, fcntl = 92, socket = 97, connect = 98, bind = 104, setsockopt = 105, listen = 106,
               getsockopt = 118, readv = 120, writev = 121, sendto = 133, shutdown = 134, socketpair = 135,
               pread = 153, pwrite = 154, lseek = 199, pthreadChdir = 348, pthreadFchdir = 349, unlinkat = 472,
               readlink = 58, readlinkat = 473, mkdir = 136, rmdir = 137, mkdirat = 475,
               guardedOpen = 441, guardedClose = 442, guardedKqueue = 443, changeFdguard = 444,
               guardedOpenDprotected = 484, guardedWrite = 485, guardedPwrite = 486, guardedWritev = 487,
               flock = 131, fsync = 95, fdatasync = 187,
               connectx = 447, disconnectx = 448, socketDelegate = 450, recvmsgX = 480, sendmsgX = 481
    /// `_nocancel` forms → the plain call (those `DarwinKernel.BSD.nocancelAliases` may not list).
    static let nocancel: [Int: Int] = [
        396: read, 397: write, 401: recvmsg, 402: sendmsg, 403: recvfrom, 404: accept, 409: connect,
        411: readv, 412: writev, 413: sendto, 414: pread, 415: pwrite, 406: fcntl, 408: fsync,
    ]
}

/// fcntl and ioctl values (Darwin `sys/fcntl.h`, `sys/filio.h`).
enum DescriptorControl {
    static let dupfd: Int32 = 0, setfl: Int32 = 4, dupfdCloexec: Int32 = 67, setNoSigPipe: Int32 = 73,
               getNoSigPipe: Int32 = 74
    static let fioclex: UInt32 = 0x2000_6601, fionclex: UInt32 = 0x2000_6602, fionread: UInt32 = 0x4004_667F,
               fionbio: UInt32 = 0x8004_667E, fioasync: UInt32 = 0x8004_667D
    /// `unlinkat` flag that makes it `rmdir`.
    static let atRemoveDir: Int32 = 0x80
}

extension DarwinKernel {
    /// BSD calls the descriptor layer owns. nil = not mine.
    func descriptorCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ fallback: inout Int32,
                        _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let n = DescriptorBSD.nocancel[n] ?? n
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        if fileSystem.guardViolation == nil {
            fileSystem.guardViolation = { [weak self] fd, flavor, value in
                self?.log("guard exception: EXC_GUARD on fd \(fd), flavor \(flavor), guard \(hx(value)) "
                    + "(fatal on Darwin; Ycode fails the call with EPERM)")
            }
        }
        switch n {
        case DescriptorBSD.read, DescriptorBSD.write, DescriptorBSD.readv, DescriptorBSD.writev, DescriptorBSD.pread:
            return try objectIO(n, a, &call, mem)

        case DescriptorBSD.pwrite:
            call.set("pwrite(fd=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))")
            guard a[2] <= UInt64(Int32.max), Int64(bitPattern: a[3]) >= 0 else { throw fail(Code.EINVAL) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            // A regular host file: the host write runs without the kernel
            // lock (stage6-contract.md §5.2).
            if let io = try hostFileIO(int(0), writing: true) {
                return .value(UInt64(try writeUnlocked(io, bytes, offset: a[3])))
            }
            return .value(UInt64(try fileSystem.pwrite(int(0), bytes, offset: a[3])))

        case DescriptorBSD.lseek:
            call.set("lseek(fd=\(int(0)), offset=\(Int64(bitPattern: a[1])), whence=\(int(2)))")
            return .value(try lseekCall(int(0), offset: Int64(bitPattern: a[1]), whence: int(2)))

        case DescriptorBSD.pipe:
            call.set("pipe()")
            let (r, w) = try makePipe()
            call += " [read fd \(r), write fd \(w)]"
            return pipeResult(r, w)

        case DescriptorBSD.dup:
            call.set("dup(\(int(0)))")
            return .value(UInt64(try fileSystem.dup(int(0))))

        case DescriptorBSD.dup2:
            call.set("dup2(\(int(0)), \(int(1)))")
            try fileSystem.dup2(int(0), int(1))
            return .value(UInt64(UInt32(bitPattern: int(1))))

        case DescriptorBSD.fcntl:
            return try descriptorFcntl(a, &call, mem)

        case DescriptorBSD.flock:
            return .value(try flockCall(int(0), int(1), &call))

        case let m where MetadataBSD.all.contains(m):
            return try metadataCall(m, a, &call, mem)

        case DescriptorBSD.fsync, DescriptorBSD.fdatasync:
            return .value(try syncCall(n, int(0), &call))

        case DescriptorBSD.ioctl:
            return try descriptorIoctl(a, &call, mem)

        case DescriptorBSD.unlink:
            let path = try readPath(a[0], mem)
            call.set("unlink(\"\(path)\")")
            try unlinkUnlocked(path)
            return .value(0)

        case DescriptorBSD.unlinkat:
            let path = try resolveAtPath(int(0), a[1], mem)
            call.set("unlinkat(\(int(0)), \"\(path)\", flag=\(hx(a[2])))")
            if int(2) & DescriptorControl.atRemoveDir != 0 {
                try hostFileSystemUnlocked { try $0.rmdir(path) }
            } else {
                try unlinkUnlocked(path)
            }
            return .value(0)

        case DescriptorBSD.mkdir, DescriptorBSD.mkdirat:
            return .value(try mkdirCall(n, a, &call, mem))

        case DescriptorBSD.rmdir:
            let path = try readPath(a[0], mem)
            call.set("rmdir(\"\(path)\")")
            try hostFileSystemUnlocked { try $0.rmdir(path) }
            return .value(0)

        case DescriptorBSD.guardedOpen, DescriptorBSD.guardedOpenDprotected, DescriptorBSD.guardedClose,
             DescriptorBSD.guardedKqueue, DescriptorBSD.changeFdguard, DescriptorBSD.guardedWrite,
             DescriptorBSD.guardedPwrite, DescriptorBSD.guardedWritev:
            return try guardedCall(n, a, &call, mem)

        case DescriptorBSD.readlink, DescriptorBSD.readlinkat:
            return .value(try readlinkCall(n, a, &call, mem))

        case DescriptorBSD.chdir, DescriptorBSD.pthreadChdir:
            let path = try readPath(a[0], mem)
            call.set("\(n == DescriptorBSD.chdir ? "chdir" : "__pthread_chdir")(\"\(path)\")")
            // The per-thread cwd of __pthread_chdir is approximated by the
            // process cwd.
            try fileSystem.chdir(path)
            call += " [\(fileSystem.cwd)]"
            return .value(0)

        case DescriptorBSD.fchdir, DescriptorBSD.pthreadFchdir:
            call.set("\(n == DescriptorBSD.fchdir ? "fchdir" : "__pthread_fchdir")(\(int(0)))")
            try fileSystem.fchdir(int(0))
            call += " [\(fileSystem.cwd)]"
            return .value(0)

        case DescriptorBSD.socket, DescriptorBSD.socketpair, DescriptorBSD.bind, DescriptorBSD.listen,
             DescriptorBSD.accept, DescriptorBSD.connect, DescriptorBSD.sendto, DescriptorBSD.recvfrom,
             DescriptorBSD.sendmsg, DescriptorBSD.recvmsg, DescriptorBSD.shutdown, DescriptorBSD.getsockname,
             DescriptorBSD.getpeername, DescriptorBSD.setsockopt, DescriptorBSD.getsockopt:
            return try socketCall(n, a, &call, mem)

        case DescriptorBSD.connectx, DescriptorBSD.disconnectx, DescriptorBSD.socketDelegate, DescriptorBSD.recvmsgX,
             DescriptorBSD.sendmsgX:
            return try extendedSocketCall(n, a, &call, mem)

        default:
            return nil
        }
    }

    /// A path operation that changes only the host file system, run with the
    /// kernel lock released (`stage6-contract.md` §5.2): resolution and the
    /// socket-name table are safe to read without it. With
    /// `YCODE_FS_LOCKED_IO=1` it keeps the lock.
    /// `mkdir`, `mkdirat`: the host directory (without L0; the umask is one
    /// word of the image). Also a BSD fast path (`bsd-locking.md` §12).
    func mkdirCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let isAt = n == DescriptorBSD.mkdirat
        let path = isAt ? try resolveAtPath(Int32(truncatingIfNeeded: a[0]), a[1], mem) : try readPath(a[0], mem)
        let mode = UInt16(truncatingIfNeeded: isAt ? a[2] : a[1])
        call.set(isAt ? "mkdirat(\(Int32(truncatingIfNeeded: a[0])), \"\(path)\", mode=0o\(String(mode & 0o7777, radix: 8)))"
            : "mkdir(\"\(path)\", mode=0o\(String(mode & 0o7777, radix: 8)))")
        let umask = extended.umask
        try hostFileSystemUnlocked { try $0.mkdir(path, mode: mode, umask: umask) }
        return 0
    }

    /// `readlink`, `readlinkat`: the host link (path resolution needs no
    /// lock). Also a BSD fast path (`bsd-locking.md` §12).
    func readlinkCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> UInt64 {
        let isAt = n == DescriptorBSD.readlinkat
        let path = isAt ? try resolveAtPath(Int32(truncatingIfNeeded: a[0]), a[1], mem) : try readPath(a[0], mem)
        let (buffer, size) = isAt ? (a[2], a[3]) : (a[1], a[2])
        call.set(isAt ? "readlinkat(\(Int32(truncatingIfNeeded: a[0])), \"\(path)\", buf=\(hx(buffer)), bufsize=\(size))"
            : "readlink(\"\(path)\", buf=\(hx(buffer)), bufsize=\(size))")
        let target = Array(try fileSystem.readlink(path).utf8)
        // No NUL; silently truncated to the buffer (POSIX).
        let n = min(target.count, Int(min(size, UInt64(Int32.max))))
        if n > 0 { try mem.write(va: buffer, bytes: Array(target.prefix(n))) }
        call += " [\(String(decoding: target, as: UTF8.self))]"
        return UInt64(n)
    }

    func hostFileSystemUnlocked(_ body: (DarwinFileSystem) throws -> Void) throws {
        let fs = fileSystem
        if Self.lockedFileIO { return try body(fs) }
        try lock.unlocked { try body(fs) }
    }

    /// `unlink`: a host file without the kernel lock; a socket file (the
    /// guest's own name table) with it.
    func unlinkUnlocked(_ path: String) throws {
        let fs = fileSystem
        let done = Self.lockedFileIO ? false : try lock.unlocked { try fs.unlinkHostFile(path) }
        if !done { try fs.unlink(path) }
    }

    /// `lseek`: checked with the kernel lock; the offset moves at once
    /// unless a transfer on the same description holds its offset lock,
    /// which is then waited for without the kernel lock (§5.2).
    func lseekCall(_ fd: Int32, offset: Int64, whence: Int32) throws -> UInt64 {
        let target = try fileSystem.lseekTarget(fd)
        if let moved = try target.seek(offset: offset, whence: whence, wait: false) { return moved }
        return try lock.unlocked { try target.seek(offset: offset, whence: whence)! }
    }

    /// `pipe` returns the read end in x0 and the write end in x1 (Ycode's
    /// libsystem_kernel `pipe` stores w0/w1 into fds[]).
    func pipeResult(_ r: Int32, _ w: Int32) -> BSDResult {
        .values(UInt64(UInt32(bitPattern: r)), UInt64(UInt32(bitPattern: w)))
    }

    // MARK: read / write on objects

    /// read, write, readv, writev, pread on an object descriptor; nil for
    /// host files, the console, and closed descriptors (bsdCall's paths).
    private func objectIO(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let fd = Int32(truncatingIfNeeded: a[0])
        // Device nodes are served by the file system itself (bsdCall's paths).
        guard let file = try? fileSystem.openFile(for: fd), let object = file.object,
              !(object is DarwinDevice) else { return nil }
        switch n {
        case DescriptorBSD.pread:
            call.set("pread(fd=\(fd), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))")
            throw fail(Code.ESPIPE)
        case DescriptorBSD.read:
            call.set("read(fd=\(fd), buf=\(hx(a[1])), len=\(hx(a[2])))")
            guard file.isReadable else { throw fail(Code.EBADF) }
            let bytes = try objectRead(object, file, count: Int(min(a[2], UInt64(Int32.max))))
            if !bytes.isEmpty { try mem.write(va: a[1], bytes: bytes) }
            return .value(UInt64(bytes.count))
        case DescriptorBSD.write:
            call.set("write(fd=\(fd), buf=\(hx(a[1])), len=\(hx(a[2])))")
            try fileSystem.checkGuard(fd, DarwinGuard.write, flavor: DarwinGuard.exceptionWrite)
            guard file.isWritable else { throw fail(Code.EBADF) }
            guard a[2] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return .value(UInt64(try objectWrite(object, file, bytes)))
        default:
            let isWrite = n == DescriptorBSD.writev
            call.set("\(isWrite ? "writev" : "readv")(fd=\(fd), iov=\(hx(a[1])), iovcnt=\(Int32(truncatingIfNeeded: a[2])))")
            let iov = try readIOVec(a[1], count: Int32(truncatingIfNeeded: a[2]), mem, limitError: Code.EINVAL)
            if isWrite {
                try fileSystem.checkGuard(fd, DarwinGuard.write, flavor: DarwinGuard.exceptionWrite)
                guard file.isWritable else { throw fail(Code.EBADF) }
                return .value(UInt64(try objectWrite(object, file, try gather(iov, mem))))
            }
            guard file.isReadable else { throw fail(Code.EBADF) }
            let bytes = try objectRead(object, file, count: iov.reduce(0) { $0 + Int($1.length) })
            try scatter(bytes, into: iov, mem)
            return .value(UInt64(bytes.count))
        }
    }

    func objectRead(_ object: any DarwinDescriptorObject, _ file: DarwinOpenFile, count: Int) throws -> [UInt8] {
        switch object {
        case let p as PipeEnd:
            return try pipeRead(p, file, count: count)
        case let s as UnixSocket:
            guard count > 0 else { return [] }
            // A plain read discards rights that arrive with the data.
            return try socketReceive(s, file, max: count, flags: 0).bytes
        case let s as InetSocket:
            guard count > 0 else { return [] }
            return try inetReceive(s, file, max: count, flags: 0, controlRoom: 0).bytes
        case let s as RouteSocket:
            return Array(try routeRead(s, file, flags: 0).prefix(count))
        case let s as KernelControlSocket:
            return Array(try kernelControlRead(s, file, flags: 0).prefix(count))
        default:
            throw fail(Code.ENXIO)
        }
    }

    func objectWrite(_ object: any DarwinDescriptorObject, _ file: DarwinOpenFile, _ bytes: [UInt8]) throws -> Int {
        switch object {
        case let p as PipeEnd:
            return try pipeWrite(p, file, bytes)
        case let s as UnixSocket:
            return try socketSend(s, file, bytes, rights: nil, to: nil, flags: 0)
        case let s as InetSocket:
            return try inetSend(s, file, bytes, to: nil, control: [], flags: 0)
        case let s as RouteSocket:
            return try routeWrite(s, bytes)
        case let s as KernelControlSocket:
            return try kernelControlWrite(s, bytes)
        default:
            throw fail(Code.ENXIO)
        }
    }

    /// A guest `struct iovec` array (16 bytes each). `count` outside
    /// 1…1024 (UIO_MAXIOV) is `limitError`; a total above INT_MAX is EINVAL.
    func readIOVec(_ va: UInt64, count: Int32, _ mem: any KernelGuestMemory,
                   limitError: Int32) throws -> [(base: UInt64, length: UInt64)] {
        guard count > 0, count <= 1024 else { throw fail(limitError) }
        let raw = try mem.read(va: va, count: 16 * Int(count))
        var iov: [(base: UInt64, length: UInt64)] = []
        var total: UInt64 = 0
        for i in 0..<Int(count) {
            let base = raw.readLE(UInt64.self, at: 16 * i), length = raw.readLE(UInt64.self, at: 16 * i + 8)
            total += length
            guard total <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
            iov.append((base, length))
        }
        return iov
    }

    func gather(_ iov: [(base: UInt64, length: UInt64)], _ mem: any KernelGuestMemory) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for v in iov where v.length > 0 { bytes += try mem.read(va: v.base, count: Int(v.length)) }
        return bytes
    }

    func scatter(_ bytes: [UInt8], into iov: [(base: UInt64, length: UInt64)], _ mem: any KernelGuestMemory) throws {
        var offset = 0
        for v in iov where offset < bytes.count && v.length > 0 {
            let n = min(Int(v.length), bytes.count - offset)
            try mem.write(va: v.base, bytes: Array(bytes[offset..<(offset + n)]))
            offset += n
        }
    }

    // MARK: fcntl / ioctl

    /// The fcntl commands this layer owns; nil for the rest.
    private func descriptorFcntl(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let fd = Int32(truncatingIfNeeded: a[0])
        let cmd = Int32(truncatingIfNeeded: a[1])
        let arg = Int32(truncatingIfNeeded: a[2])
        switch cmd {
        case let c where FileLockControl.commands.contains(c):
            return .value(try fileLockFcntl(fd, cmd, a[2], &call, mem))
        case DescriptorControl.dupfd, DescriptorControl.dupfdCloexec:
            let cloexec = cmd == DescriptorControl.dupfdCloexec
            call.set("fcntl(fd=\(fd), \(cloexec ? "F_DUPFD_CLOEXEC" : "F_DUPFD"), arg=\(arg))")
            _ = try fileSystem.openFile(for: fd)  // EBADF first
            return .value(UInt64(try fileSystem.dup(fd, minimum: arg, closeOnExec: cloexec)))
        case DescriptorControl.setfl:
            call.set("fcntl(fd=\(fd), F_SETFL, arg=\(hx(UInt32(bitPattern: arg))))")
            try fileSystem.setStatusFlags(fd, arg)
            let file = try fileSystem.openFile(for: fd)
            file.object.map { notifyObjectChanged($0) }
            return .value(0)
        case DescriptorControl.setNoSigPipe:
            call.set("fcntl(fd=\(fd), F_SETNOSIGPIPE, arg=\(arg))")
            try fileSystem.openFile(for: fd).noSigPipe = arg != 0
            return .value(0)
        case DescriptorControl.getNoSigPipe:
            call.set("fcntl(fd=\(fd), F_GETNOSIGPIPE)")
            return .value(try fileSystem.openFile(for: fd).noSigPipe ? 1 : 0)
        default:
            return nil
        }
    }

    /// FIONBIO etc. on objects; FIOCLEX/FIONCLEX on any descriptor. nil for
    /// the rest (bsdCall answers ENOTTY).
    private func descriptorIoctl(_ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let fd = Int32(truncatingIfNeeded: a[0])
        let request = UInt32(truncatingIfNeeded: a[1])
        switch request {
        case DescriptorControl.fioclex, DescriptorControl.fionclex:
            call.set("ioctl(fd=\(fd), \(request == DescriptorControl.fioclex ? "FIOCLEX" : "FIONCLEX"))")
            try fileSystem.setCloseOnExec(fd, request == DescriptorControl.fioclex)
            return .value(0)
        case DescriptorControl.fionbio, DescriptorControl.fionread, DescriptorControl.fioasync:
            guard let file = try? fileSystem.openFile(for: fd), let object = file.object else { return nil }
            switch request {
            case DescriptorControl.fionread:
                call.set("ioctl(fd=\(fd), FIONREAD, arg=\(hx(a[2])))")
                let n = (object as? KernelDescriptorObject)?.readReadiness().data ?? 0
                let value: Int64 = (object as? UnixSocket)?.isListening == true
                    || (object as? InetSocket)?.state == .listening ? 0 : n
                try writeU32(a[2], UInt32(truncatingIfNeeded: value), mem)
            default:
                let on = try mem.read(va: a[2], count: 4).readLE(Int32.self, at: 0) != 0
                let flag = request == DescriptorControl.fionbio ? DarwinOpen.O_NONBLOCK : DarwinOpen.O_ASYNC
                call.set("ioctl(fd=\(fd), \(request == DescriptorControl.fionbio ? "FIONBIO" : "FIOASYNC"), \(on ? 1 : 0))")
                file.statusFlags = on ? file.statusFlags | flag : file.statusFlags & ~flag
                notifyObjectChanged(object)
            }
            return .value(0)
        default:
            return try interfaceIoctl(fd, request, a, &call, mem)
        }
    }

    /// The interface ioctls (group 'i', `NetworkInterfaces.ioctl`) and
    /// SIOCATMARK on a socket; nil for any other request or descriptor.
    private func interfaceIoctl(_ fd: Int32, _ request: UInt32, _ a: [UInt64], _ call: inout CallText,
                                _ mem: any KernelGuestMemory) throws -> BSDResult? {
        guard let file = try? fileSystem.openFile(for: fd),
              file.object is InetSocket || file.object is UnixSocket || file.object is RouteSocket
                  || file.object is KernelControlSocket else {
            return nil
        }
        if request == KernelControlSocket.ctliocginfo, file.object is KernelControlSocket {
            call.set("ioctl(fd=\(fd), CTLIOCGINFO, arg=\(hx(a[2])))")
            return try kernelControlInfo(a, mem)
        }
        if request == 0x4004_7307 {  // SIOCATMARK
            call.set("ioctl(fd=\(fd), SIOCATMARK, arg=\(hx(a[2])))")
            let mark = (file.object as? InetSocket).map { $0.hostFD >= 0 ? HostSocketCalls.atMark($0.hostFD) : 0 } ?? 0
            try writeU32(a[2], UInt32(bitPattern: mark), mem)
            return .value(0)
        }
        let size = Int((request >> 16) & 0x1FFF)
        guard (request >> 8) & 0xFF == 0x69, size >= 12 else { return nil }
        call.set("ioctl(fd=\(fd), \(hx(request)), arg=\(hx(a[2])))")
        let argument = try mem.read(va: a[2], count: size)
        switch NetworkInterfaces.ioctl(request, argument: argument) {
        case let .reply(bytes):
            try mem.write(va: a[2], bytes: bytes)
            return .value(0)
        case let .failure(e):
            call += " [\(String(decoding: argument.prefix(16).prefix { $0 != 0 }, as: UTF8.self))]"
            throw fail(e)
        case let .configuration(entries):
            // struct ifconf (packed): int ifc_len; caddr_t ifc_buf.
            let room = Int(argument.readLE(Int32.self, at: 0)), buffer = argument.readLE(UInt64.self, at: 4)
            var out: [UInt8] = []
            for e in entries where out.count + e.count <= room || buffer == 0 { out += e }
            if buffer != 0, !out.isEmpty { try mem.write(va: buffer, bytes: out) }
            try writeU32(a[2], UInt32(out.count), mem)
            return .value(0)
        case .notMine:
            return nil
        }
    }

    /// Readiness of `object` may have changed (a flag change): wake waiters
    /// and observers.
    func notifyObjectChanged(_ object: any DarwinDescriptorObject) {
        switch object {
        case let p as PipeEnd: p.pipe.changed()
        case let s as UnixSocket: s.signals.fire()
        case let s as InetSocket: s.signals.fire()
        case let s as RouteSocket: s.signals.fire()
        case let s as KernelControlSocket: s.signals.fire()
        default: break
        }
    }
}

/// Device nodes are always ready (`/dev/null` reads at end of file at once).
extension DarwinDevice: KernelDescriptorObject {
    public func readReadiness() -> (ready: Bool, data: Int64, eof: Bool) {
        kind == .null ? (true, 0, true) : (true, 65536, false)
    }

    public func writeReadiness() -> (ready: Bool, data: Int64, eof: Bool) { (true, 65536, false) }
    public func addReadinessObserver(_ observer: @escaping () -> Void) -> Int { 0 }
    public func removeReadinessObserver(_ token: Int) {}
}

// MARK: - Guarded descriptors

extension DarwinKernel {
    /// The guarded-descriptor calls (xnu `kern_guarded.c`, Apple open
    /// source): guarded_open_np (441), guarded_open_dprotected_np (484),
    /// guarded_close_np (442), guarded_kqueue_np (443), change_fdguard_np
    /// (444), guarded_write_np / pwrite / writev (485–487). The guard rules
    /// themselves (close, dup, F_SETFD, SCM_RIGHTS, write) live in
    /// `DarwinFileSystem.checkGuard`; a violation fails with EPERM and is
    /// logged (Darwin would also end the process with EXC_GUARD).
    func guardedCall(_ n: Int, _ a: [UInt64], _ call: inout CallText, _ mem: any KernelGuestMemory) throws -> BSDResult {
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        func u32(_ i: Int) -> UInt32 { UInt32(truncatingIfNeeded: a[i]) }
        switch n {
        case DescriptorBSD.guardedOpen, DescriptorBSD.guardedOpenDprotected:
            let path = try readPath(a[0], mem)
            let flags = int(3)
            let mode = UInt16(truncatingIfNeeded: n == DescriptorBSD.guardedOpen ? a[4] : a[6])
            call.set("\(n == DescriptorBSD.guardedOpen ? "guarded_open_np" : "guarded_open_dprotected_np")(\"\(path)\", "
                + "guard=\(hx(a[1])), guardflags=\(hx(u32(2))), flags=\(openFlagsText(flags)), mode=0o\(String(mode & 0o7777, radix: 8)))")
            guard flags & DarwinOpen.O_CLOEXEC != 0, DarwinGuard.isValid(u32(2)) else { throw fail(Code.EINVAL) }
            if n == DescriptorBSD.guardedOpenDprotected { try checkDataProtectionOpen(flags: flags, dpflags: int(5)) }
            let created = n == DescriptorBSD.guardedOpenDprotected && (try? fileSystem.stat(path, followSymlinks: true)) == nil
            let value = try readU64(a[1], mem)
            let fd = try fileSystem.openGuarded(path, flags: flags, mode: mode & ~extended.umask, guard: value,
                                                guardFlags: u32(2))
            if created { noteCreatedWithClass(fd, int(4)) }
            call += " [fd \(fd)]"
            return .value(UInt64(fd))

        case DescriptorBSD.guardedClose:
            call.set("guarded_close_np(\(int(0)), guard=\(hx(a[1])))")
            let value = try readU64(a[1], mem)
            try fileSystem.guardedClose(int(0), guard: value)
            return .value(0)

        case DescriptorBSD.guardedKqueue:
            call.set("guarded_kqueue_np(guard=\(hx(a[0])), guardflags=\(hx(u32(1))))")
            guard DarwinGuard.isValid(u32(1)) else { throw fail(Code.EINVAL) }
            let value = try readU64(a[0], mem)
            guard value != 0 else { throw fail(Code.EINVAL) }
            var inner = CallText(call.enabled)
            let fd = Int32(truncatingIfNeeded: try withEvents { try kqueueCall(&inner) })
            try fileSystem.setGuard(fd, DescriptorGuard(value: value, flags: u32(1)))
            call += " [kqueue fd \(fd)]"
            return .value(UInt64(fd))

        case DescriptorBSD.changeFdguard:
            call.set("change_fdguard_np(\(int(0)), guard=\(hx(a[1])), guardflags=\(hx(u32(2))), nguard=\(hx(a[3])), "
                + "nguardflags=\(hx(u32(4))), fdflagsp=\(hx(a[5])))")
            let old = a[1] == 0 ? nil : try readU64(a[1], mem)
            let new = a[3] == 0 ? nil : try readU64(a[3], mem)
            let fdFlags = a[5] == 0 ? 0 : Int32(bitPattern: try mem.read(va: a[5], count: 4).readLE(UInt32.self, at: 0))
            // The previous fd flags go out first, as in xnu (FD_CLOEXEC only;
            // Ycode has no FD_CLOFORK).
            if a[5] != 0 { try writeU32(a[5], try fileSystem.closeOnExec(int(0)) ? 1 : 0, mem) }
            try fileSystem.changeGuard(int(0), old: old, oldFlags: u32(2), new: new, newFlags: u32(4), fdFlags: fdFlags)
            return .value(0)

        default:
            let fd = int(0)
            let value = try readU64(a[1], mem)
            let file = try fileSystem.openFile(for: fd)
            try fileSystem.checkGuardValue(fd, value)
            guard file.isWritable else { throw fail(Code.EBADF) }
            let bytes: [UInt8]
            switch n {
            case DescriptorBSD.guardedWritev:
                call.set("guarded_writev_np(\(fd), guard=\(hx(a[1])), iov=\(hx(a[2])), iovcnt=\(int(3)))")
                bytes = try gather(try readIOVec(a[2], count: int(3), mem, limitError: Code.EINVAL), mem)
            default:
                call.set(n == DescriptorBSD.guardedWrite
                    ? "guarded_write_np(\(fd), guard=\(hx(a[1])), buf=\(hx(a[2])), nbyte=\(hx(a[3])))"
                    : "guarded_pwrite_np(\(fd), guard=\(hx(a[1])), buf=\(hx(a[2])), nbyte=\(hx(a[3])), offset=\(hx(a[4])))")
                guard a[3] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
                bytes = a[3] == 0 ? [] : try mem.read(va: a[2], count: Int(a[3]))
            }
            if n == DescriptorBSD.guardedPwrite {
                guard Int64(bitPattern: a[4]) >= 0 else { throw fail(Code.EINVAL) }
                if let io = try hostFileIO(fd, writing: true, guardChecked: true) {
                    return .value(UInt64(try writeUnlocked(io, bytes, offset: a[4])))
                }
                return .value(UInt64(try fileSystem.pwrite(fd, bytes, offset: a[4], guardChecked: true)))
            }
            // A regular host file: the host write runs without the kernel
            // lock (§5.2).
            if let io = try hostFileIO(fd, writing: true, guardChecked: true) {
                return .value(UInt64(try writeUnlocked(io, bytes, offset: nil)))
            }
            if let object = file.object, !(object is DarwinDevice) {
                return .value(UInt64(try objectWrite(object, file, bytes)))
            }
            return .value(UInt64(try fileSystem.write(fd, bytes, guardChecked: true)))
        }
    }
}
