import AppKit
import YcodeAssistant

/// One workspace window's coding assistant: its conversations, the
/// responses streaming into them, and the back ends' states. The view
/// (`CodingAssistantViewController`) observes it through `onChange`.
/// See specs/ide/coding-assistant.md §4.
@MainActor
public final class CodingAssistantModel {
    public enum Change: Equatable {
        /// The conversation list or the selection changed.
        case list
        /// The conversation's transcript changed.
        case transcript(UUID)
        /// Back-end states, the chosen provider or model changed.
        case status
    }

    public private(set) var conversations: [Conversation] = []
    /// The conversation list's groups (reference-ui-6.md §9.2).
    public private(set) var groups: [ConversationGroup] = []
    public var selectedID: UUID? { didSet { if oldValue != selectedID { notify(.list) } } }
    public private(set) var availability: [ProviderKind: ProviderAvailability] = [:]
    public private(set) var isSurveying = false
    public var onChange: ((Change) -> Void)?
    /// Further observers (the pane, conversations shown in editors); an
    /// observer is dropped when its owner goes away.
    private var observers: [(owner: Weak, f: (Change) -> Void)] = []
    final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }

    public let prefs: Preferences
    public let services: CodingAssistantServices
    /// The workspace folder: agent tools run here; proposal paths are
    /// relative to it.
    public let workspaceRoot: URL
    /// The current editor's context for each request.
    public var contextProvider: () -> WorkspaceContext = { WorkspaceContext() }
    /// Where conversations are saved (nil: not saved).
    public let archiveURL: URL?
    private var running: [UUID: Task<Void, Never>] = [:]
    /// Transcript refreshes are coalesced while text streams.
    private var pendingRefresh: Set<UUID> = []
    private var refreshScheduled = false

    public init(workspaceRoot: URL, archiveURL: URL?, prefs: Preferences = .shared, services: CodingAssistantServices = .shared) {
        self.workspaceRoot = workspaceRoot
        self.archiveURL = archiveURL
        self.prefs = prefs
        self.services = services
        let library = archiveURL.map(ConversationArchive.loadLibrary) ?? ConversationLibrary()
        conversations = library.conversations
        groups = library.groups
        selectedID = conversations.last { !$0.isArchived }?.id
    }

    /// Calls `f` with every change while `owner` exists.
    public func observe(owner: AnyObject, _ f: @escaping (Change) -> Void) {
        observers.append((Weak(owner), f))
    }

    func notify(_ change: Change) {
        onChange?(change)
        observers.removeAll { $0.owner.object == nil }
        for o in observers { o.f(change) }
    }

    /// The list as the pane shows it.
    public var library: ConversationLibrary { ConversationLibrary(conversations: conversations, groups: groups) }

    /// Conversations are kept with Ycode's user data, one file per
    /// workspace (never inside the workspace).
    public static func archiveURL(forWorkspace url: URL) -> URL {
        let id = SHA256.hash(Data(url.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ycode/Conversations/\(id).json")
    }

    public var selected: Conversation? { conversations.first { $0.id == selectedID } }
    public func conversation(_ id: UUID) -> Conversation? { conversations.first { $0.id == id } }
    public var settings: AssistantSettings { prefs.codingAssistant }

    // MARK: Back ends

    /// The provider chosen in the pop-up (Settings ▸ Coding Assistant).
    public var providerKind: ProviderKind { settings.provider }

    /// The chosen model, or the provider's first.
    public var modelID: String? {
        let chosen = settings.model(for: providerKind)
        let models = availability[providerKind]?.models ?? []
        if let chosen, models.isEmpty || models.contains(where: { $0.id == chosen }) { return chosen }
        return models.first?.id
    }

    public var modelName: String? {
        let id = modelID
        return availability[providerKind]?.models.first { $0.id == id }?.displayName ?? id
    }

    /// "Ollama · qwen2.5-coder:latest".
    public var sourceLabel: String {
        guard let m = modelName, !m.isEmpty else { return providerKind.displayName }
        return "\(providerKind.displayName) · \(m)"
    }

    public var readyProviders: [ProviderKind] { ProviderKind.allCases.filter { availability[$0]?.isReady == true } }
    public var hasUsableBackend: Bool { !readyProviders.isEmpty }
    public var currentAvailability: ProviderAvailability? { availability[providerKind] }

    /// Uses the ChatGPT plan (the composer says so).
    public var usesChatGPTPlan: Bool { providerKind == .openAI && settings.openAIAuth == .chatGPT }

    public func choose(_ kind: ProviderKind, model: String?) {
        var s = settings
        s.provider = kind
        if let model { s.setModel(model, for: kind) }
        prefs.codingAssistant = s
        notify(.status)
    }

    /// Checks every back end again.
    @discardableResult
    public func refreshAvailability() -> Task<Void, Never> {
        isSurveying = true
        notify(.status)
        let services = services, prefs = prefs
        return Task { [weak self] in
            let result = await services.survey(prefs: prefs)
            guard let self else { return }
            availability = result
            isSurveying = false
            notify(.status)
        }
    }

    // MARK: Conversations

    @discardableResult
    public func newConversation() -> Conversation {
        // An untouched new conversation is reused.
        if let s = selected, s.messages.isEmpty { return s }
        let c = Conversation(provider: providerKind, model: modelID)
        conversations.append(c)
        selectedID = c.id
        notify(.list)
        save()
        return c
    }

    public func delete(_ id: UUID) {
        stop(id)
        conversations.removeAll { $0.id == id }
        if selectedID == id { selectedID = conversations.last { !$0.isArchived }?.id }
        notify(.list)
        save()
    }

    // MARK: Groups and the archive (reference-ui-6.md §9.2)

    /// Adds a group ("New Group", numbered when taken).
    @discardableResult
    public func newGroup(title: String? = nil) -> ConversationGroup {
        let g = ConversationGroup(title: title ?? library.unusedGroupTitle())
        groups.append(g)
        notify(.list)
        save()
        return g
    }

    public func renameGroup(_ id: UUID, to title: String) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        groups[i].title = t.isEmpty ? ConversationGroup.untitled : t
        notify(.list)
        save()
    }

    /// Deletes the group; its conversations move to the top level.
    public func deleteGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
        for i in conversations.indices where conversations[i].groupID == id { conversations[i].groupID = nil }
        notify(.list)
        save()
    }

    /// Files the conversation in a group (nil: the top level); an archived
    /// conversation comes back out of the archive.
    public func move(_ id: UUID, toGroup group: UUID?) {
        update(id) { c in
            c.groupID = group
            c.isArchived = false
        }
        notify(.list)
        save()
    }

    public func setArchived(_ id: UUID, _ archived: Bool) {
        update(id) { $0.isArchived = archived }
        notify(.list)
        save()
    }

    public func rename(_ id: UUID, to title: String) {
        update(id) { $0.title = title.isEmpty ? Conversation.untitled : title }
        notify(.list)
        save()
    }

    /// Conversations whose response is streaming.
    public var activeIDs: [UUID] { conversations.filter(\.isActive).map(\.id) }
    public func isRunning(_ id: UUID) -> Bool { running[id] != nil }
    /// The task streaming the conversation's response (tests await it).
    public func response(_ id: UUID) -> Task<Void, Never>? { running[id] }

    /// Navigate ▸ Jump to Next Active Conversation: the next conversation
    /// (after the selected one, wrapping) with a response in progress.
    @discardableResult
    public func selectNextActive() -> UUID? {
        let active = conversations.filter(\.isActive)
        guard !active.isEmpty else { return nil }
        let order = conversations.map(\.id)
        let current = selectedID.flatMap { order.firstIndex(of: $0) } ?? -1
        let next = active.first { order.firstIndex(of: $0.id)! > current } ?? active[0]
        selectedID = next.id
        return next.id
    }

    func update(_ id: UUID, _ f: (inout Conversation) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        f(&conversations[i])
    }

    /// Sends a message in the selected conversation (a new one if none) and
    /// streams the answer. Returns the conversation's ID.
    @discardableResult
    public func send(_ text: String, attachments: [Attachment] = [], newConversationTitle: String? = nil, in target: UUID? = nil) -> UUID? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return nil }
        var id = target.flatMap { conversation($0)?.id } ?? selected.map(\.id) ?? newConversation().id
        if newConversationTitle != nil {
            id = newConversation().id
        }
        guard !isRunning(id) else { return nil }
        let context = contextProvider()
        let kind = providerKind, model = modelID
        let history = conversation(id)?.history ?? []
        update(id) { c in
            if c.messages.isEmpty { c.title = newConversationTitle ?? Conversation.title(fromPrompt: prompt) }
            c.provider = kind
            c.model = model
            c.messages.append(ConversationMessage(role: .user, text: prompt, attachments: attachments))
            c.messages.append(ConversationMessage(role: .assistant, text: "", source: sourceLabel, isComplete: false,
                                                  target: context.proposalTarget))
        }
        if model == nil && kind.cliAgent == nil {
            // Nothing to send to: say why instead of failing at the server.
            let why = availability[kind]?.hint ?? "Choose a model in the model menu."
            finish(id, error: "No \(kind.displayName) model is available. " + why)
            return id
        }
        let provider = services.provider(kind, prefs: prefs)
        let limit = settings.contextLimit, options = settings.context, root = workspaceRoot
        let knownWindow = availability[kind]?.models.first { $0.id == model }?.contextWindow
        running[id] = Task { [weak self] in
            var window = knownWindow
            if window == nil, let model { window = await provider.contextWindow(model: model) }
            let budget = min(limit, window ?? limit)
            let built = PromptBuilder.build(history: history, prompt: prompt, attachments: attachments, context: context,
                                            options: options, contextTokens: budget)
            let request = ChatRequest(model: model, instructions: built.instructions, messages: built.messages,
                                      contextTokens: kind == .ollama ? budget : nil, workingDirectory: root)
            if !built.omitted.isEmpty {
                self?.appendActivity(id, "Left out to fit the context: " + built.omitted.joined(separator: ", "))
            }
            do {
                for try await event in provider.send(request) {
                    guard let self else { return }
                    switch event {
                    case .text(let t): appendText(id, t)
                    case .activity(let a): appendActivity(id, a)
                    case .finished: break
                    }
                }
                // A cancelled stream ends without an error.
                self?.finish(id, error: Task.isCancelled ? "Stopped." : nil)
            } catch {
                let stopped = Task.isCancelled || error is CancellationError || HTTPCancellation.matches(error)
                self?.finish(id, error: stopped ? "Stopped." : Self.describe(error))
            }
        }
        notify(.list)
        notify(.transcript(id))
        return id
    }

    /// Stops the conversation's response (the stop button).
    public func stop(_ id: UUID) {
        running[id]?.cancel()
    }

    public func stopAll() { for id in Array(running.keys) { stop(id) } }

    /// The coding tools (Editor ▸ Show Coding Tools): a new conversation
    /// with the tool's prompt and the selection or file attached.
    @discardableResult
    public func run(_ tool: CodingTool) -> UUID? {
        let ctx = contextProvider()
        guard let file = ctx.currentFile else { return nil }
        var attachments: [Attachment] = []
        let name = (file.path as NSString).lastPathComponent
        var title = "\(tool.title) \(name)"
        if let s = ctx.selection, !s.text.isEmpty {
            attachments.append(Attachment(kind: .selection, path: s.path, startLine: s.startLine, endLine: s.endLine, text: s.text))
            title = "\(tool.title) \(attachments[0].label)"
        } else {
            attachments.append(Attachment(kind: .file, path: file.path, text: file.text))
        }
        return send(tool.prompt(path: file.path, hasSelection: ctx.selection.map { !$0.text.isEmpty } ?? false),
                    attachments: attachments, newConversationTitle: title)
    }

    func appendText(_ id: UUID, _ t: String) {
        update(id) { c in if let i = c.messages.indices.last { c.messages[i].text += t } }
        scheduleRefresh(id)
    }

    func appendActivity(_ id: UUID, _ a: String) {
        update(id) { c in if let i = c.messages.indices.last { c.messages[i].activity.append(a) } }
        scheduleRefresh(id)
    }

    func finish(_ id: UUID, error: String?) {
        running[id] = nil
        update(id) { c in
            guard let i = c.messages.indices.last, c.messages[i].role == .assistant else { return }
            c.messages[i].isComplete = true
            c.messages[i].error = error
        }
        pendingRefresh.remove(id)
        notify(.transcript(id))
        notify(.list)
        save()
    }

    /// Marks a proposal accepted or rejected.
    public func resolve(message: UUID, in conversationID: UUID, proposal index: Int, _ r: ProposalResolution) {
        update(conversationID) { c in
            if let i = c.messages.firstIndex(where: { $0.id == message }) { c.messages[i].resolvedProposals[index] = r }
        }
        notify(.transcript(conversationID))
        save()
    }

    private func scheduleRefresh(_ id: UUID) {
        pendingRefresh.insert(id)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                let ids = self.pendingRefresh
                self.pendingRefresh = []
                for id in ids { self.notify(.transcript(id)) }
            }
        }
    }

    func save() {
        guard let archiveURL else { return }
        let snapshot = library
        // One queue, in order: a later snapshot is never overwritten by an
        // earlier one.
        Self.saveQueue.async { try? ConversationArchive.save(snapshot, to: archiveURL) }
    }

    static let saveQueue = DispatchQueue(label: "dev.ycode.conversations", qos: .utility)

    /// The text shown for a failed response.
    static func describe(_ error: Error) -> String {
        if let e = error as? AssistantError {
            return [e.errorDescription, e.recoverySuggestion].compactMap { $0 }.joined(separator: " ")
        }
        return error.localizedDescription
    }
}

enum HTTPCancellation {
    static func matches(_ e: Error) -> Bool { HTTP.isCancellation(e) }
}
