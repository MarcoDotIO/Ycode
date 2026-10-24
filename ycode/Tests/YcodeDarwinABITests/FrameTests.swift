import Testing
@testable import YcodeDarwinABI

private func u64(_ b: [UInt8], _ o: Int) -> UInt64 {
    (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[o + $1]) << (8 * UInt64($1)) }
}

@Suite struct BootInfoTests {
    private func sample() -> BootInfo {
        BootInfo(ttbr0EL1: 0x4020_0000, tcrEL1: 0x11, mairEL1: 0x22, sctlrEL1: 0x33,
                 el0EntryPC: 0x1_0000_0000, el0InitialSP: 0x1_7000_0000,
                 trapFrameAddress: 0x4010_4000, doorbellAddress: 0x0900_0000,
                 tpidrroEL0: 0xAAAA, tpidrEL0: 0xBBBB,
                 el0Registers: [10, 11, 12, 13, 14, 15, 16, 17], el1StackTop: 0x4012_0000)
    }

    @Test func magicIsASCII() {
        #expect(BootInfo.magic == 0x3154_4F4F_4244_4359)
        let bytes = sample().encoded()
        #expect(Array(bytes[0..<8]) == Array("YCDBOOT1".utf8))
    }

    @Test func offsets() {
        let b = sample().encoded()
        #expect(b.count == 160)
        #expect(u64(b, 0) == BootInfo.magic)
        #expect(u64(b, 8) == 0x4020_0000)
        #expect(u64(b, 16) == 0x11)
        #expect(u64(b, 24) == 0x22)
        #expect(u64(b, 32) == 0x33)
        #expect(u64(b, 40) == 0x1_0000_0000)
        #expect(u64(b, 48) == 0x1_7000_0000)
        #expect(u64(b, 56) == 0x4010_4000)
        #expect(u64(b, 64) == 0x0900_0000)
        #expect(u64(b, 72) == 0xAAAA)
        #expect(u64(b, 80) == 0xBBBB)
        for i in 0..<8 { #expect(u64(b, 88 + 8 * i) == UInt64(10 + i)) }
        #expect(u64(b, 152) == 0x4012_0000)
        #expect(BootInfo.Offset.el1StackTop == 152)
        #expect(BootInfo.Offset.el0Registers == 88)
    }

    @Test func defaultsAndPadding() {
        let info = BootInfo(ttbr0EL1: VMLayout.pageTableArenaGPA, el0EntryPC: VMLayout.selfTestImageVA,
                            tpidrroEL0: 0x1234, el0Registers: [0x1234, 100])
        let b = info.encoded()
        #expect(b.count == 160)
        #expect(u64(b, 16) == VMLayout.tcrEL1)
        #expect(u64(b, 24) == VMLayout.mairEL1)
        #expect(u64(b, 32) == VMLayout.sctlrEL1)
        #expect(u64(b, 48) == 0x1_7000_0000)
        #expect(u64(b, 56) == 0x4010_4000)
        #expect(u64(b, 64) == 0x0900_0000)
        #expect(u64(b, 88) == 0x1234)
        #expect(u64(b, 96) == 100)
        for i in 2..<8 { #expect(u64(b, 88 + 8 * i) == 0) }
        #expect(u64(b, 152) == 0x4012_0000)
    }

    @Test func roundTripAndErrors() throws {
        let info = sample()
        #expect(try BootInfo(decoding: info.encoded()) == info)
        #expect(try BootInfo(decoding: info.encoded() + [1, 2, 3]) == info)
        #expect(throws: DarwinABIError.truncated(what: "boot info", expected: 160, actual: 159)) {
            _ = try BootInfo(decoding: Array(info.encoded().prefix(159)))
        }
        var bad = info.encoded()
        bad[0] = 0
        #expect(throws: DarwinABIError.badMagic(0x3154_4F4F_4244_4300)) { _ = try BootInfo(decoding: bad) }
    }
}

@Suite struct TrapFrameTests {
    private func sample() -> TrapFrame {
        TrapFrame(x: (0..<31).map { 0x1000 + UInt64($0) }, spEL0: 0x1_6FFF_FF00, elr: 0x1_0000_0024,
                  spsr: 0x2000_0000, esr: 0x5600_0080, far: 0xDEAD, tpidrro: 0x77, tpidr: 0x88, kind: 1)
    }

    @Test func offsets() {
        let b = sample().encoded()
        #expect(b.count == 320)
        for i in 0..<31 { #expect(u64(b, 8 * i) == 0x1000 + UInt64(i)) }
        #expect(u64(b, 128) == 0x1010)  // x16
        #expect(u64(b, 240) == 0x101E)  // x30
        #expect(u64(b, 248) == 0x1_6FFF_FF00)
        #expect(u64(b, 256) == 0x1_0000_0024)
        #expect(u64(b, 264) == 0x2000_0000)
        #expect(u64(b, 272) == 0x5600_0080)
        #expect(u64(b, 280) == 0xDEAD)
        #expect(u64(b, 288) == 0x77)
        #expect(u64(b, 296) == 0x88)
        #expect(u64(b, 304) == 1)
        #expect(u64(b, 312) == 0)
        #expect(TrapFrame.Offset.spEL0 == 248 && TrapFrame.Offset.elr == 256 && TrapFrame.Offset.spsr == 264)
        #expect(TrapFrame.Offset.kind == 304)
    }

    @Test func roundTrip() throws {
        let f = sample()
        #expect(try TrapFrame(decoding: f.encoded()) == f)
        // A whole 16 KiB frame page decodes too; the reserved word is ignored.
        var page = f.encoded() + [UInt8](repeating: 0xEE, count: 16384 - 320)
        page[312] = 0x5A
        #expect(try TrapFrame(decoding: page) == f)
        #expect(throws: DarwinABIError.truncated(what: "trap frame", expected: 320, actual: 319)) {
            _ = try TrapFrame(decoding: Array(f.encoded().prefix(319)))
        }
        let empty = TrapFrame()
        #expect(empty.x.count == 31)
        #expect(empty.encoded() == [UInt8](repeating: 0, count: 320))
    }

    @Test func carryIsBit29() {
        var f = TrapFrame(spsr: 0xF000_03C0)
        #expect(f.carry)
        f.carry = false
        #expect(f.spsr == 0xD000_03C0)
        f.carry = false
        #expect(f.spsr == 0xD000_03C0)
        f.carry = true
        #expect(f.spsr == 0xF000_03C0)
        var g = TrapFrame(spsr: 0)
        g.carry = true
        #expect(g.spsr == 1 << 29)
    }

    @Test func kinds() {
        #expect(TrapFrame(kind: 1).trapKind == .svc)
        #expect(TrapFrame(kind: 2).trapKind == .el0Synchronous)
        #expect(TrapFrame(kind: 3).trapKind == .asynchronous)
        #expect(TrapFrame(kind: 4).trapKind == .el1Synchronous)
        #expect(TrapFrame(kind: 0).trapKind == nil)
        #expect(TrapFrame(kind: 5).trapKind == nil)
    }
}

@Suite struct SyndromeTests {
    @Test func svc() {
        // EC 0x15 << 26 = 0x5400_0000, IL = bit 25, imm16 = 0x80.
        let s = ExceptionSyndrome(0x5600_0080)
        #expect(s.ec == 0x15)
        #expect(s.il)
        #expect(s.iss == 0x80)
        #expect(s.exceptionClass == .svc)
        #expect(s.svcImmediate == 0x80)
        #expect(s.faultStatusCode == nil)
        #expect(ExceptionSyndrome(ec: 0x15, il: true, iss: 0x80) == s)
        #expect(s.description.contains("EC=0x15"))
        #expect(s.description.contains("svc #0x80"))
    }

    @Test func dataAbort() {
        // EC 0x24, IL, WnR (ISS bit 6), DFSC 0b000111 (translation fault, level 3).
        let s = ExceptionSyndrome(0x9200_0047)
        #expect(s.ec == 0x24)
        #expect(s.exceptionClass == .dataAbortLowerEL)
        #expect(s.iss == 0x47)
        #expect(s.faultStatusCode == 0x07)
        #expect(s.isWrite == true)
        #expect(s.description.contains("translation fault, level 3"))
        #expect(s.description.contains("write"))
        let read = ExceptionSyndrome(ec: 0x24, iss: 0x0F)
        #expect(read.isWrite == false)
        #expect(read.description.contains("permission fault, level 3"))
    }

    @Test func instructionAbortAndOthers() {
        let ia = ExceptionSyndrome(ec: 0x20, iss: 0x0B)
        #expect(ia.exceptionClass == .instructionAbortLowerEL)
        #expect(ia.faultStatusCode == 0x0B)
        #expect(ia.isWrite == nil)
        #expect(ia.description.contains("access flag fault, level 3"))
        let brk = ExceptionSyndrome(ec: 0x3C, iss: 0xF000)
        #expect(brk.exceptionClass == .brk)
        #expect(brk.iss == 0xF000)
        #expect(ExceptionSyndrome(ec: 0x00, il: false).il == false)
        #expect(ExceptionSyndrome(ec: 0x3F).exceptionClass == nil)
        #expect(ExceptionSyndrome(ec: 0x3F).description.contains("unrecognized"))
        // ISS2 is bits [55:32].
        #expect(ExceptionSyndrome(0x00AB_CDEF_0000_0000).iss2 == 0xABCDEF)
        for c in ExceptionClass.allCases { #expect(ExceptionSyndrome(ec: c.rawValue).exceptionClass == c) }
    }
}

/// The in-place trap frame decode and encode (frame-profile.md §8): the
/// same values and bytes as the byte-array path.
@Suite struct TrapFramePointerTests {
    @Test func inPlaceMatchesTheByteArrays() throws {
        var bytes = [UInt8](repeating: 0, count: TrapFrame.byteCount)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 37 &+ 11) }
        let viaArray = try TrapFrame(decoding: bytes)
        let viaPointer = bytes.withUnsafeBytes { TrapFrame(decodingFrameAt: $0.baseAddress!) }
        #expect(viaArray == viaPointer)
        var f = viaPointer
        f.x[0] = 0xDEAD_BEEF
        f.carry = true
        f.flushTLB = true
        var out = [UInt8](repeating: 0xFF, count: TrapFrame.byteCount)
        out.withUnsafeMutableBytes { f.encode(into: $0.baseAddress!) }
        #expect(out == f.encoded())
        // A short x array encodes its missing registers as 0.
        var short = f
        short.x = [1, 2, 3]
        out.withUnsafeMutableBytes { short.encode(into: $0.baseAddress!) }
        #expect(out == short.encoded())
    }
}
