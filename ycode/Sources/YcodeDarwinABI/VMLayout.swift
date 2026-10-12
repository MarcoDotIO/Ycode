/// The fixed memory map and register values of the Ycode micro-VM.
/// See `specs/simulator/vm-shim-protocol.md` §2 (guest physical memory) and
/// §3 (stage-1 translation). Every address here is a guest address.
public enum VMLayout {
    // MARK: Translation granule (§3)

    /// log2 of the translation granule: 16 KiB pages.
    public static let pageShift: UInt64 = 14
    /// 16 KiB, the translation granule and the size of every table.
    public static let pageSize: UInt64 = 1 << pageShift
    /// Each table is one granule of 8-byte descriptors.
    public static let entriesPerTable = Int(pageSize / 8)
    /// Width of the TTBR0 input address space: 64 − T0SZ.
    public static let virtualAddressBits: UInt64 = 47
    /// `TCR_EL1.T0SZ`.
    public static let t0sz: UInt64 = 64 - virtualAddressBits
    /// Width of the output address space selected by `TCR_EL1.IPS = 0b010`.
    public static let physicalAddressBits: UInt64 = 40

    // MARK: Guest physical memory (§2)

    /// The doorbell. No memslot backs it, so a store here exits to the VMM.
    public static let doorbellGPA: UInt64 = 0x0900_0000
    public static let doorbellSize: UInt64 = 0x4000

    /// Guest RAM, KVM memslot 0.
    public static let ramGPA: UInt64 = 0x4000_0000
    public static let ramSize: UInt64 = 512 << 20
    public static let ramSlot: UInt32 = 0

    /// The shim image is loaded at the start of RAM. Its first byte is the entry point.
    public static let shimGPA: UInt64 = ramGPA + 0x0000_0000
    public static let shimRegionSize: UInt64 = 1 << 20
    public static let shimEntryGPA: UInt64 = shimGPA

    /// Boot info block (§4). The VMM passes this address in `x0`.
    public static let bootInfoGPA: UInt64 = ramGPA + 0x0010_0000
    public static let bootInfoRegionSize: UInt64 = pageSize

    /// The trap frame (§5) of vCPU 0.
    public static let trapFrameGPA: UInt64 = ramGPA + 0x0010_4000
    public static let trapFrameRegionSize: UInt64 = pageSize

    /// The EL1 stack. It grows down from `el1StackTop`.
    public static let el1StackGPA: UInt64 = ramGPA + 0x0011_0000
    public static let el1StackSize: UInt64 = 64 << 10
    public static let el1StackTop: UInt64 = el1StackGPA + el1StackSize

    /// Stage-1 translation tables, allocated by the VMM.
    public static let pageTableArenaGPA: UInt64 = ramGPA + 0x0020_0000
    public static let pageTableArenaSize: UInt64 = 8 << 20

    /// Pages that back EL0 memory (image, stack, commpage): the rest of RAM.
    public static let el0PoolGPA: UInt64 = ramGPA + 0x0100_0000
    public static let el0PoolSize: UInt64 = ramSize - 0x0100_0000

    // MARK: EL1 identity mappings (§3)

    /// A virtual range and its permissions. EL1 regions are identity-mapped
    /// (physical address = `va`). For EL0 regions the VMM chooses the backing
    /// pages from the EL0 pool.
    public struct Region: Equatable, Hashable, Sendable {
        public var name: String
        public var va: UInt64
        public var size: UInt64
        public var attributes: PageAttributes

        public init(name: String, va: UInt64, size: UInt64, attributes: PageAttributes) {
            self.name = name
            self.va = va
            self.size = size
            self.attributes = attributes
        }

        public var end: UInt64 { va + size }
    }

    /// The EL1-only identity mappings, VA = GPA.
    public static let el1Regions: [Region] = [
        // Shim image: executable at EL1 only. AP 00 (EL1 RW) as §3 allows, so
        // the shim may keep writable data inside its own image.
        Region(name: "shim", va: shimGPA, size: shimRegionSize,
               attributes: PageAttributes(access: .el1ReadWrite, el1Execute: true)),
        // Boot info, trap frame, and EL1 stack: 0x4010_0000 up to 0x4012_0000.
        Region(name: "el1-data", va: bootInfoGPA, size: el1StackTop - bootInfoGPA,
               attributes: PageAttributes(access: .el1ReadWrite)),
        Region(name: "page-tables", va: pageTableArenaGPA, size: pageTableArenaSize,
               attributes: PageAttributes(access: .el1ReadWrite)),
        Region(name: "doorbell", va: doorbellGPA, size: doorbellSize,
               attributes: PageAttributes(access: .el1ReadWrite, device: true)),
    ]

    // MARK: EL0 self-test layout (§3, §7)

    /// The self-test image is linked here. Its first 16 KiB is `.text`.
    public static let selfTestImageVA: UInt64 = 0x1_0000_0000
    public static let selfTestTextSize: UInt64 = pageSize
    /// The 16 KiB-aligned data section of the self-test image.
    public static let selfTestDataVA: UInt64 = 0x1_0000_4000
    /// The value the self-test expects at the start of its data page.
    public static let selfTestDataMagic: UInt64 = 0x5943_4F44_4531_3645

    /// The EL0 stack ends at (and the initial SP is) `el0StackTop`.
    public static let el0StackTop: UInt64 = 0x1_7000_0000
    public static let el0StackSize: UInt64 = 64 << 10
    public static let el0StackBase: UInt64 = el0StackTop - el0StackSize

    /// The 64-bit Darwin commpage address (`specs/simulator/darwin-arm64-abi.md` §4).
    public static let commpageVA: UInt64 = 0xF_FFFF_C000
    public static let commpageSize: UInt64 = pageSize

    /// The EL0 regions of the self-test for an image of `imageSize` bytes:
    /// text, data (the rest of the image rounded up to 16 KiB, omitted when
    /// empty), stack, and commpage.
    public static func selfTestRegions(imageSize: UInt64) -> [Region] {
        var regions = [
            Region(name: "text", va: selfTestImageVA, size: selfTestTextSize,
                   attributes: PageAttributes(access: .el0ReadOnly, el0Execute: true)),
        ]
        let remainder = imageSize > selfTestTextSize ? imageSize - selfTestTextSize : 0
        if remainder > 0 {
            regions.append(Region(name: "data", va: selfTestDataVA, size: roundUpToPage(remainder),
                                  attributes: PageAttributes(access: .el0ReadWrite)))
        }
        regions.append(Region(name: "stack", va: el0StackBase, size: el0StackSize,
                              attributes: PageAttributes(access: .el0ReadWrite)))
        regions.append(Region(name: "commpage", va: commpageVA, size: commpageSize,
                              attributes: PageAttributes(access: .el0ReadOnly)))
        return regions
    }

    // MARK: Boot handoff (§4)

    /// `PSTATE` of the vCPU at reset: EL1h (M[3:0] = 0b0101) with D, A, I, F masked.
    public static let el1BootPSTATE: UInt64 = AArch64.SPSR.daifMask | AArch64.SPSR.modeEL1h
    /// `SPSR_EL1` for the first `eret` to EL0: EL0t with D, A, I, F masked (`0x3C0`).
    public static let el0InitialSPSR: UInt64 = AArch64.SPSR.daifMask | AArch64.SPSR.modeEL0t

    /// The guest PID that `getpid` returns in stage 2.
    public static let guestPID: Int32 = 100
    /// The VMM's exit status when the guest takes a non-SVC exception (§6).
    public static let fatalExitStatus: Int32 = 70

    // MARK: Recommended system register values (§3)

    public static let tcrEL1: UInt64 = AArch64.TCR.recommended
    public static let mairEL1: UInt64 = AArch64.MAIR.recommended
    public static let sctlrEL1: UInt64 = AArch64.SCTLR.recommended

    static func roundUpToPage(_ v: UInt64) -> UInt64 { (v + pageSize - 1) & ~(pageSize - 1) }
    static func isPageAligned(_ v: UInt64) -> Bool { v & (pageSize - 1) == 0 }
}

// MARK: - Stage 3 (specs/simulator/stage3-contract.md §2, §3, §5)

/// Stage-3 constants. The stage-2 constants above are unchanged and still
/// describe the stage-2 self-test; a stage-3 VMM uses these instead where
/// they differ (RAM size, table arena size).
extension VMLayout {
    // MARK: Guest physical memory (§3)

    /// Guest RAM (memslot 0) in stage 3: same GPA as stage 2, 1 GiB.
    public static let stage3RAMSize: UInt64 = 1 << 30
    /// The stage-1 table arena in stage 3: same GPA as stage 2, 64 MiB.
    public static let stage3PageTableArenaGPA: UInt64 = pageTableArenaGPA
    public static let stage3PageTableArenaSize: UInt64 = 64 << 20

    /// The anonymous pool: one memslot, carved at 16 KiB granularity.
    public static let anonymousPoolGPA: UInt64 = 0x10_0000_0000
    public static let anonymousPoolSize: UInt64 = 16 << 30
    /// File mappings get one memslot each, bump-allocated from here upward.
    public static let fileSlotGPABase: UInt64 = 0x20_0000_0000
    /// The first memslot number after RAM (slot 0).
    public static let firstExtraMemslot: UInt32 = 1

    /// The EL1-only identity mappings in stage 3: as `el1Regions`, with the
    /// page-table region grown to the 64 MiB arena.
    public static let stage3EL1Regions: [Region] = el1Regions.map { r in
        guard r.name == "page-tables" else { return r }
        return Region(name: r.name, va: stage3PageTableArenaGPA, size: stage3PageTableArenaSize, attributes: r.attributes)
    }

    // MARK: Guest virtual address map (§2)

    /// The lowest VA a guest mapping may use: the end of the 4 GiB
    /// `__PAGEZERO`. Only the EL1 identity regions live below it.
    public static let userVAFloor: UInt64 = 0x1_0000_0000
    /// The iOS-family user VA limit (`MACH_VM_MAX_ADDRESS`). Anywhere
    /// allocations and guest fixed mappings stay below it; only the VMM's
    /// permanent mappings (commpage) go above.
    public static let userVALimit: UInt64 = 0xF_C000_0000
    /// The main executable is mapped at its preferred vmaddr, which starts here.
    public static let mainExecutableBaseVA: UInt64 = 0x1_0000_0000

    /// The main stack: `[userStackBase, userStackTop)`, 8 MiB.
    public static let userStackTop: UInt64 = 0x1_6FE0_0000
    public static let userStackSize: UInt64 = 8 << 20
    public static let userStackBase: UInt64 = userStackTop - userStackSize

    /// The shared-region reservation. Only `MAP_FIXED` mappings go here.
    public static let sharedRegionBase: UInt64 = 0x1_8000_0000
    public static let sharedRegionSize: UInt64 = 0x1_8000_0000
    public static let sharedRegionEnd: UInt64 = sharedRegionBase + sharedRegionSize

    /// `dyld_sim` is mapped as one reservation starting here.
    public static let dyldSimBaseVA: UInt64 = 0x3_0000_0000

    /// Anonymous allocations without a fixed address: first fit at or above this.
    public static let anonymousVABase: UInt64 = 0x3_2000_0000

    /// The commpage nesting reservation, kept free of every other mapping.
    public static let commpageReservationBase: UInt64 = 0xF_C000_0000
    public static let commpageReservationEnd: UInt64 = 0x10_0000_0000
    /// The read-only commpage (16 KiB, EL0 RO). `commpageVA` is the RW-data page.
    public static let readOnlyCommpageVA: UInt64 = 0xF_FFFF_4000

    // MARK: Ycode host page (§5)

    /// The host page (`host_stubs.bin`), 64 KiB at `hostPageVA`.
    public static let hostPageVA: UInt64 = 0x3_1000_0000
    public static let hostPageSize: UInt64 = 0x1_0000

    /// Code, EL0 RX. `_ycode_launch` is at offset 0.
    public static let hostPageCodeOffset: UInt64 = 0x0000
    public static let hostPageCodeSize: UInt64 = 0x4000
    /// Read-only data, EL0 RO. It starts with the helpers table.
    public static let hostPageRODataOffset: UInt64 = 0x4000
    public static let hostPageRODataSize: UInt64 = 0x4000
    /// Read-write data, EL0 RW.
    public static let hostPageRWDataOffset: UInt64 = 0x8000
    public static let hostPageRWDataSize: UInt64 = 0x8000

    /// Helpers table: `version`, then the slot pointers (544 bytes).
    public static let hostPageHelpersOffset: UInt64 = 0x4000
    public static let hostPageHelpersSize: UInt64 = 544
    public static let helpersTableVersion: UInt64 = 18
    public static let helpersSlotCount = 67
    /// The errno cell (an `int` in an 8-byte slot).
    public static let hostPageErrnoOffset: UInt64 = 0x8000
    /// The `startGlue` cell that `dyld_sim` writes.
    public static let hostPageStartGlueOffset: UInt64 = 0x8008
    /// The launch block, 12 × u64.
    public static let hostPageLaunchBlockOffset: UInt64 = 0x8040
    public static let hostPageLaunchBlockSize: UInt64 = 96
    /// `dyld_all_image_infos`.
    public static let hostPageAllImageInfosOffset: UInt64 = 0x8100
    public static let hostPageAllImageInfosSize: UInt64 = 368
    /// `infoArray`, `uuidArray`, and path strings.
    public static let hostPageImageInfoStorageOffset: UInt64 = 0x8300
    public static let hostPageImageInfoStorageSize: UInt64 = 0x800
    /// `sysctlbyname` and scratch space.
    public static let hostPageScratchOffset: UInt64 = 0x9000
    public static let hostPageScratchSize: UInt64 = 0x1000

    /// The EL0 entry point (`_ycode_launch`).
    public static let hostPageEntryVA: UInt64 = hostPageVA + hostPageCodeOffset

    /// The host page's three EL0 regions (code RX, read-only data, read-write data).
    public static let hostPageRegions: [Region] = [
        Region(name: "host-code", va: hostPageVA + hostPageCodeOffset, size: hostPageCodeSize,
               attributes: PageAttributes(access: .el0ReadOnly, el0Execute: true)),
        Region(name: "host-rodata", va: hostPageVA + hostPageRODataOffset, size: hostPageRODataSize,
               attributes: PageAttributes(access: .el0ReadOnly)),
        Region(name: "host-rwdata", va: hostPageVA + hostPageRWDataOffset, size: hostPageRWDataSize,
               attributes: PageAttributes(access: .el0ReadWrite)),
    ]
}

/// Field positions of the AArch64 registers and descriptors the VMM programs,
/// named as in the Arm Architecture Reference Manual for A-profile.
public enum AArch64 {
    /// Translation Control Register (EL1).
    public enum TCR {
        public static func t0sz(_ v: UInt64) -> UInt64 { (v & 0x3F) << 0 }      // T0SZ, bits [5:0]
        public static let epd0: UInt64 = 1 << 7                                  // EPD0: disable TTBR0 walks
        public static func irgn0(_ v: UInt64) -> UInt64 { (v & 3) << 8 }        // IRGN0, bits [9:8]
        public static func orgn0(_ v: UInt64) -> UInt64 { (v & 3) << 10 }       // ORGN0, bits [11:10]
        public static func sh0(_ v: UInt64) -> UInt64 { (v & 3) << 12 }         // SH0, bits [13:12]
        public static func tg0(_ v: UInt64) -> UInt64 { (v & 3) << 14 }         // TG0, bits [15:14]
        public static func t1sz(_ v: UInt64) -> UInt64 { (v & 0x3F) << 16 }     // T1SZ, bits [21:16]
        public static let a1: UInt64 = 1 << 22                                   // A1: ASID from TTBR1
        public static let epd1: UInt64 = 1 << 23                                 // EPD1: disable TTBR1 walks
        public static func tg1(_ v: UInt64) -> UInt64 { (v & 3) << 30 }         // TG1, bits [31:30]
        public static func ips(_ v: UInt64) -> UInt64 { (v & 7) << 32 }         // IPS, bits [34:32]
        public static let tbi0: UInt64 = 1 << 37                                 // TBI0: top byte ignored

        /// Normal memory, inner/outer write-back read-allocate write-allocate cacheable.
        public static let cacheWriteBackAllocate: UInt64 = 0b01
        public static let shareabilityInner: UInt64 = 0b11
        /// TG0 and TG1 encode the granule differently.
        public static let tg0Granule16K: UInt64 = 0b10
        public static let tg1Granule16K: UInt64 = 0b01
        /// IPS 0b010: 40-bit (1 TiB) intermediate physical addresses.
        public static let ips40Bit: UInt64 = 0b010

        /// The §3 value. T1SZ is also set to 17 so that the (disabled) TTBR1
        /// range has an architecturally valid size; it has no other effect.
        public static let recommended: UInt64 =
            t0sz(VMLayout.t0sz)
            | irgn0(cacheWriteBackAllocate) | orgn0(cacheWriteBackAllocate)
            | sh0(shareabilityInner)
            | tg0(tg0Granule16K)
            | t1sz(VMLayout.t0sz)
            | epd1
            | tg1(tg1Granule16K)
            | ips(ips40Bit)
    }

    /// Memory Attribute Indirection Register (EL1): eight 8-bit Attr<n> fields.
    public enum MAIR {
        /// Normal memory, inner and outer write-back non-transient, read- and write-allocate.
        public static let normalWriteBack: UInt8 = 0xFF
        /// Device-nGnRnE.
        public static let deviceNGnRnE: UInt8 = 0x00
        /// AttrIndx values used in leaf descriptors.
        public static let normalIndex: UInt64 = 0
        public static let deviceIndex: UInt64 = 1

        public static func attr(_ index: UInt64, _ value: UInt8) -> UInt64 { UInt64(value) << (8 * index) }

        public static let recommended: UInt64 = attr(normalIndex, normalWriteBack) | attr(deviceIndex, deviceNGnRnE)
    }

    /// System Control Register (EL1).
    public enum SCTLR {
        public static let m: UInt64 = 1 << 0          // M: stage-1 MMU enable
        public static let a: UInt64 = 1 << 1          // A: alignment check
        public static let c: UInt64 = 1 << 2          // C: data cacheability
        public static let sa: UInt64 = 1 << 3         // SA: SP alignment check at EL1
        public static let sa0: UInt64 = 1 << 4        // SA0: SP alignment check at EL0
        public static let itd: UInt64 = 1 << 7        // ITD: AArch32 IT disable (RES1 without AArch32 EL0)
        public static let sed: UInt64 = 1 << 8        // SED: AArch32 SETEND disable (RES1 without AArch32 EL0)
        public static let eos: UInt64 = 1 << 11       // EOS: exception exit is context-synchronizing (RES1 before FEAT_ExS)
        public static let i: UInt64 = 1 << 12         // I: instruction cacheability
        public static let dze: UInt64 = 1 << 14       // DZE: EL0 may execute DC ZVA
        public static let uct: UInt64 = 1 << 15       // UCT: EL0 may read CTR_EL0
        public static let nTWI: UInt64 = 1 << 16      // nTWI: do not trap EL0 WFI
        public static let nTWE: UInt64 = 1 << 18      // nTWE: do not trap EL0 WFE
        public static let wxn: UInt64 = 1 << 19       // WXN: write implies execute-never
        public static let tscxt: UInt64 = 1 << 20     // TSCXT: trap EL0 SCXTNUM_EL0 (RES1 without FEAT_CSV2_2)
        public static let eis: UInt64 = 1 << 22       // EIS: exception entry is context-synchronizing (RES1 before FEAT_ExS)
        public static let span: UInt64 = 1 << 23      // SPAN: PSTATE.PAN unchanged on exception (RES1 before FEAT_PAN)
        public static let e0e: UInt64 = 1 << 24       // E0E: EL0 data endianness
        public static let ee: UInt64 = 1 << 25        // EE: EL1 data and table-walk endianness
        public static let uci: UInt64 = 1 << 26       // UCI: EL0 may execute cache maintenance by VA
        public static let nTLSMD: UInt64 = 1 << 28    // nTLSMD (RES1 without FEAT_LSMAOC)
        public static let lsmaoe: UInt64 = 1 << 29    // LSMAOE (RES1 without FEAT_LSMAOC)

        /// The bits that are RES1 on an ARMv8.0 implementation (and that keep
        /// the v8.0 behaviour when the later feature exists): EOS, TSCXT, EIS,
        /// SPAN, nTLSMD, LSMAOE, plus ITD and SED, which are RES1 when EL0
        /// cannot use AArch32 and only disable AArch32 instructions otherwise.
        public static let res1: UInt64 = itd | sed | eos | tscxt | eis | span | nTLSMD | lsmaoe

        /// The §3 value: MMU and caches on, SP alignment checks, EL0 cache and
        /// WFI/WFE access, little-endian, no alignment checking, no WXN.
        public static let recommended: UInt64 =
            m | c | sa | sa0 | i | dze | uct | nTWI | nTWE | uci | span | eis | eos | res1
    }

    /// Saved Program Status Register / PSTATE fields.
    public enum SPSR {
        public static let n: UInt64 = 1 << 31
        public static let z: UInt64 = 1 << 30
        /// The carry flag. Darwin BSD calls set it to report an error.
        public static let c: UInt64 = 1 << 29
        public static let v: UInt64 = 1 << 28
        public static let d: UInt64 = 1 << 9
        public static let a: UInt64 = 1 << 8
        public static let i: UInt64 = 1 << 7
        public static let f: UInt64 = 1 << 6
        public static let daifMask: UInt64 = d | a | i | f
        /// M[3:0] values (AArch64 execution state).
        public static let modeEL0t: UInt64 = 0b0000
        public static let modeEL1t: UInt64 = 0b0100
        public static let modeEL1h: UInt64 = 0b0101
    }

    /// Stage-1 VMSAv8-64 descriptor fields (16 KiB granule).
    public enum Descriptor {
        /// bits[1:0] = 0b11: a table descriptor at levels 1–2, a page descriptor at level 3.
        public static let validTableOrPage: UInt64 = 0b11
        public static let typeMask: UInt64 = 0b11
        public static func attrIndx(_ v: UInt64) -> UInt64 { (v & 7) << 2 }     // AttrIndx, bits [4:2]
        public static let ns: UInt64 = 1 << 5                                     // NS
        public static func ap(_ v: UInt64) -> UInt64 { (v & 3) << 6 }           // AP[2:1], bits [7:6]
        public static func sh(_ v: UInt64) -> UInt64 { (v & 3) << 8 }           // SH, bits [9:8]
        public static let af: UInt64 = 1 << 10                                    // AF: access flag
        public static let nG: UInt64 = 1 << 11                                    // nG: not global
        public static let pxn: UInt64 = 1 << 53                                   // PXN: privileged execute-never
        public static let uxn: UInt64 = 1 << 54                                   // UXN: unprivileged execute-never
        /// Output address bits [47:14] for the 16 KiB granule.
        public static let outputAddressMask: UInt64 = 0x0000_FFFF_FFFF_C000
    }
}
