import Foundation
import YcodeSubprocess

/// A run destination: where a scheme builds and runs. See
/// `specs/ide/destinations.md`.
public struct Destination: Equatable, Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case mac, device, simulator
        /// "Any … Device": build for the platform, nothing to run on.
        case generic
    }

    public var name: String
    /// The `-destination` specifier.
    public var specifier: String
    /// Platform display name: macOS, iOS, watchOS, tvOS, visionOS.
    public var platform: String
    public var kind: Kind
    public var osVersion: String?
    public var identifier: String?

    public init(name: String, specifier: String, platform: String, kind: Kind, osVersion: String? = nil, identifier: String? = nil) {
        self.name = name
        self.specifier = specifier
        self.platform = platform
        self.kind = kind
        self.osVersion = osVersion
        self.identifier = identifier
    }

    public static let myMac = Destination(name: "My Mac", specifier: "platform=macOS", platform: "macOS", kind: .mac)
    public static let anyMac = Destination(name: "Any Mac", specifier: "generic/platform=macOS", platform: "macOS", kind: .generic)

    /// The `-destination` platform names for simulators of a platform.
    static func simulatorPlatform(_ p: String) -> String { "\(p) Simulator" }
}

/// A titled section of the destination pop-up.
public struct DestinationGroup: Equatable, Sendable {
    public var title: String
    public var destinations: [Destination]
    public init(title: String, destinations: [Destination]) {
        self.title = title
        self.destinations = destinations
    }
}

public enum DestinationCatalog {
    static let platformOrder = ["macOS", "iOS", "watchOS", "tvOS", "visionOS"]
    /// CoreSimulator runtime identifiers spell platforms this way.
    static let runtimePlatforms = ["iOS": "iOS", "watchOS": "watchOS", "tvOS": "tvOS", "xrOS": "visionOS", "visionOS": "visionOS"]

    /// Simulators from `xcrun simctl list -j devices`. Only available
    /// devices are listed; state (booted or not) does not matter.
    public static func simulators(fromSimctlJSON data: Data) -> [Destination] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let byRuntime = root["devices"] as? [String: [[String: Any]]] else { return [] }
        var out: [Destination] = []
        for (runtime, devices) in byRuntime {
            // com.apple.CoreSimulator.SimRuntime.iOS-26-4 → iOS, 26.4
            let tail = runtime.split(separator: ".").last.map(String.init) ?? runtime
            let parts = tail.split(separator: "-").map(String.init)
            guard let first = parts.first, let platform = runtimePlatforms[first] else { continue }
            let version = parts.dropFirst().joined(separator: ".")
            for d in devices where (d["isAvailable"] as? Bool) ?? true {
                guard let name = d["name"] as? String, let udid = d["udid"] as? String else { continue }
                out.append(Destination(name: name, specifier: "platform=\(Destination.simulatorPlatform(platform)),id=\(udid)",
                                       platform: platform, kind: .simulator, osVersion: version.isEmpty ? nil : version, identifier: udid))
            }
        }
        return out
    }

    /// Physical devices from `xcrun devicectl list devices --json-output`.
    /// Simulated entries in that list are skipped (simctl covers them).
    public static func devices(fromDevicectlJSON data: Data) -> [Destination] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (root["result"] as? [String: Any])?["devices"] as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            let hw = d["hardwareProperties"] as? [String: Any] ?? [:]
            let props = d["deviceProperties"] as? [String: Any] ?? [:]
            guard (hw["reality"] as? String) == "physical",
                  let platform = hw["platform"] as? String, let udid = hw["udid"] as? String,
                  let name = props["name"] as? String else { return nil }
            return Destination(name: name, specifier: "platform=\(platform),id=\(udid)", platform: platform, kind: .device,
                               osVersion: props["osVersionNumber"] as? String, identifier: udid)
        }
    }

    /// Groups destinations the way the pop-up shows them: My Mac first,
    /// then per platform a devices section (with "Any <platform> Device")
    /// and a simulators section. Duplicate simulator names get their OS
    /// version appended.
    public static func groups(devices: [Destination], simulators: [Destination]) -> [DestinationGroup] {
        var groups = [DestinationGroup(title: "My Mac", destinations: [.myMac]),
                      DestinationGroup(title: "Build", destinations: [.anyMac])]
        let platforms = Set(devices.map(\.platform) + simulators.map(\.platform))
            .sorted { (platformOrder.firstIndex(of: $0) ?? 99, $0) < (platformOrder.firstIndex(of: $1) ?? 99, $1) }
        for p in platforms where p != "macOS" {
            let generic = Destination(name: "Any \(p) Device (arm64)", specifier: "generic/platform=\(p)", platform: p, kind: .generic)
            let devs = devices.filter { $0.platform == p }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            groups.append(DestinationGroup(title: "\(p) Device", destinations: devs + [generic]))
            var sims = simulators.filter { $0.platform == p }
            let counts = Dictionary(grouping: sims, by: \.name).mapValues(\.count)
            sims = sims.map { s in
                var s = s
                if counts[s.name, default: 0] > 1, let v = s.osVersion { s.name += " (\(v))" }
                return s
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if !sims.isEmpty {
                let anySim = Destination(name: "Any \(p) Simulator Device", specifier: "generic/platform=\(Destination.simulatorPlatform(p))",
                                         platform: p, kind: .generic)
                groups.append(DestinationGroup(title: "\(p) Simulators", destinations: [anySim] + sims))
            }
        }
        return groups
    }

    #if os(macOS)
    /// Reads both listings (read-only; nothing is booted or connected).
    public static func load(scratchDirectory: URL = FileManager.default.temporaryDirectory) -> [DestinationGroup] {
        func run(_ args: [String]) -> Data? {
            MainThreadGuard.blockingCall("xcrun \(args.joined(separator: " "))")
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
        let sims = run(["simctl", "list", "-j", "devices"]).map(simulators(fromSimctlJSON:)) ?? []
        let file = scratchDirectory.appendingPathComponent("ycode-devicectl-\(ProcessInfo.processInfo.processIdentifier).json")
        defer { try? FileManager.default.removeItem(at: file) }
        _ = run(["devicectl", "list", "devices", "--json-output", file.path, "-q"])
        let devs = (try? Data(contentsOf: file)).map(devices(fromDevicectlJSON:)) ?? []
        return groups(devices: devs, simulators: sims)
    }
    #endif
}
