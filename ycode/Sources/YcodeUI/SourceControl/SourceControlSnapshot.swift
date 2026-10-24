import Foundation

/// Everything a workspace window shows from git outside the commit editor
/// and history: the project navigator's status letters, the Source Control
/// navigator (both modes), the Integrate menu's enablement, the debug
/// bar's branch. Read in one go on a background thread
/// (`read(workspace:known:)`); the window keeps the last one and the user
/// interface reads only that, so no menu update or redraw waits for git.
public struct SourceControlSnapshot: Sendable {
    /// The repository holding the workspace; nil outside git.
    public var repository: GitRepository?
    public var status: [String: GitRepository.FileStatus] = [:]
    public var changes: [GitRepository.Change] = []
    public var currentBranch: String?
    /// HEAD's commit (nil: unborn).
    public var head: String?
    public var branches: [GitRepository.Ref] = []
    public var recentBranches: [String] = []
    public var tags: [GitRepository.Ref] = []
    public var stashes: [String] = []
    public var remotes: [GitRepository.Remote] = []
    public var remoteBranches: [GitRepository.Ref] = []
    /// The debug bar's branch (`GitBranchLookup.current(at:)` of the
    /// workspace folder).
    public var debugBarBranch: String?

    public init(repository: GitRepository? = nil) { self.repository = repository }

    /// Whether the index or HEAD may differ between the two reads (the
    /// editors' change bars then re-read their baselines).
    func baselinesMayDiffer(from other: SourceControlSnapshot) -> Bool {
        repository?.root != other.repository?.root || head != other.head || currentBranch != other.currentBranch || changes != other.changes
    }

    /// Reads the snapshot; finds the repository first unless `known` holds
    /// it (`.some(nil)`: known to be outside git). Runs git: never call it
    /// on the main thread. `branchFolder` is the debug bar's folder.
    public static func read(workspace: URL, known: GitRepository??, branchFolder: String?) -> SourceControlSnapshot {
        let repo: GitRepository? = known ?? GitRepository(containing: workspace)
        var s = SourceControlSnapshot(repository: repo)
        s.debugBarBranch = branchFolder.flatMap(GitBranchLookup.current(at:))
        guard let repo else { return s }
        s.status = (try? repo.status()) ?? [:]
        s.remotes = (try? repo.remotes()) ?? []
        s.branches = (try? repo.branches()) ?? []
        s.tags = (try? repo.tags()) ?? []
        s.remoteBranches = (try? repo.remoteBranches()) ?? []
        s.currentBranch = repo.currentBranch()
        s.head = repo.headHash()
        s.changes = (try? repo.changes()) ?? []
        s.recentBranches = repo.recentBranches()
        s.stashes = repo.stashes()
        return s
    }
}
