import Foundation
import Testing
@testable import YcodeDarwinABI

// Stage 4b descriptor tables (`specs/simulator/stage4b-contract.md` §3.5):
// shared open file descriptions, dup/dup2, child copies, exec and exit
// closing, cwd, exec path lookup, socket files.

/// An object that counts `lastReferenceClosed` calls.
private final class CountingObject: DarwinDescriptorObject {
    var closes = 0
    let confined: Bool
    init(confined: Bool = false) { self.confined = confined }
    var fileType: UInt16 { DarwinStat.S_IFIFO }
    var isConfined: Bool { confined }
    func lastReferenceClosed() { closes += 1 }
}

private func errnoOf(_ body: () throws -> Void) -> Int32? {
    do { try body() } catch let e as DarwinErrnoError { return e.errno } catch { return -1 }
    return nil
}

private final class DescriptorFixture {
    let tree: TempTree
    let fs: DarwinFileSystem
    var output: [Int32: [UInt8]] = [:]

    init() throws {
        tree = try TempTree()
        try tree.writeFile("ro/data.bin", Array("0123456789".utf8))
        try tree.writeFile("ro/bin/tool", [1, 2, 3])
        try tree.mkdir("ro/dir")
        try tree.symlink("ro/toollink", to: "bin/tool")
        try tree.mkdir("tmp")
        var sink: (Int32, [UInt8]) -> Void = { _, _ in }
        fs = DarwinFileSystem(prefixes: [.init(guestPath: "/R", hostPath: tree.host("ro"), writable: false),
                                         .init(guestPath: "/tmp", hostPath: tree.host("tmp"), writable: true)],
                              console: { sink($0, $1) })
        sink = { [unowned self] fd, bytes in self.output[fd, default: []] += bytes }
    }
}

@Suite struct FileSystemDescriptorTests {
    @Test func dupSharesTheOffsetAndFlags() throws {
        let f = try DescriptorFixture()
        let fd = try f.fs.open("/R/data.bin", flags: DarwinOpen.O_RDONLY, mode: 0)
        let d = try f.fs.dup(fd)
        #expect(d == fd + 1)
        #expect(try f.fs.read(fd, count: 3) == Array("012".utf8))
        #expect(try f.fs.read(d, count: 3) == Array("345".utf8))
        #expect(try f.fs.openFile(for: fd) === (try f.fs.openFile(for: d)))
        // dup clears close-on-exec; F_DUPFD_CLOEXEC sets it; minimum respected.
        try f.fs.setCloseOnExec(fd, true)
        #expect(try !f.fs.closeOnExec(d))
        let high = try f.fs.dup(fd, minimum: 40, closeOnExec: true)
        #expect(high == 40)
        #expect(try f.fs.closeOnExec(high))
        #expect(errnoOf { _ = try f.fs.dup(fd, minimum: 256) } == DarwinErrnoCode.EINVAL)
        #expect(errnoOf { _ = try f.fs.dup(77) } == DarwinErrnoCode.EBADF)
        // Closing one keeps the other.
        try f.fs.close(fd)
        #expect(try f.fs.read(d, count: 2) == Array("67".utf8))
    }

    @Test func dup2ReplacesAndRoutesConsoleOutput() throws {
        let f = try DescriptorFixture()
        try f.fs.dup2(2, 9)
        _ = try f.fs.write(9, Array("err".utf8))
        #expect(f.output[2] == Array("err".utf8))
        try f.fs.dup2(1, 2)  // 2 now writes to the stdout stream
        _ = try f.fs.write(2, Array("x".utf8))
        #expect(f.output[1] == Array("x".utf8))
        try f.fs.dup2(9, 9)  // same fd: only checks it is open
        #expect(errnoOf { try f.fs.dup2(50, 51) } == DarwinErrnoCode.EBADF)
        #expect(errnoOf { try f.fs.dup2(1, 256) } == DarwinErrnoCode.EBADF)
        #expect(errnoOf { try f.fs.dup2(1, -1) } == DarwinErrnoCode.EBADF)
    }

    @Test func lastReferenceClosedCountsEveryHolder() throws {
        let f = try DescriptorFixture()
        let o = CountingObject()
        let fd = try f.fs.installObject(o, statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
        #expect(try f.fs.object(for: fd) === o)
        #expect(try f.fs.object(for: 0) == nil)
        let d = try f.fs.dup(fd)
        let child = f.fs.makeChildCopy()
        try f.fs.close(fd)
        try f.fs.close(d)
        #expect(o.closes == 0)  // the child still holds it
        var held: DarwinOpenFile? = try child.openFile(for: d)  // e.g. a fileport
        child.closeAll()
        #expect(o.closes == 0)
        let n = try f.fs.install(held!, closeOnExec: true)
        held = nil
        #expect(try f.fs.closeOnExec(n))
        try f.fs.close(n)
        #expect(o.closes == 1)
    }

    @Test func childCopyAndExecClosing() throws {
        let f = try DescriptorFixture()
        try f.fs.chdir("/R/dir")
        let a = try f.fs.installObject(CountingObject(), statusFlags: DarwinOpen.O_RDWR, closeOnExec: true)
        let b = try f.fs.installObject(CountingObject(), statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
        let kq = try f.fs.installObject(CountingObject(confined: true), statusFlags: DarwinOpen.O_RDWR, closeOnExec: false)
        f.fs.maxDescriptors = 100
        let child = f.fs.makeChildCopy()
        #expect(child.cwd == "/R/dir")
        #expect(child.maxDescriptors == 100)
        #expect(child.openDescriptors == [0, 1, 2, a, b])  // the confined kqueue stays behind
        #expect(try child.closeOnExec(a) == true)
        _ = kq
        child.closeOnExecDescriptors()
        #expect(child.openDescriptors == [0, 1, 2, b])
        let c2 = f.fs.makeChildCopy()
        c2.closeOnExecDescriptors(keepOnly: [1, b])
        #expect(c2.openDescriptors == [1, b])
        var closed: [Int32] = []
        c2.descriptorClosed = { fd, _ in closed.append(fd) }
        c2.closeAll()
        #expect(c2.openDescriptors.isEmpty && closed == [1, b])
    }

    @Test func installAtAndStatusFlags() throws {
        let f = try DescriptorFixture()
        let file = DarwinOpenFile(node: .object(CountingObject()), statusFlags: DarwinOpen.O_RDWR)
        #expect(try f.fs.install(file, closeOnExec: false, at: 7) == 7)
        #expect(try f.fs.install(file, closeOnExec: false) == 3)
        try f.fs.setStatusFlags(7, DarwinOpen.O_NONBLOCK | DarwinOpen.O_WRONLY)
        #expect(try f.fs.statusFlags(3) == DarwinOpen.O_RDWR | DarwinOpen.O_NONBLOCK)  // shared, mode kept
        #expect(try f.fs.fstat(3).fileType == DarwinStat.S_IFIFO)
        #expect(errnoOf { _ = try f.fs.path(for: 3) } == DarwinErrnoCode.EBADF)
        #expect(errnoOf { _ = try f.fs.file(for: 3) } == DarwinErrnoCode.ENODEV)
        #expect(errnoOf { _ = try f.fs.read(3, count: 1) } == DarwinErrnoCode.EOPNOTSUPP)
        #expect(errnoOf { _ = try f.fs.install(file, closeOnExec: false, at: 300) } == DarwinErrnoCode.EBADF)
    }

    @Test func lseekAndPwrite() throws {
        let f = try DescriptorFixture()
        let fd = try f.fs.open("/tmp/w", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o644)
        _ = try f.fs.write(fd, Array("hello".utf8))
        #expect(try f.fs.lseek(fd, offset: 1, whence: 0) == 1)
        #expect(try f.fs.read(fd, count: 2) == Array("el".utf8))
        #expect(try f.fs.lseek(fd, offset: -1, whence: 2) == 4)
        #expect(errnoOf { _ = try f.fs.lseek(fd, offset: -10, whence: 1) } == DarwinErrnoCode.EINVAL)
        #expect(try f.fs.pwrite(fd, Array("J".utf8), offset: 0) == 1)
        #expect(f.tree.contents("tmp/w") == Array("Jello".utf8))
        #expect(errnoOf { _ = try f.fs.lseek(1, offset: 0, whence: 1) } == DarwinErrnoCode.ESPIPE)
    }

    @Test func chdirFchdirAndExecPaths() throws {
        let f = try DescriptorFixture()
        #expect(errnoOf { try f.fs.chdir("/R/data.bin") } == DarwinErrnoCode.ENOTDIR)
        #expect(errnoOf { try f.fs.chdir("/R/nope") } == DarwinErrnoCode.ENOENT)
        try f.fs.chdir("/R")
        #expect(f.fs.cwd == "/R")
        let r = try f.fs.hostPathForExec("toollink")
        #expect(r.guestPath == "/R/bin/tool" && r.hostPath == f.tree.host("ro/bin/tool"))
        #expect(errnoOf { _ = try f.fs.hostPathForExec("dir") } == DarwinErrnoCode.EACCES)
        #expect(errnoOf { _ = try f.fs.hostPathForExec("missing") } == DarwinErrnoCode.ENOENT)
        let dfd = try f.fs.open("/R/dir", flags: DarwinOpen.O_RDONLY | DarwinOpen.O_DIRECTORY, mode: 0)
        try f.fs.chdir("/tmp")
        try f.fs.fchdir(dfd)
        #expect(f.fs.cwd == "/R/dir")
        #expect(errnoOf { try f.fs.fchdir(1) } == DarwinErrnoCode.ENOTDIR)
        #expect(errnoOf { try f.fs.fchdir(99) } == DarwinErrnoCode.EBADF)
    }

    @Test func socketFilesAndUnlink() throws {
        let f = try DescriptorFixture()
        let s = CountingObject()
        let path = try f.fs.bindSocket(s, path: "/tmp/sock", umask: 0o022)
        #expect(path == "/tmp/sock")
        let st = try f.fs.stat("/tmp/sock", followSymlinks: true)
        #expect(st.fileType == DarwinStat.S_IFSOCK && st.mode & 0o777 == 0o755)
        #expect(errnoOf { _ = try f.fs.bindSocket(s, path: "/tmp/sock", umask: 0) } == DarwinErrnoCode.EADDRINUSE)
        #expect(errnoOf { _ = try f.fs.bindSocket(s, path: "/R/s", umask: 0) } == DarwinErrnoCode.EROFS)
        #expect(errnoOf { _ = try f.fs.bindSocket(s, path: "/tmp/no/s", umask: 0) } == DarwinErrnoCode.ENOENT)
        #expect(errnoOf { _ = try f.fs.bindSocket(s, path: "/R/data.bin", umask: 0) } == DarwinErrnoCode.EADDRINUSE)
        #expect(errnoOf { _ = try f.fs.open("/tmp/sock", flags: DarwinOpen.O_RDONLY, mode: 0) } == DarwinErrnoCode.EOPNOTSUPP)
        guard case let .socket(o) = try f.fs.socketTarget("/tmp/../tmp/sock") else { Issue.record("socket"); return }
        #expect(o === s)
        #expect(errnoOf { _ = try f.fs.socketTarget("/R/data.bin") } == DarwinErrnoCode.ENOTSOCK)
        #expect(errnoOf { _ = try f.fs.socketTarget("/tmp/none") } == DarwinErrnoCode.ENOENT)
        // A child sees the same socket files.
        let child = f.fs.makeChildCopy()
        #expect(child.socketNames(inDirectory: "/tmp").map(\.name) == ["sock"])
        try child.unlink("/tmp/sock")
        #expect(errnoOf { _ = try f.fs.stat("/tmp/sock", followSymlinks: false) } == DarwinErrnoCode.ENOENT)
        // unlink of host files: writable prefixes only; directories EPERM.
        let fd = try f.fs.open("/tmp/x", flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT, mode: 0o644)
        try f.fs.close(fd)
        try f.fs.unlink("/tmp/x")
        #expect(f.tree.contents("tmp/x") == nil)
        #expect(errnoOf { try f.fs.unlink("/R/data.bin") } == DarwinErrnoCode.EROFS)
        #expect(errnoOf { try f.fs.unlink("/R/dir") } == DarwinErrnoCode.EPERM)
        #expect(errnoOf { try f.fs.unlink("/tmp/x") } == DarwinErrnoCode.ENOENT)
    }

    @Test func aClosedSocketLeavesItsFile() throws {
        let f = try DescriptorFixture()
        var s: CountingObject? = CountingObject()
        _ = try f.fs.bindSocket(s!, path: "/tmp/gone", umask: 0)
        s = nil
        guard case .noSocket = try f.fs.socketTarget("/tmp/gone") else { Issue.record("no socket"); return }
        #expect(try f.fs.stat("/tmp/gone", followSymlinks: true).fileType == DarwinStat.S_IFSOCK)
    }
}
