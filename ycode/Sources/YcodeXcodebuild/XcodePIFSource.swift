import Foundation
import YcodeBuild

/// `XcodePIF` as the PIF source of YcodeBuild's swift-build engine, so the
/// IDE and ycodebuild send swift-build the same PIF (reference GUID scheme,
/// workspace path, every target kind). See `specs/ide/build-pif.md`.
public struct XcodePIFSource: PIFSource {
    /// The `SourcePackages` folder (package checkouts, the generated package
    /// root); nil: `PackageGraphLoader.defaultSourcePackages(for:)`, the
    /// folder of the IDE's checkouts.
    public var sourcePackagesDirectory: URL?

    public init(sourcePackagesDirectory: URL? = nil) { self.sourcePackagesDirectory = sourcePackagesDirectory }

    /// Loads a project (with its sub-projects) or a workspace.
    public static func container(for request: BuildRequest) throws -> Container {
        switch request.container {
        case .project(let path): return try ContainerLocator.loadProjectContainer(URL(fileURLWithPath: path).standardizedFileURL)
        case .workspace(let path): return try ContainerLocator.loadWorkspace(URL(fileURLWithPath: path).standardizedFileURL)
        case .package: throw XcodebuildFailure("packages use SwiftPM's PIF", exitCode: ExitCode.software)
        }
    }

    /// The PIF of a request's container with its package graph: what the
    /// build sends to swift-build. Also the entry point for clients that ask
    /// swift-build about a target (compiler arguments for a build server):
    /// serialize it, and name targets by `XcodePIF.targetGUID(_:_:)`.
    public func makePIF(for request: BuildRequest) throws -> XcodePIF {
        let container = try Self.container(for: request)
        let dir = sourcePackagesDirectory ?? PackageGraphLoader.defaultSourcePackages(for: container.url)
        let packages = try PackageGraphLoader(container: container, sourcePackagesDirectory: dir).load()
        return XcodePIF(container: container, packages: packages)
    }

    public func pif(for request: BuildRequest) throws -> (data: Data, targets: [String]) {
        let (data, targets, _) = try pifWithWarnings(for: request)
        return (data, targets)
    }

    /// With the synchronized-folder warnings of each target
    /// (`XcodePIF.synchronizedFolderWarnings`).
    public func pifWithWarnings(for request: BuildRequest) throws -> (data: Data, targets: [String], warnings: [String: [String]]) {
        let pif = try makePIF(for: request)
        // The container's own targets (the build target is chosen by name).
        let targets = pif.container.projects.flatMap { $0.targets.filter { ProjectPIF.targetKind($0) != nil }.compactMap { $0.string("name") } }
        var warnings: [String: [String]] = [:]
        for p in pif.container.projects {
            for t in p.targets {
                let w = pif.synchronizedFolderWarnings(p, t)
                if !w.isEmpty { warnings[t.string("name") ?? "", default: []] += w }
            }
        }
        return (try pif.serialized(), targets, warnings)
    }

    /// Whether swift-build can build the request from this PIF (the IDE's
    /// `FallbackEngine` test): packages always; projects and workspaces that
    /// load, whose package products (if any) are all in the package graph,
    /// and that apply no build-tool plug-in to a project target.
    public static func supports(_ request: BuildRequest) -> Bool {
        if case .package = request.container { return true }
        guard let container = try? container(for: request) else { return false }
        return unsupportedFeatures(container).isEmpty
    }

    /// What the PIF cannot express for a container, one line per item.
    public static func unsupportedFeatures(_ container: Container) -> [String] {
        var out: [String] = []
        for p in container.projects {
            for t in p.targets {
                for d in t.references("dependencies") where p.proj[d]?.string("productRef") != nil {
                    let product = p.proj[d]?.string("productRef").flatMap { p.proj[$0]?.string("productName") } ?? ""
                    if product.hasPrefix("plugin:") && !ProjectPlugins.isSupported {
                        out.append("\(t.string("name") ?? ""): build-tool plug-in \(product.dropFirst("plugin:".count))")
                    }
                }
            }
        }
        return out
    }
}

/// Exported build settings from swift-build through the `ycode-swb`
/// helper, for YcodeBuild's `XcodebuildEngine.settingsSource` (so the IDE
/// does not run `xcodebuild -showBuildSettings`). Targets: all targets of
/// the container's projects, the scheme's target first when it names one.
public struct SwiftBuildSettingsSource: BuildSettingsSource {
    public var helper: String
    public init(helper: String) { self.helper = helper }

    /// `YCODE_SWB`, then `ycode-swb` on PATH.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        SwiftBuildSettingsProvider.locate(environment: environment, executableDirectory: nil)
    }

    public func buildSettings(for request: BuildRequest) throws -> [(target: String, settings: [String: String])] {
        let container = try XcodePIFSource.container(for: request)
        var targets = container.projects.flatMap { p in p.targets.map { SettingsTarget(project: p, target: $0) } }
        if let i = targets.firstIndex(where: { $0.name == request.scheme }) { targets.insert(targets.remove(at: i), at: 0) }
        let configuration = request.configuration ?? container.projects.first?.defaultConfigurationName ?? "Release"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        var parameters = BuildParameters(action: "build", configuration: configuration,
                                         arena: Arena.forContainer(container, derivedDataPath: request.derivedDataPath,
                                                                   derivedDataRoot: FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Developer/Xcode/DerivedData"),
                                         runDestination: .hostMac(architecture: arch), overrides: request.settings)
        parameters.synthesized = []
        let all = try SwiftBuildSettingsProvider(helper: helper).settings(container: container, targets: targets, parameters: parameters)
        return zip(targets, all).map { ($0.name, $1) }
    }
}
