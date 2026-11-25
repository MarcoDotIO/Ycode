import Foundation

/// The motion layer both IDEs share (beta 5, `docs/ROADMAP-1.0.md`;
/// `specs/ide/parity-inventory.md` P-137, P-190–P-197; the panes' values
/// from council round 12, `specs/ide/window-layout.md` §6): every pane slide,
/// selector move, outline collapse, sheet exit and tooltip fade takes its
/// duration and curve from here, next to `EditorMetrics`.
///
/// Each curve keeps the reference's own times, from the effective input to
/// its first and its last moving frame (the 2026-11-15 parity run, 2x and
/// 120 Hz). The curve's clock starts at the press; it waits `delay`
/// (`start` less the input-to-frame latency Ycode adds on its own) and moves
/// for `duration` (`end − start`).
public enum Motion {
    /// From the effective input to the first frame Ycode draws for it, on
    /// top of a curve's delay: the parity run's inspector hide started moving
    /// at +132 ms on a 75 ms delay (P-192), so a curve that should start at
    /// the reference's +129 waits 72 ms.
    public static let inputLatency = 0.057

    /// One display frame at 120 Hz (the parity run's recorder).
    public static let frame = 1.0 / 120

    // MARK: Curves

    /// A CSS-style cubic Bézier through (0, 0) and (1, 1).
    public struct Bezier: Sendable, Equatable {
        public var x1, y1, x2, y2: Double

        public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            self.x1 = x1
            self.y1 = y1
            self.x2 = x2
            self.y2 = y2
        }

        public static let linear = Bezier(0, 0, 1, 1)
        public static let easeIn = Bezier(0.42, 0, 1, 1)
        public static let easeOut = Bezier(0, 0, 0.58, 1)
        public static let easeInOut = Bezier(0.42, 0, 0.58, 1)
        /// The navigator's hide (P-190, `window-layout.md` §6.1): the
        /// editor's tracked edge fits an ease-in-out ≈ (0.41, 0, 0.57, 1).
        public static let navigatorHide = Bezier(0.41, 0, 0.57, 1)
        /// The navigator's show: ease-in-out ≈ (0.2, 0, 0.6, 1).
        public static let navigatorShow = Bezier(0.2, 0, 0.6, 1)

        /// The progress at `x` (0–1 of the duration).
        public func progress(_ x: Double) -> Double {
            EditorMetrics.cubicBezier(x, x1: x1, y1: y1, x2: x2, y2: y2)
        }

        /// The tuple `EditorMetrics` and the toolkits take.
        public var points: (x1: Double, y1: Double, x2: Double, y2: Double) { (x1, y1, x2, y2) }
    }

    /// A measured motion: the reference's first and last moving frame
    /// (seconds after the input) and its curve.
    public struct Curve: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var bezier: Bezier

        public init(start: Double, end: Double, bezier: Bezier) {
            self.start = start
            self.end = end
            self.bezier = bezier
        }

        /// From the press to the curve's start.
        public var delay: Double { max(0, start - Motion.inputLatency) }
        /// The motion's length.
        public var duration: Double { max(0, end - start) }
        /// From the press to the motion's end.
        public var total: Double { delay + duration }
        /// Display frames the motion spans at `rate` hertz.
        public func frames(at rate: Double = 120) -> Int { Int((duration * rate).rounded()) }

        /// The progress `elapsed` seconds after the press.
        public func progress(elapsed: Double) -> Double {
            guard duration > 0 else { return elapsed >= delay ? 1 : 0 }
            return bezier.progress((elapsed - delay) / duration)
        }
    }

    // MARK: Panes (P-190, P-191, P-192)

    /// What started a navigator slide: a key (⌘0, View ▸ Navigators' key
    /// equivalents), a click on the toolbar's Navigators half, or a menu
    /// item chosen with the pointer.
    public enum NavigatorTrigger: Sendable { case key, click, menu }

    /// The navigator area (P-190, `window-layout.md` §6.1, council round
    /// 12's tracked edge): every trigger slides it 290 pt over 240 ms,
    /// ease-in-out. A key starts it +60…+83 ms after the press (+72 here),
    /// a click on the toolbar's half +79…+89 to hide (+84) and +146…+172 to
    /// show (+159). The menu path keeps the parity run's +38 (a menu's item
    /// fires as its menu closes; not re-measured in round 12). ⌘0 while
    /// hidden was not recorded: it takes the key's start (best evidence).
    public static func navigator(show: Bool, trigger: NavigatorTrigger = .key) -> Curve {
        let start: Double = switch trigger {
        case .key: 0.072
        case .click: show ? 0.159 : 0.084
        case .menu: 0.038
        }
        return Curve(start: start, end: start + navigatorSlideDuration, bezier: show ? .navigatorShow : .navigatorHide)
    }

    /// The menu path's curve (older callers).
    public static func navigator(show: Bool, viaMenu: Bool) -> Curve { navigator(show: show, trigger: viaMenu ? .menu : .key) }

    /// The navigator's slide: 240 ms for every trigger (§6.1 "Use").
    public static let navigatorSlideDuration = 0.240
    /// How far it travels: its own width.
    public static let navigatorSlideDistance = 290.0

    /// The debug area (P-191, `window-layout.md` §6.2, council round 12's
    /// tracked edge): ⇧⌘Y shows it over +69 → +319 ms and hides it over
    /// +78 → +338, **linear** (4 pt every 10 ms for a 102-pt area). The
    /// 2x run's ease-in / ease-out were whole-frame fits. Whether a taller
    /// area keeps 250 ms or the speed is OPEN: Ycode keeps the duration.
    public static func debugArea(show: Bool) -> Curve {
        show ? Curve(start: 0.069, end: 0.319, bezier: .linear) : Curve(start: 0.078, end: 0.338, bezier: .linear)
    }

    /// The coding assistant's swap (⌘0 with the navigators shown, B15) and
    /// a split editor added (main 16) happen in one frame: no slide
    /// (`window-layout.md` §6.3, §6.4).
    public static let assistantPaneSwap = 0.0
    public static let editorSplitAdded = 0.0

    /// ⌘Y (activate or deactivate breakpoints) dims or restores the
    /// breakpoint arrows over 11 frames, +88 → +155 ms (P-191).
    public static let breakpointDim = Curve(start: 0.088, end: 0.155, bezier: .linear)

    /// The inspector (P-192): its toggle hides it over +129 → +404 ms
    /// (≈ 275, ease-out) and shows it over +78 → +320 (≈ 240, ease-in-out);
    /// ⌥⌘1/2/3 for the inspector already shown hides it over +67 → +367
    /// (ease-out) and the next shows it over +111 → +377.
    public static func inspector(show: Bool, bySelector: Bool = false) -> Curve {
        if bySelector {
            return show ? Curve(start: 0.111, end: 0.377, bezier: .easeInOut) : Curve(start: 0.067, end: 0.367, bezier: .easeOut)
        }
        return show ? Curve(start: 0.078, end: 0.320, bezier: .easeInOut) : Curve(start: 0.129, end: 0.404, bezier: .easeOut)
    }

    // MARK: Navigator selector (P-193)

    /// A click on a navigator's tab slides the grey disc from the old tab
    /// to the new one over +147 → +430 ms (ease-out); the content swaps in
    /// one frame (+113).
    public static let selectorDisc = Curve(start: 0.147, end: 0.430, bezier: .easeOut)
    /// The content's swap after a click.
    public static let selectorContentSwap = 0.113
    /// ⌘1 cross-fades the disc and the content over 3 frames (75 ms at the
    /// reference's ≈ 40 fps for it); ⌘2–⌘9 change in one frame.
    public static func selectorKeyFade(index: Int) -> Double { index == 0 ? 0.075 : 0 }

    // MARK: File selection (P-199)

    /// Selecting a file in the navigator: the editor eases from the old
    /// file to the new one over ≈ 95 ms, starting ≈ +89 to +97 ms after the
    /// click (the middle, +93, here). The parity run gives the length and
    /// the start, not the curve's shape: ease-in-out is Ycode's choice.
    /// macOS cross-fades the editor's text area on this curve; it starts at
    /// the first frame that shows the new file when that comes later.
    public static let fileSelectionEase = Curve(start: 0.093, end: 0.188, bezier: .easeInOut)

    // MARK: Outlines (P-194)

    /// Left arrow on an expanded group: the rows below slide up over ≈ 75 ms
    /// (5 frames).
    public static let outlineCollapse = 0.075
    /// Right arrow or the disclosure triangle: ≈ 150–200 ms.
    public static let outlineExpand = 0.175
    /// A triangle's collapse animates as its expand.
    public static func outlineDuration(expand: Bool, byKey: Bool) -> Double {
        expand || !byKey ? outlineExpand : outlineCollapse
    }

    // MARK: Sheets and panels (P-196, P-137)

    /// Sheets leave with ≈ 250–315 ms slides: the scheme sheet +75 → +246,
    /// Create Branch +177 → +493.
    public static let schemeSheetExit = Curve(start: 0.075, end: 0.246, bezier: .easeIn)
    public static let branchSheetExit = Curve(start: 0.177, end: 0.493, bezier: .easeIn)
    /// A sheet's exit where the reference has no measurement of its own
    /// (Clone, New Branch): the middle of the measured range.
    public static let sheetExitDuration = 0.28
    /// The Welcome window fades ≈ 100 ms behind the Clone sheet.
    public static let welcomeFadeLag = 0.1
    /// The Run button's menu shows after the mouse is held 374 ms on it
    /// (P-028, B5-TOOLBAR's `RunButtonMenu`; the pressed tint at about 37 ms).
    public static let runMenuHoldDelay = 0.374
    /// New Project: the options page fades in over 190 ms after Next.
    public static let newProjectOptionsFadeIn = 0.19
    /// Welcome fades out over 100 ms before Open… (the file panel).
    public static let welcomeFadeOut = 0.1
    /// The breakpoint popover closes in one frame (no fade).
    public static let popoverClose = 0.0

    // MARK: Popovers and in-window panels (P-195, B5-POPOVERS; `popovers.md` §2.6, §5, §7)

    /// The scheme and destination choosers and Quick Help appear and leave
    /// in one frame (never the menu's fade); Incompatible grows in one frame.
    public static let popoverOpen = 0.0
    public static let popoverDisclosure = 0.0
    /// Jump to Line, Quick Actions, Open Quickly and Quick New Project
    /// appear in one frame and leave in one frame on Escape, except Jump to
    /// Line, which fades out (120–165 ms measured, ease-in).
    public static let panelOpen = 0.0
    public static let panelClose = 0.0
    public static let jumpToLineFadeOut = 0.14
    public static let jumpToLineFadeCurve = Bezier.easeIn
    /// A sheet's entrance (New Scheme): ≈ 150 ms ease-out from the next
    /// frame (90 % at ≈ 210 ms after the click); its exit ≈ 150 ms.
    public static let sheetEntrance = Curve(start: frame, end: frame + 0.15, bezier: .easeOut)
    public static let sheetExit = 0.15

    /// The merge alert sheet slides down over +85 → +368 ms in 24 frames,
    /// symmetric (P-137).
    public static let mergeAlertSheet = Curve(start: 0.085, end: 0.368, bezier: .easeInOut)
    /// How far the alert drops into its place (the merge sheet's own
    /// 32-point slide; the reference's distance is not measured).
    public static let mergeAlertDrop = 32.0

    // MARK: Tooltips (P-197, `specs/ui/control-states.md` §8)

    /// A toolbar control's tooltip appears 1.56 s after the pointer
    /// arrives (`control-states.md` §8, council round 12; B5-FIX-POPOVERS'
    /// `TooltipTiming` holds the same values); a move straight to another
    /// control replaces the shown tooltip after the hold, with no fade
    /// (§8.1), so the "chained" delay is the hold. An editor tab's rich
    /// tooltip after 1.1 s. It appears in one frame.
    public static let tooltipDelay = 1.56
    public static let tooltipChainedDelay = tooltipHold
    public static let tabTooltipDelay = 1.1
    /// The delay for a tooltip (`chained`: another one was just shown).
    public static func tooltipDelay(tab: Bool, chained: Bool) -> Double {
        chained ? tooltipChainedDelay : tab ? tabTooltipDelay : tooltipDelay
    }
    /// Placement: the left edge at the pointer's x, the top 18 pt below the
    /// pointer, one line 24 pt tall; dark fill #444446, a 1-pt #101012 outline.
    public static let tooltipBelowPointer = 18.0
    public static let tooltipLineHeight = 24.0
    public static let tooltipDarkFill: UInt32 = 0x444446
    public static let tooltipDarkOutline: UInt32 = 0x101012

    /// After the pointer leaves, the tooltip stays 350 ms, then fades over
    /// 460 ms (§8, round 12).
    public static let tooltipHold = 0.350
    public static let tooltipFade = 0.460

    /// The tooltip's opacity `t` seconds after the pointer left it.
    public static func tooltipOpacity(afterLeave t: Double) -> Double {
        if t <= tooltipHold { return 1 }
        return max(0, 1 - (t - tooltipHold) / tooltipFade)
    }

    /// When the tooltip is gone after the pointer left.
    public static var tooltipGone: Double { tooltipHold + tooltipFade }
}

/// A slide's clock (`InspectorSlideClock` for any curve): the curve's time
/// is counted from the press while frames come on time; a late first frame
/// starts the motion there, and a stalled frame later on advances the curve
/// by one 30 Hz frame at most. So a slide always plays, however late the
/// window draws, and never jumps to its end.
public struct MotionClock: Sendable {
    public let curve: Motion.Curve
    public let press: Double
    /// The curve's time so far (nil before the first frame).
    public private(set) var elapsed: Double?
    private var lastFrame: Double?

    /// The most a frame advances the curve.
    public static let maximumStep = 1.0 / 30

    public init(curve: Motion.Curve, press: Double) {
        self.curve = curve
        self.press = press
    }

    /// The progress (0–1) for a frame drawn at `time`.
    public mutating func progress(at time: Double) -> Double {
        let next: Double
        if let elapsed, let lastFrame {
            next = elapsed + min(max(0, time - lastFrame), Self.maximumStep)
        } else {
            next = min(max(0, time - press), curve.delay)
        }
        elapsed = next
        lastFrame = time
        return isFinished ? 1 : curve.progress(elapsed: next)
    }

    /// Whether the curve has reached its end.
    public var isFinished: Bool { (elapsed ?? 0) >= curve.total }
}
