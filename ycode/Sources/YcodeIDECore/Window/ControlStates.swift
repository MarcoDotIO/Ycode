import Foundation

// The control-state model both IDEs draw from (P-198, issues #63 and #64;
// `specs/ui/control-states.md`). Each kind of control has a **state** (rest,
// hover, pressed, disabled; keyboard focus is separate) and a **trigger**
// (mouse-down or mouse-up), and this table maps state to fill, label, size
// and timing, in dark and light. The macOS IDE (`YcodeUI`) and the Linux IDE
// (`ycode-ide` on OpenViews) read the same values.
//
// Measured at 1x / 100 Hz under load (b5-obs 2026-11-20): sizes ±1 pt,
// timings ±20 ms. "One frame" means the change is complete in the first
// frame after the input: no fade.

/// An sRGB colour as 0xRRGGBB and an opacity.
public struct StateColor: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let hex: UInt32
    public let alpha: Double

    public init(_ hex: UInt32, alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    public var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    public var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    public var blue: Double { Double(hex & 0xFF) / 255 }

    public var description: String { String(format: "#%06X", hex) + (alpha < 1 ? String(format: "@%.2f", alpha) : "") }
}

/// What a control shows at a moment.
public enum ControlState: String, CaseIterable, Sendable {
    case rest, hover, pressed, disabled
}

/// When a control acts (`control-states.md` §1 rule 5).
public enum ControlTrigger: Sendable, Equatable {
    /// On mouse-down: controls that open a menu or popover (choosers,
    /// pop-up buttons, the filter options menu) and Settings sidebar rows.
    case mouseDown
    /// On mouse-up inside the control; releasing outside cancels.
    case mouseUp
    /// On mouse-up anywhere: a glass tab bar selects the tab under its lens
    /// (or the last one the pointer crossed); releasing outside is not a
    /// cancel (§3).
    case release
}

/// The kinds of control the spec measures.
public enum ControlKind: String, CaseIterable, Sendable {
    /// A segment of a toolbar glass capsule (Run, Coding Assistant).
    case toolbarSegment
    /// The selected segment of a toolbar group (Navigators).
    case toolbarSelectedSegment
    /// A toolbar glass circle (the inspector toggle).
    case toolbarCircle
    /// One half of the scheme › destination capsule.
    case toolbarChooserHalf
    /// The issue capsule ("⚠ 1").
    case issueCapsule
    /// A tab of the navigator selector.
    case navigatorTab
    /// A tab of the inspector's tab bar.
    case inspectorTab
    /// A flat segmented control (Build Settings Basic / Customized / All).
    case segment
    /// A sheet's default push button (Next, OK, Perform Changes).
    case sheetDefaultButton
    /// A sheet's other push buttons (Cancel, Previous).
    case sheetCancelButton
    /// A Settings pop-up button ("Use System Setting").
    case settingsPopUp
    /// A Settings switch.
    case settingsSwitch
    /// A Settings sidebar row.
    case settingsSidebarRow
    /// The "Recent files" toggle in the navigator's filter field.
    case filterToggle
    /// The filter options button in the navigator's filter field.
    case filterOptions
    /// A glyph button of the editor's bottom bar ("show debug area").
    case bottomBarGlyph
    /// An outline row's disclosure triangle.
    case disclosure
    /// A target tab of the project editor.
    case targetTab
    /// An editor tab.
    case editorTab
    /// An editor tab's close button.
    case editorTabClose
    /// A path segment of the jump bar (hover and press not recorded, §10
    /// item 4: Ycode draws none).
    case jumpBarSegment
}

/// One kind of control's look per state.
public struct ControlStateStyle: Equatable, Sendable {
    public var kind: ControlKind
    /// Whether the control has a hover state (§1 rule 2: most have none).
    public var hasHover: Bool
    public var trigger: ControlTrigger
    /// The fill (or bezel) at rest, under the pointer and while held; nil:
    /// none drawn in that state.
    public var restFill: StateColor?
    public var hoverFill: StateColor?
    public var pressedFill: StateColor?
    /// The label's or glyph's colour while held, where it changes (a
    /// pressed segment's label dims; the bottom bar's glyph brightens in
    /// dark and darkens in light).
    public var restLabel: StateColor?
    public var pressedLabel: StateColor?
    /// The hover bezel's size inside the control (nil: the whole control).
    public var hoverBezel: BezelSize?
    /// How much larger the held shape is on each side, points (§2 Grow:
    /// toolbar glass 1–2 pt; flat controls 0).
    public var grow: Double
    /// Seconds the hover bezel takes to go after the pointer leaves (0: one
    /// frame; the editor tab's × fades ≈ 150 ms, §5).
    public var hoverFadeOut: Double

    /// A bezel's width and height, points.
    public struct BezelSize: Equatable, Sendable {
        public var width: Double
        public var height: Double

        public init(width: Double, height: Double) {
            self.width = width
            self.height = height
        }
    }

    init(kind: ControlKind, hasHover: Bool = false, trigger: ControlTrigger = .mouseUp, restFill: StateColor? = nil,
         hoverFill: StateColor? = nil, pressedFill: StateColor? = nil, restLabel: StateColor? = nil,
         pressedLabel: StateColor? = nil, hoverBezel: (Double, Double)? = nil, grow: Double = 0, hoverFadeOut: Double = 0) {
        self.kind = kind
        self.hasHover = hasHover
        self.trigger = trigger
        self.restFill = restFill
        self.hoverFill = hoverFill
        self.pressedFill = pressedFill
        self.restLabel = restLabel
        self.pressedLabel = pressedLabel
        self.hoverBezel = hoverBezel.map { BezelSize(width: $0.0, height: $0.1) }
        self.grow = grow
        self.hoverFadeOut = hoverFadeOut
    }

    /// The fill in `state` (disabled: the rest fill; a disabled control
    /// has no hover and no pressed state, §7).
    public func fill(_ state: ControlState) -> StateColor? {
        switch state {
        case .rest, .disabled: return restFill
        case .hover: return hasHover ? (hoverFill ?? restFill) : restFill
        case .pressed: return pressedFill ?? restFill
        }
    }

    /// The label colour in `state` (nil: the control's own).
    public func label(_ state: ControlState) -> StateColor? {
        state == .pressed ? (pressedLabel ?? restLabel) : restLabel
    }

    /// Whether `state` can be shown at all: hover only where the kind has
    /// it, nothing but rest when disabled.
    public func resolve(hovered: Bool, pressed: Bool, enabled: Bool) -> ControlState {
        guard enabled else { return .disabled }
        if pressed { return .pressed }
        if hovered && hasHover { return .hover }
        return .rest
    }
}

/// The table (`control-states.md` §2–§7).
public enum ControlStates {
    // MARK: Timing

    /// Hover appears and goes in one frame (§1 rule 1).
    public static let hoverDuration = 0.0
    /// The editor tab's × bezel fades out over ≈ 150 ms (§5).
    public static let closeBezelFadeOut = 0.150
    /// Held toolbar glass: the tint and grow reach 90 % at 100–145 ms
    /// (§2 Timing); Ycode animates over 120 ms.
    public static let pressIn = 0.120
    /// After release or leaving, the control settles in 120–320 ms; Ycode
    /// settles over 200 ms.
    public static let settle = 0.200
    /// Flat controls (segments, sheet buttons) tint in one frame and do not
    /// grow (§1 rule 3).
    public static let flatPress = 0.0

    /// The progress (0–1) of a glass control's held look `elapsed` seconds
    /// after mouse-down (ease-out to 1 at `pressIn`).
    public static func pressProgress(elapsed: Double) -> Double {
        guard elapsed > 0 else { return 0 }
        let x = min(1, elapsed / pressIn)
        return 1 - (1 - x) * (1 - x)
    }

    /// The progress (1 → 0) of the held look `elapsed` seconds after the
    /// release, starting from `from` (ease-in-out over `settle`).
    public static func settleProgress(elapsed: Double, from: Double = 1) -> Double {
        guard elapsed > 0 else { return from }
        let x = min(1, elapsed / settle)
        let eased = x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
        return from * (1 - eased)
    }

    /// The scale of a held shape of `size` points (the larger side) that
    /// grows `grow` points on each side.
    public static func pressedScale(size: Double, grow: Double) -> Double {
        guard size > 0 else { return 1 }
        return (size + 2 * grow) / size
    }

    /// The toolbar's hover and held bezels are 28 tall in the 36-point glass.
    public static let toolbarBezelHeight = 28.0

    // MARK: Focus (§6)

    /// Focus rings are drawn only with the system's Full Keyboard Access on
    /// (not recorded with it on, §10 item 2: Ycode then draws the system's).
    /// Without it a focused field shows only its caret.
    public static func showsFocusRing(fullKeyboardAccess: Bool) -> Bool { fullKeyboardAccess }

    /// The caret of a focused field (dark #2360A5; light: the accent).
    public static func fieldCaret(dark: Bool) -> StateColor? { dark ? StateColor(0x2360A5) : nil }

    // MARK: Settings pop-up (§4)

    /// The pop-up's hover bezel covers the whole control (166 × 24 for "Use
    /// System Setting"): 24 tall, reaching this far before the value's text
    /// (Ycode's measure of the control's frame), radius 6.
    public static let popUpBezelLead = 8.0
    public static let popUpBezelHeight = 24.0
    public static let popUpBezelRadius = 6.0

    // MARK: Disabled (§7)

    /// A disabled toolbar button keeps its glass; only its glyph dims
    /// (Stop with nothing running).
    public static func disabledToolbarGlyph(dark: Bool) -> StateColor { dark ? StateColor(0x7A7A7B) : StateColor(0xA5A6A7) }
    /// Mouse-down on a disabled toolbar button starts a window drag: the
    /// press falls through to the toolbar.
    public static let disabledToolbarPressDragsWindow = true

    // MARK: The table

    /// The style of `kind` in dark or light.
    public static func style(_ kind: ControlKind, dark: Bool) -> ControlStateStyle {
        func c(_ d: UInt32, _ l: UInt32) -> StateColor { StateColor(dark ? d : l) }
        switch kind {
        case .toolbarSegment:
            // Run: #444446 → #58585A / #F0F0F3 → #E7E7E7; held dark #6E6E71,
            // light #ECECEE; bezel ≈ 34 × 28 in a 37 × 36 segment.
            return ControlStateStyle(kind: kind, hasHover: true, restFill: c(0x444446, 0xF0F0F3), hoverFill: c(0x58585A, 0xE7E7E7),
                                     pressedFill: c(0x6E6E71, 0xECECEE), hoverBezel: (34, 28), grow: 1)
        case .toolbarSelectedSegment:
            return ControlStateStyle(kind: kind, hasHover: true, restFill: c(0x58585A, 0xDDDDDF), hoverFill: c(0x6D6D6F, 0xD2D2D2),
                                     pressedFill: c(0x6E6E71, 0xFDFDFD), hoverBezel: (32, 28), grow: 1)
        case .toolbarCircle:
            return ControlStateStyle(kind: kind, hasHover: true, restFill: c(0x434345, 0xF0F0F3), hoverFill: c(0x58585A, 0xE6E6E6),
                                     pressedFill: c(0x8C8C8F, 0xF9F9FB), grow: 1.5)
        case .toolbarChooserHalf:
            // Opens its popover on mouse-down; the bezel is as wide as the
            // half's content, 28 tall.
            return ControlStateStyle(kind: kind, hasHover: true, trigger: .mouseDown, restFill: c(0x424242, 0xFAFAFA),
                                     hoverFill: c(0x4B4B4B, 0xEDEDED), pressedFill: c(0x505050, 0xDFDFDF))
        case .issueCapsule:
            return ControlStateStyle(kind: kind, hasHover: true, restFill: c(0x424242, 0xFAF9F9), hoverFill: c(0x565656, 0xEFEEEF),
                                     hoverBezel: (53, 28))
        case .navigatorTab:
            return ControlStateStyle(kind: kind, trigger: .release, restFill: c(0x5E5E60, 0xE8E8EB), pressedFill: c(0x423F41, 0xDDDEDE))
        case .inspectorTab:
            return ControlStateStyle(kind: kind, trigger: .release, restFill: c(0x626265, 0xE9E9EC), pressedFill: c(0x49494B, 0xE5E5E7))
        case .segment:
            // The pressed segment takes the selected fill and its label dims.
            return ControlStateStyle(kind: kind, restFill: c(0x303030, 0xF3F3F3), pressedFill: c(0xA0A0A0, 0x787878),
                                     restLabel: c(0xE8E8E8, 0xFFFFFF), pressedLabel: c(0xC4C4C4, 0xFFFFFF))
        case .sheetDefaultButton:
            // #0078FE; held lighter in dark, darker in light.
            return ControlStateStyle(kind: kind, restFill: StateColor(0x0078FE), pressedFill: c(0x2C85FD, 0x006CE5),
                                     restLabel: StateColor(0xFFFFFF))
        case .sheetCancelButton:
            return ControlStateStyle(kind: kind, restFill: c(0x2F2F31, 0xEBEBEB), pressedFill: c(0x434345, 0xD3D3D3))
        case .settingsPopUp:
            // A bezel over the whole control; the menu opens on mouse-down.
            return ControlStateStyle(kind: kind, hasHover: true, trigger: .mouseDown, restFill: c(0x232326, 0xF6F6F6),
                                     hoverFill: c(0x343436, 0xE4E4E4))
        case .settingsSwitch:
            return ControlStateStyle(kind: kind, restFill: c(0x232323, 0xFDFDFD), pressedFill: c(0x272729, 0xF5F5F5))
        case .settingsSidebarRow:
            // Selects on mouse-down: grey to the accent at once.
            return ControlStateStyle(kind: kind, trigger: .mouseDown, restFill: c(0x434345, 0xD6D6D6), pressedFill: c(0x0078FE, 0x006EF4))
        case .filterToggle:
            return ControlStateStyle(kind: kind, restFill: c(0x575759, 0xD0D0D2), pressedFill: c(0x69696C, 0xD3D3D6))
        case .filterOptions:
            return ControlStateStyle(kind: kind, trigger: .mouseDown)
        case .bottomBarGlyph:
            return ControlStateStyle(kind: kind, restLabel: c(0x6E6E6E, 0xAEAEAE), pressedLabel: c(0x979797, 0x767676))
        case .disclosure, .targetTab, .jumpBarSegment:
            // No hover and no visible pressed state (§4; D-046).
            return ControlStateStyle(kind: kind)
        case .editorTab:
            // Hover shows the tab's × and pin buttons, no bezel (§5).
            return ControlStateStyle(kind: kind, hasHover: true)
        case .editorTabClose:
            // Dark #575757 → #606060, held #686868; light not recorded
            // (§10 item 3): Ycode's equivalents on the light tab.
            return ControlStateStyle(kind: kind, hasHover: true, restFill: nil, hoverFill: c(0x606060, 0xD8D8D8),
                                     pressedFill: c(0x686868, 0xCDCDCD), hoverBezel: (16, 16), hoverFadeOut: closeBezelFadeOut)
        }
    }

    /// The kinds with a hover state (§1 rule 2).
    public static var hoverKinds: [ControlKind] { ControlKind.allCases.filter { style($0, dark: true).hasHover } }
}

// MARK: - Editor tabs (§5)

/// The editor tab's hover controls.
public enum EditorTabStates {
    /// The × button's frame and its round hover bezel.
    public static let closeButtonSize = 18.0
    public static let closeBezelDiameter = 16.0
    /// The rich tooltip's delay on a tab.
    public static let toolTipDelay = 1.1

    /// Whether tab `tab` shows its × and pin: the hovered tab (one frame).
    public static func showsHoverControls(tab: Int, hovered: Int?) -> Bool { tab == hovered }

    /// The × bezel's opacity `elapsed` seconds after the pointer left it
    /// (a linear fade over `ControlStates.closeBezelFadeOut`).
    public static func closeBezelOpacity(afterLeave elapsed: Double) -> Double {
        guard elapsed > 0 else { return 1 }
        return max(0, 1 - elapsed / ControlStates.closeBezelFadeOut)
    }
}

// MARK: - Glass tab bars (§3)

/// The glass lens of the navigator selector and the inspector's tab bar:
/// no hover; mouse-down raises a lens over the selected tab that glides to
/// the pressed tab and follows the pointer along the bar while the button
/// is held; the selection changes on release, to the tab under the lens (or
/// the last tab the pointer crossed). Releasing outside is not a cancel.
public struct GlassTabLens: Equatable, Sendable {
    public enum Bar: Sendable { case navigator, inspector }

    public let bar: Bar
    public private(set) var tabCount: Int
    public private(set) var selected: Int
    /// The tab the lens sits over (nil: no lens).
    public private(set) var lensTab: Int?
    /// The tab the lens rose from (the selection at mouse-down).
    public private(set) var origin: Int?

    public init(bar: Bar, tabCount: Int, selected: Int) {
        self.bar = bar
        self.tabCount = max(0, tabCount)
        self.selected = min(max(0, selected), max(0, tabCount - 1))
    }

    public var isHeld: Bool { lensTab != nil }

    /// The lens's size: a circle ≈ 42 across on the navigator selector, a
    /// capsule ≈ 98 × 40 on an inspector tab (larger than the bar: it
    /// overhangs it above and below).
    public var lensSize: (width: Double, height: Double) { bar == .navigator ? (42, 42) : (98, 40) }
    /// The lens glides from the selected tab to the pressed tab (≈ 0.35 s
    /// under load across two tabs; Ycode: 200 ms) and shrinks into the
    /// selected pill after release (150–250 ms; Ycode: 200 ms).
    public static let glide = 0.200
    public static let shrink = 0.200

    /// The tint inside the lens at rest (lens just risen) and held.
    public func tint(dark: Bool, held: Bool) -> StateColor {
        let s = ControlStates.style(bar == .navigator ? .navigatorTab : .inspectorTab, dark: dark)
        return (held ? s.pressedFill : s.restFill) ?? StateColor(0x808080)
    }

    /// Mouse-down on `tab`.
    public mutating func press(_ tab: Int) {
        guard tabCount > 0 else { return }
        origin = selected
        lensTab = clamp(tab)
    }

    /// The pointer moved while held: the lens follows it along the bar,
    /// tab by tab (nil: the pointer is past the bar's ends or off it
    /// vertically; the lens stays on the last tab it crossed).
    public mutating func drag(_ tab: Int?) {
        guard lensTab != nil, let tab else { return }
        lensTab = clamp(tab)
    }

    /// The release: the tab under the lens becomes selected (returned).
    @discardableResult
    public mutating func release() -> Int? {
        guard let t = lensTab else { return nil }
        selected = t
        lensTab = nil
        origin = nil
        return t
    }

    /// Updates the bar after the selection changed elsewhere.
    public mutating func update(tabCount: Int, selected: Int) {
        self.tabCount = max(0, tabCount)
        self.selected = clamp(selected)
        if let l = lensTab { lensTab = clamp(l) }
    }

    /// The tab at `x` along a bar whose tabs start at `leading` and are
    /// `tabWidth` wide (nil: past either end).
    public static func tab(atX x: Double, leading: Double, tabWidth: Double, count: Int) -> Int? {
        guard tabWidth > 0, count > 0, x >= leading else { return nil }
        let i = Int((x - leading) / tabWidth)
        return i < count ? i : nil
    }

    private func clamp(_ t: Int) -> Int { min(max(0, t), max(0, tabCount - 1)) }
}
