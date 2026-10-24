import Foundation

/// The named colours and their resolved values per colour scheme
/// (07-text-images-color.md §4, measured with `Color.resolve(in:)` on the
/// reference runtime; sRGB hex, alpha last).
package enum SystemColor: String, Hashable, Sendable, CaseIterable {
    case primary, secondary, accentColor
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown
    case white, black, gray, clear

    /// (light, dark) in `#RRGGBBAA`.
    package var hex: (light: String, dark: String) {
        switch self {
        case .primary: return ("#000000FF", "#FFFFFFFF")
        case .secondary: return ("#3C3C4399", "#EBEBF599")
        case .accentColor: return ("#0088FFFF", "#0091FFFF")
        case .red: return ("#FF383CFF", "#FF4245FF")
        case .orange: return ("#FF8D28FF", "#FF9230FF")
        case .yellow: return ("#FFCC00FF", "#FFD600FF")
        case .green: return ("#34C759FF", "#30D158FF")
        case .mint: return ("#00C8B3FF", "#00DAC3FF")
        case .teal: return ("#00C3D0FF", "#00D2E0FF")
        case .cyan: return ("#00C0E8FF", "#3CD3FEFF")
        case .blue: return ("#0088FFFF", "#0091FFFF")
        case .indigo: return ("#6155F5FF", "#6D7CFFFF")
        case .purple: return ("#CB30E0FF", "#DB34F2FF")
        case .pink: return ("#FF2D55FF", "#FF375FFF")
        case .brown: return ("#AC7F5EFF", "#B78A66FF")
        // Plain components do not adapt to the colour scheme.
        case .white: return ("#FFFFFFFF", "#FFFFFFFF")
        case .black: return ("#000000FF", "#000000FF")
        case .gray: return ("#8E8E93FF", "#8E8E93FF")
        case .clear: return ("#00000000", "#00000000")
        }
    }

    /// Values under increased contrast, where the reference showed a change.
    /// Only `blue` and `accentColor` were measured to change (07 §4); every
    /// other colour keeps its standard value (an open question for the rest).
    package var increasedContrastHex: (light: String, dark: String)? {
        switch self {
        case .blue, .accentColor: return ("#1E6EF4FF", "#5CB8FFFF")
        default: return nil
        }
    }

    func resolve(scheme: ColorScheme, contrast: ColorSchemeContrast) -> Color.Resolved {
        let pair = (contrast == .increased ? increasedContrastHex : nil) ?? hex
        let s = scheme == .dark ? pair.dark : pair.light
        return Color.Resolved(hex: s)!
    }
}
