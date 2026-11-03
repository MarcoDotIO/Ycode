import Foundation
import YcodeSimFeatures

/// Debug ▸ View Debugging ▸ Appearance (`reference-ui-5.md` §2.10) on the
/// Ycode simulator: each item is a change of the running app's Environment
/// Overrides (`specs/ide/debug.md` §Environment Overrides). Ycode decision:
/// System Appearance removes the appearance and contrast overrides; Light
/// and Dark set the appearance and remove the contrast override; the High
/// Contrast items set the appearance and Increase Contrast.
public enum DebugAppearanceMenu {
    public static let titles = ["System Appearance", "Light", "Dark", "High Contrast Light", "High Contrast Dark"]
    /// The selector of each item, in `titles` order.
    public static let actions = ["debugAppearanceSystem:", "debugAppearanceLight:", "debugAppearanceDark:",
                                 "debugAppearanceHighContrastLight:", "debugAppearanceHighContrastDark:"]

    /// `overrides` with item `index` chosen.
    public static func apply(_ index: Int, to overrides: EnvironmentOverrides) -> EnvironmentOverrides {
        var o = overrides
        switch index {
        case 1, 3: o.values[.appearance] = "light"
        case 2, 4: o.values[.appearance] = "dark"
        default: o.values[.appearance] = nil
        }
        o.values[.increaseContrast] = index >= 3 ? "on" : nil
        return o
    }

    /// The item the overrides correspond to (the one shown checked).
    public static func checkedIndex(_ overrides: EnvironmentOverrides) -> Int {
        let contrast = overrides.values[.increaseContrast] == "on"
        switch overrides.values[.appearance] {
        case "light": return contrast ? 3 : 1
        case "dark": return contrast ? 4 : 2
        default: return 0
        }
    }
}
