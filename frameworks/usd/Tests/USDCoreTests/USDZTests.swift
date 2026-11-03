import Testing
@testable import USDCore

@Suite struct USDZTests {
    /// `props.usdz` was packaged by OpenUSD (usd-core) from `props.usda`.
    @Test func readsOpenUSDPackages() throws {
        let archive = try USDZArchive.read(try Fixture.bytes("props.usdz"))
        #expect(archive.rootLayer?.name == "props.usda")
        let layer = try Fixture.layer("props.usdz")
        #expect(layer.identifier == "props.usdz[props.usda]")
        #expect(differences(layer, try Fixture.layer("props.usda")).isEmpty)
        for (_, offset) in try USDZArchive.dataOffsets(try Fixture.bytes("props.usdz")) { #expect(offset % 64 == 0) }
    }

    @Test func writesAlignedPackages() throws {
        let layer = try Fixture.layer("scene.usda")
        let texture = (0..<333).map { UInt8($0 % 251) }
        let archive = try LayerIO.package(root: layer, rootName: "scene.usdc", assets: [
            USDZArchive.Entry(name: "textures/albedo.png", data: texture),
            USDZArchive.Entry(name: "props.usda", data: try Fixture.bytes("props.usda")),
        ])
        let bytes = archive.write()
        let offsets = try USDZArchive.dataOffsets(bytes)
        #expect(offsets.count == 3)
        for (_, offset) in offsets { #expect(offset % 64 == 0) }
        let back = try USDZArchive.read(bytes)
        #expect(back == archive)
        #expect(back.rootLayer?.name == "scene.usdc")
        #expect(differences(try LayerIO.read(bytes, identifier: "x.usdz"), layer).isEmpty)
    }

    @Test func rejectsCompressedEntriesAndBadChecksums() throws {
        var bytes = USDZArchive(entries: [.init(name: "a.usda", data: Array("#usda 1.0\n".utf8))]).write()
        var bad = bytes
        bad[14] ^= 0xFF // CRC in the local header is not checked; corrupt the data instead
        bad[64] ^= 0xFF
        #expect(throws: USDError.self) { try USDZArchive.read(bad) }
        bytes[8] = 8 // method: deflate
        let central = bytes.count - 22 - (46 + 6)
        bytes[central + 10] = 8
        #expect(throws: USDError.self) { try USDZArchive.read(bytes) }
    }

    @Test func crc32() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
    }
}
