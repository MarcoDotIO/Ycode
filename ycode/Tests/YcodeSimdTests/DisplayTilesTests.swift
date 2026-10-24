import Foundation
import Testing
import YcodeDisplayStream
@testable import ycode_simd

/// The display server's tile comparison and encoding (display-stream.md §4).
struct DisplayTilesTests {
    @Test func frameRecord() {
        let r = FrameRecord.parse("ycode-framebuffer 1 display 1 surface 17 rect 0 0 1398 2034 frame 342          \n")
        #expect(r == FrameRecord(surface: 17, frame: 342))
        #expect(FrameRecord.parse("garbage") == nil)
    }

    @Test func mirrorFindsChangedTiles() {
        let w = 100, h = 70, bpr = 104 * 4
        var surface = [UInt8](repeating: 0, count: bpr * h)
        let m = DisplayMirror(width: w, height: h, tile: 32)
        // Identical: nothing.
        #expect(surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: bpr, full: false) }.isEmpty)
        // Full: everything.
        #expect(surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: bpr, full: true) }
            == [PixelRect(x: 0, y: 0, width: w, height: h)])
        // One pixel in tile (2, 1) → that tile.
        surface[40 * bpr + 70 * 4 + 1] = 9
        let rects = surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: bpr, full: false) }
        #expect(rects == [PixelRect(x: 64, y: 32, width: 32, height: 32)])
        // The mirror now has it: no change left.
        #expect(surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: bpr, full: false) }.isEmpty)
    }

    @Test func mergeJoinsRunsAndRows() {
        // 8x4 tiles; row 0: tiles 0 and 2 (gap of one → one run 0..<3); rows 1-2: tiles 5..<7.
        var d = [Bool](repeating: false, count: 32)
        d[0] = true; d[2] = true
        d[8 + 5] = true; d[8 + 6] = true; d[16 + 5] = true; d[16 + 6] = true
        let rects = DisplayMirror.merge(dirty: d, tilesX: 8, tilesY: 4, tile: 10, width: 80, height: 40)
        #expect(rects.contains(PixelRect(x: 0, y: 0, width: 30, height: 10)))
        #expect(rects.contains(PixelRect(x: 50, y: 10, width: 20, height: 20)))
        #expect(rects.count == 2)
        // Most of the screen → one bounding box.
        let most = DisplayMirror.merge(dirty: [Bool](repeating: true, count: 32), tilesX: 8, tilesY: 4, tile: 10, width: 75, height: 40)
        #expect(most == [PixelRect(x: 0, y: 0, width: 75, height: 40)])
    }

    @Test func zlibTilesDecodeToTheMirror() throws {
        let w = 64, h = 64
        var surface = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<surface.count { surface[i] = UInt8(truncatingIfNeeded: i / 3) }
        let m = DisplayMirror(width: w, height: h, tile: 64)
        let rects = surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: w * 4, full: true) }
        var enc = TileEncoder(encoding: .zlibBGRA, quality: 75, downscale: 2)
        guard let tile = enc.encode(rects[0], mirror: m) else { return } // no zlib here
        #expect(tile.width == 32 && tile.height == 32 && tile.data.first == 0x78)
    }

    @Test func tallRectanglesAreCutIntoAlignedBands() {
        // Full 1398 x 2034 at downscale 1: bands of 256 rows, the last one shorter.
        let full = TileEncoder.bands([PixelRect(x: 0, y: 0, width: 1398, height: 2034)], downscale: 1)
        #expect(full.count == 8)
        #expect(full.allSatisfy { $0.x == 0 && $0.width == 1398 && $0.y % 256 == 0 })
        #expect(full.reduce(0) { $0 + $1.height } == 2034)
        // A rectangle starting mid-band is cut at band multiples from the top.
        let mid = TileEncoder.bands([PixelRect(x: 32, y: 192, width: 64, height: 320)], downscale: 1)
        #expect(mid == [PixelRect(x: 32, y: 192, width: 64, height: 64), PixelRect(x: 32, y: 256, width: 64, height: 256)])
        // Downscale 2: bands of 512 device rows; short rectangles stay whole.
        #expect(TileEncoder.bands([PixelRect(x: 0, y: 0, width: 64, height: 512)], downscale: 2).count == 1)
        #expect(TileEncoder.bands([PixelRect(x: 0, y: 0, width: 64, height: 1024)], downscale: 2).count == 2)
    }

    @Test func parallelEncodingKeepsOrderAndCoversTheImage() {
        let w = 96, h = 600
        var surface = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<surface.count { surface[i] = UInt8(truncatingIfNeeded: i &* 7) }
        let m = DisplayMirror(width: w, height: h, tile: 32)
        let rects = surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: w * 4, full: true) }
        let tiles = TileEncoder(encoding: .zlibBGRA, quality: 75, downscale: 1).encodeAll(rects, mirror: m)
        guard !tiles.isEmpty else { return } // no zlib here
        #expect(tiles.map(\.y) == [0, 256, 512])
        #expect(tiles.reduce(0) { $0 + $1.height } == h)
    }

    @Test func pngSignature() {
        let png = CompressedPNG.encode(width: 2, height: 2, rgba: [UInt8](repeating: 200, count: 16))
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(CompressedPNG.crc(Array("IEND".utf8)) == 0xAE42_6082)
    }
}
