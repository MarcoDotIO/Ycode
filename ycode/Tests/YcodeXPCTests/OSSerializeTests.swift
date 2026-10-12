import Testing
@testable import YcodeXPC

/// The OSSerialize binary format (iosurface-remote.md §5.1) and the `!CPX` magic.
@Suite struct OSSerializeTests {
    @Test func roundTrip() throws {
        let v = OSValue.dictionary([
            ("IOSurfaceWidth", .number(1206, bits: 64)), ("IOSurfaceName", .string("QuartzCore")),
            ("IOSurfacePixelSizeCastingAllowed", .bool(false)), ("blob", .data([1, 2, 3])),
            ("IOSurfacePlaneInfo", .array([.dictionary([("IOSurfacePlaneWidth", .number(8, bits: 32))])])),
        ])
        let bytes = OSSerialize.encode(v)
        #expect(Array(bytes[0..<4]) == [0xD3, 0, 0, 0])
        #expect(try OSSerialize.decode(bytes) == v)
        #expect(try OSSerialize.decode(bytes)["IOSurfaceWidth"]?.numberValue == 1206)
    }

    @Test func objectReferences() throws {
        // {Width: 64, Height: <ref to object 2>}: objects 0 dict, 1 key, 2 number, 3 key.
        var b: [UInt8] = []
        func u32(_ v: UInt32) { b += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
        u32(0xD3)
        u32(0x8100_0002)                       // dictionary, 2 pairs, last
        u32(0x0800_0006); b += Array("Width".utf8) + [0, 0, 0]
        u32(0x0400_0040); u32(64); u32(0)      // number 64
        u32(0x0800_0007); b += Array("Height".utf8) + [0, 0]
        u32(0x8C00_0002)                       // reference to object 2
        let v = try OSSerialize.decode(b)
        #expect(v["Width"]?.numberValue == 64 && v["Height"]?.numberValue == 64)
        #expect(throws: OSSerializeError.self) { try OSSerialize.decode([0xD4, 0, 0, 0]) }
    }

    @Test func sim2hostMagic() throws {
        let d: XPCObject = ["ErrorCode": .uint64(0)]
        let e = try XPCWire.encode(d, magic: XPCWire.sim2hostMagic)
        #expect(Array(e.body[0..<4]) == Array("!CPX".utf8))
        #expect(try XPCWire.decode(body: e.body, descriptors: []) == d)
    }
}
