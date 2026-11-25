import Foundation
import Testing
import YcodePlist
@testable import YcodeProject

/// Ycode's project validation and Perform Changes (`specs/ide/issues.md`
/// §5, §6, §8; P-120).
@Suite struct RecommendedSettingsTests {
    func fixture() throws -> (text: String, proj: PBXProj) {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/Hello.xcodeproj/project", withExtension: "pbxproj"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return (text, try PBXProj(parsing: text))
    }

    /// Lines of `b` that are not in `a` (a multiset difference).
    func addedLines(_ a: String, _ b: String) -> [String] {
        var pool = a.components(separatedBy: "\n")
        return b.components(separatedBy: "\n").filter { line in
            if let i = pool.firstIndex(of: line) { pool.remove(at: i); return false }
            return true
        }
    }

    func projectConfigs(_ p: PBXProj) -> [PBXObject] { p.buildConfigurations(listID: p.project?.string("buildConfigurationList")) }

    /// §5: one row per target and configuration, then the project's rows, in
    /// the reference's order and wording (hyphen and em-dash as recorded).
    @Test func rowsFollowTheSpecsOrderAndWording() throws {
        let (_, proj) = try fixture()
        let changes = RecommendedSettings.changes(in: proj, projectName: "Hello")
        #expect(changes.map(\.title) == [
            "Target 'Hello' - Enable Weak References in Manual Retain Release",
            "Target 'Hello' - Enable Weak References in Manual Retain Release",
            "Target 'Hello' \u{2014} Enable Dead Code Stripping",
            "Project 'Hello' - Enable Recommended Warnings",
            "Project 'Hello' \u{2014} Enable Dead Code Stripping",
            "Enable User Script Sandboxing",
        ])
        #expect(changes.allSatisfy { $0.group == .buildSettings && $0.isCheckedByDefault })
        #expect(changes[0].explanation.hasSuffix("for the \"Debug\" configuration.") && changes[1].explanation.hasSuffix("for the \"Release\" configuration."))
        #expect(changes[0].explanation.contains("CLANG_ENABLE_OBJC_WEAK"))
        #expect(changes[2].explanation == "Enabling dead code stripping is recommended. This will update the DEAD_CODE_STRIPPING build setting.")
        #expect(changes[3].explanation == "This will enable the following recommended compiler warnings:")
        #expect(Array(changes[3].bullets.prefix(2)) == ["Block Capture of Autoreleasing", "Duplicate Method Definitions"])
        #expect(changes[3].bullets.count == RecommendedSettings.recommendedWarnings.count)
        #expect(changes[5].explanation.contains("ENABLE_USER_SCRIPT_SANDBOXING"))
        // No catalogs in this project: no Asset Catalog or Localization rows.
        #expect(!changes.contains { $0.group != .buildSettings })
        // Texts name build settings, never the reference product.
        #expect(!changes.contains { ($0.title + $0.explanation).contains("Xcode") })
    }

    /// Perform Changes with every row: only the named keys are added (the
    /// round trip keeps every other byte), and the check then finds nothing.
    @Test func performingEveryChangeAddsOnlyThoseKeys() throws {
        var (text, proj) = try fixture()
        let changes = RecommendedSettings.changes(in: proj, projectName: "Hello")
        // Writing the untouched project reproduces the file.
        #expect(proj.serialized(projectName: "Hello") == text)
        RecommendedSettings.apply(changes, to: &proj)
        let edited = proj.serialized(projectName: "Hello")
        let keys = Set(changes.flatMap(\.edits).map(\.key))
        let added = addedLines(text, edited)
        // The rows' keys, and the running version in LastUpgradeCheck (§1 item 5).
        #expect(added.count == changes.flatMap(\.edits).count + 1)
        #expect(added.filter { $0.contains("LastUpgradeCheck = \(RecommendedSettings.ideVersionDigits);") }.count == 1)
        #expect(added.filter { !$0.contains("LastUpgradeCheck") }.allSatisfy { line in keys.contains { line.contains("\($0) = YES") } })
        #expect(addedLines(edited, text).isEmpty, "nothing was removed or rewritten")
        let again = try PBXProj(parsing: edited)
        #expect(RecommendedSettings.changes(in: again, projectName: "Hello").isEmpty)
        #expect(!RecommendedSettings.needsUpdate(again, projectName: "Hello"))
        // The stricter values are written as the templates have them.
        let debug = try #require(projectConfigs(again).first { $0.string("name") == "Debug" })
        #expect(debug["buildSettings"]?.dictionary?["CLANG_WARN_OBJC_ROOT_CLASS"] == "YES_ERROR")
        #expect(debug["buildSettings"]?.dictionary?["GCC_WARN_UNINITIALIZED_AUTOS"] == "YES_AGGRESSIVE")
    }

    /// Unchecked rows are not written; the rest of the file stays.
    @Test func performingSomeChangesWritesOnlyThose() throws {
        var (text, proj) = try fixture()
        let changes = RecommendedSettings.changes(in: proj, projectName: "Hello")
        let strip = changes.filter { $0.title.hasSuffix("Enable Dead Code Stripping") }
        RecommendedSettings.apply(strip, to: &proj)
        let added = addedLines(text, proj.serialized(projectName: "Hello"))
        #expect(added.count == 5 && added.filter { $0.contains("DEAD_CODE_STRIPPING = YES;") }.count == 4)
        #expect(added.contains { $0.contains("LastUpgradeCheck = \(RecommendedSettings.ideVersionDigits);") })
        // The project is now current: no warning, though the unchecked rows
        // still differ from the set.
        #expect(RecommendedSettings.changes(in: proj, projectName: "Hello").isEmpty)
        let left = RecommendedSettings.changes(in: proj, projectName: "Hello", gated: false)
        #expect(left.map(\.id) == changes.map(\.id).filter { !$0.hasPrefix("strip|") })
        // Applying nothing changes nothing (Cancel).
        var untouched = try fixture().proj
        RecommendedSettings.apply([], to: &untouched)
        #expect(untouched.serialized(projectName: "Hello") == text)
    }

    /// §8: a target inherits the project's value; `YES_ERROR` and
    /// `YES_AGGRESSIVE` count as set; a key left to an `.xcconfig` is not
    /// judged.
    @Test func inheritedStricterAndXcconfigValuesCount() throws {
        var (_, proj) = try fixture()
        let project = try #require(proj.project)
        proj.setBuildSetting("CLANG_ENABLE_OBJC_WEAK", "YES", inListOf: project.id)
        proj.setBuildSetting("DEAD_CODE_STRIPPING", "YES_ERROR", inListOf: project.id)
        var titles = RecommendedSettings.changes(in: proj, projectName: "Hello").map(\.title)
        #expect(!titles.contains { $0.contains("Weak References") || $0.contains("Dead Code") })
        // A target that turns it off is flagged again.
        let target = try #require(proj.targets.first)
        proj.setBuildSetting("DEAD_CODE_STRIPPING", "NO", inListOf: target.id)
        titles = RecommendedSettings.changes(in: proj, projectName: "Hello").map(\.title)
        #expect(titles.contains("Target 'Hello' \u{2014} Enable Dead Code Stripping"))
        // Sandboxing from an xcconfig: not judged.
        for c in projectConfigs(proj) {
            var o = c
            o["baseConfigurationReference"] = "0B0000000000000000000099"
            proj[c.id] = o
        }
        #expect(!RecommendedSettings.changes(in: proj, projectName: "Hello").contains { $0.id == "sandboxing" })
    }

    /// §5: the Asset Catalog row (unchecked) and the Localization row appear
    /// when the project holds the catalogs, and write project-level keys.
    @Test func catalogRowsNeedTheirCatalogs() throws {
        var (_, proj) = try fixture()
        let main = try #require(proj.project?.string("mainGroup"))
        proj.addFileReference(path: "Assets.xcassets", to: main)
        proj.addFileReference(path: "Localizable.xcstrings", to: main)
        let changes = RecommendedSettings.changes(in: proj, projectName: "Hello")
        let asset = try #require(changes.first)
        #expect(asset.group == .assetCatalog && asset.title == "Enable Generated Asset Symbol Extensions" && !asset.isCheckedByDefault)
        #expect(asset.explanation == "Generate asset symbol extensions on Apple framework color and image types.")
        let strings = try #require(changes.last)
        #expect(strings.group == .localization && strings.title == "Project 'Hello' \u{2014} Enable String Catalog Symbol Generation")
        #expect(strings.edits.map(\.key) == ["STRING_CATALOG_GENERATE_SYMBOLS", "STRING_CATALOG_GENERATE_SYMBOLS"])
        #expect(Set(strings.edits.map(\.configurationID)) == Set(projectConfigs(proj).map(\.id)))
    }

    /// A synchronized folder's catalogs count too (found on disk).
    @Test func catalogsInSynchronizedFoldersCount() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-recsettings-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("App/Resources/Media.xcassets"), withIntermediateDirectories: true)
        var (_, proj) = try fixture()
        let main = try #require(proj.project?.string("mainGroup"))
        let id = proj.makeObjectID()
        proj[id] = PBXObject(id: id, attributes: PlistDictionary([("isa", "PBXFileSystemSynchronizedRootGroup"), ("path", "App"), ("sourceTree", "<group>")]))
        if var g = proj[main] {
            g["children"] = .array((g["children"]?.array ?? []) + [.string(id)])
            proj[main] = g
        }
        #expect(!RecommendedSettings.changes(in: proj, projectName: "Hello").contains { $0.group == .assetCatalog })
        let groups = RecommendedSettings.changes(in: proj, projectName: "Hello", projectDirectory: dir).map(\.group)
        #expect(groups.first == .assetCatalog && !groups.contains(.localization))
    }

    /// §1 item 5: the check is gated by `LastUpgradeCheck`. An older
    /// version (2700, as the projects that warned in 27.1) or none: the rows
    /// that apply are offered; the running version: none, whatever is
    /// missing.
    @Test func lastUpgradeCheckGatesTheCheck() throws {
        var (_, proj) = try fixture()
        #expect(RecommendedSettings.lastUpgradeCheck(proj) == nil && RecommendedSettings.isCheckDue(proj))
        RecommendedSettings.markUpgradeChecked(&proj, ideVersion: "2700")
        #expect(RecommendedSettings.lastUpgradeCheck(proj) == "2700" && RecommendedSettings.isCheckDue(proj))
        let rows = RecommendedSettings.changes(in: proj, projectName: "Hello")
        #expect(rows.contains { $0.title == "Project 'Hello' \u{2014} Enable Dead Code Stripping" })
        #expect(RecommendedSettings.needsUpdate(proj, projectName: "Hello"))
        RecommendedSettings.markUpgradeChecked(&proj)
        #expect(!RecommendedSettings.isCheckDue(proj))
        #expect(RecommendedSettings.changes(in: proj, projectName: "Hello").isEmpty)
        #expect(!RecommendedSettings.needsUpdate(proj, projectName: "Hello"))
        #expect(RecommendedSettings.changes(in: proj, projectName: "Hello", gated: false).map(\.id) == rows.map(\.id))
        // A newer version than the running one is not checked either.
        RecommendedSettings.markUpgradeChecked(&proj, ideVersion: "2800")
        #expect(!RecommendedSettings.isCheckDue(proj))
    }

    /// A project with the recommended settings (the new-project template's
    /// set plus dead-code stripping) reports nothing.
    @Test func aProjectWithTheRecommendedSetIsClean() throws {
        var (_, proj) = try fixture()
        let project = try #require(proj.project)
        for w in RecommendedSettings.recommendedWarnings { proj.setBuildSetting(w.key, .string(w.value), inListOf: project.id) }
        for k in ["CLANG_ENABLE_OBJC_WEAK", "DEAD_CODE_STRIPPING", "ENABLE_USER_SCRIPT_SANDBOXING"] { proj.setBuildSetting(k, "YES", inListOf: project.id) }
        #expect(RecommendedSettings.changes(in: proj, projectName: "Hello").isEmpty)
    }
}
