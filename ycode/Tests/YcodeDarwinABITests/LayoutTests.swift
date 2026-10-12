import Testing
@testable import YcodeDarwinABI

/// Checks the constants of specs/simulator/vm-shim-protocol.md §2–§4 and the
/// recommended system register values, which are derived by hand here from the
/// Arm field positions.
@Suite struct LayoutTests {
    @Test func guestPhysicalMap() {
        #expect(VMLayout.pageSize == 16384)
        #expect(VMLayout.entriesPerTable == 2048)
        #expect(VMLayout.t0sz == 17)
        #expect(VMLayout.doorbellGPA == 0x0900_0000)
        #expect(VMLayout.doorbellSize == 0x4000)
        #expect(VMLayout.ramGPA == 0x4000_0000)
        #expect(VMLayout.ramSize == 0x2000_0000)
        #expect(VMLayout.ramSlot == 0)
        #expect(VMLayout.shimGPA == 0x4000_0000)
        #expect(VMLayout.shimEntryGPA == 0x4000_0000)
        #expect(VMLayout.shimRegionSize == 0x10_0000)
        #expect(VMLayout.bootInfoGPA == 0x4010_0000)
        #expect(VMLayout.trapFrameGPA == 0x4010_4000)
        #expect(VMLayout.el1StackGPA == 0x4011_0000)
        #expect(VMLayout.el1StackSize == 0x1_0000)
        #expect(VMLayout.el1StackTop == 0x4012_0000)
        #expect(VMLayout.pageTableArenaGPA == 0x4020_0000)
        #expect(VMLayout.pageTableArenaSize == 0x80_0000)
        #expect(VMLayout.el0PoolGPA == 0x4100_0000)
        #expect(VMLayout.el0PoolGPA + VMLayout.el0PoolSize == 0x6000_0000)
        for a in [VMLayout.doorbellGPA, VMLayout.shimGPA, VMLayout.bootInfoGPA, VMLayout.trapFrameGPA,
                  VMLayout.el1StackGPA, VMLayout.el1StackTop, VMLayout.pageTableArenaGPA, VMLayout.el0PoolGPA] {
            #expect(a % 0x4000 == 0)
        }
    }

    @Test func el1Regions() {
        let r = Dictionary(uniqueKeysWithValues: VMLayout.el1Regions.map { ($0.name, $0) })
        #expect(r["shim"]?.va == 0x4000_0000 && r["shim"]?.end == 0x4010_0000)
        #expect(r["el1-data"]?.va == 0x4010_0000 && r["el1-data"]?.end == 0x4012_0000)
        #expect(r["page-tables"]?.va == 0x4020_0000 && r["page-tables"]?.end == 0x40A0_0000)
        #expect(r["doorbell"]?.va == 0x0900_0000 && r["doorbell"]?.size == 0x4000)
        #expect(r["shim"]?.attributes == PageAttributes(access: .el1ReadWrite, device: false, el0Execute: false, el1Execute: true))
        #expect(r["el1-data"]?.attributes == PageAttributes(access: .el1ReadWrite))
        #expect(r["page-tables"]?.attributes == PageAttributes(access: .el1ReadWrite))
        #expect(r["doorbell"]?.attributes == PageAttributes(access: .el1ReadWrite, device: true))
        for region in VMLayout.el1Regions {
            #expect(!region.attributes.access.isEL0Readable, "\(region.name) must be EL1-only")
            #expect(!region.attributes.el0Execute)
            #expect(region.end <= 0x1_0000_0000, "EL1 regions live below 4 GiB (inside __PAGEZERO)")
        }
    }

    @Test func selfTestRegions() {
        let regions = VMLayout.selfTestRegions(imageSize: 0x4000 + 10)
        #expect(regions.map(\.name) == ["text", "data", "stack", "commpage"])
        #expect(regions[0].va == 0x1_0000_0000 && regions[0].size == 0x4000)
        #expect(regions[0].attributes == PageAttributes(access: .el0ReadOnly, el0Execute: true, el1Execute: false))
        #expect(regions[1].va == 0x1_0000_4000 && regions[1].size == 0x4000)
        #expect(regions[1].attributes == PageAttributes(access: .el0ReadWrite))
        #expect(regions[2].va == 0x1_6FFF_0000 && regions[2].end == 0x1_7000_0000)
        #expect(regions[2].attributes == PageAttributes(access: .el0ReadWrite))
        #expect(regions[3].va == 0xF_FFFF_C000 && regions[3].size == 0x4000)
        #expect(regions[3].attributes == PageAttributes(access: .el0ReadOnly))

        #expect(VMLayout.selfTestRegions(imageSize: 0x4000).map(\.name) == ["text", "stack", "commpage"])
        #expect(VMLayout.selfTestRegions(imageSize: 100).map(\.name) == ["text", "stack", "commpage"])
        #expect(VMLayout.selfTestRegions(imageSize: 0x9000)[1].size == 0x8000)
        #expect(VMLayout.selfTestRegions(imageSize: 0xC000)[1].size == 0x8000)
    }

    @Test func handoffConstants() {
        #expect(VMLayout.el0InitialSPSR == 0x3C0)
        // EL1h is M[3:0] = 0b0101; D, A, I, F are bits 9..6.
        #expect(VMLayout.el1BootPSTATE == 0x3C5)
        #expect(VMLayout.guestPID == 100)
        #expect(VMLayout.fatalExitStatus == 70)
        #expect(VMLayout.selfTestDataMagic == 0x5943_4F44_4531_3645)
    }

    @Test func tcrValue() {
        // T0SZ=17 (0x11) | IRGN0=01<<8 | ORGN0=01<<10 | SH0=11<<12 | TG0=10<<14
        // | T1SZ=17<<16 | EPD1=1<<23 | TG1=01<<30 | IPS=010<<32
        // | TBI0=1<<37 (stage 6: Darwin ignores the top byte of EL0 data addresses)
        let expected: UInt64 = 0x11 | 0x100 | 0x400 | 0x3000 | 0x8000 | 0x11_0000 | 0x80_0000 | 0x4000_0000 | 0x2_0000_0000
            | 1 << 37
        #expect(expected == 0x22_4091_B511)
        #expect(VMLayout.tcrEL1 == expected)
        // A1 (bit 22), EPD0 (bit 7) are clear.
        #expect(VMLayout.tcrEL1 & (1 << 22) == 0)
        #expect(VMLayout.tcrEL1 & (1 << 7) == 0)
    }

    @Test func mairValue() {
        #expect(VMLayout.mairEL1 == 0x0000_0000_0000_00FF)
        #expect(VMLayout.mairEL1 & 0xFF == 0xFF)          // Attr0: Normal WB RW-allocate
        #expect((VMLayout.mairEL1 >> 8) & 0xFF == 0x00)   // Attr1: Device-nGnRnE
    }

    @Test func sctlrValue() {
        let bits: [Int] = [
            0, 2, 3, 4,          // M, C, SA, SA0
            7, 8,                // ITD, SED (RES1 without AArch32 EL0)
            11,                  // EOS (RES1 before FEAT_ExS)
            12, 14, 15, 16, 18,  // I, DZE, UCT, nTWI, nTWE
            20,                  // TSCXT (RES1 without FEAT_CSV2_2)
            22, 23,              // EIS, SPAN
            26,                  // UCI
            28, 29,              // nTLSMD, LSMAOE (RES1 without FEAT_LSMAOC)
        ]
        let expected = bits.reduce(UInt64(0)) { $0 | (1 << UInt64($1)) }
        #expect(expected == 0x34D5_D99D)
        #expect(VMLayout.sctlrEL1 == expected)
        // A, WXN, EE, E0E are clear.
        for b: UInt64 in [1, 19, 24, 25] { #expect(VMLayout.sctlrEL1 & (1 << b) == 0) }
        #expect(VMLayout.sctlrEL1 & AArch64.SCTLR.res1 == AArch64.SCTLR.res1)
    }
}
