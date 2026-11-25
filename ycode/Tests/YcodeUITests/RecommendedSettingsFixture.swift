import Foundation
import YcodeProject

/// Test fixtures that stand for current projects: their project files
/// record the running IDE version in `LastUpgradeCheck`, as a project made
/// or updated by this version does, so the "Update to recommended settings"
/// warning (P-120, `specs/ide/issues.md` §1 item 5), which is right for an
/// older hand-written project, does not crowd the issue lists, capsules
/// and jump bars that the tests check for something else. The check
/// itself is unchanged.
enum RecommendedSettingsFixture {
    /// Every `.xcodeproj` at `url` (a project, or a folder holding them).
    static func bringUpToDate(_ url: URL) throws {
        let fm = FileManager.default
        let projects = url.pathExtension == "xcodeproj" ? [url]
            : try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).filter { $0.pathExtension == "xcodeproj" }
        for x in projects {
            var proj = try PBXProj(contentsOf: x)
            guard RecommendedSettings.isCheckDue(proj) else { continue }
            RecommendedSettings.markUpgradeChecked(&proj)
            try proj.serialized(projectName: x.deletingPathExtension().lastPathComponent)
                .write(to: x.appendingPathComponent("project.pbxproj"), atomically: true, encoding: .utf8)
        }
    }
}
