import AppKit
import Testing
import YcodeBuild
@testable import YcodeIDECore
@testable import YcodeUI

/// specs/ide/reference-ui-2.md §1 (issue navigator), §2 (capsule), §3 (Find).
@MainActor
@Suite struct IssueFindNavigatorTests {
    func d(_ sev: Diagnostic.Severity, _ msg: String, _ file: String? = nil, _ line: Int = 1) -> Diagnostic {
        Diagnostic(severity: sev, message: msg, location: file.map { .init(file: $0, line: line) })
    }

    /// reference-ui-6.md §5.1 (N1), §5.2.4: one file row per file under a
    /// parent, fresh and stale issues together by line; the project row
    /// holds the file-less issues and the files no target builds.
    @Test func groupsByProjectTargetAndFile() {
        let x = d(.error, "x", "/p/B.swift", 4), y = d(.warning, "y", "/p/A.swift"), z = d(.error, "z", "/p/B.swift", 9)
        let s = d(.error, "s", "/p/B.swift", 3), n = d(.error, "n"), loose = d(.warning, "w", "/p/Loose.swift")
        let both = d(.warning, "shared", "/p/Shared.swift")
        let grouping = IssueGrouping(projectName: "Proj", targetOrder: ["App", "Tests", "Unused"]) { file in
            switch URL(fileURLWithPath: file).lastPathComponent {
            case "A.swift": ["Tests"]
            case "B.swift": ["App"]
            case "Shared.swift": ["App", "Tests"]
            default: []
            }
        }
        let rows = IssueNavigatorModel.tree([.init(n), .init(x), .init(y), .init(z), .init(s, stale: true), .init(loose), .init(both)], grouping: grouping)
        #expect(rows.map(\.title) == ["Proj", "App", "Tests"])
        #expect(rows.map(\.kind) == [.project, .target, .target])
        #expect(rows[0].entries.map(\.diagnostic) == [n] && rows[0].files.map(\.title) == ["Loose"])
        #expect(rows[0].countText == "2 issues")
        #expect(rows[1].files.map(\.title) == ["B", "Shared"])
        #expect(rows[1].files[0].entries.map(\.diagnostic.message) == ["s", "x", "z"])
        #expect(rows[1].files[0].entries.map(\.isStale) == [true, false, false])
        #expect(rows[1].countText == "4 issues" && rows[2].countText == "2 issues")
        #expect(rows[2].files.map(\.title) == ["A", "Shared"])
        // No project row without project issues; unknown targets by name.
        let only = IssueNavigatorModel.tree([.init(y)], grouping: IssueGrouping(projectName: "P", targetOrder: []) { _ in ["Zed"] })
        #expect(only.map(\.title) == ["Zed"] && only[0].countText == "1 issue")
    }

    /// reference-ui-6.md §5.1 (supersedes reference-ui-5.md §5.3.1, N9):
    /// issues without a file, such as the project's signing warning, are
    /// rows directly under the project row; without target information
    /// the files go there too.
    @Test func filelessIssuesSitUnderTheProjectRow() {
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.workspaceName = "Demo"
        nav.select(4)
        let signing = d(.warning, "Signing for \u{201C}App\u{201D} requires a development team.")
        nav.setIssues([signing, d(.error, "bad", "/p/Main.swift"), d(.error, "linker failed")])
        let root = nav.roots[4].first
        #expect(nav.roots[4].count == 1 && root?.title == "Demo" && root?.detail == "3 issues")
        #expect(root?.children.map(\.title) == [signing.message, "linker failed", "Main"])
        #expect(root?.children[2].children.map(\.title) == ["bad"])
        #expect(root?.children[0].children.isEmpty == true && root?.children[0].symbol == "exclamationmark.triangle.fill")
        #expect(root?.children[1].symbol == "xmark.octagon.fill")
        // With targets: the project row, then a row per target.
        nav.issueGrouping = { IssueGrouping(projectName: "Demo", targetOrder: ["App"]) { _ in ["App"] } }
        nav.setIssues([signing, d(.error, "bad", "/p/Main.swift")])
        #expect(nav.roots[4].map(\.title) == ["Demo", "App"] && nav.roots[4].map(\.detail) == ["1 issue", "1 issue"])
        #expect(nav.roots[4][1].symbol == "app.dashed" && nav.roots[4][1].children.map(\.title) == ["Main"])
    }

    @Test func navigatorRootAndMenu() {
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.workspaceName = "Demo"
        nav.select(4)
        #expect(nav.filterOptionTitles == ["Additional Filtering", "Deprecation", "-", "Add Filter", "Kind = Build", "≠ Deprecation", "-", "Clear Recents"])
        #expect(nav.recentToggle.toolTip == "Show only issues from open documents and recently built sources")
        #expect(nav.sourceControlToggle.toolTip == "Show only errors")
        let a = d(.error, "first", "/p/Main.swift"), b = d(.warning, "second", "/p/Main.swift")
        nav.issuesBuildFinished([a, b], full: false)
        nav.issuesBuildFinished([b], full: false, compiledFiles: [])
        let root = nav.roots[4].first
        #expect(root?.detail == "2 issues")
        // §5.2.4: one row for the file, the stale issue in it, greyed.
        #expect(root?.children.map(\.title) == ["Main"])
        #expect(root?.children[0].children.map(\.title) == ["second", "first"])
        #expect(root?.children[0].children.last?.tint == .tertiaryLabelColor)
        #expect(root?.children[0].children.first?.maxLines == 3)
        nav.chooseIssueFilter(tag: 11)
        #expect(nav.filter.placeholderString == "≠ Deprecation")
        nav.select(0)
        #expect(nav.filterOptionTitles == ["Show Only Recent Files", "Show Only Files with Source-Control Status"])
    }

    @Test func findHeaderAndScopeMenu() {
        let nav = NavigatorAreaController()
        _ = nav.view
        #expect(NavigatorAreaController.findModes == ["Find", "Replace"])
        #expect(nav.findStyle.itemTitles == NavigatorAreaController.findKinds && nav.findKinds_last == "Asset References")
        #expect(nav.findMatch.itemTitles == ["Containing", "Matching Word", "Starting With", "Ending With"])
        #expect(nav.findCaseToggle.title == "Aa")
        nav.isPackage = true
        nav.containingGroups = { [("Sources", "/p/Sources"), ("Demo", "/p/Sources/Demo")] }
        nav.rebuildScopeMenu()
        let titles = nav.findScope.menu!.items.map { $0.isSeparatorItem ? "-" : $0.title }
        #expect(titles == ["Package", "Package Dependencies", "Package and Package Dependencies", "-", "Current Find Results",
                           "-", "Containing Groups", "Sources", "Demo", "-", "Open Files", "Custom Scopes…"])
        #expect(nav.findScope.menu!.item(withTitle: "Current Find Results")?.isEnabled == false)
        #expect(nav.findScope.menu!.item(withTitle: "Custom Scopes…")?.isEnabled == true)
        #expect(nav.findScope.title == "In Package")
    }

    @Test func capsuleHidesZeros() {
        let c = IssueCapsuleView()
        c.errors = 0; c.warnings = 2
        #expect(c.parts.map(\.1) == [2] && !c.isHidden)
        c.warnings = 0
        #expect(c.isHidden)
    }
}

extension NavigatorAreaController { var findKinds_last: String? { Self.findKinds.last } }
