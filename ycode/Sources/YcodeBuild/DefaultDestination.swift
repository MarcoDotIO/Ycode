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

    /// The default destination for a product (`reference-ui-6.md` §2.4.2–
    /// §2.4.3, T3 and T11; refines `reference-ui-5.md` §4.3.5):
    /// 1. My Mac when the product supports macOS (`supportsMacOS`: a
    ///    multiplatform app), its platform is macOS, or it is unknown (a
    ///    package);
    /// 2. otherwise, of the candidates (simulators of that platform whose
    ///    runtime is not below the deployment target and whose device
    ///    family the product supports), the newest-generation Pro iPhone
    ///    ("iPhone 18 Pro", not "Pro Max", "Air" or "e") on the newest
    ///    runtime that has one;
    /// 3. otherwise the first candidate in the Simulators order;
    /// 4. otherwise the generic "Any <Platform> Simulator Device".
    ///
    /// My Mac is never chosen for a product that does not support macOS.
    /// - Parameters:
    ///   - simulators: the simulator rows (any kind but devices and the
    ///     Mac; Ycode's remote simulator rows included by the caller).
    ///   - deviceFamilies: the families the product supports ("iPhone",
    ///     "iPad"; `deviceFamilies(targetedDeviceFamily:)`); nil = all. A
    ///     simulator of an unknown family stays a candidate.
    ///   - order: the Simulators order (the menu's, which also places rows
    ///     whose runtime version is not known yet).
    public static func defaultDestination(platform: String?, deploymentTarget: String?, simulators: [Destination],
                                          supportsMacOS: Bool = false, deviceFamilies: Set<String>? = nil,
                                          order: ([Destination]) -> [Destination] = simulatorsInMenuOrder) -> Destination {
        guard let platform, platform != "macOS", !supportsMacOS else { return .myMac }
        let candidates = order(simulators.filter { $0.platform == platform && $0.kind != .device && $0.kind != .mac }).filter { sim in
            if let families = deviceFamilies, let family = deviceFamily(of: sim), !families.contains(family) { return false }
            guard let target = deploymentTarget, !target.isEmpty, let v = sim.osVersion else { return true }
            return compareVersions(v, target) != .orderedAscending
        }
        // Step 2: the Simulators order is newest runtime first, so the
        // first row of the newest Pro generation is on the newest runtime
        // that has one.
        let generations = candidates.map(proIPhoneGeneration(of:))
        if let newest = generations.compactMap({ $0 }).max(), let i = generations.firstIndex(of: newest) {
            return candidates[i]
        }
        return candidates.first ?? anySimulator(platform)
    }

    /// The device family of a simulator ("iPhone", "iPad", "Apple Vision"):
    /// from its device type when the listing names one, else from its
    /// name. Nil when neither tells.
    public static func deviceFamily(of d: Destination) -> String? {
        let words = [deviceTypeName(d.deviceType), d.deviceType == nil ? d.name : nil].compactMap { $0 }
        for w in words {
            for family in ["iPhone", "iPad", "Apple Vision"] where w.hasPrefix(family) { return family }
        }
        return nil
    }

    /// The generation of a Pro iPhone device type ("iPhone 18 Pro" → 18);
    /// nil for any other type ("Pro Max", "Air", "e", the base model). The
    /// type comes from the device type identifier when known
    /// ("…SimDeviceType.iPhone-18-Pro"); else from the simulator's name,
    /// without a trailing parenthesized note ("iPhone 18 Pro (Ycode)").
    public static func proIPhoneGeneration(of d: Destination) -> Int? {
        var name = deviceTypeName(d.deviceType) ?? d.name
        if d.deviceType == nil, name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        let words = name.split(separator: " ")
        guard words.count == 3, words[0] == "iPhone", words[2] == "Pro", let n = Int(words[1]) else { return nil }
        return n
    }

    /// "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro" → "iPhone 18 Pro".
    static func deviceTypeName(_ identifier: String?) -> String? {
        guard let identifier, let last = identifier.split(separator: ".").last else { return nil }
        return last.replacingOccurrences(of: "-", with: " ")
    }

    /// `TARGETED_DEVICE_FAMILY` ("1" iPhone, "2" iPad, "1,2" both) as
    /// family names; nil when unset or naming neither (no restriction).
    public static func deviceFamilies(targetedDeviceFamily value: String?) -> Set<String>? {
        let codes = (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let names = Set(codes.compactMap { ["1": "iPhone", "2": "iPad"][$0] })
        return names.isEmpty ? nil : names
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
