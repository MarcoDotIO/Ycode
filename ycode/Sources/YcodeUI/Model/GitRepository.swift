import Foundation
import YcodeSubprocess

/// Read-only views of a git repository and a narrow commit operation,
/// through the `git` command-line tool. Every command runs with `-C` on
/// this repository's top level, so nothing touches other repositories.
/// See `specs/ide/source-control.md`.
public struct GitRepository: Sendable {
    public struct Ref: Equatable, Sendable {
        public var name: String
        public var isCurrent: Bool
    }

    public struct Remote: Equatable, Sendable {
        public var name: String
        public var url: String
    }

    /// Badge letters as the project navigator shows them.
    public enum FileStatus: String, Equatable, Sendable {
        case modified = "M", added = "A", deleted = "D", renamed = "R", untracked = "?", conflicted = "C"
    }

    public struct GitError: Error, CustomStringConvertible {
        public var description: String
    }

    public let root: URL
    public var git: String = "/usr/bin/git"

    /// The repository containing `path`, or nil when it is not in one.
    public init?(containing path: URL, git: String = "/usr/bin/git") {
        self.git = git
        let dir = (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? path : path.deletingLastPathComponent()
        guard let top = try? Self.run(git, ["-C", dir.path, "rev-parse", "--show-toplevel"]).trimmingCharacters(in: .whitespacesAndNewlines),
              !top.isEmpty else { return nil }
        root = URL(fileURLWithPath: top).standardizedFileURL
    }

    static func run(_ git: String, _ args: [String]) throws -> String {
        // Never prompt (credentials, editors) and never page.
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_PAGER"] = "cat"
        env["GIT_EDITOR"] = "true"
        // Reads never rewrite the index (git status refreshes its stat
        // cache otherwise): the window's file-system watcher would see
        // that write and read again.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Waits for git: debug builds check this is not the main thread.
        let r = try Subprocess.run(git, args, environment: env)
        guard r.status == 0 else { throw GitError(description: r.stderrText) }
        return r.stdoutText
    }

    func git(_ args: [String]) throws -> String { try Self.run(git, ["-C", root.path] + args) }

    // MARK: Reading

    public func branches() throws -> [Ref] { try refs("refs/heads") }
    public func tags() throws -> [Ref] { try refs("refs/tags") }
    public func remoteBranches() throws -> [Ref] { try refs("refs/remotes").filter { !$0.name.hasSuffix("/HEAD") } }

    func refs(_ prefix: String) throws -> [Ref] {
        // Full ref names, shortened here: `refname:short` turns
        // refs/remotes/origin/HEAD into plain "origin" in newer git.
        try git(["for-each-ref", "--format=%(HEAD)%09%(refname)", prefix])
            .split(separator: "\n").map { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                var name = parts.count > 1 ? parts[1] : parts[0]
                if name.hasPrefix(prefix + "/") { name = String(name.dropFirst(prefix.count + 1)) }
                return Ref(name: name, isCurrent: parts.first == "*")
            }
    }

    public func remotes() throws -> [Remote] {
        var seen = Set<String>()
        return try git(["remote", "-v"]).split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard f.count >= 2, seen.insert(f[0]).inserted else { return nil }
            return Remote(name: f[0], url: f[1])
        }
    }

    /// Working-tree status by absolute path (porcelain v1).
    public func status() throws -> [String: FileStatus] {
        var out: [String: FileStatus] = [:]
        let entries = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < entries.count {
            let e = String(entries[i])
            i += 1
            guard e.count > 3 else { continue }
            let x = e[e.startIndex], y = e[e.index(after: e.startIndex)]
            let path = root.appendingPathComponent(String(e.dropFirst(3))).path
            let status: FileStatus
            switch (x, y) {
            case ("?", "?"): status = .untracked
            case ("U", _), (_, "U"), ("A", "A"), ("D", "D"): status = .conflicted
            case ("R", _):
                status = .renamed
                i += 1 // the original path follows
            case ("A", _): status = .added
            case ("D", _), (_, "D"): status = .deleted
            default: status = .modified
            }
            out[path] = status
        }
        return out
    }

    /// A file's contents in HEAD (`git show HEAD:<path>`), or nil when the
    /// file is not in HEAD (new or untracked).
    public func headContents(of path: String) -> String? {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        guard p.hasPrefix(root.path + "/") else { return nil }
        return try? git(["show", "HEAD:" + String(p.dropFirst(root.path.count + 1))])
    }

    /// Unified diff text of a file, working copy against HEAD, from git
    /// itself: the commit sheet and the commit editor's cards show the
    /// same hunks.
    public func diff(of path: String) -> String { diff(of: path, scope: .all) }

    // MARK: Committing

    /// Stages exactly `files` (absolute paths inside this repository) and
    /// commits them with `message`. Returns the new commit's hash.
    @discardableResult
    public func commit(files: [String], message: String) throws -> String {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw GitError(description: "empty commit message") }
        let rel = try files.map { path -> String in
            let p = URL(fileURLWithPath: path).standardizedFileURL.path
            guard p.hasPrefix(root.path + "/") else { throw GitError(description: "\(path) is outside the repository") }
            return String(p.dropFirst(root.path.count + 1))
        }
        guard !rel.isEmpty else { throw GitError(description: "no files selected") }
        _ = try git(["add", "--"] + rel)
        _ = try git(["commit", "-m", message, "--"] + rel)
        return try git(["rev-parse", "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
