import AppKit
import YcodeAssistant

/// One conversation's transcript and message field (coding-assistant.md
/// §4): the back end's status, the transcript (Markdown, code blocks,
/// proposals), the attachment chips, and the message field with the attach
/// menu, the provider and model pull-down and Send / Stop. The Coding
/// Assistant pane shows the selected conversation; a conversation opened
/// in an editor tab or pane (File ▸ New ▸ Conversation in New Tab / in
/// Editor Pane, reference-ui-6.md §9.5) shows that one only.
@MainActor
public final class ConversationView: NSView {
    public let model: CodingAssistantModel
    /// The conversation shown; nil follows the list's selection.
    public let fixedID: UUID?
    /// Opens a proposal's review sheet (the window applies accepted changes).
    public var onReviewProposal: ((ChangeProposal, ConversationMessage, UUID) -> Void)?
    /// Opens Settings ▸ Coding Assistant.
    public var onOpenSettings: (() -> Void)?
    /// The current file and selection, for the attach menu.
    public var attachmentSource: (() -> (file: Attachment?, selection: Attachment?))?
    /// The shown conversation's title changed (an editor's jump bar follows it).
    public var onTitleChange: ((String) -> Void)?

    public let providerPopUp = NSPopUpButton(frame: .zero, pullsDown: true)
    public let statusLabel = NSTextField(wrappingLabelWithString: "")
    public let statusButtons = NSStackView()
    let statusBox = NSStackView()
    public let transcript = NSStackView()
    let transcriptScroll = NSScrollView()
    public let messageView = ComposerTextView()
    public let sendButton = NSButton()
    public let attachButton = NSPopUpButton(frame: .zero, pullsDown: true)
    public let planLabel = NSTextField(labelWithString: "Using ChatGPT plan · Manage usage in ChatGPT settings")
    let chips = NSStackView()
    /// Attachments for the next message.
    public private(set) var pendingAttachments: [Attachment] = []
    private var renderedID: UUID?
    private var renderedCount = 0
    private var lastTitle: String?

    public init(model: CodingAssistantModel, conversation: UUID? = nil) {
        self.model = model
        fixedID = conversation
        super.init(frame: .zero)
        build()
        model.observe(owner: self) { [weak self] change in self?.apply(change) }
        reloadAll()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The conversation shown.
    public var conversationID: UUID? { fixedID ?? model.selectedID }
    public var conversation: Conversation? { conversationID.flatMap(model.conversation) }

    func build() {
        // Status (back end not running, no models, …).
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true
        statusButtons.orientation = .horizontal
        statusButtons.spacing = 6
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.spacing = 6
        statusBox.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        statusBox.addArrangedSubview(statusLabel)
        statusBox.addArrangedSubview(statusButtons)

        // Transcript.
        transcript.orientation = .vertical
        transcript.alignment = .leading
        transcript.spacing = 10
        transcript.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        transcript.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(transcript)
        transcriptScroll.documentView = doc
        transcriptScroll.hasVerticalScroller = true
        transcriptScroll.drawsBackground = false
        transcriptScroll.autohidesScrollers = true
        transcriptScroll.setAccessibilityLabel("Transcript")

        // Composer.
        messageView.isRichText = false
        messageView.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageView.onSubmit = { [weak self] in self?.sendClicked() }
        messageView.setAccessibilityLabel("Message")
        messageView.textContainerInset = NSSize(width: 4, height: 4)
        let messageScroll = ComposerScrollView()
        messageScroll.documentView = messageView
        messageScroll.hasVerticalScroller = true
        messageView.isVerticallyResizable = true
        messageView.minSize = NSSize(width: 0, height: 0)
        messageView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        messageView.autoresizingMask = [.width]
        messageView.textContainer?.widthTracksTextView = true
        AttachMenu.configure(attachButton, target: self, action: #selector(attachChosen(_:)))
        // The provider and model (the header's pull-down before
        // reference-ui-6.md §9.2 left the header to New Conversation and
        // New Group).
        providerPopUp.controlSize = .small
        providerPopUp.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        providerPopUp.isBordered = false
        providerPopUp.setAccessibilityLabel("Model")
        providerPopUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sendButton.bezelStyle = .rounded
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.keyEquivalent = ""
        planLabel.font = .systemFont(ofSize: 10)
        planLabel.textColor = .secondaryLabelColor
        planLabel.lineBreakMode = .byTruncatingTail
        planLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chips.orientation = .horizontal
        chips.spacing = 4
        let bottom = NSStackView(views: [attachButton, providerPopUp, NSView(), sendButton])
        bottom.orientation = .horizontal
        bottom.spacing = 6

        for v in [statusBox, transcriptScroll, chips, messageScroll, bottom, planLabel] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        let planGap = planLabel.topAnchor.constraint(equalTo: bottom.bottomAnchor, constant: 2)
        NSLayoutConstraint.activate([
            statusBox.topAnchor.constraint(equalTo: topAnchor),
            statusBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: statusBox.bottomAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            transcriptScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            doc.topAnchor.constraint(equalTo: transcriptScroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: transcriptScroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: transcriptScroll.contentView.widthAnchor),
            transcript.topAnchor.constraint(equalTo: doc.topAnchor),
            transcript.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            transcript.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            transcript.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            chips.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 4),
            chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            chips.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            messageScroll.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 4),
            messageScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            messageScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            messageScroll.heightAnchor.constraint(equalToConstant: 64),
            bottom.topAnchor.constraint(equalTo: messageScroll.bottomAnchor, constant: 4),
            bottom.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            bottom.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            planGap,
            planLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            planLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            planLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    // MARK: Updates

    func apply(_ change: CodingAssistantModel.Change) {
        switch change {
        case .list:
            renderTranscript(force: conversationID != renderedID)
            updateComposer()
            noteTitle()
        case .transcript(let id):
            if id == conversationID { renderTranscript(force: false) }
            updateComposer()
        case .status:
            reloadProviderMenu()
            updateStatus()
            updateComposer()
        }
    }

    func reloadAll() {
        reloadProviderMenu()
        updateStatus()
        renderTranscript(force: true)
        updateComposer()
        noteTitle()
    }

    func noteTitle() {
        guard let t = conversation?.title, t != lastTitle else { return }
        lastTitle = t
        onTitleChange?(t)
    }

    // MARK: Provider and model

    func reloadProviderMenu() {
        providerPopUp.menu = ProviderMenu.build(model, target: self, choose: #selector(menuChoice(_:)),
                                                checkAgain: #selector(refreshClicked), settings: #selector(settingsClicked))
        providerPopUp.toolTip = "Model: \(model.sourceLabel)"
    }

    /// The model choices in the pull-down, as "Provider/Model" (tests).
    public var modelChoiceTitles: [String] { ProviderMenu.choiceTitles(providerPopUp.menu) }

    @objc func menuChoice(_ item: NSMenuItem) {
        guard let c = item.representedObject as? ProviderMenu.Choice else { return }
        model.choose(c.kind, model: c.model)
    }

    @objc func refreshClicked() { model.refreshAvailability() }
    @objc func settingsClicked() { onOpenSettings?() }

    // MARK: Status / empty state

    /// The text shown above the transcript when the chosen back end can't
    /// be used (nil when it can).
    public var statusText: String? { statusBox.isHidden ? nil : statusLabel.stringValue }

    func updateStatus() {
        statusButtons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let a = model.currentAvailability
        if model.isSurveying && model.availability.isEmpty {
            statusLabel.stringValue = "Looking for models…"
            statusBox.isHidden = false
            return
        }
        guard let a, !a.isReady else { statusBox.isHidden = true; return }
        if !model.hasUsableBackend {
            statusLabel.stringValue = AssistantBackends.noBackendText
        } else {
            statusLabel.stringValue = "\(model.providerKind.displayName): " + (a.hint ?? "unavailable.")
            for k in model.readyProviders.prefix(3) {
                let b = ClosureButton(title: "Use \(k.displayName)", target: nil, action: nil)
                b.bezelStyle = .inline
                b.onChange = { [weak self] _ in self?.model.choose(k, model: nil) }
                statusButtons.addArrangedSubview(b)
            }
        }
        for (title, action) in [("Check Again", #selector(refreshClicked)), ("Settings…", #selector(settingsClicked))] {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .inline
            statusButtons.addArrangedSubview(b)
        }
        statusBox.isHidden = false
    }

    // MARK: Transcript

    func renderTranscript(force: Bool) {
        let conv = conversation
        let messages = conv?.messages ?? []
        if force || conv?.id != renderedID || messages.count != renderedCount {
            transcript.arrangedSubviews.forEach { $0.removeFromSuperview() }
            if messages.isEmpty {
                let text: String
                if fixedID != nil && conv == nil {
                    text = "This conversation was deleted."
                } else if model.hasUsableBackend || model.availability.isEmpty {
                    text = "Ask a question about your code, or select code and choose Editor ▸ Show Coding Tools."
                } else {
                    text = AssistantBackends.noBackendText
                }
                let hint = NSTextField(wrappingLabelWithString: text)
                hint.textColor = .secondaryLabelColor
                hint.font = .systemFont(ofSize: 11)
                transcript.addArrangedSubview(hint)
            }
            for m in messages { addMessageView(m, conversation: conv!.id) }
        } else if let last = messages.last, let lastView = transcript.arrangedSubviews.last {
            // Streaming: rebuild only the last message.
            lastView.removeFromSuperview()
            addMessageView(last, conversation: conv!.id)
        }
        renderedID = conv?.id
        renderedCount = messages.count
        scrollToEnd()
    }

    func scrollToEnd() {
        transcript.layoutSubtreeIfNeeded()
        guard let doc = transcriptScroll.documentView else { return }
        doc.layoutSubtreeIfNeeded()
        let y = max(0, doc.frame.height - transcriptScroll.contentView.bounds.height)
        transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
    }

    func addMessageView(_ m: ConversationMessage, conversation: UUID) {
        let v = MessageView(message: m, proposals: m.role == .assistant && m.isComplete ? ChangeProposal.parse(m.text, target: m.target) : [])
        v.onReview = { [weak self] p in self?.onReviewProposal?(p, m, conversation) }
        v.translatesAutoresizingMaskIntoConstraints = false
        transcript.addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: transcript.widthAnchor, constant: -16).isActive = true
    }

    /// The transcript's message views (tests).
    public var messageViews: [MessageView] { transcript.arrangedSubviews.compactMap { $0 as? MessageView } }

    // MARK: Composer

    func updateComposer() {
        let running = conversationID.map(model.isRunning) ?? false
        sendButton.title = running ? "Stop" : "Send"
        sendButton.image = NSImage(systemSymbolName: running ? "stop.fill" : "arrow.up.circle.fill", accessibilityDescription: nil)
        sendButton.imagePosition = .imageLeading
        sendButton.toolTip = running ? "Stop the response" : "Send (Return)"
        sendButton.isEnabled = !(fixedID != nil && conversation == nil)
        planLabel.isHidden = !model.usesChatGPTPlan
        messageView.placeholder = "Ask \(model.sourceLabel)"
        messageView.needsDisplay = true
    }

    @objc public func sendClicked() {
        if let id = conversationID, model.isRunning(id) {
            model.stop(id)
            return
        }
        if fixedID != nil && conversation == nil { return NSSound.beep() }
        let text = messageView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if model.send(text, attachments: pendingAttachments, in: fixedID) != nil {
            messageView.string = ""
            pendingAttachments = []
            renderChips()
        }
    }

    @objc func attachChosen(_ sender: NSPopUpButton) {
        guard let src = attachmentSource?() else { return }
        let a = sender.indexOfSelectedItem == 1 ? src.file : src.selection
        guard let a else { NSSound.beep(); return }
        attach(a)
    }

    public func attach(_ a: Attachment) {
        guard !pendingAttachments.contains(a) else { return }
        pendingAttachments.append(a)
        renderChips()
    }

    func renderChips() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, a) in pendingAttachments.enumerated() {
            let b = ClosureButton(title: a.label + "  ✕", target: nil, action: nil)
            b.bezelStyle = .inline
            b.controlSize = .small
            b.toolTip = "Remove \(a.path) from the message"
            b.onChange = { [weak self] _ in
                guard let self, i < pendingAttachments.count else { return }
                pendingAttachments.remove(at: i)
                renderChips()
            }
            chips.addArrangedSubview(b)
        }
    }

    public func focusMessageField() { window?.makeFirstResponder(messageView) }
}

/// The paperclip pull-down: attach the current file or the selection.
enum AttachMenu {
    @MainActor static func configure(_ b: NSPopUpButton, target: AnyObject, action: Selector) {
        b.isBordered = false
        b.removeAllItems()
        b.addItem(withTitle: "")
        b.item(at: 0)?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach")
        b.addItems(withTitles: ["Attach Current File", "Attach Selection"])
        b.target = target
        b.action = action
        b.toolTip = "Attach the current file or selection"
        b.setAccessibilityLabel("Attach")
        (b.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
    }
}

/// The provider and model pull-down's menu: "Provider · Model" as its
/// title, each back end with its state and its models under it (the
/// current one checked), then Check Again and Coding Assistant Settings….
@MainActor
enum ProviderMenu {
    final class Choice: NSObject {
        let kind: ProviderKind
        let model: String?
        init(kind: ProviderKind, model: String?) { self.kind = kind; self.model = model }
    }

    static func build(_ model: CodingAssistantModel, target: AnyObject, choose: Selector, checkAgain: Selector, settings: Selector,
                      title: String? = nil, image: NSImage? = nil) -> NSMenu {
        let menu = NSMenu()
        let titleItem = NSMenuItem(title: title ?? model.sourceLabel, action: nil, keyEquivalent: "")
        titleItem.image = image
        menu.addItem(titleItem)
        let current = model.providerKind
        let currentModel = model.modelID ?? ""
        for kind in ProviderKind.allCases {
            let a = model.availability[kind]
            let header = NSMenuItem(title: kind.displayName + stateSuffix(a), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let models = a?.models ?? []
            // A back end that is not ready can still be chosen: the pane
            // then says how to make it ready.
            for m in models.isEmpty ? [ModelInfo(id: "", displayName: "Choose \(kind.displayName)")] : models {
                let item = NSMenuItem(title: m.displayName.isEmpty ? "Default" : m.displayName, action: choose, keyEquivalent: "")
                item.indentationLevel = 1
                item.representedObject = Choice(kind: kind, model: models.isEmpty ? nil : m.id)
                item.target = target
                item.state = kind == current && (models.isEmpty || m.id == currentModel) ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Check Again", action: checkAgain, keyEquivalent: "")
        refresh.target = target
        menu.addItem(refresh)
        let s = NSMenuItem(title: "Coding Assistant Settings…", action: settings, keyEquivalent: "")
        s.target = target
        menu.addItem(s)
        return menu
    }

    static func choiceTitles(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).compactMap { item in
            (item.representedObject as? Choice).map { "\($0.kind.displayName)/\(item.title)" }
        }
    }

    static func stateSuffix(_ a: ProviderAvailability?) -> String {
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
}

/// The message field: Return sends, ⇧Return (or ⌥Return) adds a line.
public final class ComposerTextView: NSTextView {
    var onSubmit: (() -> Void)?
    /// Escape (the prompt popover closes).
    var onCancel: (() -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }

    public override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }

    public override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && event.modifierFlags.isDisjoint(with: [.shift, .option]) && !hasMarkedText() {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.placeholderTextColor, .font: font ?? .systemFont(ofSize: 13)]
        (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attrs)
    }

    public override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// One message in the transcript.
public final class MessageView: NSStackView {
    public let message: ConversationMessage
    public let proposals: [ChangeProposal]
    var onReview: ((ChangeProposal) -> Void)?
    /// The proposal buttons, by proposal (tests).
    public private(set) var reviewButtons: [NSButton] = []

    init(message: ConversationMessage, proposals: [ChangeProposal]) {
        self.message = message
        self.proposals = proposals
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func build() {
        let who = NSTextField(labelWithString: message.role == .user ? "You" : (message.source ?? "Assistant"))
        who.font = .boldSystemFont(ofSize: 11)
        who.textColor = .secondaryLabelColor
        addArrangedSubview(who)
        if !message.attachments.isEmpty {
            let a = NSTextField(labelWithString: "Attached: " + message.attachments.map(\.label).joined(separator: ", "))
            a.font = .systemFont(ofSize: 10)
            a.textColor = .secondaryLabelColor
            addArrangedSubview(a)
        }
        for line in message.activity.suffix(6) {
            let l = NSTextField(labelWithString: "› " + line)
            l.font = .systemFont(ofSize: 10)
            l.textColor = .tertiaryLabelColor
            l.lineBreakMode = .byTruncatingMiddle
            addArrangedSubview(l)
        }
        if message.role == .user {
            addArrangedSubview(prose(message.text, markdown: false))
        } else {
            var codeIndex = 0
            for block in MarkdownBlocks.parse(message.text) {
                switch block {
                case .prose(let p): addArrangedSubview(prose(p, markdown: true))
                case .code(let info, let text, _):
                    addArrangedSubview(codeBlock(info: info, text: text, proposal: proposals.first { $0.blockIndex == codeIndex }, index: codeIndex))
                    codeIndex += 1
                }
            }
            if !message.isComplete && message.text.isEmpty {
                let p = NSProgressIndicator()
                p.style = .spinning
                p.controlSize = .small
                p.startAnimation(nil)
                addArrangedSubview(p)
            }
        }
        if let e = message.error {
            let l = NSTextField(wrappingLabelWithString: e)
            l.textColor = e == "Stopped." ? .secondaryLabelColor : .systemRed
            l.font = .systemFont(ofSize: 11)
            l.isSelectable = true
            addArrangedSubview(l)
        }
        // Text wraps at the transcript's width; code boxes fill it.
        for v in arrangedSubviews {
            v.translatesAutoresizingMaskIntoConstraints = false
            if v is NSTextField || v is NSStackView {
                v.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            }
        }
    }

    func prose(_ text: String, markdown: Bool) -> NSTextField {
        let s: NSAttributedString
        if markdown, let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let m = NSMutableAttributedString(a)
            m.addAttribute(.font, value: NSFont.systemFont(ofSize: NSFont.systemFontSize), range: NSRange(location: 0, length: m.length))
            // Inline code and emphasis keep their styles.
            a.runs.forEach { run in
                guard let intent = run.inlinePresentationIntent else { return }
                let r = NSRange(run.range, in: a)
                var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
                if intent.contains(.code) { font = .monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular) }
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                m.addAttribute(.font, value: font, range: r)
            }
            m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: m.length))
            s = m
        } else {
            s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor])
        }
        let l = NSTextField(wrappingLabelWithString: "")
        l.attributedStringValue = s
        l.isSelectable = true
        l.allowsEditingTextAttributes = true
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    func codeBlock(info: String, text: String, proposal: ChangeProposal?, index: Int) -> NSView {
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 2
        let titleText: String
        if let p = proposal {
            switch p.kind {
            case .wholeFile: titleText = "Proposed: \(p.path)"
            case .replaceSelection: titleText = "Proposed: replace the selection in \((p.path as NSString).lastPathComponent)"
            case .append: titleText = "Proposed: add to \((p.path as NSString).lastPathComponent)"
            }
        } else {
            titleText = info.split(separator: " ").first.map(String.init) ?? ""
        }
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 10, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let copy = ClosureButton(title: "Copy", target: nil, action: nil)
        copy.bezelStyle = .inline
        copy.controlSize = .small
        copy.onChange = { _ in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        var headerViews: [NSView] = [title, NSView(), copy]
        if let p = proposal {
            if let r = message.resolvedProposals[p.blockIndex] {
                let l = NSTextField(labelWithString: r == .accepted ? "Applied" : "Rejected")
                l.font = .systemFont(ofSize: 10, weight: .semibold)
                l.textColor = r == .accepted ? .systemGreen : .secondaryLabelColor
                headerViews.append(l)
            }
            let review = ClosureButton(title: "Review…", target: nil, action: nil)
            review.bezelStyle = .inline
            review.controlSize = .small
            review.toolTip = "Compare the proposed change with the file, then accept or reject it"
            review.onChange = { [weak self] _ in self?.onReview?(p) }
            reviewButtons.append(review)
            headerViews.append(review)
        }
        let header = NSStackView(views: headerViews)
        header.orientation = .horizontal
        header.spacing = 4
        let code = NSTextField(wrappingLabelWithString: text)
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.isSelectable = true
        code.drawsBackground = true
        code.backgroundColor = .textBackgroundColor
        code.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        box.addArrangedSubview(header)
        box.addArrangedSubview(code)
        header.translatesAutoresizingMaskIntoConstraints = false
        code.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.widthAnchor.constraint(equalTo: box.widthAnchor),
            code.widthAnchor.constraint(equalTo: box.widthAnchor),
        ])
        box.wantsLayer = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.layer?.cornerRadius = 4
        box.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        return box
    }
}
