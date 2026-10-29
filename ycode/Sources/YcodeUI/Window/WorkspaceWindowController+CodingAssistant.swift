import AppKit
import YcodeAssistant
import YcodeBuild

/// The window's coding assistant, made the first time it is shown or used.
final class CodingAssistantHolder: NSObject, NSPopoverDelegate {
    var controller: CodingAssistantViewController?
    var tokens: [NSObjectProtocol] = []
    var lastSettings: AssistantSettings?
    /// The review sheet on screen (tests drive it).
    weak var review: ProposalReviewController?
    /// The toolbar button's prompt while it is open (reference-ui-6.md §9.4).
    var prompt: NewConversationPromptController?
    var popover: NSPopover?

    func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            prompt = nil
            popover = nil
        }
    }
}

/// The coding assistant in the workspace window (specs/ide/coding-assistant.md):
/// the left area's Coding Assistant pane, File ▸ New ▸ Conversation (and in
/// a new tab or editor pane), the toolbar's New Conversation prompt,
/// Navigate ▸ Jump to Next Active Conversation, Editor ▸ Show Coding Tools,
/// and the review of proposed changes (reference-ui-6.md §9).
extension WorkspaceWindowController {
    /// The folder agent tools run in and proposal paths are relative to.
    public var workspaceFolder: URL {
        (session.model.kind == .package ? session.model.url : session.model.url.deletingLastPathComponent()).standardizedFileURL
    }

    public var codingAssistant: CodingAssistantViewController {
        if let c = codingAssistantHolder.controller { return c }
        let services = CodingAssistantServices.shared
        let prefs = services.preferences ?? .shared
        let model = CodingAssistantModel(workspaceRoot: workspaceFolder,
                                         archiveURL: Self.isTestProcess ? nil : CodingAssistantModel.archiveURL(forWorkspace: session.model.url),
                                         prefs: prefs, services: services)
        model.contextProvider = { [weak self] in self?.codingAssistantContext() ?? WorkspaceContext() }
        let c = CodingAssistantViewController(model: model)
        c.onReviewProposal = { [weak self] p, m, conversation in self?.reviewProposal(p, message: m, conversation: conversation) }
        c.onOpenSettings = { SettingsWindowController.shared.show(pane: CodingAssistantSettingsPane.paneTitle) }
        c.attachmentSource = { [weak self] in self?.currentAttachments() ?? (nil, nil) }
        codingAssistantHolder.controller = c
        navigator.assistantContent = c.view
        codingAssistantHolder.lastSettings = prefs.codingAssistant
        let center = NotificationCenter.default
        codingAssistantHolder.tokens = [
            center.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.codingAssistantSettingsChanged() }
            },
            // A key saved or a sign-in changed: check the back ends again.
            center.addObserver(forName: CodingAssistantSettingsPane.credentialsDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.codingAssistantHolder.controller?.model.refreshAvailability() }
            },
        ]
        model.refreshAvailability()
        return c
    }

    public var codingAssistantModel: CodingAssistantModel { codingAssistant.model }

    /// Back ends are checked again when their settings change.
    func codingAssistantSettingsChanged() {
        guard let c = codingAssistantHolder.controller else { return }
        let now = c.model.prefs.codingAssistant
        let before = codingAssistantHolder.lastSettings
        codingAssistantHolder.lastSettings = now
        guard now != before else { return }
        if now.ollamaURL != before?.ollamaURL || now.llamaCppURL != before?.llamaCppURL || now.openAIURL != before?.openAIURL
            || now.openAIAuth != before?.openAIAuth || now.toolPaths != before?.toolPaths {
            c.model.refreshAvailability()
        } else {
            c.apply(.status)
        }
    }

    /// Shows the Coding Assistant pane.
    func revealCodingAssistant() {
        if navigatorItem.isCollapsed || !navigator.showsCodingAssistant { setLeftPane(codingAssistant: true) }
    }

    // MARK: Commands

    /// File ▸ New ▸ Conversation (⌃⌘H): the prompt in the pane.
    @objc public func newConversation(_ sender: Any?) {
        revealCodingAssistant()
        codingAssistant.model.newConversation()
        codingAssistant.focusMessageField()
    }

    /// File ▸ New ▸ Conversation in New Tab (⌃⌥⌘H): the conversation in a
    /// new editor tab (reference-ui-6.md §9.5).
    @objc public func newConversationInNewTab(_ sender: Any?) {
        let id = codingAssistant.model.newConversation().id
        let e = editorArea.newTab()
        showConversation(id, in: e)
        editorArea.reloadTabBar()
    }

    /// File ▸ New ▸ Conversation in Editor Pane (⌃⌥⇧⌘H): the conversation
    /// in the next editor pane, made when there is only one.
    @objc public func newConversationInEditorPane(_ sender: Any?) {
        let id = codingAssistant.model.newConversation().id
        let t = editorArea.tab
        let panes = t.editors.filter { $0 !== t.assistant }
        let next: SourceEditorController
        if panes.count > 1, let i = panes.firstIndex(where: { $0 === t.focusedEditor }) {
            next = panes[(i + 1) % panes.count]
        } else {
            next = editorArea.split(sideBySide: true)
        }
        editorArea.focus(next)
        showConversation(id, in: next)
    }

    /// Shows one conversation (transcript and message field) in an editor.
    @discardableResult
    public func showConversation(_ id: UUID, in e: SourceEditorController) -> ConversationView {
        let model = codingAssistant.model
        let v = ConversationView(model: model, conversation: id)
        v.onReviewProposal = { [weak self] p, m, conversation in self?.reviewProposal(p, message: m, conversation: conversation) }
        v.onOpenSettings = { SettingsWindowController.shared.show(pane: CodingAssistantSettingsPane.paneTitle) }
        v.attachmentSource = { [weak self] in self?.currentAttachments() ?? (nil, nil) }
        let title = model.conversation(id)?.title ?? Conversation.untitled
        e.showText("", title: title)
        e.showAuxiliary(v, path: Self.conversationPath(title))
        v.onTitleChange = { [weak self, weak e, weak v] t in
            guard let self, let e, let v, e.auxiliary === v else { return }
            e.pathComponents = Self.conversationPath(t)
            editorArea.reloadTabBar()
        }
        updateWindowTitle()
        if window?.isVisible == true { window?.makeFirstResponder(v.messageView) }
        return v
    }

    static func conversationPath(_ title: String) -> [(String, String)] {
        [("Conversations", "bubble.left.and.bubble.right"), (title, "bubble.left")]
    }

    /// The toolbar's New Conversation: opens the prompt popover under the
    /// button, or closes it when it is open (reference-ui-6.md §9.4).
    @objc public func toggleNewConversationPrompt(_ sender: Any?) {
        if codingAssistantHolder.prompt != nil { closeNewConversationPrompt(); return }
        let model = codingAssistant.model
        let c = NewConversationPromptController(model: model)
        c.attachmentSource = { [weak self] in self?.currentAttachments() ?? (nil, nil) }
        c.onOpenSettings = { SettingsWindowController.shared.show(pane: CodingAssistantSettingsPane.paneTitle) }
        c.onCancel = { [weak self] in self?.closeNewConversationPrompt() }
        c.onSend = { [weak self] text, attachments in self?.startConversation(prompt: text, attachments: attachments) }
        codingAssistantHolder.prompt = c
        _ = c.view
        guard window?.isVisible == true,
              let item = window?.toolbar?.items.first(where: { $0.itemIdentifier == Self.newConversationID }) else { return }
        let p = NSPopover()
        p.contentViewController = c
        p.contentSize = NewConversationPromptController.size
        p.behavior = .transient
        p.delegate = codingAssistantHolder
        codingAssistantHolder.popover = p
        p.show(relativeTo: item)
    }

    /// The open prompt popover's content, if any.
    public var newConversationPrompt: NewConversationPromptController? { codingAssistantHolder.prompt }

    public func closeNewConversationPrompt() {
        let p = codingAssistantHolder.popover
        codingAssistantHolder.prompt = nil
        codingAssistantHolder.popover = nil
        p?.close()
    }

    /// Sending from the prompt: a new conversation in the pane.
    @discardableResult
    public func startConversation(prompt: String, attachments: [Attachment] = []) -> UUID? {
        closeNewConversationPrompt()
        revealCodingAssistant()
        let model = codingAssistant.model
        let id = model.newConversation().id
        return model.send(prompt, attachments: attachments, in: id)
    }

    /// Navigate ▸ Jump to Next Active Conversation (⌃⌘K).
    @objc public func jumpToNextActiveConversation(_ sender: Any?) {
        guard codingAssistant.model.selectNextActive() != nil else { return NSSound.beep() }
        revealCodingAssistant()
    }

    @objc public func codingToolExplain(_ sender: Any?) { runCodingTool(.explain) }
    @objc public func codingToolDocument(_ sender: Any?) { runCodingTool(.document) }
    @objc public func codingToolGeneratePlayground(_ sender: Any?) { runCodingTool(.generatePlayground) }
    @objc public func codingToolGeneratePreview(_ sender: Any?) { runCodingTool(.generatePreview) }

    @discardableResult
    public func runCodingTool(_ tool: CodingTool) -> UUID? {
        guard canRunCodingTool(tool) else { NSSound.beep(); return nil }
        revealCodingAssistant()
        return codingAssistant.model.run(tool)
    }

    /// Enabled with a provider set up (reference-ui-6.md §9.5, A4: until
    /// the back ends have been checked, assumed set up) and an editable file
    /// the tool applies to.
    public func canRunCodingTool(_ tool: CodingTool) -> Bool {
        guard let url = editor.fileURL, editor.textView.isEditable else { return false }
        if let m = codingAssistantHolder.controller?.model, !m.availability.isEmpty, !m.hasUsableBackend { return false }
        return tool.applies(toPath: url.path, text: editor.text)
    }

    /// Enablement of the assistant's menu items (nil: not one of them).
    func validateCodingAssistantItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(newConversation(_:)), #selector(newConversationInNewTab(_:)), #selector(newConversationInEditorPane(_:)),
             #selector(toggleNewConversationPrompt(_:)):
            return true
        // While the assistant is shown there is no navigator filter (§9.5, A7).
        case #selector(filterInNavigator(_:)): return shownLeftPane != .codingAssistant
        case #selector(jumpToNextActiveConversation(_:)):
            return codingAssistantHolder.controller.map { !$0.model.activeIDs.isEmpty } ?? false
        case #selector(codingToolExplain(_:)): return canRunCodingTool(.explain)
        case #selector(codingToolDocument(_:)): return canRunCodingTool(.document)
        case #selector(codingToolGeneratePlayground(_:)): return canRunCodingTool(.generatePlayground)
        case #selector(codingToolGeneratePreview(_:)): return canRunCodingTool(.generatePreview)
        default: return nil
        }
    }

    // MARK: Context

    func relativePath(_ url: URL) -> String {
        let root = workspaceFolder.path.hasSuffix("/") ? workspaceFolder.path : workspaceFolder.path + "/"
        let p = url.standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
    }

    /// The current editor's file and selection, the other open files and
    /// the workspace's issues.
    public func codingAssistantContext() -> WorkspaceContext {
        var ctx = WorkspaceContext(workspaceName: session.model.displayName)
        let e = editor
        if let url = e.fileURL {
            let text = e.text
            let path = relativePath(url)
            ctx.currentFile = .init(path: path, text: text)
            let sel = e.textView.selectedRange()
            let index = LineIndex(text)
            ctx.caretLine = index.line(at: sel.location)
            if sel.length > 0, NSMaxRange(sel) <= (text as NSString).length {
                let s = (text as NSString).substring(with: sel)
                let endOffset = max(sel.location, NSMaxRange(sel) - 1)
                ctx.selection = .init(path: path, startLine: index.line(at: sel.location), endLine: index.line(at: endOffset), text: s,
                                      location: sel.location, length: sel.length)
            }
        }
        var seen = Set(ctx.currentFile.map { [$0.path] } ?? [])
        for other in editorArea.allEditors where other !== e {
            guard let url = other.fileURL else { continue }
            let path = relativePath(url)
            if seen.insert(path).inserted { ctx.openFiles.append(.init(path: path, text: other.text)) }
        }
        ctx.issues = session.displayedIssues.prefix(100).map { d in
            WorkspaceContext.Issue(severity: d.severity.rawValue, message: d.message, path: d.location.map { relativePath(URL(fileURLWithPath: $0.file)) },
                                   line: d.location?.line)
        }
        return ctx
    }

    /// The attach menu's choices: the current file and the selection.
    func currentAttachments() -> (file: Attachment?, selection: Attachment?) {
        let ctx = codingAssistantContext()
        let file = ctx.currentFile.map { Attachment(kind: .file, path: $0.path, text: $0.text) }
        let sel = ctx.selection.map { Attachment(kind: .selection, path: $0.path, startLine: $0.startLine, endLine: $0.endLine, text: $0.text) }
        return (file, sel)
    }

    // MARK: Reviewing and applying proposals

    /// The proposal's file inside the workspace (nil when the path leaves it).
    func proposalURL(_ p: ChangeProposal) -> URL? {
        let url = workspaceFolder.appendingPathComponent(p.path).standardizedFileURL
        let root = workspaceFolder.path.hasSuffix("/") ? workspaceFolder.path : workspaceFolder.path + "/"
        return url.path.hasPrefix(root) ? url : nil
    }

    /// The text the change applies to: the open editor's (unsaved edits
    /// included) or the file's on disk; nil for a new file.
    func currentText(of url: URL) -> String? {
        if let e = editorArea.allEditors.first(where: { $0.fileURL?.standardizedFileURL == url }) { return e.text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Opens the review sheet. Returns it (tests accept or reject it).
    @discardableResult
    public func reviewProposal(_ p: ChangeProposal, message: ConversationMessage, conversation: UUID) -> ProposalReviewController? {
        guard let url = proposalURL(p) else {
            presentAssistantAlert("The proposal names a file outside the workspace (\(p.path)); it was not applied.")
            return nil
        }
        let original = currentText(of: url)
        let proposed: String
        do {
            proposed = try p.apply(to: original, target: message.target)
        } catch {
            presentAssistantAlert(error.localizedDescription)
            return nil
        }
        let review = ProposalReviewController(proposal: p, original: original, proposed: proposed)
        review.onDecision = { [weak self] ok in
            guard let self else { return }
            let applied = ok && applyProposal(url: url, original: original, proposed: proposed)
            codingAssistant.model.resolve(message: message.id, in: conversation, proposal: p.blockIndex, applied ? .accepted : .rejected)
        }
        codingAssistantHolder.review = review
        if let content = window?.contentViewController, window?.isVisible == true {
            content.presentAsSheet(review)
        } else {
            _ = review.view
        }
        return review
    }

    /// The review sheet on screen, if any.
    public var proposalReview: ProposalReviewController? { codingAssistantHolder.review }

    /// Applies an accepted change: into the file's editor as one undoable
    /// edit (opening the file first), or, for a new file, by creating it.
    /// The user saves the document; nothing else is written.
    func applyProposal(url: URL, original: String?, proposed: String) -> Bool {
        if original == nil {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try proposed.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                presentAssistantAlert("Ycode could not create \(url.lastPathComponent): \(error.localizedDescription)")
                return false
            }
            open(path: url.path, line: nil)
            return true
        }
        if editor.fileURL?.standardizedFileURL != url { open(path: url.path, line: nil) }
        guard editor.fileURL?.standardizedFileURL == url else { return false }
        return editor.replaceText(with: proposed, actionName: "Apply Coding Assistant Change") || editor.text == proposed
    }

    func presentAssistantAlert(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "The change can't be applied"
        alert.informativeText = text
        if let w = window, w.isVisible { alert.beginSheetModal(for: w) } else { NSSound.beep() }
    }
}
