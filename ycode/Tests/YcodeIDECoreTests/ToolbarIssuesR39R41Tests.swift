import Foundation
import Testing
import YcodeBuild
@testable import YcodeIDECore

private let ycodeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// reference-ui-6.md rounds R39 (toolbar layout and activity view, §2–§3)
/// and R41 (Issue navigator grouping and merging, §5.1–§5.2).
@MainActor
@Suite(.serialized) struct ToolbarIssuesR39R41Tests {
    func scratch(_ name: String) -> URL {
        ycodeDir.appendingPathComponent(".build-ide/r39/\(name)-\(UUID().uuidString)")
    }

    /// Package workspaces group by the package's targets (§5.1).
    @Test func packageIssuesGroupByPackageTarget() throws {
        let dir = scratch("n1-pkg")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        for t in ["Sources/Kit", "Sources/Tool", "Tests/KitTests"] {
            try fm.createDirectory(at: dir.appendingPathComponent(t), withIntermediateDirectories: true)
        }
        try "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"Kit\")\n"
            .write(to: dir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let session = WorkspaceSession(model: try WorkspaceModel(url: dir))
        let g = session.issueGrouping
        #expect(g.projectName == dir.lastPathComponent && g.targetOrder == ["Kit", "Tool", "KitTests"])
        #expect(g.targetsOfFile(dir.appendingPathComponent("Tests/KitTests/KitTests.swift").path) == ["KitTests"])
        #expect(g.targetsOfFile(dir.appendingPathComponent("Package.swift").path).isEmpty)
    }

    @Test func toolbarFitSteps() {
        let steps = ToolbarFit.steps(schemeNatural: 200, activityNatural: 150)
        #expect(steps.first == ToolbarFit() && steps[1] == ToolbarFit(editorModesCollapsed: true))
        let schemeCaps = steps.compactMap(\.schemeWidth)
        #expect(!schemeCaps.isEmpty && schemeCaps.first! < 200 && schemeCaps.last == ToolbarFit.schemeMinimum)
        #expect(schemeCaps == schemeCaps.sorted(by: >))
        #expect(steps.last?.activityWidth == ToolbarFit.activityMinimum && steps.last?.schemeWidth == ToolbarFit.schemeMinimum)
        // Activity caps only after the scheme reached its minimum.
        #expect(steps.filter { $0.activityWidth != nil }.allSatisfy { $0.schemeWidth == ToolbarFit.schemeMinimum })
        #expect(ToolbarFit.steps(schemeNatural: 40, activityNatural: 60) == [ToolbarFit(), ToolbarFit(editorModesCollapsed: true)])
    }
}
