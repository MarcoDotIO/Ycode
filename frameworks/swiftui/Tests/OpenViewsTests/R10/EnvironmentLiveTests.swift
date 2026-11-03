import Foundation
import OVPlatform
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// T-ENV (10-plan.md §3.2): the 08 §1 defaults at the scene root and live
// updates when a platform setting changes (08 §1.1), on the headless host;
// the desktop settings sources (environment variables, settings file,
// portal text) of OVPlatform.

@MainActor
final class EnvReads {
    static let shared = EnvReads()
    var schemeBodies = 0
    var otherBodies = 0
    var scheme: ColorScheme?
    var size: DynamicTypeSize?
    var contrast: ColorSchemeContrast?
    var reduceMotion: Bool?
    var direction: LayoutDirection?
    var locale: String?
    var rowHeight: CGFloat?
    var env: EnvironmentValues?
}

struct SchemeReader: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        EnvReads.shared.schemeBodies += 1
        EnvReads.shared.scheme = scheme
        return Color.red.frame(width: 10, height: 10)
    }
}

struct OtherReader: View {
    @Environment(\.dynamicTypeSize) var size
    @Environment(\.colorSchemeContrast) var contrast
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.layoutDirection) var direction
    @Environment(\.locale) var locale
    @Environment(\.defaultMinListRowHeight) var rowHeight
    var body: some View {
        let r = EnvReads.shared
        r.otherBodies += 1
        r.size = size
        r.contrast = contrast
        r.reduceMotion = reduceMotion
        r.direction = direction
        r.locale = locale.identifier
        r.rowHeight = rowHeight
        return Text("Body text")
    }
}

struct EnvironmentProbe: View {
    @Environment(\.self) var env
    var body: some View {
        EnvReads.shared.env = env
        return Color.clear.frame(width: 1, height: 1)
    }
}

@MainActor
@Suite("R10 live environment (T-ENV)")
struct EnvironmentLiveTests {
    @Test func defaultsOfTheReferenceTable() {
        // 08 §1, the values a fresh environment and the headless host's root
        // (default platform settings) have.
        EnvReads.shared.env = nil
        let h = Harness { EnvironmentProbe() }
        _ = h
        for env in [EnvironmentValues(), EnvReads.shared.env].compactMap({ $0 }) {
            #expect(env.colorScheme == .light && env.colorSchemeContrast == .standard)
            #expect(env.dynamicTypeSize == .large && env.legibilityWeight == .regular)
            #expect(env.layoutDirection == .leftToRight && env.locale.identifier == "en_US")
            #expect(env.calendar.identifier == .gregorian)
            #expect(env.horizontalSizeClass == .compact && env.verticalSizeClass == .regular)
            #expect(!env.accessibilityReduceMotion && !env.accessibilityReduceTransparency
                && !env.accessibilityDifferentiateWithoutColor && !env.accessibilityInvertColors
                && !env.accessibilityShowButtonShapes && !env.accessibilityVoiceOverEnabled
                && !env.accessibilitySwitchControlEnabled && !env.accessibilityEnabled)
            #expect(env.isEnabled && env.lineLimit == nil && env.multilineTextAlignment == .leading)
            #expect(env.truncationMode == .tail && env.defaultMinListRowHeight == 52 && env.defaultMinListHeaderHeight == nil)
            #expect(env.controlSize == .regular && env.imageScale == .medium && env.redactionReasons.isEmpty)
            #expect(!env.isLuminanceReduced && !env.supportsMultipleWindows && !env.isSceneCaptured && env.font == nil)
        }
        #expect(EnvironmentValues().displayScale == 3)
    }

    @Test func liveChangesReachOnlyTheirReaders() {
        let r = EnvReads.shared
        r.schemeBodies = 0
        r.otherBodies = 0
        let h = Harness { VStack { SchemeReader(); OtherReader() } }
        #expect(r.scheme == .light && r.schemeBodies == 1 && r.otherBodies == 1)
        let textBefore = h.frame { ($0 as? Text)?.plainString == "Body text" }
        // Dark mode (08 §1.1 "appearance dark").
        h.backend.settings.darkAppearance = true
        h.run(until: 1)
        #expect(r.scheme == .dark && r.schemeBodies == 2)
        #expect(r.otherBodies == 1)
        // Content size accessibility-large (AX2): Dynamic Type and the list
        // row minimum follow (06 §3: 59).
        h.backend.settings.contentSizeIndex = 8
        h.run(until: 1.5)
        #expect(r.size == .accessibility2 && r.rowHeight == 59 && r.schemeBodies == 2)
        let textAfter = h.frame { ($0 as? Text)?.plainString == "Body text" }
        #expect((textAfter?.height ?? 0) > (textBefore?.height ?? 0) + 5)
        // Increased contrast, reduce motion.
        h.backend.settings.increasedContrast = true
        h.backend.settings.reduceMotion = true
        h.run(until: 2)
        #expect(r.contrast == .increased && r.reduceMotion == true)
        // An Arabic locale lays out right to left.
        h.backend.settings.localeIdentifier = "ar_SA"
        h.run(until: 2.5)
        #expect(r.direction == .rightToLeft && r.locale == "ar_SA")
        // Back to the defaults, one change at a time.
        h.backend.settings = PlatformSettings()
        h.run(until: 3)
        #expect(r.scheme == .light && r.size == .large && r.direction == .leftToRight && r.contrast == .standard)
    }

    @Test func adaptiveColoursFollowTheLiveScheme() {
        let h = Harness(presenter: true) { Color.primary.frame(width: 40, height: 40) }
        h.run(until: 0.6)
        let light = (h.window.platform as? HeadlessWindow)?.lastFrame
        h.backend.settings.darkAppearance = true
        h.run(until: 1)
        let dark = (h.window.platform as? HeadlessWindow)?.lastFrame
        #expect(light != nil && dark != nil)
        if let l = light, let d = dark {
            let a = l[200, 200], b = d[200, 200]
            #expect(a != b)
        }
    }

    @Test func settingsFileTextAndEnvironmentVariables() {
        var s = PlatformSettings()
        s.apply(fileText: """
        # OpenViews settings
        color-scheme = dark
        contrast = high
        reduce-motion = yes
        content-size = xxLarge
        locale = fr_FR   # French
        unknown = 1
        """)
        #expect(s.darkAppearance && s.increasedContrast && s.reduceMotion)
        #expect(s.contentSizeIndex == 5 && s.localeIdentifier == "fr_FR")
        s.apply(environment: ["OV_COLOR_SCHEME": "light", "OV_TEXT_SCALE": "1.25", "OV_BOLD_TEXT": "1"])
        #expect(!s.darkAppearance && s.contentSizeIndex == 5 && s.boldText)
        #expect(PlatformSettings.contentSizeIndex(forTextScale: 1.0) == 3)
        #expect(PlatformSettings.contentSizeIndex(forTextScale: 1.7) == 8)
        #expect(PlatformSettings.contentSizeIndex(forTextScale: 0.8) == 0)
        #expect(PlatformSettings.localeIdentifier(fromPOSIX: ["LANG": "de_DE.UTF-8"]) == "de_DE")
        #expect(PlatformSettings.localeIdentifier(fromPOSIX: ["LC_ALL": "C", "LANG": "de_DE.UTF-8"]) == nil)
        #expect(PlatformSettings.localeIdentifier(fromPOSIX: ["LC_MESSAGES": "sr_RS@latin"]) == "sr_RS")
    }

    @Test func portalReplyAndSignalText() {
        let reply = "({'org.freedesktop.appearance': {'color-scheme': <uint32 1>, 'accent-color': <(0.2, 0.4, 0.8)>, "
            + "'contrast': <uint32 0>}, 'org.gnome.desktop.interface': {'text-scaling-factor': <1.25>, "
            + "'enable-animations': <false>, 'gtk-theme': <'Adwaita'>}},)"
        let v = PortalSettings.parseReadAll(reply)
        #expect(v["org.freedesktop.appearance color-scheme"] == "1")
        #expect(v["org.freedesktop.appearance contrast"] == "0")
        #expect(v["org.gnome.desktop.interface text-scaling-factor"] == "1.25")
        #expect(v["org.gnome.desktop.interface enable-animations"] == "false")
        #expect(v["org.gnome.desktop.interface gtk-theme"] == nil)
        let line = "/org/freedesktop/portal/desktop: org.freedesktop.portal.Settings.SettingChanged "
            + "('org.freedesktop.appearance', 'color-scheme', <uint32 2>)"
        let s = PortalSettings.parseSignal(line)
        #expect(s?.0 == "org.freedesktop.appearance color-scheme" && s?.1 == "2")
    }

    @Test func settingsFileChangesAreSeenWithoutPolling() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ov-r10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.conf")
        let reader = DesktopSettingsReader(environment: ["OV_SETTINGS_FILE": file.path], usePortal: false)
        var seen: [PlatformSettings] = []
        reader.onChange = { seen.append($0) }
        #expect(reader.current == PlatformSettings())
        try "color-scheme = dark\ncontent-size = accessibility1\n".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<100 where seen.isEmpty { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(seen.last?.darkAppearance == true && seen.last?.contentSizeIndex == 7)
        #expect(reader.sources.contains("file"))
        try "color-scheme = light\n".write(to: file, atomically: true, encoding: .utf8)
        for _ in 0..<100 where seen.count < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(seen.last?.darkAppearance == false)
        reader.stop()
    }
}
