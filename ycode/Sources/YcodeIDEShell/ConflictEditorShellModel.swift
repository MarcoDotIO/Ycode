import Foundation
import Observation
import YcodeIDECore

/// The merge sheet's model in the SwiftUI shell (`specs/ide/merge-sheet.md`
/// §3–§9; `source-control.md`, "Conflicts"): the core's
/// `ConflictEditorState`, which the AppKit `MergeSheetController` draws
/// too, plus the git reads and writes it needs, always off the main actor.
/// Every conflicted file is read ahead (Merge needs every file decided) and
/// keeps its choices while another is shown. The source-control model
/// shows the sheet and performs Merge and Cancel
/// (`SourceControlShellModel+Conflicts.swift`).
@MainActor
@Observable
public final class ConflictEditorShellModel {
    @ObservationIgnored public let repository: GitRepository
    public internal(set) var state = ConflictEditorState(source: .repository)
    /// The file list: Flat instead of Hierarchical (§3).
    public var isFlat = false
    /// The file list's Filter field.
    public var filterText = ""
    /// Counts the stepper's and the conflict navigator's moves: the panes
    /// scroll the selected change into view (a click on a change does not).
    public private(set) var revealCount = 0
    /// The repository's folder is a Swift package (the jump bar's symbol).
    @ObservationIgnored public let isPackage: Bool
    /// The hand editor's text while the selected change is written by hand
    /// (Ycode's choice: double-click a change's left lines).
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

    @ObservationIgnored private var pending: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextPending = 0
    @ObservationIgnored private var showGeneration = 0
    @ObservationIgnored private let focus: String?

    public init(repository: GitRepository, focus: String? = nil) {
        self.repository = repository
        self.focus = focus
        isPackage = FileManager.default.fileExists(atPath: repository.root.appendingPathComponent("Package.swift").path)
    }

    /// Whether a read or write runs.
    public var isLoading: Bool { !pending.isEmpty }

    /// The file list's rows as shown (§3).
    public var fileRows: [ConflictEditorState.FileRow] {
        state.fileRows(root: repository.root.path, flat: isFlat, filter: filterText)
    }

    /// The jump bar's path (§4.1).
    /// The workspace's project: the jump bar starts with it (§13.7).
    @ObservationIgnored public var project: MergeSheetProject?
    public var jumpPath: [String] { state.jumpPath(root: repository.root.path, project: project) }

    // MARK: Loading

    /// Reads the conflicted files, the operation, the footers and every
    /// file not read yet, then shows the focused (or shown) file while it is
    /// conflicted, else the first. Choices made so far are kept.
    public func reload() {
        let repo = repository, wanted = state.currentFile ?? focus
        let known = Set(state.files.filter { state.sheetDocument($0) != nil })
        track { [weak self] in
            let read = await Task.detached { () -> ([String], GitRepository.IntegrationState, (MergeSheetFooter?, MergeSheetFooter?), [String: MergeDocument]) in
                let files = repo.conflictedFiles(), integration = repo.integrationState()
                let labels = repo.conflictLabels(integration)
                let footers = MergeSheetFooter.read(repo, integration: integration, oursLabel: labels.ours, theirsLabel: labels.theirs)
                var docs: [String: MergeDocument] = [:]
                for f in files where !known.contains(f) { docs[f] = repo.mergeDocument(forConflictedFile: f) }
                return (files, integration, footers, docs)
            }.value
            guard let self else { return }
            _ = self.state.update(integration: read.1, conflicted: read.0)
            self.state.files = read.0
            self.state.leftFooter = read.2.0
            self.state.rightFooter = read.2.1
            for (f, d) in read.3 { self.state.prefetch(file: f, document: d) }
            let target = ConflictEditorState.target(wanted: wanted, in: read.0)
            if target != self.state.currentFile || self.state.document == nil {
                self.state.show(file: target, document: target.flatMap { read.3[$0] })
                self.editorText = self.state.editedText
            }
        }
    }

    /// The window's latest read of git: a changed list of conflicted files
    /// is read again (a file resolved elsewhere moves the sheet on).
    public func update(integration: GitRepository.IntegrationState, conflicted: [String]) {
        guard pending.isEmpty else { return }
        if conflicted != state.files {
            reload()
        } else {
            state.integration = integration
        }
    }

    /// Shows one conflicted file, keeping the choices made in the others.
    public func show(file: String?) async {
        let repo = repository
        guard let file else {
            state.show(file: nil, document: nil)
            editorText = ""
            return
        }
        // The shown file again: nothing to do (the core's `show` would
        // reload it without its choices).
        if file == state.currentFile, state.document != nil { return }
        if state.sheetDocument(file) != nil {
            state.show(file: file, document: nil)
            editorText = state.editedText
            return
        }
        showGeneration += 1
        let generation = showGeneration
        await track { [weak self] in
            let doc = await Task.detached { repo.mergeDocument(forConflictedFile: file) }.value
            // A later show replaced this one.
            guard let self, generation == self.showGeneration else { return }
            self.state.show(file: file, document: doc)
            self.editorText = self.state.editedText
        }.value
    }

    /// A file row's click.
    public func showFile(_ path: String) {
        track { [weak self] in await self?.show(file: path) }
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

    // MARK: Changes

    /// Selects a change (a row's click, the stepper, the conflict navigator).
    public func selectHunk(_ h: Int?) { state.selectHunk(h); editorText = state.editedText }
    /// The stepper's › and the conflict navigator's next (§8, §4.1).
    public func nextHunk() { state.nextHunk(); editorText = state.editedText; revealCount += 1 }
    /// The stepper's ‹.
    public func previousHunk() { state.previousHunk(); editorText = state.editedText; revealCount += 1 }

    /// The Choose menu of change `h`'s token (§7): selects the change, then
    /// rewrites the left pane's lines; the change stays selected.
    public func choose(_ choice: MergeDocument.Choice, forHunk h: Int) {
        state.choose(choice, forHunk: h)
        editorText = state.editedText
    }

    /// A choice for the selected change (it stays selected).
    public func choose(_ choice: MergeDocument.Choice) {
        state.chooseKeepingSelection(choice)
        editorText = state.editedText
    }

    /// Hand editing (Ycode's choice): the selected change becomes
    /// hand-written, starting from what it has.
    public func beginEditing() {
        state.beginEditing()
        editorText = state.editedText
    }

    // MARK: Writing

    /// Mark as Resolved (the file row's menu, Integrate ▸ Mark as Resolved):
    /// writes the shown file's result and stages it, then reads the list
    /// again. False when it was refused.
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
        reload()
        await idle()
        return true
    }

    /// Merge's first step (§9): writes every decided file and stages it.
    /// The first failure, or nil.
    public func writeResolutions() async -> String? {
        let repo = repository, items = state.resolutions
        var error: String?
        await track {
            error = await Task.detached { () -> String? in
                for r in items {
                    do { try repo.resolveConflict(r.file, text: r.text) } catch let e as GitRepository.GitError {
                        return e.errorDescription ?? e.description
                    } catch { return "\(error)" }
                }
                return nil
            }.value
        }.value
        state.lastError = error
        return error
    }
}
