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
}
