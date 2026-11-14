// `ycode-simd --check-encoders`: whether the display stream's tile encoders
// work on this machine (display-stream.md §4.3), without booting anything.
// A release's smoke check runs it (packaging/flatpak/check-sim-tree.sh):
// a JPEG library that loads but cannot encode for this build used to be
// offered to viewers, and every frame then came without its tiles.

import CYcodeCodec
import Foundation

enum EncoderCheck {
    static func isRequested(_ arguments: [String]) -> Bool { arguments.dropFirst().first == "--check-encoders" }

    /// One line per encoder; exit status 0 when JPEG and zlib both encode a
    /// test picture that decodes again, 1 otherwise.
    static func run() -> Never {
        let (w, h) = (64, 48)
        var picture = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                picture[i] = UInt8(x * 4)
                picture[i + 1] = UInt8(y * 5)
                picture[i + 2] = 160
                picture[i + 3] = 255
            }
        }
        var ok = true
        if let why = ycodec_jpeg_problem() {
            print("jpeg: unavailable: \(String(cString: why))")
            ok = false
        } else {
            var out: UnsafeMutablePointer<UInt8>?
            var size = 0
            if ycodec_jpeg_encode_bgra(picture, Int32(w), Int32(h), w * 4, 75, &out, &size) == 0, let out, size > 0 {
                var back = [UInt8](repeating: 0, count: w * h * 4)
                let decoded = ycodec_jpeg_decode_bgra(out, size, Int32(w), Int32(h), &back, w * 4) == 0
                ycodec_free(out)
                print(decoded ? "jpeg: ok (libjpeg ABI \(ycodec_jpeg_abi_version()), \(size) bytes for a \(w)x\(h) test picture)"
                              : "jpeg: the test picture does not decode")
                ok = ok && decoded
            } else {
                print("jpeg: the test picture did not encode")
                ok = false
            }
        }
        if ycodec_zlib_available() == 0 {
            print("zlib: unavailable: no libz.so.1")
            ok = false
        } else {
            var cap = ycodec_zlib_bound(picture.count)
            var out = [UInt8](repeating: 0, count: cap)
            let r = out.withUnsafeMutableBufferPointer { ycodec_zlib_compress(picture, picture.count, 1, $0.baseAddress, &cap) }
            print(r == 0 && cap > 0 ? "zlib: ok (\(cap) bytes)" : "zlib: the test picture did not compress")
            ok = ok && r == 0 && cap > 0
        }
        exit(ok ? 0 : 1)
    }
}
