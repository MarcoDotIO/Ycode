import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The close, minimize and zoom buttons OpenViews draws for windows with a
// hidden title bar (B5-OPENVIEWS; `specs/ide/cross-platform-parity.md` §2
// and §15 OV-1). OpenViews' own drawing (circles and strokes), no artwork.
//
// Geometry (Ycode's macOS IDE window, its view dump: three 14 × 14 buttons at
// x 19, 42 and 65, y 19 in a window whose toolbar band is 52 tall; Settings
// the same): circles of 14 points, centres 23 apart from x 26, centred on
// half the title bar's height.
//
// Look (Ycode's rules, from the macOS IDE's drawing):
// - key window: close red, minimize yellow, zoom green, each with a
//   half-point rim a shade darker;
// - other windows, and buttons that are disabled: grey (#E7E8E9 with a
//   #C1C1C4 rim in light, #4A4A4B in dark, the macOS IDE's inactive drawing);
//   the pointer over the group shows the colours again;
// - the pointer over the group: every enabled button shows its glyph (a
//   cross, a bar, and the full-screen arrows; with Alt held, a plus: zoom
//   then maximises instead);
// - pressed: the fill darkened by a fifth.
// Actions: close asks the window to close (as the window system's own close
// does), minimize minimises, zoom toggles full screen (Alt: maximise and
// restore). While a sheet or alert is up, close is disabled and the other
// two stay usable (`merge-sheet.md` §13.1, rule 4).

/// The window buttons' geometry.
package enum WindowButtonMetrics {
    /// The title-bar band of a window with a toolbar (the macOS IDE's).
    package static let titleBarHeight: CGFloat = 52
    package static let diameter: CGFloat = 14
    /// Left edge of the close button.
    package static let leading: CGFloat = 19
    /// Centre-to-centre distance.
    package static let pitch: CGFloat = 23
    /// The region over which the glyphs show (the three buttons and the
    /// gaps, with a 4-point margin).
    package static func hoverRegion(titleBarHeight: CGFloat) -> CGRect {
        let top = titleBarHeight / 2 - diameter / 2
        return CGRect(x: leading - 4, y: top - 4, width: 2 * pitch + diameter + 8, height: diameter + 8)
    }

    /// The frame of button `index` (0 close, 1 minimize, 2 zoom) in window
    /// points, below `contentTop`.
    package static func frame(_ index: Int, titleBarHeight: CGFloat, contentTop: CGFloat = 0) -> CGRect {
        CGRect(x: leading + CGFloat(index) * pitch, y: contentTop + titleBarHeight / 2 - diameter / 2,
               width: diameter, height: diameter)
    }
}

/// The window buttons' colours.
package struct WindowButtonPalette {
    package struct Pair { package let fill: Color; package let rim: Color; package let glyph: Color }
    package let close: Pair, minimize: Pair, zoom: Pair, inactive: Pair

    package init(_ scheme: ColorScheme) {
        func c(_ hex: UInt32) -> Color {
            Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
        }
        close = Pair(fill: c(0xFF5F57), rim: c(0xE2463F), glyph: c(0x8C1A10))
        minimize = Pair(fill: c(0xFEBC2E), rim: c(0xE1A116), glyph: c(0x985712))
        zoom = Pair(fill: c(0x28C840), rim: c(0x12AC28), glyph: c(0x0B650D))
        inactive = scheme == .dark ? Pair(fill: c(0x4A4A4B), rim: c(0x4A4A4B), glyph: c(0x8E8E8F))
            : Pair(fill: c(0xE7E8E9), rim: c(0xC1C1C4), glyph: c(0x8E8E8F))
    }

    package func pair(_ index: Int) -> Pair { [close, minimize, zoom][min(max(index, 0), 2)] }
}

/// The three buttons, placed in the window (the window root's layer).
struct WindowButtonsLayer: View {
    let state: WindowChromeState
    /// The top of the content (below an in-window menu bar).
    let contentTop: CGFloat
    /// A sheet or alert is up: close is disabled.
    let modal: Bool
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let b = state.behaviors
        let enabled = [!modal && b.dismiss != .disabled, b.minimize != .disabled,
                       b.fullScreen != .disabled || b.resize != .disabled]
        let top = contentTop + state.titleBarHeight / 2 - WindowButtonMetrics.diameter / 2
        // Read here, not in the ForEach's closure, so that the body depends
        // on them.
        let isKey = activeState != .inactive
        let set = b.shownButtons
        let shown = [WindowButtonSet.close, .minimize, .zoom].map { set.contains($0) }
        HStack(spacing: WindowButtonMetrics.pitch - WindowButtonMetrics.diameter) {
            ForEach(0..<3, id: \.self) { i in
                if shown[i] {
                    WindowButton(index: i, state: state, isEnabled: enabled[i], isKey: isKey)
                } else {
                    Color.clear.frame(width: WindowButtonMetrics.diameter, height: WindowButtonMetrics.diameter)
                        .allowsHitTesting(false)
                }
            }
        }
        .padding(4)
        .contentShape(Rectangle())
        .onHover { h in if state.buttonsHovered != h { state.buttonsHovered = h } }
        .padding(.leading, WindowButtonMetrics.leading - 4)
        .padding(.top, top - 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
    }
}

/// One window button.
struct WindowButton: View {
    let index: Int
    let state: WindowChromeState
    let isEnabled: Bool
    let isKey: Bool
    @Environment(\.colorScheme) private var scheme

    private static let labels = ["Close", "Minimize", "Zoom"]
    private static let identifiers = ["_ov.window.close", "_ov.window.minimize", "_ov.window.zoom"]

    var body: some View {
        let palette = WindowButtonPalette(scheme)
        let hovered = state.buttonsHovered
        let coloured = isEnabled && (isKey || hovered)
        let pair = coloured ? palette.pair(index) : palette.inactive
        let pressed = state.pressedButton == index && isEnabled
        let d = WindowButtonMetrics.diameter
        ZStack {
            Circle().fill(pair.fill)
            if pressed { Circle().fill(Color.black.opacity(0.2)) }
            Circle().inset(by: 0.25).stroke(pair.rim, lineWidth: 0.5)
            if hovered && isEnabled {
                WindowButtonGlyph(index: index, plus: state.optionHeld)
                    .stroke(pair.glyph, style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
                if index == 2 && !state.optionHeld {
                    WindowButtonGlyph.fullScreenArrows().fill(pair.glyph)
                }
            }
        }
        .frame(width: d, height: d)
        .contentShape(Circle())
        .gesture(ControlPressGesture(onPressed: { p in
            guard isEnabled else { return }
            state.pressedButton = p ? index : nil
        }, onAction: { trigger() }))
        .accessibilityControl(.button, traits: .isButton, label: Self.labels[index],
                              actions: isEnabled ? ["default": { trigger() }] : [:])
        .accessibilityIdentifier(Self.identifiers[index])
    }

    private func trigger() {
        guard isEnabled else { return }
        state.pressedButton = nil
        switch index {
        case 0: state.close()
        case 1: state.minimize()
        default: state.zoom(state.optionHeld)
        }
    }
}

/// The glyphs: a cross (close), a bar (minimize), a plus (zoom with Alt).
/// The zoom button's full-screen arrows are filled (`fullScreenArrows`).
struct WindowButtonGlyph: Shape {
    let index: Int
    let plus: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        switch index {
        case 0:
            let r: CGFloat = 2.6
            p.move(to: CGPoint(x: c.x - r, y: c.y - r)); p.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
            p.move(to: CGPoint(x: c.x + r, y: c.y - r)); p.addLine(to: CGPoint(x: c.x - r, y: c.y + r))
        case 1:
            p.move(to: CGPoint(x: c.x - 3.6, y: c.y)); p.addLine(to: CGPoint(x: c.x + 3.6, y: c.y))
        default:
            if plus {
                p.move(to: CGPoint(x: c.x - 3.4, y: c.y)); p.addLine(to: CGPoint(x: c.x + 3.4, y: c.y))
                p.move(to: CGPoint(x: c.x, y: c.y - 3.4)); p.addLine(to: CGPoint(x: c.x, y: c.y + 3.4))
            }
        }
        return p
    }

    /// Two triangles pointing at opposite corners (full screen).
    static func fullScreenArrows() -> some Shape {
        FullScreenArrows()
    }
}

private struct FullScreenArrows: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let o = CGPoint(x: rect.minX, y: rect.minY), s = rect.width / 14
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * s, y: o.y + y * s) }
        p.move(to: pt(4.4, 4.4)); p.addLine(to: pt(8.3, 4.4)); p.addLine(to: pt(4.4, 8.3)); p.closeSubpath()
        p.move(to: pt(9.6, 9.6)); p.addLine(to: pt(5.7, 9.6)); p.addLine(to: pt(9.6, 5.7)); p.closeSubpath()
        return p
    }
}
