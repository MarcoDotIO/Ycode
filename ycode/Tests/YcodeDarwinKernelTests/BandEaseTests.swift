import Foundation
import Synchronization
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// The band's ease window (`YCODE_BG_BAND_EASE_MS`, scheduling-policy.md
/// §4.9): background threads that fill the CPUs themselves do not count as
/// a burst, or they would keep each other out (`boot-profile.md` §22).
extension KernelSwitchSuites {
@Suite(.serialized) struct BandEaseTests {
    let kernel = DarwinKernel(fileSystem: DarwinFileSystem(prefixes: [], console: { _, _ in }), pid: 101)
    final class Box: @unchecked Sendable { let ctx: ThreadContext; let k: DarwinKernel; init(_ c: ThreadContext, _ k: DarwinKernel) { ctx = c; self.k = k } }
    @Test(arguments: [0, 300]) func backgroundThreadsFillingTheCPUsDoNotKeepEachOtherOut(ease: Int) {
        let saved = (BackgroundBand.cpus, BackgroundBand.easeNanoseconds, BackgroundBand.pollNanoseconds)
        BackgroundBand.cpus = 4
        BackgroundBand.easeNanoseconds = UInt64(ease) * 1_000_000
        BackgroundBand.pollNanoseconds = 100_000_000
        defer { (BackgroundBand.cpus, BackgroundBand.easeNanoseconds, BackgroundBand.pollNanoseconds) = saved }
        BackgroundBand.lastSaturated.store(KernelClock.now(), ordering: .relaxed)
        let start = Date()
        let group = DispatchGroup()
        for i in 0..<20 {
            let c = ThreadContext(threadID: UInt64(100 + i), portName: 0x1003, vcpuIndex: 0, kind: .pthread)
            c.schedClassStore.store(SchedClass.background, ordering: .relaxed)
            c.kernel = kernel
            let b = Box(c, kernel)
            group.enter()
            Thread {
                for _ in 0..<50 { BackgroundBand.afterTrap(b.ctx, kernel: b.k); usleep(200) }
                BackgroundBand.stopped()
                group.leave()
            }.start()
        }
        #expect(group.wait(timeout: .now() + 60) == .success)
        // 20 threads × 50 trap ends on 4 places: well under a second either way
        // (the window costs one wait of at most 300 ms after the stamp above).
        #expect(Date().timeIntervalSince(start) < 5)
    }
}
}
