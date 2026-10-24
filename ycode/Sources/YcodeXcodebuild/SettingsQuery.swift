import Foundation
import YcodeProject
import YcodeSettings
import YcodeSubprocess

/// Build locations (swift-build's "arena"). See
/// `specs/xcodebuild/show-build-settings.md` §4.
public struct Arena: Equatable, Sendable {
    public var derivedDataPath: String
    public var buildProductsPath: String
    public var buildIntermediatesPath: String

    /// `<DerivedData>/<name>-<hash>` for a container, or the given path.
    public static func forContainer(_ c: Container, derivedDataPath: String?, derivedDataRoot root: String) -> Arena {
        if let d = derivedDataPath {
            return Arena(derivedDataPath: d, buildProductsPath: d + "/Build/Products", buildIntermediatesPath: d + "/Build/Intermediates.noindex")
        }
        let folder = root + "/" + DerivedDataName.folder(name: c.name, path: c.url.path)
        return Arena(derivedDataPath: root, buildProductsPath: folder + "/Build/Products", buildIntermediatesPath: folder + "/Build/Intermediates.noindex")
    }

    var json: [String: Any] {
        let projectFolder = URL(fileURLWithPath: buildProductsPath).deletingLastPathComponent().deletingLastPathComponent().path
        return [
            "derivedDataPath": derivedDataPath,
            "buildProductsPath": buildProductsPath,
            "buildIntermediatesPath": buildIntermediatesPath,
            "pchPath": buildIntermediatesPath + "/PrecompiledHeaders",
            "indexRegularBuildProductsPath": projectFolder + "/Index.noindex/Build/Products",
            "indexRegularBuildIntermediatesPath": projectFolder + "/Index.noindex/Build/Intermediates.noindex",
            "indexPCHPath": projectFolder + "/Index.noindex/PrecompiledHeaders",
            "indexDataStoreFolderPath": projectFolder + "/Index.noindex/DataStore",
            "indexEnableDataStore": true,
        ]
    }
}

/// The per-container DerivedData folder name: `<name>-<28 letters>`, the
/// letters derived from the MD5 of the container path (two 64-bit
/// big-endian halves, each written as 14 base-26 digits a–z, most
/// significant first).
public enum DerivedDataName {
    public static func hash(_ path: String) -> String {
        let d = MD5.digest(Array(path.utf8))
        func half(_ bytes: ArraySlice<UInt8>) -> String {
            var v = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            var chars = [Character](repeating: "a", count: 14)
            for i in stride(from: 13, through: 0, by: -1) {
                chars[i] = Character(UnicodeScalar(UInt8(97 + v % 26)))
                v /= 26
            }
            return String(chars)
        }
        return half(d[0..<8]) + half(d[8..<16])
    }

    /// Spaces in the name become underscores.
    public static func folder(name: String, path: String) -> String {
        name.replacingOccurrences(of: " ", with: "_") + "-" + hash(path)
    }
}

/// A run destination as swift-build takes it.
public struct RunDestination: Equatable, Sendable {
    public var platform: String
    public var sdk: String
    public var sdkVariant: String?
    public var targetArchitecture: String
    public var supportedArchitectures: [String]
    /// A generic destination ("Any Mac"): builds every architecture.
    public var disableOnlyActiveArch = false

    public static func hostMac(architecture: String) -> RunDestination {
        RunDestination(platform: "macosx", sdk: "macosx", sdkVariant: "macos", targetArchitecture: architecture,
                       supportedArchitectures: ["arm64", "x86_64"])
    }

    var json: [String: Any] {
        var d: [String: Any] = ["platform": platform, "sdk": sdk, "targetArchitecture": targetArchitecture,
                                "supportedArchitectures": supportedArchitectures, "disableOnlyActiveArch": disableOnlyActiveArch]
        if let v = sdkVariant { d["sdkVariant"] = v }
        return d
    }
}

/// What to evaluate settings (or build) for.
public struct BuildParameters: Sendable {
    public var action: String
    public var configuration: String
    public var arena: Arena?
    public var runDestination: RunDestination?
    public var overrides: [(String, String)]
    public var xcconfigPath: String?
    /// Settings the tool itself adds for the run (code coverage, the run
    /// destination's device): swift-build's "synthesized" overrides.
    public var synthesized: [(String, String)] = []

    public init(action: String, configuration: String, arena: Arena? = nil, runDestination: RunDestination? = nil,
                overrides: [(String, String)] = [], xcconfigPath: String? = nil) {
        self.action = action
        self.configuration = configuration
        self.arena = arena
        self.runDestination = runDestination
        self.overrides = overrides
        self.xcconfigPath = xcconfigPath
    }

    /// swift-build's `SWBBuildParameters` JSON.
    public var json: [String: Any] {
        var table: [String: String] = [:]
        for (k, v) in overrides { table[k] = v }
        var overridesObject: [String: Any] = ["commandLine": ["table": table]]
        if let x = xcconfigPath { overridesObject["commandLineConfigPath"] = x }
        if !synthesized.isEmpty {
            var s: [String: String] = [:]
            for (k, v) in synthesized { s[k] = v }
            overridesObject["synthesized"] = ["table": s]
        }
        var d: [String: Any] = ["action": action, "configurationName": configuration, "overrides": overridesObject]
        if let a = arena { d["arenaInfo"] = a.json }
        if let r = runDestination {
            d["activeRunDestination"] = r.json
            d["activeArchitecture"] = r.targetArchitecture
        }
        return d
    }
}

/// One target to evaluate.
public struct SettingsTarget {
    public var project: LoadedProject
    public var target: PBXObject
    public var name: String { target.string("name") ?? "" }
}

public protocol SettingsProvider {
    /// Exported settings per target, in order.
    func settings(container: Container, targets: [SettingsTarget], parameters: BuildParameters) throws -> [[String: String]]
}

public struct SettingsError: Error, CustomStringConvertible {
    public var description: String
}

/// Evaluates settings with swift-build (through the `ycode-swb` helper),
/// from a PIF Ycode generates.
public struct SwiftBuildSettingsProvider: SettingsProvider {
    public var helper: String
    public var scratch: URL

    public init(helper: String, scratch: URL = FileManager.default.temporaryDirectory) {
        self.helper = helper
        self.scratch = scratch
    }

    /// `YCODE_SWB`, then `ycode-swb` on `PATH`, then next to the executable.
    public static func locate(environment: [String: String], executableDirectory: String?) -> String? {
        let fm = FileManager.default
        if let p = environment["YCODE_SWB"], fm.isExecutableFile(atPath: p) { return p }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where fm.isExecutableFile(atPath: "\(dir)/ycode-swb") {
            return "\(dir)/ycode-swb"
        }
        if let d = executableDirectory, fm.isExecutableFile(atPath: d + "/ycode-swb") { return d + "/ycode-swb" }
        return nil
    }

    public func settings(container: Container, targets: [SettingsTarget], parameters: BuildParameters) throws -> [[String: String]] {
        let pif = XcodePIF(container: container)
        let work = scratch.appendingPathComponent("ycodebuild-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let pifURL = work.appendingPathComponent("workspace.pif.json")
        try pif.serialized().write(to: pifURL)
        return try settings(pif: pifURL, guids: targets.map { pif.targetGUID($0.project, $0.target) }, parameters: parameters, work: work)
    }

    /// Settings of targets of an existing build description (a Swift
    /// package's, from SwiftPM).
    public func settings(pif pifURL: URL, guids: [String], parameters: BuildParameters, work: URL? = nil) throws -> [[String: String]] {
        let work = work ?? scratch.appendingPathComponent("ycodebuild-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let request: [String: Any] = [
            "pif": pifURL.path,
            "parameters": parameters.json,
            "levels": guids.map { ["target": $0] },
        ]
        let requestURL = work.appendingPathComponent("request.json")
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]).write(to: requestURL)
        MainThreadGuard.blockingCall("ycode-swb settings")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: helper)
        p.arguments = ["settings", requestURL.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = reply["settings"] as? [[String: String]] else {
            throw SettingsError(description: "the settings helper failed: " + String(decoding: errData, as: UTF8.self))
        }
        return list
    }
}

/// Without swift-build: Ycode's own resolver (`YcodeSettings`). It knows the
/// project-defined levels and a few built-ins, not the defaults of the
/// build system's specifications, so it prints fewer settings.
public struct ResolverSettingsProvider: SettingsProvider {
    public var developerDirectory: String?
    public init(developerDirectory: String?) { self.developerDirectory = developerDirectory }

    public func settings(container: Container, targets: [SettingsTarget], parameters: BuildParameters) throws -> [[String: String]] {
        let catalog = developerDirectory.map { SDKCatalog(developerDirectory: $0) }
        return try targets.map { t in
            var b = ProjectSettingsBuilder(proj: t.project.proj, xcodeprojURL: t.project.url)
            b.developerDirectory = developerDirectory
            if let catalog { b.sdkLookup = { catalog.lookup($0) } }
            var o: [String: String] = [:]
            // (-xcconfig files are not applied by this fallback.)
            for (k, v) in parameters.overrides { o[k] = v }
            b.overrides = o
            let resolved = try b.resolve(target: t.name, configuration: parameters.configuration)
            var all = resolved.settings.all()
            all["ACTION"] = parameters.action
            return all
        }
    }
}
