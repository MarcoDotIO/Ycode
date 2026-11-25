import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeIDEShell
import YcodeProject

/// P-120 in the Linux IDE's model (`specs/ide/issues.md`): the live warning
/// before any build (capsule counts, the project row, the stepper's kind);
/// the row shows the checklist; the stepper only selects it; Cancel writes
/// nothing; Perform Changes writes only the checked settings.
@MainActor
@Suite(.serialized) struct RecommendedSettingsShellTests {
    /// A one-target project (a command-line tool), written in Ycode's
    /// writer's layout.
    func project() throws -> (dir: URL, project: URL, file: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-p120-\(UUID().uuidString)")
        let project = dir.appendingPathComponent("Tool.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Tool"), withIntermediateDirectories: true)
        try "print(1)\n".write(to: dir.appendingPathComponent("Tool/main.swift"), atomically: true, encoding: .utf8)
        let text = """
        // !$*UTF8*$!
        {
        archiveVersion = 1; classes = {}; objectVersion = 77;
        objects = {
        D10000000000000000000001 = {isa = PBXBuildFile; fileRef = D10000000000000000000002; };
        D10000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = main.swift; sourceTree = "<group>"; };
        D10000000000000000000004 = {isa = PBXGroup; children = (D10000000000000000000005); sourceTree = "<group>"; };
        D10000000000000000000005 = {isa = PBXGroup; children = (D10000000000000000000002); path = Tool; sourceTree = "<group>"; };
        D10000000000000000000007 = {isa = PBXNativeTarget; buildConfigurationList = D10000000000000000000008; buildPhases = (D10000000000000000000009); buildRules = (); dependencies = (); name = Tool; productName = Tool; productType = "com.apple.product-type.tool"; };
        D10000000000000000000008 = {isa = XCConfigurationList; buildConfigurations = (D1000000000000000000000A, D1000000000000000000000B); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        D10000000000000000000009 = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (D10000000000000000000001); runOnlyForDeploymentPostprocessing = 0; };
        D1000000000000000000000A = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Debug; };
        D1000000000000000000000B = {isa = XCBuildConfiguration; buildSettings = {PRODUCT_NAME = "$(TARGET_NAME)"; }; name = Release; };
        D1000000000000000000000C = {isa = PBXProject; buildConfigurationList = D1000000000000000000000D; mainGroup = D10000000000000000000004; targets = (D10000000000000000000007); };
        D1000000000000000000000D = {isa = XCConfigurationList; buildConfigurations = (D1000000000000000000000E, D1000000000000000000000F); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
        D1000000000000000000000E = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; }; name = Debug; };
        D1000000000000000000000F = {isa = XCBuildConfiguration; buildSettings = {SDKROOT = macosx; }; name = Release; };
        };
        rootObject = D1000000000000000000000C;
        }
        """
        let file = project.appendingPathComponent("project.pbxproj")
        try PBXProj(parsing: text).serialized(projectName: "Tool").write(to: file, atomically: true, encoding: .utf8)
        return (dir, project, file)
    }

    func model(_ project: URL) throws -> WorkspaceShellModel {
        try WorkspaceShellModel(url: project, engine: ScriptedEngine(lines: [], issues: []))
    }

    @Test func theLiveWarningShowsBeforeABuild() throws {
        let (dir, project, _) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = try model(project)
        #expect(m.issueCounts.warnings == 1 && m.issueCounts.errors == 0)
        #expect(m.issueSummary.parts.map(\.count) == [1])
        #expect(IssueStepper.kind(errors: m.issueCounts.errors, warnings: m.issueCounts.warnings) == .warning)
        let group = try #require(m.issueGroups.first)
        #expect(group.title == "Tool" && group.countText == "1 issue" && group.files.isEmpty)
        #expect(group.issues.map(\.message) == ["Update to recommended settings"] && group.issues.first?.severity == .warning)
        // The stepper selects the row without the sheet.
        m.stepIssue(forward: true)
        #expect(m.issueSelection == group.issues.first?.id && !m.recommendedSettings.isShown)
    }

    @Test func theRowShowsTheChecklistAndCancelWritesNothing() throws {
        let (dir, project, file) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try String(contentsOf: file, encoding: .utf8)
        let m = try model(project)
        m.issueSelection = m.allIssues.first?.id
        let list = try #require(m.recommendedSettings.checklist)
        #expect(list.groups == [.buildSettings])
        #expect(list.changes.map(\.title).first == "Target 'Tool' - Enable Weak References in Manual Retain Release")
        #expect(list.chosen.count == list.changes.count)
        m.recommendedSettings.cancel()
        #expect(!m.recommendedSettings.isShown)
        #expect(try String(contentsOf: file, encoding: .utf8) == before)
    }

    @Test func performChangesWritesTheCheckedSettings() throws {
        let (dir, project, file) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = try String(contentsOf: file, encoding: .utf8)
        let m = try model(project)
        #expect(m.showRecommendedSettings())
        m.recommendedSettings.toggle(rowID: "warnings")
        #expect(m.recommendedSettings.checklist?.state(of: .buildSettings) == .mixed)
        m.recommendedSettings.perform(m.session)
        #expect(!m.recommendedSettings.isShown && m.recommendedSettings.lastError == nil)
        let after = try String(contentsOf: file, encoding: .utf8)
        var pool = before.components(separatedBy: "\n")
        let added = after.components(separatedBy: "\n").filter { l in
            if let i = pool.firstIndex(of: l) { pool.remove(at: i); return false }
            return true
        }
        #expect(pool.isEmpty, "nothing removed: \(pool)")
        // The checked rows' eight settings and the running version in
        // LastUpgradeCheck (`issues.md` §1 item 5, §8 item 8); the
        // unchecked warnings row wrote nothing.
        #expect(added.filter { $0.contains(" = YES;") }.count == 8, "\(added)")
        #expect(!added.contains { $0.contains("_WARN_") })
        #expect(added.contains { $0.contains("LastUpgradeCheck = \(RecommendedSettings.ideVersionDigits);") }, "\(added)")
        // The project is current now: the warning goes, and the unchecked
        // row is not offered again by this version.
        #expect(m.issueCounts.warnings == 0 && m.issueGroups.isEmpty)
        #expect(!m.showRecommendedSettings())
    }
}
