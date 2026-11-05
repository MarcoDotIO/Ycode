import Foundation

/// `-showBuildSettings [-json]`. See `specs/xcodebuild/show-build-settings.md`.
enum ShowBuildSettings {
    /// The provider to use: the context's, else swift-build through the
    /// helper, else Ycode's own resolver (with a warning).
    static func provider(_ ctx: XcodebuildContext) -> SettingsProvider {
        if let p = ctx.settingsProvider { return p }
        if let helper = SwiftBuildSettingsProvider.locate(environment: ctx.environment, executableDirectory: ctx.executableDirectory) {
            return SwiftBuildSettingsProvider(helper: helper)
        }
        ctx.console.err("ycodebuild: warning: the ycode-swb helper was not found (set YCODE_SWB); showing only project-defined settings")
        return ResolverSettingsProvider(developerDirectory: ctx.developerDirectory)
    }

    static func run(_ inv: Invocation, plan: inout Plan, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let action = plan.actions.first ?? .build
        let all: [[String: String]]
        do {
            all = try provider(ctx).settings(container: plan.container, targets: plan.targets, parameters: plan.parameters(action: action))
        } catch {
            throw XcodebuildFailure("Could not resolve build settings: \(error)", exitCode: ExitCode.software)
        }
        let console = ctx.console
        #if !os(macOS)
        for w in unavailableSDKWarnings(all) { console.err(w) }
        #endif
        if inv.json {
            let list: [[String: Any]] = zip(plan.targets, all).map { t, s in
                ["action": action.rawValue, "target": t.name, "buildSettings": s]
            }
            console.out(JSONText.render(list))
            return 0
        }
        for (t, s) in zip(plan.targets, all) {
            console.out("Build settings for action \(action.rawValue) and target \(ShellQuote.quote(t.name)):")
            for k in s.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                console.out("    \(k) = \(s[k]!)")
            }
            console.out()
        }
        return 0
    }

    /// One warning per `SDKROOT` that swift-build could not resolve to an
    /// installed SDK (it stays a name, and `SDK_NAME` is missing), and one
    /// when the Xcode version settings are swift-build's placeholders (a
    /// session on a Swift toolchain, not a developer directory). On Linux that
    /// is every Apple-platform project: their SDKs exist only on a Mac (§5.1).
    static func unavailableSDKWarnings(_ all: [[String: String]]) -> [String] {
        var seen: Set<String> = []
        var warnings: [String] = []
        for s in all {
            guard let sdk = s["SDKROOT"], !sdk.isEmpty, !sdk.hasPrefix("/"), (s["SDK_NAME"] ?? "").isEmpty,
                  seen.insert(sdk).inserted else { continue }
            warnings.append("ycodebuild: warning: the SDK \"\(sdk)\" is not installed on this computer. "
                + "Settings that come from the SDK and its platform (ARCHS, SDK_NAME, SDK_VERSION, PLATFORM_NAME, "
                + "the bundle layout such as EXECUTABLE_PATH and WRAPPER_EXTENSION, and the SDK's defaults) are left out, "
                + "and build folders end in \"-unknown\".")
        }
        if all.contains(where: { $0["XCODE_PRODUCT_BUILD_VERSION"] == placeholderBuildVersion }) {
            warnings.append("ycodebuild: warning: there is no Xcode on this computer: XCODE_VERSION_ACTUAL, XCODE_VERSION_MAJOR, "
                + "XCODE_VERSION_MINOR and XCODE_PRODUCT_BUILD_VERSION are swift-build's placeholders (\(placeholderBuildVersion)).")
        }
        return warnings
    }

    /// swift-build's Xcode build version for a session on a Swift toolchain.
    static let placeholderBuildVersion = "99T999"
}
