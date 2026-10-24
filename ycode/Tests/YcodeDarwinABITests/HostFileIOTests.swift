import Foundation
import Testing
@testable import YcodeDarwinABI

/// Regular-file transfers and renames that run without the kernel lock
/// (stage6-contract.md §5.2).
@Suite struct HostFileIOTests {
    @Test func checksMatchThePlainCalls() throws {
        let f = try IOFixture()
        #expect(throws: DarwinErrnoError.self) { _ = try f.fs.hostFileIO(99, writing: false) }
        let ro = try f.fs.open("/Runtime/usr/lib/dyld_sim", flags: 0, mode: 0)
        #expect(try f.fs.hostFileIO(ro, writing: false) != nil)
        #expect { _ = try f.fs.hostFileIO(ro, writing: true) } throws: { ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.EBADF }
        let dir = try f.fs.open("/Runtime/usr/lib", flags: 0, mode: 0)
        #expect { _ = try f.fs.hostFileIO(dir, writing: false) } throws: { ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.EISDIR }
        // The console is not a regular host file: the plain call serves it.
        #expect(try f.fs.hostFileIO(1, writing: true) == nil)
    }

    @Test func readAdvancesTheSharedOffset() throws {
        let f = try IOFixture()
        let fd = try f.fs.open("/tmp/data", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o600)
        _ = try f.fs.write(fd, Array(0..<100))
        _ = try f.fs.lseek(fd, offset: 0, whence: 0)
        let dup = try f.fs.dup(fd)
        let io = try #require(try f.fs.hostFileIO(fd, writing: false))
        #expect(try io.read(count: 10) == Array(0..<10))
        // The dup'd descriptor shares the offset.
        #expect(try f.fs.read(dup, count: 5) == Array(10..<15))
        // Cached reads use preadv2(RWF_NOWAIT), which only Linux has; on
        // other hosts they always answer nil and leave the offset alone.
        #if os(Linux)
        #expect(io.readIfCached(count: 5) == Array(15..<20))
        let offset: Int64 = 20
        #else
        #expect(io.readIfCached(count: 5) == nil)
        let offset: Int64 = 15
        #endif
        #expect(try f.fs.lseek(fd, offset: 0, whence: 1) == offset)
        #expect(try io.pread(count: 3, offset: 50) == [50, 51, 52])
        #expect(try f.fs.lseek(fd, offset: 0, whence: 1) == offset)
        #if os(Linux)
        // At the end of the file a short cached read is the whole answer.
        #expect(io.preadIfCached(count: 10, offset: 95) == Array(95..<100))
        #expect(io.preadIfCached(count: 10, offset: 100) == [])
        #else
        #expect(io.preadIfCached(count: 10, offset: 95) == nil)
        #endif
    }

    @Test func writeHonorsAppendAndOffset() throws {
        let f = try IOFixture()
        let fd = try f.fs.open("/tmp/log", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT | DarwinOpen.O_APPEND, mode: 0o600)
        let io = try #require(try f.fs.hostFileIO(fd, writing: true))
        #expect(try io.write([1, 2, 3]) == 3)
        #expect(try io.write([4]) == 1)
        #expect(try f.fs.lseek(fd, offset: 0, whence: 1) == 4)
        #expect(try io.pwrite([9], offset: 0) == 1)
        #expect(f.tree.contents("run/tmp/log") == [9, 2, 3, 4])
    }

    /// Concurrent offset-based transfers on one description never read the
    /// same bytes twice or skip any.
    @Test func concurrentReadsAreAtomic() throws {
        let f = try IOFixture()
        let fd = try f.fs.open("/tmp/big", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o600)
        var data: [UInt8] = []
        for i in 0..<4096 { data += withUnsafeBytes(of: UInt32(i).littleEndian, Array.init) }
        _ = try f.fs.write(fd, data)
        _ = try f.fs.lseek(fd, offset: 0, whence: 0)
        let io = try #require(try f.fs.hostFileIO(fd, writing: false))
        final class Box: @unchecked Sendable { var chunks: [[UInt8]] = []; let lock = NSLock() }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            while true {
                guard let chunk = try? io.read(count: 4), !chunk.isEmpty else { return }
                box.lock.withLock { box.chunks.append(chunk) }
            }
        }
        let values = box.chunks.map { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }.sorted()
        #expect(values == (0..<4096).map(UInt32.init))
    }

    /// `lseek` SEEK_CUR racing offset-based reads never loses an update:
    /// every read and every seek moves the shared offset exactly once.
    @Test func lseekIsAtomicWithTransfers() throws {
        let f = try IOFixture()
        let fd = try f.fs.open("/tmp/seek", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o600)
        _ = try f.fs.write(fd, [UInt8](repeating: 7, count: 1 << 16))
        _ = try f.fs.lseek(fd, offset: 0, whence: 0)
        let io = try #require(try f.fs.hostFileIO(fd, writing: false))
        let target = try f.fs.lseekTarget(fd)
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            for _ in 0..<500 {
                if i % 2 == 0 { _ = try? io.read(count: 3) } else { _ = try? target.seek(offset: 5, whence: 1) }
            }
        }
        #expect(try f.fs.lseek(fd, offset: 0, whence: 1) == UInt64(4 * 500 * 3 + 4 * 500 * 5))
    }

    /// A caller holding the kernel lock never waits for a transfer: with the
    /// offset lock taken, the cached read and a non-waiting seek give up and
    /// change nothing.
    @Test func lockedCallersDoNotWaitForTransfers() throws {
        let f = try IOFixture()
        let fd = try f.fs.open("/tmp/busy", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o600)
        _ = try f.fs.write(fd, Array(0..<10))
        let io = try #require(try f.fs.hostFileIO(fd, writing: false))
        let target = try f.fs.lseekTarget(fd)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        Thread {
            _ = io.description.updateOffset { _ in
                held.signal()
                release.wait()
            }
            done.signal()
        }.start()
        held.wait()
        #expect(io.readIfCached(count: 2) == nil)
        #expect(try target.seek(offset: 0, whence: 0, wait: false) == nil)
        release.signal()
        done.wait()
        #expect(try target.seek(offset: 4, whence: 0, wait: false) == 4)
        #if os(Linux)
        #expect(io.readIfCached(count: 2) == [4, 5])
        #else
        #expect(io.readIfCached(count: 2) == nil)  // Linux-only cached reads
        #endif
        #expect { _ = try target.seek(offset: -100, whence: 1) } throws: { ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.EINVAL }
        #expect { _ = try target.seek(offset: 0, whence: 9) } throws: { ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.EINVAL }
        #expect(try target.seek(offset: -1, whence: 2) == 9)
    }

    /// A transfer checked before the guest closes the descriptor completes
    /// on the description it started with, and the host descriptor stays
    /// open (its number is not reused) until the transfer lets go.
    @Test func transferOutlivesClose() throws {
        let f = try IOFixture()
        let fd = try f.fs.open("/tmp/keep", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o600)
        _ = try f.fs.write(fd, [1, 2, 3, 4])
        _ = try f.fs.lseek(fd, offset: 0, whence: 0)
        let io = try #require(try f.fs.hostFileIO(fd, writing: false))
        let writer = try #require(try f.fs.hostFileIO(fd, writing: true))
        try f.fs.close(fd)
        // A new open may take the guest number, never the host descriptor.
        let other = try f.fs.open("/tmp/other", flags: DarwinOpen.O_RDWR | DarwinOpen.O_CREAT, mode: 0o600)
        #expect(other == fd)
        #expect(try io.read(count: 2) == [1, 2])
        #expect(try writer.write([9]) == 1)
        #expect(f.tree.contents("run/tmp/keep") == [1, 2, 9, 4])
        #expect(f.tree.contents("run/tmp/other") == [])
    }

    @Test func unlinkHostFileRemovesHostFilesOnly() throws {
        let f = try IOFixture()
        try f.tree.writeFile("run/tmp/gone", [1])
        #expect(try f.fs.unlinkHostFile("/tmp/gone"))
        #expect(f.tree.contents("run/tmp/gone") == nil)
        #expect { _ = try f.fs.unlinkHostFile("/tmp/gone") } throws: { ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.ENOENT }
        #expect { _ = try f.fs.unlinkHostFile("/Runtime/usr/lib/dyld_sim") } throws: {
            ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.EROFS
        }
    }

    @Test func renameHostFilesLeavesSocketsToTheLockedPath() throws {
        let f = try IOFixture()
        try f.tree.writeFile("run/tmp/a", [1])
        #expect(try f.fs.renameHostFiles("/tmp/a", to: "/tmp/b"))
        #expect(f.tree.contents("run/tmp/b") == [1])
        #expect { _ = try f.fs.renameHostFiles("/tmp/missing", to: "/tmp/c") } throws: {
            ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.ENOENT
        }
        #expect { _ = try f.fs.renameHostFiles("/Runtime/usr/lib/dyld_sim", to: "/tmp/x") } throws: {
            ($0 as? DarwinErrnoError)?.errno == DarwinErrnoCode.EROFS
        }
    }
}

/// `/Runtime` (read-only) and `/tmp` (read-write) over a temporary tree.
private final class IOFixture {
    let tree: TempTree
    let fs: DarwinFileSystem

    init() throws {
        tree = try TempTree()
        try tree.writeFile("runtime/usr/lib/dyld_sim", Array("DYLD".utf8))
        try tree.mkdir("run/tmp")
        fs = DarwinFileSystem(prefixes: [
            .init(guestPath: "/Runtime", hostPath: tree.host("runtime"), writable: false),
            .init(guestPath: "/tmp", hostPath: tree.host("run/tmp"), writable: true),
        ], console: { _, _ in })
    }
}
