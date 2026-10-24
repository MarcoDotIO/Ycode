import Foundation
import YcodeBuild

/// `XcodePIF` as the PIF source of YcodeBuild's swift-build engine, so the
/// IDE and ycodebuild send swift-build the same PIF (reference GUID scheme,
/// workspace path, every target kind). See `specs/ide/build-pif.md`.
public struct XcodePIFSource: PIFSource {
    public init() {}

    /// Loads a project (with its sub-projects) or a workspace.
    public static func container(for request: BuildRequest) throws -> Container {
        switch request.container {
        case .project(let path): return try ContainerLocator.loadProjectContainer(URL(fileURLWithPath: path).standardizedFileURL)
        case .workspace(let path): return try ContainerLocator.loadWorkspace(URL(fileURLWithPath: path).standardizedFileURL)
        case .package: throw XcodebuildFailure("packages use SwiftPM's PIF", exitCode: ExitCode.software)
        }
    }

    public func pif(for request: BuildRequest) throws -> (data: Data, targets: [String]) {
        let pif = XcodePIF(container: try Self.container(for: request))
        let targets = pif.objects().filter { $0["type"] as? String == "target" }
            .compactMap { ($0["contents"] as? [String: Any])?["name"] as? String }
        return (try pif.serialized(), targets)
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
