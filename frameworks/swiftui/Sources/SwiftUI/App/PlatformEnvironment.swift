import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Live environment from the platform (round R10; 08 §1, §1.1). The host puts
// the back end's `PlatformSettings` (OVPlatform/Settings.swift: environment
// variables, the settings file, the desktop portal, SDL's theme) into the
// root environment of the app and of every window, and applies them again
// when the back end reports `.settingsChanged`; views that read a changed
// key re-render, the others do not (03 §4, per-key dependencies).

@MainActor
package enum PlatformEnvironment {
    /// Right-to-left UI languages (the locale's language code).
    static let rightToLeftLanguages: Set<String> = ["ar", "arc", "ckb", "dv", "fa", "he", "iw", "ks", "ku", "ps", "sd", "ug",
                                                     "ur", "yi"]

    package static func layoutDirection(forLocale id: String) -> LayoutDirection {
        let lang = String(id.split(whereSeparator: { $0 == "_" || $0 == "-" }).first ?? "").lowercased()
        return rightToLeftLanguages.contains(lang) ? .rightToLeft : .leftToRight
    }

    package static func dynamicTypeSize(_ index: Int) -> DynamicTypeSize {
        let all = DynamicTypeSize.allCases
        return all[max(0, min(all.count - 1, index))]
    }

    /// Writes the settings into `env`.
    package static func apply(_ s: PlatformSettings, to env: inout EnvironmentValues) {
        set(&env, \.colorScheme, s.darkAppearance ? .dark : .light)
        set(&env, \.colorSchemeContrast, s.increasedContrast ? .increased : .standard)
        let size = dynamicTypeSize(s.contentSizeIndex)
        set(&env, \.dynamicTypeSize, size)
        // 06 §3: 52 points at the default size, 59 at accessibility2 and up
        // (the two measured values).
        set(&env, \.defaultMinListRowHeight, size >= .accessibility2 ? 59 : 52)
        set(&env, \.legibilityWeight, s.boldText ? .bold : .regular)
        set(&env, \.accessibilityReduceMotion, s.reduceMotion)
        set(&env, \.accessibilityReduceTransparency, s.reduceTransparency)
        set(&env, \.accessibilityDifferentiateWithoutColor, s.differentiateWithoutColor)
        set(&env, \.accessibilityInvertColors, s.invertColors)
        set(&env, \.accessibilityShowButtonShapes, s.showButtonShapes)
        set(&env, \._prefersOverlayScrollers, s.overlayScrollers)
        if env.locale.identifier != s.localeIdentifier {
            let locale = Locale(identifier: s.localeIdentifier)
            env.locale = locale
            env.calendar = locale.calendar
        }
        set(&env, \.layoutDirection, layoutDirection(forLocale: s.localeIdentifier))
        if let tz = s.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)), env.timeZone != tz { env.timeZone = tz }
    }

    /// Sets a key only when the value differs (an unchanged key keeps its
    /// readers clean).
    private static func set<V: Equatable>(_ env: inout EnvironmentValues, _ kp: WritableKeyPath<EnvironmentValues, V>, _ v: V) {
        if env[keyPath: kp] != v { env[keyPath: kp] = v }
    }
}
