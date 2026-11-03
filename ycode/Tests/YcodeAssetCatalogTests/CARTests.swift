import Foundation
import Testing
@testable import YcodeAssetCatalog
import YcodeIcon

/// CAR-WRITER phase 1 (specs/formats/assets-car.md): the container and
/// CoreUI structures byte for byte where the spec gives bytes, and
/// write-then-read round trips.
struct CARStructureTests {
    func sample(_ platform: CARPlatform = .iOS, compression: CARCompression = .lzfse) throws -> (Data, CARWriter) {
        var w = CARWriter(platform: platform, deploymentTarget: "27.0", compression: compression)
        w.add(CARRendition(name: "Brand", attributes: platform == .macOS ? [:] : [.idiom: 0], renditionName: "Brand",
                           content: .color(CARColor(colorSpace: 1, components: [1, 0, 0, 1]))))
        w.add(CARRendition(name: "Brand", attributes: [.appearance: 1], renditionName: "Brand", content: .color(CARColor(colorSpace: 1, components: [0, 0, 1, 1]))))
        w.add(CARRendition(name: "Tall", attributes: [.scale: 2], renditionName: "tall@2x.png", content: .image(Bitmap(width: 4, height: 1024, fill: (0, 1, 0, 1))), flags: 16))
        w.add(CARRendition(name: "AppIcon", renditionName: "AppIcon", content: .multisize([CARMultisizeEntry(width: 1024, height: 1024, index: 1)])))
        return (try w.data(), w)
    }

    @Test func bomHeaderBlocksAndVariables() throws {
        let (data, _) = try sample()
        let b = [UInt8](data)
        #expect(Array(b[0..<8]) == Array("BOMStore".utf8))
        #expect(b.u32be(at: 8) == 1)
        let bom = try BOMReader(data)
        let indexOffset = Int(b.u32be(at: 16)), indexLength = Int(b.u32be(at: 20))
        #expect(indexOffset + indexLength == b.count)
        #expect(bom.table.count >= 256)
        #expect(bom.table[0].offset == 0 && bom.table[0].length == 0)
        #expect(Array(b[(b.count - 20)...]) == [UInt8](repeating: 0, count: 20))
        let used = bom.table.dropFirst().filter { $0.length > 0 }
        #expect(bom.usedBlockCount == UInt32(used.count))
        #expect(used.allSatisfy { $0.offset >= 512 && $0.offset % 16 == 0 })
        #expect(used.map(\.offset).min() == 512)
        #expect(Int(b.u32be(at: 24)) > Int(used.map { $0.offset + $0.length }.max()!) - 1)
        #expect(Set(bom.variables.map(\.name)) == ["CARHEADER", "EXTENDED_METADATA", "KEYFORMAT", "APPEARANCEKEYS", "FACETKEYS", "RENDITIONS"])
    }

    @Test func carHeaderIs436Bytes() throws {
        let (data, w) = try sample()
        let bom = try BOMReader(data)
        let h = Array(try bom.block(bom.variable("CARHEADER")!))
        #expect(h.count == 436)
        #expect(Array(h[0..<4]) == Array("RATC".utf8))
        #expect(h.u32le(at: 4) == 1010 && h.u32le(at: 8) == 17 && h.u32le(at: 12) == 0)
        #expect(h.u32le(at: 16) == 4)
        #expect(String(decoding: h[20..<148].prefix { $0 != 0 }, as: UTF8.self) == w.mainVersion)
        #expect(String(decoding: h[148..<404].prefix { $0 != 0 }, as: UTF8.self) == w.versionString)
        #expect(Array(h[404..<420]) == [UInt8](repeating: 0, count: 16))
        #expect(h.u32le(at: 420) == 0 && h.u32le(at: 424) == 2 && h.u32le(at: 428) == 1 && h.u32le(at: 432) == 2)
        let mac = try BOMReader(try sample(.macOS).0)
        #expect(Array(try mac.block(mac.variable("CARHEADER")!)).u32le(at: 432) == 1)
    }

    @Test func extendedMetadataIs1028Bytes() throws {
        let bom = try BOMReader(try sample().0)
        let m = Array(try bom.block(bom.variable("EXTENDED_METADATA")!))
        #expect(m.count == 1028)
        #expect(Array(m[0..<4]) == Array("META".utf8))
        #expect(m[4] == 0)
        #expect(String(decoding: m[260..<516].prefix { $0 != 0 }, as: UTF8.self) == "27.0")
        #expect(String(decoding: m[516..<772].prefix { $0 != 0 }, as: UTF8.self) == "ios")
        #expect(m[772] != 0)
    }

    @Test func keyFormatsPerPlatform() throws {
        func kf(_ p: CARPlatform) throws -> [UInt8] {
            let bom = try BOMReader(try sample(p).0)
            return Array(try bom.block(bom.variable("KEYFORMAT")!))
        }
        var ios = ByteWriter()
        ios.tag("tmfk")
        ios.u32le(0)
        ios.u32le(9)
        for v: UInt32 in [7, 13, 12, 15, 16, 9, 17, 1, 2] { ios.u32le(v) }
        #expect(try kf(.iOS) == ios.bytes)
        #expect(try kf(.watchOS) == ios.bytes)
        var mac = ByteWriter()
        mac.tag("tmfk")
        mac.u32le(0)
        mac.u32le(9)
        for v: UInt32 in [7, 13, 1, 2, 3, 17, 9, 11, 12] { mac.u32le(v) }
        #expect(try kf(.macOS) == mac.bytes)
    }

    @Test func renditionsTreeHasFixedKeysWithLeafCopies() throws {
        let bom = try BOMReader(try sample().0)
        let info = try bom.treeInfo("RENDITIONS")
        #expect(info.keyLength == 18 && !info.inlineKeys && info.blockSize == 4096 && info.pathCount == 4)
        let header = Array(try bom.block(bom.variable("RENDITIONS")!))
        #expect(header.count == 29 && Array(header[0..<4]) == Array("tree".utf8) && header.u32be(at: 4) == 1)
        let leaves = try bom.leaves("RENDITIONS")
        #expect(leaves.count == 1)
        let leaf = Array(try bom.block(leaves[0].block))
        #expect(leaf.u16be(at: 0) == 1 && leaf.u16be(at: 2) == 4)
        #expect(leaf.count == 4096 + 4 * 18)
        // 4 zero bytes after the entries, then the keys back to back.
        #expect(leaf.u32be(at: 12 + 4 * 8) == 0)
        #expect(Array(leaf[(16 + 4 * 8)..<(16 + 4 * 8 + 18)]) == Array(try bom.block(leaves[0].entries[0].key)))
        for (j, e) in leaves[0].entries.enumerated() { #expect(leaves[0].keyCopies[j] == Array(try bom.block(e.key))) }
        // Names use variable keys.
        #expect(try bom.treeInfo("FACETKEYS").keyLength == 0xFFFF_FFFF)
    }

    @Test func facetAndAppearanceValues() throws {
        let (data, _) = try sample()
        let bom = try BOMReader(data)
        let facets = try bom.tree("FACETKEYS")
        #expect(facets.map { String(decoding: $0.key, as: UTF8.self) } == ["AppIcon", "Brand", "Tall"])
        let ids = CARWriter.identifiers(for: ["AppIcon", "Brand", "Tall"])
        var v = ByteWriter()
        for x: UInt16 in [0, 0, 3, 1, 85, 2, 217, 17, ids["Brand"]!] { v.u16le(x) }
        #expect(facets[1].value == v.bytes)
        let ap = try bom.tree("APPEARANCEKEYS")
        #expect(ap.map { String(decoding: $0.key, as: UTF8.self) } == ["UIAppearanceAny", "UIAppearanceDark"])
        #expect(ap.map(\.value) == [[0, 0], [1, 0]])
    }

    @Test func csiHeaderAndTLVsOfAnImage() throws {
        let (data, _) = try sample()
        let bom = try BOMReader(data)
        let tall = try bom.tree("RENDITIONS").first { $0.value.u16le(at: 36) == 12 }!.value
        #expect(Array(tall[0..<4]) == Array("ISTC".utf8))
        #expect(tall.u32le(at: 4) == 1 && tall.u32le(at: 8) == 16)
        #expect(tall.u32le(at: 12) == 4 && tall.u32le(at: 16) == 1024 && tall.u32le(at: 20) == 200)
        #expect(Array(tall[24..<28]) == Array("BGRA".utf8))
        #expect(tall.u32le(at: 28) == 1 && tall.u32le(at: 32) == 0 && tall.u16le(at: 36) == 12 && tall.u16le(at: 38) == 0)
        #expect(String(decoding: tall[40..<168].prefix { $0 != 0 }, as: UTF8.self) == "tall@2x.png")
        let tlvLength = Int(tall.u32le(at: 168))
        #expect(tall.u32le(at: 172) == 1 && tall.u32le(at: 176) == 0)
        #expect(184 + tlvLength + Int(tall.u32le(at: 180)) == tall.count)
        var t = ByteWriter()
        for (type, words) in [(UInt32(1001), [1, 0, 0, 4, 1024]), (1003, [1, 0, 0, 0, 0, 4, 1024])] as [(UInt32, [UInt32])] {
            t.u32le(type)
            t.u32le(UInt32(words.count * 4))
            for w in words { t.u32le(w) }
        }
        t.u32le(1004); t.u32le(8); t.u32le(0); t.f32le(1)
        t.u32le(1006); t.u32le(4); t.u32le(1)
        t.u32le(1007); t.u32le(4); t.u32le(16)
        #expect(Array(tall[184..<(184 + tlvLength)]) == t.bytes)
        // CELM v1 (an image-set image may have alpha), LZFSE in KCBC chunks of height / 3 rows, the last with the rest.
        let p = Array(tall[(184 + tlvLength)...])
        #expect(Array(p[0..<4]) == Array("MLEC".utf8) && p.u32le(at: 4) == 1 && p.u32le(at: 8) == 4 && p.u32le(at: 12) == 3)
        var off = 16
        var rows: [UInt32] = []
        for _ in 0..<3 {
            #expect(Array(p[off..<off + 4]) == Array("KCBC".utf8) && p.u32le(at: off + 4) == 0 && p.u32le(at: off + 8) == 0)
            rows.append(p.u32le(at: off + 12))
            off += 20 + Int(p.u32le(at: off + 16))
        }
        #expect(rows == [341, 341, 342] && off == p.count)
    }

    @Test func colorAndMultisizePayloads() throws {
        let (data, _) = try sample()
        let rs = try BOMReader(data).tree("RENDITIONS").map(\.value)
        // The first component (an f64 at 184 + 28 + 16) is 1.0 for red, 0.0 for blue.
        let red = rs.first { $0.u16le(at: 36) == 1009 && $0.u32le(at: 232) != 0 }!
        #expect(red.u32le(at: 12) == 0 && red.u32le(at: 20) == 0 && Array(red[24..<28]) == [0, 0, 0, 0] && red.u32le(at: 28) == 0)
        let tl = Int(red.u32le(at: 168))
        var t = ByteWriter()
        t.u32le(1004); t.u32le(8); t.u32le(0); t.f32le(0)
        t.u32le(1006); t.u32le(4); t.u32le(1)
        #expect(Array(red[184..<(184 + tl)]) == t.bytes)
        var c = ByteWriter()
        c.tag("RLOC"); c.u32le(1); c.u32le(1); c.u32le(4)
        for x in [1.0, 0, 0, 1] { c.f64le(x) }
        #expect(Array(red[(184 + tl)...]) == c.bytes)
        let ms = rs.first { $0.u16le(at: 36) == 1010 }!
        var m = ByteWriter()
        m.tag("SISM"); m.u32le(1); m.u32le(1); m.u32le(1024); m.u32le(1024); m.u32le(1)
        #expect(Array(ms[(184 + Int(ms.u32le(at: 168)))...]) == m.bytes)
    }

    @Test func renditionKeysAreSortedAsStoredBytes() throws {
        let car = try CARFile(data: try sample().0)
        #expect(car.structureIssues.isEmpty)
        // By the stored bytes (little-endian values), the order the runtime searches.
        let keys = car.renditions.map { CARWriter.keyBytes($0.keyValues) }
        #expect(keys == keys.sorted { $0.lexicographicallyPrecedes($1) })
        #expect(car.renditions.allSatisfy { $0.key[.element] == 85 })
    }

    @Test func writeThenReadRoundTrips() throws {
        for comp in CARCompression.allCases {
            let car = try CARFile(data: try sample(compression: comp).0)
            #expect(car.header.renditionCount == 4)
            #expect(car.metadata?.platform == "ios")
            #expect(car.facets.map(\.name) == ["AppIcon", "Brand", "Tall"])
            let tall = car.renditions.first { car.facetName(for: $0) == "Tall" }!
            guard case .bitmap(let b, let c, _, _) = tall.payload else { Issue.record("no bitmap"); continue }
            #expect(b == Bitmap(width: 4, height: 1024, fill: (0, 1, 0, 1)))
            #expect(c == (comp == .lzfse ? 4 : 0))
            #expect(tall.key[.scale] == 2)
            let colors = car.renditions.filter { $0.part == CARPart.color }.map(\.payload)
            #expect(colors.contains(.color(CARColor(colorSpace: 1, components: [0, 0, 1, 1]))))
        }
    }

    @Test func largeTreesSplitIntoLeavesUnderABranch() throws {
        var w = CARWriter(platform: .iOS)
        for k in 0..<1200 {
            w.add(CARRendition(name: "C\(k)", renditionName: "C\(k)", content: .color(CARColor(colorSpace: 1, components: [Double(k) / 1200, 0, 0, 1]))))
        }
        let data = try w.data()
        let bom = try BOMReader(data)
        let leaves = try bom.leaves("RENDITIONS")
        #expect(leaves.count == 3)
        #expect(leaves.map(\.entries.count) == [510, 510, 180])
        #expect(leaves[0].backward == 0 && leaves[2].forward == 0 && leaves[0].forward == leaves[1].block && leaves[1].backward == leaves[0].block)
        let info = try bom.treeInfo("RENDITIONS")
        let root = Array(try bom.block(info.root))
        #expect(root.u16be(at: 0) == 0 && root.u16be(at: 2) == 3)
        let car = try CARFile(data: data)
        #expect(car.renditions.count == 1200 && car.facets.count == 1200 && car.structureIssues.isEmpty)
    }

    @Test func duplicateKeysAreAnError() {
        var w = CARWriter(platform: .iOS)
        for _ in 0..<2 { w.add(CARRendition(name: "X", renditionName: "X", content: .color(CARColor(colorSpace: 1, components: [0, 0, 0, 1])))) }
        #expect(throws: CARWriter.WriteError.self) { try w.data() }
    }

    @Test func identifiersAreStableUniqueAndNonZero() {
        let names = (0..<3000).map { "asset\($0)" }
        let a = CARWriter.identifiers(for: names), b = CARWriter.identifiers(for: names.reversed())
        #expect(a == b)
        #expect(Set(a.values).count == 3000 && !a.values.contains(0))
    }

    @Test func icnsEntries() throws {
        let d = ICNS.write(ICNS.defaultSet) { Bitmap(width: $0, height: $0, fill: (0, 0.5, 1, 1)) }
        let b = [UInt8](d)
        #expect(Array(b[0..<4]) == Array("icns".utf8) && Int(b.u32be(at: 4)) == b.count)
        let e = ICNS.entries(d)
        #expect(e.map(\.type) == ["ic13", "ic11", "ic04", "ic07"])
        #expect(try PNG.decode(Data(e[0].data)).width == 256)
        #expect(try PNG.decode(Data(e[1].data)).width == 32)
        #expect(try PNG.decode(Data(e[3].data)).width == 128)
        // ARGB: four run-length planes of 256 bytes each (A = 255, R = 0, G = 128, B = 255).
        #expect(Array(e[2].data.prefix(4)) == Array("ARGB".utf8))
        // Runs are at most 130 bytes: 130 (code 255) then 126 (code 251).
        #expect(Array(e[2].data.dropFirst(4)) == [255, 255, 251, 255] + [255, 0, 251, 0] + [255, 128, 251, 128] + [255, 255, 251, 255])
    }
}

/// The compiler: inputs → car, loose files, partial Info.plist (icon-compile.md §3).
struct AssetCompilerTests {
    @Test func iOSCatalogCompiles() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = try Fixture.catalog(in: dir)
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([cat], platform: "iphonesimulator", out: out, devices: ["iphone", "ipad"])
        #expect(r.succeeded, "\(r.diagnostics)")
        #expect(r.outputs.map(\.lastPathComponent) == ["Assets.car", "AppIcon60x60@2x.png", "AppIcon76x76@2x~ipad.png"])
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        #expect(car.structureIssues.isEmpty)
        #expect(car.facets.map(\.name) == ["AccentColor", "AppIcon", "Brand", "Logo", "Shapes/Star"])
        #expect(car.facets.first { $0.name == "AppIcon" }?.part == CARPart.iconImage)
        let icons = car.renditions.filter { $0.part == CARPart.iconImage }
        #expect(icons.count == 2)
        #expect(Set(icons.compactMap { $0.key[.idiom] }) == [1, 2] && icons.allSatisfy { $0.key[.dimension2] == 1 && $0.key[.scale] == 1 })
        #expect(car.renditions.filter { $0.part == CARPart.multisizeImage }.map(\.payload) == [
            .multisize([CARMultisizeEntry(width: 1024, height: 1024, index: 1)]), .multisize([CARMultisizeEntry(width: 1024, height: 1024, index: 1)]),
        ])
        let logos = car.renditions.filter { car.facetName(for: $0) == "Logo" }
        #expect(logos.map { [$0.key[.scale] ?? 0, $0.key[.appearance] ?? 0] }.sorted { $0.lexicographicallyPrecedes($1) } == [[1, 0], [2, 0], [2, 1]])
        #expect(logos.allSatisfy { $0.flags == 16 && $0.layout == 12 })
        guard case .color(let accent) = car.renditions.first(where: { car.facetName(for: $0) == "AccentColor" })!.payload else { Issue.record("no colour"); return }
        #expect(accent.colorSpace == 3 && abs(accent.components[0] - 0.2) < 1e-9)
        for (name, px) in [("AppIcon60x60@2x.png", 120), ("AppIcon76x76@2x~ipad.png", 152)] {
            let b = try PNG.decode(try Data(contentsOf: out.appendingPathComponent(name)))
            #expect(b.width == px && b.height == px && b.isOpaque)
        }
        let plist = try #require(NSDictionary(contentsOf: out.appendingPathComponent("partial.plist")))
        let expected: NSDictionary = [
            "CFBundleIcons": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60"], "CFBundleIconName": "AppIcon"]],
            "CFBundleIcons~ipad": ["CFBundlePrimaryIcon": ["CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"], "CFBundleIconName": "AppIcon"]],
            "NSAccentColorName": "AccentColor",
        ]
        #expect(plist == expected)
        let deps = [UInt8](try Data(contentsOf: out.appendingPathComponent("deps")))
        #expect(deps.first == 0 && deps.contains(0x10) && deps.contains(0x40))
    }

    @Test func onlyTheTargetedFamilyGetsTheIconName() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = try Fixture.catalog(in: dir)
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([cat], platform: "iphoneos", out: out, devices: ["iphone"])
        #expect(r.succeeded)
        let p = try #require(NSDictionary(contentsOf: out.appendingPathComponent("partial.plist")))
        #expect((p["CFBundleIcons~ipad"] as? NSDictionary)?["CFBundlePrimaryIcon"] as? NSDictionary == ["CFBundleIconFiles": ["AppIcon60x60", "AppIcon76x76"]])
        // Both loose PNGs anyway.
        #expect(r.outputs.count == 3)
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        #expect(Set(car.renditions.filter { $0.part == CARPart.iconImage }.compactMap { $0.key[.idiom] }) == [1])
    }

    @Test func macOSCatalogCompiles() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = try Fixture.catalog(in: dir)
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([cat], platform: "macosx", out: out)
        #expect(r.succeeded, "\(r.diagnostics)")
        #expect(r.outputs.map(\.lastPathComponent) == ["Assets.car", "AppIcon.icns"])
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        #expect(car.header.keySemantics == 1 && car.metadata?.platform == "macosx")
        #expect(car.appearances.map(\.name).sorted() == ["NSAppearanceNameDarkAqua", "NSAppearanceNameSystem"])
        let ms = car.renditions.first { $0.part == CARPart.multisizeImage }
        let sizes: [UInt32] = [16, 32, 128, 256, 512]
        var entries: [CARMultisizeEntry] = []
        for (k, v) in sizes.enumerated() { entries.append(CARMultisizeEntry(width: v, height: v, index: UInt16(k + 1))) }
        #expect(ms?.payload == .multisize(entries))
        #expect(car.renditions.filter { $0.part == CARPart.iconImage }.count == 10)
        #expect(ICNS.entries(try Data(contentsOf: out.appendingPathComponent("AppIcon.icns"))).map(\.type) == ["ic13", "ic11", "ic04", "ic07"])
        let p = try #require(NSDictionary(contentsOf: out.appendingPathComponent("partial.plist")))
        #expect(p == ["CFBundleIconFile": "AppIcon", "CFBundleIconName": "AppIcon", "NSAccentColorName": "AccentColor"] as NSDictionary)
    }

    @Test func watchOSCatalogCompiles() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([try Fixture.catalog(in: dir)], platform: "watchsimulator", out: out)
        #expect(r.succeeded, "\(r.diagnostics)")
        #expect(r.outputs.map(\.lastPathComponent) == ["Assets.car"])
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        #expect(car.metadata?.platform == "watch")
        #expect(car.renditions.filter { $0.part == CARPart.iconImage }.map { $0.key[.idiom] } == [5])
        let p = try #require(NSDictionary(contentsOf: out.appendingPathComponent("partial.plist")))
        #expect(p["CFBundleIcons"] as? NSDictionary == ["CFBundlePrimaryIcon": ["CFBundleIconName": "AppIcon"]])
    }

    @Test func dotIconWinsOverAnIconSetOfTheSameName() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = try Fixture.catalog(in: dir)
        let icon = try Fixture.icon(in: dir)
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([cat, icon], platform: "iphonesimulator", out: out)
        #expect(r.succeeded, "\(r.diagnostics)")
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        let icons = car.renditions.filter { $0.part == CARPart.iconImage }
        // phone and pad × any, dark, tinted.
        #expect(icons.count == 6)
        #expect(Set(icons.compactMap { $0.key[.appearance] }) == [0, 1, 10])
        #expect(car.appearances.map(\.name).sorted() == ["ISAppearanceTintable", "UIAppearanceAny", "UIAppearanceDark"])
        // The placeholder render: the fill colour in the corner, the white layer in the middle, dark fill in dark.
        func pixel(_ appearance: UInt16, _ x: Int, _ y: Int) -> [UInt8] {
            guard case .bitmap(let b, _, _, _) = icons.first(where: { $0.key[.appearance] == appearance })!.payload else { return [] }
            return Array(b.rgba[((y * b.width + x) * 4)..<((y * b.width + x) * 4 + 4)])
        }
        #expect(pixel(0, 5, 5) == [230, 51, 26, 255])
        #expect(pixel(0, 512, 512) == [255, 255, 255, 255])
        #expect(pixel(1, 5, 5) == [26, 26, 102, 255])
        let t = pixel(10, 5, 5)
        #expect(t[0] == t[1] && t[1] == t[2])
        let loose = try PNG.decode(try Data(contentsOf: out.appendingPathComponent("AppIcon60x60@2x.png")))
        #expect(loose.width == 120 && Array(loose.rgba[0..<4]) == [230, 51, 26, 255])
    }

    @Test func dotIconOnMacOSHasSevenSizesAndTheShape() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([try Fixture.icon(in: dir)], platform: "macosx", out: out) { $0.accentColor = nil }
        #expect(r.succeeded, "\(r.diagnostics)")
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        let icons = car.renditions.filter { $0.part == CARPart.iconImage }
        #expect(icons.map { [$0.key[.dimension2] ?? 0, $0.key[.scale] ?? 0] }.sorted { $0.lexicographicallyPrecedes($1) }
                == [[1, 2], [2, 2], [3, 2], [4, 2], [5, 2], [6, 2], [7, 1]])
        guard case .bitmap(let big, _, let v, _) = icons.first(where: { $0.key[.dimension2] == 7 })!.payload else { Issue.record("no bitmap"); return }
        #expect(v == 1 && big.width == 1024)
        #expect(big.rgba[3] == 0)                                   // transparent corner
        #expect(Array(big.rgba[((512 * 1024 + 120) * 4)..<((512 * 1024 + 120) * 4 + 4)]) == [230, 51, 26, 255])
        #expect(ICNS.entries(try Data(contentsOf: out.appendingPathComponent("AppIcon.icns"))).count == 4)
    }

    @Test func flattenedImagesFromAFolder() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = dir.appendingPathComponent("flat")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try Fixture.writePNG(images.appendingPathComponent("default.png"), 64, 64, (0, 1, 0, 1))
        try Fixture.writePNG(images.appendingPathComponent("dark-ios.png"), 64, 64, (0, 0, 1, 1))
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([try Fixture.icon(in: dir)], platform: "iphoneos", out: out, devices: ["iphone"]) { $0.iconImages = images }
        #expect(r.succeeded, "\(r.diagnostics)")
        let car = try CARFile(contentsOf: out.appendingPathComponent("Assets.car"))
        var seen: [UInt16: [UInt8]] = [:]
        for rr in car.renditions where rr.part == CARPart.iconImage {
            if case .bitmap(let b, _, _, _) = rr.payload { seen[rr.key[.appearance] ?? 0] = Array(b.rgba[0..<4]); #expect(b.width == 1024) }
        }
        #expect(seen[0] == [0, 255, 0, 255] && seen[1] == [0, 0, 255, 255])
        #expect(seen[10].map { $0[0] == $0[1] && $0[1] == $0[2] } == true)
    }

    @Test func alternateIconsAndErrors() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try Fixture.icon(in: dir, name: "AppIcon"), b = try Fixture.icon(in: dir, name: "Night")
        let out = dir.appendingPathComponent("out")
        let r = Fixture.compile([a, b], platform: "iphoneos", out: out) {
            $0.alternateAppIcons = ["Night"]
            $0.accentColor = nil
        }
        #expect(r.succeeded)
        let p = try #require(NSDictionary(contentsOf: out.appendingPathComponent("partial.plist")))
        let icons = try #require(p["CFBundleIcons"] as? NSDictionary)
        #expect(icons["CFBundleAlternateIcons"] as? NSDictionary == ["Night": ["CFBundleIconName": "Night"]])
        // Only the primary icon writes loose PNGs.
        #expect(r.outputs.filter { $0.pathExtension == "png" }.count == 2)
        let missing = Fixture.compile([a], platform: "iphoneos", out: out, appIcon: "Other")
        #expect(missing.errors.map(\.message) == ["None of the input catalogs contained a matching stickers icon set, app icon set, or icon stack named \"Other\""])
        // visionOS ignores an .icon without a word.
        let vision = Fixture.compile([a], platform: "xrsimulator", out: dir.appendingPathComponent("v"))
        #expect(vision.succeeded && vision.diagnostics.isEmpty && vision.outputs.isEmpty)
    }

    @Test func dotIconInsideACatalogIsIgnored() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = try Fixture.catalog(in: dir)
        let inner = try Fixture.icon(in: cat, name: "Inner")
        _ = inner
        let r = Fixture.compile([cat], platform: "iphoneos", out: dir.appendingPathComponent("out"), appIcon: "Inner")
        #expect(r.diagnostics.contains { $0.kind == .warning && $0.message.contains("inside an asset catalog is ignored") })
        #expect(r.errors.count == 1)
    }

    @Test func commandLineCompileAndInfo() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let cat = try Fixture.catalog(in: dir)
        let out = dir.appendingPathComponent("out")
        // actool's spelling, as swift-build passes it.
        let status = AssetsCLI.run(["compile", cat.path, "--compile", out.path, "--output-format", "human-readable-text", "--notices", "--warnings",
                                    "--export-dependency-info", dir.appendingPathComponent("deps").path,
                                    "--output-partial-info-plist", dir.appendingPathComponent("p.plist").path, "--app-icon", "AppIcon",
                                    "--accent-color", "AccentColor", "--compress-pngs", "--enable-on-demand-resources", "YES",
                                    "--development-region", "en", "--target-device", "iphone", "--target-device", "ipad",
                                    "--minimum-deployment-target", "27.0", "--platform", "iphonesimulator", "--bundle-identifier", "x.y"])
        #expect(status == 0)
        #expect(FileManager.default.fileExists(atPath: out.appendingPathComponent("Assets.car").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("deps").path))
        let text = AssetsCLI.describe(try CARFile(contentsOf: out.appendingPathComponent("Assets.car")))
        #expect(text.lines.contains { $0.contains("facet AppIcon: Icon Image") })
        #expect(AssetsCLI.run(["compile", cat.path, "--compile", out.path, "--bogus"]) == 2)
        // The symbol step writes its three files and no car.
        let sym = dir.appendingPathComponent("sym")
        #expect(AssetsCLI.run(["compile", cat.path, "--compile", sym.path, "--generate-swift-asset-symbols", sym.appendingPathComponent("S.swift").path,
                               "--generate-objc-asset-symbols", sym.appendingPathComponent("S.h").path,
                               "--generate-asset-symbol-index", sym.appendingPathComponent("I.plist").path]) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sym.path).sorted() == ["I.plist", "S.h", "S.swift"])
    }

    @Test func iconCommands() throws {
        let dir = try Fixture.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let icon = try Fixture.icon(in: dir)
        let json = dir.appendingPathComponent("doc.json")
        #expect(AssetsCLI.run(["icon", "to-json", icon.path, "-o", json.path]) == 0)
        let copy = dir.appendingPathComponent("Copy.icon")
        #expect(AssetsCLI.run(["icon", "from-json", json.path, "-o", copy.path, "--assets", icon.appendingPathComponent("Assets").path]) == 0)
        #expect(try IconPackage(contentsOf: copy).document == (try IconPackage(contentsOf: icon)).document)
        #expect(try Data(contentsOf: copy.appendingPathComponent("icon.json")) == (try Data(contentsOf: icon.appendingPathComponent("icon.json"))))
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("Assets/dot.png").path))
        let png = dir.appendingPathComponent("r.png")
        #expect(AssetsCLI.run(["icon", "render", icon.path, "-o", png.path, "--size", "64", "--appearance", "dark"]) == 0)
        #expect(try PNG.decode(try Data(contentsOf: png)).rgba[0..<4] == [26, 26, 102, 255])
        #expect(AssetsCLI.run(["icon", "validate", icon.path]) == 0)
        #expect(AssetsCLI.run(["icon", "info", icon.path, "--platform", "watchOS"]) == 0)
    }
}
