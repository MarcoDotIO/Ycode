import Foundation
import Testing
@testable import YcodeDarwinABI

/// Snapshot restore from a copied device directory (snapshot.md §2.7): the
/// guest keeps seeing the inode numbers recorded at the snapshot.
@Suite(.serialized) struct InodeMapTests {
    @Test func statReportsTheRecordedInode() throws {
        let tree = try TempTree()
        try tree.writeFile("dev/a.db", [1, 2, 3])
        try tree.writeFile("dev/b", [4])
        let fs = DarwinFileSystem(prefixes: [.init(guestPath: tree.root, hostPath: tree.root, writable: true)],
                                  console: { _, _ in })
        let a = try fs.stat(tree.host("dev/a.db"), followSymlinks: false)
        let b = try fs.stat(tree.host("dev/b"), followSymlinks: false)
        var host = stat()
        #expect(lstat(tree.host("dev/a.db"), &host) == 0)
        DarwinInodeMap.install([(UInt64(host.st_dev), UInt64(host.st_ino), 4242)])
        defer { DarwinInodeMap.install([]) }
        #expect(DarwinInodeMap.count == 1)
        #expect(try fs.stat(tree.host("dev/a.db"), followSymlinks: false).ino == 4242)
        let fd = try fs.open(tree.host("dev/a.db"), flags: DarwinOpen.O_RDONLY, mode: 0)
        #expect(try fs.fstat(fd).ino == 4242)
        try fs.close(fd)
        // Other files are untouched; an identity entry is not stored.
        #expect(try fs.stat(tree.host("dev/b"), followSymlinks: false).ino == b.ino)
        DarwinInodeMap.install([(UInt64(host.st_dev), UInt64(host.st_ino), UInt64(host.st_ino))])
        #expect(DarwinInodeMap.count == 0)
        #expect(try fs.stat(tree.host("dev/a.db"), followSymlinks: false).ino == a.ino)
    }
}
