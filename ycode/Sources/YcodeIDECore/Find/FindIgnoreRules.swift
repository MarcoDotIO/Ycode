import Foundation

/// The files a workspace search skips inside folders: names that are
/// never searched (version-control and build folders), and the patterns
/// of `.gitignore` files and `.git/info/exclude` in the repository that
/// holds the folder. See `specs/ide/navigators.md` §Find navigator,
/// "Ycode implementation". Thread-safe; parsed files are cached.
public final class FindIgnoreRules: @unchecked Sendable {
    /// File and folder names never searched.
    public static let alwaysIgnored: Set<String> = [
        ".git", ".svn", ".hg", ".build", ".swiftpm", ".build-ide", "DerivedData", "xcuserdata", "node_modules", ".DS_Store",
    ]

    struct Pattern {
        let regex: NSRegularExpression
        let negated: Bool
        let directoryOnly: Bool
        /// The folder the pattern is relative to.
        let base: String
        /// No "/" in the pattern: it is matched against the name alone.
        var nameOnly = false
        /// Fast paths for a name pattern: the exact name, or "*<suffix>".
        var exactName: String?
        var nameSuffix: String?

        func matches(path: String) -> Bool {
            if nameOnly {
                let name = (path as NSString).lastPathComponent
                if let e = exactName { return name == e }
                if let s = nameSuffix { return name.hasSuffix(s) }
                return regex.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)) != nil
            }
            guard path.hasPrefix(base == "/" ? "/" : base + "/") else { return false }
            let rel = String(path.dropFirst(base == "/" ? 1 : base.count + 1))
            return regex.firstMatch(in: rel, range: NSRange(location: 0, length: (rel as NSString).length)) != nil
        }
    }

    /// Whether `.gitignore` files are read (the search can turn them off).
    public let readsGitIgnore: Bool
    private let lock = NSLock()
    private var patternsByDirectory: [String: [Pattern]] = [:]
    private var repositoryRoots: [String: String?] = [:]
    private var patternsAlong: [String: [Pattern]] = [:]

    public init(readsGitIgnore: Bool = true) { self.readsGitIgnore = readsGitIgnore }

    /// Whether a file (or folder) is skipped. Only the item itself is
    /// judged: a search lists folders top-down and does not enter an
    /// ignored one, and the folder it starts from is searched even when
    /// an enclosing repository ignores it (a project opened from a build
    /// folder).
    public func isIgnored(_ path: String, isDirectory: Bool = false) -> Bool {
        let name = (path as NSString).lastPathComponent
        if Self.alwaysIgnored.contains(name) { return true }
        guard readsGitIgnore else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        guard let root = repositoryRoot(of: parent) else { return false }
        return verdict(path, isDirectory: isDirectory, root: root)
    }

    // MARK: Evaluation

    /// The last pattern that matches decides; "!" patterns re-include.
    private func verdict(_ path: String, isDirectory: Bool, root: String) -> Bool {
        var ignored = false
        for p in patterns(along: (path as NSString).deletingLastPathComponent, root: root) {
            if p.directoryOnly && !isDirectory { continue }
            // Only a pattern that could change the verdict is evaluated.
            if ignored != p.negated { continue }
            if p.matches(path: path) { ignored = !p.negated }
        }
        return ignored
    }

    /// The patterns that apply to entries of `dir`: the repository's
    /// exclude file, then each `.gitignore` from the root down.
    private func patterns(along dir: String, root: String) -> [Pattern] {
        if let cached = lock.withLock({ patternsAlong[dir] }) { return cached }
        var dirs: [String] = [dir]
        var d = dir
        while d != root, d.hasPrefix(root + "/") {
            d = (d as NSString).deletingLastPathComponent
            dirs.append(d)
        }
        var out = load(file: (root as NSString).appendingPathComponent(".git/info/exclude"), base: root)
        for d in dirs.reversed() { out += load(file: (d as NSString).appendingPathComponent(".gitignore"), base: d) }
        lock.withLock { patternsAlong[dir] = out }
        return out
    }

    private func load(file: String, base: String) -> [Pattern] {
        if let cached = lock.withLock({ patternsByDirectory[file] }) { return cached }
        let parsed = (try? String(contentsOfFile: file, encoding: .utf8)).map { Self.parse($0, base: base) } ?? []
        lock.withLock { patternsByDirectory[file] = parsed }
        return parsed
    }

    /// The nearest folder at or above `dir` that holds `.git`.
    private func repositoryRoot(of dir: String) -> String? {
        if let cached = lock.withLock({ repositoryRoots[dir] }) { return cached }
        var result: String?
        if FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
            result = dir
        } else {
            let parent = (dir as NSString).deletingLastPathComponent
            result = parent == dir || parent.isEmpty ? nil : repositoryRoot(of: parent)
        }
        lock.withLock { repositoryRoots[dir] = result }
        return result
    }

    // MARK: Parsing

    /// The patterns of one ignore file (gitignore syntax: `#` comments,
    /// `!` negation, a trailing `/` for folders only, a `/` elsewhere
    /// anchors the pattern to `base`, `*`, `?`, `[…]` and `**`).
    static func parse(_ text: String, base: String) -> [Pattern] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> Pattern? in
            var line = String(raw)
            while line.hasSuffix(" ") && !line.hasSuffix("\\ ") { line.removeLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            var negated = false
            if line.hasPrefix("!") { negated = true; line.removeFirst() }
            if line.hasPrefix("\\#") || line.hasPrefix("\\!") { line.removeFirst() }
            var directoryOnly = false
            if line.hasSuffix("/") { directoryOnly = true; line.removeLast() }
            guard !line.isEmpty else { return nil }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard let regex = try? NSRegularExpression(pattern: "^" + globToRegex(line) + "$") else { return nil }
            var p = Pattern(regex: regex, negated: negated, directoryOnly: directoryOnly, base: base)
            if !anchored {
                p.nameOnly = true
                let glob = Set("*?[\\")
                if !line.contains(where: { glob.contains($0) }) { p.exactName = line }
                else if line.hasPrefix("*"), !line.dropFirst().contains(where: { glob.contains($0) }) { p.nameSuffix = String(line.dropFirst()) }
            }
            return p
        }
    }

    /// A gitignore glob as a regular expression (no anchors).
    static func globToRegex(_ glob: String) -> String {
        let c = Array(glob)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            if ch == "*" {
                if i + 1 < c.count, c[i + 1] == "*" {
                    let atStart = i == 0 || c[i - 1] == "/"
                    let slashAfter = i + 2 < c.count && c[i + 2] == "/"
                    if atStart && slashAfter { out += "(?:.*/)?"; i += 3; continue }
                    out += ".*"; i += 2; continue
                }
                out += "[^/]*"
            } else if ch == "?" {
                out += "[^/]"
            } else if ch == "[", let close = c[(i + 1)...].firstIndex(of: "]") {
                var cls = String(c[(i + 1)..<close])
                if cls.hasPrefix("!") { cls = "^" + cls.dropFirst() }
                out += "[" + cls.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                i = close
            } else if ch == "/" {
                out += "/"
            } else if ch == "\\", i + 1 < c.count {
                out += NSRegularExpression.escapedPattern(for: String(c[i + 1]))
                i += 1
            } else {
                out += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i += 1
        }
        return out
    }
}
