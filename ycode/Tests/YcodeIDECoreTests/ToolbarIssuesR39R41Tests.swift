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

    /// liquid-glass.md §8.2: the scheme capsule drops its titles, then the
    /// editor modes may stay in the "»" overflow, then the subtitle
    /// shortens down to its minimum.
    @Test func toolbarFitSteps() {
        let steps = ToolbarFit.steps(activityNatural: 150)
        #expect(steps.first == ToolbarFit())
        #expect(steps[1] == ToolbarFit(schemeGlyphsOnly: true))
        #expect(steps[2] == ToolbarFit(editorModesInOverflow: true, schemeGlyphsOnly: true))
        let caps = steps.compactMap(\.activityWidth)
        #expect(!caps.isEmpty && caps.first! < 150 && caps == caps.sorted(by: >) && caps.last == ToolbarFit.activityMinimum)
        #expect(steps.dropFirst(2).allSatisfy { $0.schemeGlyphsOnly && $0.editorModesInOverflow })
        #expect(ToolbarFit.steps(activityNatural: 60).count == 3)
        // What each step lets the overflow hold.
        #expect(!ToolbarFit().accepts(overflowed: ["editorModes"]) && ToolbarFit().accepts(overflowed: []))
        #expect(!steps[1].accepts(overflowed: ["editorModes"]))
        #expect(steps[2].accepts(overflowed: ["editorModes"]) && !steps[2].accepts(overflowed: ["editorModes", "history"]))
    }

    /// B10: the public runner (macOS 27.0.1 at 1x) capped the activity view
    /// at 188 at 1150 points, a step of a 222-point natural width, and at
    /// 124 and 90 at 1100 and 1050, steps of 226: the width the steps
    /// followed then held the view's leading pad, which moved by 4 between
    /// the layouts. The steps are a pure function of one natural width
    /// (now without the pad), so only a changing input splits them.
    @Test func toolbarFitStepsOfTheRunnersWidths() {
        let caps222 = ToolbarFit.steps(activityNatural: 222).compactMap(\.activityWidth)
        let caps226 = ToolbarFit.steps(activityNatural: 226).compactMap(\.activityWidth)
        #expect(caps222 == [188, 154, 120, 86, 72])
        #expect(caps226 == [192, 158, 124, 90, 72])
        #expect(!caps226.contains(188) && caps226.contains(124) && caps226.contains(90))
        #expect(ToolbarFit.steps(activityNatural: 222) == ToolbarFit.steps(activityNatural: 222))
    }
}
