import Foundation
import SwiftUI
import YcodeIDECore

// B5-STATES (P-198, #64): the Linux IDE's controls in the states of
// `specs/ui/control-states.md`, from the shared table (`ControlStates`,
// YcodeIDECore) so the macOS IDE draws the same values. OpenViews gives the
// desktop rules (no transparency while held, no focus rings without Full
// Keyboard Access, menus on mouse-down; ControlStates.swift there).

extension StateColor {
    /// The colour as an OpenViews/SwiftUI colour.
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

extension ControlStates {
    /// `kind`'s style in the view's appearance.
    static func style(_ kind: ControlKind, _ scheme: ColorScheme) -> ControlStateStyle { style(kind, dark: scheme == .dark) }
}

// MARK: - Triggers

/// A row that acts on mouse-down with no hover and no pressed look (the
/// Settings sidebar's rows: the selection moves at once, §4).
struct MouseDownRowStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StatefulButtonStyle(trigger: .mouseDown, tracksHover: false) { label, _ in label }.makeBody(configuration: configuration)
    }
}

// MARK: - Hover bezel

/// The Settings pop-up's hover bezel: over the whole control, one frame in
/// and out (dark #232326 → #343436, light #F6F6F6 → #E4E4E4). Disabled
/// controls have none.
struct HoverBezel: ViewModifier {
    let kind: ControlKind
    var radius: CGFloat = 6
    /// How far the bezel reaches before the content, and its height (nil:
    /// the content's).
    var lead: CGFloat = 0
    var height: CGFloat?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    func body(content: Content) -> some View {
        let s = ControlStates.style(kind, scheme)
        let state = s.resolve(hovered: hovered, pressed: false, enabled: isEnabled)
        content
            .background {
                if state == .hover, let fill = s.hoverFill {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill.color)
                        .frame(height: height)
                        .padding(.leading, -lead)
                }
            }
            .onHover { h in if hovered != h { hovered = h } }
    }
}

extension View {
    /// A hover bezel from the state table (`kind` must have hover).
    func hoverBezel(_ kind: ControlKind, radius: CGFloat = 6, lead: Double = 0, height: Double? = nil) -> some View {
        modifier(HoverBezel(kind: kind, radius: radius, lead: CGFloat(lead), height: height.map { CGFloat($0) }))
    }
}

// MARK: - Toolbar glass

/// A toolbar glass control's states (§2): under the pointer a bezel 28
/// tall in the hover fill, one frame in and out; held, the pressed fill and
/// the control grows 1–2 points a side (120 ms in, 200 ms back); disabled,
/// no hover and no press, the glyph at the table's disabled colour (drawn by
/// the control: this style does not dim). A disabled control takes no
/// pointer, so a press on it moves the window (§7).
struct ToolbarGlassStyle: PrimitiveButtonStyle {
    let kind: ControlKind
    /// The bezel's width (nil: the table's, else the control's).
    var bezelWidth: CGFloat?
    var circle = false

    func makeBody(configuration: Configuration) -> some View {
        StatefulButtonStyle { label, state in
            ToolbarGlassLook(kind: kind, bezelWidth: bezelWidth, circle: circle, state: state) { label }
        }.makeBody(configuration: configuration)
    }
}

struct ToolbarGlassLook<Content: View>: View {
    let kind: ControlKind
    var bezelWidth: CGFloat?
    var circle = false
    let state: ControlStateSnapshot
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = ControlStates.style(kind, scheme)
        let fill = state.isPressed ? s.pressedFill : state.isHovered ? s.hoverFill : nil
        let width = bezelWidth ?? s.hoverBezel.map { CGFloat($0.width) }
        content()
            .background {
                if let fill {
                    Group {
                        if circle { Circle().fill(fill.color) } else { Capsule(style: .continuous).fill(fill.color) }
                    }
                    .frame(width: circle ? nil : width, height: circle ? nil : CGFloat(ControlStates.toolbarBezelHeight))
                }
            }
            .scaleEffect(state.isPressed ? CGFloat(ControlStates.pressedScale(size: Double(WorkspaceChrome.toolbarItemHeight), grow: s.grow)) : 1)
            .animation(.easeOut(duration: state.isPressed ? ControlStates.pressIn : ControlStates.settle), value: state.isPressed)
    }
}

extension ControlStates {
    /// A toolbar glyph's colour: the table's disabled grey when disabled.
    static func toolbarGlyph(enabled: Bool, normal: Color, _ scheme: ColorScheme) -> Color {
        enabled ? normal : disabledToolbarGlyph(dark: scheme == .dark).color
    }
}

// MARK: - Glass tab bar lens

/// The inspector's (and the navigator selector's) glass lens (§3): no
/// hover; mouse-down raises a lens over the selected tab that glides to the
/// pressed one and follows the pointer along the bar while held, even off
/// it vertically; the selection changes on release, to the tab under the
/// lens. Releasing outside is not a cancel.
struct GlassTabLensModifier: ViewModifier {
    let bar: GlassTabLens.Bar
    let count: Int
    let selected: Int
    /// Space before the first tab inside the bar.
    var leading: CGFloat = 0
    let select: (Int) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var lens: GlassTabLens?
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let tabWidth = max(0, width - 2 * leading) / CGFloat(max(1, count))
        content
            .background { GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } } }
            .overlay(alignment: .leading) {
                if let lens, let t = lens.lensTab {
                    let size = lens.lensSize
                    Self.lensShape(bar: bar)
                        .fill(lens.tint(dark: scheme == .dark, held: true).color.opacity(0.55))
                        .overlay { Self.lensShape(bar: bar).stroke(Color.white.opacity(scheme == .dark ? 0.35 : 0.9), lineWidth: 1) }
                        .frame(width: size.width, height: size.height)
                        .offset(x: leading + (CGFloat(t) + 0.5) * tabWidth - size.width / 2)
                        .animation(.easeOut(duration: GlassTabLens.glide), value: t)
                        .allowsHitTesting(false)
                }
            }
            .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { v in
                    let tab = GlassTabLens.tab(atX: v.location.x, leading: leading, tabWidth: tabWidth, count: count)
                    if var l = lens {
                        l.drag(tab)
                        lens = l
                    } else {
                        var l = GlassTabLens(bar: bar, tabCount: count, selected: selected)
                        l.press(tab ?? selected)
                        lens = l
                    }
                }
                .onEnded { _ in
                    guard var l = lens else { return }
                    let chosen = l.release()
                    lens = nil
                    if let chosen { select(chosen) }
                })
    }

    static func lensShape(bar: GlassTabLens.Bar) -> AnyShape {
        bar == .navigator ? AnyShape(Circle()) : AnyShape(Capsule(style: .continuous))
    }
}

extension View {
    /// The glass lens over a tab bar of `count` equal tabs.
    func glassTabLens(_ bar: GlassTabLens.Bar, count: Int, selected: Int, leading: CGFloat = 0,
                      select: @escaping (Int) -> Void) -> some View {
        modifier(GlassTabLensModifier(bar: bar, count: count, selected: selected, leading: leading, select: select))
    }
}

#if !os(Linux)
// On macOS `ycode-ide` builds against Apple's SwiftUI (`ov-editor-bench`'s
// comparison build): a stand-in for OpenViews' `StatefulButtonStyle`.

enum ControlPressTrigger { case mouseUp, mouseDown }

struct ControlStateSnapshot {
    var isHovered = false
    var isPressed = false
    var isEnabled = true
    var showsFocus = false
}

struct StatefulButtonStyle: PrimitiveButtonStyle {
    let trigger: ControlPressTrigger
    let tracksHover: Bool
    let look: (PrimitiveButtonStyleConfiguration.Label, ControlStateSnapshot) -> AnyView

    init<V: View>(trigger: ControlPressTrigger = .mouseUp, tracksHover: Bool = true,
                  @ViewBuilder look: @escaping (PrimitiveButtonStyleConfiguration.Label, ControlStateSnapshot) -> V) {
        self.trigger = trigger
        self.tracksHover = tracksHover
        self.look = { AnyView(look($0, $1)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        StatefulBody(configuration: configuration, style: self)
    }

    struct StatefulBody: View {
        let configuration: Configuration
        let style: StatefulButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        @State private var pressed = false

        var body: some View {
            let s = ControlStateSnapshot(isHovered: style.tracksHover && isEnabled && hovered, isPressed: isEnabled && pressed, isEnabled: isEnabled)
            style.look(configuration.label, s)
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed {
                            pressed = true
                            if style.trigger == .mouseDown { configuration.trigger() }
                        }
                    }
                    .onEnded { _ in
                        pressed = false
                        if style.trigger == .mouseUp { configuration.trigger() }
                    })
        }
    }
}
#endif
