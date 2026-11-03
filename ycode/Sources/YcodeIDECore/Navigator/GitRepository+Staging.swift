import Foundation

extension GitRepository {
    /// Stages paths the project navigator created, moved or trashed
    /// (`git add -A -- <path>`, which records additions, removals and, for
    /// both ends of a move, the rename, as `git mv` would). Paths outside the
    /// repository, ignored ones and ones git never saw are skipped. Runs
    /// git: call it off the main thread.
    public func stageNavigatorChanges(_ paths: [String]) {
        // Compare real paths (a temporary folder may be reached through a link).
        func real(_ p: String) -> String {
            let u = URL(fileURLWithPath: p).standardizedFileURL
            return u.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(u.lastPathComponent).path
        }
        let top = root.resolvingSymlinksInPath().path + "/"
        for p in Set(paths) {
            let full = real(p)
            guard full.hasPrefix(top) else { continue }
            _ = try? git(["add", "-A", "--", String(full.dropFirst(top.count))])
        }
    }
}
