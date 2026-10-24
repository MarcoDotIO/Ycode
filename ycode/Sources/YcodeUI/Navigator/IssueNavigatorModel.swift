import Foundation
import YcodeBuild

/// The issue navigator's data model (specs/ide/reference-ui-2.md §1, §2):
/// stale-issue tracking across builds, the filter tokens, and grouping.
public struct IssueNavigatorModel: Equatable {
    /// An issue as shown: fresh from the latest build, or stale (kept
    /// from an earlier build that the latest build did not reproduce).
    public struct Entry: Equatable, Hashable {
        public var diagnostic: Diagnostic
        public var isStale: Bool
        public init(_ diagnostic: Diagnostic, stale: Bool = false) { self.diagnostic = diagnostic; isStale = stale }
    }

    /// One group per file; stale and fresh groups of one file are separate
    /// and may share a title.
    public struct Group: Equatable {
        public var file: String
        public var title: String
        public var isStale: Bool
        public var entries: [Entry]
    }

    /// Filter tokens from the "Add Filter" section; they join the text filter.
    public enum Token: Hashable {
        case kind(String)
        case notDeprecation
        public var title: String {
            switch self {
            case .kind(let k): "Kind = \(k)"
            case .notDeprecation: "≠ Deprecation"
            }
        }
    }

    /// The filter-options menu sections, in order.
    public static let menuSections: [(String, [String])] = [
        ("Additional Filtering", ["Deprecation"]),
        ("Add Filter", [Token.kind("Build").title, Token.notDeprecation.title]),
        ("", ["Clear Recents"]),
    ]

    public private(set) var stale: [Diagnostic] = []
    private var lastBuild: [Diagnostic] = []
    public var tokens: [Token] = []
    public var recentTokens: [Token] = []
    /// "Additional Filtering › Deprecation": only deprecation issues.
    public var deprecationOnly = false
    public var errorsOnly = false

    public init() {}

    /// A build is running: the previous build's issues stay listed, as
    /// stale, until it finishes (reference-ui-5.md §5.3.2).
    public private(set) var isBuilding = false

    public mutating func startBuild() { isBuilding = true }

    /// Records a finished build's issues (reference-ui-5.md §5.3.2, N10).
    /// An earlier issue this build did not report is removed, unless its
    /// file is one the build did not compile: that one stays, stale, until
    /// a build compiles the file. `compiledFiles` holds the file names the
    /// build compiled; nil when unknown (every file counts as compiled).
    /// A clean (`full`) clears all stale issues.
    public mutating func finishBuild(_ current: [Diagnostic], full: Bool, compiledFiles: Set<String>? = nil) {
        isBuilding = false
        let now = Set(current)
        if full { stale = [] } else {
            var next: [Diagnostic] = []
            for d in stale + lastBuild where !now.contains(d) && !next.contains(d) {
                guard let file = d.location?.file, let compiled = compiledFiles else { continue }
                if !compiled.contains(URL(fileURLWithPath: file).lastPathComponent) { next.append(d) }
            }
            stale = next
        }
        lastBuild = current
    }

    /// The file names a build log shows as compiled (SwiftPM `Compiling`
    /// and xcodebuild `CompileSwift`/`CompileC` steps); nil when the log
    /// has no compile steps Ycode recognizes.
    public static func compiledFiles(inLog log: [String], isPackage: Bool) -> Set<String>? {
        let sources: Set<String> = ["swift", "c", "m", "mm", "cpp", "cc", "cxx", "s"]
        var out = Set<String>()
        var sawTask = false
        for line in log {
            guard let (_, group, _, _) = BuildLogModel.task(line, isPackage: isPackage) else { continue }
            sawTask = true
            let s = line.trimmingCharacters(in: .whitespaces)
            if let r = s.range(of: " (in target '") {
                // xcodebuild: the source files among the command's arguments.
                let words = s[..<r.lowerBound].split(separator: " ")
                guard let cmd = words.first, ["CompileSwift", "SwiftCompile", "CompileC"].contains(String(cmd)) else { continue }
                for w in words.dropFirst() {
                    let name = URL(fileURLWithPath: String(w)).lastPathComponent
                    if sources.contains(URL(fileURLWithPath: name).pathExtension) { out.insert(name) }
                }
            } else if group.hasPrefix("Compiling ") {
                for name in group.dropFirst("Compiling ".count).split(separator: " ") { out.insert(String(name)) }
            }
        }
        return sawTask ? out : nil
    }

    public mutating func addToken(_ t: Token) {
        if !tokens.contains(t) { tokens.append(t) }
        recentTokens.removeAll { $0 == t }
        recentTokens.insert(t, at: 0)
    }
    public mutating func clearRecents() { recentTokens = [] }

    public static func isDeprecation(_ d: Diagnostic) -> Bool {
        let m = d.message.lowercased()
        return m.contains("deprecated") || m.contains("deprecation")
    }

    /// Fresh issues followed by stale ones, notes left out, filters applied.
    public func entries(fresh: [Diagnostic], text: String = "", keepFile: (String) -> Bool = { _ in true }) -> [Entry] {
        let freshSet = Set(fresh)
        var shownStale = stale.filter { !freshSet.contains($0) }
        if isBuilding { for d in lastBuild where !freshSet.contains(d) && !shownStale.contains(d) { shownStale.append(d) } }
        let all = fresh.map { Entry($0) } + shownStale.map { Entry($0, stale: true) }
        let t = text.lowercased()
        return all.filter { e in
            let d = e.diagnostic
            if d.severity == .note { return false }
            if errorsOnly && d.severity != .error { return false }
            if deprecationOnly && !Self.isDeprecation(d) { return false }
            if tokens.contains(.notDeprecation) && Self.isDeprecation(d) { return false }
            for case .kind(let k) in tokens where k != "Build" { return false }
            if let f = d.location?.file, !keepFile(f) { return false }
            if !t.isEmpty && !d.message.lowercased().contains(t) { return false }
            return true
        }
    }

    /// Groups by (file, stale), sorted by title. Issues without a file are
    /// not grouped (reference-ui-5.md §5.3.1, N9): see `rootEntries`.
    public static func groups(_ entries: [Entry]) -> [Group] {
        var out: [Group] = []
        for e in entries {
            guard let file = e.diagnostic.location?.file, !file.isEmpty else { continue }
            if let i = out.firstIndex(where: { $0.file == file && $0.isStale == e.isStale }) { out[i].entries.append(e); continue }
            let title = URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
            out.append(Group(file: file, title: title, isStale: e.isStale, entries: [e]))
        }
        return out.enumerated().sorted { a, b in
            let c = a.element.title.localizedStandardCompare(b.element.title)
            if c != .orderedSame { return c == .orderedAscending }
            if a.element.isStale != b.element.isStale { return !a.element.isStale }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Issues without a file, in order: rows directly under the navigator's
    /// root, after the file groups (reference-ui-5.md §5.3.1, N9). Project
    /// checks (§11.6, T8) are among them.
    public static func rootEntries(_ entries: [Entry]) -> [Entry] {
        entries.filter { ($0.diagnostic.location?.file ?? "").isEmpty }
    }

    /// Toolbar capsule counts (§2.1): they include stale issues.
    public func capsuleCounts(fresh: [Diagnostic]) -> (errors: Int, warnings: Int) {
        let set = Set(fresh)
        var all = fresh + stale.filter { !set.contains($0) }
        if isBuilding { for d in lastBuild where !set.contains(d) && !all.contains(d) { all.append(d) } }
        return (all.filter { $0.severity == .error }.count, all.filter { $0.severity == .warning }.count)
    }
}
