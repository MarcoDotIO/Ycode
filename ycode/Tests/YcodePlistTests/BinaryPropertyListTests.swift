import Foundation
import Testing
@testable import YcodePlist

/// Binary property lists keep the file's key order and write back byte for
/// byte (reference-ui-5.md §11.2, P8; specs/ide/plist-editor.md).
@Suite struct BinaryPropertyListTests {
    static func bytes(_ hex: String) -> Data { Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! }) }
    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined(separator: " ") }

    /// Lists written by Foundation's binary writer (captured on macOS), so
    /// the check runs on every platform: a dictionary in hash order with a
    /// shared string and two `true` values, an array of integers of every
    /// width with repeated values, and long, non-ASCII, data and date items.
    static let goldens = [
        "62 70 6c 69 73 74 30 30 d6 01 02 03 04 05 06 07 08 09 07 0b 0b 51 62 51 63 51 64 51 61 51 65 51 66 09 10 01 23 3f f0 00 00 00 00 00 00 09 51 78 08 15 17 19 1b 1d 1f 21 22 24 2d 2e 00 00 00 00 00 00 01 01 00 00 00 00 00 00 00 0c 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 30",
        "62 70 6c 69 73 74 30 30 a9 01 01 03 04 04 05 06 07 08 09 09 08 10 01 13 ff ff ff ff ff ff ff ff 11 01 2c 12 00 01 11 70 13 00 00 00 01 2a 05 f2 00 08 12 13 14 15 17 20 23 28 00 00 00 00 00 00 01 01 00 00 00 00 00 00 00 09 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 31",
        "62 70 6c 69 73 74 30 30 a4 01 02 03 04 61 00 e9 5f 10 11 61 62 63 64 65 66 67 68 69 6a 6b 6c 6d 6e 6f 70 71 42 01 02 33 00 00 00 00 00 00 00 00 08 0d 10 24 27 00 00 00 00 00 00 01 01 00 00 00 00 00 00 00 05 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 30",
    ]

    @Test func foundationGoldensRoundTripByteForByte() throws {
        for g in Self.goldens {
            let doc = try PropertyListDocument(data: Self.bytes(g))
            #expect(doc.format == .binary)
            #expect(Self.hex(try doc.data()) == g)
        }
        // The file's key order, not sorted.
        guard case .dictionary(let d) = try PropertyListDocument(data: Self.bytes(Self.goldens[0])).root else { Issue.record("not a dict"); return }
        #expect(d.map(\.key) == ["b", "c", "d", "a", "e", "f"])
        #expect(d.map(\.value) == [.bool(true), .integer(1), .real(1), .bool(true), .string("x"), .string("x")])
        guard case .array(let a) = try PropertyListDocument(data: Self.bytes(Self.goldens[1])).root else { Issue.record("not an array"); return }
        #expect(a == [.bool(true), .bool(true), .bool(false), .integer(1), .integer(1), .integer(-1), .integer(300), .integer(70000), .integer(5_000_000_000)])
        guard case .array(let c) = try PropertyListDocument(data: Self.bytes(Self.goldens[2])).root else { Issue.record("not an array"); return }
        #expect(c == [.string("é"), .string("abcdefghijklmnopq"), .data(Data([1, 2])), .date(Date(timeIntervalSinceReferenceDate: 0))])
    }

    @Test func editsKeepKeyOrder() throws {
        var doc = PropertyListDocument(root: .dictionary([
            .init(key: "Zebra", value: .string("z")), .init(key: "Apple", value: .integer(-4)),
            .init(key: "Mid", value: .dictionary([.init(key: "y", value: .bool(false)), .init(key: "x", value: .array([]))])),
        ]), format: .binary)
        let first = try doc.data()
        #expect(first.starts(with: Array("bplist00".utf8)))
        var back = try PropertyListDocument(data: first)
        #expect(back == doc)
        guard case .dictionary(var d) = back.root else { Issue.record("not a dict"); return }
        d[0].value = .string("zz")
        back.root = .dictionary(d)
        let again = try PropertyListDocument(data: try back.data())
        guard case .dictionary(let e) = again.root else { Issue.record("not a dict"); return }
        #expect(e.map(\.key) == ["Zebra", "Apple", "Mid"] && e[0].value == .string("zz"))
        // Foundation reads what Ycode writes.
        let ns = try PropertyListSerialization.propertyList(from: try again.data(), options: [], format: nil) as? NSDictionary
        #expect(ns?["Apple"] as? Int == -4 && ns?["Zebra"] as? String == "zz")
        doc.format = .xml
        #expect(String(decoding: try doc.data(), as: UTF8.self).contains("<key>Zebra</key>"))
    }

    @Test func largeListsUseWiderReferencesAndOffsets() throws {
        // 300 distinct strings: 2-byte object references and offsets.
        let items = (0..<300).map { PropertyListItem.string("item \($0) " + String(repeating: "x", count: 20)) }
        let doc = PropertyListDocument(root: .array(items), format: .binary)
        let data = try doc.data()
        #expect(data[data.count - 25] == 2 && data[data.count - 26] == 2)
        #expect(try PropertyListDocument(data: data) == doc)
        let ns = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String]
        #expect(ns?.count == 300 && ns?.last == "item 299 " + String(repeating: "x", count: 20))
    }

    @Test func malformedListsThrow() {
        #expect(throws: PropertyListDocument.ParseError.self) { try PropertyListDocument(data: Data("bplist00".utf8)) }
        var bad = [UInt8](Self.bytes(Self.goldens[1]))
        bad[bad.count - 1] = 0xFF // offset table beyond the trailer
        #expect(throws: PropertyListDocument.ParseError.self) { try PropertyListDocument(data: Data(bad)) }
    }

    #if canImport(Darwin)
    /// On macOS, lists Foundation writes now round-trip byte for byte.
    @Test func foundationWrittenListsRoundTrip() throws {
        let samples: [Any] = [
            ["CFBundleName": "Demo & <Co>", "Count": 3, "Ratio": 1.5, "Enabled": true, "Off": false,
             "List": ["a", 2, ["k": "v"]] as [Any], "Empty": [String: Any](), "None": [Any](),
             "Blob": Data((0..<40).map { UInt8($0) }), "When": Date(timeIntervalSince1970: 1_700_000_000),
             "Unicode": "naïve – ✓", "Neg": -123456, "Big": 1 << 40] as [String: Any],
            (0..<400).map { ["id": $0, "name": "row \($0)", "flag": $0 % 2 == 0] as [String: Any] },
        ]
        for s in samples {
            let data = try PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0)
            let doc = try PropertyListDocument(data: data)
            #expect(try doc.data() == data)
        }
    }
    #endif
}
