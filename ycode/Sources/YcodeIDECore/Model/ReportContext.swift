import Foundation
import YcodeBuild

/// What a report shows besides its log: the action, where it ran, and
/// (for test runs) the outcomes. See `specs/ide/reference-ui-2.md` §4–§6.
public struct ReportContext: Equatable, Sendable {
    public var action = "Build"
    public var scheme: String?
    public var containerKind = "Project"
    public var containerName = ""
    public var configuration = "Debug"
    public var destination = ""
    public var duration: TimeInterval = 0
    public var issues: [Diagnostic] = []
    public var tests: [TestOutcome] = []
    /// Test plan name (test runs): the scheme's default plan, else
    /// "<scheme> (Autocreated)".
    public var plan: String?
    public var testTargets = 0
    /// The test target's name, when known.
    public var testTarget: String?
    /// Local or Cloud (the Report navigator's switch).
    public var location: ReportLocation = .local
    /// SDK name and version ("macOS 27.2"), for the build log subtitle.
    public var sdk = ""
    /// Line coverage per target (test runs with coverage enabled).
    public var coverage: [CoverageItem] = []
    /// Seconds from the start of the operation at which each `log` line
    /// arrived (same count as the log when recorded), for step durations.
    public var logTimes: [TimeInterval] = []
    /// Build-log steps of earlier builds of the same scheme (since its last
    /// clean) that this build did not run again: the build log's "All"
    /// scope adds them; "Recent" shows only this build's steps.
    public var carriedOver: [BuildLogSection] = []
    public var kind: ReportKind {
        switch action {
        case "Test": .test
        case "Clean": .clean
        case "Analyze": .analyze
        case "Build": .build
        default: .package
        }
    }
    public init() {}
}

/// Relative day and time: "Today, 3:46 AM".
public enum ReportFormat {
    public static func dayAndTime(_ d: Date) -> String {
        let day = DateFormatter()
        day.dateStyle = .medium
        day.timeStyle = .none
        day.doesRelativeDateFormatting = true
        // Foundation on Linux ignores relative formatting: the day names
        // the formatter gives on macOS.
        var dayText = day.string(from: d)
        #if os(Linux)
        let cal = Calendar.current
        if cal.isDateInToday(d) { dayText = "Today" } else if cal.isDateInYesterday(d) { dayText = "Yesterday" }
        #endif
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        return "\(dayText), \(time.string(from: d))"
    }

    public static func footerDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "M/d/yy"
        let t = DateFormatter()
        t.dateStyle = .none
        t.timeStyle = .short
        return "\(f.string(from: d)), \(t.string(from: d))"
    }

    public static func seconds(_ s: TimeInterval) -> String { String(format: "%.1f", s) }
}
