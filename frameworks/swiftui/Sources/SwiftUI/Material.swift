import Foundation
import OVRender
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Materials (B5-OPENVIEWS; public API names: `Material`,
// `ultraThinMaterial` … `ultraThickMaterial`, `bar`;
// `cross-platform-parity.md` §15 OV-2).
//
// The reference blends the desktop behind the window into its materials.
// Linux desktops offer no portable behind-window blur (on Wayland it needs a
// compositor-specific protocol, on X11 a compositing manager's own
// property), so OpenViews draws each material as the colour the macOS IDE's
// material shows over its neutral desktop (09-open-design.md §1: materials
// are approximated). The colours are Ycode's macOS IDE as the window server
// drew it (`CrossPlatformParityShotTests`, the B5-PARITY audit):
//
// | Material | Light | Dark | Where in the macOS IDE |
// |---|---|---|---|
// | `sidebar` (OpenViews) | #F2F2F3 | #252627 | navigator, inspector, Settings sidebar |
// | `bar` | #FFFFFF | #262626 | the toolbar band, jump bar |
// | `ultraThin` … `ultraThick` | white at 0.55 … 0.95 | #1E1E1E at 0.55 … 0.95 | (Ycode's steps) |
//
// `List` with `.listStyle(.sidebar)` draws on the sidebar material on a
// desktop.

/// A background material.
public struct Material: Sendable, Equatable, ShapeStyle, PaintableShapeStyle {
    enum Kind: Equatable, Sendable { case ultraThin, thin, regular, thick, ultraThick, bar, sidebar }
    let kind: Kind

    public static let ultraThin = Material(kind: .ultraThin)
    public static let thin = Material(kind: .thin)
    public static let regular = Material(kind: .regular)
    public static let thick = Material(kind: .thick)
    public static let ultraThick = Material(kind: .ultraThick)
    /// The material of tool bars and title bars.
    public static let bar = Material(kind: .bar)
    /// OpenViews: the macOS sidebar material (navigator and inspector
    /// columns). Not SwiftUI API (on macOS, `List`'s sidebar style draws it).
    public static let sidebar = Material(kind: .sidebar)

    /// The colour the material shows.
    package func color(_ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch kind {
        case .sidebar: return dark ? Color(ycodeHex: 0x252627) : Color(ycodeHex: 0xF2F2F3)
        case .bar: return dark ? Color(ycodeHex: 0x262626) : Color(ycodeHex: 0xFFFFFF)
        case .ultraThin: return dark ? Color(ycodeHex: 0x1E1E1E, opacity: 0.55) : Color(ycodeHex: 0xF6F6F6, opacity: 0.55)
        case .thin: return dark ? Color(ycodeHex: 0x1E1E1E, opacity: 0.68) : Color(ycodeHex: 0xF6F6F6, opacity: 0.68)
        case .regular: return dark ? Color(ycodeHex: 0x1E1E1E, opacity: 0.8) : Color(ycodeHex: 0xF6F6F6, opacity: 0.8)
        case .thick: return dark ? Color(ycodeHex: 0x1E1E1E, opacity: 0.9) : Color(ycodeHex: 0xF6F6F6, opacity: 0.9)
        case .ultraThick: return dark ? Color(ycodeHex: 0x1E1E1E, opacity: 0.95) : Color(ycodeHex: 0xF6F6F6, opacity: 0.95)
        }
    }

    package func _paint(bounds: CGRect, environment: EnvironmentValues) -> RenderPaint? {
        .color(color(environment.colorScheme).resolve(in: environment).renderColor)
    }
}

extension ShapeStyle where Self == Material {
    public static var ultraThinMaterial: Material { .ultraThin }
    public static var thinMaterial: Material { .thin }
    public static var regularMaterial: Material { .regular }
    public static var thickMaterial: Material { .thick }
    public static var ultraThickMaterial: Material { .ultraThick }
    public static var bar: Material { .bar }
    /// OpenViews: the macOS sidebar material. Not SwiftUI API.
    public static var sidebarMaterial: Material { .sidebar }
}
