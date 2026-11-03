import Foundation
import YcodeBuild
import YcodeXcodebuild

/// Opening an `.xcresult` (`specs/ide/testing.md` §Result bundles in the
/// IDE): the bundle's tests, read with `XCResultReader`
/// (`specs/xcodebuild/result-bundle.md`), become a test report in the
/// Report navigator, as if the run had happened in this window.
public enum ResultBundleReport {
    /// One recorded test as the IDE's outcome: `Class/method()` gives suite
    /// `Class` and name `method`; Success and Expected Failure pass,
    /// Failure fails, Skipped is skipped; failures become issues.
    public static func outcome(_ t: XCResultReader.Test) -> TestOutcome {
        let parts = t.identifier.split(separator: "/").map(String.init)
        let last = parts.last ?? t.name
        let name = last.hasSuffix("()") ? String(last.dropLast(2)) : last
        let suite = parts.count > 1 ? parts[parts.count - 2] : nil
        let status: TestOutcome.Status = switch t.status {
        case "Failure": .failed
        case "Skipped": .skipped
        default: .passed
        }
        let failures = t.failures.map { f in
            Diagnostic(severity: .error, message: f.message, location: f.file.map { Diagnostic.Location(file: $0, line: f.line ?? 0) })
        }
        return TestOutcome(suite: suite, name: name, status: status, failures: failures, duration: t.duration)
    }

    /// The report for a bundle: "Test <bundle name>", failed when a test
    /// failed; the Tests page lists every test; the issues are the failures.
    public static func report(_ bundle: URL) throws -> BuildReport {
        let reader = try XCResultReader(bundle)
        let outcomes = try reader.tests().map(outcome)
        let failed = outcomes.filter { $0.status == .failed }
        let created = (try? bundle.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
        var r = BuildReport(title: "Test \(bundle.deletingPathExtension().lastPathComponent)", date: created, succeeded: failed.isEmpty,
                            log: ["Ycode: read \(outcomes.count) tests from \(bundle.path)"], errorCount: failed.count, warningCount: 0)
        r.context.action = "Test"
        r.context.tests = outcomes
        r.context.issues = failed.flatMap(\.failures)
        return r
    }
}

extension WorkspaceSession {
    /// Opens a result bundle as a report (newest first in the Report
    /// navigator). Throws what the reader throws.
    @discardableResult
    public func openResultBundle(_ bundle: URL) throws -> BuildReport {
        let r = try ResultBundleReport.report(bundle)
        recordReport(r)
        return r
    }
}
