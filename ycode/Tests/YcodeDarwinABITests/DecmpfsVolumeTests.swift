import Foundation
import Testing
@testable import YcodeDarwinABI

/// decmpfs on Ycode's volume (`lzbitmap.md` §4.2; DecmpfsVolume.swift): the
/// writer's calls succeed, and setting UF_COMPRESSED decompresses the file
/// into its data.
@Suite struct DecmpfsVolumeTests {
    static let oRDWR: Int32 = 0x2, oCREAT: Int32 = 0x200

    func fixture() throws -> (TempTree, DarwinFileSystem) {
        let tree = try TempTree()
        try tree.mkdir("var")
        let fs = DarwinFileSystem(prefixes: [.init(guestPath: "/data", hostPath: tree.host("var"), writable: true)],
                                  console: { _, _ in })
        return (tree, fs)
    }

    static func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
    static func header(type: UInt8, size: Int) -> [UInt8] {
        [0x66, 0x70, 0x6D, 0x63, type, 0, 0, 0] + le32(size) + [0, 0, 0, 0]
    }

    @Test func inlineFileReadsBackDecompressed() throws {
        let (tree, fs) = try fixture()
        defer { withExtendedLifetime(tree) {} }
        let fd = try fs.open("/data/a.txt", flags: Self.oRDWR | Self.oCREAT, mode: 0o644)
        let attr = Self.header(type: 13, size: 222) + LZBitmapTests.example
        try fs.setExtendedAttribute(.descriptor(fd), name: Decmpfs.attributeName, value: attr, create: false, replace: false)
        try fs.setFileFlags(.descriptor(fd), Decmpfs.compressedFlag)
        #expect(try fs.pread(fd, count: 1000, offset: 0) == LZBitmapTests.exampleText)
        #expect(try fs.stat("/data/a.txt", followSymlinks: true).size == 222)
        // The attribute is gone; the flag is not kept (the file is plain now).
        #expect(try !fs.listExtendedAttributes(.descriptor(fd)).contains(Decmpfs.attributeName))
        #expect(try fs.stat("/data/a.txt", followSymlinks: true).flags & Decmpfs.compressedFlag == 0)
    }

    @Test func forkFileWrittenAtAPosition() throws {
        let (tree, fs) = try fixture()
        defer { withExtendedLifetime(tree) {} }
        let fd = try fs.open("/data/b.bin", flags: Self.oRDWR | Self.oCREAT, mode: 0o644)
        let first = (0..<65_536).map { UInt8(truncatingIfNeeded: $0 &* 7) }
        let block0 = [UInt8(0xFF)] + first, block1 = LZBitmapTests.example
        let table = Self.le32(12) + Self.le32(12 + block0.count) + Self.le32(12 + block0.count + block1.count)
        let t = DarwinFileSystem.XattrTarget.descriptor(fd)
        // The writer's order: blocks at position 12, then the table at 0 (it must not truncate).
        try fs.writeResourceFork(t, value: block0 + block1, position: 12, create: false, replace: false)
        try fs.writeResourceFork(t, value: table, position: 0, create: false, replace: false)
        #expect(try fs.getExtendedAttribute(t, name: Decmpfs.resourceForkName) == table + block0 + block1)
        #expect(try fs.listExtendedAttributes(t).contains(Decmpfs.resourceForkName))
        try fs.setExtendedAttribute(t, name: Decmpfs.attributeName, value: Self.header(type: 14, size: 65_536 + 222),
                                    create: false, replace: false)
        try fs.setFileFlags(t, Decmpfs.compressedFlag)
        let back = try fs.pread(fd, count: 70_000, offset: 0)
        #expect(back == first + LZBitmapTests.exampleText)
        #expect(try !fs.listExtendedAttributes(t).contains(Decmpfs.resourceForkName))
        #expect(throws: DarwinErrnoError.self) { try fs.getExtendedAttribute(t, name: Decmpfs.resourceForkName) }
    }

    @Test func anInvalidHeaderLeavesTheFileAlone() throws {
        let (tree, fs) = try fixture()
        defer { withExtendedLifetime(tree) {} }
        let fd = try fs.open("/data/c", flags: Self.oRDWR | Self.oCREAT, mode: 0o644)
        _ = try fs.write(fd, Array("plain".utf8))
        let t = DarwinFileSystem.XattrTarget.descriptor(fd)
        try fs.setExtendedAttribute(t, name: Decmpfs.attributeName, value: [1, 2, 3], create: false, replace: false)
        try fs.setFileFlags(t, Decmpfs.compressedFlag)
        #expect(try fs.pread(fd, count: 100, offset: 0) == Array("plain".utf8))
        #expect(try fs.getExtendedAttribute(t, name: Decmpfs.attributeName) == [1, 2, 3])
    }
}
