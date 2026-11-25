import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// The beta 5 fix round (Ycode's P-197): `TooltipTimings` lets an app give
// `help(_:)` a hold and a linear fade after the pointer leaves, and swap the
// tip for the next view's once the hold is over, with no new delay.

@MainActor
@Suite("B5 tooltip hold, fade and swap", .serialized)
struct TooltipHoldFadeTests {
    func withYcodeTimings(_ body: () -> Void) {
        let saved = (TooltipTimings.delay, TooltipTimings.hold, TooltipTimings.fade, TooltipTimings.grace)
        TooltipTimings.delay = 1.56
        TooltipTimings.hold = 0.35
        TooltipTimings.fade = 0.46
        TooltipTimings.grace = 0
        defer { (TooltipTimings.delay, TooltipTimings.hold, TooltipTimings.fade, TooltipTimings.grace) = saved }
        body()
    }

    func harness() -> CommandsHarness {
        CommandsHarness(menuBar: false) {
            VStack(spacing: 40) {
                Button("Run") {}.help("Build and then run")
                Button("Stop") {}.help("Stop the running scheme")
                Text("Plain")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @Test func holdsThenFadesAfterTheDelay() {
        withYcodeTimings {
            let h = harness()
            guard let run = h.textFrame("Run"), let plain = h.textFrame("Plain") else { Issue.record("views"); return }
            h.hover(CGPoint(x: run.midX, y: run.midY), at: 1.0)
            h.run(until: 2.5)
            #expect(h.textFrame("Build and then run") == nil, "not before 1.56 s")
            h.run(until: 2.6)
            #expect(h.textFrame("Build and then run") != nil)
            let center = h.main.services.tooltips
            // Leaving: held 350 ms, then fading, gone after 460 ms more.
            h.hover(CGPoint(x: plain.midX, y: plain.midY), at: 3.0)
            h.run(until: 3.3)
            #expect(center.current != nil && !center.fading, "held")
            h.run(until: 3.4)
            #expect(center.current != nil && center.fading, "fading")
            h.run(until: 3.85)
            #expect(center.current == nil, "gone after 350 + 460 ms")
        }
    }

    @Test func movingOntoAnotherViewSwapsAfterTheHold() {
        withYcodeTimings {
            let h = harness()
            guard let run = h.textFrame("Run"), let stop = h.textFrame("Stop") else { Issue.record("views"); return }
            h.hover(CGPoint(x: run.midX, y: run.midY), at: 1.0)
            h.run(until: 2.6)
            h.hover(CGPoint(x: stop.midX, y: stop.midY), at: 3.0)
            h.run(until: 3.2)
            #expect(h.textFrame("Build and then run") != nil && h.textFrame("Stop the running scheme") == nil, "the old tip held")
            h.run(until: 3.36)
            #expect(h.textFrame("Stop the running scheme") != nil && h.textFrame("Build and then run") == nil, "swapped after 350 ms")
            #expect(!h.main.services.tooltips.fading)
            // A press removes it at once.
            h.click(CGPoint(x: stop.midX, y: stop.midY), at: 3.5)
            #expect(h.textFrame("Stop the running scheme") == nil)
        }
    }
}
