import Testing
import YcodeDarwinABI
import YcodeHypervisor
@testable import ycode_simd

/// The vCPU slots of a process (stage4a-contract.md §4, agent ICON-FREEZE):
/// 512 slots, as many as Darwin's workqueue threads per process, in two
/// identity-mapped regions that overlap nothing else in guest RAM.
@Suite struct VCPUSlotLayoutTests {
    @Test func slotsCoverDarwinsWorkqueueThreadLimit() {
        #expect(VCPUSlots.count == 512)
        #expect(VCPUSlots.lowCount == 64)
        // The first 64 slots keep their stage-4a addresses.
        #expect(VCPUSlots.slotGPA(0) == 0x4100_0000)
        #expect(VCPUSlots.slotGPA(63) == 0x4100_0000 + 63 * 0x1_0000)
        #expect(VCPUSlots.slotGPA(64) == VCPUSlots.highBaseGPA)
        #expect(VCPUSlots.stackTop(VCPUSlots.count - 1) == VCPUSlots.highBaseGPA + VCPUSlots.highRegionSize)
    }

    @Test func everySlotLiesInItsRegionAndNoTwoOverlap() {
        var previousEnd: UInt64 = 0
        for i in 0..<VCPUSlots.count {
            let start = VCPUSlots.slotGPA(i), end = start + VCPUSlots.slotSize
            let region = i < VCPUSlots.lowCount ? VCPUSlots.region : VCPUSlots.highRegion
            #expect(start >= region.va && end <= region.va + region.size, "slot \(i)")
            #expect(start >= previousEnd, "slot \(i)")
            previousEnd = end
            #expect(VCPUSlots.bootInfoGPA(i) == start && VCPUSlots.frameGPA(i) == start + 0x4000)
        }
    }

    #if os(Linux) && arch(arm64)
    @Test func processRegionsDoNotOverlapAndFitInRAM() {
        let regions = stage4EL1Regions
        #expect(regions.contains { $0.name == "vcpu-slots" } && regions.contains { $0.name == "vcpu-slots-2" })
        let ramEnd = VMLayout.ramGPA + VMLayout.stage3RAMSize
        for (i, a) in regions.enumerated() {
            // The doorbell is MMIO outside RAM on purpose (no memslot backs it).
            if a.name != "doorbell" { #expect(a.va >= VMLayout.ramGPA && a.va + a.size <= ramEnd, "\(a.name)") }
            for b in regions[(i + 1)...] {
                #expect(a.va + a.size <= b.va || b.va + b.size <= a.va, "\(a.name) overlaps \(b.name)")
            }
        }
        // The table arena ends where the second slot region starts.
        #expect(stage4TableArenaGPA + VMLayout.stage3PageTableArenaSize == VCPUSlots.highBaseGPA)
    }
    #endif
}
