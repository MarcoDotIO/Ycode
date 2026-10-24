import Foundation
import YcodeProject
import YcodeWorkspace
import YcodeSettings

/// `-version`, `-showsdks`, `-list`, `-showdestinations`, `-showTestPlans`.
/// See `specs/xcodebuild/info-commands.md`.
enum InfoCommands {
    static var versionText: String { "\(YcodeVersion.product) \(YcodeVersion.version)\nBuild version \(YcodeVersion.build)" }

    static func version(_ inv: Invocation, sdks: SDKRegistry, context ctx: XcodebuildContext) throws(XcodebuildFailure) -> Int32 {
        let console = ctx.console
        guard inv.sdk != nil || inv.sdkWithoutValue else {
            console.out(versionText)
            return 0
        }
        var selected = sdks.entries
        if let name = inv.sdk {
            guard let e = sdks.lookup(name, relativeTo: ctx.cwd) else {
                throw XcodebuildFailure("SDK \"\(name)\" cannot be located.", exitCode: ExitCode.usage)
            }
            selected = [e]
        }
        if inv.json {
            console.out(JSONText.render(selected.map(\.json)))
            return 0
        }
        if let item = inv.infoItems.first, inv.sdk != nil {
            if let v = selected.first?.infoLines.first(where: { $0.key == item })?.value { console.out(v) }
            return 0
        }
        for e in selected {
            console.out(SDKRegistry.versionBlock(e))
            console.out()
        }
        if inv.sdk == nil { console.out(versionText) }
        return 0
    }

    static func showsdks(_ inv: Invocation, sdks: SDKRegistry, context ctx: XcodebuildContext) -> Int32 {
        if inv.json { ctx.console.out(JSONText.render(sdks.entries.map(\.json))) } else { ctx.console.rawOut(sdks.showsdksText() + "\n") }
        return 0
    }

    static func list(_ inv: Invocation, container: Container, context ctx: XcodebuildContext) -> Int32 {
        let console = ctx.console
        let schemes = container.schemes(user: ctx.user).map(\.name)
        switch container.kind {
        case .project:
            guard let p = container.mainProject else { return 0 }
            let targets = p.targetNames
            if inv.json {
                console.out(JSONText.render(["project": ["name": p.name, "targets": targets, "configurations": p.configurationNames, "schemes": schemes]]))
                return 0
            }
            console.out("Information about project \"\(p.name)\":")
            console.out("    Targets:")
            for t in targets { console.out("        " + t) }
            console.out()
            console.out("    Build Configurations:")
            for c in p.configurationNames { console.out("        " + c) }
            console.out()
            console.out("    If no build configuration is specified and -scheme is not passed then \"\(p.defaultConfigurationName)\" is used.")
            console.out()
            if schemes.isEmpty {
                console.out("    This project contains no schemes.")
            } else {
                console.out("    Schemes:")
                for s in schemes { console.out("        " + s) }
            }
            console.out()
        case .workspace:
            if inv.json {
                console.out(JSONText.render(["workspace": ["name": container.name, "schemes": schemes]]))
                return 0
            }
            console.out("Information about workspace \"\(container.name)\":")
            console.out("    Schemes:")
            for s in schemes { console.out("        " + s) }
            console.out()
        }
        return 0
    }

    /// Platforms the plan's targets build for (raw `SUPPORTED_PLATFORMS`,
    /// else the platform of `SDKROOT`).
    static func supportedPlatforms(_ plan: Plan, context ctx: XcodebuildContext) -> Set<String> {
        var out: Set<String> = []
        let catalog = ctx.developerDirectory.map { SDKCatalog(developerDirectory: $0) }
        for t in plan.targets {
            var b = ProjectSettingsBuilder(proj: t.project.proj, xcodeprojURL: t.project.url)
            b.developerDirectory = ctx.developerDirectory
            guard let r = try? b.resolve(target: t.name, configuration: plan.configuration) else { continue }
            let supported = r.settings["SUPPORTED_PLATFORMS"].split(separator: " ").map(String.init)
            if !supported.isEmpty { out.formUnion(supported); continue }
            let sdkroot = r.settings["SDKROOT"]
            let base = catalog?.lookup(sdkroot)?.canonicalName.prefix { !$0.isNumber }.description ?? sdkroot
            if !base.isEmpty { out.insert(base) }
            // A device SDK implies its simulator.
            let sims = ["iphoneos": "iphonesimulator", "appletvos": "appletvsimulator", "watchos": "watchsimulator", "xros": "xrsimulator"]
            if let s = sims[base] { out.insert(s) }
        }
        return out.isEmpty ? ["macosx"] : out
    }

    static func showdestinations(_ inv: Invocation, plan: Plan, context ctx: XcodebuildContext) -> Int32 {
        let name = plan.scheme?.name ?? ""
        let subject = plan.scheme?.buildEntries.first?.reference.buildableName ?? name
        let (compatible, incompatible) = Destinations.listing(subject: subject, supportedPlatforms: supportedPlatforms(plan, context: ctx), context: ctx)
        let console = ctx.console
        console.out()
        console.out()
        console.out("\tDestinations compatible with the \"\(name)\" scheme:")
        for c in compatible { console.out("\t\t" + c) }
        if !incompatible.isEmpty {
            console.out()
            console.out("\tDestinations incompatible with the \"\(name)\" scheme:")
            for c in incompatible { console.out("\t\t" + c) }
        }
        return 0
    }

    static func showTestPlans(_ inv: Invocation, plan: Plan, context ctx: XcodebuildContext) -> Int32 {
        guard let scheme = plan.scheme else { return 0 }
        let names = scheme.testPlans.map { URL(fileURLWithPath: $0.reference).deletingPathExtension().lastPathComponent }
        ctx.console.out("Test plans associated with the scheme \"\(scheme.name)\":")
        for n in names.isEmpty ? [scheme.name] : names { ctx.console.out("        " + n) }
        return 0
    }
}
