import Foundation
import SwiftUI
import YcodeAssistant
import YcodeIDECore
import YcodeIDEShell

// The Coding Assistant pane of the left area (issue #18,
// `specs/ide/coding-assistant.md` §4, `reference-ui-6.md` §9.2), as the
// macOS IDE lays it out: the toolbar band, the header with New
// Conversation (and its chevron's provider menu) and New Group, the
// conversation list with the Archive group last, then the selected
// conversation: its status, transcript and message field.

/// The left area while the Coding Assistant pane is shown.
struct AssistantColumn: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let a = model.assistant
        VStack(spacing: 0) {
            NavigatorToolbar(model: model)
            AssistantHeader(assistant: a)
            ConversationList(assistant: a)
                .frame(height: 150)
            Hairline(color: c.separator)
            ConversationPanel(model: model, assistant: a)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .shellTarget("assistant pane")
    }
}

/// "New Conversation" with its chevron, and "New Group", each on its own
/// glass capsule (`liquid-glass.md` §2.4).
struct AssistantHeader: View {
    var assistant: ShellAssistantModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 7) {
            HStack(spacing: 0) {
                Button { startConversation() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.bubble").font(.system(size: 12))
                        Text(verbatim: "New Conversation").font(ShellFonts.row).lineLimit(1)
                    }
                    .foregroundStyle(c.label)
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .frame(height: 27)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Start a conversation with the coding assistant")
                .shellTarget("assistant new conversation")
                Rectangle().fill(c.capsuleStroke).frame(width: 1, height: 16)
                Menu {
                    ProviderStartMenu(assistant: assistant, openSettings: { open() })
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(c.label)
                        .frame(width: 22, height: 27)
                }
                .menuStyle(.borderlessButton)
                .help("Choose a model provider for the new conversation")
                .shellTarget("assistant new conversation menu")
            }
            .background { GlassCapsule(height: 30) }
            Button { assistant.newGroup() } label: {
                Text(verbatim: "New Group").font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 27)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background { GlassCapsule(height: 30) }
            .help("Add a group to the conversation list")
            .shellTarget("assistant new group")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 7)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// The button part: a conversation with the chosen back end (with none
    /// set up, the pane's status says how to set one up).
    func startConversation() { assistant.newConversation() }

    func open() {
        ShellSettingsModel.shared.select(.codingAssistant)
        openSettings()
    }
}

/// The chevron's menu: "Model Providers", then one row per back end; a
/// ready one starts a conversation with it, one that is not set up shows
/// its hint and Set Up.
struct ProviderStartMenu: View {
    var assistant: ShellAssistantModel
    var openSettings: () -> Void

    var body: some View {
        Button("Model Providers") {}.disabled(true)
        ForEach(assistant.providerChoices) { p in
            if p.isReady {
                Button(p.title) {
                    assistant.choose(p.kind, model: nil)
                    assistant.newConversation()
                }
            } else {
                Menu(p.title) {
                    Button(assistant.core?.availability[p.kind]?.hint ?? "Checking…") {}.disabled(true)
                    Button("Set Up…") { openSettings() }
                }
            }
        }
    }
}

// MARK: - The conversation list

/// The outline: groups (each with its conversations), the conversations
/// outside any group, newest first, then Archive, always last.
struct ConversationList: View {
    var assistant: ShellAssistantModel
    @State private var collapsed: Set<UUID> = []
    @State private var archiveExpanded = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(assistant.outline.enumerated()), id: \.offset) { pair in
                    node(pair.element, c)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
        .shellTarget("assistant list")
    }

    @ViewBuilder func node(_ n: ConversationLibrary.Node, _ c: ShellColors) -> some View {
        switch n {
        case .group(let g, let convs):
            let open = !collapsed.contains(g.id)
            ListRow(symbol: "folder", title: g.title, isSelected: false, disclosure: open, level: 0, renaming: assistant.renamingID == g.id,
                    assistant: assistant, colors: c, toggle: { if open { collapsed.insert(g.id) } else { collapsed.remove(g.id) } }) {}
                .contextMenu {
                    Button("Rename") { assistant.beginRename(g.id, title: g.title) }
                    Button("Delete Group") { assistant.deleteGroup(g.id) }
                }
            if open {
                ForEach(convs) { conv in conversationRow(conv, level: 1, c) }
            }
        case .conversation(let conv):
            conversationRow(conv, level: 0, c)
        case .archive(let convs):
            ListRow(symbol: "archivebox", title: ConversationLibrary.archiveTitle, isSelected: false, disclosure: archiveExpanded, level: 0,
                    renaming: false, assistant: assistant, colors: c, toggle: { archiveExpanded.toggle() }) {}
            if archiveExpanded {
                ForEach(convs) { conv in conversationRow(conv, level: 1, c) }
            }
        }
    }

    func conversationRow(_ conv: Conversation, level: Int, _ c: ShellColors) -> some View {
        ListRow(symbol: conv.isActive ? "ellipsis" : "text.bubble", title: conv.title, isSelected: assistant.selectedID == conv.id, disclosure: nil,
                level: level, renaming: assistant.renamingID == conv.id, assistant: assistant, colors: c, toggle: {}) {
            assistant.select(conv.id)
        }
        .onTapGesture(count: 2) { assistant.beginRename(conv.id, title: conv.title) }
        .contextMenu {
            Button("Rename") { assistant.beginRename(conv.id, title: conv.title) }
            Menu("Move to Group") {
                Button("None") { assistant.move(conv.id, toGroup: nil) }
                ForEach(assistant.groups) { g in Button(g.title) { assistant.move(conv.id, toGroup: g.id) } }
            }
            Button(conv.isArchived ? "Move out of Archive" : "Archive") { assistant.setArchived(conv.id, !conv.isArchived) }
            Divider()
            Button("Delete") { assistant.delete(conv.id) }
        }
        .shellTarget("assistant row \(conv.title)")
    }
}

/// One row of the list: disclosure, icon, title (or the rename field).
struct ListRow: View {
    var symbol: String
    var title: String
    var isSelected: Bool
    /// nil: no disclosure triangle.
    var disclosure: Bool?
    var level: Int
    var renaming: Bool
    var assistant: ShellAssistantModel
    var colors: ShellColors
    var toggle: () -> Void
    var select: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let c = colors
        HStack(spacing: 4) {
            Group {
                if let open = disclosure {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(c.chevron)
                        .frame(width: 13, height: 22).contentShape(Rectangle())
                        .onTapGesture { toggle() }
                } else {
                    Color.clear.frame(width: 13, height: 22)
                }
            }
            .padding(.leading, CGFloat(level) * 12)
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(c.accent).frame(width: 16)
            if renaming {
                TextField("Title", text: Binding(get: { assistant.renameText }, set: { assistant.renameText = $0 }))
                    .textFieldStyle(.plain)
                    .font(ShellFonts.row)
                    .focused($fieldFocused)
                    .onSubmit { assistant.commitRename() }
                    .onAppear { fieldFocused = true }
                    .shellTarget("assistant rename")
            } else {
                Text(verbatim: title).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .background { if isSelected { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.rowSelection) } }
        .contentShape(Rectangle())
        .onTapGesture { if disclosure == nil { select() } else { toggle() } }
    }
}

// MARK: - The conversation

/// The selected conversation: the back end's status, the transcript and
/// the message field.
struct ConversationPanel: View {
    var model: WorkspaceShellModel
    var assistant: ShellAssistantModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            if let s = assistant.status {
                StatusNote(status: s, assistant: assistant, colors: c, openSettings: { open() })
                Hairline(color: c.separator)
            }
            TranscriptView(model: model, assistant: assistant)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Composer(model: model, assistant: assistant, openSettings: { open() })
        }
    }

    func open() {
        ShellSettingsModel.shared.select(.codingAssistant)
        openSettings()
    }
}

/// Above the transcript when the chosen back end can't be used: its hint,
/// up to three "Use <ready back end>" buttons, Check Again and Settings….
struct StatusNote: View {
    var status: AssistantStatus
    var assistant: ShellAssistantModel
    var colors: ShellColors
    var openSettings: () -> Void

    var body: some View {
        let c = colors
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                if status.checking { ProgressView().controlSize(.small) }
                Text(verbatim: status.text).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .shellTarget("assistant status")
            }
            if !status.checking {
                FlowButtons(titles: status.alternatives.map { "Use \($0.displayName)" } + ["Check Again", "Settings…"]) { i in
                    if i < status.alternatives.count {
                        assistant.choose(status.alternatives[i], model: nil)
                    } else if i == status.alternatives.count {
                        assistant.checkAgain()
                    } else {
                        openSettings()
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small inline buttons in rows of at most three.
struct FlowButtons: View {
    var titles: [String]
    var action: (Int) -> Void

    var body: some View {
        let rows = stride(from: 0, to: titles.count, by: 3).map { Array($0..<min($0 + 3, titles.count)) }
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { row in
                HStack(spacing: 6) {
                    ForEach(row.element, id: \.self) { i in
                        Button(titles[i]) { action(i) }
                            .controlSize(.small)
                            .shellTarget("assistant status \(titles[i])")
                    }
                }
            }
        }
    }
}

/// The message field: the attachment chips, what the request will carry,
/// the field (Return sends), then the attach menu, the provider and model
/// pull-down and Send / Stop.
struct Composer: View {
    var model: WorkspaceShellModel
    @Bindable var assistant: ShellAssistantModel
    var openSettings: () -> Void
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 5) {
            if !assistant.attachments.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(assistant.attachments.enumerated()), id: \.offset) { pair in
                        AttachmentChip(attachment: pair.element, colors: c) { assistant.removeAttachment(pair.element) }
                    }
                    Spacer(minLength: 0)
                }
            }
            Text(verbatim: AssistantContextLine.text(model.assistantContext(), settings: assistant.core?.settings ?? AssistantSettings(),
                                                     attachments: assistant.attachments))
                .font(ShellFonts.mini).foregroundStyle(c.secondaryLabel).lineLimit(1)
                .shellTarget("assistant context")
            TextField(text: $assistant.draft, prompt: Text(verbatim: "Ask \(assistant.sourceLabel)"), axis: .vertical) { Text(verbatim: "Message") }
                .textFieldStyle(.plain)
                .font(ShellFonts.row)
                .focused($fieldFocused)
                .onSubmit { assistant.send() }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(minHeight: 52, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.fieldFill)
                        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                }
                .shellTarget("assistant message")
            HStack(spacing: 6) {
                Menu {
                    let choices = assistant.attachmentChoices
                    Button("Current File") { if let f = choices.file { assistant.attach(f) } }.disabled(choices.file == nil)
                    Button("Selection") { if let s = choices.selection { assistant.attach(s) } }.disabled(choices.selection == nil)
                } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(c.toolbarIcon)
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .help("Attach the current file or the selection")
                .shellTarget("assistant attach")
                Menu {
                    ProviderModelMenu(assistant: assistant, openSettings: openSettings)
                } label: {
                    PopUpLook(title: assistant.sourceLabel)
                }
                .menuStyle(.borderlessButton)
                .help("The model provider and model")
                .shellTarget("assistant model")
                Spacer(minLength: 4)
                let responding = assistant.isResponding
                Button {
                    if responding { assistant.stop() } else { assistant.send() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: responding ? "stop.fill" : "arrow.up").font(.system(size: 10, weight: .bold))
                        Text(verbatim: responding ? "Stop" : "Send").font(ShellFonts.small)
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(!responding && !assistant.canSend)
                .help(responding ? "Stop the response" : "Send (Return)")
                .shellTarget("assistant send")
            }
            if assistant.usesChatGPTPlan {
                Text(verbatim: "Using ChatGPT plan · Manage usage in ChatGPT settings").font(ShellFonts.mini).foregroundStyle(c.secondaryLabel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .onChange(of: assistant.focusCount) { _, _ in fieldFocused = true }
        .onAppear { if assistant.focusCount > 0 { fieldFocused = true } }
    }
}

/// An attachment above the field: its label and ✕.
struct AttachmentChip: View {
    var attachment: Attachment
    var colors: ShellColors
    var remove: () -> Void

    var body: some View {
        let c = colors
        HStack(spacing: 3) {
            Image(systemName: attachment.kind == .file ? "doc.text" : "text.magnifyingglass").font(.system(size: 9))
            Text(verbatim: attachment.label).font(ShellFonts.mini).lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Remove \(attachment.path) from the message")
        }
        .foregroundStyle(c.label)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background { Capsule(style: .continuous).fill(c.popUpFill) }
        .shellTarget("assistant chip \(attachment.label)")
    }
}

/// The model pull-down: each back end with its state, its models under it
/// (the current one checked), then Check Again and Coding Assistant
/// Settings….
struct ProviderModelMenu: View {
    var assistant: ShellAssistantModel
    var openSettings: () -> Void

    var body: some View {
        ForEach(assistant.providerChoices) { p in
            Button(p.title) {}.disabled(true)
            ForEach(Array(p.models.enumerated()), id: \.offset) { pair in
                let m = pair.element
                Button((m.isCurrent ? "✓ " : "    ") + m.title) { assistant.choose(p.kind, model: m.id) }
            }
        }
        Divider()
        Button("Check Again") { assistant.checkAgain() }
        Button("Coding Assistant Settings…") { openSettings() }
    }
}

/// The line under the chips that says what goes with the message (the
/// open file, the selection, the issues, as Settings allows).
enum AssistantContextLine {
    static func text(_ ctx: WorkspaceContext, settings: AssistantSettings, attachments: [Attachment]) -> String {
        var parts: [String] = []
        if let f = ctx.currentFile, settings.context.includeCurrentFile {
            parts.append((f.path as NSString).lastPathComponent)
        }
        if let s = ctx.selection {
            parts.append(s.startLine == s.endLine ? "line \(s.startLine) selected" : "lines \(s.startLine)–\(s.endLine) selected")
        }
        if settings.context.includeIssues, !ctx.issues.isEmpty {
            parts.append("\(ctx.issues.count) issue\(ctx.issues.count == 1 ? "" : "s")")
        }
        if settings.context.includeOpenFiles, !ctx.openFiles.isEmpty {
            parts.append("\(ctx.openFiles.count) other open file\(ctx.openFiles.count == 1 ? "" : "s")")
        }
        if !attachments.isEmpty { parts.append("\(attachments.count) attached") }
        return parts.isEmpty ? "Sends your message only" : "Sends: " + parts.joined(separator: " · ")
    }
}

/// The toolbar's New Conversation: a prompt under the button
/// (`reference-ui-6.md` §9.4); sending starts a conversation in the pane.
struct NewConversationToolbarButton: View {
    @Bindable var assistant: ShellAssistantModel
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // Row 214: Ycode's own gradient glyph and hover (AssistantButtonGlyphView.swift).
        AssistantCircleButton(help: WorkspaceChrome.newConversation.toolTips[0], target: "tb new conversation") { assistant.togglePrompt() }
            .popover(isPresented: $assistant.isPromptShown, arrowEdge: .bottom) {
                let c = ShellColors(scheme)
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "New Conversation").font(ShellFonts.rowBold).foregroundStyle(c.label)
                    TextField(text: $assistant.promptDraft, prompt: Text(verbatim: "Ask \(assistant.sourceLabel)"), axis: .vertical) {
                        Text(verbatim: "Message")
                    }
                    .textFieldStyle(.plain)
                    .font(ShellFonts.row)
                    .focused($fieldFocused)
                    .onSubmit { assistant.sendPrompt() }
                    .padding(8)
                    .frame(minHeight: 60, alignment: .topLeading)
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.fieldFill)
                            .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                    }
                    .shellTarget("assistant prompt field")
                    HStack {
                        Text(verbatim: assistant.sourceLabel).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
                        Spacer(minLength: 8)
                        Button("Send") { assistant.sendPrompt() }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(assistant.promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .shellTarget("assistant prompt send")
                    }
                }
                .frame(width: 340)
                .onAppear { fieldFocused = true }
            }
    }
}
