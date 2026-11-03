import Foundation
import YcodeBuild
import YcodeProject
import YcodeWorkspace

/// Watch apps and their companion iOS apps in a project (`specs/simulator/device-pairing.md`
/// P-9, §13; `watchos.md` §8): the facts of the project file that a run on a
/// phone with a paired watch needs. An iOS app *embeds* a watch app when it
/// depends on the watch app's target and copies its product into
/// `$(CONTENTS_FOLDER_PATH)/Watch` (the layout of §5, `<iOS app>/Watch/<watch app>.app`).
public enum WatchCompanion {
    /// The target a scheme builds and runs: a scheme file's launch target,
    /// else its first build entry; a scheme without a file is the target of
    /// its name (the scheme Ycode autocreates per target).
    public static func targetName(scheme: String, schemes: [Scheme]) -> String {
        guard let s = schemes.first(where: { $0.name == scheme }) else { return scheme }
        return s.launchTarget?.blueprintName ?? s.buildEntries.first?.reference.blueprintName ?? scheme
    }

    /// A target object by name.
    static func target(named name: String, in proj: PBXProj) -> PBXObject? { proj.targets.first { $0.string("name") == name } }

    /// The platforms a target supports (its `SUPPORTED_PLATFORMS`, else its
    /// `SDKROOT`; the project's settings when the target has none).
    public static func platforms(ofTarget name: String, in proj: PBXProj) -> Set<String> {
        guard let t = target(named: name, in: proj) else { return [] }
        func value(_ listID: String?, _ key: String) -> String? {
            proj.buildConfigurations(listID: listID).lazy.compactMap { $0.attributes["buildSettings"]?.dictionary?[key]?.string }.first
        }
        let tl = t.string("buildConfigurationList"), pl = proj.project?.string("buildConfigurationList")
        return DestinationMenuModel.platforms(supportedPlatforms: value(tl, "SUPPORTED_PLATFORMS") ?? value(pl, "SUPPORTED_PLATFORMS"),
                                              sdkroot: value(tl, "SDKROOT") ?? value(pl, "SDKROOT"))
    }

    /// A target's deployment target for a platform (`WATCHOS_DEPLOYMENT_TARGET`, …).
    public static func deploymentTarget(ofTarget name: String, platform: String, in proj: PBXProj) -> String? {
        guard let t = target(named: name, in: proj), let key = DestinationCatalog.deploymentTargetSetting(platform) else { return nil }
        func value(_ listID: String?) -> String? {
            proj.buildConfigurations(listID: listID).lazy.compactMap { $0.attributes["buildSettings"]?.dictionary?[key]?.string }.first
        }
        return value(t.string("buildConfigurationList")) ?? value(proj.project?.string("buildConfigurationList"))
    }

    /// The application targets that embed `watchTarget`: they depend on it
    /// and have a copy-files phase into a `Watch` folder of their contents
    /// that copies its product.
    public static func companionTargets(of watchTarget: String, in proj: PBXProj) -> [String] {
        guard let watch = target(named: watchTarget, in: proj) else { return [] }
        let product = watch.string("productReference")
        return proj.targets.compactMap { t -> String? in
            guard t.id != watch.id, t.string("productType") == "com.apple.product-type.application" else { return nil }
            let depends = t.references("dependencies").contains { proj[$0]?.string("target") == watch.id }
            let copies = t.references("buildPhases").contains { id in
                guard let phase = proj[id], phase.isa == "PBXCopyFilesBuildPhase",
                      (phase.string("dstPath") ?? "").hasSuffix("/Watch") else { return false }
                return phase.references("files").contains { proj[$0]?.string("fileRef") == product }
            }
            return depends && copies ? t.string("name") : nil
        }
    }

    /// The scheme that builds a target: a scheme file whose launch target
    /// or a build entry is it, else the target's own name.
    public static func scheme(forTarget name: String, schemes: [Scheme]) -> String {
        schemes.first { $0.launchTarget?.blueprintName == name }?.name
            ?? schemes.first { $0.buildEntries.contains { $0.reference.blueprintName == name } && $0.buildEntries.count == 1 }?.name
            ?? name
    }

    /// The companion iOS app's scheme of a watch app's scheme (P-9: a run on
    /// a phone with a paired watch builds and installs the iOS app with its
    /// embedded watch app); nil when no target embeds the watch app.
    public static func companionScheme(watchScheme: String, projects: [PBXProj], schemes: [Scheme]) -> String? {
        let name = targetName(scheme: watchScheme, schemes: schemes)
        for proj in projects {
            if let c = companionTargets(of: name, in: proj).first { return scheme(forTarget: c, schemes: schemes) }
        }
        return nil
    }
}

extension WorkspaceModel {
    /// The companion iOS app scheme of a watch app scheme (`WatchCompanion`).
    public func companionScheme(watchScheme: String) -> String? {
        WatchCompanion.companionScheme(watchScheme: watchScheme, projects: projects.keys.sorted().compactMap { projects[$0] }, schemes: loadSchemes())
    }

    /// The platforms of a scheme's target (empty when it is not found).
    public func platforms(scheme: String) -> Set<String> {
        let name = WatchCompanion.targetName(scheme: scheme, schemes: loadSchemes())
        for key in projects.keys.sorted() {
            let p = WatchCompanion.platforms(ofTarget: name, in: projects[key]!)
            if !p.isEmpty { return p }
        }
        return []
    }
}
