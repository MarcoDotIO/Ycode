import AppKit
import YcodeIDECore

// The AppKit edge of the settings model in YcodeIDECore: appearances,
// fonts, colors and event modifier flags as AppKit types.

extension Preferences {
    /// The NSAppearance to apply (nil follows the system).
    public var nsAppearance: NSAppearance? {
        switch appearance { case .system: nil; case .light: NSAppearance(named: .aqua); case .dark: NSAppearance(named: .darkAqua) }
    }

    /// The action for a click on code with these modifier flags (nil: a
    /// plain click, or modifiers that are not a Click on Code row).
    public func codeClick(for flags: NSEvent.ModifierFlags) -> CodeClick? { codeClick(forModifiers: MenuCommand.Modifiers(flags)) }

    /// Where a navigator click with these modifier flags (and click count)
    /// opens: the focused pane, a new unpinned tab or the next pane.
    public func navigationTarget(modifiers: NSEvent.ModifierFlags, clickCount: Int = 1) -> NavigationTarget {
        navigationTarget(keys: MenuCommand.Modifiers(modifiers), clickCount: clickCount)
    }
}

extension MenuCommand.Modifiers {
    /// ⌘, ⇧, ⌥ and ⌃ of an event's modifier flags; other flags are dropped.
    public init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.control) { insert(.control) }
    }
}

extension EditorTheme.FontSpec {
    /// The font (an empty or unknown name: the monospaced system font).
    public var font: NSFont { NSFont.editorFont(self) }
}

extension EditorTheme {
    public var font: NSFont { fontSpec.font }

    public var consoleFont: NSFont { consoleFontSpec.font }

    /// A theme color entry as an sRGB NSColor (nil: empty, absent or not
    /// `#RRGGBB`).
    public static func color(_ hex: String?) -> NSColor? { themeColor(hex).map(NSColor.init(themeColor:)) }

    /// `#RRGGBB` of a color, converted to sRGB.
    public static func hex(_ c: NSColor) -> String {
        let s = c.usingColorSpace(.sRGB) ?? c
        return String(format: "#%02X%02X%02X", Int((s.redComponent * 255).rounded()), Int((s.greenComponent * 255).rounded()), Int((s.blueComponent * 255).rounded()))
    }
}

extension NSColor {
    /// An opaque sRGB color from a theme color.
    public convenience init(themeColor c: ThemeColor) {
        self.init(srgbRed: CGFloat(c.red) / 255, green: CGFloat(c.green) / 255, blue: CGFloat(c.blue) / 255, alpha: 1)
    }
}

extension NSFont {
    /// A theme font descriptor as a font: the named font, or the monospaced
    /// system font when the name is empty or unknown.
    static func editorFont(_ spec: EditorTheme.FontSpec) -> NSFont {
        let s = CGFloat(spec.size)
        return spec.name.isEmpty ? .monospacedSystemFont(ofSize: s, weight: .regular) : (NSFont(name: spec.name, size: s) ?? .monospacedSystemFont(ofSize: s, weight: .regular))
    }
}
