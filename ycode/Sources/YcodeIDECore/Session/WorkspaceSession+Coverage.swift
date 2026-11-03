import Foundation
import YcodeBuild

/// Editor ▸ Code Coverage (`specs/ide/source-editor.md` §Code coverage):
/// the newest test run that gathered coverage gives each file's execution
/// counts per line.
extension WorkspaceSession {
    /// The coverage rows of the newest report that has any.
    public var latestCoverage: [CoverageItem] {
        reports.first { !$0.context.coverage.isEmpty }?.context.coverage ?? []
    }

    /// Execution counts per line of `file` (index 0 = line 1; -1: not
    /// executable), from the newest coverage run; nil when it has none for
    /// the file.
    public func coverageLineCounts(file: String) -> [Int]? {
        let want = IssueMerge.canonicalPath(file)
        for target in latestCoverage {
            for f in target.files {
                guard let p = f.path, let counts = f.lineCounts, IssueMerge.canonicalPath(p) == want else { continue }
                return counts
            }
        }
        return nil
    }

    /// The editor's ribbon marks: line → count, executable lines only.
    public static func coverageMarks(_ counts: [Int]?) -> [Int: Int] {
        guard let counts else { return [:] }
        var m: [Int: Int] = [:]
        for (i, c) in counts.enumerated() where c >= 0 { m[i + 1] = c }
        return m
    }
}
