import Foundation
import YcodeBuild
import YcodeDebug
import YcodeLanguage

extension LineIndex {
    /// The LSP position (0-based line, UTF-16 column) of an offset.
    public func position(at offset: Int) -> Position {
        let line = self.line(at: offset)
        return Position(line: line - 1, character: offset - starts[line - 1])
    }

    /// The offset of an LSP position, clamped to the text.
    public func offset(of p: Position) -> Int {
        guard let r = range(ofLine: p.line + 1) else { return length }
        return r.location + min(max(0, p.character), r.length)
    }
}

/// The session's language service: one sourcekit-lsp per workspace window.
/// Open documents are kept in sync; published diagnostics become live
/// issues. See `specs/ide/language.md`.
@MainActor
public final class LanguageService {
    public let client: LSPClient
    private var versions: [URL: Int] = [:]
    /// The hash of the text last sent per document (an `open` of an open
    /// document with the same text is not an edit).
    private var textHashes: [URL: Int] = [:]
    /// The text last sent per open document (a restarted server gets them again).
    public private(set) var openTexts: [URL: String] = [:]
    /// Live issues by file path, from `publishDiagnostics`.
    public private(set) var liveIssues: [String: [Diagnostic]] = [:]
    /// The diagnostics as sent, by file path (for code-action requests).
    public private(set) var liveDiagnostics: [String: [LSPDiagnostic]] = [:]
    /// Holds back the live issues of the line being typed (P-080).
    public var typingHold = LiveIssueHold()
    private var holdTasks: [String: Task<Void, Never>] = [:]
    /// Per document, the errors and text it was last sent again for.
    private var refreshedErrors: [URL: Int] = [:]
    /// The same for the late recheck (P-070, beta 5).
    private var lateRefreshedErrors: [URL: Int] = [:]
    /// Edits the server asks to apply (`workspace/applyEdit`).
    package var onApplyEdit: ((WorkspaceEdit) -> Void)?
    var onIssuesChanged: (() -> Void)?
    /// The server's work in progress (IndexingProgress.swift, row 189).
    public private(set) var progress = LanguageProgress()
    var onProgressChanged: (() -> Void)?
    /// A document's text changed (the path, standardized): its build
    /// issues no longer stand for it (`reference-ui-6.md` §5.2.2).
    var onEdited: ((String) -> Void)?

    public init(transport: DAPTransport, root: URL, initializationOptions: JSON? = nil) async throws {
        client = try LSPClient(transport: transport)
        let notes = client.notifications
        Task { [weak self] in
            for await n in notes {
                if n.method == "$/progress" {
                    let wasActive = self?.progress.isActive ?? false
                    if self?.progress.apply(n.params) == true { self?.onProgressChanged?() }
                    if wasActive, self?.progress.isActive == false { self?.refreshDiagnosticsWithErrors() }
                    continue
                }
                if n.method == "workspace/applyEdit" {
                    self?.onApplyEdit?(WorkspaceEdit(n.params["edit"]))
                    continue
                }
                guard n.method == "textDocument/publishDiagnostics", let (url, d) = LSPDiagnostic.published(n.params) else { continue }
                self?.publish(url: url, d)
            }
        }
        try await client.initialize(root: root, initializationOptions: initializationOptions)
    }

    /// Converts LSP diagnostics (0-based) to issues (1-based lines/columns).
    public static func issues(file: String, _ list: [LSPDiagnostic]) -> [Diagnostic] {
        list.compactMap { d in
            let severity: Diagnostic.Severity
            switch d.severity {
            case 1: severity = .error
            case 2: severity = .warning
            default: return nil // information and hints are not issues
            }
            // Inline fix-its whose edits stay in this file become fix-its.
            let fixIts = d.fixIts.compactMap(\.edit).flatMap { e in
                e.changes.filter { $0.key.standardizedFileURL.path == file }.flatMap(\.value).map { t in
                    Diagnostic.FixIt(file: file, start: .init(file: file, line: t.start.line + 1, column: t.start.character + 1),
                                     end: .init(file: file, line: t.end.line + 1, column: t.end.character + 1), replacement: t.newText)
                }
            }
            return Diagnostic(severity: severity, message: Diagnostic.displayMessage(d.message),
                              location: .init(file: file, line: d.start.line + 1, column: d.start.character + 1), fixIts: fixIts)
        }
    }

    private func publish(url: URL, _ list: [LSPDiagnostic]) {
        // Only sources have live issues (row 228), whatever a server sends.
        guard FileTypeRoles.usesLanguageService(url) else { return }
        let path = url.standardizedFileURL.path
        liveDiagnostics[path] = list
        showLiveIssues(path)
        if list.contains(where: { $0.severity == 1 }) { scheduleLateRecheck() }
    }

    /// How long after a document's errors arrive it is sent again, once
    /// (P-070, beta 5).
    public static var lateRecheckDelay: Duration = .seconds(3)
    private var lateRecheck: Task<Void, Never>?

    /// sourcekit-lsp diagnoses a document with fallback settings (no other
    /// file of the module: "Cannot find 'Counter' in scope") when the build
    /// server's arguments come later than it waits for them, and does not
    /// always publish again once they come; nor is there always a work
    /// progress ending after that (the B4 refresh). A while after errors
    /// arrive, the documents with errors are sent again, unchanged, once per
    /// set of errors and text (`refreshDiagnosticsWithErrors`): real errors
    /// come back the same and are not sent again.
    private func scheduleLateRecheck() {
        guard lateRecheck == nil else { return }
        lateRecheck = Task { [weak self] in
            try? await Task.sleep(for: Self.lateRecheckDelay)
            guard let self, !Task.isCancelled else { return }
            self.lateRecheck = nil
            self.refreshDiagnosticsWithErrors(late: true)
        }
    }

    /// The live issues of `path` from its last diagnostics, without those of
    /// the line being typed while its hold lasts (P-080, `LiveIssueHold`);
    /// the held ones appear when the hold ends.
    private func showLiveIssues(_ path: String) {
        let list = liveDiagnostics[path] ?? []
        liveIssues[path] = Self.issues(file: path, typingHold.visible(list, path: path))
        onIssuesChanged?()
        guard let end = typingHold.holdEnd(path), typingHold.visible(list, path: path).count != list.count else { return }
        holdTasks[path]?.cancel()
        holdTasks[path] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, end.timeIntervalSinceNow) * 1e9) + 20_000_000)
            guard !Task.isCancelled, let self else { return }
            self.holdTasks[path] = nil
            self.showLiveIssues(path)
        }
    }

    /// Whether the server gets `url` at all: only Swift and C-family
    /// sources do. Markdown, JSON, property lists, text and images are never
    /// opened, changed or saved in it, so they get no diagnostics and add
    /// nothing to the issue counts (council round 9, row 228; `language.md`
    /// §Features).
    public static func handles(_ url: URL) -> Bool { FileTypeRoles.usesLanguageService(url) }

    public func open(_ url: URL, text: String) {
        guard Self.handles(url) else { return }
        guard versions[url] == nil else { return change(url, text: text) }
        versions[url] = 1
        textHashes[url] = text.hashValue
        openTexts[url] = text
        client.didOpen(url, text: text)
    }

    public func change(_ url: URL, text: String) {
        guard Self.handles(url) else { return }
        let v = (versions[url] ?? 0) + 1
        versions[url] = v
        client.didChange(url, text: text, version: v)
        typingHold.noteEdit(path: url.standardizedFileURL.path, old: openTexts[url], new: text)
        openTexts[url] = text
        let h = text.hashValue
        if textHashes.updateValue(h, forKey: url) != h { onEdited?(url.standardizedFileURL.path) }
    }

    /// The server finished its work (preparing targets, indexing): the
    /// open documents with errors are sent again, unchanged, so that it
    /// diagnoses them once more. sourcekit-lsp diagnoses a document as soon
    /// as it is opened, before the modules of its target's dependencies
    /// exist, and does not by itself publish again when they do: a unit
    /// test's `@testable import App` stays "No such module" until the next
    /// edit (P-070).
    /// A document is sent again once per set of errors and text, so a real
    /// error (which the server publishes again) does not repeat this.
    func refreshDiagnosticsWithErrors(late: Bool = false) {
        for (url, text) in openTexts.sorted(by: { $0.key.path < $1.key.path }) {
            guard let list = liveDiagnostics[url.standardizedFileURL.path], list.contains(where: { $0.severity == 1 }) else { continue }
            var key = Hasher()
            key.combine(text)
            for d in list { key.combine(d.message); key.combine(d.start.line) }
            let h = key.finalize()
            // The late recheck keeps its own record, so it never uses up the
            // sending again when work progress ends (and the other way).
            if late {
                guard lateRefreshedErrors.updateValue(h, forKey: url) != h else { continue }
            } else {
                guard refreshedErrors.updateValue(h, forKey: url) != h else { continue }
            }
            let v = (versions[url] ?? 0) + 1
            versions[url] = v
            client.didChange(url, text: text, version: v)
        }
    }

    /// The file was written (`textDocument/didSave`).
    public func saved(_ url: URL) {
        guard versions[url] != nil else { return }
        client.didSave(url)
    }

    /// No editor shows the file any more (`textDocument/didClose`).
    public func close(_ url: URL) {
        guard versions.removeValue(forKey: url) != nil else { return }
        textHashes[url] = nil
        openTexts[url] = nil
        typingHold.forget(url.standardizedFileURL.path)
        refreshedErrors[url] = nil
        lateRefreshedErrors[url] = nil
        client.didClose(url)
    }

    /// A file that is not open changed on disk (`workspace/didChangeWatchedFiles`).
    public func fileChangedOnDisk(_ url: URL) {
        client.notify("workspace/didChangeWatchedFiles", ["changes": [["uri": .string(url.absoluteString), "type": 2]]])
    }

    public func stop() async {
        lateRecheck?.cancel()
        await client.shutdown()
    }
}

extension WorkspaceSession {
    /// The directory the language server treats as the workspace root.
    var languageRoot: URL {
        model.kind == .package ? model.url : model.url.deletingLastPathComponent()
    }

    /// Starts sourcekit-lsp (or `transport`) for this workspace.
    public func startLanguageService(transport: DAPTransport? = nil) async {
        isPreparingEditorServices = true
        defer { isPreparingEditorServices = false }
        let t: DAPTransport
        var root = languageRoot
        languageRestart.context = nil
        let startedContext = languageBuildContext
        var options: JSON?
        if let transport { t = transport } else {
            guard let path = await Task.detached(operation: { SourceKitLSP.locate() }).value else { return }
            t = ProcessTransport(executable: path)
            // Projects and workspaces: through Ycode's build server (language.md §Build server).
            let (container, scheme, destination) = (model.url, startedContext.scheme, startedContext.destination)
            if let folder = await Task.detached(operation: {
                BuildServerLaunch.prepareWorkspaceFolder(container: container, scheme: scheme, destination: destination)
            }).value {
                (root, options) = (folder, BuildServerLaunch.initializationOptions)
                languageRestart.context = startedContext
            }
        }
        if transport != nil, model.kind != .package, languageRestart.makeTransport != nil { languageRestart.context = startedContext }
        do {
            let service = try await LanguageService(transport: t, root: root, initializationOptions: options)
            service.onIssuesChanged = { [weak self] in self?.languageIssuesChanged() }
            service.onProgressChanged = { [weak self, weak service] in self?.isIndexing = service?.progress.isActive ?? false }
            service.onEdited = { [weak self] in self?.noteFileEdited($0) }
            language = service
            // The scheme or destination changed while the server started.
            buildContextChanged()
        } catch {
            appendConsole("Ycode: the language server did not start: \(error)\n")
        }
    }

    public func completions(_ url: URL, at p: Position) async -> [CompletionItem] {
        guard let language else { return [] }
        return (try? await language.client.completion(url, at: p)) ?? []
    }

    public func hover(_ url: URL, at p: Position) async -> String? {
        guard let language else { return nil }
        return try? await language.client.hover(url, at: p)
    }

    public func definition(_ url: URL, at p: Position) async -> Location? {
        guard let language else { return nil }
        return (try? await language.client.definition(url, at: p))?.first
    }

    /// The language server's document highlights of the symbol at `p`.
    public func documentHighlights(_ url: URL, at p: Position) async -> [DocumentHighlight] {
        guard let language else { return [] }
        return (try? await language.client.documentHighlights(url, at: p)) ?? []
    }
}
