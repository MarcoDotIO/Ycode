import AppKit
import YcodeIDECore
import YcodeSyntax

/// "Ycode Default" takes the colours measured for the council (the
/// owner's decision, `fidelity-council.md` row 10 for light, applied to
/// dark in round 4, rows 85 and 86): light from `editor-area.md` §C.4, dark
/// from F.3. Doc comments, preprocessor statements and attributes take the
/// values the Linux IDE draws them with (`WorkspaceChrome.defaultThemeColors`,
/// one table for both IDEs; dark doc comments in the Comments colour, as the
/// reference); the selection keeps its system colour; a property referenced
/// in an interpolation was measured in dark only, so light draws it as
/// plain text.
@MainActor
enum DefaultTheme {
    /// Whether the selected theme is the built-in default (no colours of
    /// its own).
    static var applies: Bool {
        let t = Theme.current
        return t.name == EditorTheme.builtIns[0].name && t.tokens.isEmpty && t.foreground == nil
    }

    /// One appearance's measured values.
    struct Palette {
        var roles: [SyntaxTokenKind.Role: String]
        var plain: String
        var lineNumber: String
        /// nil: the system's text background.
        var background: String?
        /// The current line's band in the focused pane and in a split's
        /// other pane; nil: Ycode's neutral band.
        var band: String?
        var unfocusedBand: String?
    }

    static let light = Palette(
        roles: [.keyword: "#C4246E", .comment: "#6A7084", .docComment: "#67C468", .string: "#CA2B1C", .number: "#0178B8",
                .preprocessor: "#FF9500", .attribute: "#A2845E", .typeName: "#9D31CF", .typeDeclaration: "#007D9E", .otherDeclaration: "#006178"],
        plain: "#322529", lineNumber: "#B8B3B4", background: nil, band: "#EEEEEE", unfocusedBand: "#EEEEEE")

    static let dark = Palette(
        roles: [.keyword: "#FF83B4", .comment: "#ABB3CD", .docComment: "#ABB3CD", .string: "#FF8E7B", .number: "#ECA900",
                .preprocessor: "#FF9F0A", .attribute: "#AC8E68", .typeName: "#D997FF", .typeDeclaration: "#00CAFB",
                .otherDeclaration: "#27A7C1", .propertyReference: "#20AD9D"],
        plain: "#FAF1F3", lineNumber: "#706D6E", background: "#262626", band: "#353535", unfocusedBand: "#2A2A2A")

    /// One instance per colour pair, so equal colours compare equal.
    private static var cache: [String: NSColor] = [:]

    /// `light` in the light appearance, `dark` in the dark one; a nil hex
    /// takes the fallback colour in that appearance.
    static func dynamic(light: String?, dark: String?, fallback: NSColor) -> NSColor {
        if light == nil, dark == nil { return fallback }
        // Keyed by the fallback's description (a system colour's name), not
        // its identity: system colours are fresh objects whose addresses
        // are reused.
        let key = (light ?? "-") + "|" + (dark ?? "-") + "|" + String(describing: fallback)
        if let c = cache[key] { return c }
        let l = light.flatMap(EditorTheme.color) ?? fallback
        let d = dark.flatMap(EditorTheme.color) ?? fallback
        let c = NSColor(name: NSColor.Name("ycode.default." + key)) { a in
            a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        }
        cache[key] = c
        return c
    }

    static var plain: NSColor { dynamic(light: light.plain, dark: dark.plain, fallback: .textColor) }
    static var lineNumber: NSColor { dynamic(light: light.lineNumber, dark: dark.lineNumber, fallback: .secondaryLabelColor) }
    static var background: NSColor { dynamic(light: light.background, dark: dark.background, fallback: .textBackgroundColor) }

    /// A role's colour; roles without a measured value in an appearance
    /// take `fallback` there.
    static func color(for role: SyntaxTokenKind.Role, fallback: NSColor) -> NSColor {
        dynamic(light: light.roles[role], dark: dark.roles[role], fallback: fallback)
    }

    /// The current-line band (`editor-area.md` §C.2, F.3): #EEEEEE on white
    /// in light; #353535 on #262626 in dark, #2A2A2A in a split's pane
    /// without focus. Light names its colour: the neutral band (a
    /// translucent label colour) returned from this dynamic colour's
    /// provider drew nothing, so the band vanished in light and after a
    /// switch to it (council round 8, row 197).
    static func band(focused: Bool, neutral: NSColor) -> NSColor {
        focused ? dynamic(light: light.band, dark: dark.band, fallback: neutral)
            : dynamic(light: light.unfocusedBand, dark: dark.unfocusedBand, fallback: neutral)
    }
}
