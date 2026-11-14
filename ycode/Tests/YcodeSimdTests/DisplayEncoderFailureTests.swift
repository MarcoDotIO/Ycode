import CYcodeCodec
import Foundation
import Testing
@testable import ycode_simd

/// A JPEG encoder that cannot work is reported, never a stream of frames
/// without tiles (the 1.0.0-beta.2 aarch64 release: its libjpeg header was
/// ABI 62, the host's unversioned libjpeg.so was ABI 80, every picture
/// failed in jpeg_CreateCompress and the frames went out empty).
struct DisplayEncoderFailureTests {
    /// Libraries to try: this build's ABI first, then the usual names.
    private static let candidates = ["libjpeg.so.62", "libjpeg.so.8", "libjpeg.so", "/opt/homebrew/lib/libjpeg.dylib",
                                     "/usr/local/lib/libjpeg.dylib"]

    @Test func jpegIsOfferedOnlyWithAReasonWhenItIsNot() {
        let available = ycodec_jpeg_available() != 0
        #expect(available == (ycodec_jpeg_problem() == nil))
        if !available {
            let why = String(cString: ycodec_jpeg_problem()!)
            #expect(!why.isEmpty)
            // A missing encoder is not offered to viewers.
            #expect(ycodec_jpeg_encode_bgra([0, 0, 0, 255], 1, 1, 4, 75, nil, nil) == -1)
        }
    }

    @Test func aLibraryOfAnotherABIIsRejectedWithTheLibrarysReason() {
        let abi = ycodec_jpeg_abi_version()
        guard abi > 0 else { return }  // built without jpeglib.h: nothing to load
        var why = [CChar](repeating: 0, count: 512)
        guard let usable = Self.candidates.first(where: { ycodec_jpeg_probe_library($0, abi, &why, why.count) == 0 }) else { return }
        // The same library, asked for by a caller of another ABI: what an
        // ABI-62 build met in an ABI-80 libjpeg.so.
        let other: Int32 = abi == 80 ? 62 : 80
        #expect(ycodec_jpeg_probe_library(usable, other, &why, why.count) == -1)
        let reason = String(cString: why)
        #expect(reason.hasPrefix(usable + ": "))
        #expect(reason.contains("version"), "the library's own message names the version mismatch: \(reason)")
    }

    @Test func aWorkingEncoderProducesTilesThatDecode() {
        guard ycodec_jpeg_available() != 0 else { return }
        let (w, h) = (64, 64)
        var surface = [UInt8](repeating: 0, count: w * h * 4)
        for i in stride(from: 0, to: surface.count, by: 4) { surface[i] = 30; surface[i + 1] = 140; surface[i + 2] = 220; surface[i + 3] = 255 }
        let m = DisplayMirror(width: w, height: h, tile: 32)
        let rects = surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: w * 4, full: true) }
        let (tiles, failed) = TileEncoder(encoding: .jpeg, quality: 75, downscale: 1).encodeAllChecked(rects, mirror: m)
        #expect(failed == 0)
        #expect(tiles.count == rects.count && tiles.allSatisfy { $0.data.count > 100 })
        var back = [UInt8](repeating: 0, count: w * h * 4)
        #expect(ycodec_jpeg_decode_bgra(tiles[0].data, tiles[0].data.count, Int32(w), Int32(h), &back, w * 4) == 0)
        #expect(abs(Int(back[2]) - 220) < 24)
    }

    @Test func failedTilesAreCountedNotDropped() {
        let (w, h) = (96, 600)
        let surface = [UInt8](repeating: 77, count: w * h * 4)
        let m = DisplayMirror(width: w, height: h, tile: 32)
        _ = surface.withUnsafeBytes { m.update(from: $0.baseAddress!, bytesPerRow: w * 4, full: true) }
        // A zero-width rectangle cannot be encoded by any encoder: the
        // result says so instead of handing back a shorter tile list.
        let rects = [PixelRect(x: 0, y: 0, width: w, height: 64), PixelRect(x: 32, y: 64, width: 0, height: 32)]
        let jpeg = TileEncoder(encoding: .jpeg, quality: 75, downscale: 1).encodeAllChecked(rects, mirror: m)
        #expect(jpeg.tiles.count + jpeg.failed == rects.count)
        #expect(jpeg.failed >= 1)
        if ycodec_jpeg_available() == 0 {
            // Without a working library every JPEG band fails, and is counted.
            let full = TileEncoder(encoding: .jpeg, quality: 75, downscale: 1)
                .encodeAllChecked([PixelRect(x: 0, y: 0, width: w, height: h)], mirror: m)
            #expect(full.tiles.isEmpty && full.failed == TileEncoder.bands([PixelRect(x: 0, y: 0, width: w, height: h)], downscale: 1).count)
        }
    }

    @Test func failedJPEGFallsBackToZlibAndFailedZlibEnds() {
        #expect(TileEncoder.fallback(after: .jpeg, zlibAvailable: true) == .zlibBGRA)
        #expect(TileEncoder.fallback(after: .jpeg, zlibAvailable: false) == nil)
        #expect(TileEncoder.fallback(after: .zlibBGRA, zlibAvailable: true) == nil)
    }
}
