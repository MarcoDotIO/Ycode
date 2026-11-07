import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

/// task_info's CPU-time flavors (`TaskInfoFlavors.swift`, boot-profile.md
/// §16): layouts of xnu's `osfmk/mach/task_info.h`, the count checks, and
/// the private trap answering them for the caller's own task.
@Suite struct TaskInfoFlavorTests {
    private let s = Env.scratch

    @Test func layoutsAndCounts() {
        let user: UInt64 = 2_500_000_000, system: UInt64 = 750_000_000
        func reply(_ flavor: UInt32, _ count: UInt32 = 64) -> ([UInt8], UInt32)? {
            guard case let .reply(b, words) = DarwinKernel.taskInfoTimes(flavor: flavor, count: count, user: user,
                                                                       system: system, frequency: 24_000_000) else { return nil }
            return (b, words)
        }
        // TASK_THREAD_TIMES_INFO: two time_value_t.
        let times = try? #require(reply(3))
        #expect(times?.1 == 4 && times?.0.count == 16)
        #expect(times?.0.readLE(Int32.self, at: 0) == 2 && times?.0.readLE(Int32.self, at: 4) == 500_000)
        #expect(times?.0.readLE(Int32.self, at: 8) == 0 && times?.0.readLE(Int32.self, at: 12) == 750_000)
        // TASK_ABSOLUTETIME_INFO: mach absolute time at 24 MHz.
        let abs = try? #require(reply(1))
        #expect(abs?.1 == 8 && abs?.0.readLE(UInt64.self, at: 0) == 60_000_000 && abs?.0.readLE(UInt64.self, at: 8) == 18_000_000)
        // MACH_TASK_BASIC_INFO: the times after three sizes, then policy and suspend count.
        let basic = try? #require(reply(20))
        #expect(basic?.1 == 12 && basic?.0.count == 48 && basic?.0.readLE(Int32.self, at: 24) == 2)
        #expect(basic?.0.readLE(Int32.self, at: 40) == 1)
        // TASK_BASIC_INFO_64 and _64_2: packed to 4 (the size at offset 4).
        #expect(reply(5)?.1 == 10 && reply(5)?.0.count == 40 && reply(18)?.0.readLE(Int32.self, at: 20) == 2)
        // TASK_POWER_INFO and _V2 (24 words, 26 with task_energy).
        #expect(reply(21)?.1 == 12 && reply(21)?.0.count == 48)
        #expect(reply(26, 24)?.1 == 24 && reply(26, 24)?.0.count == 96 && reply(26)?.1 == 26)
        #expect(reply(26)?.0.readLE(UInt64.self, at: 80) == user + system)  // task_ptime
        // Too small a count; an unknown flavor.
        #expect(DarwinKernel.taskInfoTimes(flavor: 3, count: 3, user: 0, system: 0, frequency: 0) == .tooSmall)
        #expect(DarwinKernel.taskInfoTimes(flavor: 99, count: 64, user: 0, system: 0, frequency: 0) == .unsupported)
    }

    @Test func theTrapAnswersForTheCallersTask() throws {
        let env = try Env()
        env.kernel.processCPUTimes = { (2_500_000_000, 750_000_000) }
        try env.put(le32(4), at: s + 0x40)
        let (_, r) = env.svc(0x7963_0006, [0x103, 3, s, s + 0x40])         // TASK_THREAD_TIMES_INFO
        #expect(r.x[0] == 0)
        let b = try env.space.read(va: s, count: 16)
        #expect(b.readLE(Int32.self, at: 0) == 2 && b.readLE(Int32.self, at: 12) == 750_000)
        #expect(try env.u32(s + 0x40) == 4)
        try env.put(le32(2), at: s + 0x40)
        #expect(env.svc(0x7963_0006, [0x103, 3, s, s + 0x40]).1.x[0] == 4)  // count too small
        try env.put(le32(12), at: s + 0x40)
        #expect(env.svc(0x7963_0006, [0x999, 20, s, s + 0x40]).1.x[0] == 4) // not a task port
    }
}
