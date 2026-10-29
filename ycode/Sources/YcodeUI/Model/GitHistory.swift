import Foundation

/// History, staging and network operations for the Source Control
/// navigator, the commit editor and the Integrate menu
/// (`specs/ide/reference-ui-4.md` §2–§3). Everything goes through git's
/// porcelain or plumbing output with explicit formats.
extension GitRepository {
    /// One commit as history rows and the commit detail show it.
    public struct Commit: Equatable, Sendable {
        public var hash: String
        public var authorName: String
        public var authorEmail: String
        public var date: Date
        public var subject: String
        public var body: String
        /// Branch and tag names pointing at this commit (decorations).
        public var branches: [String]
        public var tags: [String]
        /// git's signature letter (`%G?`): "N" means no signature.
        public var signature: String

        public var shortHash: String { String(hash.prefix(7)) }
        /// The whole message: subject, blank line, body.
        public var message: String { body.isEmpty ? subject : subject + "\n\n" + body }
        /// "Commit unverified" for unsigned or unverifiable commits.
        public var verification: String { signature == "G" ? "Commit verified" : "Commit unverified" }
    }

    /// One working-tree change with both porcelain columns.
    public struct Change: Equatable, Sendable {
        public var path: String
        public var index: Character
        public var worktree: Character
        public var status: FileStatus
        public var isStaged: Bool { index != " " && index != "?" }
        public var isUnstaged: Bool { worktree != " " }
    }

    public struct Author: Equatable, Sendable {
        public var name: String
        public var email: String
    }

    // MARK: Reading

    /// The checked-out branch, or nil when HEAD is detached or unborn.
    public func currentBranch() -> String? {
        let s = (try? git(["symbolic-ref", "--quiet", "--short", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    /// The full hash of HEAD, or nil when the branch is unborn (no commits).
    public func headHash() -> String? {
        let s = (try? git(["rev-parse", "--verify", "--quiet", "HEAD"]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    /// The value of git config `key` (all scopes), or nil when unset or empty.
    public func config(_ key: String) -> String? {
        let s = (try? git(["config", "--get", key]))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    /// The commit author from git's configuration (`user.name`, `user.email`).
    public func author() -> Author { Author(name: config("user.name") ?? "", email: config("user.email") ?? "") }

    /// Working-tree changes, both columns (porcelain v1).
    public func changes() throws -> [Change] {
        var out: [Change] = []
        let entries = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split(separator: "\0", omittingEmptySubsequences: true)
        let flat = try status()
        var i = 0
        while i < entries.count {
            let e = String(entries[i])
            i += 1
            guard e.count > 3 else { continue }
            let x = e[e.startIndex], y = e[e.index(after: e.startIndex)]
            if x == "R" || x == "C" { i += 1 }
            let path = root.appendingPathComponent(String(e.dropFirst(3))).path
            out.append(Change(path: path, index: x, worktree: y, status: flat[path] ?? .modified))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Stashes, newest first ("stash@{0}: On main: message").
    public func stashes() -> [String] {
        ((try? git(["stash", "list", "--format=%gd: %gs"])) ?? "").split(separator: "\n").map(String.init)
    }

    /// Branches checked out recently, newest first, from HEAD's reflog
    /// ("checkout: moving from A to B"), excluding the current branch.
    public func recentBranches(limit: Int = 5) -> [String] {
        let log = (try? git(["reflog", "show", "--format=%gs", "-n", "200", "HEAD"])) ?? ""
        let existing = Set(((try? branches()) ?? []).map(\.name))
        let current = currentBranch()
        var out: [String] = []
        for line in log.split(separator: "\n") where line.hasPrefix("checkout: moving from ") {
            let parts = line.dropFirst("checkout: moving from ".count).components(separatedBy: " to ")
            for name in parts.reversed() where existing.contains(name) && name != current && !out.contains(name) { out.append(name) }
            if out.count >= limit { break }
        }
        return Array(out.prefix(limit))
    }

    static let fieldSeparator = "\u{1f}", recordSeparator = "\u{1e}"

    /// The history of `ref` (newest first), optionally since a date.
    public func log(_ ref: String = "HEAD", since: Date? = nil, limit: Int = 500) -> [Commit] {
        var args = ["log", "--format=%H%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%G?%x1f%s%x1f%b%x1e", "-n", String(limit)]
        if let since { args.append("--since=@\(Int(since.timeIntervalSince1970))") }
        args += [ref, "--"]
        guard let text = try? git(args) else { return [] }
        return text.components(separatedBy: Self.recordSeparator).compactMap(Self.parseCommit)
    }

    /// The commit `hash` names (any revision git accepts), or nil.
    public func commit(_ hash: String) -> Commit? { log(hash, limit: 1).first }

    /// The commits that changed one file, newest first, following renames
    /// (`git log --follow`; the History inspector, reference-ui-5.md §7.4).
    public func history(ofFile path: String, limit: Int = 200) -> [Commit] {
        guard let rel = relative(path) else { return [] }
        let args = ["log", "--follow", "--format=%H%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%G?%x1f%s%x1f%b%x1e", "-n", String(limit), "--", rel]
        guard let text = try? git(args) else { return [] }
        return text.components(separatedBy: Self.recordSeparator).compactMap(Self.parseCommit)
    }

    static func parseCommit(_ record: String) -> Commit? {
        let f = record.trimmingCharacters(in: .newlines).components(separatedBy: fieldSeparator)
        guard f.count >= 8, f[0].count >= 7 else { return nil }
        var branches: [String] = [], tags: [String] = []
        for d in f[4].components(separatedBy: ", ") where !d.isEmpty {
            if d.hasPrefix("tag: ") { tags.append(String(d.dropFirst(5))) }
            else if d.hasPrefix("HEAD -> ") { branches.append(String(d.dropFirst(8))) }
            else if d != "HEAD" { branches.append(d) }
        }
        return Commit(hash: f[0], authorName: f[1], authorEmail: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0),
                      subject: f[6], body: f[7].trimmingCharacters(in: .whitespacesAndNewlines), branches: branches, tags: tags,
                      signature: f[5].isEmpty ? "N" : f[5])
    }

    /// The files a commit changed, with A/M/D letters (against its first
    /// parent; a root commit lists everything as added).
    public func files(in hash: String) -> [(path: String, status: FileStatus)] {
        let text = (try? git(["diff-tree", "--no-commit-id", "--name-status", "-r", "--root", "-M", hash])) ?? ""
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t").map(String.init)
            guard f.count >= 2, let c = f[0].first else { return nil }
            let status: FileStatus = switch c {
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            default: .modified
            }
            return (f[f.count - 1], status)
        }
    }

    /// Local branches containing a commit.
    public func branches(containing hash: String) -> [String] {
        ((try? git(["branch", "--format=%(refname:short)", "--contains", hash])) ?? "").split(separator: "\n").map(String.init)
    }

    /// The upstream of a local branch ("origin/main"), or nil.
    public func upstream(of branch: String) -> String? {
        let s = (try? git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", branch + "@{upstream}"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    }

    /// The remote a local branch tracks (`branch.<name>.remote`), or nil.
    public func remote(of branch: String) -> String? { config("branch.\(branch).remote") }

    public enum DiffScope: Int, Sendable { case all, unstaged, staged }

    /// A file's diff for a scope. Untracked files show all their content
    /// as added. The result is unified-diff text from git.
    public func diff(of path: String, scope: DiffScope) -> String {
        let rel = repoRelative(path)
        let untracked = (try? git(["ls-files", "--error-unmatch", "--", rel])) == nil
        if untracked {
            guard scope != .staged else { return "" }
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let lines = LineDiff.lines(text)
            return "@@ -0,0 +1,\(lines.count) @@\n" + lines.map { "+" + $0 }.joined(separator: "\n")
        }
        let args: [String] = switch scope {
        case .all: headHash() == nil ? ["diff", "--cached"] : ["diff", "HEAD"]
        case .unstaged: ["diff"]
        case .staged: ["diff", "--cached"]
        }
        let text = (try? git(args + ["--no-color", "--no-ext-diff", "-U3", "--", rel])) ?? ""
        // Drop the file header; keep hunks.
        guard let hunk = text.range(of: "\n@@") else { return text.hasPrefix("@@") ? text : "" }
        return String(text[text.index(after: hunk.lowerBound)...])
    }

    func repoRelative(_ path: String) -> String {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return p.hasPrefix(root.path + "/") ? String(p.dropFirst(root.path.count + 1)) : path
    }

    // MARK: Writing

    /// `git add` the given absolute or repository-relative paths. Throws
    /// `GitError` with git's message when git fails.
    public func stage(_ paths: [String]) throws { guard !paths.isEmpty else { return }; _ = try git(["add", "--"] + paths.map(repoRelative)) }
    /// Stages every change, including deletions and untracked files.
    public func stageAll() throws { _ = try git(["add", "-A"]) }

    /// Removes paths from the index, keeping the working-tree files. Before
    /// the first commit this is `git rm --cached`, else `git reset`.
    public func unstage(_ paths: [String]) throws {
        guard !paths.isEmpty else { return }
        if headHash() == nil { _ = try git(["rm", "--cached", "-q", "--"] + paths.map(repoRelative)) }
        else { _ = try git(["reset", "-q", "HEAD", "--"] + paths.map(repoRelative)) }
    }

    /// Unstages everything (works before the first commit too).
    public func unstageAll() throws {
        if headHash() == nil { _ = try git(["rm", "-r", "--cached", "-q", "."]) } else { _ = try git(["reset", "-q"]) }
    }

    /// Discards a file's changes: tracked files return to HEAD; untracked
    /// files go to the Trash (never deleted outright).
    public func discard(_ path: String) throws {
        let rel = repoRelative(path)
        if (try? git(["ls-files", "--error-unmatch", "--", rel])) == nil {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        } else if headHash() != nil, (try? git(["cat-file", "-e", "HEAD:" + rel])) != nil {
            _ = try git(["checkout", "HEAD", "--", rel])
        } else {
            // Added in the index only: unstage, then trash the file.
            _ = try git(["rm", "--cached", "-q", "--", rel])
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            }
        }
    }

    /// Commits what is staged (the commit editor). `amend` rewrites HEAD.
    @discardableResult
    public func commitStaged(message: String, amend: Bool = false) throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw GitError(description: "empty commit message") }
        _ = try git(["commit", "-q", "-m", message] + (amend ? ["--amend"] : []))
        return try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Marks conflicted files resolved by staging them.
    public func markResolved(_ paths: [String]) throws { try stage(paths) }

    /// Stashes all changes, untracked files included; an empty message lets
    /// git name the stash.
    public func stash(message: String) throws {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(["stash", "push", "--include-untracked"] + (m.isEmpty ? [] : ["-m", m]))
    }

    /// Applies commit `hash` on top of the current branch.
    public func cherryPick(_ hash: String) throws { _ = try git(["cherry-pick", hash]) }

    /// Switches to a local branch (`git switch`); refused while the working
    /// tree has conflicts (the debug bar's branch menu, reference-ui-5.md §6.2).
    public func switchBranch(_ name: String) throws {
        if (try? status())?.values.contains(.conflicted) == true {
            throw GitError(description: "The working copy has unresolved conflicts. Resolve them before switching branches.")
        }
        _ = try git(["switch", "--", name])
    }
    /// Fetches every remote, pruning deleted remote branches.
    public func fetch() throws { _ = try git(["fetch", "--all", "--prune"]) }
    /// Pulls the upstream branch; only fast-forwards, otherwise throws.
    public func pull() throws { _ = try git(["pull", "--ff-only"]) }
    /// Pushes the current branch to its upstream. git never prompts for
    /// credentials here, so a push that needs them fails with `GitError`.
    public func push() throws { _ = try git(["push"]) }

    /// `git init` in a folder, then the repository there.
    public static func initialize(at dir: URL, git: String = "/usr/bin/git") throws -> GitRepository? {
        _ = try run(git, ["-C", dir.path, "init", "-q"])
        return GitRepository(containing: dir, git: git)
    }

    /// `git clone` of `url` into `dir`. Throws `GitError` on failure.
    public static func clone(_ url: String, into dir: URL, git: String = "/usr/bin/git") throws {
        _ = try run(git, ["clone", "--", url, dir.path])
    }
}

/// Relative day labels and date formats of history rows and commit detail.
public enum GitDates {
    /// "Today", "Yesterday", or a medium date.
    public static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMM d, yyyy"
        return f.string(from: date)
    }

    /// "Oct 18, 2026 at 11:46 PM".
    public static func detail(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f.string(from: date)
    }
}

/// The history scope bar: All, Last 24 Hours, Last 7 Days, Last 30 Days.
public enum HistoryScope: Int, CaseIterable, Sendable {
    case all, day, week, month
    public static let titles = ["All", "Last 24 Hours", "Last 7 Days", "Last 30 Days"]
    public func since(now: Date = Date()) -> Date? {
        switch self {
        case .all: nil
        case .day: now.addingTimeInterval(-86_400)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        }
    }

    /// Commits in scope that match the filter (subject, author, hash).
    public func apply(_ commits: [GitRepository.Commit], filter: String, now: Date = Date()) -> [GitRepository.Commit] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let since = since(now: now)
        return commits.filter { c in
            (since.map { c.date >= $0 } ?? true)
                && (q.isEmpty || c.subject.lowercased().contains(q) || c.authorName.lowercased().contains(q)
                    || c.message.lowercased().contains(q) || c.hash.hasPrefix(q))
        }
    }
}
