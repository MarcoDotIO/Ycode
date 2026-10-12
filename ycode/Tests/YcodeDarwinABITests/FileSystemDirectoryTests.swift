import Foundation
import Testing
@testable import YcodeDarwinABI

// mkdir / rmdir (stage 4c: launchd_sim creates its state directories).

private func errnoOf(_ body: () throws -> Void) -> Int32? {
    do { try body() } catch let e as DarwinErrnoError { return e.errno } catch { return -1 }
    return nil
}

@Suite struct FileSystemDirectoryTests {
    private func fixture() throws -> (TempTree, DarwinFileSystem) {
        let tree = try TempTree()
        try tree.writeFile("ro/file", [1])
        try tree.mkdir("ro/sub")
        try tree.mkdir("w")
        let fs = DarwinFileSystem(prefixes: [.init(guestPath: "/R", hostPath: tree.host("ro"), writable: false),
                                             .init(guestPath: "/private/tmp", hostPath: tree.host("w"), writable: true)],
                                  console: { _, _ in })
        fs.guestSymlinks = DarwinFileSystem.darwinRootSymlinks
        return (tree, fs)
    }

    @Test func mkdirSemantics() throws {
        let (tree, fs) = try fixture()
        try fs.mkdir("/tmp/state", mode: 0o777, umask: 0o022)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: tree.host("w/state"), isDirectory: &isDir) && isDir.boolValue)
        let st = try fs.stat("/private/tmp/state", followSymlinks: true)
        #expect(st.isDirectory && st.mode & 0o7777 == 0o755)
        try fs.mkdir("/tmp/open", mode: 0o777, umask: 0)
        #expect(try fs.stat("/tmp/open", followSymlinks: true).mode & 0o7777 == 0o777)  // host umask does not apply
        try fs.mkdir("/tmp/state/inner/", mode: 0o700, umask: 0o022)
        #expect(try fs.stat("/tmp/state/inner", followSymlinks: true).mode & 0o7777 == 0o700)
        #expect(errnoOf { try fs.mkdir("/tmp/state", mode: 0o755, umask: 0) } == DarwinErrnoCode.EEXIST)
        #expect(errnoOf { try fs.mkdir("/tmp", mode: 0o755, umask: 0) } == DarwinErrnoCode.EEXIST)  // a guest link
        #expect(errnoOf { try fs.mkdir("/R/file", mode: 0o755, umask: 0) } == DarwinErrnoCode.EEXIST)
        #expect(errnoOf { try fs.mkdir("/R/sub", mode: 0o755, umask: 0) } == DarwinErrnoCode.EEXIST)
        #expect(errnoOf { try fs.mkdir("/R/new", mode: 0o755, umask: 0) } == DarwinErrnoCode.EROFS)
        #expect(errnoOf { try fs.mkdir("/tmp/no/new", mode: 0o755, umask: 0) } == DarwinErrnoCode.ENOENT)
        #expect(errnoOf { try fs.mkdir("/tmp/state/x/y", mode: 0o755, umask: 0) } == DarwinErrnoCode.ENOENT)
        #expect(errnoOf { try fs.mkdir("/nowhere/x", mode: 0o755, umask: 0) } == DarwinErrnoCode.ENOENT)
        #expect(errnoOf { try fs.mkdir("/dev/x", mode: 0o755, umask: 0) } == DarwinErrnoCode.EROFS)
        #expect(errnoOf { try fs.mkdir("/dev", mode: 0o755, umask: 0) } == DarwinErrnoCode.EEXIST)
        #expect(errnoOf { try fs.mkdir("/dev/null", mode: 0o755, umask: 0) } == DarwinErrnoCode.EEXIST)
    }

    @Test func rmdirSemantics() throws {
        let (tree, fs) = try fixture()
        try fs.mkdir("/tmp/d", mode: 0o755, umask: 0)
        try fs.mkdir("/tmp/d/e", mode: 0o755, umask: 0)
        #expect(errnoOf { try fs.rmdir("/tmp/d") } == DarwinErrnoCode.ENOTEMPTY)
        try fs.rmdir("/tmp/d/e")
        try fs.rmdir("/tmp/d")
        #expect(!FileManager.default.fileExists(atPath: tree.host("w/d")))
        #expect(errnoOf { try fs.rmdir("/tmp/d") } == DarwinErrnoCode.ENOENT)
        let fd = try fs.open("/tmp/f", flags: DarwinOpen.O_WRONLY | DarwinOpen.O_CREAT, mode: 0o644)
        try fs.close(fd)
        #expect(errnoOf { try fs.rmdir("/tmp/f") } == DarwinErrnoCode.ENOTDIR)
        #expect(errnoOf { try fs.rmdir("/tmp") } == DarwinErrnoCode.ENOTDIR)  // a guest link
        #expect(errnoOf { try fs.rmdir("/private/tmp") } == DarwinErrnoCode.EBUSY)  // a prefix root
        #expect(errnoOf { try fs.rmdir("/R") } == DarwinErrnoCode.EBUSY)
        #expect(errnoOf { try fs.rmdir("/R/sub") } == DarwinErrnoCode.EROFS)
        #expect(errnoOf { try fs.rmdir("/dev") } == DarwinErrnoCode.EBUSY)
        #expect(errnoOf { try fs.rmdir("/dev/null") } == DarwinErrnoCode.ENOTDIR)
        // A socket file makes a directory non-empty.
        final class Sock: DarwinDescriptorObject {
            var fileType: UInt16 { DarwinStat.S_IFSOCK }
            func lastReferenceClosed() {}
        }
        try fs.mkdir("/tmp/s", mode: 0o755, umask: 0)
        let s = Sock()
        _ = try fs.bindSocket(s, path: "/tmp/s/sock", umask: 0)
        #expect(errnoOf { try fs.rmdir("/tmp/s") } == DarwinErrnoCode.ENOTEMPTY)
        try fs.unlink("/tmp/s/sock")
        try fs.rmdir("/tmp/s")
    }
}
