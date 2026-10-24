import Foundation

/// The run destination a scheme starts with when it has no remembered one
/// (`specs/ide/reference-ui-5.md` §4.3 item 5, T1).
extension DestinationCatalog {
    /// Simulators in the destination menu's order (`reference-ui-5.md`
    /// §11.4): runtime version newest first; within a runtime iPhone, then
    /// iPad, then Apple Vision, then the rest; each group by name in
    /// localized standard order.
    public static func simulatorsInMenuOrder(_ sims: [Destination]) -> [Destination] {
        func family(_ d: Destination) -> Int {
            if d.name.hasPrefix("iPhone") { return 0 }
            if d.name.hasPrefix("iPad") { return 1 }
            if d.name.hasPrefix("Apple Vision") { return 2 }
            return 3
        }
        return sims.sorted { a, b in
            let v = compareVersions(a.osVersion ?? "", b.osVersion ?? "")
            if v != .orderedSame { return v == .orderedDescending }
            let (fa, fb) = (family(a), family(b))
            if fa != fb { return fa < fb }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Dotted version comparison ("26.10" > "26.4"); missing parts are 0.
    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }, pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    /// The default destination for a product:
    /// 1. My Mac when the product's platform is macOS (or unknown, as for
    ///    a package);
    /// 2. otherwise the first simulator of that platform, in menu order,
    ///    whose OS version is not below the deployment target;
    /// 3. otherwise the generic "Any <Platform> Simulator Device".
    ///
    /// My Mac is never chosen for a product whose platform is not macOS.
    public static func defaultDestination(platform: String?, deploymentTarget: String?, simulators: [Destination]) -> Destination {
        guard let platform, platform != "macOS" else { return .myMac }
        let candidates = simulatorsInMenuOrder(simulators.filter { $0.kind == .simulator && $0.platform == platform })
        if let first = candidates.first(where: { sim in
            guard let target = deploymentTarget, !target.isEmpty, let v = sim.osVersion else { return true }
            return compareVersions(v, target) != .orderedAscending
        }) {
            return first
        }
        return anySimulator(platform)
    }

    /// "Any <Platform> Simulator Device".
    public static func anySimulator(_ platform: String) -> Destination {
        Destination(name: "Any \(platform) Simulator Device", specifier: "generic/platform=\(Destination.simulatorPlatform(platform))",
                    platform: platform, kind: .generic)
    }

    /// The deployment-target build setting of a platform.
    public static func deploymentTargetSetting(_ platform: String) -> String? {
        ["macOS": "MACOSX_DEPLOYMENT_TARGET", "iOS": "IPHONEOS_DEPLOYMENT_TARGET", "watchOS": "WATCHOS_DEPLOYMENT_TARGET",
         "tvOS": "TVOS_DEPLOYMENT_TARGET", "visionOS": "XROS_DEPLOYMENT_TARGET"][platform]
    }
}
