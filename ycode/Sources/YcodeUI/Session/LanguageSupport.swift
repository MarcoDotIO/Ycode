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
    /// Live issues by file path, from `publishDiagnostics`.
    public private(set) var liveIssues: [String: [Diagnostic]] = [:]
    /// The diagnostics as sent, by file path (for code-action requests).
    public private(set) var liveDiagnostics: [String: [LSPDiagnostic]] = [:]
    /// Edits the server asks to apply (`workspace/applyEdit`).
    var onApplyEdit: ((WorkspaceEdit) -> Void)?
    var onIssuesChanged: (() -> Void)?

    public init(transport: DAPTransport, root: URL) async throws {
        client = try LSPClient(transport: transport)
        let notes = client.notifications
        Task { [weak self] in
            for await n in notes {
                if n.method == "workspace/applyEdit" {
                    self?.onApplyEdit?(WorkspaceEdit(n.params["edit"]))
                    continue
                }
                guard n.method == "textDocument/publishDiagnostics", let (url, d) = LSPDiagnostic.published(n.params) else { continue }
                self?.publish(url: url, d)
            }
        }
        try await client.initialize(root: root)
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
            return Diagnostic(severity: severity, message: d.message,
                              location: .init(file: file, line: d.start.line + 1, column: d.start.character + 1), fixIts: fixIts)
        }
    }

    private func publish(url: URL, _ list: [LSPDiagnostic]) {
        let path = url.standardizedFileURL.path
        liveIssues[path] = Self.issues(file: path, list)
        liveDiagnostics[path] = list
        onIssuesChanged?()
    }

    public func open(_ url: URL, text: String) {
        guard versions[url] == nil else { return change(url, text: text) }
        versions[url] = 1
        client.didOpen(url, text: text)
    }

    public func change(_ url: URL, text: String) {
        let v = (versions[url] ?? 0) + 1
        versions[url] = v
        client.didChange(url, text: text, version: v)
    }

    /// The file was written (`textDocument/didSave`).
    public func saved(_ url: URL) {
        guard versions[url] != nil else { return }
        client.didSave(url)
    }

    /// No editor shows the file any more (`textDocument/didClose`).
    public func close(_ url: URL) {
        guard versions.removeValue(forKey: url) != nil else { return }
        client.didClose(url)
    }

    /// A file that is not open changed on disk (`workspace/didChangeWatchedFiles`).
    public func fileChangedOnDisk(_ url: URL) {
        client.notify("workspace/didChangeWatchedFiles", ["changes": [["uri": .string(url.absoluteString), "type": 2]]])
    }

    public func stop() async { await client.shutdown() }
}

extension WorkspaceSession {
    /// The directory the language server treats as the workspace root.
    var languageRoot: URL {
        model.kind == .package ? model.url : model.url.deletingLastPathComponent()
    }

    /// Starts sourcekit-lsp (or `transport`) for this workspace.
    public func startLanguageService(transport: DAPTransport? = nil) async {
        let t: DAPTransport
        if let transport { t = transport } else {
            guard let path = await Task.detached(operation: { SourceKitLSP.locate() }).value else { return }
            t = ProcessTransport(executable: path)
        }
        do {
            let service = try await LanguageService(transport: t, root: languageRoot)
            service.onIssuesChanged = { [weak self] in self?.languageIssuesChanged() }
            language = service
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
