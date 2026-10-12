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
               readlink = 58, readlinkat = 473
    /// `_nocancel` forms → the plain call (those `DarwinKernel.BSD.nocancelAliases` may not list).
    static let nocancel: [Int: Int] = [
        396: read, 397: write, 401: recvmsg, 402: sendmsg, 403: recvfrom, 404: accept, 409: connect,
        411: readv, 412: writev, 413: sendto, 414: pread, 415: pwrite, 406: fcntl,
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
    func descriptorCall(_ n: Int, _ a: [UInt64], _ call: inout String, _ fallback: inout Int32,
                        _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let n = DescriptorBSD.nocancel[n] ?? n
        func int(_ i: Int) -> Int32 { Int32(truncatingIfNeeded: a[i]) }
        switch n {
        case DescriptorBSD.read, DescriptorBSD.write, DescriptorBSD.readv, DescriptorBSD.writev, DescriptorBSD.pread:
            return try objectIO(n, a, &call, mem)

        case DescriptorBSD.pwrite:
            call = "pwrite(fd=\(int(0)), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))"
            guard a[2] <= UInt64(Int32.max), Int64(bitPattern: a[3]) >= 0 else { throw fail(Code.EINVAL) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return .value(UInt64(try fileSystem.pwrite(int(0), bytes, offset: a[3])))

        case DescriptorBSD.lseek:
            call = "lseek(fd=\(int(0)), offset=\(Int64(bitPattern: a[1])), whence=\(int(2)))"
            return .value(try fileSystem.lseek(int(0), offset: Int64(bitPattern: a[1]), whence: int(2)))

        case DescriptorBSD.pipe:
            call = "pipe()"
            let (r, w) = try makePipe()
            call += " [read fd \(r), write fd \(w)]"
            return pipeResult(r, w)

        case DescriptorBSD.dup:
            call = "dup(\(int(0)))"
            return .value(UInt64(try fileSystem.dup(int(0))))

        case DescriptorBSD.dup2:
            call = "dup2(\(int(0)), \(int(1)))"
            try fileSystem.dup2(int(0), int(1))
            return .value(UInt64(UInt32(bitPattern: int(1))))

        case DescriptorBSD.fcntl:
            return try descriptorFcntl(a, &call)

        case DescriptorBSD.ioctl:
            return try descriptorIoctl(a, &call, mem)

        case DescriptorBSD.unlink:
            let path = try readPath(a[0], mem)
            call = "unlink(\"\(path)\")"
            try fileSystem.unlink(path)
            return .value(0)

        case DescriptorBSD.unlinkat:
            guard int(2) & DescriptorControl.atRemoveDir == 0 else { return nil }
            let path = try resolveAtPath(int(0), a[1], mem)
            call = "unlinkat(\(int(0)), \"\(path)\", flag=\(hx(a[2])))"
            try fileSystem.unlink(path)
            return .value(0)

        case DescriptorBSD.readlink, DescriptorBSD.readlinkat:
            let isAt = n == DescriptorBSD.readlinkat
            let path = isAt ? try resolveAtPath(int(0), a[1], mem) : try readPath(a[0], mem)
            let (buffer, size) = isAt ? (a[2], a[3]) : (a[1], a[2])
            call = isAt ? "readlinkat(\(int(0)), \"\(path)\", buf=\(hx(buffer)), bufsize=\(size))"
                : "readlink(\"\(path)\", buf=\(hx(buffer)), bufsize=\(size))"
            let target = Array(try fileSystem.readlink(path).utf8)
            // No NUL; silently truncated to the buffer (POSIX).
            let n = min(target.count, Int(min(size, UInt64(Int32.max))))
            if n > 0 { try mem.write(va: buffer, bytes: Array(target.prefix(n))) }
            call += " [\(String(decoding: target, as: UTF8.self))]"
            return .value(UInt64(n))

        case DescriptorBSD.chdir, DescriptorBSD.pthreadChdir:
            let path = try readPath(a[0], mem)
            call = "\(n == DescriptorBSD.chdir ? "chdir" : "__pthread_chdir")(\"\(path)\")"
            // The per-thread cwd of __pthread_chdir is approximated by the
            // process cwd.
            try fileSystem.chdir(path)
            call += " [\(fileSystem.cwd)]"
            return .value(0)

        case DescriptorBSD.fchdir, DescriptorBSD.pthreadFchdir:
            call = "\(n == DescriptorBSD.fchdir ? "fchdir" : "__pthread_fchdir")(\(int(0)))"
            try fileSystem.fchdir(int(0))
            call += " [\(fileSystem.cwd)]"
            return .value(0)

        case DescriptorBSD.socket, DescriptorBSD.socketpair, DescriptorBSD.bind, DescriptorBSD.listen,
             DescriptorBSD.accept, DescriptorBSD.connect, DescriptorBSD.sendto, DescriptorBSD.recvfrom,
             DescriptorBSD.sendmsg, DescriptorBSD.recvmsg, DescriptorBSD.shutdown, DescriptorBSD.getsockname,
             DescriptorBSD.getpeername, DescriptorBSD.setsockopt, DescriptorBSD.getsockopt:
            return try socketCall(n, a, &call, mem)

        default:
            return nil
        }
    }

    /// `pipe` returns the read end in x0 and the write end in x1 (Ycode's
    /// libsystem_kernel `pipe` stores w0/w1 into fds[]).
    func pipeResult(_ r: Int32, _ w: Int32) -> BSDResult {
        .values(UInt64(UInt32(bitPattern: r)), UInt64(UInt32(bitPattern: w)))
    }

    // MARK: read / write on objects

    /// read, write, readv, writev, pread on an object descriptor; nil for
    /// host files, the console, and closed descriptors (bsdCall's paths).
    private func objectIO(_ n: Int, _ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let fd = Int32(truncatingIfNeeded: a[0])
        // Device nodes are served by the file system itself (bsdCall's paths).
        guard let file = try? fileSystem.openFile(for: fd), let object = file.object,
              !(object is DarwinDevice) else { return nil }
        switch n {
        case DescriptorBSD.pread:
            call = "pread(fd=\(fd), buf=\(hx(a[1])), len=\(hx(a[2])), off=\(hx(a[3])))"
            throw fail(Code.ESPIPE)
        case DescriptorBSD.read:
            call = "read(fd=\(fd), buf=\(hx(a[1])), len=\(hx(a[2])))"
            guard file.isReadable else { throw fail(Code.EBADF) }
            let bytes = try objectRead(object, file, count: Int(min(a[2], UInt64(Int32.max))))
            if !bytes.isEmpty { try mem.write(va: a[1], bytes: bytes) }
            return .value(UInt64(bytes.count))
        case DescriptorBSD.write:
            call = "write(fd=\(fd), buf=\(hx(a[1])), len=\(hx(a[2])))"
            guard file.isWritable else { throw fail(Code.EBADF) }
            guard a[2] <= UInt64(Int32.max) else { throw fail(Code.EINVAL) }
            let bytes = a[2] == 0 ? [] : try mem.read(va: a[1], count: Int(a[2]))
            return .value(UInt64(try objectWrite(object, file, bytes)))
        default:
            let isWrite = n == DescriptorBSD.writev
            call = "\(isWrite ? "writev" : "readv")(fd=\(fd), iov=\(hx(a[1])), iovcnt=\(Int32(truncatingIfNeeded: a[2])))"
            let iov = try readIOVec(a[1], count: Int32(truncatingIfNeeded: a[2]), mem, limitError: Code.EINVAL)
            if isWrite {
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
    private func descriptorFcntl(_ a: [UInt64], _ call: inout String) throws -> BSDResult? {
        let fd = Int32(truncatingIfNeeded: a[0])
        let cmd = Int32(truncatingIfNeeded: a[1])
        let arg = Int32(truncatingIfNeeded: a[2])
        switch cmd {
        case DescriptorControl.dupfd, DescriptorControl.dupfdCloexec:
            let cloexec = cmd == DescriptorControl.dupfdCloexec
            call = "fcntl(fd=\(fd), \(cloexec ? "F_DUPFD_CLOEXEC" : "F_DUPFD"), arg=\(arg))"
            _ = try fileSystem.openFile(for: fd)  // EBADF first
            return .value(UInt64(try fileSystem.dup(fd, minimum: arg, closeOnExec: cloexec)))
        case DescriptorControl.setfl:
            call = "fcntl(fd=\(fd), F_SETFL, arg=\(hx(UInt32(bitPattern: arg))))"
            try fileSystem.setStatusFlags(fd, arg)
            let file = try fileSystem.openFile(for: fd)
            file.object.map { notifyObjectChanged($0) }
            return .value(0)
        case DescriptorControl.setNoSigPipe:
            call = "fcntl(fd=\(fd), F_SETNOSIGPIPE, arg=\(arg))"
            try fileSystem.openFile(for: fd).noSigPipe = arg != 0
            return .value(0)
        case DescriptorControl.getNoSigPipe:
            call = "fcntl(fd=\(fd), F_GETNOSIGPIPE)"
            return .value(try fileSystem.openFile(for: fd).noSigPipe ? 1 : 0)
        default:
            return nil
        }
    }

    /// FIONBIO etc. on objects; FIOCLEX/FIONCLEX on any descriptor. nil for
    /// the rest (bsdCall answers ENOTTY).
    private func descriptorIoctl(_ a: [UInt64], _ call: inout String, _ mem: any KernelGuestMemory) throws -> BSDResult? {
        let fd = Int32(truncatingIfNeeded: a[0])
        let request = UInt32(truncatingIfNeeded: a[1])
        switch request {
        case DescriptorControl.fioclex, DescriptorControl.fionclex:
            call = "ioctl(fd=\(fd), \(request == DescriptorControl.fioclex ? "FIOCLEX" : "FIONCLEX"))"
            try fileSystem.setCloseOnExec(fd, request == DescriptorControl.fioclex)
            return .value(0)
        case DescriptorControl.fionbio, DescriptorControl.fionread, DescriptorControl.fioasync:
            guard let file = try? fileSystem.openFile(for: fd), let object = file.object else { return nil }
            switch request {
            case DescriptorControl.fionread:
                call = "ioctl(fd=\(fd), FIONREAD, arg=\(hx(a[2])))"
                let n = (object as? KernelDescriptorObject)?.readReadiness().data ?? 0
                let value: Int64 = (object as? UnixSocket)?.isListening == true ? 0 : n
                try writeU32(a[2], UInt32(truncatingIfNeeded: value), mem)
            default:
                let on = try mem.read(va: a[2], count: 4).readLE(Int32.self, at: 0) != 0
                let flag = request == DescriptorControl.fionbio ? DarwinOpen.O_NONBLOCK : DarwinOpen.O_ASYNC
                call = "ioctl(fd=\(fd), \(request == DescriptorControl.fionbio ? "FIONBIO" : "FIOASYNC"), \(on ? 1 : 0))"
                file.statusFlags = on ? file.statusFlags | flag : file.statusFlags & ~flag
                notifyObjectChanged(object)
            }
            return .value(0)
        default:
            return nil
        }
    }

    /// Readiness of `object` may have changed (a flag change): wake waiters
    /// and observers.
    func notifyObjectChanged(_ object: any DarwinDescriptorObject) {
        switch object {
        case let p as PipeEnd: p.pipe.changed()
        case let s as UnixSocket: s.signals.fire()
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
