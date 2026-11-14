import Foundation

/// The clang module cache that preview compiles share
/// (`specs/ide/previews.md` §Fast updates, "Module cache location").
///
/// A module cache records absolute paths. After its folder moves (a project
/// copied or moved to another drive, or a symlinked folder pointed at a new
/// place), reusing it can crash the compiler. So each cache carries a stamp
/// beside it, `<cache>.location`, holding the cache's real path (symlinks
/// resolved). A cache whose stamp is missing or names another place is
/// discarded before use, and a compile that crashes is retried once with an
/// empty cache.
public enum PreviewModuleCache {
    /// Serializes check, discard and stamp within this process, so two
    /// compiles starting together don't discard each other's fresh cache.
    private static let lock = NSLock()

    /// The stamp file of `cache`.
    public static func stampURL(for cache: URL) -> URL {
        let c = cache.standardizedFileURL
        return c.deletingLastPathComponent().appendingPathComponent(c.lastPathComponent + ".location")
    }

    /// The real path `cache` is at now, as written in its stamp.
    static func location(of cache: URL) -> String {
        cache.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Makes `cache` ready for a compile and returns it (standardized). A
    /// cache made for another location, or one without a stamp, is removed
    /// first; the stamp then names the current location.
    @discardableResult
    public static func prepare(_ cache: URL) -> URL {
        let c = cache.standardizedFileURL
        let fm = FileManager.default
        lock.lock()
        defer { lock.unlock() }
        let stamp = stampURL(for: c)
        // Resolve after the folder exists, so a symlink in the path and the
        // real path give the same answer.
        try? fm.createDirectory(at: c, withIntermediateDirectories: true)
        let here = location(of: c)
        let recorded = (try? String(contentsOf: stamp, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        if recorded != here {
            if recorded != nil || !isEmptyDirectory(c) {
                try? fm.removeItem(at: c)
                try? fm.createDirectory(at: c, withIntermediateDirectories: true)
            }
            try? (here + "\n").write(to: stamp, atomically: true, encoding: .utf8)
        }
        return c
    }

    /// Empties `cache` and stamps it for its current location.
    public static func discard(_ cache: URL) {
        let c = cache.standardizedFileURL
        lock.lock()
        try? FileManager.default.removeItem(at: c)
        try? FileManager.default.removeItem(at: stampURL(for: c))
        lock.unlock()
        prepare(c)
    }

    /// Whether a compiler log shows the compiler itself crashed (as opposed
    /// to reporting errors in the code).
    public static func looksLikeCompilerCrash(_ log: String) -> Bool {
        let l = log.lowercased()
        return l.contains("failed due to signal") || l.contains("stack dump:")
            || l.contains("please submit a bug report") || l.contains("segmentation fault")
    }

    /// Runs `compile`; if it failed with a compiler crash, empties `cache`
    /// and runs it once more.
    public static func retryingAfterCrash<R>(_ cache: URL, _ compile: () throws -> R, crashed: (R) -> Bool) rethrows -> R {
        let first = try compile()
        guard crashed(first) else { return first }
        discard(cache)
        return try compile()
    }

    private static func isEmptyDirectory(_ url: URL) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }
}
