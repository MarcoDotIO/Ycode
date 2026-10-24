// The private file window's host helper (boot-profile.md §3.2): a mapping of
// a file that ends inside a host page places the zero tail at the next host
// page boundary.
#if os(Linux) && arch(arm64)
import CKVM
import Foundation
import Glibc
import Testing

@Suite struct PrivateFileWindowTests {
    @Test func fileEndingInsideAHostPage() throws {
        let path = NSTemporaryDirectory() + "ycode-window-\(getpid()).bin"
        let fileBytes = 5000  // not a multiple of any host page size
        let content = (0..<fileBytes).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
        _ = FileManager.default.createFile(atPath: path, contents: Data(content))
        defer { unlink(path) }
        let fd = open(path, O_RDONLY)
        #expect(fd >= 0)
        defer { close(fd) }
        let total = 64 << 10
        let reservation = try #require(mmap(nil, total * 2, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0))
        #expect(reservation != MAP_FAILED)
        defer { munmap(reservation, total * 2) }
        let at = reservation + total
        let p = ckvm_map_file_private_at(at, fd, 0, fileBytes, total)
        #expect(p == at)
        guard p == at else { return }
        let bytes = at.assumingMemoryBound(to: UInt8.self)
        #expect((0..<fileBytes).allSatisfy { bytes[$0] == content[$0] })
        #expect((fileBytes..<total).allSatisfy { bytes[$0] == 0 })
        bytes[total - 1] = 9  // private and writable to the end
        #expect(bytes[total - 1] == 9)
    }
}
#endif
