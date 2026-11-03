// DeviceButtonTable (watchos.md §5.2; hid-input.md §5.5): the display
// stream's buttons and the watch's named buttons as HID usage pairs.

import Testing
@testable import YcodeDisplayStream

struct ButtonUsageTests {
    typealias T = DeviceButtonTable

    @Test func phoneButtonsKeepTheirUsages() {
        #expect(T.usage(of: .home, for: .phone) == HIDUsagePair(page: 0x0C, usage: 0x40))
        #expect(T.usage(of: .lock, for: .phone) == HIDUsagePair(page: 0x0C, usage: 0x30))
        #expect(T.usage(of: .side, for: .phone) == HIDUsagePair(page: 0x0C, usage: 0x95))
        #expect(T.usage(of: .volumeUp, for: .phone)?.usage == 0xE9 && T.usage(of: .volumeDown, for: .phone)?.usage == 0xEA)
        // A phone's Action button keeps its provisional side usage.
        #expect(T.usage(of: .action, for: .phone) == T.side)
        #expect(T.buttons(for: .phone) == DisplayButton.allCases)
    }

    @Test func watchButtons() {
        let series = T.Family.watch(actionButton: false), ultra = T.Family.watch(actionButton: true)
        // §5.2: crown press 0x0C/0x40, side button 0x0C/0x95, screen toggle 0x0C/0x30.
        for f in [series, ultra] {
            #expect(T.usage(of: .home, for: f) == HIDUsagePair(page: 0x0C, usage: 0x40))
            #expect(T.usage(of: .side, for: f) == HIDUsagePair(page: 0x0C, usage: 0x95))
            #expect(T.usage(of: .lock, for: f) == HIDUsagePair(page: 0x0C, usage: 0x30))
            #expect(T.usage(of: .volumeUp, for: f) == nil && T.usage(of: .volumeDown, for: f) == nil)
        }
        // The Action button only on the Ultra types, on the vendor page 0xFF01, usage 0x200.
        #expect(T.usage(of: .action, for: ultra) == HIDUsagePair(page: 0xFF01, usage: 0x200))
        #expect(T.usage(of: .action, for: series) == nil)
        #expect(T.buttons(for: series) == [.home, .lock, .side])
        #expect(T.buttons(for: ultra) == [.home, .lock, .side, .action])
        #expect(T.buttons(for: ultra).map(\.name) == ["home", "lock", "side", "action"])
    }

    @Test func watchBundleAcceptsOnlyItsPairs() {
        for p in [T.home, T.side, T.lock] { #expect(T.watchAccepts(p, actionButton: false)) }
        #expect(T.watchAccepts(T.watchAction, actionButton: true) && !T.watchAccepts(T.watchAction, actionButton: false))
        // §5.2's other sources: no receiver, a vendor event, the source that crashed the reference.
        for p in [HIDUsagePair(page: 0x0C, usage: 0x1BA), HIDUsagePair(page: 0x0C, usage: 0x223), HIDUsagePair(page: 7, usage: 0),
                  HIDUsagePair(page: 0xFF00, usage: 0x10), HIDUsagePair(page: 0x0B, usage: 0x2D), T.volumeUp] {
            #expect(!T.watchAccepts(p, actionButton: true), "\(p)")
        }
    }

    @Test func namedWatchButtons() {
        #expect(T.WatchButton(named: "crown") == .crown && T.WatchButton(named: "home") == .crown)
        #expect(T.WatchButton(named: "Side") == .side && T.WatchButton(named: "action-button") == .action)
        #expect(T.WatchButton(named: "screen") == .screen && T.WatchButton(named: "lock") == .screen)
        #expect(T.WatchButton(named: "volume") == nil)
        #expect(T.WatchButton.allCases.map(\.displayButton) == [.home, .side, .action, .lock])
        #expect("\(T.watchAction)" == "0xFF01/0x200")
    }

    @Test func actionButtonOnTheWire() throws {
        let m = DisplayMessage.input(.button(sequence: 3, button: .action, down: true))
        #expect(Array(m.encoded().suffix(2)) == [6, 1])
        var p = DisplayMessageParser()
        p.append(m.encoded())
        #expect(try p.next() == m)
    }
}
