import Foundation
import Testing
@testable import YcodeIDECore

/// reference-ui-4.md §1–§3: Source Control navigator, commit editor,
/// branch history, inspector sections and the Integrate menu.
@MainActor
@Suite(.serialized) struct SourceControlNavigatorTests {
    @Test func datesScopesAndDiffLines() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12))!
        #expect(GitDates.relativeDay(now.addingTimeInterval(-3600), now: now, calendar: cal) == "Today")
        #expect(GitDates.relativeDay(now.addingTimeInterval(-86_400), now: now, calendar: cal) == "Yesterday")
        #expect(GitDates.relativeDay(now.addingTimeInterval(-3 * 86_400), now: now, calendar: cal) == "Oct 16, 2026")
        let late = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 23, minute: 46))!
        #expect(GitDates.detail(late, calendar: cal) == "Oct 18, 2026 at 11:46 PM")
        #expect(HistoryScope.titles == ["All", "Last 24 Hours", "Last 7 Days", "Last 30 Days"])
        func c(_ s: String, _ ago: Double) -> GitRepository.Commit {
            .init(hash: String(repeating: "a", count: 40), authorName: "A", authorEmail: "", date: now.addingTimeInterval(-ago * 86_400),
                  subject: s, body: "", branches: [], tags: [], signature: "N")
        }
        let all = [c("one", 0.5), c("two", 3), c("three", 20), c("four", 90)]
        #expect(HistoryScope.day.apply(all, filter: "", now: now).map(\.subject) == ["one"])
        #expect(HistoryScope.week.apply(all, filter: "", now: now).map(\.subject) == ["one", "two"])
        #expect(HistoryScope.month.apply(all, filter: "", now: now).count == 3)
        #expect(HistoryScope.all.apply(all, filter: "THR", now: now).map(\.subject) == ["three"])

        let lines = UnifiedDiffLines.parse("@@ -1,3 +1,3 @@\n-let a = 1\n+let a = 10\n let b = 2\n")
        #expect(lines.map(\.kind) == [.hunk, .removed, .added, .context])
        #expect(lines[1].old == 1 && lines[2].new == 1 && lines[3].old == 2 && lines[3].new == 2)
    }
}
