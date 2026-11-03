import Testing
import YcodeBuild
@testable import YcodeIDECore

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

    /// reference-ui-6.md §5.2 (N2): live and build copies of one
    /// diagnostic merge; messages start with a capital letter.
    @Test func liveAndBuildIssuesMerge() {
        let build = d(.warning, "initialization of immutable value 'unused' was never used", "/private/var/t/Model.swift", 4)
        var live = d(.warning, "Initialization of immutable value 'unused' was never used", "/var/t/Model.swift", 4)
        live.location?.column = 9
        live.fixIts = [.init(file: "/var/t/Model.swift", start: .init(file: "/var/t/Model.swift", line: 4, column: 5),
                             end: .init(file: "/var/t/Model.swift", line: 4, column: 8), replacement: "_")]
        let other = d(.error, "cannot find 'x' in scope", "/var/t/Other.swift", 2)
        let merged = IssueMerge.merge([[], [], [build, build]], live: [live, other])
        #expect(merged.map(\.message) == ["Initialization of immutable value 'unused' was never used", "Cannot find 'x' in scope"])
        #expect(merged[0].location?.file == "/private/var/t/Model.swift" && merged[0].fixIts == live.fixIts)
        // A different line or severity is a different issue.
        #expect(IssueMerge.merge([[build]], live: [d(.warning, build.message, "/var/t/Model.swift", 5)]).count == 2)
        #expect(IssueMerge.merge([[build]], live: [d(.error, build.message, "/var/t/Model.swift", 4)]).count == 2)
        // §5.2.2: live issues of a file the build reported on are dropped.
        let hidden = IssueMerge.merge([[build]], live: [other, d(.warning, "stale live", "/var/t/Model.swift", 9)],
                                      liveHiddenFiles: ["/var/t/Model.swift"])
        #expect(hidden.map(\.message) == ["Initialization of immutable value 'unused' was never used", "Cannot find 'x' in scope"])
        #expect(IssueMerge.capitalized("éclair") == "Éclair" && IssueMerge.capitalized("'x' is unused") == "'x' is unused")
        // The stale copy of a merged issue is not listed twice.
        var m = IssueNavigatorModel()
        m.finishBuild([build], full: false)
        m.startBuild()
        #expect(m.entries(fresh: [IssueMerge.capitalized(live)]).count == 1)
        #expect(m.capsuleCounts(fresh: [IssueMerge.capitalized(live)]) == (0, 1))
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
}
