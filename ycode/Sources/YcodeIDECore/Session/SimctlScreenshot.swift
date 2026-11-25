#if canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif
import Foundation

/// Screenshot of a Mac simulator (`specs/ide/device-hub.md`, "Ycode
/// decisions (2026-11-17)", "The Mac's own simulators", "Screenshot"):
/// `simctl io <udid> screenshot <file>`. A device with several screens
/// makes simctl refuse (code 22) and list them; then each listed screen is
/// captured with `--display=<id>`, the pictures that are entirely black (a
/// screen that is off) are dropped unless all are, and the kept files carry
/// the screen's name in parentheses when there is more than one.
extension SimctlDeviceControl {
    /// One screen from simctl's list: `--display=1  LCD (primary) 1398x2034`.
    public struct SimctlDisplay: Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The screens simctl lists when it cannot choose one (empty for any
    /// other output). Each line is `--display=<id>`, spaces, the screen's
    /// name and its size `<width>x<height>`.
    public static func displays(inScreenshotRefusal output: String) -> [SimctlDisplay] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("--display=") else { return nil }
            let rest = line.dropFirst("--display=".count)
            guard let space = rest.firstIndex(where: \.isWhitespace) else { return nil }
            let id = String(rest[..<space])
            var words = rest[space...].split(separator: " ").map(String.init)
            if let last = words.last, isSize(last) { words.removeLast() }
            let name = words.joined(separator: " ")
            return id.isEmpty ? nil : SimctlDisplay(id: id, name: name.isEmpty ? id : name)
        }
    }

    private static func isSize(_ s: String) -> Bool {
        let parts = s.split(separator: "x")
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    public static func screenshotArguments(_ udid: String, display: String, to path: String) -> [String] {
        ["io", udid, "screenshot", "--display=\(display)", path]
    }

    /// `path` with ` (<screen>)` before its extension.
    public static func path(_ path: String, screen: String) -> String {
        let url = URL(fileURLWithPath: path)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().path
        let name = screen.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return base + " (\(name))" + (ext.isEmpty ? "" : ".\(ext)")
    }

    /// The banner after a capture: "Screenshot Saved" or "N Screenshots Saved".
    public static func savedMessage(_ count: Int) -> String {
        count == 1 ? "Screenshot Saved" : "\(count) Screenshots Saved"
    }

    /// Screenshot: simctl's own picture of the device's screen, saved at
    /// `path`, or one picture per lit screen of a multi-screen device.
    public func screenshot(_ udid: String, to path: String) -> (Bool, String) {
        let (s, out) = simctl.run(Self.screenshotArguments(udid, to: path))
        if s == 0 { return (true, Self.savedMessage(1)) }
        let screens = Self.displays(inScreenshotRefusal: out)
        guard !screens.isEmpty else { return (false, Self.failure("take a screenshot of", out)) }
        return screenshot(udid, screens: screens, to: path)
    }

    private func screenshot(_ udid: String, screens: [SimctlDisplay], to path: String) -> (Bool, String) {
        let fm = FileManager.default
        var captured: [(screen: SimctlDisplay, file: String)] = []
        var lastFailure = ""
        for screen in screens {
            let file = Self.path(path, screen: screen.name)
            let (s, out) = simctl.run(Self.screenshotArguments(udid, display: screen.id, to: file))
            if s == 0 { captured.append((screen, file)) } else { lastFailure = out }
        }
        guard let first = captured.first else { return (false, Self.failure("take a screenshot of", lastFailure)) }
        var kept = captured.filter { !isBlackImage($0.file) }
        if kept.isEmpty { kept = [first] }
        for c in captured where !kept.contains(where: { $0.file == c.file }) { try? fm.removeItem(atPath: c.file) }
        if kept.count == 1 {
            // One picture kept: the plain name.
            try? fm.removeItem(atPath: path)
            if (try? fm.moveItem(atPath: kept[0].file, toPath: path)) == nil { return (true, Self.savedMessage(1)) }
        }
        return (true, Self.savedMessage(kept.count))
    }

    /// Whether the picture at `path` is entirely black (every pixel's red,
    /// green and blue are 0). A picture that cannot be read is not black.
    public static let imageIsBlack: @Sendable (String) -> Bool = { path in
        #if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return false }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return false }
        var i = 0
        while i < pixels.count {
            if pixels[i] != 0 || pixels[i + 1] != 0 || pixels[i + 2] != 0 { return false }
            i += 4
        }
        return true
        #else
        return false
        #endif
    }
}
