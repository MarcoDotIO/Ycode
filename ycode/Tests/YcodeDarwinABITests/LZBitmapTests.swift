import Testing
@testable import YcodeDarwinABI

/// LZBITMAP streams and decmpfs payloads (`specs/simulator/lzbitmap.md`).
@Suite struct LZBitmapTests {
    /// §2.10's worked example (our own input, encoded by the reference's
    /// encoder): 222 bytes in a 134-byte stream.
    static let example: [UInt8] = hexBytes("""
    5a 42 4d 09 7c 00 00 de 00 00 5e 00 00 5f 00 00
    5f 00 00 59 63 6f 64 65 20 4c 5a 42 49 54 4d 41
    50 21 20 59 63 6f 64 65 20 4c 5a 6c 7a 62 69 74
    6d 61 70 3f 00 00 00 00 00 00 00 00 00 00 00 00
    00 00 00 00 30 31 32 33 34 35 36 37 38 39 30 31
    32 33 34 35 36 37 38 39 30 31 32 33 34 35 36 37
    38 39 10 77 87 f3 60 35 2f 77 f3 72 77 34 0f 00
    fc f0 07 30 ff 00 04 00 00 00 00 00 00 00 00 00
    06 00 00 00 00 00
    """)

    static var exampleText: [UInt8] {
        Array(String(repeating: "Ycode LZBITMAP! ", count: 4).utf8) + Array(String(repeating: "Ycode lzbitmap? ", count: 4).utf8)
            + [UInt8](repeating: 0, count: 64) + Array(String(repeating: "0123456789", count: 3).utf8)
    }

    static func hexBytes(_ s: String) -> [UInt8] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map { UInt8($0, radix: 16)! }
    }

    /// A stored-only stream (§2.9: a valid writer).
    static func stored(_ data: [UInt8], chunk: Int = 32_768) -> [UInt8] {
        var s: [UInt8] = [0x5A, 0x42, 0x4D, 0x09]
        var i = 0
        while i < data.count {
            let n = min(chunk, data.count - i)
            let len = n + 6
            s += [UInt8(len & 0xFF), UInt8(len >> 8 & 0xFF), UInt8(len >> 16), UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16)]
            s += data[i..<(i + n)]
            i += n
        }
        return s + [6, 0, 0, 0, 0, 0]
    }

    @Test func decodesTheWorkedExample() {
        #expect(Self.exampleText.count == 222)
        #expect(LZBitmap.decode(Self.example) == Self.exampleText)
        // A limit below the output rejects it (decmpfs knows the size).
        #expect(LZBitmap.decode(Self.example, limit: 200) == nil)
    }

    @Test func storedChunksAndTheEndChunk() {
        let data = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
        #expect(LZBitmap.decode(Self.stored(data)) == data)
        #expect(LZBitmap.decode(Self.stored(data, chunk: 100)) == data)
        // Magic + end only: empty output.
        #expect(LZBitmap.decode([0x5A, 0x42, 0x4D, 0x09, 6, 0, 0, 0, 0, 0]) == [])
        // No end chunk: rejected; bytes after it: ignored.
        let s = Self.stored([1, 2, 3])
        #expect(LZBitmap.decode(Array(s.dropLast(6))) == nil)
        #expect(LZBitmap.decode(s + [9, 9, 9]) == [1, 2, 3])
        // End chunk of length 7, a stored chunk over 32 768, wrong magic.
        #expect(LZBitmap.decode([0x5A, 0x42, 0x4D, 0x09, 7, 0, 0, 0, 0, 0, 0]) == nil)
        var big = Self.stored([UInt8](repeating: 1, count: 32_769), chunk: 32_769)
        #expect(LZBitmap.decode(big) == nil)
        big = Self.stored([1])
        big[3] = 0x0C
        #expect(LZBitmap.decode(big) == nil)
        big[3] = 0x08
        #expect(LZBitmap.decode(big) == [1])
    }

    @Test func copiesReachIntoEarlierChunks() {
        // A compressed chunk whose copies all read the stored chunk before
        // it: 16 bytes, all copied with the default period 8.
        var chunk: [UInt8] = []
        let outLen = 16
        // header (len patched), offsets: no literals, no periods, no bitmaps.
        chunk += [0, 0, 0, UInt8(outLen), 0, 0]
        chunk += [15, 0, 0, 15, 0, 0, 15, 0, 0]
        // selectors: 3 (table entry 0: bitmap 0x00, no period) twice.
        chunk += [0x33]
        chunk += [UInt8](repeating: 0, count: 17)   // table: entry 0 = 0x00 / 0
        while chunk.count < 32 { chunk.insert(0, at: 16) }   // pad the selector area
        let len = chunk.count
        chunk[0] = UInt8(len)
        var s = Self.stored(Array("abcdefgh".utf8))
        s.removeLast(6)
        s += chunk + [6, 0, 0, 0, 0, 0]
        #expect(LZBitmap.decode(s).map { String(decoding: $0, as: UTF8.self) } == "abcdefghabcdefghabcdefgh")
    }

    @Test func decmpfsInlineAndForkTypes() throws {
        // §3.3: a 1-byte file "A", type 13 stored.
        let a = Self.hexBytes("66 70 6d 63 0d 00 00 00 01 00 00 00 00 00 00 00 ff 41")
        #expect(Decmpfs.header(a)?.type == 13)
        #expect(try Decmpfs.decode(attribute: a, fork: nil).get() == [0x41])
        // Type 13 with an LZBITMAP payload.
        var h13 = Self.hexBytes("66 70 6d 63 0d 00 00 00 de 00 00 00 00 00 00 00")
        #expect(try Decmpfs.decode(attribute: h13 + Self.example, fork: nil).get() == Self.exampleText)
        // An undecodable payload reads as nothing.
        h13[8] = 0xDF
        #expect(try Decmpfs.decode(attribute: h13 + Self.example, fork: nil).get() == [])
        // Type 14: two blocks (65 536 stored bytes and the example).
        let first = (0..<65_536).map { UInt8(truncatingIfNeeded: $0) }
        let size = 65_536 + 222
        let block0 = [UInt8(0xFF)] + first, block1 = Self.example
        var fork: [UInt8] = []
        for off in [12, 12 + block0.count, 12 + block0.count + block1.count] {
            fork += [UInt8(off & 0xFF), UInt8(off >> 8 & 0xFF), UInt8(off >> 16 & 0xFF), UInt8(off >> 24)]
        }
        fork += block0 + block1
        var h14 = Self.hexBytes("66 70 6d 63 0e 00 00 00 00 00 00 00 00 00 00 00")
        h14[8] = UInt8(size & 0xFF); h14[9] = UInt8(size >> 8 & 0xFF); h14[10] = UInt8(size >> 16)
        #expect(try Decmpfs.decode(attribute: h14, fork: fork).get() == first + Self.exampleText)
        #expect(Decmpfs.decode(attribute: h14, fork: nil) == .failure(.missingFork))
        var badTable = fork
        badTable[0] = 16
        #expect(Decmpfs.decode(attribute: h14, fork: badTable) == .failure(.invalid))
        // Unknown type; too short or too long an attribute.
        var h99 = h14
        h99[4] = 99
        #expect(Decmpfs.decode(attribute: h99, fork: fork) == .failure(.unsupportedType))
        #expect(Decmpfs.header(Array(a.prefix(15))) == nil)
        #expect(Decmpfs.header(a + [UInt8](repeating: 0, count: 3_802)) == nil)
    }
}
