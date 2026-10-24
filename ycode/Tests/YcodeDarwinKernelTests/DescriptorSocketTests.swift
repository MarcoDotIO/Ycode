import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// Stage 4b AF_UNIX sockets (`specs/simulator/stage4b-contract.md` §6 item 3,
// `processes.md` §5): naming, connection, data, SCM_RIGHTS between two
// processes of one system, peer identity, and the log sink.

/// A Darwin `sockaddr_un` for `path`: 106 bytes (`sizeof`), longer when the
/// path needs it (test directories are long; the kernel takes up to 255).
private func sockaddr(_ path: String) -> [UInt8] {
    let size = max(106, 2 + path.utf8.count + 1)
    var b: [UInt8] = [UInt8(size), 1] + Array(path.utf8)
    b += [UInt8](repeating: 0, count: size - b.count)
    return b
}

/// The length argument for `sockaddr(path)`.
private func socklen(_ path: String) -> UInt64 { UInt64(sockaddr(path).count) }

/// Stands in for a kqueue: confined, so neither inherited nor sendable.
private final class ConfinedObject: DarwinDescriptorObject {
    var fileType: UInt16 { 0 }
    var isConfined: Bool { true }
    func lastReferenceClosed() {}
}

private let addrVA = DEnv.scratch + 0x600
private let lenVA = DEnv.scratch + 0x6F0
private let optVA = DEnv.scratch + 0x700

extension DEnv {
    func socket(_ type: UInt64 = 1) -> Int32 {
        let r = call(97, [1, type, 0])
        precondition(!r.carry, "socket failed: \(r.x0)")
        return r.fd
    }

    @discardableResult
    func bind(_ fd: Int32, _ path: String) -> Result {
        put(sockaddr(path), at: addrVA)
        return call(104, [UInt64(fd), addrVA, socklen(path)])
    }

    @discardableResult
    func connect(_ fd: Int32, _ path: String) -> Result {
        put(sockaddr(path), at: addrVA)
        return call(98, [UInt64(fd), addrVA, socklen(path)])
    }

    func accept(_ fd: Int32) -> Result {
        put([0, 1, 0, 0], at: lenVA)  // room: 256
        return call(30, [UInt64(fd), addrVA, lenVA])
    }

    /// getsockopt(level, name) → (errno, value bytes).
    func getsockopt(_ fd: Int32, _ level: UInt32, _ name: UInt32, room: UInt32 = 128) -> (Int32?, [UInt8]) {
        put([UInt8](repeating: 0xEE, count: Int(room)), at: optVA)
        put([UInt8(room & 0xFF), UInt8(room >> 8), 0, 0], at: lenVA)
        let r = call(118, [UInt64(fd), UInt64(level), UInt64(name), optVA, lenVA])
        if let e = r.errno { return (e, []) }
        return (nil, get(optVA, Int(u32(lenVA))))
    }

    func setsockopt(_ fd: Int32, _ level: UInt32, _ name: UInt32, _ value: Int32) -> Result {
        put(withUnsafeBytes(of: value.littleEndian) { Array($0) }, at: optVA)
        return call(105, [UInt64(fd), UInt64(level), UInt64(name), optVA, 4])
    }

    /// sendmsg with one iovec of `text` and SCM_RIGHTS for `fds`.
    func sendRights(_ fd: Int32, _ text: String, fds: [Int32], flags: UInt64 = 0) -> Result {
        let base = DEnv.scratch + 0x8000
        put(Array(text.utf8), at: base + 0x100)
        put(leBytes(base + 0x100) + leBytes(UInt64(text.utf8.count)), at: base + 0x80)
        var c: [UInt8] = []
        c.appendLE(UInt32(12 + 4 * fds.count))
        c.appendLE(Int32(0xFFFF))
        c.appendLE(Int32(1))
        for f in fds { c.appendLE(f) }
        put(c, at: base + 0x200)
        var h = [UInt8](repeating: 0, count: 48)
        h.putLE(base + 0x80, at: 16)
        h.putLE(Int32(1), at: 24)
        if !fds.isEmpty {
            h.putLE(base + 0x200, at: 32)
            h.putLE(UInt32(c.count), at: 40)
        }
        put(h, at: base)
        return call(28, [UInt64(fd), base, flags])
    }

    /// recvmsg with a 256-byte buffer and `controlRoom` bytes of control.
    func receiveRights(_ fd: Int32, controlRoom: UInt32 = 64, flags: UInt64 = 0, size: UInt64 = 256)
        -> (Result, text: String, fds: [Int32], cmsgLength: UInt32, controlLength: UInt32, flags: Int32) {
        let base = DEnv.scratch + 0x9000
        put(leBytes(base + 0x100) + leBytes(size), at: base + 0x80)
        put([UInt8](repeating: 0xEE, count: 64), at: base + 0x400)
        var h = [UInt8](repeating: 0, count: 48)
        h.putLE(base + 0x80, at: 16)
        h.putLE(Int32(1), at: 24)
        h.putLE(base + 0x400, at: 32)
        h.putLE(controlRoom, at: 40)
        put(h, at: base)
        let r = call(27, [UInt64(fd), base, flags])
        guard let n = r.value else { return (r, "", [], 0, 0, 0) }
        let controlLength = u32(base + 40)
        var fds: [Int32] = []
        var i: UInt64 = 12
        while i + 4 <= UInt64(controlLength) {
            fds.append(i32(base + 0x400 + i))
            i += 4
        }
        return (r, String(decoding: get(base + 0x100, Int(n)), as: UTF8.self), fds,
                controlLength >= 4 ? u32(base + 0x400) : 0, controlLength, i32(base + 44))
    }
}

@Suite(.serialized) struct DescriptorSocketTests {
    @Test func socketDomainsAndTypes() throws {
        let e = try DEnv()
        #expect(e.call(97, [2, 1, 0]).errno == 47)   // AF_INET: EAFNOSUPPORT
        #expect(e.call(97, [30, 2, 0]).errno == 47)  // AF_INET6
        #expect(e.call(97, [1, 5, 0]).errno == 43)   // SEQPACKET: EPROTONOSUPPORT
        #expect(e.call(97, [1, 1, 6]).errno == 43)
        let s = e.socket()
        #expect(e.getsockopt(s, 0xFFFF, 0x1008).1 == [1, 0, 0, 0])  // SO_TYPE
        #expect(e.getsockopt(s, 0xFFFF, 0x1001).1 == [0, 0x20, 0, 0])  // SO_SNDBUF 8192
        #expect(e.call(92, [UInt64(s), 3, 0]).value == 2)  // O_RDWR
        let st = DEnv.scratch + 0x4000
        #expect(e.call(339, [UInt64(s), st]).value == 0)
        #expect(try #require(DarwinStat(decodingStat64: e.get(st, 144))).mode == DarwinStat.S_IFSOCK | 0o666)
        // Not connected.
        #expect(e.write(s, "x").errno == 57)
        #expect(e.read(s).0.errno == 57)
        #expect(e.call(31, [UInt64(s), addrVA, lenVA]).errno == 57)
        #expect(e.call(134, [UInt64(s), 1]).errno == 57)
        // getsockname of an unbound socket: the 16-byte unnamed address.
        e.put([0, 1, 0, 0], at: lenVA)
        #expect(e.call(32, [UInt64(s), addrVA, lenVA]).value == 0)
        #expect(e.u32(lenVA) == 16 && e.get(addrVA, 2) == [16, 1])
        // Non-sockets.
        #expect(e.call(106, [1, 5]).errno == 38)
        #expect(e.call(106, [99, 5]).errno == 9)
    }

    @Test func socketpairStreamAndPeerOptions() throws {
        let e = try DEnv(pid: 123)
        e.put([UInt8](repeating: 0, count: 8), at: DEnv.scratch + 0x100)
        #expect(e.call(135, [1, 1, 0, DEnv.scratch + 0x100]).value == 0)
        let a = e.i32(DEnv.scratch + 0x100), b = e.i32(DEnv.scratch + 0x104)
        #expect(a == 3 && b == 4)
        #expect(e.write(a, "ping").value == 4)
        #expect(e.write(b, "pong").value == 4)
        #expect(e.read(b).1 == "ping")
        #expect(e.read(a).1 == "pong")
        // LOCAL_PEERPID, LOCAL_PEERCRED (xucred: version 0, uid 501, 1 group 20), LOCAL_PEERTOKEN.
        #expect(e.getsockopt(a, 0, 2).1 == [123, 0, 0, 0])
        let cred = e.getsockopt(a, 0, 1, room: 76).1
        #expect(cred.count == 76 && u32(cred, 0) == 0 && u32(cred, 4) == 501 && u16(cred, 8) == 1 && u32(cred, 12) == 20)
        let token = e.getsockopt(a, 0, 6, room: 32).1
        #expect(token.count == 32 && u32(token, 20) == 123)
        #expect(e.getsockopt(a, 0, 9).0 == 102)  // unknown SOL_LOCAL: EOPNOTSUPP
        // Truncated getsockopt copies what fits and reports that.
        #expect(e.getsockopt(a, 0xFFFF, 0x1008, room: 2).1 == [1, 0])
        // shutdown(SHUT_WR): the peer reads EOF, our writes fail.
        e.ignore(13)
        #expect(e.call(134, [UInt64(a), 1]).value == 0)
        #expect(e.read(b).0.value == 0)
        #expect(e.write(a, "x").errno == 32)
        #expect(e.write(b, "still").value == 5)
        #expect(e.read(a).1 == "still")
        // Closing b: a reads EOF.
        e.call(6, [UInt64(b)])
        #expect(e.read(a).0.value == 0)
        #expect(e.getsockopt(a, 0, 2).0 == 57)  // no peer any more
    }

    @Test func soNoSigPipeAndMsgNoSignal() throws {
        let e = try DEnv()
        e.put([UInt8](repeating: 0, count: 8), at: DEnv.scratch + 0x100)
        e.call(135, [1, 1, 0, DEnv.scratch + 0x100])
        let a = e.i32(DEnv.scratch + 0x100), b = e.i32(DEnv.scratch + 0x104)
        e.call(6, [UInt64(b)])
        #expect(e.setsockopt(a, 0xFFFF, 0x1022, 1).value == 0)
        #expect(e.getsockopt(a, 0xFFFF, 0x1022).1 == [1, 0, 0, 0])
        #expect(e.write(a, "x").errno == 32)
        #expect(!e.kernel.isTerminating)
        #expect(e.setsockopt(a, 0xFFFF, 0x1022, 0).value == 0)
        e.put(Array("y".utf8), at: DEnv.scratch + 0x200)
        #expect(e.call(133, [UInt64(a), DEnv.scratch + 0x200, 1, 0x80000, 0, 0]).errno == 32)  // MSG_NOSIGNAL
        #expect(!e.kernel.isTerminating)
        #expect(e.write(a, "z").errno == 32)
        #expect(e.kernel.isTerminating)  // SIGPIPE's default action
    }

    @Test func bindListenConnectAccept() throws {
        let e = try DEnv()
        let path = e.writable + "/srv.sock"
        let l = e.socket()
        #expect(e.call(106, [UInt64(l), 5]).errno == 22)  // listen unbound: EINVAL
        #expect(e.bind(l, path).value == 0)
        #expect(e.bind(l, path).errno == 22)  // already bound
        let other = e.socket()
        #expect(e.bind(other, path).errno == 48)  // EADDRINUSE
        #expect(e.bind(other, e.root + "/ro.sock").errno == 30)  // read-only prefix
        // The socket file is visible: stat says S_IFSOCK with 0777 & ~umask.
        e.putString(path, at: DEnv.scratch + 0x100)
        #expect(e.call(338, [DEnv.scratch + 0x100, DEnv.scratch + 0x4000]).value == 0)
        let st = try #require(DarwinStat(decodingStat64: e.get(DEnv.scratch + 0x4000, 144)))
        #expect(st.mode == DarwinStat.S_IFSOCK | 0o755)
        // Not listening yet: refused.
        let c0 = e.socket()
        #expect(e.connect(c0, path).errno == 61)
        #expect(e.call(106, [UInt64(l), 1]).value == 0)
        // Nonblocking accept with nothing pending.
        e.call(92, [UInt64(l), 4, 4])
        #expect(e.accept(l).errno == 35)
        // backlog 1: 3 × 1 / 2 = 1, so two pending connections, the third is refused at once.
        let c1 = e.socket(), c2 = e.socket(), c3 = e.socket()
        #expect(e.connect(c1, path).value == 0)
        #expect(e.connect(c2, path).value == 0)
        #expect(e.connect(c3, path).errno == 61)
        #expect(e.connect(c1, path).errno == 56)  // EISCONN
        // Data sent before accept waits in the new connection.
        #expect(e.write(c1, "early").value == 5)
        let s1 = e.accept(l)
        #expect(s1.value != nil)
        #expect(e.u32(lenVA) == 16 && e.get(addrVA, 2) == [16, 1])  // the client is unbound
        #expect(e.call(92, [s1.x0, 3, 0]).value == 6)  // O_RDWR | the listener's O_NONBLOCK
        #expect(e.read(s1.fd).1 == "early")
        // getsockname of the accepted socket: the listener's path; getpeername of the client too.
        e.put([0, 1, 0, 0], at: lenVA)
        #expect(e.call(32, [s1.x0, addrVA, lenVA]).value == 0)
        #expect(e.u32(lenVA) == UInt32(socklen(path)) && e.get(addrVA + 2, path.utf8.count) == Array(path.utf8))
        e.put([8, 0, 0, 0], at: lenVA)  // a short buffer: truncated copy, full length reported
        #expect(e.call(31, [UInt64(c1), addrVA, lenVA]).value == 0)
        #expect(e.u32(lenVA) == UInt32(socklen(path)))
        // Wrong type: EPROTOTYPE; missing path: ENOENT; regular file: ENOTSOCK.
        let d = e.socket(2)
        #expect(e.connect(d, path).errno == 41)
        #expect(e.connect(e.socket(), e.writable + "/none").errno == 2)
        try Data("x".utf8).write(to: URL(fileURLWithPath: e.root + "/plain"))
        #expect(e.connect(e.socket(), e.root + "/plain").errno == 38)
        // After the listener closes, the name stays and connect is refused;
        // unlink removes it, then bind works again.
        e.call(6, [UInt64(l)])
        #expect(e.connect(e.socket(), path).errno == 61)
        e.putString(path, at: DEnv.scratch + 0x100)
        #expect(e.call(10, [DEnv.scratch + 0x100]).value == 0)
        #expect(e.connect(e.socket(), path).errno == 2)
        #expect(e.bind(e.socket(), path).value == 0)
        // c2's server side was dropped with the listener: c2 reads EOF.
        #expect(e.read(c2).0.value == 0)
    }

    @Test func datagrams() throws {
        let e = try DEnv()
        let path = e.writable + "/dg.sock"
        let rcv = e.socket(2)
        #expect(e.bind(rcv, path).value == 0)
        let snd = e.socket(2)
        e.put(sockaddr(path), at: addrVA)
        e.put(Array("one".utf8), at: DEnv.scratch + 0x200)
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x200, 3, 0, addrVA, socklen(path)]).value == 3)
        e.put(Array("second".utf8), at: DEnv.scratch + 0x200)
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x200, 6, 0, addrVA, socklen(path)]).value == 6)
        // Boundaries are kept; recvfrom reports the unnamed sender.
        e.put([0, 1, 0, 0], at: lenVA)
        #expect(e.call(29, [UInt64(rcv), DEnv.scratch + 0x300, 100, 0, DEnv.scratch + 0x500, lenVA]).value == 3)
        #expect(e.u32(lenVA) == 16)
        // recvmsg of a datagram longer than the buffer: MSG_TRUNC.
        let r = e.receiveRights(rcv, size: 2)
        #expect(r.0.value == 2 && r.text == "se" && r.flags == 0x10)
        // Too big for the 2048-byte send buffer: EMSGSIZE.
        e.put([UInt8](repeating: 1, count: 3000), at: DEnv.scratch + 0x1000)
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x1000, 2049, 0, addrVA, socklen(path)]).errno == 40)
        // The 4096-byte receive buffer fills: ENOBUFS (no blocking).
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x1000, 2048, 0, addrVA, socklen(path)]).value == 2048)
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x1000, 2048, 0, addrVA, socklen(path)]).value == 2048)
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x1000, 1, 0, addrVA, socklen(path)]).errno == 55)
        // Unconnected send without an address: ENOTCONN. Connected: EISCONN with one.
        #expect(e.write(snd, "x").errno == 57)
        #expect(e.connect(snd, path).value == 0)
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x200, 1, 0, addrVA, socklen(path)]).errno == 56)
        // The receiver closes: the connected sender gets ECONNRESET once, then ENOTCONN.
        e.call(6, [UInt64(rcv)])
        #expect(e.write(snd, "x").errno == 54)
        #expect(e.write(snd, "x").errno == 57)
        // A path with a closed socket: ECONNREFUSED.
        #expect(e.call(133, [UInt64(snd), DEnv.scratch + 0x200, 1, 0, addrVA, socklen(path)]).errno == 61)
    }

    @Test func logSinkPathsLogTheText() throws {
        let e = try DEnv()
        let s = e.socket(2)
        e.put(sockaddr("/var/run/syslog"), at: addrVA)
        e.putString("<13>first message", at: DEnv.scratch + 0x200)
        #expect(e.call(133, [UInt64(s), DEnv.scratch + 0x200, 17, 0, addrVA, socklen("/var/run/syslog")]).value == 17)
        #expect(e.sink.lines.contains("note: sendto message: <13>first message"))
        // connect + send (libc syslog's way).
        #expect(e.connect(s, "/var/run/syslog").value == 0)
        #expect(e.write(s, "<13>second").value == 10)
        #expect(e.sink.lines.contains("note: sendto message: <13>second"))
        // Other missing paths stay ENOENT; streams get no sink.
        #expect(e.connect(e.socket(2), "/var/run/other").errno == 2)
        #expect(e.connect(e.socket(1), "/var/run/syslog").errno == 2)
    }

    @Test func scmRightsBetweenTwoProcesses() throws {
        let parent = try DEnv(pid: 100)
        let path = parent.writable + "/p_unix.sock"
        let l = parent.socket()
        #expect(parent.bind(l, path).value == 0)
        #expect(parent.call(106, [UInt64(l), 5]).value == 0)
        // The child (another image in the same system) inherits the
        // listening descriptor too, like a spawned job.
        let child = try DEnv(parent: parent, pid: 101)
        #expect(try child.kernel.fileSystem.object(for: l) === parent.kernel.fileSystem.object(for: l))
        let c = child.socket()
        #expect(child.connect(c, path).value == 0)
        #expect(child.write(c, "hello parent").value == 12)
        let (pr, pw) = child.pipe()
        #expect(child.write(pw, "through the pipe").value == 16)
        #expect(child.sendRights(c, "!", fds: [pr]).value == 1)
        // The child closes its pipe ends; the passed read end stays alive in the message.
        child.call(6, [UInt64(pr)])
        child.call(6, [UInt64(pw)])

        let s = parent.accept(l)
        #expect(s.value != nil)
        // Peer identity: each side sees the other process.
        #expect(parent.getsockopt(s.fd, 0, 2).1 == [101, 0, 0, 0])
        #expect(child.getsockopt(c, 0, 2).1 == [100, 0, 0, 0])
        let token = parent.getsockopt(s.fd, 0, 6, room: 32).1
        #expect(u32(token, 20) == 101)
        // The text, then (stopping at the rights boundary) the rights message.
        let (_, text) = parent.read(s.fd, 64)
        #expect(text == "hello parent")
        let m = parent.receiveRights(s.fd)
        #expect(m.text == "!" && m.fds.count == 1 && m.cmsgLength == 16 && m.controlLength == 16 && m.flags == 0)
        let got = try #require(m.fds.first)
        #expect(try parent.kernel.fileSystem.object(for: got) is PipeEnd)
        #expect(parent.call(92, [UInt64(got), 1, 0]).value == 0)  // close-on-exec clear
        #expect(parent.read(got, 64).1 == "through the pipe")
        #expect(parent.read(got, 64).0.value == 0)  // every write end is closed: EOF
    }

    @Test func scmRightsEdgeCases() throws {
        let e = try DEnv()
        e.put([UInt8](repeating: 0, count: 8), at: DEnv.scratch + 0x100)
        e.call(135, [1, 1, 0, DEnv.scratch + 0x100])
        let a = e.i32(DEnv.scratch + 0x100), b = e.i32(DEnv.scratch + 0x104)
        #expect(e.sendRights(a, "x", fds: [77]).errno == 9)
        // A confined descriptor (a kqueue) cannot be sent.
        let kq = try e.kernel.fileSystem.installObject(ConfinedObject(), statusFlags: 2, closeOnExec: false)
        #expect(e.sendRights(a, "x", fds: [kq]).errno == 22)
        // Two fds, room for one: one installed, MSG_CTRUNC, cmsg_len stays 20.
        let (r1, _) = e.pipe()
        let before = e.kernel.fileSystem.openDescriptors.count
        #expect(e.sendRights(a, "two", fds: [r1, r1]).value == 3)
        // MSG_PEEK shows the cmsg with zeroed slots and installs nothing.
        let peek = e.receiveRights(b, controlRoom: 64, flags: 0x2)
        #expect(peek.text == "two" && peek.fds == [0, 0])
        #expect(e.kernel.fileSystem.openDescriptors.count == before)
        let m = e.receiveRights(b, controlRoom: 16)
        #expect(m.text == "two" && m.fds.count == 1 && m.cmsgLength == 20 && m.controlLength == 16 && m.flags == 0x20)
        #expect(e.kernel.fileSystem.openDescriptors.count == before + 1)
        // Control data that is not exactly one SCM_RIGHTS: EINVAL.
        let base = DEnv.scratch + 0x8000
        _ = e.sendRights(a, "y", fds: [r1])
        e.put([12 + 4 + 4, 0, 0, 0], at: base + 0x200)  // cmsg_len ≠ msg_controllen
        #expect(e.call(28, [UInt64(a), base, 0]).errno == 22)
    }

    @Test func blockedSocketReaderIsWokenByAnotherProcess() throws {
        let parent = try DEnv(pid: 100)
        parent.put([UInt8](repeating: 0, count: 8), at: DEnv.scratch + 0x100)
        parent.call(135, [1, 1, 0, DEnv.scratch + 0x100])
        let a = parent.i32(DEnv.scratch + 0x100), b = parent.i32(DEnv.scratch + 0x104)
        let child = try DEnv(parent: parent, pid: 101)
        parent.call(6, [UInt64(b)])  // b lives on in the child only
        let reader = HostThread { parent.read(a, 64, at: DEnv.scratch + 0x5000) }
        Thread.sleep(forTimeInterval: 0.15)
        #expect(reader.result == nil)
        #expect(child.write(b, "from 101").value == 8)
        #expect(reader.wait()?.1 == "from 101")
        // accept blocks until a connection arrives from the other process.
        let path = parent.writable + "/wake.sock"
        let l = parent.socket()
        parent.bind(l, path)
        parent.call(106, [UInt64(l), 5])
        let acceptor = HostThread { parent.accept(l) }
        Thread.sleep(forTimeInterval: 0.1)
        #expect(acceptor.result == nil)
        let c = child.socket()
        #expect(child.connect(c, path).value == 0)
        #expect(acceptor.wait()?.value != nil)
    }

    @Test func receiveTimeout() throws {
        let e = try DEnv()
        e.put([UInt8](repeating: 0, count: 8), at: DEnv.scratch + 0x100)
        e.call(135, [1, 2, 0, DEnv.scratch + 0x100])
        let a = e.i32(DEnv.scratch + 0x100)
        var tv: [UInt8] = []
        tv.appendLE(Int64(0))
        tv.appendLE(Int32(50_000))
        tv.appendLE(Int32(0))
        e.put(tv, at: optVA)
        #expect(e.call(105, [UInt64(a), 0xFFFF, 0x1006, optVA, 16]).value == 0)
        let start = Date()
        #expect(e.read(a).0.errno == 35)
        #expect(Date().timeIntervalSince(start) >= 0.04)
    }

    /// The host end of /private/var/run/.sim_diagnosticd_socket
    /// (HostStreamSockets.swift, launchd-sim.md §8.1): a connect succeeds
    /// with no guest listener, writes are consumed, nothing comes back.
    @Test func hostDiagnosticdSocketAcceptsAndDiscards() throws {
        let e = try DEnv()
        let saved = HostStreamSockets.diagnosticdEnabled
        defer { HostStreamSockets.diagnosticdEnabled = saved }
        // Off (the default): nobody serves the path.
        HostStreamSockets.diagnosticdEnabled = false
        #expect(e.connect(e.socket(), HostStreamSockets.diagnosticdPath).errno == 2)  // ENOENT
        HostStreamSockets.diagnosticdEnabled = true
        let before = HostStreamSockets.bytesReceived
        let fd = e.socket()
        #expect(e.connect(fd, HostStreamSockets.diagnosticdPath).value == 0)
        for _ in 0..<10 { #expect(e.write(fd, String(repeating: "x", count: 4000)).value == 4000) }
        #expect(HostStreamSockets.bytesReceived - before == 40000)
        // Nothing to read: non-blocking read is EAGAIN.
        #expect(e.call(92, [UInt64(fd), 4, 4]).value == 0)  // F_SETFL O_NONBLOCK
        #expect(e.read(fd).0.errno == 35)
        // Other unbound paths still fail.
        #expect(e.connect(e.socket(), "/private/var/run/.no_such_socket").errno != nil)
    }
}
