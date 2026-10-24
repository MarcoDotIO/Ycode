import Foundation
import Testing
@testable import YcodeDarwinKernel

/// The per-trap kernel-lock profile (`YCODE_TRAP_PROFILE`, diagnostics).
@Suite struct TrapProfileTests {
    @Test func rowsAccumulateAndReport() throws {
        let path = NSTemporaryDirectory() + "ycode-trap-profile-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).txt"
        let profile = TrapProfile(path: path)
        // workq_kernreturn (368): two traps; the second takes the lock twice.
        profile.noteHandler(368, 3_000_000)
        profile.noteHandler(368, 5_000_000)
        profile.noteWait(368, 1_000, contended: false)
        profile.noteHold(368, 2_000_000)
        profile.noteWait(368, 4_000_000, contended: true)
        profile.noteHold(368, 1_000_000)
        profile.noteHold(368, 500_000)
        profile.noteHold(TrapProfile.serviceKey, 10_000)

        let row = try #require(profile.snapshot[368])
        #expect(row.count == 2)
        #expect(row.acquisitions == 3)
        #expect(row.holdNanoseconds == 3_500_000)
        #expect(row.maxHoldNanoseconds == 2_000_000)
        #expect(row.waits == 2)
        #expect(row.contended == 1)
        #expect(row.maxWaitNanoseconds == 4_000_000)
        #expect(profile.snapshot[TrapProfile.serviceKey]?.acquisitions == 1)

        let text = profile.report(limit: 5)
        #expect(text.contains("bsd 368 workq_kernreturn"))
        #expect(text.contains("(service: no trap)"))
        #expect(text.contains("Acquisitions 4 (2.00 per trap)"))
        #expect(text.contains("contended 1 (50.0 %)"))

        profile.dump()
        let written = try String(contentsOfFile: path, encoding: .utf8)
        #expect(written.hasPrefix("ycode trap lock profile:"))
        try? FileManager.default.removeItem(atPath: path)
    }

    @Test func keysFollowTheTrapInProgress() {
        let context = ThreadContext(threadID: 7, portName: 0x1003, vcpuIndex: 1, kind: .pthread)
        #expect(TrapProfile.key(for: nil) == TrapProfile.serviceKey)
        #expect(TrapProfile.key(for: context) == TrapProfile.serviceKey)
        context.arrivingTrap = UInt64(bitPattern: -3)
        #expect(TrapProfile.key(for: context) == -3)
        context.trapInProgress = (375, [])
        #expect(TrapProfile.key(for: context) == 375)
    }
}
