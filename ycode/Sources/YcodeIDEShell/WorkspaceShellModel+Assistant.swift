import Foundation
import YcodeAssistant
import YcodeEditorKit
import YcodeIDECore

/// The coding assistant in the workspace window (issue #18,
/// `specs/ide/coding-assistant.md` §4–§5): the left area's Coding Assistant
/// pane and its commands, the context a request carries, and applying an
/// accepted change.
extension WorkspaceShellModel {
    // MARK: Commands

    /// View ▸ Navigators ▸ Show Coding Assistant (⌘0) and the toolbar's
    /// Navigators | Coding Assistant control: clicking the shown pane hides
    /// the area.
    public func showLeftPane(assistant: Bool) {
        if isNavigatorShown && self.assistant.isShown == assistant {
            isNavigatorShown = false
            return
        }
        if assistant { self.assistant.show() } else { self.assistant.isShown = false }
        isNavigatorShown = true
    }

    /// Whether the left area shows the Coding Assistant pane.
    public var isAssistantPaneShown: Bool { isNavigatorShown && assistant.isShown }

    func isAssistantCommandEnabled(_ c: ShellCommand) -> Bool {
        switch c {
        case .showCodingAssistant, .newConversation: true
        case .jumpToNextActiveConversation: assistant.hasActiveConversations
        default: c.codingTool.map(assistant.canRun) ?? false
        }
    }

    func performAssistantCommand(_ c: ShellCommand) {
        switch c {
        case .showCodingAssistant: showLeftPane(assistant: true)
        case .newConversation: assistant.newConversation()
        case .jumpToNextActiveConversation: assistant.jumpToNextActive()
        default: if let t = c.codingTool { assistant.run(t) }
        }
    }

    // MARK: Context

    /// The folder agent tools run in and proposal paths are relative to:
    /// the package's folder, or the project's or workspace's.
    public var assistantFolder: URL {
        let url = session.model.url
        return (session.model.kind == .package ? url : url.deletingLastPathComponent()).standardizedFileURL
    }

    /// A path relative to the workspace folder (absolute when outside it).
    func assistantRelativePath(_ path: String) -> String {
        let root = assistantFolder.path.hasSuffix("/") ? assistantFolder.path : assistantFolder.path + "/"
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        return p.hasPrefix(root) ? String(p.dropFirst(root.count)) : p
    }

    /// A proposal's file inside the workspace folder (nil when the path
    /// leaves it).
    public func assistantPath(_ relative: String) -> String? {
        let url = assistantFolder.appendingPathComponent(relative).standardizedFileURL
        let root = assistantFolder.path.hasSuffix("/") ? assistantFolder.path : assistantFolder.path + "/"
        return url.path.hasPrefix(root) ? url.path : nil
    }

    /// The text a change applies to: the open editor's (unsaved edits
    /// included), else the file's on disk; nil for a file that does not
    /// exist.
    public func assistantCurrentText(_ path: String) -> String? {
        if let d = openDocuments[path] { return d.buffer.text }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// What a request carries (coding-assistant.md §5.2): the open file
    /// and the caret, the selection, the other open files and the issues.
    public func assistantContext() -> WorkspaceContext {
        var ctx = WorkspaceContext(workspaceName: workspaceName)
        if let e = editor {
            let b = e.buffer
            let path = assistantRelativePath(e.path)
            ctx.currentFile = .init(path: path, text: b.text)
            ctx.caretLine = b.caretLine + 1
            let r = b.selection.range
            if !r.isEmpty {
                let start = b.document.line(containing: r.lowerBound)
                let end = b.document.line(containing: max(r.lowerBound, r.upperBound - 1))
                ctx.selection = .init(path: path, startLine: start + 1, endLine: end + 1, text: b.selectedText,
                                      location: r.lowerBound, length: r.count)
            }
        }
        var seen = Set(ctx.currentFile.map { [$0.path] } ?? [])
        for d in openDocuments.values.sorted(by: { $0.path < $1.path }) where d !== editor {
            let path = assistantRelativePath(d.path)
            if seen.insert(path).inserted { ctx.openFiles.append(.init(path: path, text: d.buffer.text)) }
        }
        ctx.issues = allIssues.prefix(100).map { i in
            WorkspaceContext.Issue(severity: i.severity.rawValue, message: i.message, path: i.file.map(assistantRelativePath), line: i.line)
        }
        return ctx
    }

    // MARK: Applying an accepted change

    /// Applies a change the user accepted: into the file's editor (opened
    /// first) as one undoable edit, left unsaved unless `save`; a new file
    /// is created and opened. Returns why it could not be applied, else
    /// nil. Nothing else is written.
    func applyAssistantChange(_ diff: AssistantChangeDiff, save: Bool) -> String? {
        let path = diff.path
        if diff.original == nil {
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try diff.proposed.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                return "Ycode could not create \(url.lastPathComponent): \(error.localizedDescription)"
            }
            open(path)
            return nil
        }
        if editor?.path != path { open(path) }
        guard let e = editor, e.path == path else {
            return "\((path as NSString).lastPathComponent) can't be opened as text, so the change was not applied."
        }
        if let why = e.readOnlyReason { return why }
        // The editor's text may differ from what the review showed (typed
        // since): the change applies only to the text it was made against.
        guard e.buffer.text == diff.original else {
            return "\(e.name) changed since the review; ask again or review the proposal again."
        }
        Self.replaceChangedPart(of: e.buffer, with: diff.proposed)
        if save, !saveCurrent() { return "Ycode could not save \(e.name)." }
        return nil
    }

    /// Replaces only the part that differs (one undo step), so the caret
    /// and the rest of the file stay where they were.
    static func replaceChangedPart(of b: EditorBuffer, with new: String) {
        let old = Array(b.text.utf16), now = Array(new.utf16)
        guard old != now else { return }
        var p = 0
        while p < old.count, p < now.count, old[p] == now[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < now.count - p, old[old.count - 1 - s] == now[now.count - 1 - s] { s += 1 }
        // Never split a surrogate pair.
        if p > 0, UTF16.isLeadSurrogate(old[p - 1]) { p -= 1 }
        if s > 0, UTF16.isTrailSurrogate(old[old.count - s]) { s -= 1 }
        let range = NSRange(location: p, length: old.count - s - p)
        b.replace(range, with: String(decoding: now[p..<(now.count - s)], as: UTF16.self))
    }
}

extension ShellCommand {
    /// The coding assistant's commands (`CommandTable`: File ▸ New ▸
    /// Conversation, View ▸ Navigators ▸ Show Coding Assistant, Navigate ▸
    /// Jump to Next Active Conversation, Editor ▸ Show Coding Tools).
    static let assistantActions: [ShellCommand: (selector: String, menu: String)] = [
        .showCodingAssistant: ("showCodingAssistant:", "View"),
        .newConversation: ("newConversation:", "File"),
        .jumpToNextActiveConversation: ("jumpToNextActiveConversation:", "Navigate"),
        .codingToolExplain: ("codingToolExplain:", "Editor"),
        .codingToolDocument: ("codingToolDocument:", "Editor"),
        .codingToolGeneratePlayground: ("codingToolGeneratePlayground:", "Editor"),
        .codingToolGeneratePreview: ("codingToolGeneratePreview:", "Editor"),
    ]

    public var isAssistant: Bool { Self.assistantActions[self] != nil }

    /// The Show Coding Tools item's tool.
    public var codingTool: CodingTool? {
        switch self {
        case .codingToolExplain: .explain
        case .codingToolDocument: .document
        case .codingToolGeneratePlayground: .generatePlayground
        case .codingToolGeneratePreview: .generatePreview
        default: nil
        }
    }
}
