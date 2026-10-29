import Foundation
import YcodeBuild
import YcodeSettings

/// `-destination` specifiers and `-showdestinations`.
/// See `specs/xcodebuild/info-commands.md` §5.
enum Destinations {
    /// Parses `key=value[,key=value]`, or `generic/platform=…`.
    static func parse(_ spec: String) -> (generic: Bool, fields: [String: String]) {
        var s = spec
        var generic = false
        if s.hasPrefix("generic/") { generic = true; s.removeFirst("generic/".count) }
        var fields: [String: String] = [:]
        for part in s.split(separator: ",") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { fields[kv[0]] = kv[1] }
        }
        return (generic, fields)
    }

    /// swift-build platform/sdk names for a destination platform name.
    static let platforms: [String: (platform: String, variant: String?)] = [
        "macOS": ("macosx", "macos"), "OS X": ("macosx", "macos"),
        "iOS": ("iphoneos", nil), "iOS Simulator": ("iphonesimulator", nil),
        "tvOS": ("appletvos", nil), "tvOS Simulator": ("appletvsimulator", nil),
        "watchOS": ("watchos", nil), "watchOS Simulator": ("watchsimulator", nil),
        "visionOS": ("xros", nil), "visionOS Simulator": ("xrsimulator", nil),
        "DriverKit": ("driverkit", nil),
    ]

    /// The run destination for a scheme run. With no `-destination`, the
    /// host Mac (the reference tool picks "the first of multiple matching
    /// destinations", which is My Mac with the host architecture).
    static func runDestination(for specs: [String], targets: [SettingsTarget], configuration: String, overrides: [(String, String)] = [], generic: Bool = false,
                               context ctx: XcodebuildContext) throws(XcodebuildFailure) -> (RunDestination?, [(String, String)]) {
        guard let spec = specs.first else { return defaultDestination(targets: targets, configuration: configuration, overrides: overrides, generic: generic, context: ctx) }
        return (try explicitDestination(spec, context: ctx), [])
    }

    /// The first matching destination: My Mac for macOS targets; for iOS
    /// applications that can run on the Mac, "My Mac (Designed for iPad)",
    /// which also describes the Mac as the target device.
    static func defaultDestination(targets: [SettingsTarget], configuration: String, overrides: [(String, String)], generic: Bool = false,
                                   context ctx: XcodebuildContext) -> (RunDestination?, [(String, String)]) {
        guard let t = targets.first else { return (RunDestination.hostMac(architecture: ctx.hostArchitecture), []) }
        var b = ProjectSettingsBuilder(proj: t.project.proj, xcodeprojURL: t.project.url)
        b.developerDirectory = ctx.developerDirectory
        let r = try? b.resolve(target: t.name, configuration: configuration)
        let sdkroot = r?.settings["SDKROOT"] ?? ""
        let base = sdkroot.hasPrefix("/") ? URL(fileURLWithPath: sdkroot).lastPathComponent.lowercased().prefix { $0.isLetter }.description
            : sdkroot.prefix { $0.isLetter }.description
        if base.isEmpty || base == "macosx" {
            // My Mac, in each architecture it can run, then Any Mac; an
            // `ARCHS` override naming one architecture moves that one first.
            var archs = ctx.hostArchitecture == "arm64" ? ["arm64", "x86_64"] : ["x86_64"]
            if let a = overrides.last(where: { $0.0 == "ARCHS" })?.1, archs.contains(a) { archs.removeAll { $0 == a }; archs.insert(a, at: 0) }
            let id = macProvisioningUDID()
            var lines = archs.map { a in describe([("platform", "macOS"), ("arch", a)] + (id.map { [("id", $0)] } ?? []) + [("name", "My Mac")]) }
            let anyMac = describe([("platform", "macOS"), ("name", "Any Mac")])
            // `archive` prefers the generic destination (every architecture).
            if generic { lines.insert(anyMac, at: 0) } else { lines.append(anyMac) }
            ctx.console.warning("Using the first of multiple matching destinations:\n" + lines.joined(separator: "\n"))
            var dest = RunDestination.hostMac(architecture: archs[0])
            dest.disableOnlyActiveArch = generic
            return (dest, [])
        }
        let isApp = (t.target.string("productType") ?? "").hasSuffix(".application")
        let designedForIPad = r?.settings["SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD"] ?? ""
        if base == "iphoneos", isApp, designedForIPad != "NO", ctx.hostArchitecture == "arm64" {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            let version = os.patchVersion == 0 ? "\(os.majorVersion).\(os.minorVersion)" : "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            let family = "MacFamily20,1"
            var device: [(String, String)] = [
                ("ASSETCATALOG_FILTER_FOR_DEVICE_MODEL", family), ("ASSETCATALOG_FILTER_FOR_DEVICE_OS_VERSION", version),
                ("ASSETCATALOG_FILTER_FOR_THINNING_DEVICE_CONFIGURATION", family), ("BUILD_ACTIVE_RESOURCES_ONLY", "YES"),
                ("TARGET_DEVICE_MODEL", hardwareModel() ?? ""), ("TARGET_DEVICE_OS_VERSION", version), ("TARGET_DEVICE_PLATFORM_NAME", "macosx"),
            ]
            if let id = macProvisioningUDID() { device.append(("TARGET_DEVICE_IDENTIFIER", id)) }
            return (RunDestination(platform: "iphoneos", sdk: "iphoneos", sdkVariant: nil, targetArchitecture: "arm64",
                                   supportedArchitectures: ["arm64"]), device)
        }
        // Otherwise the Mac is still the first destination; for targets of
        // another platform it does not match, so ONLY_ACTIVE_ARCH has no
        // effect (observed: ONLY_ACTIVE_ARCH = NO).
        return (RunDestination.hostMac(architecture: ctx.hostArchitecture), [])
    }

    /// `hw.model`, e.g. `Mac15,10`.
    static func hardwareModel() -> String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
        #else
        return nil
        #endif
    }

    static func explicitDestination(_ spec: String, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> RunDestination? {
        let (generic, fields) = parse(spec)
        let name = fields["platform"] ?? "macOS"
        guard let p = platforms[name] else {
            throw XcodebuildFailure("Could not configure request: Unable to find a device matching the provided destination specifier:\n\t\t{ \(fields.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ", ")) }\n\n\tThe requested device could not be found because no platform could be found for the requested platform name.\n",
                                    exitCode: ExitCode.usage)
        }
        if generic { return nil }
        let arch = fields["arch"] ?? ctx.hostArchitecture
        if p.platform == "macosx" {
            var d = RunDestination.hostMac(architecture: arch)
            if fields["variant"] == "Mac Catalyst" { d.sdkVariant = "iosmac" }
            return d
        }
        return RunDestination(platform: p.platform, sdk: p.platform, sdkVariant: p.variant, targetArchitecture: arch, supportedArchitectures: [arch])
    }

    /// The Mac's provisioning UDID (the `id` the reference tool shows for
    /// My Mac), read from `system_profiler` output.
    static func macProvisioningUDID() -> String? { hardwareOverview["Provisioning UDID"] }

    /// `Model Name` (`MacBook Pro`).
    static func macModelName() -> String? { hardwareOverview["Model Name"] }

    /// `system_profiler SPHardwareDataType` as key/value pairs (read once).
    static let hardwareOverview: [String: String] = {
        var out: [String: String] = [:]
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return out }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            if out[key] == nil { out[key] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        #endif
        return out
    }()

    /// One `{ key:value, … }` line.
    static func describe(_ pairs: [(String, String)]) -> String {
        "{ " + pairs.map { "\($0.0):\($0.1)" }.joined(separator: ", ") + " }"
    }

    /// `subject` names the scheme's product in incompatibility errors
    /// (its first buildable, such as `Hello.app`).
    static func listing(subject: String, supportedPlatforms: Set<String>, context ctx: XcodebuildContext) -> (compatible: [String], incompatible: [String]) {
        var compatible: [String] = []
        var incompatible: [String] = []
        func error(_ name: String, _ platform: String) -> String {
            "\(name)’s \(platform) platform doesn’t match \(subject)’s supported platforms. You can change \(subject)’s Base SDK or Supported Platforms to support \(name)."
        }
        if supportedPlatforms.contains("macosx") {
            var mac: [(String, String)] = [("platform", "macOS"), ("arch", ctx.hostArchitecture)]
            if let id = macProvisioningUDID() { mac.append(("id", id)) }
            mac.append(("name", "My Mac"))
            compatible.append(describe(mac))
            compatible.append(describe([("platform", "macOS"), ("name", "Any Mac")]))
        }
        #if os(macOS)
        for d in PhysicalDevices.load() {
            if supportedPlatforms.contains(platforms[d.platform]?.platform ?? "") {
                compatible.append(describe([("platform", d.platform), ("arch", d.arch), ("id", d.udid), ("name", d.name)]))
            } else {
                // Incompatible devices show the device's own architecture.
                incompatible.append(describe([("platform", d.platform), ("arch", d.deviceArch), ("id", d.udid), ("name", d.name),
                                              ("error", error(d.name, d.platform))]))
            }
        }
        for s in Simulators.load() {
            var pairs = [("platform", s.platform), ("arch", ctx.hostArchitecture), ("id", s.udid)]
            if let os = s.os { pairs.append(("OS", os)) }
            pairs.append(("name", s.name))
            if supportedPlatforms.contains(platforms[s.platform]?.platform ?? "") { compatible.append(describe(pairs)) } else {
                incompatible.append(describe(pairs + [("error", error(s.name, s.platform))]))
            }
        }
        #endif
        return (compatible, incompatible)
    }

    /// `-showdestinations` for a package scheme, which builds for every
    /// platform: My Mac and its variants, available devices, the generic
    /// destinations of the installed platforms, then the simulators.
    /// See `specs/xcodebuild/packages.md` §5.
    static func packageListing(context ctx: XcodebuildContext) -> [String] {
        let installed = Set(SDKRegistry(developerDirectory: ctx.developerDirectory ?? "").entries.map(\.platformName))
        let arch = ctx.hostArchitecture
        let macID = macProvisioningUDID().map { [("id", $0)] } ?? []
        var out: [String] = []
        let mac: [(String, String)] = [("platform", "macOS"), ("arch", arch)]
        out.append(describe(mac + macID + [("name", "My Mac")]))
        let variants: [(String, String)] = [("Mac Catalyst", "iphoneos"), ("DriverKit", "driverkit"), ("Designed for [iPad,iPhone]", "iphoneos")]
        for (variant, sdk) in variants where installed.contains(sdk) && (variant != "Designed for [iPad,iPhone]" || arch == "arm64") {
            out.append(describe(mac + [("variant", variant)] + macID + [("name", "My Mac")]))
        }
        #if os(macOS)
        for d in PhysicalDevices.load() where installed.contains(platforms[d.platform]?.platform ?? "") {
            out.append(describe([("platform", d.platform), ("arch", d.arch), ("id", d.udid), ("name", d.name)]))
        }
        #endif
        for g in genericDestinations where installed.contains(g.sdk) {
            var pairs = [("platform", g.platform)]
            if let v = g.variant { pairs.append(("variant", v)) }
            if let id = g.id { pairs.append(("id", id)) }
            out.append(describe(pairs + [("name", g.name)]))
        }
        #if os(macOS)
        for s in Simulators.load() where installed.contains(platforms[s.platform]?.platform ?? "") {
            var pairs = [("platform", s.platform), ("arch", arch), ("id", s.udid)]
            if let os = s.os { pairs.append(("OS", os)) }
            out.append(describe(pairs + [("name", s.name)]))
        }
        #endif
        return out
    }

    /// Generic destinations in listing order, with the platform SDK each needs.
    static let genericDestinations: [(platform: String, variant: String?, id: String?, name: String, sdk: String)] = [
        ("DriverKit", nil, nil, "Any DriverKit Host", "driverkit"),
        ("iOS", nil, "dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder", "Any iOS Device", "iphoneos"),
        ("iOS Simulator", nil, "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder", "Any iOS Simulator Device", "iphonesimulator"),
        ("macOS", nil, nil, "Any Mac", "macosx"),
        ("macOS", "Mac Catalyst", nil, "Any Mac", "iphoneos"),
        ("tvOS", nil, "dvtdevice-DVTiOSDevicePlaceholder-appletvos:placeholder", "Any tvOS Device", "appletvos"),
        ("tvOS Simulator", nil, "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-appletvsimulator:placeholder", "Any tvOS Simulator Device", "appletvsimulator"),
        ("visionOS", nil, "dvtdevice-DVTiOSDevicePlaceholder-xros:placeholder", "Any visionOS Device", "xros"),
        ("visionOS Simulator", nil, "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-xrsimulator:placeholder", "Any visionOS Simulator Device", "xrsimulator"),
        ("watchOS", nil, "dvtdevice-DVTiOSDevicePlaceholder-watchos:placeholder", "Any watchOS Device", "watchos"),
        ("watchOS Simulator", nil, "dvtdevice-DVTiOSDeviceSimulatorPlaceholder-watchsimulator:placeholder", "Any watchOS Simulator Device", "watchsimulator"),
    ]
}

/// One simulator as `-showdestinations` lists it.
struct SimulatorEntry: Equatable {
    var platform: String   // `iOS Simulator`, …
    var udid: String
    /// The runtime's full version (`26.4.1`).
    var os: String?
    var name: String
}

enum Simulators {
    static let runtimePlatforms = ["iOS": "iOS Simulator", "tvOS": "tvOS Simulator", "watchOS": "watchOS Simulator",
                                   "xrOS": "visionOS Simulator", "visionOS": "visionOS Simulator"]
    /// Platform order of the listing (observed).
    static let order = ["tvOS Simulator", "visionOS Simulator", "watchOS Simulator", "iOS Simulator"]

    /// Available simulators from `xcrun simctl list -j devices` and the
    /// runtimes' versions from `xcrun simctl list -j runtimes`, ordered by
    /// platform, name (byte order) and OS version.
    static func entries(devicesJSON: Data, runtimesJSON: Data?) -> [SimulatorEntry] {
        var versions: [String: String] = [:]
        if let data = runtimesJSON, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for r in root["runtimes"] as? [[String: Any]] ?? [] {
                if let id = r["identifier"] as? String, let v = r["version"] as? String { versions[id] = v }
            }
        }
        guard let root = try? JSONSerialization.jsonObject(with: devicesJSON) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [SimulatorEntry] = []
        for (runtime, devices) in byRuntime {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-4 → iOS, 26.4
            let parts = (runtime.split(separator: ".").last.map(String.init) ?? runtime).split(separator: "-").map(String.init)
            guard let first = parts.first, let platform = runtimePlatforms[first] else { continue }
            let fallback = parts.dropFirst().joined(separator: ".")
            for d in devices where (d["isAvailable"] as? Bool) ?? true {
                guard let name = d["name"] as? String, let udid = d["udid"] as? String else { continue }
                out.append(SimulatorEntry(platform: platform, udid: udid, os: versions[runtime] ?? (fallback.isEmpty ? nil : fallback), name: name))
            }
        }
        return out.sorted { a, b in
            let x = order.firstIndex(of: a.platform) ?? 9, y = order.firstIndex(of: b.platform) ?? 9
            if x != y { return x < y }
            if a.name != b.name { return Array(a.name.utf8).lexicographicallyPrecedes(Array(b.name.utf8)) }
            return (a.os ?? "").compare(b.os ?? "", options: .numeric) == .orderedAscending
        }
    }

    #if os(macOS)
    static func load() -> [SimulatorEntry] {
        guard let devices = xcrun(["simctl", "list", "-j", "devices"]) else { return [] }
        return entries(devicesJSON: devices, runtimesJSON: xcrun(["simctl", "list", "-j", "runtimes"]))
    }
    #endif
}

/// One physical device as `-showdestinations` lists it.
struct DeviceEntry: Equatable {
    var platform: String
    /// The architecture listed for a compatible device (`arm64e` → `arm64`).
    var arch: String
    /// The device's CPU type name (`arm64e`).
    var deviceArch: String
    var udid: String
    var name: String
}

enum PhysicalDevices {
    /// Physical devices with a connection (a transport) from `xcrun devicectl
    /// list devices --json-output`; `arm64e` devices are listed as `arm64`.
    static func entries(devicectlJSON data: Data) -> [DeviceEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return list.compactMap { d -> DeviceEntry? in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            let conn = d["connectionProperties"] as? [String: Any] ?? [:]
            guard hw["reality"] as? String == "physical", conn["transportType"] is String,
                  let platform = hw["platform"] as? String, let udid = hw["udid"] as? String,
                  let name = props["name"] as? String else { return nil }
            let cpu = (hw["cpuType"] as? [String: Any])?["name"] as? String ?? "arm64"
            return DeviceEntry(platform: platform, arch: cpu == "arm64e" ? "arm64" : cpu, deviceArch: cpu, udid: udid, name: name)
        }.sorted { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }
    }

    #if os(macOS)
    static func load() -> [DeviceEntry] {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ycodebuild-devicectl-\(ProcessInfo.processInfo.processIdentifier).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = xcrun(["devicectl", "list", "devices", "--json-output", file.path, "-q"])
        return (try? Data(contentsOf: file)).map(entries(devicectlJSON:)) ?? []
    }
    #endif
}

#if os(macOS)
/// Runs `xcrun` (read-only listings); its standard output, or nil.
func xcrun(_ args: [String]) -> Data? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return p.terminationStatus == 0 ? data : nil
}
#endif
