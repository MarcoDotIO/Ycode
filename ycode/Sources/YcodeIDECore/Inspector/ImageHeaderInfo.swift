import Foundation

/// The File inspector's Image Properties for the Linux IDE, read from the
/// file's header without decoding it (the macOS IDE reads them with Image
/// I/O): PNG's IHDR and pHYs chunks (the PNG specification, ISO/IEC 15948),
/// the rows the macOS inspector shows (`editor-area.md` §C.6, §D.8). Other
/// formats read "--" (F.8: the not-yet-known state).
public struct ImageHeaderInfo: Equatable, Sendable {
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var hasAlpha: Bool
    public var colorModel: String
    /// Dots per inch, when the file records a resolution.
    public var dpi: Int?

    /// The extensions the inspector treats as images (its Image Properties
    /// and Localization sections; no Text Settings).
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "heif", "bmp", "webp", "ico", "icns"]

    public static func isImage(_ url: URL) -> Bool { imageExtensions.contains(url.pathExtension.lowercased()) }

    /// Dimensions, Resolution, Color Space, Alpha Channel, worded as the
    /// macOS inspector words them.
    public var rows: [(String, String)] {
        [("Dimensions", "\(pixelWidth) × \(pixelHeight) pixels"),
         ("Resolution", dpi.map { "\($0) × \($0) DPI" } ?? "--"),
         ("Color Space", colorModel),
         ("Alpha Channel", hasAlpha ? "Yes" : "No")]
    }

    /// The rows before (or without) a readable header.
    public static let placeholderRows: [(String, String)] = ["Dimensions", "Resolution", "Color Space", "Alpha Channel"].map { ($0, "--") }

    /// Reads a PNG file's header; nil for anything else.
    public static func read(_ url: URL) -> ImageHeaderInfo? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        // The signature, IHDR, and room for the ancillary chunks before IDAT.
        guard let data = try? h.read(upToCount: 64 * 1024) else { return nil }
        return parsePNG([UInt8](data))
    }

    static func parsePNG(_ b: [UInt8]) -> ImageHeaderInfo? {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard b.count >= 33, Array(b[0..<8]) == signature else { return nil }
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        func type(_ i: Int) -> String { String(decoding: b[i..<(i + 4)], as: UTF8.self) }
        guard type(12) == "IHDR" else { return nil }
        let colorType = b[25]
        // Colour types 4 and 6 carry alpha; grey (0, 4) is "Gray".
        var info = ImageHeaderInfo(pixelWidth: u32(16), pixelHeight: u32(20), hasAlpha: colorType == 4 || colorType == 6,
                                   colorModel: colorType == 0 || colorType == 4 ? "Gray" : "RGB", dpi: nil)
        var i = 8
        while i + 8 <= b.count {
            let length = u32(i), name = type(i + 4)
            if name == "IDAT" || name == "IEND" { break }
            if name == "tRNS" { info.hasAlpha = true }
            // pHYs: pixels per unit on x and y, unit 1 = metre.
            if name == "pHYs", i + 17 <= b.count, b[i + 16] == 1 {
                info.dpi = Int((Double(u32(i + 8)) * 0.0254).rounded())
            }
            i += 12 + length
        }
        return info
    }
}
