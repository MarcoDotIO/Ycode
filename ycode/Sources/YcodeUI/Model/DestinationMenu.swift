import Foundation
import YcodeBuild
import YcodeProject

/// The run destination menu's layout (`specs/ide/reference-ui-3.md` §4,
/// with the ordering, titles and Incompatible reasons of
/// `reference-ui-5.md` §11.4): a filter, then Recent, Devices, Simulators
/// and Build, then the Incompatible submenu and Manage Devices…. The
/// Product ▸ Destination submenu shows the same Devices, Simulators and
/// Build rows (§2.9 item 20).
public struct DestinationMenuModel: Equatable, Sendable {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var destinations: [Destination]
    }
    public var sections: [Section]
    /// Destinations the scheme cannot run on (the Incompatible ▸ submenu).
    /// Their names read "<name> [(<runtime>)] (<reason>)"; the OS version
    /// follows in the row.
    public var incompatible: [Destination]

    public static let manageDevicesTitle = "Manage Devices…"
    public static let incompatibleTitle = "Incompatible"
    public static let showAllTitle = "Show All Run Destinations"
    /// §11.4 item 4: why a destination is incompatible.
    public static let mismatchedPlatform = "mismatched platform"
    public static let osTooOld = "OS version lower than deployment target"

    /// - Parameters:
    ///   - platforms: the platforms the product supports; empty = all.
    ///   - designedForIPad: an iOS app, which also runs on the Mac and on
    ///     Apple Vision simulators ("Designed for iPad").
    ///   - deploymentTargets: the product's deployment target per platform;
    ///     destinations below it are incompatible (§11.4 item 3).
    public init(current: Destination?, devices: [Destination], simulators: [Destination],
                platforms: Set<String>, designedForIPad: Bool = false, deploymentTargets: [String: String] = [:], filter: String = "") {
        let ipadOnVision = designedForIPad && !platforms.contains("visionOS")
        func platformOK(_ d: Destination) -> Bool {
            platforms.isEmpty || platforms.contains(d.platform) || (ipadOnVision && d.platform == "visionOS")
        }
        func tooOld(_ d: Destination) -> Bool {
            guard let target = deploymentTargets[d.platform], !target.isEmpty, let v = d.osVersion else { return false }
            return DestinationCatalog.compareVersions(v, target) == .orderedAscending
        }
        func ok(_ d: Destination) -> Bool { platformOK(d) && !tooOld(d) }
        let f = filter.trimmingCharacters(in: .whitespaces)
        func match(_ d: Destination) -> Bool { f.isEmpty || d.name.localizedCaseInsensitiveContains(f) }
        var mac = Destination.myMac
        if designedForIPad && !platforms.contains("macOS") {
            mac.name = "My Mac (Designed for iPad)"
        }
        let macOK = platforms.isEmpty || platforms.contains("macOS") || designedForIPad
        let devs = devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let sims = Self.orderedSimulators(simulators)
        var build: [Destination] = []
        for p in ["macOS", "iOS", "watchOS", "tvOS", "visionOS"] where !platforms.isEmpty && platforms.contains(p) {
            if p == "macOS" { build.append(.anyMac); continue }
            build.append(Destination(name: "Any \(p) Device (arm64)", specifier: "generic/platform=\(p)", platform: p, kind: .generic))
            build.append(Destination(name: "Any \(p) Simulator Device (arm64, x86_64)",
                                     specifier: "generic/platform=\(p) Simulator", platform: p, kind: .generic))
        }
        // §11.4 item 2: Apple Vision rows of an iOS app.
        func titled(_ d: Destination) -> Destination {
            guard ipadOnVision, d.platform == "visionOS", d.kind == .simulator, let v = d.osVersion else { return d }
            var d = d
            d.name = "\(d.name) (Designed for iPad, \(v))"
            return d
        }
        var s: [Section] = []
        if let current, match(current) { s.append(Section(title: "Recent", destinations: [current])) }
        let devRows = ((macOK ? [mac] : []) + devs.filter(ok)).filter(match)
        if !devRows.isEmpty { s.append(Section(title: "Devices", destinations: devRows)) }
        let simRows = sims.filter(ok).map(titled).filter(match)
        if !simRows.isEmpty { s.append(Section(title: "Simulators", destinations: simRows)) }
        let buildRows = build.filter(match)
        if !buildRows.isEmpty { s.append(Section(title: "Build", destinations: buildRows)) }
        sections = s
        // §11.4 item 4: "<name> (<reason>)", with "(<runtime>)" first when
        // the name exists for several runtimes.
        let runtimes = Dictionary(grouping: simulators, by: \.name).mapValues { Set($0.compactMap(\.osVersion)).count }
        func incompatibleRow(_ d: Destination) -> Destination {
            var d = d
            let reason = platformOK(d) ? Self.osTooOld : Self.mismatchedPlatform
            let runtime = d.kind == .simulator && runtimes[d.name, default: 0] > 1 ? d.osVersion.map { " (\($0))" } ?? "" : ""
            d.name = "\(d.name)\(runtime) (\(reason))"
            return d
        }
        incompatible = ((macOK ? [] : [mac]) + devs.filter { !ok($0) } + sims.filter { !ok($0) }).filter(match).map(incompatibleRow)
    }

    /// The rows Product ▸ Destination lists under its "Devices",
    /// "Simulators" and "Build" labels (§2.9 item 20).
    public func rows(_ label: String) -> [Destination] {
        sections.first { $0.title == label }?.destinations ?? []
    }

    /// The selectable destinations in menu order, without Recent: what
    /// Select Next / Previous Destination steps through.
    public var selectable: [Destination] {
        sections.filter { $0.title != "Recent" }.flatMap(\.destinations)
    }

    /// A row's title in the Product ▸ Destination submenu: "<name> <OS
    /// version>" (§2.9 item 20).
    public static func submenuTitle(_ d: Destination) -> String {
        d.osVersion.map { "\(d.name) \($0)" } ?? d.name
    }

    /// Simulators in menu order (§11.4 item 1): runtime version, newest
    /// first; within a runtime iPhone, iPad, then Apple Vision; each group
    /// by name in localized standard order. Rows carry the OS version, so
    /// names are not changed. Ycode's remote simulator sorts by its
    /// runtime version; while that is unknown, with the newest runtime
    /// (§11.5).
    public static func orderedSimulators(_ sims: [Destination]) -> [Destination] {
        let newest = sims.compactMap(\.osVersion).max { DestinationCatalog.compareVersions($0, $1) == .orderedAscending }
        let unversioned = sims.indices.filter { sims[$0].isYcodeRemoteSimulator && sims[$0].osVersion == nil }
        guard !unversioned.isEmpty, let newest else { return DestinationCatalog.simulatorsInMenuOrder(sims) }
        // Sort them as the newest runtime, then show them without a version.
        var keyed = sims
        for i in unversioned { keyed[i].osVersion = newest }
        let unknown = Set(unversioned.compactMap { sims[$0].identifier })
        return DestinationCatalog.simulatorsInMenuOrder(keyed).map { d in
            guard d.isYcodeRemoteSimulator, let id = d.identifier, unknown.contains(id) else { return d }
            var o = d
            o.osVersion = nil
            return o
        }
    }

    /// The platforms a build setting set supports, from
    /// `SUPPORTED_PLATFORMS` (preferred) or `SDKROOT`.
    public static func platforms(supportedPlatforms: String?, sdkroot: String?) -> Set<String> {
        let names = ["macosx": "macOS", "iphoneos": "iOS", "iphonesimulator": "iOS", "watchos": "watchOS",
                     "watchsimulator": "watchOS", "appletvos": "tvOS", "appletvsimulator": "tvOS",
                     "xros": "visionOS", "xrsimulator": "visionOS"]
        let words = (supportedPlatforms ?? sdkroot ?? "").split(separator: " ").map(String.init)
        return Set(words.compactMap { names[$0] })
    }

    /// The first target's platforms (target settings over project ones),
    /// and whether it is an iOS app (which also runs "Designed for iPad").
    public static func platforms(of proj: PBXProj) -> (platforms: Set<String>, designedForIPad: Bool) {
        func value(_ listID: String?, _ key: String) -> String? {
            proj.buildConfigurations(listID: listID).lazy.compactMap { $0.attributes["buildSettings"]?.dictionary?[key]?.string }.first
        }
        let target = proj.targets.first
        let tl = target?.string("buildConfigurationList"), pl = proj.project?.string("buildConfigurationList")
        let p = platforms(supportedPlatforms: value(tl, "SUPPORTED_PLATFORMS") ?? value(pl, "SUPPORTED_PLATFORMS"),
                          sdkroot: value(tl, "SDKROOT") ?? value(pl, "SDKROOT"))
        let isApp = target?.string("productType") == "com.apple.product-type.application"
        return (p, isApp && p.contains("iOS"))
    }

    /// The first target's own platform and deployment target, for the
    /// default destination (`reference-ui-5.md` §4.3, T1). The platform is
    /// the one `SDKROOT` names; with no specific SDK (`auto`, unset) it is
    /// iOS when supported, else macOS when supported, else the first
    /// supported platform. Nil when nothing is known (the Mac is used).
    public static func productPlatform(of proj: PBXProj) -> (platform: String?, deploymentTarget: String?) {
        func value(_ listID: String?, _ key: String) -> String? {
            proj.buildConfigurations(listID: listID).lazy.compactMap { $0.attributes["buildSettings"]?.dictionary?[key]?.string }.first
        }
        let tl = proj.targets.first?.string("buildConfigurationList"), pl = proj.project?.string("buildConfigurationList")
        func setting(_ key: String) -> String? { value(tl, key) ?? value(pl, key) }
        let fromSDK = platforms(supportedPlatforms: nil, sdkroot: setting("SDKROOT")).first
        let supported = platforms(supportedPlatforms: setting("SUPPORTED_PLATFORMS"), sdkroot: nil)
        let platform = fromSDK ?? (supported.contains("iOS") ? "iOS" : supported.contains("macOS") ? "macOS"
            : ["watchOS", "tvOS", "visionOS"].first(where: supported.contains))
        let target = platform.flatMap(DestinationCatalog.deploymentTargetSetting).flatMap(setting)
        return (platform, target)
    }

    /// What the default destination needs to know of the first target
    /// beyond its platform (`reference-ui-6.md` §2.4.2–§2.4.3): whether it
    /// supports macOS (`SUPPORTED_PLATFORMS` includes `macosx`, or with no
    /// list `SDKROOT` is `macosx`: a multiplatform app defaults to My Mac),
    /// and the device families it targets (`TARGETED_DEVICE_FAMILY`; nil =
    /// no restriction).
    public static func defaultDestinationTraits(of proj: PBXProj) -> (supportsMacOS: Bool, deviceFamilies: Set<String>?) {
        func value(_ listID: String?, _ key: String) -> String? {
            proj.buildConfigurations(listID: listID).lazy.compactMap { $0.attributes["buildSettings"]?.dictionary?[key]?.string }.first
        }
        let tl = proj.targets.first?.string("buildConfigurationList"), pl = proj.project?.string("buildConfigurationList")
        let families = DestinationCatalog.deviceFamilies(targetedDeviceFamily: value(tl, "TARGETED_DEVICE_FAMILY") ?? value(pl, "TARGETED_DEVICE_FAMILY"))
        return (platforms(of: proj).platforms.contains("macOS"), families)
    }
}
