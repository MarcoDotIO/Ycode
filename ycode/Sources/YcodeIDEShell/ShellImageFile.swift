import Foundation

/// An image file in the Linux IDE's image editor (`specs/ide/editor-area.md`
/// §C.6, E.3, F.8; `cross-platform-parity.md` §4): which files it shows and
/// what their headers say (the File inspector's Image Properties). The
/// macOS IDE reads the same values through ImageIO
/// (`ImageViewerController`); here they come from the PNG and JPEG headers,
/// the formats the Linux toolkit decodes.
public struct ShellImageFile: Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Dots per inch; nil when the file records none (the inspector shows "--").
    public var dpi: Double?
    /// "RGB", "Gray" or "CMYK".
    public var colorSpace: String
    public var hasAlpha: Bool

    public init(pixelWidth: Int, pixelHeight: Int, dpi: Double?, colorSpace: String, hasAlpha: Bool) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.dpi = dpi
        self.colorSpace = colorSpace
        self.hasAlpha = hasAlpha
    }

    /// The image types the image editor shows (any image, as the macOS IDE:
    /// a type the toolkit cannot decode shows the editor's failure text).
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "bmp", "heic", "heif", "webp", "ico"]
    /// The types the Linux toolkit decodes.
    public static let decodableExtensions: Set<String> = ["png", "jpg", "jpeg"]

    /// Whether `path` opens in the image editor.
    public static func handles(_ path: String) -> Bool {
        imageExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// The size in points: pixels at the file's resolution (72 dpi is 1:1).
    public var pointSize: CGSize {
        let scale = dpi.map { $0 > 0 ? 72 / $0 : 1 } ?? 1
        return CGSize(width: Double(pixelWidth) * scale, height: Double(pixelHeight) * scale)
    }

    /// The inspector rows, as the macOS IDE words them.
    public var rows: [(String, String)] {
        [("Dimensions", "\(pixelWidth) × \(pixelHeight) pixels"),
         ("Resolution", dpi.map { "\(Int($0.rounded())) × \(Int($0.rounded())) DPI" } ?? "--"),
         ("Color Space", colorSpace),
         ("Alpha Channel", hasAlpha ? "Yes" : "No")]
    }

    /// The rows before the header has been read.
    public static let placeholderRows: [(String, String)] = ["Dimensions", "Resolution", "Color Space", "Alpha Channel"].map { ($0, "--") }

    /// Reads the header of the file at `path` (nil: not a PNG or JPEG, or unreadable).
    public static func read(path: String) -> ShellImageFile? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        // The header and the chunks or segments before the pixels.
        guard let data = try? h.read(upToCount: 256 * 1024) else { return nil }
        return parse([UInt8](data))
    }

    /// Parses a PNG or JPEG header.
    public static func parse(_ b: [UInt8]) -> ShellImageFile? {
        if b.count >= 24, b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return png(b) }
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xD8 { return jpeg(b) }
        return nil
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }

    /// IHDR (size, colour type), tRNS (alpha), pHYs (resolution).
    static func png(_ b: [UInt8]) -> ShellImageFile? {
        var i = 8
        var out: ShellImageFile?
        while i + 8 <= b.count {
            let length = be32(b, i)
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let body = i + 8
            guard length >= 0, body + length <= b.count else { break }
            switch type {
            case "IHDR" where length >= 13:
                let colorType = b[body + 9]
                out = ShellImageFile(pixelWidth: be32(b, body), pixelHeight: be32(b, body + 4), dpi: nil,
                                     colorSpace: colorType == 0 || colorType == 4 ? "Gray" : "RGB",
                                     hasAlpha: colorType == 4 || colorType == 6)
            case "tRNS": out?.hasAlpha = true
            case "pHYs" where length >= 9:
                // Pixels per metre, when the unit is the metre.
                if b[body + 8] == 1 { out?.dpi = (Double(be32(b, body)) * 0.0254).rounded() }
            case "IDAT", "IEND": return out
            default: break
            }
            i = body + length + 4
        }
        return out
    }

    /// APP0 (JFIF density) and the frame header (size, components).
    static func jpeg(_ b: [UInt8]) -> ShellImageFile? {
        var i = 2
        var dpi: Double?
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { i += 1; continue }
            let marker = b[i + 1]
            if marker == 0xD8 || marker == 0x01 || (0xD0...0xD7).contains(marker) { i += 2; continue }
            let length = be16(b, i + 2)
            let body = i + 4
            guard length >= 2, body + length - 2 <= b.count else { return nil }
            if marker == 0xE0, length >= 16, b[body] == 0x4A, b[body + 1] == 0x46 {
                let unit = b[body + 7], x = Double(be16(b, body + 8))
                if unit == 1, x > 0 { dpi = x } else if unit == 2, x > 0 { dpi = (x * 2.54).rounded() }
            }
            // SOF0–SOF15 except DHT (C4), JPG (C8) and DAC (CC).
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker), length >= 8 {
                let components = b[body + 5]
                return ShellImageFile(pixelWidth: be16(b, body + 3), pixelHeight: be16(b, body + 1), dpi: dpi,
                                      colorSpace: components == 1 ? "Gray" : (components == 4 ? "CMYK" : "RGB"), hasAlpha: false)
            }
            if marker == 0xDA { return nil }
            i = body + length - 2
        }
        return nil
    }
}
