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
        // The same issue reported again (§5.2.1: compared by IssueMerge.key)
        // is not stale.
        let now = Set(current.map(IssueMerge.key))
        if full { stale = [] } else {
            var next: [Diagnostic] = []
            var kept = Set<IssueMerge.Key>()
            for d in stale + lastBuild where !now.contains(IssueMerge.key(d)) && kept.insert(IssueMerge.key(d)).inserted {
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
        var shown = Set(fresh.map(IssueMerge.key))
        var shownStale: [Diagnostic] = []
        for d in stale + (isBuilding ? lastBuild : []) where shown.insert(IssueMerge.key(d)).inserted { shownStale.append(d) }
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

    /// Toolbar capsule counts (§2.1): they include stale issues.
    public func capsuleCounts(fresh: [Diagnostic]) -> (errors: Int, warnings: Int) {
        var shown = Set(fresh.map(IssueMerge.key))
        var all = fresh
        for d in stale + (isBuilding ? lastBuild : []) where shown.insert(IssueMerge.key(d)).inserted { all.append(d) }
        return (all.filter { $0.severity == .error }.count, all.filter { $0.severity == .warning }.count)
    }
}

// MARK: One row per diagnostic (reference-ui-6.md §5.2, N2)

/// Merges the issue sets the IDE knows about (project checks, package
/// resolution, the build, the language service) into one list with one
/// entry per diagnostic, and capitalizes messages.
public enum IssueMerge {
    /// The message with its first letter capitalized (§5.2.3); the rest is
    /// left as it is.
    public static func capitalized(_ message: String) -> String {
        guard let first = message.first, first.isLowercase else { return message }
        return first.uppercased() + message.dropFirst()
    }

    /// The diagnostic with a capitalized message (notes too).
    public static func capitalized(_ d: Diagnostic) -> Diagnostic {
        var d = d
        d.message = capitalized(d.message)
        d.notes = d.notes.map(capitalized)
        return d
    }

    /// One spelling per file: the standardized path, with the `/private`
    /// prefix of the system's symlinked folders dropped (the build and the
    /// language server may each name a temporary file differently).
    public static func canonicalPath(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.path
        for dir in ["/private/var/", "/private/tmp/", "/private/etc/"] where p.hasPrefix(dir) { p.removeFirst("/private".count) }
        return p
    }

    /// What makes two diagnostics the same issue (§5.2.1): file, line,
    /// severity and message, the message's first character compared
    /// without case. Columns, notes and fix-its do not count.
    public struct Key: Hashable {
        public var file: String?
        public var line: Int?
        public var severity: Diagnostic.Severity
        public var message: String
    }

    public static func key(_ d: Diagnostic) -> Key {
        Key(file: d.location.map { canonicalPath($0.file) }, line: d.location?.line, severity: d.severity, message: capitalized(d.message))
    }

    /// `sources` in order (each capitalized, duplicates dropped), then the
    /// live issues that no source already has. Live issues of the files in
    /// `liveHiddenFiles` (canonical paths) are left out: the build's
    /// issues stand for those files until they are edited (§5.2.2). A
    /// kept build issue without fix-its takes the live copy's.
    public static func merge(_ sources: [[Diagnostic]], live: [Diagnostic], liveHiddenFiles: Set<String> = []) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var index: [Key: Int] = [:]
        for d in sources.joined() {
            let k = key(d)
            guard index[k] == nil else { continue }
            index[k] = out.count
            out.append(capitalized(d))
        }
        for d in live {
            if let f = d.location?.file, liveHiddenFiles.contains(canonicalPath(f)) { continue }
            let k = key(d)
            if let i = index[k] {
                if out[i].fixIts.isEmpty && !d.fixIts.isEmpty { out[i].fixIts = d.fixIts }
                continue
            }
            index[k] = out.count
            out.append(capitalized(d))
        }
        return out
    }
}

// MARK: Grouping by project, target and file (reference-ui-6.md §5.1, N1)

/// What the Issue navigator needs to group issues by target: the project
/// row's name, the targets in project order, and the targets that build a
/// file (empty when no target does or it is not known).
public struct IssueGrouping {
    public var projectName: String
    public var targetOrder: [String]
    public var targetsOfFile: (String) -> [String]
    public init(projectName: String, targetOrder: [String] = [], targetsOfFile: @escaping (String) -> [String] = { _ in [] }) {
        self.projectName = projectName
        self.targetOrder = targetOrder
        self.targetsOfFile = targetsOfFile
    }
}

extension IssueNavigatorModel {
    /// A file row: one per file under a parent (§5.2.4), fresh and stale
    /// issues together, by line.
    public struct FileRow: Equatable {
        public var file: String
        public var title: String
        public var entries: [Entry]
    }

    /// A top-level row: the project (its issues without a file, and the
    /// files no target builds) or one target.
    public struct GroupRow: Equatable {
        public enum Kind: Equatable { case project, target }
        public var kind: Kind
        public var title: String
        /// Issues directly under the row (the project's file-less issues).
        public var entries: [Entry]
        public var files: [FileRow]
        /// The number after the title ("1 issue").
        public var count: Int { entries.count + files.reduce(0) { $0 + $1.entries.count } }
        public var countText: String { "\(count) issue\(count == 1 ? "" : "s")" }
    }

    /// The Issue navigator's tree (§5.1): the project row when it has
    /// issues of its own, then one row per target with issues, in target
    /// order (targets the order does not name come after, by name). A file
    /// built by two targets is listed under each.
    public static func tree(_ entries: [Entry], grouping: IssueGrouping) -> [GroupRow] {
        var projectEntries: [Entry] = []
        var byGroup: [String?: [String: [Entry]]] = [:]   // nil = the project row
        var targetsCache: [String: [String]] = [:]
        for e in entries {
            guard let file = e.diagnostic.location?.file, !file.isEmpty else { projectEntries.append(e); continue }
            let key = IssueMerge.canonicalPath(file)
            let targets = targetsCache[key] ?? grouping.targetsOfFile(file)
            targetsCache[key] = targets
            for t in targets.isEmpty ? [nil] : targets.map(Optional.some) {
                byGroup[t, default: [:]][file, default: []].append(e)
            }
        }
        func fileRows(_ files: [String: [Entry]]) -> [FileRow] {
            files.map { file, list in
                let sorted = list.enumerated().sorted { a, b in
                    let la = a.element.diagnostic.location?.line ?? 0, lb = b.element.diagnostic.location?.line ?? 0
                    return la != lb ? la < lb : a.offset < b.offset
                }.map(\.element)
                return FileRow(file: file, title: URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent, entries: sorted)
            }.sorted { a, b in
                let c = a.title.localizedStandardCompare(b.title)
                return c != .orderedSame ? c == .orderedAscending : a.file < b.file
            }
        }
        var rows: [GroupRow] = []
        let projectFiles = byGroup[nil] ?? [:]
        if !projectEntries.isEmpty || !projectFiles.isEmpty {
            rows.append(GroupRow(kind: .project, title: grouping.projectName, entries: projectEntries, files: fileRows(projectFiles)))
        }
        let named = byGroup.keys.compactMap { $0 }
        let ordered = grouping.targetOrder.filter(named.contains)
            + named.filter { !grouping.targetOrder.contains($0) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var seen = Set<String>()
        for t in ordered where seen.insert(t).inserted {
            rows.append(GroupRow(kind: .target, title: t, entries: [], files: fileRows(byGroup[t] ?? [:])))
        }
        return rows
    }
}
