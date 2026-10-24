import AppKit
import Testing
import YcodeBuild
@testable import YcodeUI

/// specs/ide/reference-ui-2.md §1 (issue navigator), §2 (capsule), §3 (Find).
@MainActor
@Suite struct IssueFindNavigatorTests {
    func d(_ sev: Diagnostic.Severity, _ msg: String, _ file: String? = nil, _ line: Int = 1) -> Diagnostic {
        Diagnostic(severity: sev, message: msg, location: file.map { .init(file: $0, line: line) })
    }

    /// reference-ui-5.md §5.3.2: an unreported issue stays stale only
    /// while its file was not compiled again.
    @Test func staleIssuesSurviveUntilFullBuild() {
        var m = IssueNavigatorModel()
        let a = d(.error, "a", "/p/Zed.swift"), b = d(.warning, "b", "/p/Alpha.swift")
        m.finishBuild([a, b], full: false)
        #expect(m.stale.isEmpty)
        m.finishBuild([b], full: false, compiledFiles: ["Alpha.swift"])
        #expect(m.stale == [a])
        let e = m.entries(fresh: [b])
        #expect(e == [.init(b), .init(a, stale: true)])
        #expect(m.capsuleCounts(fresh: [b]) == (1, 1))
        m.finishBuild([b, a], full: false)
        #expect(m.stale.isEmpty)
        m.finishBuild([b], full: false, compiledFiles: []); m.finishBuild([], full: true)
        #expect(m.stale.isEmpty)
    }

    @Test func groupsByFileAndStaleness() {
        let x = d(.error, "x", "/p/B.swift"), y = d(.warning, "y", "/p/A.swift"), z = d(.error, "z", "/p/B.swift", 9)
        let s = d(.error, "s", "/p/B.swift", 3), n = d(.error, "n")
        let g = IssueNavigatorModel.groups([.init(n), .init(x), .init(y), .init(z), .init(s, stale: true)])
        #expect(g.map(\.title) == ["A", "B", "B"])
        #expect(g[1].entries.map(\.diagnostic.message) == ["x", "z"] && !g[1].isStale && g[2].isStale)
        #expect(IssueNavigatorModel.rootEntries([.init(n), .init(x)]).map(\.diagnostic) == [n])
    }

    /// reference-ui-5.md §5.3.1 (N9), §11.6 (T8): issues without a file,
    /// such as the project's signing warning, are rows directly under the
    /// root after the file groups, not in a group.
    @Test func filelessIssuesSitUnderTheRoot() {
        let nav = NavigatorAreaController()
        _ = nav.view
        nav.workspaceName = "Demo"
        nav.select(4)
        let signing = d(.warning, "Signing for \u{201C}App\u{201D} requires a development team.")
        nav.setIssues([signing, d(.error, "bad", "/p/Main.swift"), d(.error, "linker failed")])
        let root = nav.roots[4].first
        #expect(root?.detail == "3 issues")
        #expect(root?.children.map(\.title) == ["Main", signing.message, "linker failed"])
        #expect(root?.children[0].children.map(\.title) == ["bad"])
        #expect(root?.children[1].children.isEmpty == true && root?.children[1].symbol == "exclamationmark.triangle.fill")
        #expect(root?.children[2].symbol == "xmark.octagon.fill")
    }

    @Test func tokensAndFilters() {
        var m = IssueNavigatorModel()
        let dep = d(.warning, "'foo' is deprecated", "/p/A.swift"), err = d(.error, "bad", "/p/A.swift"), note = d(.note, "n")
        #expect(m.entries(fresh: [dep, err, note]).count == 2)
        m.addToken(.notDeprecation)
        #expect(m.entries(fresh: [dep, err]).map(\.diagnostic) == [err])
        m.tokens = []; m.deprecationOnly = true
        #expect(m.entries(fresh: [dep, err]).map(\.diagnostic) == [dep])
        m.deprecationOnly = false; m.errorsOnly = true
        #expect(m.entries(fresh: [dep, err]).map(\.diagnostic) == [err])
        m.addToken(.kind("Build"))
        #expect(m.recentTokens.first == .kind("Build") && m.tokens.map(\.title).contains("Kind = Build"))
        m.clearRecents()
        #expect(m.recentTokens.isEmpty)
        #expect(IssueNavigatorModel.menuSections.map(\.0) == ["Additional Filtering", "Add Filter", ""])
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
        #expect(root?.children.map(\.title) == ["Main", "Main"])
        #expect(root?.children[1].children.first?.tint == .tertiaryLabelColor)
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
                           "-", "Containing Groups", "Sources", "Demo", "-", "Custom Scopes…"])
        #expect(nav.findScope.menu!.item(withTitle: "Current Find Results")?.isEnabled == false)
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
