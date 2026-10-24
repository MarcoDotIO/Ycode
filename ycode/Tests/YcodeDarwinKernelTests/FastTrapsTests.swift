import Foundation
import Testing
import YcodeDarwinABI
@testable import YcodeDarwinKernel

// specs/simulator/fast-traps.md §2, §4, §5 (the VMM-side data of the
// exit-free hot calls).
@Suite struct FastTrapsTests {
    private func u64(_ p: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(p[o + $1]) << (8 * UInt64($1)) } }
    private func u32(_ p: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(p[o + $1]) << (8 * UInt32($1)) } }

    @Test func defaultCommpageTrapsEverything() {
        let p = CommpageBuilder().rwPage()
        #expect(CommpageBuilder.Offset.fastFlags == 0x0F8 && p[0x0F8] == 0)
        #expect((0..<16).allSatisfy { p[0x1000 + $0] == 0 })
        #expect((0..<5).allSatisfy { u64(p, 0x120 + 8 * $0) == 0 })
    }

    @Test func flagsCredentialsAndSnapshot() {
        var c = CommpageBuilder()
        c.fastFlags = CommpageBuilder.FastFlag.directClock | CommpageBuilder.FastFlag.credentialBlock
        c.credentials = .init(uid: 501, euid: 502, gid: 20, egid: 21)
        c.timeOfDay = .init(tick: 777, seconds: 1_700_000_000, nanoseconds: 500_000_000, frequency: 1_000_000_000)
        let p = c.rwPage()
        #expect(p[0x0F8] == 3)
        #expect(u32(p, 0x1000) == 501 && u32(p, 0x1004) == 502 && u32(p, 0x1008) == 20 && u32(p, 0x100C) == 21)
        #expect(u64(p, 0x120) == 777 && u64(p, 0x128) == 1_700_000_000)
        #expect(u64(p, 0x130) == UInt64(1) << 63)                      // 0.5 s as a binary fraction
        #expect(u64(p, 0x138) == ((UInt64(1) << 63) / 1_000_000_000) * 2)
        #expect(u64(p, 0x140) == 1_000_000_000)
        // Darwin's own fields are unchanged by the flags.
        // (USER_TIMEBASE is 0 with the 24 MHz guest timebase, 1 with the host counter.)
        #expect(p[0x090] == (GuestTimebase.usesHostCounter ? 1 : 0) && u64(p, 0x088) == 0 && u64(p, 0x098) == 0 && p[0x0C8] == 0)
        // No scale block unless one is set.
        #expect(u64(p, 0x1010) == 0 && u64(p, 0x1018) == 0)
    }

    /// §3.2: the clock scale block, and the library's formula
    /// ⌊c × M / 2^s⌋ equals the kernel's `ClockScale.apply`.
    @Test func clockScaleBlockAndFormula() {
        let scale = GuestTimebase.ClockScale(from: 1_000_000_000, to: 24_000_000)
        #expect(scale.shift == 64)
        var c = CommpageBuilder()
        c.fastFlags = CommpageBuilder.FastFlag.directClock
        c.clockScale = scale
        let p = c.rwPage()
        #expect(u64(p, 0x1010) == scale.multiplier && u64(p, 0x1018) == 64)
        // The guest library's formula, written out with 128-bit arithmetic.
        func library(_ counter: UInt64) -> UInt64 {
            let product = UInt128(counter) * UInt128(scale.multiplier)
            return UInt64(truncatingIfNeeded: product >> UInt128(scale.shift))
        }
        var x: UInt64 = 0x1234_5678_9ABC
        var last: UInt64 = 0
        for i in 0..<10_000 {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            let counter = (x >> 14) &+ UInt64(i)
            #expect(library(counter) == scale.apply(counter))
            // Within one tick of the exact ratio 3/125, never below it.
            let exact = counter.multipliedFullWidth(by: 3)
            let q = UInt64(125).dividingFullWidth(exact).quotient
            #expect(scale.apply(counter) == q || scale.apply(counter) == q + 1)
        }
        // Monotonic over a run of consecutive counter values.
        for counter in UInt64(4_000_000_000_000)..<4_000_000_002_000 {
            let v = scale.apply(counter)
            #expect(v >= last)
            last = v
        }
        // Whole multiples of the ratio are exact; identity when the frequencies match.
        #expect(scale.apply(1_000_000_000) == 24_000_000 && scale.apply(125) == 3 && scale.apply(124) == 2)
        #expect(GuestTimebase.ClockScale(from: 24_000_000, to: 24_000_000) == .identity)
        // A slower counter scales up (31.25 MHz -> 24 MHz down, 19.2 MHz -> 24 MHz up).
        #expect(GuestTimebase.ClockScale(from: 31_250_000, to: 24_000_000).apply(31_250_000) == 24_000_000)
        #expect(GuestTimebase.ClockScale(from: 19_200_000, to: 24_000_000).apply(19_200_000) == 24_000_000)
    }

    @Test func snapshotReaderMatchesTheWallClock() {
        let f: UInt64 = 1_000_000_000
        let s = CommpageBuilder.TimeOfDaySnapshot(tick: 10_000, seconds: 100, nanoseconds: 999_999_000, frequency: f)
        let now = s.timeval(at: 10_000)!
        #expect(now.seconds == 100 && (999_998...999_999).contains(now.microseconds))
        // 2 µs later the second rolls over.
        let later = s.timeval(at: 12_000)!
        #expect(later.seconds == 101 && later.microseconds <= 1)
        // 0.3 s later.
        #expect(s.timeval(at: 10_000 + 300_000_000)!.seconds == 101)
        // One second or more: stale.
        #expect(s.timeval(at: 10_000 + f) == nil)
        // A tick of 0 is invalid.
        #expect(CommpageBuilder.TimeOfDaySnapshot(tick: 0, seconds: 1, nanoseconds: 0, frequency: f).timeval(at: 5) == nil)
        // 24 MHz: 1.5 s - 1 tick away from a .25 s snapshot gives .75 s.
        let g = CommpageBuilder.TimeOfDaySnapshot(tick: 1, seconds: 7, nanoseconds: 250_000_000, frequency: 24_000_000)
        let v = g.timeval(at: 1 + 12_000_000)!
        #expect(v.seconds == 7 && (749_999...750_000).contains(v.microseconds))
    }

    @Test func gettimeofdayTrapRefreshesTheSnapshot() throws {
        let env = try Env(counter: { 0x5555 })
        var published: [(UInt64, Int64, Int64)] = []
        env.kernel.timeOfDayPublisher = { published.append(($0, $1, $2)) }
        let (_, f) = env.svc(116, [Env.scratch, 0, 0])
        #expect(f.x[0] == 0 && !f.carry)
        #expect(published.count == 1)
        #expect(published.first.map { $0.0 == 0x5555 && $0.1 == 1_700_000_000 && $0.2 == 250_000_000 } == true)
        // Without a publisher nothing is stored (the default).
        let plain = try Env()
        #expect(plain.kernel.timeOfDayPublisher == nil)
        #expect(plain.svc(116, [Env.scratch, 0, 0]).1.x[0] == 0)
    }

    @Test func hvcDoorbellBootInfo() throws {
        let info = BootInfo(ttbr0EL1: 0x4020_0000, el0EntryPC: 0, doorbellAddress: 0)
        let decoded = try BootInfo(decoding: info.encoded())
        #expect(decoded.doorbellAddress == 0 && decoded.encoded() == info.encoded())
        #expect(BootInfo(ttbr0EL1: 0, el0EntryPC: 0).doorbellAddress == VMLayout.doorbellGPA)
    }
}
