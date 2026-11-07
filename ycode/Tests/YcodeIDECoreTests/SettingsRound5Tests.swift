import Foundation
import Testing
@testable import YcodeIDECore

/// The shared parts of council round 5 in Settings (`specs/ide/settings.md`
/// R5.1–R5.5) that both IDEs draw from, and the runtime wizard's host form
/// (`cross-platform-parity.md` §11). Runs on macOS and Linux.
@Suite struct SettingsRound5Tests {
    func defaults() -> (UserDefaults, String) {
        let name = "ycode-r5-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func appearanceGeometry() {
        let L = SettingsAppearanceLayout.self
        #expect(L.thumbnailXs == [463, 538, 613])
        #expect(L.thumbnailXs[2] + L.thumbnailSize.width == 680)
        // The ring's outer edge 4 outside the thumbnail (534 for Light).
        #expect(L.thumbnailXs[1] - L.ringGap - L.ringWidth == 534)
        #expect(L.segmentsSize == CGSize(width: 210, height: 28) && L.segmentTitles.count == 3)
        // Centred on the detail pane: x 340–550.
        let detail = SettingsLayout.detailX
        #expect(detail + (SettingsLayout.windowSize.width - detail - L.segmentsSize.width) / 2 == 340)
        // The slider ends 8 before the well, which ends 10 inside the card.
        #expect(L.sliderX + L.sliderWidth + 8 + L.wellSize.width + SettingsLayout.controlInset == SettingsLayout.cardWidth)
        #expect(L.previewTop + L.previewHeight + 12 == L.separator1Y)
        #expect(L.listTop == L.separator2Y + L.separator2Height)
        #expect(SettingsLayout.titleFontSize == 15 && SettingsTitleR5.selectedSidebarLabelIsSemibold)
        #expect(SettingsR5Palette.ring.light == 0x0088FF && SettingsR5Palette.captionSelected.light == 0x262626
            && SettingsR5Palette.lineNumber.light == 0xB8B3B4 && SettingsR5Palette.previewBorder.light == 0xE6E6E6)
    }

    @Test func colourRowsAndTint() {
        #expect(ThemeColorRows.all.first?.title == "Foreground" && ThemeColorRows.all.count == 12)
        var t = EditorTheme.builtIns[0]
        ThemeColorRows.set("keyword", "#123456", in: &t)
        ThemeColorRows.set("background", "#FFFFFF", in: &t)
        #expect(ThemeColorRows.value("keyword", in: t) == "#123456" && t.background == "#FFFFFF")
        #expect(ThemeColorRows.components("#3366CC").map { ThemeColorRows.hex($0.r, $0.g, $0.b) } == "#3366CC")
        #expect(ThemeColorRows.components("nope") == nil)
        let base = (r: 0.2, g: 0.4, b: 0.8), white = (r: 1.0, g: 1.0, b: 1.0)
        let full = ThemeColorRows.tint(base, over: white, strength: 1)
        #expect(ThemeColorRows.hex(full.r, full.g, full.b) == "#3366CC")
        let pale = ThemeColorRows.tint(base, over: white, strength: 0)
        #expect(abs(pale.r - (1 - 0.8 * ThemeColorRows.minimumStrength)) < 1e-9)
    }

    @Test func componentsRows() {
        let inv = ComponentsInventory(
            sdks: [.init(canonicalName: "macosx27.1", version: "27.1"), .init(canonicalName: "iphoneos27.1", version: "27.1")],
            runtimes: [SimRuntimeRecord(platform: .iOS, version: "27.0", build: "A", sizeBytes: 15_000_000_000),
                       SimRuntimeRecord(platform: .iOS, version: "27.1", build: "B", sizeBytes: 15_940_000_000, lastUsed: "2026-11-04T10:00:00Z"),
                       SimRuntimeRecord(platform: .visionOS, version: "27.0", build: "C", sizeBytes: 820_000_000, location: .host("sim-host"))])
        let now = ComponentsPage.date("2026-11-07T10:00:00Z")!
        let mac = ComponentsPage.platformRows(inv, isMac: true, now: now)
        #expect(mac.map(\.title) == ["macOS 27.1", "iOS 27.1", "watchOS", "tvOS", "visionOS 27.0"])
        #expect(mac.map(\.subtitle) == ["Built-in", "15.94 GB", "Not installed", "Not installed", "820 MB"])
        #expect(mac[1].lastUsed == "Last used 3 days ago" && mac[0].lastUsed == nil)
        #expect(mac[1].details.first == "iphoneos27.1 SDK" && mac[1].details.contains { $0.contains("27.1 (B)") && $0.contains("on this Mac") })
        #expect(mac[4].details.contains { $0.contains("on sim-host") })
        let linux = ComponentsPage.platformRows(ComponentsInventory(), isMac: false, now: now)
        #expect(linux.first?.title == "Linux" && linux.first?.subtitle == "Built-in" && linux.count == 5)
        let other = ComponentsPage.otherRows(predictiveEnabled: true, predictiveBackend: "Ollama", predictiveModel: "m", hostDestination: "")
        #expect(other.map(\.title) == ["Predictive Code Completion", "Simulator Host"] && other.last?.kind == .simulatorHost)
        #expect(other[0].subtitle == "Ollama, m" && other[1].subtitle == "Not set up")
        #expect(ComponentsPage.lastUsedText(now, now: now) == "Last used today")
        #expect(ComponentsPage.lastUsedText(now.addingTimeInterval(-86_400 * 20), now: now) == "Last used 2 weeks ago")
        #expect(ComponentsPage.versionLess("27.9", "27.10"))
        // Every symbol has parts inside its box.
        for g in ComponentGlyph.allCases {
            #expect(!g.parts.isEmpty && g.size.width <= 25 && g.size.height <= 19)
        }
    }

    @Test func hostPageReadsAndWritesBothModels() {
        let (d, name) = defaults()
        defer { d.removePersistentDomain(forName: name) }
        #expect(SimulatorHostPage.destination(d).isEmpty && SimulatorHostPage.subtitle(destination: "") == "Not set up")
        SimulatorHostPage.set(.host, " me@sim ", d)
        SimulatorHostPage.set(.dataFolder, "/data/y", d)
        SimulatorHostPage.set(.linkName, "thor", d)
        SimulatorHostPage.set(.ports, "47820/47821", d)
        SimulatorHostPage.set(.runtimeRoot, "/data/y/runtime", d)
        SimulatorHostPage.set(.otherRuntimeRoots, "/a, /b", d)
        SimulatorHostPage.set(.deviceName, "", d)
        let c = RuntimeSetupChoices.load(d).host, s = RemoteSimulatorSettings.load(d)
        #expect(c.destination == "me@sim" && s.destination == "me@sim" && c.dataDirectory == "/data/y" && s.dataDirectory == "/data/y")
        #expect(c.linkName == "thor" && c.tcpPort == 47820 && c.udpPort == 47821)
        #expect(s.runtimeRoot == "/data/y/runtime" && s.otherRuntimeRoots == ["/a", "/b"] && s.deviceName == "ycode-device")
        SimulatorHostPage.set(.ports, "bad", d)
        #expect(SimulatorHostPage.value(.ports, d) == "47820/47821")
        #expect(!SimulatorHostPage.isOn(.leanBoot, d) && SimulatorHostPage.isOn(.warmBoot, d))
        SimulatorHostPage.set(.leanBoot, true, d)
        #expect(RemoteSimulatorSettings.load(d).leanBoot)
        // The sections, in order; no camera (a per-device setting).
        #expect(SimulatorHostPage.Section.allCases.map(\.rawValue) == ["Host", "Runtimes", "Boot", "Advanced"])
        #expect(!SimulatorHostPage.Field.allCases.map(\.title).contains("Camera"))
        // The host's page is offered on both IDEs.
        #expect(SettingsPaneOrder.notOnLinux.isEmpty && SettingsPaneOrder.subPages["Simulators"] == "Components")
    }

    @Test func wizardHostForm() {
        #expect(RuntimeSetupLayout.fieldWidth == 320 && RuntimeSetupLayout.portsWidth == 120 && RuntimeSetupLayout.fieldHeight == 22)
        #expect(RuntimeSetupLayout.hostNote.contains("never asks for a password"))
    }
}
