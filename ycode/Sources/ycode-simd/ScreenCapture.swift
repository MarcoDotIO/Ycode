// ycode-simd --device --screenshot: PNG captures of the presented display
// buffer. The headless SimFramebuffer library writes a frame record (the
// presented IOSurface's ID) to DEV/data/tmp/ycode-framebuffer.state; the
// VMM's IOSurface service holds that surface's memory. A capture converts
// it from BGRA (honoring bytes per row) to RGBA and writes a PNG.

import Foundation
import YcodeHostServices

struct ScreenCapture {
    let statePath: String
    let service: IOSurfaceHostService

    /// The surface ID of the latest frame record, if any.
    func presentedSurface() -> UInt32? {
        guard let data = FileManager.default.contents(atPath: statePath) else { return nil }
        let words = String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == " " || $0 == "\n" })
        guard let i = words.firstIndex(of: "surface"), i + 1 < words.count else { return nil }
        return UInt32(words[i + 1])
    }

    /// Writes a PNG of the presented surface (or, with no frame record yet,
    /// of the largest surface named "LCD") to `path`. Returns a description.
    func capture(to path: String) -> String {
        var id = presentedSurface()
        var how = "presented surface"
        if id == nil {
            id = service.surfaceSummary.filter { $0.name.hasPrefix("LCD") }.max { $0.width * $0.height < $1.width * $1.height }?.id
            how = "no frame presented yet; the display buffer"
        }
        guard let id, let s = service.snapshot(surfaceID: id) else {
            return "no surface to capture (\(service.surfaceSummary.count) surfaces exist)"
        }
        guard s.bytesPerElement == 4, s.width > 0, s.height > 0 else {
            return "surface \(id) (\(s.name)) is \(s.width)x\(s.height) with \(s.bytesPerElement) bytes per element: not captured"
        }
        let rgba = PNG.rgba(fromBGRA: s.bytes, width: s.width, height: s.height, bytesPerRow: s.bytesPerRow)
        let nonzero = rgba.lazy.enumerated().contains { $0.offset % 4 != 3 && $0.element != 0 }
        let png = PNG.encode(width: s.width, height: s.height, rgba: rgba)
        do {
            try Data(png).write(to: URL(fileURLWithPath: path))
        } catch {
            return "cannot write \(path): \(error)"
        }
        return "\(path): \(how) \(id) (\(s.name)), \(s.width)x\(s.height), \(png.count) bytes" + (nonzero ? "" : ", all black")
    }
}
