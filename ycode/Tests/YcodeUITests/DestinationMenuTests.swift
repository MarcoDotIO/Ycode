import Testing
import YcodeBuild
@testable import YcodeUI

@Suite struct DestinationMenuTests {
    func sim(_ n: String, _ p: String = "iOS", _ v: String = "26.0") -> Destination {
        Destination(name: n, specifier: "id=\(n)\(v)", platform: p, kind: .simulator, osVersion: v)
    }

    @Test func sectionsInOrderForAnIOSApp() {
        let phone = Destination(name: "Pocket", specifier: "id=dev", platform: "iOS", kind: .device, osVersion: "26.1")
        let m = DestinationMenuModel(current: sim("iPhone 17"), devices: [phone], simulators: [sim("iPhone 17"), sim("Watch X", "watchOS")],
                                     platforms: ["iOS"], designedForIPad: true)
        #expect(m.sections.map(\.title) == ["Recent", "Devices", "Simulators", "Build"])
        #expect(m.sections[1].destinations.map(\.name) == ["My Mac (Designed for iPad)", "Pocket"])
        #expect(m.sections[3].destinations.map(\.name) == ["Any iOS Device (arm64)", "Any iOS Simulator Device (arm64, x86_64)"])
        #expect(m.incompatible.map(\.name) == ["Watch X (mismatched platform)"])
    }

    @Test func macOnlyProductPutsSimulatorsUnderIncompatible() {
        let m = DestinationMenuModel(current: nil, devices: [], simulators: [sim("iPhone 17")], platforms: ["macOS"])
        #expect(m.sections.map(\.title) == ["Devices", "Build"])
        #expect(m.sections[0].destinations == [.myMac])
        #expect(m.incompatible.map(\.name) == ["iPhone 17 (mismatched platform)"])
    }

    /// reference-ui-5.md §11.4 item 1: runtime newest first; then iPhone,
    /// iPad, Apple Vision; each by name in localized standard order. Names
    /// are kept: the row shows the OS version.
    @Test func simulatorsByRuntimeThenFamilyThenName() {
        let sims = [sim("Apple Vision Pro", "visionOS", "26.0"), sim("iPad Air", "iOS", "26.1"), sim("iPhone 17 Pro", "iOS", "26.1"),
                    sim("iPhone Air", "iOS", "26.1"), sim("iPhone 17", "iOS", "26.1"), sim("iPhone 17e", "iOS", "26.1"),
                    sim("iPhone 17", "iOS", "26.0"), sim("iPhone 17 Pro Max", "iOS", "26.1")]
        #expect(DestinationMenuModel.orderedSimulators(sims).map { "\($0.name) \($0.osVersion!)" }
                == ["iPhone 17 26.1", "iPhone 17 Pro 26.1", "iPhone 17 Pro Max 26.1", "iPhone 17e 26.1", "iPhone Air 26.1", "iPad Air 26.1",
                    "iPhone 17 26.0", "Apple Vision Pro 26.0"])
    }

    /// §11.4 items 2–4: Vision rows of an iOS app, versions below the
    /// deployment target in Incompatible with their reason, "(<runtime>)"
    /// before the reason for a name on several runtimes.
    @Test func visionRowsAndIncompatibleReasons() {
        let sims = [sim("iPhone 17", "iOS", "26.1"), sim("iPhone 17", "iOS", "18.5"), sim("iPhone 16", "iOS", "18.5"),
                    sim("Apple Vision Pro", "visionOS", "26.0"), sim("Apple Watch X", "watchOS", "26.0")]
        let m = DestinationMenuModel(current: nil, devices: [], simulators: sims, platforms: ["iOS"], designedForIPad: true,
                                     deploymentTargets: ["iOS": "26.0"])
        #expect(m.rows("Simulators").map(DestinationMenuModel.submenuTitle)
                == ["iPhone 17 26.1", "Apple Vision Pro (Designed for iPad, 26.0) 26.0"])
        #expect(m.incompatible.map(DestinationMenuModel.submenuTitle)
                == ["Apple Watch X (mismatched platform) 26.0",
                    "iPhone 16 (OS version lower than deployment target) 18.5",
                    "iPhone 17 (18.5) (OS version lower than deployment target) 18.5"])
        #expect(m.rows("Devices").map(\.name) == ["My Mac (Designed for iPad)"])
        #expect(m.selectable.map(\.name).prefix(2) == ["My Mac (Designed for iPad)", "iPhone 17"])
        #expect(m.rows("Build").map(DestinationMenuModel.submenuTitle) == ["Any iOS Device (arm64)", "Any iOS Simulator Device (arm64, x86_64)"])
        // A Mac-only product: My Mac is fine, the rest mismatched.
        let mac = DestinationMenuModel(current: nil, devices: [], simulators: sims, platforms: ["macOS"])
        #expect(mac.incompatible.count == sims.count && mac.incompatible.allSatisfy { $0.name.hasSuffix("(mismatched platform)") })
    }

    @Test func filterMatchesNames() {
        let m = DestinationMenuModel(current: nil, devices: [], simulators: [sim("iPhone 17"), sim("iPad Air")], platforms: ["iOS"], filter: "ipad")
        #expect(m.sections.map(\.title) == ["Simulators"])
        #expect(m.sections[0].destinations.map(\.name) == ["iPad Air"])
    }

    @Test func platformsFromSettings() {
        #expect(DestinationMenuModel.platforms(supportedPlatforms: "iphoneos iphonesimulator", sdkroot: "macosx") == ["iOS"])
        #expect(DestinationMenuModel.platforms(supportedPlatforms: nil, sdkroot: "macosx") == ["macOS"])
    }
}
