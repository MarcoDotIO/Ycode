import Foundation
import Testing
@testable import YcodeDarwinABI

// Stage 4c device nodes, device-mode standard descriptors, and guest
// namespace symbolic links (`specs/simulator/stage4c-contract.md` §2, §4).

private func errnoOf(_ body: () throws -> Void) -> Int32? {
    do { try body() } catch let e as DarwinErrnoError { return e.errno } catch { return -1 }
    return nil
}

private final class DeviceFixture {
    let tree: TempTree
    let fs: DarwinFileSystem
    var output: [Int32: [UInt8]] = [:]

    /// `/R` read-only, `/private/tmp` and `/private/var` writable (device-mode-like).
    init(links: Bool = false) throws {
        tree = try TempTree()
        try tree.writeFile("ro/file", Array("data".utf8))
        try tree.mkdir("tmp")
        try tree.mkdir("var/run")
        var sink: (Int32, [UInt8]) -> Void = { _, _ in }
        fs = DarwinFileSystem(prefixes: [.init(guestPath: "/R", hostPath: tree.host("ro"), writable: false),
                                         .init(guestPath: "/private/tmp", hostPath: tree.host("tmp"), writable: true),
                                         .init(guestPath: "/private/var", hostPath: tree.host("var"), writable: true)],
                              console: { sink($0, $1) })
        sink = { [unowned self] fd, bytes in self.output[fd, default: []] += bytes }
        if links { fs.guestSymlinks = DarwinFileSystem.darwinRootSymlinks }
    }
}

@Suite struct FileSystemDeviceTests {
    @Test func deviceNodesStatAsCharacterDevices() throws {
        let f = try DeviceFixture()
        let expected: [(String, UInt32, UInt16)] = [("null", 0x0300_0002, 0o666), ("zero", 0x0300_0003, 0o666),
                                                    ("random", 0x0E00_0000, 0o666), ("urandom", 0x0E00_0001, 0o666),
                                                    ("console", 0, 0o600), ("tty", 0x0200_0000, 0o666)]
        var inodes = Set<UInt64>()
        for (name, rdev, perm) in expected {
            let st = try f.fs.stat("/dev/" + name, followSymlinks: true)
            #expect(st.fileType == DarwinStat.S_IFCHR && st.rdev == rdev && st.mode & 0o7777 == perm, "\(name)")
            inodes.insert(st.ino)
        }
        #expect(inodes.count == 6)
        #expect(try f.fs.stat("/dev", followSymlinks: true).isDirectory)
        #expect(try f.fs.stat("/dev/../dev/./null", followSymlinks: false).rdev == 0x0300_0002)
        #expect(errnoOf { _ = try f.fs.stat("/dev/sda", followSymlinks: true) } == DarwinErrnoCode.ENOENT)
        #expect(errnoOf { _ = try f.fs.stat("/dev/null/x", followSymlinks: true) } == DarwinErrnoCode.ENOTDIR)
        #expect(try f.fs.realpath("/dev/zero") == "/dev/zero")
        #expect(errnoOf { _ = try f.fs.hostPathForExec("/dev/null") } == DarwinErrnoCode.EACCES)
        // Turned off: /dev is not served.
        f.fs.servesDevices = false
        #expect(errnoOf { _ = try f.fs.stat("/dev/null", followSymlinks: true) } == DarwinErrnoCode.ENOENT)
    }

    @Test func openingAndUsingDevices() throws {
        let f = try DeviceFixture()
        let null = try f.fs.open("/dev/null", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CLOEXEC, mode: 0)
        #expect(try f.fs.closeOnExec(null))
        #expect(try f.fs.read(null, count: 100) == [])
        #expect(try f.fs.write(null, [1, 2, 3]) == 3)
        #expect(try f.fs.pread(null, count: 5, offset: 9) == [])
        #expect(try f.fs.lseek(null, offset: 10, whence: 0) == 10)
        #expect(try f.fs.path(for: null) == "/dev/null")
        #expect(try f.fs.fstat(null).rdev == 0x0300_0002)
        #expect(try f.fs.statusFlags(null) == DarwinOpen.O_RDWR)
        #expect(errnoOf { _ = try f.fs.file(for: null) } == DarwinErrnoCode.ENODEV)
        let zero = try f.fs.open("/dev/zero", flags: DarwinOpen.O_RDONLY, mode: 0)
        #expect(try f.fs.read(zero, count: 7) == [UInt8](repeating: 0, count: 7))
        #expect(errnoOf { _ = try f.fs.write(zero, [1]) } == DarwinErrnoCode.EBADF)  // opened read-only
        let random = try f.fs.open("/dev/urandom", flags: DarwinOpen.O_RDONLY, mode: 0)
        let a = try f.fs.read(random, count: 64), b = try f.fs.read(random, count: 64)
        #expect(a.count == 64 && b.count == 64 && a != b)
        #expect(try f.fs.read(f.fs.open("/dev/random", flags: 0, mode: 0), count: 3).count == 3)
        // Flags and errors.
        #expect(errnoOf { _ = try f.fs.open("/dev/tty", flags: DarwinOpen.O_RDWR, mode: 0) } == DarwinErrnoCode.ENXIO)
        #expect(errnoOf {
            _ = try f.fs.open("/dev/null", flags: DarwinOpen.O_RDONLY | DarwinOpen.O_DIRECTORY, mode: 0)
        } == DarwinErrnoCode.ENOTDIR)
        #expect(errnoOf {
            _ = try f.fs.open("/dev/null", flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT | DarwinOpen.O_EXCL, mode: 0)
        } == DarwinErrnoCode.EEXIST)
        #expect(try f.fs.open("/dev/null", flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT | DarwinOpen.O_TRUNC, mode: 0) >= 0)
        #expect(errnoOf { _ = try f.fs.open("/dev/new", flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT, mode: 0o644) }
                == DarwinErrnoCode.EROFS)
        #expect(errnoOf { try f.fs.unlink("/dev/null") } == DarwinErrnoCode.EROFS)
        // /dev opens as a directory (listable through the host's /dev, where
        // only the served names stat successfully).
        let dir = try f.fs.open("/dev", flags: DarwinOpen.O_RDONLY | DarwinOpen.O_DIRECTORY, mode: 0)
        let file = try f.fs.file(for: dir)
        #expect(file.isDirectory && file.guestPath == "/dev")
        try f.fs.chdir("/dev")
        #expect(try f.fs.stat("zero", followSymlinks: true).rdev == 0x0300_0003)
    }

    @Test func consoleByPath() throws {
        let f = try DeviceFixture()
        let c = try f.fs.open("/dev/console", flags: DarwinOpen.O_RDWR, mode: 0)
        #expect(try f.fs.write(c, Array("hi".utf8)) == 2)
        #expect(f.output[1] == Array("hi".utf8))
        #expect(try f.fs.read(c, count: 10) == [])
        #expect(try f.fs.fstat(c).fileType == DarwinStat.S_IFCHR)
        #expect(try f.fs.path(for: c) == "/dev/console")
    }

    @Test func deviceModeStandardDescriptors() throws {
        let f = try DeviceFixture()
        try f.fs.installDeviceModeStandardDescriptors()
        #expect(f.fs.openDescriptors == [0, 1, 2, 3])
        #expect(try f.fs.path(for: 0) == "/dev/null" && f.fs.statusFlags(0) == DarwinOpen.O_RDONLY)
        #expect(try f.fs.path(for: 1) == "/dev/null" && f.fs.statusFlags(1) == DarwinOpen.O_WRONLY)
        #expect(try f.fs.path(for: 3) == "/dev/console" && f.fs.statusFlags(3) == DarwinOpen.O_WRONLY)
        #expect(try !f.fs.closeOnExec(0) && !f.fs.closeOnExec(3))
        _ = try f.fs.write(1, Array("dropped".utf8))
        _ = try f.fs.write(2, Array("err".utf8))
        _ = try f.fs.write(3, Array("cons".utf8))
        #expect(f.output[2] == Array("err".utf8) && f.output[1] == Array("cons".utf8))
        #expect(try f.fs.read(0, count: 4) == [])
        // open(at:) replaces, and checks the range.
        #expect(try f.fs.open("/dev/zero", flags: DarwinOpen.O_RDONLY, mode: 0, at: 0) == 0)
        #expect(try f.fs.read(0, count: 2) == [0, 0])
        #expect(errnoOf { _ = try f.fs.open("/dev/zero", flags: 0, mode: 0, at: 256) } == DarwinErrnoCode.EBADF)
        #expect(errnoOf { _ = try f.fs.open("/dev/nope", flags: 0, mode: 0, at: 5) } == DarwinErrnoCode.ENOENT)
        #expect(f.fs.openDescriptors == [0, 1, 2, 3])
    }

    @Test func guestSymlinksAreOptIn() throws {
        let plain = try DeviceFixture()
        #expect(plain.fs.guestSymlinks.isEmpty)
        #expect(errnoOf { _ = try plain.fs.stat("/tmp", followSymlinks: false) } == DarwinErrnoCode.ENOENT)

        let f = try DeviceFixture(links: true)
        let st = try f.fs.stat("/tmp", followSymlinks: false)
        #expect(st.isSymbolicLink && st.size == Int64("private/tmp".utf8.count))
        #expect(try f.fs.stat("/tmp", followSymlinks: true).isDirectory)
        #expect(try f.fs.readlink("/tmp") == "private/tmp")
        #expect(try f.fs.readlink("/var") == "private/var")
        #expect(try f.fs.readlink("/etc") == "private/etc")
        #expect(errnoOf { _ = try f.fs.readlink("/R/file") } == DarwinErrnoCode.EINVAL)
        #expect(errnoOf { _ = try f.fs.readlink("/R/none") } == DarwinErrnoCode.ENOENT)
        // Lookups follow them; files land in the target prefix.
        let fd = try f.fs.open("/tmp/x", flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT, mode: 0o644)
        _ = try f.fs.write(fd, Array("ok".utf8))
        #expect(f.tree.contents("tmp/x") == Array("ok".utf8))
        #expect(try f.fs.realpath("/tmp/x") == "/private/tmp/x")
        #expect(try f.fs.path(for: fd) == "/private/tmp/x")
        try f.fs.chdir("/var/run")
        #expect(f.fs.cwd == "/private/var/run")
        // O_NOFOLLOW on the link itself: ELOOP; the link cannot be removed.
        #expect(errnoOf { _ = try f.fs.open("/tmp", flags: DarwinOpen.O_RDONLY | DarwinOpen.O_NOFOLLOW, mode: 0) }
                == DarwinErrnoCode.ELOOP)
        #expect(errnoOf { try f.fs.unlink("/tmp") } == DarwinErrnoCode.EROFS)
        // /etc has no target here: following it fails, lstat works.
        #expect(errnoOf { _ = try f.fs.stat("/etc/hosts", followSymlinks: true) } == DarwinErrnoCode.ENOENT)
        // Socket files are named by their canonical path.
        final class Sock: DarwinDescriptorObject {
            var fileType: UInt16 { DarwinStat.S_IFSOCK }
            func lastReferenceClosed() {}
        }
        let s = Sock()
        #expect(try f.fs.bindSocket(s, path: "/var/run/syslog", umask: 0o022) == "/private/var/run/syslog")
        guard case let .socket(o) = try f.fs.socketTarget("/private/var/run/syslog") else { Issue.record("socket"); return }
        #expect(o === s)
        // A child keeps the links; a host symlink to "/tmp/…" follows them.
        let child = f.fs.makeChildCopy()
        #expect(try child.readlink("/tmp") == "private/tmp")
        try f.tree.symlink("ro/tmplink", to: "/tmp/x")
        #expect(try f.fs.realpath("/R/tmplink") == "/private/tmp/x")
        // Paths are normalized when set.
        f.fs.guestSymlinks = ["/a/": "/private/tmp"]
        #expect(f.fs.guestSymlinks == ["/a": "/private/tmp"])
        #expect(try f.fs.realpath("/a/x") == "/private/tmp/x")
    }
}
