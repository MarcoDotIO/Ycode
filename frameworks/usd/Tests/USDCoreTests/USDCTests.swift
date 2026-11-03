import Testing
@testable import USDCore

@Suite struct USDCTests {
    /// `scene.usdc` was written by OpenUSD (usd-core) from `scene.usda`.
    @Test func readsOpenUSDCrateFiles() throws {
        let text = try Fixture.layer("scene.usda")
        let crate = try Fixture.layer("scene.usdc")
        #expect(differences(text, crate).isEmpty, "\(differences(text, crate).prefix(5))")
    }

    @Test func writesWhatItReads() throws {
        let layer = try Fixture.layer("scene.usda")
        let bytes = try USDCWriter.write(layer)
        #expect(Array(bytes.prefix(8)) == Array("PXR-USDC".utf8))
        #expect(Array(bytes[8..<11]) == [0, 9, 0]) // timecode values need 0.9.0
        let back = try USDCReader.read(bytes)
        #expect(differences(layer, back).isEmpty, "\(differences(layer, back).prefix(5))")
        // Text written from the crate data equals text written from the source.
        #expect(USDAWriter.write(back) == USDAWriter.write(layer))
    }

    @Test func versionWithoutTimecodes() throws {
        var layer = Layer()
        try layer.createPrim(at: "/A", typeName: "Xform")
        try layer.createAttribute(at: "/A.x", typeName: TypeName("float")!, value: .float(1))
        let bytes = try USDCWriter.write(layer)
        #expect(Array(bytes[8..<11]) == [0, 8, 0])
    }

    @Test func compressedAndInlinedValues() throws {
        var layer = Layer()
        try layer.createPrim(at: "/P")
        let ints = (0..<1000).map { $0 * 3 - 500 }
        let floats = (0..<300).map { Float($0) * 0.5 }
        let integral = (0..<300).map { Float($0) }
        let values: [(String, String, Value)] = [
            ("ints", "int[]", .ints(ints)),
            ("int64s", "int64[]", .array(.int64, .integers((0..<100).map { Int64($0) * 10_000_000_000 }))),
            ("floats", "float[]", .floats(floats)),
            ("integral", "float[]", .floats(integral)),
            ("halfs", "half[]", .array(.half, .floats((0..<40).map { Half.round(Float($0) / 7) }))),
            ("smallVec", "float3", .float3(1, -2, 3)),
            ("bigVec", "float3", .float3(1.5, 2, 3)),
            ("identity", "matrix4d", .matrix4d([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])),
            ("scaled", "matrix4d", .matrix4d([2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0, 0, 0, 0, 1])),
            ("general", "matrix4d", .matrix4d([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])),
            ("exactDouble", "double", .double(0.5)),
            ("inexactDouble", "double", .double(0.1)),
            ("quat", "quatf", .quatf(real: 0.5, 0.1, 0.2, 0.3)),
            ("big", "int64", .int64(Int64.max)),
            ("empty", "int[]", .ints([])),
        ]
        for (name, type, value) in values {
            try layer.createAttribute(at: Path.root.appendingChild("P").appendingProperty(name), typeName: TypeName(type)!, value: value)
        }
        try layer.createAttribute(at: "/P.dict", typeName: TypeName("token")!)
        layer.setField(FieldKey.customData, .dictionary([
            "a": .int(1), "b": .dictionary(["c": .string("deep"), "d": .float3s([1, 2, 3])]), "e": .tokens(["x", "y"]),
        ]), at: "/P.dict")
        let bytes = try USDCWriter.write(layer)
        let back = try USDCReader.read(bytes)
        #expect(differences(layer, back).isEmpty, "\(differences(layer, back).prefix(5))")
    }

    @Test func lz4RoundTrips() throws {
        var generator = SystemRandomNumberGenerator()
        let samples: [[UInt8]] = [
            [], [1], Array("hello hello hello hello hello hello".utf8),
            [UInt8](repeating: 7, count: 100_000),
            (0..<50_000).map { _ in UInt8.random(in: 0...3, using: &generator) },
            (0..<20_000).map { _ in UInt8.random(in: 0...255, using: &generator) },
        ]
        for s in samples {
            let c = LZ4.compress(s)
            #expect(try LZ4.decompress(c[...], expectedSize: s.count) == s)
        }
        #expect(LZ4.compress([UInt8](repeating: 7, count: 100_000)).count < 1000)
    }

    @Test func integerCodingRoundTrips() throws {
        let values: [Int64] = [123, 124, 125, 100_125, 100_125, 100_126, 100_126, -5, Int64(Int32.max), Int64(Int32.min), 0]
        #expect(try IntegerCoding.decode32(IntegerCoding.encode32(values)[...], count: values.count) == values)
        let wide: [Int64] = [0, 1, -1, 40_000, -40_000, 5_000_000_000, Int64.max, Int64.min]
        #expect(try IntegerCoding.decode64(IntegerCoding.encode64(wide)[...], count: wide.count) == wide)
    }

    @Test func rejectsDamagedFiles() throws {
        let bytes = try USDCWriter.write(try Fixture.layer("scene.usda"))
        #expect(throws: USDError.self) { try USDCReader.read(Array(bytes.prefix(200))) }
        var damaged = bytes
        damaged[16] = 0xFF // table of contents offset
        #expect(throws: USDError.self) { try USDCReader.read(damaged) }
        #expect(throws: USDError.self) { try USDCReader.read(Array("#usda 1.0".utf8)) }
    }
}
