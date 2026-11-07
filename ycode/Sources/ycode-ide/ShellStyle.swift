import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// The workspace window's look, as the AppKit IDE draws it
// (`docs/PARITY.md` §5.10): its colors in light and dark appearance (read
// from that IDE's own windows: `LinuxParityProbeTests`), its fonts and the
// glass shapes as flat capsules (the material is approximated; pixel
// identity with the system's glass is a non-goal).

/// The chrome's colors for an appearance.
struct ShellColors {
    let dark: Bool
    /// Text and icons on the accent selection band: white.
    var onAccent = false

    init(_ scheme: ColorScheme) { dark = scheme == .dark }

    private func gray(_ light: Double, _ dark: Double) -> Color {
        let v = (self.dark ? dark : light) / 255
        return Color(.sRGB, red: v, green: v, blue: v)
    }

    /// The navigator and inspector areas: the sidebar material as the macOS
    /// IDE draws it, #F2F2F3 / #252627 (`cross-platform-parity.md` §3, §5;
    /// more pane colours in PaneStyle.swift).
    var sidebar: Color {
        dark ? Color(.sRGB, red: 37 / 255, green: 38 / 255, blue: 39 / 255) : Color(.sRGB, red: 242 / 255, green: 242 / 255, blue: 243 / 255)
    }
    /// The editor area and the toolbar band over it (the AppKit window's
    /// #FFFFFF / #262626, `cross-platform-parity.md` §2, §6).
    var content: Color { gray(255, 38) }
    /// Glass capsules' outlines.
    var capsuleStroke: Color { gray(225, 20) }
    /// A disabled toolbar glyph's opacity over its capsule.
    static let disabledGlyphOpacity = 0.6
    /// Glass capsules' fill (the AppKit toolbar's #ECECEC / #3A3A3A, §2).
    var capsuleFill: Color { gray(236, 58) }
    /// A toolbar segment that is on (Navigators, Canvas): the AppKit
    /// toolbar's pill, #D2D2D3 / #4D4E4F (`cross-platform-parity.md` §2).
    var segmentPill: Color { gray(210, 78) }
    /// The selected navigator's and inspector's pill.
    var selectorPill: Color { gray(226, 59) }
    /// Lines in the editor area (jump bar, debug bar, minimap).
    var separator: Color { gray(229, 57) }
    /// The navigator's and inspector's dividers.
    var sidebarDivider: Color { gray(227, 21) }
    var label: Color { onAccent ? .white : gray(23, 253) }
    var secondaryLabel: Color { onAccent ? .white : gray(128, 123) }
    var tertiaryLabel: Color { gray(170, 90) }
    var toolbarIcon: Color { gray(138, 126) }
    var chevron: Color { onAccent ? .white : gray(124, 152) }
    var popUpFill: Color { gray(232, 46) }
    var fieldStroke: Color { gray(213, 49) }
    var fieldFill: Color { gray(255, 22) }
    var rowSelection: Color { gray(220, 64) }
    var minimapText: Color { gray(189, 86) }
    var accent: Color {
        dark ? Color(.sRGB, red: 53 / 255, green: 116 / 255, blue: 233 / 255) : Color(.sRGB, red: 52 / 255, green: 120 / 255, blue: 246 / 255)
    }
    var error: Color { Color(.sRGB, red: 1, green: 59 / 255, blue: 48 / 255) }
    var warning: Color { Color(.sRGB, red: 1, green: 204 / 255, blue: 0) }
    var success: Color { Color(.sRGB, red: 52 / 255, green: 199 / 255, blue: 89 / 255) }

    func tint(_ t: OutlineRow.Tint) -> Color {
        if onAccent { return .white }
        return switch t {
        case .accent: accent
        case .secondary: secondaryLabel
        case .error: error
        case .warning: warning
        case .success: success
        case .icon(let t): icon(t)   // PaneStyle.swift
        }
    }
}

/// The fonts (`metrics.md`; the macOS system sizes).
enum ShellFonts {
    /// Outline rows: 13 points, regular (Inter's widths match the AppKit
    /// outline's at this size; its text looks a little heavier there, from
    /// font smoothing, but Inter Medium is wider and wraps rows the AppKit
    /// outline keeps on one line).
    static let row = Font.system(size: 13)
    static let rowBold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 11)
    static let smallBold = Font.system(size: 11, weight: .bold)
    static let mini = Font.system(size: 10)
    /// Letter spacing for text of 11 points and less: the desktop UI font
    /// the AppKit IDE uses spaces its small sizes wider than Inter does
    /// (measured on the paired windows: 11-point labels 7 % wider); none
    /// with Apple's SwiftUI, whose system font has it built in.
    /// Since OpenViews tracks Inter itself (`ShellLook.apply`, OV-4), none.
    static let smallTracking: CGFloat = 0
    static let activityName = Font.system(size: 13, weight: .bold)
    static let toolbarTitle = Font.system(size: 13, weight: .semibold)
    /// The scheme capsule's titles: 13 points regular, as the AppKit
    /// toolbar's pop-ups (`cross-platform-parity.md` §2).
    static let toolbarItem = Font.system(size: 13)
    static let symbol = Font.system(size: 15)
    static func editor(_ size: CGFloat) -> Font { .system(size: size, design: .monospaced) }
}

/// A flat stand-in for a glass capsule: a fill with a hairline rim. The
/// toolbar's capsules are filled as the AppKit toolbar's are
/// (`ShellColors.capsuleFill`, `cross-platform-parity.md` §2).
struct GlassCapsule: View {
    var height = CGFloat(WorkspaceChrome.toolbarItemHeight)
    /// The fill; nil for none (the rim alone).
    var fill: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Capsule(style: .continuous).fill(fill ?? Color.clear)
            .overlay { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
            .frame(height: height)
    }
}

/// A row of symbol buttons in one capsule (Run | Stop, Back | Forward, the
/// editor modes), with a pill under the segments that are on.
struct GlassSegments: View {
    struct Segment {
        var symbol: String
        var help: String
        var isOn = false
        var isEnabled = true
        var target: String
        var action: () -> Void
    }

    var segments: [Segment]
    var segmentWidth: CGFloat = 30
    var dividers = true
    var symbolSize: CGFloat = 15
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { pair in
                let s = pair.element
                if pair.offset > 0 && dividers {
                    Rectangle().fill(c.capsuleStroke).frame(width: 1, height: 18)
                }
                Button(action: s.action) {
                    ZStack {
                        if s.isOn { Capsule(style: .continuous).fill(c.segmentPill).frame(width: segmentWidth + 6, height: 28) }
                        Image(systemName: s.symbol)
                            .font(.system(size: symbolSize))
                            // The AppKit toolbar keeps a segment's glyph grey when
                            // it is on; a disabled glyph reads #606060 on the dark
                            // capsule, #ACACAC on the light one (parity §2).
                            .foregroundStyle(c.toolbarIcon)
                            .opacity(s.isEnabled ? 1 : ShellColors.disabledGlyphOpacity)
                    }
                    .frame(width: segmentWidth + 6, height: CGFloat(WorkspaceChrome.toolbarItemHeight))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!s.isEnabled)
                .help(s.help)
                .accessibilityLabel(s.help)
                .shellTarget(s.target)
            }
        }
        .padding(.horizontal, 4)
        .background { GlassCapsule(fill: c.capsuleFill) }
    }
}

/// A round glass button with one symbol (New Conversation, the inspector
/// toggle, the navigator's "+").
struct GlassCircleButton: View {
    var symbol: String
    var help: String
    var diameter = CGFloat(WorkspaceChrome.toolbarItemHeight)
    var isEnabled = true
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(c.toolbarIcon)
                .opacity(isEnabled ? 1 : ShellColors.disabledGlyphOpacity)
                .frame(width: diameter, height: diameter)
                .background { Circle().fill(c.capsuleFill).overlay { Circle().stroke(c.capsuleStroke, lineWidth: 1) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .shellTarget(target)
    }
}

/// A one-pixel line.
struct Hairline: View {
    var color: Color
    var vertical = false
    var body: some View {
        Rectangle().fill(color).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A small pop-up's look: its title and the up/down chevrons on a fill.
struct PopUpLook: View {
    var title: String
    var bold = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 4) {
            Text(verbatim: title).font(bold ? ShellFonts.smallBold : ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(c.label)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.popUpFill) }
    }
}
