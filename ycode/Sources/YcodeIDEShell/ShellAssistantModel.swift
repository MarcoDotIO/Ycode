import Foundation
import Observation
import YcodeAssistant
import YcodeIDECore

/// The Linux IDE's Coding Assistant pane (`specs/ide/coding-assistant.md`
/// §4, issue #18) over the shared `CodingAssistantModel`: whether the left
/// area shows it, the message being written and its attachments, and the
/// review of proposed changes. The conversations, back ends, prompts and
/// streaming are the shared model's; this class mirrors its changes into
/// Observation (`revision`) so the SwiftUI views redraw, and applies
/// accepted changes through the workspace's editor. It has no toolkit
/// types, so it is tested headless on macOS and Linux.
@MainActor
@Observable
public final class ShellAssistantModel {
    @ObservationIgnored public weak var workspace: WorkspaceShellModel?

    /// The left area shows the pane instead of the navigators.
    public var isShown = false
    /// The shared model, made the first time the pane is shown or used.
    public private(set) var core: CodingAssistantModel?
    /// Bumped on every change of the shared model (views read it).
    public private(set) var revision = 0
    /// The message being written, and what goes with it.
    public var draft = ""
    public private(set) var attachments: [Attachment] = []
    /// The review sheet's change (Review…).
    public var review: AssistantChangeReview?
    /// "The change can't be applied" (a path outside the workspace, a
    /// selection that changed, a file that could not be created).
    public var alertText: String?
    /// Bumped when the message field should take the keyboard.
    public private(set) var focusCount = 0
    /// The toolbar's New Conversation prompt is open (`reference-ui-6.md`
    /// §9.4), and what is typed in it.
    public var isPromptShown = false
    public var promptDraft = ""
    /// The conversation or group whose title is being edited in the list.
    public var renamingID: UUID?
    public var renameText = ""
    /// Opens Settings ▸ Coding Assistant (set by the app).
    @ObservationIgnored public var onOpenSettings: (() -> Void)?
    /// The secret store, account and providers (nil: the app's
    /// `CodingAssistantServices.shared`; tests pass their own).
    @ObservationIgnored public var services: CodingAssistantServices?

    @ObservationIgnored private var lastSettings: AssistantSettings?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Proposal previews by message, block and text (the diff of a
    /// proposal is computed once per version of the file it changes).
    @ObservationIgnored private var previewCache: [String: AssistantChangePreview] = [:]
    /// The diff each decided proposal was accepted or rejected on (the
    /// file moves on afterwards), by message and block.
    @ObservationIgnored private var decidedDiffs: [String: AssistantChangeDiff] = [:]

    /// Posted by the settings pane when a key is saved or removed, or the
    /// OpenAI sign-in changes: back ends are checked again.
    public static let credentialsDidChange = Notification.Name("YcodeShellAssistantCredentialsDidChange")

    public init() {}

    // MARK: The shared model

    /// The shared model, made on first use: conversations saved per
    /// workspace with Ycode's user data (not in test processes), context
    /// from the workspace's editor, back ends checked at once.
    @discardableResult
    public func ensure() -> CodingAssistantModel {
        if let core { return core }
        let services = services ?? CodingAssistantServices.shared
        let prefs = services.preferences ?? .shared
        let root = workspace?.assistantFolder ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let archive = IDEProcess.isTestProcess ? nil : workspace.map { CodingAssistantModel.archiveURL(forWorkspace: $0.session.model.url) }
        let m = CodingAssistantModel(workspaceRoot: root, archiveURL: archive, prefs: prefs, services: services)
        m.contextProvider = { [weak self] in self?.workspace?.assistantContext() ?? WorkspaceContext() }
        m.observe(owner: self) { [weak self] _ in self?.revision &+= 1 }
        core = m
        lastSettings = prefs.codingAssistant
        // No delivery queue: on Linux, Foundation waits for a queued
        // observer to run, which deadlocks a poster on another thread.
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: Preferences.didChange, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in self?.settingsChanged() }
            },
            center.addObserver(forName: Self.credentialsDidChange, object: nil, queue: nil) { [weak self] _ in
                Task { @MainActor in _ = self?.core?.refreshAvailability() }
            },
        ]
        m.refreshAvailability()
        return m
    }

    /// Changed addresses, tool paths or the sign-in method: check the back
    /// ends again; other changes redraw.
    private func settingsChanged() {
        guard let core else { return }
        let now = core.settings, before = lastSettings
        lastSettings = now
        guard now != before else { return }
        if now.ollamaURL != before?.ollamaURL || now.llamaCppURL != before?.llamaCppURL || now.openAIURL != before?.openAIURL
            || now.openAIAuth != before?.openAIAuth || now.toolPaths != before?.toolPaths || now.acpCommand != before?.acpCommand {
            core.refreshAvailability()
        } else {
            revision &+= 1
        }
    }

    // MARK: What the pane shows

    public var outline: [ConversationLibrary.Node] { _ = revision; return core?.library.outline ?? [ConversationLibrary.Node.archive([])] }
    public var selectedID: UUID? { _ = revision; return core?.selectedID }
    public var selected: Conversation? { _ = revision; return core?.selected }
    public var groups: [ConversationGroup] { _ = revision; return core?.library.groups ?? [] }
    public var sourceLabel: String { _ = revision; return core?.sourceLabel ?? CodingAssistantModel.placeholderLabel }
    public var isSurveying: Bool { _ = revision; return core?.isSurveying ?? false }
    public var hasUsableBackend: Bool { _ = revision; return core?.hasUsableBackend ?? false }
    public var usesChatGPTPlan: Bool { _ = revision; return core?.usesChatGPTPlan ?? false }
    /// The selected conversation's response is streaming (Send reads Stop).
    public var isResponding: Bool {
        _ = revision
        guard let core, let id = core.selectedID else { return false }
        return core.isRunning(id)
    }
    public var hasActiveConversations: Bool { _ = revision; return !(core?.activeIDs.isEmpty ?? true) }
    public var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding }

    /// The note above the transcript when the chosen back end can't be
    /// used: its hint and "Use <ready back end>" choices (nil: none).
    public var status: AssistantStatus? {
        _ = revision
        guard let core else { return nil }
        if core.isSurveying && core.availability.isEmpty { return AssistantStatus(text: "Looking for models…", alternatives: [], checking: true) }
        guard let a = core.currentAvailability, !a.isReady else { return nil }
        if !core.hasUsableBackend { return AssistantStatus(text: AssistantBackends.noBackendText, alternatives: [], checking: false) }
        return AssistantStatus(text: "\(core.providerKind.displayName): " + (a.hint ?? "unavailable."),
                               alternatives: Array(core.readyProviders.prefix(3)), checking: false)
    }

    /// The model pull-down: each back end with its state and its models
    /// (coding-assistant.md §4).
    public var providerChoices: [AssistantProviderChoice] {
        _ = revision
        guard let core else { return [] }
        let currentModel = core.modelID ?? ""
        return ProviderKind.allCases.map { kind in
            let a = core.availability[kind]
            let models = a?.models ?? []
            let rows = models.isEmpty
                ? [AssistantProviderChoice.Model(id: nil, title: "Choose \(kind.displayName)", isCurrent: kind == core.providerKind)]
                : models.map { m in
                    AssistantProviderChoice.Model(id: m.id, title: m.displayName.isEmpty ? "Default" : m.displayName,
                                                  isCurrent: kind == core.providerKind && m.id == currentModel)
                }
            return AssistantProviderChoice(kind: kind, title: kind.displayName + Self.stateSuffix(a), isReady: a?.isReady == true, models: rows)
        }
    }

    public static func stateSuffix(_ a: ProviderAvailability?) -> String {
        switch a {
        case nil: " (checking…)"
        case .ready?: ""
        case .notRunning?: " (not running)"
        case .noModels?: " (no models)"
        case .notInstalled?: " (not installed)"
        case .signedOut?: " (not signed in)"
        case .failed?: " (unavailable)"
        }
    }

    // MARK: Showing the pane

    /// Shows the pane in the left area (making the model the first time).
    public func show() {
        ensure()
        isShown = true
        workspace?.isNavigatorShown = true
    }

    /// File ▸ New ▸ Conversation (⌃⌘H): the pane, a new conversation, the
    /// message field focused. An untouched new conversation is reused.
    public func newConversation() {
        show()
        core?.newConversation()
        focusCount &+= 1
    }

    /// The toolbar's New Conversation: opens its prompt, or closes it.
    public func togglePrompt() {
        ensure()
        isPromptShown.toggle()
    }

    /// Sending from the prompt: a new conversation in the pane.
    @discardableResult
    public func sendPrompt() -> UUID? {
        let text = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        isPromptShown = false
        promptDraft = ""
        show()
        let core = ensure()
        return core.send(text, in: core.newConversation().id)
    }

    /// Navigate ▸ Jump to Next Active Conversation (⌃⌘K).
    @discardableResult
    public func jumpToNextActive() -> Bool {
        guard let core, core.selectNextActive() != nil else { return false }
        show()
        return true
    }

    public func select(_ id: UUID) {
        ensure().selectedID = id
        renamingID = nil
    }

    public func openSettings() { onOpenSettings?() }
    public func checkAgain() { ensure().refreshAvailability() }
    public func choose(_ kind: ProviderKind, model: String?) { ensure().choose(kind, model: model) }

    // MARK: The list

    public func newGroup() {
        let g = ensure().newGroup()
        beginRename(g.id, title: g.title)
    }

    public func beginRename(_ id: UUID, title: String) {
        renamingID = id
        renameText = title
    }

    /// Ends the rename in the list (a conversation's or a group's title).
    public func commitRename() {
        guard let id = renamingID, let core else { return }
        renamingID = nil
        if core.library.groups.contains(where: { $0.id == id }) {
            core.renameGroup(id, to: renameText)
        } else {
            core.rename(id, to: renameText.trimmingCharacters(in: .whitespaces))
        }
    }

    public func delete(_ id: UUID) { core?.delete(id) }
    public func deleteGroup(_ id: UUID) { core?.deleteGroup(id) }
    public func setArchived(_ id: UUID, _ archived: Bool) { core?.setArchived(id, archived) }
    public func move(_ id: UUID, toGroup group: UUID?) { core?.move(id, toGroup: group) }

    // MARK: The message field

    /// The attach menu's choices: the current file and the selection.
    public var attachmentChoices: (file: Attachment?, selection: Attachment?) {
        guard let ctx = workspace?.assistantContext() else { return (nil, nil) }
        let file = ctx.currentFile.map { Attachment(kind: .file, path: $0.path, text: $0.text) }
        let sel = ctx.selection.map { Attachment(kind: .selection, path: $0.path, startLine: $0.startLine, endLine: $0.endLine, text: $0.text) }
        return (file, sel)
    }

    public func attach(_ a: Attachment) {
        if !attachments.contains(a) { attachments.append(a) }
    }

    public func removeAttachment(_ a: Attachment) { attachments.removeAll { $0 == a } }

    /// Send (Return): the message with its attachments in the selected
    /// conversation (a new one if none); the answer streams in.
    @discardableResult
    public func send() -> UUID? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isResponding else { return nil }
        let id = ensure().send(text, attachments: attachments)
        if id != nil {
            draft = ""
            attachments = []
        }
        return id
    }

    /// Stop: cancels the selected conversation's response.
    public func stop() {
        guard let core, let id = core.selectedID else { return }
        core.stop(id)
    }

    /// Continue after a reply cut off at the output limit.
    public func continueReply(in id: UUID) { core?.continueReply(in: id) }

    // MARK: Coding tools (Editor ▸ Show Coding Tools)

    /// Enabled for an editable file the tool applies to, while a back end
    /// is usable (assumed until the back ends were first checked).
    public func canRun(_ tool: CodingTool) -> Bool {
        guard let w = workspace, let e = w.editor, e.readOnlyReason == nil else { return false }
        if let core, !core.availability.isEmpty, !core.hasUsableBackend { return false }
        return tool.applies(toPath: e.path, text: e.buffer.text)
    }

    @discardableResult
    public func run(_ tool: CodingTool) -> UUID? {
        guard canRun(tool) else { return nil }
        show()
        return core?.run(tool)
    }

    // MARK: Proposals

    /// The proposals in a response (closed blocks only).
    public func proposals(in message: ConversationMessage) -> [ChangeProposal] {
        guard message.role == .assistant else { return [] }
        return ChangeProposal.parse(message.text, target: message.target)
    }

    /// Proposals not yet accepted or rejected.
    public func undecided(in message: ConversationMessage) -> [ChangeProposal] {
        proposals(in: message).filter { message.resolvedProposals[$0.blockIndex] == nil }
    }

    /// What accepting the proposal would do: the file's change as a diff,
    /// or why it can't be applied.
    public func preview(_ p: ChangeProposal, in message: ConversationMessage) -> AssistantChangePreview {
        guard let w = workspace else { return .failed("No workspace is open.") }
        guard let path = w.assistantPath(p.path) else {
            return .failed("The proposal names a file outside the workspace (\(p.path)); it can't be applied.")
        }
        let original = w.assistantCurrentText(path)
        let key = "\(message.id) \(p.blockIndex) \(p.text.hashValue) \(original?.hashValue ?? 0)"
        if let cached = previewCache[key] { return cached }
        let proposed: String
        do {
            proposed = try ensure().agentProposalText(message: message.id, block: p.blockIndex) ?? p.apply(to: original, target: message.target)
        } catch {
            return .failed(error.localizedDescription)
        }
        let r = AssistantChangePreview.ready(AssistantChangeDiff(path: path, relativePath: p.path, original: original, proposed: proposed))
        if previewCache.count > 200 { previewCache = [:] }
        previewCache[key] = r
        return r
    }

    /// Accept: the change goes into the file's editor (opened first) as
    /// one undoable edit, unsaved; a new file is created and opened. Agent
    /// changes are saved too (the agent builds from disk next).
    @discardableResult
    public func accept(_ p: ChangeProposal, message: ConversationMessage, conversation: UUID) -> Bool {
        guard message.resolvedProposals[p.blockIndex] == nil else { return false }
        guard case .ready(let diff) = preview(p, in: message), let w = workspace else {
            if case .failed(let why) = preview(p, in: message) { alertText = why }
            return false
        }
        let isAgent = core?.agentProposalText(message: message.id, block: p.blockIndex) != nil
        decidedDiffs["\(message.id) \(p.blockIndex)"] = diff
        var applied = false
        if let error = w.applyAssistantChange(diff, save: isAgent) { alertText = error } else { applied = true }
        core?.resolve(message: message.id, in: conversation, proposal: p.blockIndex, applied ? .accepted : .rejected)
        return applied
    }

    /// Reject: nothing changes; the block is marked Rejected.
    public func reject(_ p: ChangeProposal, message: ConversationMessage, conversation: UUID) {
        guard message.resolvedProposals[p.blockIndex] == nil else { return }
        if case .ready(let d) = preview(p, in: message) { decidedDiffs["\(message.id) \(p.blockIndex)"] = d }
        core?.resolve(message: message.id, in: conversation, proposal: p.blockIndex, .rejected)
    }

    /// Accept All: every undecided proposal of the response, in order.
    public func acceptAll(in message: ConversationMessage, conversation: UUID) {
        for p in undecided(in: message) {
            // The message is read again: an accepted change can move the
            // text the next selection proposal applies to.
            guard let m = core?.conversation(conversation)?.messages.first(where: { $0.id == message.id }) else { return }
            accept(p, message: m, conversation: conversation)
        }
    }

    public func rejectAll(in message: ConversationMessage, conversation: UUID) {
        for p in undecided(in: message) { reject(p, message: message, conversation: conversation) }
    }

    /// The diff a decided proposal was decided on (nil after a relaunch).
    public func decidedDiff(_ p: ChangeProposal, in message: ConversationMessage) -> AssistantChangeDiff? {
        decidedDiffs["\(message.id) \(p.blockIndex)"]
    }

    /// Review…: the change side by side in a sheet.
    public func openReview(_ p: ChangeProposal, message: ConversationMessage, conversation: UUID) {
        if message.resolvedProposals[p.blockIndex] != nil, let d = decidedDiff(p, in: message) {
            review = AssistantChangeReview(conversation: conversation, message: message.id, proposal: p, diff: d,
                                           decided: message.resolvedProposals[p.blockIndex])
            return
        }
        switch preview(p, in: message) {
        case .failed(let why): alertText = why
        case .ready(let diff):
            review = AssistantChangeReview(conversation: conversation, message: message.id, proposal: p, diff: diff,
                                           decided: message.resolvedProposals[p.blockIndex])
        }
    }

    public func acceptReview() {
        guard let r = review else { return }
        review = nil
        guard let m = core?.conversation(r.conversation)?.messages.first(where: { $0.id == r.message }) else { return }
        accept(r.proposal, message: m, conversation: r.conversation)
    }

    public func rejectReview() {
        guard let r = review else { return }
        review = nil
        guard let m = core?.conversation(r.conversation)?.messages.first(where: { $0.id == r.message }) else { return }
        reject(r.proposal, message: m, conversation: r.conversation)
    }

    /// The text shown for a proposal's code block ("Proposed: …").
    public static func proposalTitle(_ p: ChangeProposal) -> String {
        switch p.kind {
        case .wholeFile: "Proposed: \(p.path)"
        case .replaceSelection: "Proposed: replace the selection in \((p.path as NSString).lastPathComponent)"
        case .append: "Proposed: add to \((p.path as NSString).lastPathComponent)"
        }
    }
}

extension CodingAssistantModel {
    /// The pull-down's title before the model exists.
    static let placeholderLabel = "Coding Assistant"
}

/// The status note above the transcript.
public struct AssistantStatus: Equatable, Sendable {
    public var text: String
    /// Ready back ends offered as "Use <name>".
    public var alternatives: [ProviderKind]
    public var checking: Bool
}

/// One back end in the model pull-down.
public struct AssistantProviderChoice: Equatable, Sendable, Identifiable {
    public struct Model: Equatable, Sendable {
        /// nil: the back end has no models listed (choosing it sets the
        /// back end; the pane then says how to make it ready).
        public var id: String?
        public var title: String
        public var isCurrent: Bool
    }
    public var kind: ProviderKind
    /// "Ollama (not running)".
    public var title: String
    public var isReady: Bool
    public var models: [Model]
    public var id: String { kind.rawValue }
}

/// What a proposal would change.
public enum AssistantChangePreview: Equatable, Sendable {
    case ready(AssistantChangeDiff)
    case failed(String)
}

/// A proposed change to one file, as a diff: the file's current text (the
/// open editor's, unsaved edits included, else the disk's; nil for a new
/// file) and the text with the change.
public struct AssistantChangeDiff: Equatable, Sendable {
    public var path: String
    public var relativePath: String
    public var original: String?
    public var proposed: String
    public let lines: [AssistantDiffLine]
    public let rows: [LineDiff.Row]
    public let added: Int
    public let removed: Int

    public init(path: String, relativePath: String, original: String?, proposed: String) {
        self.path = path
        self.relativePath = relativePath
        self.original = original
        self.proposed = proposed
        let ops = LineDiff.diff(LineDiff.lines(original ?? ""), LineDiff.lines(proposed))
        lines = AssistantDiffLine.unified(ops)
        rows = LineDiff.sideBySide(ops)
        added = ops.filter { if case .added = $0 { true } else { false } }.count
        removed = ops.filter { if case .removed = $0 { true } else { false } }.count
    }

    public var name: String { (path as NSString).lastPathComponent }
    public var isNewFile: Bool { original == nil }

    /// The review's title: "Change Model.swift: +3 −1 lines" or "Create
    /// Sources/New.swift" (coding-assistant.md §5.3).
    public var title: String {
        isNewFile ? "Create \(relativePath)" : "Change \(name): +\(added) \u{2212}\(removed) lines"
    }

    public var currentTitle: String { "\(name) (Current)" }
    public var proposedTitle: String { "\(name) (Proposed)" }

    public static func == (a: Self, b: Self) -> Bool {
        a.path == b.path && a.original == b.original && a.proposed == b.proposed
    }
}

/// One line of a compact unified diff: old and new line numbers, or a
/// separator between the change's parts.
public struct AssistantDiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed, gap }
    public var kind: Kind
    public var old: Int?
    public var new: Int?
    public var text: String

    /// The changed lines with `context` unchanged lines around each.
    public static func unified(_ ops: [LineDiff.Op], context: Int = 3) -> [AssistantDiffLine] {
        var numbered: [AssistantDiffLine] = []
        var o = 0, n = 0
        for op in ops {
            switch op {
            case .same(let s): o += 1; n += 1; numbered.append(.init(kind: .context, old: o, new: n, text: s))
            case .removed(let s): o += 1; numbered.append(.init(kind: .removed, old: o, new: nil, text: s))
            case .added(let s): n += 1; numbered.append(.init(kind: .added, old: nil, new: n, text: s))
            }
        }
        let changed = numbered.indices.filter { numbered[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(numbered.count - 1, c + context) { keep.insert(k) } }
        var out: [AssistantDiffLine] = []
        var last = -1
        for k in keep.sorted() {
            if last >= 0, k != last + 1 { out.append(.init(kind: .gap, old: nil, new: nil, text: "")) }
            out.append(numbered[k])
            last = k
        }
        return out
    }
}

/// The review sheet's change.
public struct AssistantChangeReview: Identifiable, Equatable, Sendable {
    public var conversation: UUID
    public var message: UUID
    public var proposal: ChangeProposal
    public var diff: AssistantChangeDiff
    /// Already accepted or rejected (the sheet then only shows it).
    public var decided: ProposalResolution?
    public var id: String { "\(message) \(proposal.blockIndex)" }
    public var acceptTitle: String { diff.isNewFile ? "Create File" : "Accept" }
}

/// Inline Markdown in a response's prose (coding-assistant.md §4: code
/// spans and emphasis), as styled runs a view joins into one text.
public enum AssistantInline {
    public struct Run: Equatable, Sendable {
        public var text: String
        public var code = false
        public var bold = false
        public var italic = false
    }

    public static func runs(_ s: String) -> [Run] {
        var out: [Run] = []
        var i = s.startIndex
        var plain = ""
        var bold = false, italic = false
        func flush() {
            if !plain.isEmpty { out.append(Run(text: plain, bold: bold, italic: italic)) }
            plain = ""
        }
        while i < s.endIndex {
            let c = s[i]
            if c == "`", let end = s[s.index(after: i)...].firstIndex(of: "`") {
                flush()
                out.append(Run(text: String(s[s.index(after: i)..<end]), code: true))
                i = s.index(after: end)
                continue
            }
            if c == "*" || c == "_" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == c {
                    // "**" (or "__") toggles bold when it opens before a
                    // word or closes after one.
                    flush()
                    bold.toggle()
                    i = s.index(after: next)
                    continue
                }
                let before = i > s.startIndex ? s[s.index(before: i)] : " "
                let after = next < s.endIndex ? s[next] : " "
                if (italic && !before.isWhitespace) || (!italic && !after.isWhitespace && (before.isWhitespace || before.isPunctuation)) {
                    flush()
                    italic.toggle()
                    i = next
                    continue
                }
            }
            plain.append(c)
            i = s.index(after: i)
        }
        flush()
        return out
    }
}
