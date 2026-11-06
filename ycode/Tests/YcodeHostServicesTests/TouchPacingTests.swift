import Foundation
import Testing
@testable import YcodeHostServices

/// How the host paces input into the guest (uikit-feel-ycode.md §4.0, hid-input.md §14.3).
struct TouchPacingTests {
    func u32(_ b: [UInt8], _ at: Int) -> UInt32 { b.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) } }

    @Test func theAgeTravelsInTheReservedWords() {
        let t = HIDHostService.body(.touch(display: 0, contacts: [
            .init(index: 1, phase: .moved, edge: .none, x: 0.5, y: 0.5),
            .init(index: 2, phase: .moved, edge: .none, x: 0.25, y: 0.5),
        ]), sequence: 1, age: 1234)
        #expect(u32(t, 24 + 12) == 1234 && u32(t, 56 + 12) == 1234)
        let k = HIDHostService.body(.key(usagePage: 7, usage: 4, down: true), sequence: 2, age: 99)
        #expect(u32(k, 28) == 99)
        // Without an age the bytes are those of older hosts.
        #expect(u32(HIDHostService.body(.key(usagePage: 7, usage: 4, down: true), sequence: 2), 28) == 0)
    }

    @Test func ageIsMicrosecondsAndClamped() {
        #expect(TouchPacing.ageMicroseconds(received: 1_000_000, now: 1_000_000) == 0)
        #expect(TouchPacing.ageMicroseconds(received: 1_000_000, now: 18_000_000) == 17_000)
        #expect(TouchPacing.ageMicroseconds(received: 5, now: 4) == 0)
        #expect(TouchPacing.ageMicroseconds(received: 0, now: 60_000_000_000) == TouchPacing.maximumAgeMicroseconds)
    }

    @Test func onlyAMoveFollowedSoonByAMoveIsDropped() {
        let ms: UInt64 = 1_000_000
        // A 60 Hz stream that backed up: every sample is kept.
        #expect(!TouchPacing.isSuperseded(moveOnly: true, received: 0, next: (true, 16 * ms + ms / 2)))
        // Faster than 120 Hz: the older move goes.
        #expect(TouchPacing.isSuperseded(moveOnly: true, received: 0, next: (true, 4 * ms)))
        // Never a began, ended, key or button, and never before one.
        #expect(!TouchPacing.isSuperseded(moveOnly: false, received: 0, next: (true, ms)))
        #expect(!TouchPacing.isSuperseded(moveOnly: true, received: 0, next: (false, ms)))
        #expect(!TouchPacing.isSuperseded(moveOnly: true, received: 0, next: nil))
    }

    @Test func aRestingContactIsReportedEveryFrame() {
        let ms: UInt64 = 1_000_000
        #expect(!TouchPacing.restReportDue(anyDown: false, lastTouchSent: 0, now: 100 * ms))
        #expect(!TouchPacing.restReportDue(anyDown: true, lastTouchSent: 100 * ms, now: 110 * ms))
        #expect(TouchPacing.restReportDue(anyDown: true, lastTouchSent: 100 * ms, now: 117 * ms))
    }

    @Test func restReportsAlternateByOnePixelTowardsTheCentre() {
        let w = 1206.0
        #expect(TouchPacing.restPosition(x: 0.2, y: 0.3, count: 2, pixelWidth: w) == (0.2, 0.3))
        let a = TouchPacing.restPosition(x: 0.2, y: 0.3, count: 1, pixelWidth: w)
        #expect(abs(a.x - (0.2 + 1 / w)) < 1e-12 && a.y == 0.3)
        let b = TouchPacing.restPosition(x: 0.9, y: 0.3, count: 3, pixelWidth: w)
        #expect(abs(b.x - (0.9 - 1 / w)) < 1e-12)
    }
}
