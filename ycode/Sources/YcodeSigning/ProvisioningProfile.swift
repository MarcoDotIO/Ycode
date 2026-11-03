import Foundation

/// The platform a product is signed for, from the SDK.
public enum SigningPlatform: Equatable, Sendable {
    case macOS
    /// An iOS app built for the Mac (`SDK_VARIANT` `iosmac`).
    case macCatalyst
    /// A simulator SDK (`iphonesimulator`, `xrsimulator`, …).
    case simulator(String)
    /// A device SDK (`iphoneos`, `xros`, `appletvos`, `watchos`, `driverkit`).
    case device(String)

    /// From an SDK canonical name (`macosx27.1`, `iphonesimulator27.0`) and variant.
    public init(sdk: String, variant: String?) {
        let base = String(sdk.prefix { $0.isLetter })
        if base == "macosx" { self = variant == "iosmac" ? .macCatalyst : .macOS }
        else if base.hasSuffix("simulator") { self = .simulator(base) }
        else { self = .device(base) }
    }

    public var isMac: Bool { self == .macOS || self == .macCatalyst }
    public var isSimulator: Bool { if case .simulator = self { true } else { false } }

    /// The application-identifier entitlement's key: the macOS name on the
    /// Mac, the short one elsewhere (Apple TN3125).
    public var applicationIdentifierKey: String { isMac ? "com.apple.application-identifier" : "application-identifier" }
    /// The debugging entitlement's key.
    public var getTaskAllowKey: String { isMac ? "com.apple.security.get-task-allow" : "get-task-allow" }

    /// The `Platform` names a provisioning profile lists for this platform.
    public var profilePlatforms: [String] {
        switch self {
        case .macOS, .macCatalyst: ["OSX"]
        case .simulator(let s), .device(let s):
            switch s.replacingOccurrences(of: "simulator", with: "os") {
            case "iphoneos": ["iOS"]
            case "xros": ["xrOS", "visionOS"]
            case "appletvos": ["tvOS"]
            case "watchos": ["watchOS", "iOS"]
            case "driverkit": ["DriverKit", "OSX", "iOS"]
            default: [s]
            }
        }
    }
}

/// A provisioning profile, decoded from its CMS envelope (Apple TN3125:
/// "Inside Code Signing: Provisioning Profiles"). Ycode only reads the
/// profiles the user already has; it never creates or downloads one.
public struct ProvisioningProfile: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var teamIdentifiers: [String]
    public var teamName: String?
    public var appIDName: String?
    public var applicationIdentifierPrefixes: [String]
    public var platforms: [String]
    public var creationDate: Date?
    public var expirationDate: Date?
    public var entitlements: Entitlements
    public var provisionedDevices: [String]
    public var provisionsAllDevices: Bool
    /// SHA-1 of each certificate in `DeveloperCertificates`.
    public var certificateHashes: [String]
    public var isXcodeManaged: Bool
    /// Where it was read from.
    public var path: String?

    public init(uuid: String, name: String, teamIdentifiers: [String], teamName: String? = nil, appIDName: String? = nil,
                applicationIdentifierPrefixes: [String] = [], platforms: [String], creationDate: Date? = nil, expirationDate: Date? = nil,
                entitlements: Entitlements, provisionedDevices: [String] = [], provisionsAllDevices: Bool = false,
                certificateHashes: [String], isXcodeManaged: Bool = false, path: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.teamIdentifiers = teamIdentifiers
        self.teamName = teamName
        self.appIDName = appIDName
        self.applicationIdentifierPrefixes = applicationIdentifierPrefixes
        self.platforms = platforms
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.entitlements = entitlements
        self.provisionedDevices = provisionedDevices
        self.provisionsAllDevices = provisionsAllDevices
        self.certificateHashes = certificateHashes.map { $0.uppercased() }
        self.isXcodeManaged = isXcodeManaged
        self.path = path
    }

    public enum DecodingError: Error, Equatable, CustomStringConvertible {
        case missingKey(String)
        public var description: String {
            switch self {
            case .missingKey(let k): "the profile has no \(k)"
            }
        }
    }

    /// From the profile's property list (the CMS content).
    public init(propertyList data: Data, path: String? = nil) throws {
        let d = try Entitlements.fromPropertyList(data)
        guard let uuid = d["UUID"]?.stringValue else { throw DecodingError.missingKey("UUID") }
        guard let name = d["Name"]?.stringValue else { throw DecodingError.missingKey("Name") }
        self.init(uuid: uuid, name: name,
                  teamIdentifiers: d["TeamIdentifier"]?.strings ?? [],
                  teamName: d["TeamName"]?.stringValue,
                  appIDName: d["AppIDName"]?.stringValue,
                  applicationIdentifierPrefixes: d["ApplicationIdentifierPrefix"]?.strings ?? [],
                  platforms: d["Platform"]?.strings ?? [],
                  creationDate: d["CreationDate"]?.dateValue,
                  expirationDate: d["ExpirationDate"]?.dateValue,
                  entitlements: d["Entitlements"]?.dictionaryValue ?? [:],
                  provisionedDevices: d["ProvisionedDevices"]?.strings ?? [],
                  provisionsAllDevices: d["ProvisionsAllDevices"]?.boolValue ?? false,
                  certificateHashes: (d["DeveloperCertificates"]?.arrayValue ?? []).compactMap(\.dataValue).map { SHA1.hex([UInt8]($0)) },
                  isXcodeManaged: d["IsXcodeManaged"]?.boolValue ?? false,
                  path: path)
    }

    /// The profile's application identifier (`<prefix>.<bundle id pattern>`).
    public var applicationIdentifier: String? {
        (entitlements["application-identifier"] ?? entitlements["com.apple.application-identifier"])?.stringValue
    }

    /// The team prefix of the application identifier.
    public var applicationIdentifierPrefix: String? {
        applicationIdentifier.flatMap { id in id.firstIndex(of: ".").map { String(id[..<$0]) } } ?? applicationIdentifierPrefixes.first
    }

    /// The bundle-identifier pattern (`com.example.app`, `com.example.*`, `*`).
    public var bundleIdentifierPattern: String? {
        applicationIdentifier.flatMap { id in id.firstIndex(of: ".").map { String(id[id.index(after: $0)...]) } }
    }

    /// Whether the application identifier is a wildcard.
    public var isWildcard: Bool { bundleIdentifierPattern?.hasSuffix("*") ?? false }

    public enum Kind: String, Sendable {
        case development, adHoc = "ad-hoc", enterprise, distribution
    }

    /// The kind, from what the profile allows (TN3125): debugging means
    /// development; devices without debugging, ad hoc; all devices, enterprise.
    public var kind: Kind {
        if entitlements["get-task-allow"]?.boolValue == true || entitlements["com.apple.security.get-task-allow"]?.boolValue == true { return .development }
        if provisionsAllDevices { return .enterprise }
        if !provisionedDevices.isEmpty { return .adHoc }
        return .distribution
    }

    public func isExpired(at now: Date) -> Bool { expirationDate.map { $0 <= now } ?? false }

    /// Whether the profile covers the bundle identifier.
    public func covers(bundleIdentifier: String) -> Bool {
        guard let pattern = bundleIdentifierPattern else { return false }
        return EntitlementPolicy.pattern(pattern, matches: bundleIdentifier)
    }
}

/// The provisioning profiles installed for the user.
public enum ProfileStore {
    /// Where profiles are installed: Xcode 16 and later keep them in
    /// `~/Library/Developer/Xcode/UserData/Provisioning Profiles`; earlier
    /// versions (and other tools) in `~/Library/MobileDevice/Provisioning Profiles`.
    /// `YCODE_PROVISIONING_PROFILES` (folders separated by `:`) replaces both.
    public static func directories(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        if let list = environment["YCODE_PROVISIONING_PROFILES"] {
            return list.split(separator: ":").map(String.init)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        return [home + "/Library/Developer/Xcode/UserData/Provisioning Profiles",
                home + "/Library/MobileDevice/Provisioning Profiles"]
    }

    /// The property list inside a profile file: plain property lists (as
    /// tests write them) are used as they are; CMS envelopes are opened
    /// with `security cms -D` on macOS.
    public static func contents(ofFile path: String, runner: CommandRunner = .system) -> Data? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        if data.starts(with: Array("<?xml".utf8)) || data.starts(with: Array("bplist".utf8)) { return data }
        guard FileManager.default.isExecutableFile(atPath: Keychain.security) else { return nil }
        let r = runner.run(Keychain.security, ["cms", "-D", "-i", path])
        return r.status == 0 ? r.output : nil
    }

    /// Every readable profile (`*.mobileprovision`, `*.provisionprofile`) in the folders.
    public static func load(directories: [String], runner: CommandRunner = .system) -> [ProvisioningProfile] {
        var out: [ProvisioningProfile] = []
        var seen = Set<String>()
        for dir in directories {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
            for n in names where n.hasSuffix(".mobileprovision") || n.hasSuffix(".provisionprofile") {
                let path = dir + "/" + n
                guard let data = contents(ofFile: path, runner: runner),
                      let p = try? ProvisioningProfile(propertyList: data, path: path),
                      seen.insert(p.uuid).inserted else { continue }
                out.append(p)
            }
        }
        return out
    }
}
