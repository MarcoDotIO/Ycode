import Foundation
import Testing
import OVText

// The fallback for a scalar the requested face lacks prefers a face whose
// glyphs OpenViews can draw. CFF outlines are not read (Outlines.swift), so
// a CFF-flavoured face that sorts first (Noto Sans CJK before Droid Sans
// Fallback on a Linux system) left composed CJK text invisible (issue 23).
// The CFF face here is the bundled Noto Sans with its `glyf` table renamed:
// it maps every character but has no outlines to draw.

private let bundledNoto = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Sources/OVText/Resources/Fonts/NotoSans-Regular.ttf")

/// The font with the `glyf` entry of its table directory renamed `CFF `.
private func withoutTrueTypeOutlines(_ data: Data) -> Data {
    var bytes = [UInt8](data)
    let tables = Int(bytes[4]) << 8 | Int(bytes[5])
    for t in 0..<tables {
        let r = 12 + 16 * t
        if bytes[r..<r + 4].elementsEqual("glyf".utf8) {
            bytes.replaceSubrange(r..<r + 4, with: Array("CFF ".utf8))
        }
    }
    return Data(bytes)
}

/// A folder with the given fonts, by file name.
private func fontFolder(_ files: [String: Data]) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ov-fallback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, data) in files { try data.write(to: dir.appendingPathComponent(name)) }
    return dir
}

@Suite struct FontFallbackOutlineTests {
    @Test func fallbackPrefersAFaceWithOutlines() throws {
        let trueType = try Data(contentsOf: bundledNoto)
        let dir = try fontFolder(["a-cff.ttf": withoutTrueTypeOutlines(trueType), "b-truetype.ttf": trueType])
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = FontCatalog()
        catalog.addDirectory(dir)
        let face = try #require(catalog.fallback(for: "x", near: FontTraits()))
        let glyph = try #require(face.glyph(for: "x"))
        #expect(face.outline(of: glyph) != nil)
    }

    @Test func aFaceWithoutOutlinesIsTheLastResort() throws {
        let dir = try fontFolder(["a-cff.ttf": withoutTrueTypeOutlines(try Data(contentsOf: bundledNoto))])
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = FontCatalog()
        catalog.addDirectory(dir)
        let face = try #require(catalog.fallback(for: "x", near: FontTraits()))
        #expect(face.glyph(for: "x") != nil)
        #expect(face.outline(of: face.glyph(for: "x")!) == nil)
    }
}
