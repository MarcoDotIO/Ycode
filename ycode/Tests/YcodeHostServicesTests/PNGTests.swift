import Testing
@testable import YcodeHostServices

@Suite struct PNGTests {
    @Test func knownChecksumsAndLayout() {
        #expect(PNG.crc32(Array("IEND".utf8)) == 0xAE42_6082)       // the well-known IEND CRC
        #expect(PNG.adler32(Array("Wikipedia".utf8)) == 0x11E6_0398)
        let rgba = PNG.rgba(fromBGRA: [1, 2, 3, 4, 9, 9, 9, 9], width: 1, height: 1, bytesPerRow: 8)
        #expect(rgba == [3, 2, 1, 4])
        let png = PNG.encode(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 255, 0, 255])
        #expect(Array(png[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(Array(png[12..<16]) == Array("IHDR".utf8) && Array(png.suffix(12)) == [0, 0, 0, 0] + Array("IEND".utf8) + [0xAE, 0x42, 0x60, 0x82])
        // The sRGB chunk follows IHDR (uikit-feel-ycode.md §8.1): length 1, "sRGB", intent 0, CRC.
        #expect(Array(png[33..<46]) == [0, 0, 0, 1] + Array("sRGB".utf8) + [0, 0xAE, 0xCE, 0x1C, 0xE9])
    }
}
