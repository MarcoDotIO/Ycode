import Foundation
import YcodeBuild
import YcodeXcodebuild

/// Ycode ▸ Settings ▸ Locations ▸ Build System. See
/// `specs/ide/settings.md`.
public enum BuildSystemPreference: String, CaseIterable, Sendable {
    case xcodebuild
    case swiftBuild = "swift-build"

    public static let defaultsKey = "YcodeBuildSystem"
    /// The default engine: swift-build, now that it builds apps, tools and
    /// packages (it falls back to xcodebuild per request otherwise).
    public static let defaultValue: BuildSystemPreference = .swiftBuild

    public var title: String {
        switch self {
        case .xcodebuild: "xcodebuild"
        case .swiftBuild: "swift-build"
        }
    }

    public static func current(_ defaults: UserDefaults = .standard) -> BuildSystemPreference {
        defaults.string(forKey: defaultsKey).flatMap(BuildSystemPreference.init(rawValue:)) ?? defaultValue
    }

    public func save(_ defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.defaultsKey) }

    /// The engine for this preference. swift-build falls back to
    /// xcodebuild when `swbuild` cannot be found, and per request for
    /// containers it cannot describe yet.
    /// xcodebuild for building; its product lookup uses swift-build's
    /// settings through `ycode-swb` when that helper is available.
    static func xcodebuildEngine() -> XcodebuildEngine {
        var e = XcodebuildEngine()
        if let helper = SwiftBuildSettingsSource.locate() { e.settingsSource = SwiftBuildSettingsSource(helper: helper) }
        return e
    }

    public func makeEngine(locateSwiftBuild: () -> String? = { SwiftBuildEngine.locate() }) -> BuildEngine {
        switch self {
        case .xcodebuild: return Self.xcodebuildEngine()
        case .swiftBuild:
            guard let tool = locateSwiftBuild() else { return Self.xcodebuildEngine() }
            // The PIF comes from YcodeXcodebuild's XcodePIF (the reference
            // GUID scheme, every target kind), shared with ycodebuild.
            var engine = SwiftBuildEngine(swbuild: tool)
            engine.pifSource = XcodePIFSource()
            return FallbackEngine(primary: engine, fallback: Self.xcodebuildEngine(), supports: XcodePIFSource.supports)
        }
    }
}
