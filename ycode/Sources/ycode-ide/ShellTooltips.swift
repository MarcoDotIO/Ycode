import Foundation
import SwiftUI
import YcodeIDECore

/// Tooltips with the macOS IDE's timing (P-197, `specs/ui/control-states.md`
/// §8, §8.1): 1.56 s to appear, a 350 ms hold after the pointer leaves, then
/// a 460 ms linear fade; moving straight onto another control swaps the
/// tooltip once the hold is over. OpenViews' `help(_:)` draws them; this sets
/// its timing from `TooltipTiming` (YcodeIDECore), the numbers the AppKit
/// IDE's `ToolTipPresenter` uses.
@MainActor
enum ShellTooltips {
    static func apply() {
        #if os(Linux)
        guard TooltipTimings.delay != TooltipTiming.delay else { return }
        TooltipTimings.delay = TooltipTiming.delay
        TooltipTimings.hold = TooltipTiming.hold
        TooltipTimings.fade = TooltipTiming.fade
        // After a tooltip has faded out completely, the next control waits
        // the full delay (§8.1 item 3, OPEN: the full delay until settled).
        TooltipTimings.grace = 0
        #endif
    }
}
