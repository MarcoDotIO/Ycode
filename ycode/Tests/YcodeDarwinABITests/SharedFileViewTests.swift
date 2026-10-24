#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import YcodeDarwinABI

/// MAP_SHARED file mappings as host file views (`SharedMemoryObject(hostFile:…)`):
/// writes through one view are seen through another, in a space that maps
/// it, and by the host file.
@Suite struct SharedFileViewTests {
    private func temporaryFile(size: Int, flags: Int32) -> (fd: Int32, path: String) {
        var template = Array("/tmp/ycode-shared-view-XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        precondition(fd >= 0)
        let path = String(cString: template)
        #expect(ftruncate(fd, off_t(size)) == 0)
        if flags == O_RDWR { return (fd, path) }
        close(fd)
        return (open(path, flags), path)
    }

    @Test func writesAreSeenByOtherViewsAndTheFile() throws {
        let (fd, path) = temporaryFile(size: 0x8000, flags: O_RDWR)
        defer { close(fd); unlink(path) }
        let a = try #require(SharedMemoryObject(hostFile: fd, offset: 0, size: 0x8000, fileSize: 0x8000))
        let b = try #require(SharedMemoryObject(hostFile: fd, offset: 0x4000, size: 0x4000, fileSize: 0x8000))
        #expect(a.isFileView && a.size == 0x8000 && b.size == 0x4000)
        a.write(offset: 0x4010, bytes: [1, 2, 3, 4])
        #expect(b.read(offset: 0x10, count: 4) == [1, 2, 3, 4])
        var bytes = [UInt8](repeating: 0, count: 4)
        #expect(pread(fd, &bytes, 4, 0x4010) == 4)
        #expect(bytes == [1, 2, 3, 4])
        // A host write is seen through the views.
        var more: [UInt8] = [9, 8]
        #expect(pwrite(fd, &more, 2, 0x20) == 2)
        #expect(a.read(offset: 0x20, count: 2) == [9, 8])

        // Through a guest address space: two mappings of the same file.
        let space = GuestAddressSpace(backing: FakePhysicalBacking())
        let va1 = try space.mapShared(a, offset: 0, at: nil, size: 0x8000, protection: .readWrite, hint: nil)
        let c = try #require(SharedMemoryObject(hostFile: fd, offset: 0, size: 0x8000, fileSize: 0x8000))
        let va2 = try space.mapShared(c, offset: 0, at: nil, size: 0x8000, protection: .read, hint: nil)
        try space.write(va: va1 + 0x100, bytes: [0xAA, 0xBB])
        #expect(try space.read(va: va2 + 0x100, count: 2) == [0xAA, 0xBB])
    }

    @Test func pagesPastTheEndReadAsZero() throws {
        // 0x5000 bytes: the second 16 KiB page is partly past the end.
        let (fd, path) = temporaryFile(size: 0x5000, flags: O_RDWR)
        defer { close(fd); unlink(path) }
        let a = try #require(SharedMemoryObject(hostFile: fd, offset: 0, size: 0x8000, fileSize: 0x5000))
        #expect(a.read(offset: 0x7FF0, count: 16) == [UInt8](repeating: 0, count: 16))
        a.write(offset: 0x7FF0, bytes: [7])  // writable, not part of the file
        var st = stat()
        #expect(fstat(fd, &st) == 0 && st.st_size == 0x5000)
    }

    @Test func readOnlyDescriptorsAndUnalignedOffsetsAreRefused() {
        let (fd, path) = temporaryFile(size: 0x4000, flags: O_RDONLY)
        defer { close(fd); unlink(path) }
        #expect(SharedMemoryObject(hostFile: fd, offset: 0, size: 0x4000, fileSize: 0x4000) == nil)
        let (rw, path2) = temporaryFile(size: 0x4000, flags: O_RDWR)
        defer { close(rw); unlink(path2) }
        #expect(SharedMemoryObject(hostFile: rw, offset: 0x10, size: 0x4000, fileSize: 0x4000) == nil)
    }

    /// service-fidelity.md §10: a view made while the file was short shows
    /// what is later written past the old end, and its writes there reach
    /// the file (SpotlightIndex maps 1 MiB of a 16 KiB file and grows it).
    @Test func viewsFollowTheFileWhenItGrows() throws {
        let (fd, path) = temporaryFile(size: 0x4000, flags: O_RDWR)
        defer { close(fd); unlink(path) }
        let a = try #require(SharedMemoryObject(hostFile: fd, offset: 0, size: 0x10000, fileSize: 0x4000))
        #expect(a.fileBackedBytes == 0x4000)
        // A view that starts at the end of the file has no file pages yet.
        let b = try #require(SharedMemoryObject(hostFile: fd, offset: 0x8000, size: 0x8000, fileSize: 0x4000))
        #expect(b.fileBackedBytes == 0)
        #expect(ftruncate(fd, 0xC000) == 0)
        var data: [UInt8] = [5, 6, 7]
        #expect(pwrite(fd, &data, 3, 0x8010) == 3)
        SharedFileViews.sizeMayHaveChanged(hostFD: fd)
        #expect(a.fileBackedBytes == 0xC000 && b.fileBackedBytes == 0x4000)
        #expect(a.read(offset: 0x8010, count: 3) == [5, 6, 7])
        #expect(b.read(offset: 0x10, count: 3) == [5, 6, 7])
        a.write(offset: 0x9000, bytes: [0x42])
        var back = [UInt8](repeating: 0, count: 1)
        #expect(pread(fd, &back, 1, 0x9000) == 1 && back == [0x42])
        #expect(b.read(offset: 0x1000, count: 1) == [0x42])
    }

    /// Truncation makes the pages past the new end zeros again (no host fault).
    @Test func viewsFollowTheFileWhenItShrinks() throws {
        let (fd, path) = temporaryFile(size: 0x10000, flags: O_RDWR)
        defer { close(fd); unlink(path) }
        let a = try #require(SharedMemoryObject(hostFile: fd, offset: 0, size: 0x10000, fileSize: 0x10000))
        a.write(offset: 0x8000, bytes: [1])
        #expect(ftruncate(fd, 0x4000) == 0)
        SharedFileViews.sizeMayHaveChanged(hostFD: fd)
        #expect(a.fileBackedBytes == 0x4000)
        #expect(a.read(offset: 0x8000, count: 1) == [0])
        #expect(ftruncate(fd, 0x10000) == 0)
        SharedFileViews.sizeMayHaveChanged(hostFD: fd)
        #expect(a.read(offset: 0x8000, count: 1) == [0], "the truncated bytes are gone, as on Darwin")
    }

    #if os(Linux)
    /// A read-only descriptor's view (reopened for the host mapping) sees
    /// later writes through another descriptor.
    @Test func readOnlyViewsSeeLaterWrites() throws {
        let (rw, path) = temporaryFile(size: 0x4000, flags: O_RDWR)
        defer { close(rw); unlink(path) }
        let ro = open(path, O_RDONLY)
        defer { close(ro) }
        let v = try #require(SharedMemoryObject(hostFile: ro, offset: 0, size: 0x8000, fileSize: 0x4000, reopenReadOnly: true))
        var data: [UInt8] = [3, 1, 4]
        #expect(pwrite(rw, &data, 3, 0x10) == 3)
        #expect(v.read(offset: 0x10, count: 3) == [3, 1, 4])
        #expect(pwrite(rw, &data, 3, 0x6000) == 3)
        SharedFileViews.sizeMayHaveChanged(hostFD: rw)
        #expect(v.read(offset: 0x6000, count: 3) == [3, 1, 4])
    }
    #endif

}
