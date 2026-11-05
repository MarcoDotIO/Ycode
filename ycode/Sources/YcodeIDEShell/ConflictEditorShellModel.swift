import Foundation
import Observation
import YcodeIDECore

/// The conflict editor in the SwiftUI shell (`specs/ide/comparison.md`,
/// "Conflict editor"; `source-control.md`, "Conflicts"): the core's
/// `ConflictEditorState`, which the AppKit `ConflictEditorController`
/// draws too, plus the git reads and writes it needs, always off the main
/// actor. The source-control model shows it over the editor area and
/// performs Continue and Abort.
@MainActor
@Observable
public final class ConflictEditorShellModel {
    @ObservationIgnored public let repository: GitRepository
    public private(set) var state = ConflictEditorState(source: .repository)
    /// The hand editor's text while the selected hunk is written by hand.
    public var editedText: String {
        get { editorText }
        set {
            editorText = newValue
            state.setEditedText(newValue)
        }
    }
    private var editorText = ""

    /// A file was marked resolved (the window reads git again).
    @ObservationIgnored public var onResolved: (() -> Void)?
    @ObservationIgnored public var onContinue: (() -> Void)?
    @ObservationIgnored public var onAbort: (() -> Void)?

    @ObservationIgnored private var pending: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextPending = 0
    @ObservationIgnored private var showGeneration = 0
    @ObservationIgnored private let focus: String?

    public init(repository: GitRepository, focus: String? = nil) {
        self.repository = repository
        self.focus = focus
    }

    /// Whether a read or write runs.
    public var isLoading: Bool { !pending.isEmpty }

    // MARK: Loading

    /// Re-reads the conflicted files and the operation in progress, then
    /// shows the focused (or shown) file while it is conflicted, else the
    /// first.
    public func reload() {
        let repo = repository, wanted = state.currentFile ?? focus
        track { [weak self] in
            let read = await Task.detached { () -> ([String], GitRepository.IntegrationState) in
                (repo.conflictedFiles(), repo.integrationState())
            }.value
            guard let self else { return }
            self.state.files = read.0
            self.state.integration = read.1
            await self.show(file: ConflictEditorState.target(wanted: wanted, in: read.0))
        }
    }

    /// The window's latest read of git: a file resolved elsewhere moves
    /// the editor on to the next one.
    public func update(integration: GitRepository.IntegrationState, conflicted: [String]) {
        guard pending.isEmpty else { return }
        if case .show(let next) = state.update(integration: integration, conflicted: conflicted) {
            track { [weak self] in await self?.show(file: next) }
        }
    }

    /// Shows one conflicted file.
    public func show(file: String?) async {
        let repo = repository
        state.currentFile = file
        guard let file else { load(nil); return }
        showGeneration += 1
        let generation = showGeneration
        await track { [weak self] in
            let doc = await Task.detached { repo.mergeDocument(forConflictedFile: file) }.value
            // A later show replaced this one.
            guard let self, generation == self.showGeneration, self.state.currentFile == file else { return }
            self.load(doc)
        }.value
    }

    /// The file pop-up's choice.
    public func showFile(at index: Int) {
        guard state.files.indices.contains(index) else { return }
        let f = state.files[index]
        track { [weak self] in await self?.show(file: f) }
    }

    private func load(_ doc: MergeDocument?) {
        state.load(doc)
        editorText = state.editedText
    }

    /// Runs `body` on the main actor as a tracked task; it removes itself
    /// as its last step, so `idle()` never waits on a finished one.
    @discardableResult
    func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        nextPending += 1
        let id = nextPending
        let t = Task { @MainActor [weak self] in
            await body()
            self?.pending[id] = nil
        }
        pending[id] = t
        return t
    }

    /// Waits until no read or write runs (tests, drivers).
    public func idle() async {
        while let t = pending.values.first { await t.value }
    }

    // MARK: Hunks

    public func selectHunk(_ h: Int) { state.selectHunk(h); editorText = state.editedText }
    public func nextHunk() { state.nextHunk(); editorText = state.editedText }
    public func previousHunk() { state.previousHunk(); editorText = state.editedText }

    /// A choice for the selected hunk (moves on to the next undecided one).
    public func choose(_ choice: MergeDocument.Choice) {
        state.choose(choice)
        editorText = state.editedText
    }

    /// The choice control's segment (Edit opens the hand editor).
    public func chooseSegment(_ i: Int) {
        state.chooseSegment(i)
        editorText = state.editedText
    }

    /// Edit: the selected hunk becomes hand-written.
    public func beginEditing() {
        state.beginEditing()
        editorText = state.editedText
    }

    public func setPair(_ p: ConflictEditorState.Pair) { state.setPair(p) }

    // MARK: Actions

    /// Mark as Resolved: writes the result and stages the file, then shows
    /// the next conflicted file. False when it was refused.
    @discardableResult
    public func markResolved() async -> Bool {
        guard state.canMarkResolved, let file = state.currentFile, let doc = state.document else { return false }
        let repo = repository, text = doc.result
        await track { [weak self] in
            let error = await Task.detached { () -> String? in
                do { try repo.resolveConflict(file, text: text); return nil } catch let e as GitRepository.GitError {
                    return e.errorDescription ?? e.description
                } catch { return "\(error)" }
            }.value
            self?.state.lastError = error
        }.value
        guard state.lastError == nil else { return false }
        onResolved?()
        // The resolved file stays shown until the next one is read (it is
        // no longer conflicted, so the reload moves on).
        reload()
        await idle()
        return true
    }

    public func continueIntegration() { onContinue?() }
    public func abortIntegration() { onAbort?() }
}
