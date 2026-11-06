import Foundation

extension GitRepository {
    /// A stash's changes as a patch (`git stash show -p --binary`; git's
    /// documentation of `stash show`), for Export Stashed Changes as Patch
    /// File… (`specs/ide/merge-sheet.md` §1.1).
    public func stashPatch(_ ref: String) throws -> String {
        guard ref.hasPrefix("stash@{") else { throw GitError(description: "\(ref) is not a stash") }
        return try git(["stash", "show", "-p", "--binary", ref])
    }

    /// Writes a stash's patch to `url`.
    public func exportStash(_ ref: String, to url: URL) throws {
        try stashPatch(ref).write(to: url, atomically: true, encoding: .utf8)
    }
}
