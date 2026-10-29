// ycode-simd --device: the lean boot profile (specs/simulator/lean-boot.md).
// Off by default. When on, the device boots with fewer background jobs
// (launchd's per-label disabled overrides in TMP/disabled.plist, the file
// `launchctl disable` writes; lean-boot.md §3) and, optionally, with the
// busiest log subsystems set to level off (the files `log config
// --subsystem S --mode level:off` writes; lean-boot.md §4). Plain Foundation.

import Foundation

struct LeanBootProfile: Equatable {
    /// Labels written as disabled (`true`) into TMP/disabled.plist.
    var disabledLabels: [String]
    /// Write level-off preferences for `loggingOffSubsystems`.
    var loggingOff: Bool

    var isEmpty: Bool { disabledLabels.isEmpty && !loggingOff }

    /// The background jobs the lean profile disables (lean-boot.md §3.2):
    /// on-demand jobs that are not on the path to the home screen, to app
    /// install or to app launch, and that cost the most guest work in a
    /// Ycode boot (measured) or start again and again.
    static let defaultDisabledLabels: [String] = [
        // Suggestions, search and Spotlight indexing.
        "com.apple.suggestd",
        "com.apple.parsecd",
        "com.apple.parsec-fbf",
        "com.apple.searchd",
        "com.apple.spotlightknowledged",
        "com.apple.spotlightknowledged.updater",
        // Accessibility asset downloads.
        "com.apple.accessibility.axassetsd",
        // Proactive, intelligence, Siri and media-analysis background work.
        "com.apple.proactiveeventtrackerd",
        "com.apple.mlhostd",
        "com.apple.intelligencetasksd",
        "com.apple.intelligenceplatformd",
        "com.apple.knowledgeconstructiond",
        "com.apple.textunderstandingd",
        "com.apple.siriactionsd",
        "com.apple.siriinferenced",
        "com.apple.siriknowledged",
        "com.apple.mediaanalysisd",
        "com.apple.photoanalysisd",
        "com.apple.sensorkitd",
        // Paired-watch companions: the launcher that enables them, and the
        // busiest one.
        "com.apple.nanoregistrylaunchd",
        "com.apple.pairedsyncd",
        // FaceTime message store, HomeKit.
        "com.apple.facetimemessagestored",
        "com.apple.homed",
    ]

    /// The log subsystems that `logging` turns off (lean-boot.md §4.3): the
    /// 40 subsystems with the most messages in a Mac simulator boot of the
    /// same runtime (`log show`, level 3), without `com.apple.runtime-issues`
    /// (Xcode's runtime-issue reports). Together 68 % of that boot's messages.
    static let loggingOffSubsystems: [String] = [
        "com.apple.containermanager", "com.apple.network", "com.apple.runningboard", "com.apple.xpc",
        "com.apple.Foundation", "com.apple.defaults", "com.apple.SpringBoard", "com.apple.launchservices",
        "com.apple.appinstallation", "com.apple.iconservices", "com.apple.securityd", "com.apple.CFNetwork",
        "com.apple.IDS", "com.apple.appintents", "com.apple.contacts", "com.apple.apsd",
        "com.apple.intelligenceplatform", "com.apple.chrono", "com.apple.migration", "com.apple.Biome",
        "com.apple.xpc.activity", "com.apple.locationd.Core", "com.apple.mobileassetd", "com.apple.coredata",
        "com.apple.StreamingExtractor", "com.apple.FrontBoard", "com.apple.MobileAsset", "com.apple.reminderkit.store",
        "com.apple.AppleMediaServices", "com.apple.UIKit", "com.apple.xpc.transaction", "com.apple.PlugInKit",
        "com.apple.TCC", "com.apple.contacts.contactsd", "com.apple.GeoServices", "com.apple.BackBoard",
        "com.apple.UnifiedAssetFramework", "com.apple.CoreRoutine", "com.apple.HomeKit", "com.apple.Accessibility",
    ]

    /// The subsystem preference `log config --subsystem S --mode level:off`
    /// writes (lean-boot.md §4.3; a binary plist on the Mac, any plist format
    /// reads the same).
    static var levelOffPreference: [String: Any] { ["DEFAULT-OPTIONS": ["Level": ["Enable": "off", "Persist": "off"]]] }

    /// The profile from the environment, or nil when it is off.
    ///
    /// - `YCODE_LEAN_BOOT`: unset, empty or `0` = off; `1` or `daemons` =
    ///   the disabled jobs; `logging` = os_log off only; `all` = both.
    /// - `YCODE_LEAN_BOOT_DISABLE=label,label`: more labels to disable.
    /// - `YCODE_LEAN_BOOT_KEEP=label,label`: labels taken off the list.
    static func from(environment env: [String: String]) -> LeanBootProfile? {
        let mode = (env["YCODE_LEAN_BOOT"] ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let daemons: Bool, logging: Bool
        switch mode {
        case "", "0", "off", "no": return nil
        case "1", "daemons", "on", "yes": (daemons, logging) = (true, false)
        case "logging": (daemons, logging) = (false, true)
        case "all": (daemons, logging) = (true, true)
        default: return nil
        }
        func list(_ key: String) -> [String] {
            (env[key] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let keep = Set(list("YCODE_LEAN_BOOT_KEEP"))
        var labels = daemons ? defaultDisabledLabels : []
        for extra in list("YCODE_LEAN_BOOT_DISABLE") where !labels.contains(extra) { labels.append(extra) }
        labels.removeAll { keep.contains($0) }
        let profile = LeanBootProfile(disabledLabels: labels, loggingOff: logging)
        return profile.isEmpty ? nil : profile
    }

    static var fromProcessEnvironment: LeanBootProfile? { from(environment: ProcessInfo.processInfo.environment) }

    /// The disabled-overrides dictionary for a boot: `existing` (an earlier
    /// TMP/disabled.plist, label → disabled) with the profile's labels added
    /// as disabled. An explicit `false` (enabled, e.g. after `launchctl
    /// enable`) is kept.
    func disabledOverrides(existing: [String: Bool] = [:]) -> [String: Bool] {
        var result = existing
        for label in disabledLabels where result[label] == nil { result[label] = true }
        return result
    }

    /// One line for the run log.
    var summary: String {
        var parts: [String] = []
        if !disabledLabels.isEmpty { parts.append("\(disabledLabels.count) jobs disabled") }
        if loggingOff { parts.append("\(Self.loggingOffSubsystems.count) log subsystems off") }
        return "lean boot: " + parts.joined(separator: ", ")
    }
}
