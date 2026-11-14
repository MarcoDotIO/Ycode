import Foundation
import YcodeSyntax

/// The merge sheet's geometry, colours, motion and texts
/// (`specs/ide/merge-sheet.md`), shared by the AppKit sheet and the Linux
/// IDE's sheet so both draw the same thing. Values are points; colours are
/// sRGB hex. Entries marked "Ycode's choice" answer the spec's open
/// questions and say so there.
public enum MergeSheetMetrics {
    // §2 Frame
    /// From each side of the window (and, Ycode's choice, from its bottom).
    public static let sheetInset = 24.0
    public static let cornerRadius = 16.0
    /// The content box: 20 inside the sheet's sides, 11.5 below its top.
    public static let boxSideInset = 20.0
    public static let boxTopInset = 11.5
    // §3 File list
    public static let fileListWidth = 198.0
    public static let fileListHeader = 27.0
    public static let fileRowHeight = 24.0
    public static let fileIconX = 31.5
    public static let fileNameX = 52.5
    public static let badgeSize = 12.0
    public static let badgeTrailing = 8.0
    public static let filterHeight = 21.0
    public static let filterBottom = 3.5
    public static let segmentHeight = 17.0
    // §4 Panes
    public static let jumpBarHeight = 36.0
    public static let footerHeight = 27.0
    public static let gutterWidth = 46.0
    public static let rulerWidth = 17.0
    public static let rulerMarkX = 2.0
    public static let rulerMarkWidth = 10.0
    /// The ruler's knob (§14.4, dark): 11 wide from 1 inside the strip,
    /// over the track, which runs 3 inside the pane's top and bottom.
    public static let rulerKnobX = 1.0
    public static let rulerKnobWidth = 11.0
    public static let rulerTrackInset = 3.0
    /// Line numbers end here, right-aligned, from the pane's left edge.
    public static let lineNumberRight = 27.0
    /// Column 0 of the code, from the pane's left edge.
    public static let codeX = 41.0
    /// The first line's top below the jump bar's rule.
    public static let firstLineTop = 8.0
    /// The current-line highlight: from +8 to the text's right edge −8.
    public static let currentLineInset = 8.0
    /// The editor's cell and line pitch (`editor-area.md` C.1).
    public static let cellWidth = 8.0
    public static let lineHeight = 18.0
    /// A wrapped line's continuation starts this many columns past the
    /// line's indentation, as in the editor.
    public static let wrapIndent = 4
    // §5 Tokens
    public static let tokenWidth = 38.5
    public static let tokenHeight = 14.0
    public static let tokenLeft = 3.5
    public static let chevronCircle = 11.0
    // §6 Shading: changed-word fills are the row less 1 at top and bottom.
    public static let wordInset = 1.0
    // §8 Footer
    public static let footerTextX = 9.5
    public static let stepperWidth = 60.0
    // §9, §14.1–§14.2 Buttons
    public static let buttonWidth = 84.0
    public static let buttonSpacing = 12.0
    /// Cancel's top below the box (§14.2, measured: 866 under 847).
    public static let buttonGap = 19.0
    /// 20 tall (§14.1: Cancel y 866–886).
    public static let buttonHeight = 20.0
    /// Rounded rectangles, not capsules (§14.2).
    public static let buttonCornerRadius = 6.0
    /// The sheet's bottom below the buttons (§14.1: 22).
    public static let bottomMargin = 22.0
    /// The content box ends this far above the window's bottom edge
    /// (§13.3: y 847 in the 880-point window); the button row below it then
    /// runs past the window, as the reference's does. Ycode's choice for
    /// other window heights (open question 1): the same distance.
    public static let boxBottomInset = 33.0

    // §1.2 The alert
    public static let alertWidth = 420.0
    /// 132 (`merge-sheet.md` §16.1, council row 195; it was 133).
    public static let alertHeight = 132.0
    public static let alertIcon = 55.0
    public static let alertIconOrigin = (x: 28.5, y: 22.0)
    public static let alertTextX = 106.0
    public static let alertTitleTop = 20.0
    public static let alertMessageTop = 59.5
    public static let alertButtonHeight = 20.0
    public static let alertCancelWidth = 58.0
    public static let alertMergeWidth = 79.0
    public static let alertButtonSpacing = 14.5
    public static let alertButtonTrailing = 20.5
    public static let alertButtonBottom = 18.0
    /// Ycode's choice: the branch pop-up Integrate ▸ Merge… adds.
    public static let alertChooserHeight = 30.0

    /// The sheet's frame in a window of `size` (origin top-left) whose
    /// toolbar ends at `toolbarBottom`: 24 from each side, the top at the
    /// toolbar's bottom, and tall enough that its content box ends 33 above
    /// the window's bottom (§13.3); the buttons and the sheet's bottom margin
    /// follow (§14.1: in the 880-point window the sheet ends at 908). The
    /// sheet is a window of its own, so the part below the parent's bottom
    /// edge is drawn over whatever lies below it; the parent is neither
    /// moved nor resized.
    public static func sheetFrame(window size: (width: Double, height: Double), toolbarBottom: Double) -> Rect {
        let boxBottom = size.height - boxBottomInset - toolbarBottom
        let h = max(240, boxBottom + buttonGap + buttonHeight + bottomMargin)
        return Rect(x: sheetInset, y: toolbarBottom, width: max(400, size.width - 2 * sheetInset), height: h)
    }

    /// The content box inside a sheet of `size` (sheet coordinates).
    public static func contentBox(sheet size: (width: Double, height: Double)) -> Rect {
        let bottom = size.height - bottomMargin - buttonHeight - buttonGap
        return Rect(x: boxSideInset, y: boxTopInset, width: size.width - 2 * boxSideInset, height: max(120, bottom - boxTopInset))
    }

    /// The alert's frame, centred in a window of `size`.
    public static func alertFrame(window size: (width: Double, height: Double), chooser: Bool = false) -> Rect {
        let h = alertHeight + (chooser ? alertChooserHeight : 0)
        // The top stays where the 133-point alert had it (§1.2: y 373 in the 880 window).
        return Rect(x: ((size.width - alertWidth) / 2).rounded(.down), y: ((size.height - h - 1) / 2).rounded(.down), width: alertWidth, height: h)
    }

    /// The columns inside a content box `width` wide (box coordinates;
    /// the box's 1-point border is outside them): the file list, a rule,
    /// the left pane, a rule, the gutter, a rule, the right pane (its
    /// text, then the ruler).
    public struct Columns: Equatable, Sendable {
        public var fileList: Range1
        public var left: Range1
        public var gutter: Range1
        public var right: Range1
        /// The right pane's text, without the ruler.
        public var rightText: Range1
        public var ruler: Range1
    }

    public static func columns(boxWidth: Double) -> Columns {
        let inner = boxWidth - 2
        let paneSpace = inner - fileListWidth - 1 - gutterWidth - 2 - rulerWidth
        let pane = (paneSpace / 2).rounded(.down)
        let fileList = Range1(1, fileListWidth)
        let left = Range1(fileList.end + 1, pane)
        let gutter = Range1(left.end + 1, gutterWidth)
        let rightStart = gutter.end + 1
        let right = Range1(rightStart, boxWidth - 1 - rightStart)
        let rightText = Range1(rightStart, right.length - rulerWidth)
        return Columns(fileList: fileList, left: left, gutter: gutter, right: right, rightText: rightText,
                       ruler: Range1(rightText.end, rulerWidth))
    }

    /// A ruler mark's top in a ruler `height` tall: its share of the track,
    /// which runs `rulerTrackInset` inside the ruler's top and bottom
    /// (§14.4: y 105–815 in the pane 102–818).
    public static func rulerMarkY(share: Double, height: Double) -> Double {
        (rulerTrackInset + share * max(0, height - 2 * rulerTrackInset)).rounded(.down)
    }

    /// The ruler's knob in a ruler `height` tall: the visible part of the
    /// content (`visibleTop`, `visibleHeight` of `contentHeight`) on the
    /// track; the whole track when everything is visible (§14.4).
    public static func rulerKnob(visibleTop: Double, visibleHeight: Double, contentHeight: Double, height: Double) -> (y: Double, height: Double) {
        let track = max(0, height - 2 * rulerTrackInset)
        guard contentHeight > visibleHeight, contentHeight > 0 else { return (rulerTrackInset, track) }
        let h = max(18, track * visibleHeight / contentHeight)
        let travel = max(0, contentHeight - visibleHeight)
        let y = rulerTrackInset + (track - h) * min(1, max(0, visibleTop / travel))
        return (y, h)
    }

    /// The number of cells a pane `width` wide shows before wrapping.
    public static func columnsOfText(paneWidth: Double) -> Int {
        max(8, Int(((paneWidth - codeX - currentLineInset) / cellWidth).rounded(.down)))
    }

    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
        public var maxX: Double { x + width }
        public var maxY: Double { y + height }
    }

    public struct Range1: Equatable, Sendable {
        public var start, length: Double
        public init(_ start: Double, _ length: Double) { self.start = start; self.length = length }
        public var end: Double { start + length }
    }
}

/// The sheet's colours (`merge-sheet.md` §1–§9, light, measured; §13, dark,
/// measured in council round 4).
public struct MergeSheetPalette: Equatable, Sendable {
    public var sheet: UInt32
    /// The sheet's 1-point rim (dark: a step lighter than its fill, §13.3;
    /// light: none, the sheet's own colour).
    public var sheetRim: UInt32
    /// The panes' background (§13.4: #262627 in dark; white in light).
    public var pane: UInt32
    /// The veil: black at this opacity (white becomes #CDCDCD).
    public var veilOpacity: Double
    public var boxBorder: UInt32
    public var columnRule: UInt32
    public var bandRule: UInt32
    public var footerRule: UInt32
    public var label: UInt32
    public var secondaryLabel: UInt32
    public var disabledLabel: UInt32
    public var accent: UInt32
    /// The view control's selected segment: its pill and its label (§3:
    /// #D1E7FF with the accent label in light; council round 9, row 219:
    /// #335273 with a white label in dark).
    /// The view control's selected segment: its pill and its label (§3:
    /// #D1E7FF with the accent label in light; council round 9, row 219:
    /// #335273 with a white label in dark).
    public var segmentPill: UInt32
    public var segmentLabel: UInt32 = 0x007AFF
    public var selection: UInt32
    public var badge: UInt32
    public var badgeLetter: UInt32
    public var filterFill: UInt32
    public var filterPlaceholder: UInt32
    public var lineNumber: UInt32
    public var currentLineNumber: UInt32
    public var currentLine: UInt32
    public var gutter: UInt32
    /// The 1-point rules on both sides of the gutter.
    public var gutterRule: UInt32
    public var gutterConflict: UInt32
    public var gutterClean: UInt32
    public var conflictRow: UInt32
    public var conflictWord: UInt32
    public var cleanRow: UInt32
    /// The current change's 1-point rules while the file list has the
    /// focus (#DA5559).
    public var selectedRule: UInt32
    /// The current change's rules while the panes have the focus (#FF656A;
    /// §15.2: they brighten with the click that moves the focus there, not
    /// with the choice).
    public var decidedRule: UInt32
    public var token: UInt32
    /// The unselected token's 0.5-point rim (§13.5; in light the token's
    /// own fill: no visible rim).
    public var tokenRim: UInt32
    public var selectedToken: UInt32
    public var selectedTokenRim: UInt32
    public var tokenInk: UInt32
    public var chevronCircle: UInt32
    public var selectedChevronCircle: UInt32
    public var rulerConflict: UInt32
    public var rulerClean: UInt32
    /// The ruler's knob (§14.4: #A2A2A2 in dark; nil: none, as the light
    /// capture of §4.4 showed none).
    public var rulerKnob: UInt32?
    /// The file list's selection while the panes have the focus (§14.3:
    /// #464546 in dark; Ycode's choice in light: AppKit's unemphasized grey).
    public var unfocusedSelection: UInt32
    /// A conflict badge on a row that is not the focused selection (§14.3:
    /// a red square #FF4245 with a white letter).
    public var rowBadge: UInt32
    public var rowBadgeLetter: UInt32
    public var button: UInt32
    public var buttonLabel: UInt32
    public var disabledButton: UInt32
    public var disabledButtonLabel: UInt32
    public var folder: UInt32

    public static let light = MergeSheetPalette(
        sheet: 0xFFFFFF, sheetRim: 0xFFFFFF, pane: 0xFFFFFF, veilOpacity: 0.196, boxBorder: 0xBFBFBF, columnRule: 0xD7D7D7,
        bandRule: 0xE5E5E5, footerRule: 0xE6E6E6,
        label: 0x262626, secondaryLabel: 0x7A7A7A, disabledLabel: 0xA0A0A0, accent: 0x007AFF, segmentPill: 0xD1E7FF,
        selection: 0x0064E1, badge: 0xFFFFFF, badgeLetter: 0xFF383C, filterFill: 0xF3F3F3, filterPlaceholder: 0x7A7A7A,
        lineNumber: 0xB7B2B4, currentLineNumber: 0x322529, currentLine: 0xEEEEED,
        gutter: 0xF5F5F4, gutterRule: 0xD7D7D7, gutterConflict: 0xF9D5D5, gutterClean: 0xD1E4F8,
        conflictRow: 0xFFDCDD, conflictWord: 0xFF9A9D, cleanRow: 0xD6EBFE, selectedRule: 0xDA5559, decidedRule: 0xFF656A,
        token: 0x575757, tokenRim: 0x575757, selectedToken: 0x6D2A2D, selectedTokenRim: 0xDA5559, tokenInk: 0xFFFFFF,
        chevronCircle: 0x6B6C6B, selectedChevronCircle: 0xFF6569, rulerConflict: 0xFDB9B5, rulerClean: 0xD4D4D4,
        rulerKnob: nil, unfocusedSelection: 0xDCDCDC, rowBadge: 0xFF4245, rowBadgeLetter: 0xFFFFFF,
        button: 0xEDEDED, buttonLabel: 0x252525, disabledButton: 0xF5F5F5, disabledButtonLabel: 0xB6B6B6, folder: 0x3A9AF5)

    /// The dark appearance (council round 4, `merge-sheet.md` §13.3–§13.5,
    /// measured): the sheet #1D1E1F with a #2D2E2F rim, panes #262627, the
    /// gutter #313131 between #484848 rules, the box's dark hairline,
    /// conflict and clean shading, word fills, the selected rules, tokens
    /// #575757 with a lighter rim, and the veil that takes the window to
    /// about 0.70 of its value; round 5 (§14.2–§14.4): the buttons, the
    /// ruler's knob and marks, the unfocused selection and the row badge.
    /// Roles the rounds did not measure keep Ycode's earlier choices.
    public static let dark = MergeSheetPalette(
        sheet: 0x1D1E1F, sheetRim: 0x2D2E2F, pane: 0x262627, veilOpacity: 0.30, boxBorder: 0x171718, columnRule: 0x383838,
        bandRule: 0x333333, footerRule: 0x333333,
        label: 0xE6E6E6, secondaryLabel: 0x8C8C8C, disabledLabel: 0x6A6A6A, accent: 0x0A84FF,
        segmentPill: 0x335273, segmentLabel: 0xFFFFFF,
        selection: 0x0059CF, badge: 0xFFFFFF, badgeLetter: 0xFF453A, filterFill: 0x2B2B2B, filterPlaceholder: 0x8C8C8C,
        lineNumber: 0x6E6A6C, currentLineNumber: 0xE2DADD, currentLine: 0x2A2A2A,
        gutter: 0x313131, gutterRule: 0x484848, gutterConflict: 0x613D3F, gutterClean: 0x394C61,
        conflictRow: 0x583436, conflictWord: 0x9B3A3C, cleanRow: 0x2F4457, selectedRule: 0xDA5559, decidedRule: 0xFF656A,
        token: 0x575757, tokenRim: 0x6A6A6A, selectedToken: 0x6D2A2D, selectedTokenRim: 0xDA5559, tokenInk: 0xFFFFFF,
        chevronCircle: 0x6B6C6B, selectedChevronCircle: 0xFF6569, rulerConflict: 0xFDB9B5, rulerClean: 0xD4D4D4,
        rulerKnob: 0xA2A2A2, unfocusedSelection: 0x464546, rowBadge: 0xFF4245, rowBadgeLetter: 0xFFFFFF,
        button: 0x2E2F30, buttonLabel: 0xDFDFDF, disabledButton: 0x252627, disabledButtonLabel: 0x5B5C5C, folder: 0x3A9AF5)

    public static func forDark(_ dark: Bool) -> MergeSheetPalette { dark ? .dark : .light }

    /// A file row's colours (§3, §14.3): the selected row is accent-filled
    /// with white text and a white badge holding a red letter while the
    /// file list has the focus; once the panes have it (a click in either
    /// pane, the gutter or a token), the selection turns grey and the badge
    /// red with a white letter, as on any other row.
    public struct FileRowColors: Equatable, Sendable {
        public var fill: UInt32?
        /// White on the focused selection; nil: the label colour.
        public var ink: UInt32?
        public var badge: UInt32
        public var badgeLetter: UInt32
    }

    public func fileRow(selected: Bool, listFocused: Bool) -> FileRowColors {
        if selected && listFocused { return FileRowColors(fill: selection, ink: 0xFFFFFF, badge: badge, badgeLetter: badgeLetter) }
        return FileRowColors(fill: selected ? unfocusedSelection : nil, ink: nil, badge: rowBadge, badgeLetter: rowBadgeLetter)
    }

    /// The current change's rules (§15.2, checklist row 147): #FF656A
    /// whenever the panes have the focus, #DA5559 when the file list has
    /// it; a choice changes only the text.
    public func changeRule(panesFocused: Bool) -> UInt32 { panesFocused ? decidedRule : selectedRule }

    /// A colour's red, green and blue in 0…1.
    public static func components(_ hex: UInt32) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }
}

/// The window behind the merge alert and sheet (`merge-sheet.md` §13.1):
/// before the veil, its text is drawn at about 0.63 of its value and its
/// toolbar glyphs at about 0.33.
public enum MergeModalTone {
    public static let text = 0.63
    /// What the dimmed window is drawn over: the window's own background
    /// (macOS draws the faded content over it; the Linux window must not
    /// show black through, cross-platform-parity.md §12).
    public static func backdrop(dark: Bool) -> UInt32 { dark ? 0x1E1E1E : 0xECECEC }
    public static let glyph = 0.33
}

/// The alert's and the sheet's motion (`merge-sheet.md` §1.2, §7, §10).
public enum MergeSheetMotion {
    /// The veil behind the alert darkens over this long, ease-out.
    public static let veilIn = 0.255
    /// The alert is fully drawn within two frames.
    public static let alertIn = 0.017
    /// Clicking Merge: the alert fades out over this long.
    public static let alertOut = 0.09
    /// The sheet's fade in (and, with Reduce Motion, its only motion).
    public static let sheetFade = 0.09
    /// The sheet's slide down from under the toolbar.
    public static let sheetSlide = 0.2
    public static let slideDistance = 32.0
    /// The slide's timing curve (cubic Bézier control points): nearly
    /// linear with a soft ease-out, fitted to §10's keyframes (within 2.5
    /// points at every measured frame).
    public static let slideCurve = (x1: 0.4, y1: 0.3, x2: 0.6, y2: 1.0)
    /// Ycode's choice (open question 3): closing reverses the opening.
    public static let sheetOutFade = 0.09
    public static let sheetOutSlide = 0.2
    /// The Choose menu's dismissal in the reference (§7); Ycode's menus
    /// close as the platform closes them and the pane changes in the next
    /// frame.
    public static let chooseDismissal = 0.33

    /// The sheet's opacity `t` seconds into its appearance.
    public static func sheetOpacity(at t: Double) -> Double {
        min(1, max(0, t / sheetFade))
    }

    /// The sheet's vertical offset from its resting place (negative: above
    /// it) `t` seconds into its appearance; 0 with Reduce Motion.
    public static func sheetOffset(at t: Double, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 0 }
        let p = bezier(min(1, max(0, t / sheetSlide)), slideCurve)
        return -slideDistance * (1 - p)
    }

    /// The veil's share of its full darkness `t` seconds into the alert.
    public static func veilProgress(at t: Double) -> Double {
        let p = min(1, max(0, t / veilIn))
        return 1 - (1 - p) * (1 - p) * (1 - p)
    }

    /// A CSS-style cubic Bézier timing curve's progress at time share `x`.
    public static func bezier(_ x: Double, _ c: (x1: Double, y1: Double, x2: Double, y2: Double)) -> Double {
        func coord(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if coord(t, c.x1, c.x2) < x { lo = t } else { hi = t }
        }
        return coord(t, c.y1, c.y2)
    }
}

/// Texts of the merge workflow (`merge-sheet.md` §1.2, §7, §9).
public enum MergeSheetText {
    static func q(_ s: String) -> String { "\u{201C}\(s)\u{201D}" }

    public static func alertTitle(branch: String) -> String { "Are you sure you want to merge from \(q(branch))?" }
    public static func alertMessage(branch: String, current: String) -> String {
        "Changes from \(q(branch)) will be merged into your current branch (\(q(current)))."
    }
    public static let cancel = "Cancel"
    public static let merge = "Merge"
    public static let hierarchical = "Hierarchical"
    public static let flat = "Flat"
    public static let filter = "Filter"
    public static let noSelection = "No Selection"
    public static let noEditor = "No Editor"
    public static let loading = "Loading\u{2026}"

    /// The Choose menu: four items, a separator after the second.
    public static let chooseTitles = ["Choose Left", "Choose Right", "Choose Left Then Right", "Choose Right Then Left"]
    public static let chooseChoices: [MergeDocument.Choice] = [.ours, .theirs, .oursThenTheirs, .theirsThenOurs]
    public static let chooseSeparatorAfter = 1

    /// Ycode's choice (open question 3): Cancel's question while an
    /// operation is stopped.
    public static func cancelTitle(verb: String) -> String { "Abort the \(verb.isEmpty ? "operation" : verb.lowercased())?" }
    public static func cancelMessage(verb: String) -> String {
        let v = verb.isEmpty ? "operation" : verb.lowercased()
        return "The changes chosen in this sheet are discarded and the branch returns to where it was before the \(v)."
    }
}

/// One changed stretch's token in the centre gutter (§5).
public enum MergeSheetToken {
    /// The down-chevron: about 6 wide and 3.5 tall, drawn with a thin
    /// stroke (§5; round 4 §13.5: light and thin).
    public static let chevronHalfWidth = 3.0
    public static let chevronHeight = 3.5
    public static let chevronLineWidth = 1.0
    /// The rims: 0.5 point on an unselected token, 1 on the selected one.
    public static let rimWidth = 0.5
    public static let selectedRimWidth = 1.0

    /// The glyph: "?" for an undecided conflict, else a digit for the
    /// choice in effect. Ycode's choice (open question 4), keeping the
    /// two digits seen: Choose Right "1", a change taken automatically "3";
    /// Choose Left "2", Left Then Right "4", Right Then Left "5", the
    /// ancestor "6", written by hand "7".
    public static func glyph(choice: MergeDocument.Choice, kind: ThreeWayMerge.Chunk.Kind) -> String {
        if kind != .conflict, choice == MergeDocument.defaultChoice(kind) { return "3" }
        switch choice {
        case .unresolved: return "?"
        case .theirs: return "1"
        case .ours: return "2"
        case .oursThenTheirs: return "4"
        case .theirsThenOurs: return "5"
        case .base: return "6"
        case .custom: return "7"
        }
    }
}

/// One aligned row of the two panes (§4.3): the left pane is the current
/// branch's version with every choice applied, the right the incoming
/// version. A change shorter on one side is padded with empty rows there
/// (Ycode's choice, open question 5), so corresponding lines share a y.
public struct MergeSheetRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case same, conflict, clean }
    public struct Side: Equatable, Sendable {
        /// 1-based line number in that pane's text.
        public var number: Int
        /// Tabs expanded to four columns.
        public var text: String
        /// Changed words, as cell ranges of `text`.
        public var words: [Range<Int>]
    }
    public var left: Side?
    public var right: Side?
    public var kind: Kind
    /// The change (index into the document's hunks) the row belongs to.
    public var hunk: Int?
    public var isFirstOfHunk: Bool
    public var isLastOfHunk: Bool
    /// The empty line after a text's final line break (`editor-area.md`
    /// I.3, council row 178): numbered like any other, nothing on it.
    public var isFinalEmptyLine = false
}

public enum MergeSheetLayout {
    /// The aligned rows of a document.
    public static func rows(_ doc: MergeDocument) -> [MergeSheetRow] {
        var out: [MergeSheetRow] = []
        var l = 0, r = 0, h = 0
        for (i, c) in doc.chunks.enumerated() {
            if h < doc.hunks.count, doc.hunks[h] == i {
                let left = doc.choices[h] == .unresolved ? c.ours : doc.lines(forHunk: h)
                let right = c.theirs
                let kind: MergeSheetRow.Kind = c.kind == .conflict ? .conflict : .clean
                // Changed words of a conflict, line against line of the
                // original sides; the left fills stay at those cells after
                // a choice (§7, open question 6: as captured).
                var lw: [[Range<Int>]] = [], rw: [[Range<Int>]] = []
                if kind == .conflict {
                    for k in 0..<max(c.ours.count, c.theirs.count) {
                        let a = k < c.ours.count ? expandTabs(c.ours[k]) : nil, b = k < c.theirs.count ? expandTabs(c.theirs[k]) : nil
                        let w = changedWords(a ?? "", b ?? "")
                        lw.append(a == nil ? [] : w.left)
                        rw.append(b == nil ? [] : w.right)
                    }
                }
                let n = max(1, left.count, right.count)
                for k in 0..<n {
                    var row = MergeSheetRow(left: nil, right: nil, kind: kind, hunk: h, isFirstOfHunk: k == 0, isLastOfHunk: k == n - 1)
                    if k < left.count {
                        l += 1
                        let t = expandTabs(left[k])
                        row.left = .init(number: l, text: t, words: k < lw.count ? lw[k].filter { $0.upperBound <= t.count } : [])
                    }
                    if k < right.count {
                        r += 1
                        row.right = .init(number: r, text: expandTabs(right[k]), words: k < rw.count ? rw[k] : [])
                    }
                    out.append(row)
                }
                h += 1
            } else {
                for line in c.ours {
                    l += 1; r += 1
                    let t = expandTabs(line)
                    out.append(MergeSheetRow(left: .init(number: l, text: t, words: []), right: .init(number: r, text: t, words: []),
                                             kind: .same, hunk: nil, isFirstOfHunk: false, isLastOfHunk: false))
                }
            }
        }
        // A text that ends with a line break has one more line, empty
        // (I.3: the reference numbers 19 in both panes for 18 lines and a
        // final break).
        if doc.oursEndsWithNewline || doc.theirsEndsWithNewline, l > 0 || r > 0 {
            out.append(MergeSheetRow(left: doc.oursEndsWithNewline ? .init(number: l + 1, text: "", words: []) : nil,
                                     right: doc.theirsEndsWithNewline ? .init(number: r + 1, text: "", words: []) : nil,
                                     kind: .same, hunk: nil, isFirstOfHunk: false, isLastOfHunk: false, isFinalEmptyLine: true))
        }
        return out
    }

    /// The left pane's whole text (every choice applied, an undecided
    /// conflict showing the current branch's lines): what is highlighted.
    public static func leftText(_ doc: MergeDocument) -> [String] {
        var lines: [String] = []
        var h = 0
        for (i, c) in doc.chunks.enumerated() {
            if h < doc.hunks.count, doc.hunks[h] == i {
                lines += doc.choices[h] == .unresolved ? c.ours : doc.lines(forHunk: h)
                h += 1
            } else {
                lines += c.ours
            }
        }
        return lines
    }

    /// Tabs to the next multiple of four columns (the editor's tab width).
    public static func expandTabs(_ s: String) -> String {
        guard s.contains("\t") else { return s }
        var out = ""
        var col = 0
        for ch in s {
            if ch == "\t" {
                let n = 4 - col % 4
                out += String(repeating: " ", count: n)
                col += n
            } else {
                out.append(ch)
                col += 1
            }
        }
        return out
    }

    /// The changed runs of `a` and `b` (§15.1, checklist row 146): each line
    /// is split into tokens (a run of word characters, a run of white space,
    /// or one other character, so every quote, comma and operator is a token
    /// of its own); the two token sequences are matched by a longest common
    /// subsequence; each maximal run of consecutive unmatched tokens is one
    /// fill, white space inside it included. Cell ranges of the line.
    public static func changedWords(_ a: String, _ b: String) -> (left: [Range<Int>], right: [Range<Int>]) {
        let ca = Array(a), cb = Array(b)
        let ta = tokens(ca), tb = tokens(cb)
        let sa = ta.map { String(ca[$0]) }, sb = tb.map { String(cb[$0]) }
        let n = sa.count, m = sb.count
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = sa[i] == sb[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var keepA = Set<Int>(), keepB = Set<Int>()
        var i = 0, j = 0
        while i < n, j < m {
            if sa[i] == sb[j] { keepA.insert(i); keepB.insert(j); i += 1; j += 1 }
            else if dp[i + 1][j] >= dp[i][j + 1] { i += 1 } else { j += 1 }
        }
        return (runs(ta, keeping: keepA), runs(tb, keeping: keepB))
    }

    /// The maximal runs of consecutive tokens not in `kept`, as cell ranges.
    static func runs(_ tokens: [Range<Int>], keeping kept: Set<Int>) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var open: Range<Int>?
        for (k, t) in tokens.enumerated() {
            if kept.contains(k) {
                if let o = open { out.append(o); open = nil }
            } else {
                open = open.map { $0.lowerBound..<t.upperBound } ?? t
            }
        }
        if let o = open { out.append(o) }
        return out
    }

    /// A line's tokens (§15.1): runs of word characters (letters, digits,
    /// underscore), runs of white space, and every other character alone.
    static func tokens(_ chars: [Character]) -> [Range<Int>] {
        enum Class { case word, space, other }
        func kind(_ c: Character) -> Class {
            if c == " " || c == "\t" { return .space }
            if c == "_" || c.isLetter || c.isNumber { return .word }
            return .other
        }
        var out: [Range<Int>] = []
        var k = 0
        while k < chars.count {
            let c = kind(chars[k])
            var e = k + 1
            if c != .other { while e < chars.count, kind(chars[e]) == c { e += 1 } }
            out.append(k..<e)
            k = e
        }
        return out
    }

    /// One visual line of a wrapped line: the cells it shows and the
    /// column it starts at (0, or the indentation plus four).
    public struct Segment: Equatable, Sendable {
        public var cells: Range<Int>
        public var column: Int
    }

    /// Wraps a line `columns` cells wide at the last space that fits (else
    /// mid-word); continuation lines start four columns past the line's
    /// indentation (`editor-area.md`).
    public static func wrap(_ text: String, columns: Int) -> [Segment] {
        let chars = Array(text)
        guard chars.count > columns, columns > 8 else { return [Segment(cells: 0..<chars.count, column: 0)] }
        let indent = min(chars.prefix { $0 == " " }.count + MergeSheetMetrics.wrapIndent, columns / 2)
        var out: [Segment] = []
        var start = 0, column = 0
        while start < chars.count {
            let width = columns - column
            if chars.count - start <= width { out.append(Segment(cells: start..<chars.count, column: column)); break }
            var end = start + width
            if let space = chars[(start + 1)..<end].lastIndex(of: " ") { end = space + 1 }
            out.append(Segment(cells: start..<end, column: column))
            start = end
            column = indent
        }
        return out
    }

    /// A row's height: the taller side's visual lines × 18.
    public static func height(_ row: MergeSheetRow, columns: Int) -> Double {
        let l = row.left.map { wrap($0.text, columns: columns).count } ?? 1
        let r = row.right.map { wrap($0.text, columns: columns).count } ?? 1
        return Double(max(1, l, r)) * MergeSheetMetrics.lineHeight
    }

    /// Syntax runs per line (tabs expanded): the highlighter's tokens in
    /// their colour roles, the gaps plain (nil role).
    public static func highlight(_ lines: [String], fileName: String) -> [[(text: String, role: SyntaxTokenKind.Role?)]] {
        let language = SyntaxLanguage(fileName: fileName)
        let text = lines.joined(separator: "\n")
        let doc = lines.count <= 20_000 && language != .plain ? SyntaxDocument(text: text, language: language) : nil
        let units = Array(text.utf16)
        var out: [[(text: String, role: SyntaxTokenKind.Role?)]] = []
        out.reserveCapacity(lines.count)
        var start = 0
        for (n, line) in lines.enumerated() {
            let end = start + line.utf16.count
            var runs: [(text: String, role: SyntaxTokenKind.Role?)] = []
            func add(_ a: Int, _ b: Int, _ role: SyntaxTokenKind.Role?) {
                guard b > a else { return }
                let s = String(decoding: units[a..<b], as: UTF16.self)
                if let last = runs.last, last.role == role { runs[runs.count - 1].text += s } else { runs.append((s, role)) }
            }
            var at = start
            if let doc, n < doc.lineCount {
                for t in doc.tokens(onLine: n).sorted(by: { $0.location < $1.location }) {
                    let a = max(t.location, at), b = min(t.end, end)
                    guard a < b else { continue }
                    add(at, a, nil)
                    add(a, b, t.kind.role == .identifier ? nil : t.kind.role)
                    at = b
                }
            }
            add(at, end, nil)
            // Tabs expanded across the runs.
            var col = 0
            out.append(runs.map { run in
                var s = ""
                for ch in run.text {
                    if ch == "\t" { let k = 4 - col % 4; s += String(repeating: " ", count: k); col += k } else { s.append(ch); col += 1 }
                }
                return (s, run.role)
            })
            start = end + 1
        }
        return out
    }
}

/// The workspace's project as the merge sheet's jump bar names it
/// (§13.7): its name and the folder its files are under.
public struct MergeSheetProject: Equatable, Sendable {
    public var name: String
    public var folder: String

    public init(name: String, folder: String) {
        self.name = name
        self.folder = folder
    }

    /// The project of a workspace: a project's or workspace's name and the
    /// folder holding it, a package's folder.
    public init(workspace: WorkspaceModel) {
        name = workspace.displayName
        folder = (workspace.kind == .package ? workspace.url : workspace.url.deletingLastPathComponent()).path
    }
}

/// A side's commit, as its footer shows it (§8): repository › branch ›
/// date, author, short hash and "(HEAD)" on the current side.
public struct MergeSheetFooter: Equatable, Sendable {
    public var repository: String
    public var branch: String
    public var date: Date?
    public var author: String
    public var shortHash: String
    public var isHead: Bool

    public init(repository: String, branch: String, date: Date?, author: String, shortHash: String, isHead: Bool) {
        self.repository = repository
        self.branch = branch
        self.date = date
        self.author = author
        self.shortHash = shortHash
        self.isHead = isHead
    }

    /// "1/3/26" (month/day/two-digit year).
    public var dateText: String {
        guard let date else { return "" }
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return "\(c.month ?? 0)/\(c.day ?? 0)/\(String(format: "%02d", (c.year ?? 0) % 100))"
    }

    /// The commit part: "1/3/26  Capture Test  1a2b3c4 (HEAD)".
    public var commitText: String {
        [dateText, author, shortHash + (isHead ? " (HEAD)" : "")].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    /// The footers of an operation's two sides. Both name the current
    /// branch (§13.7, as captured for a merge; Ycode's choice for a
    /// cherry-pick, revert or stash apply); the right footer's commit is the
    /// incoming one. A rebase replays onto another branch, so its right
    /// footer keeps the replayed branch's name.
    public static func read(_ repo: GitRepository, integration: GitRepository.IntegrationState, oursLabel: String,
                            theirsLabel: String) -> (left: MergeSheetFooter?, right: MergeSheetFooter?) {
        let name = repo.root.lastPathComponent
        func footer(_ rev: String, _ branch: String, head: Bool) -> MergeSheetFooter? {
            guard let c = repo.commit(rev) else { return nil }
            return MergeSheetFooter(repository: name, branch: branch, date: c.date, author: c.authorName, shortHash: c.shortHash, isHead: head)
        }
        let theirsRev: String = switch integration {
        case .merging: "MERGE_HEAD"
        case .rebasing: "REBASE_HEAD"
        case .cherryPicking(let c): c
        case .reverting(let c): c
        case .none: "stash@{0}"
        }
        let rightBranch: String = if case .rebasing = integration { theirsLabel } else { oursLabel }
        return (footer("HEAD", oursLabel, head: true), footer(theirsRev, rightBranch, head: false))
    }
}
