import Foundation
import YcodeEditorKit
import YcodeIDECore
import YcodeLanguage

/// One completion offered in the editor (from sourcekit-lsp).
public struct EditorCompletion: Equatable, Sendable {
    public var label: String
    public var detail: String?
    /// The text to insert, snippet stops removed.
    public var text: String
    /// Where the caret goes in `text` (the first snippet stop, else its end).
    public var caretOffset: Int

    public init(label: String, detail: String? = nil, text: String, caretOffset: Int? = nil) {
        self.label = label
        self.detail = detail
        self.text = text
        self.caretOffset = caretOffset ?? text.utf16.count
    }

    init(_ item: CompletionItem) {
        let (text, stop) = item.isSnippet ? Self.plain(snippet: item.insertText) : (item.insertText, nil)
        self.init(label: item.label, detail: item.detail, text: text, caretOffset: stop)
    }

    /// An LSP snippet as plain text (`${1:name}` → `name`, `$1`, `${1}` and
    /// `$0` → nothing, `\$` → `$`), with the UTF-16 offset of the first stop.
    public static func plain(snippet s: String) -> (String, Int?) {
        let it = Array(s)
        var out = "", first: Int?
        var i = 0
        func mark() { if first == nil { first = out.utf16.count } }
        while i < it.count {
            let c = it[i]
            if c == "\\", i + 1 < it.count { out.append(it[i + 1]); i += 2; continue }
            if c == "$", i + 1 < it.count {
                if it[i + 1] == "{" {
                    // ${n} or ${n:default}
                    var j = i + 2
                    while j < it.count, it[j].isNumber { j += 1 }
                    if j < it.count, it[j] == "}" {
                        mark()
                        i = j + 1
                        continue
                    }
                    if j < it.count, it[j] == ":" {
                        mark()
                        j += 1
                        var depth = 1
                        while j < it.count {
                            let d = it[j]
                            if d == "\\", j + 1 < it.count { out.append(it[j + 1]); j += 2; continue }
                            if d == "$", j + 1 < it.count, it[j + 1] == "{" { depth += 1; j += 2; continue }
                            if d == "}" { depth -= 1; if depth == 0 { j += 1; break } }
                            out.append(d)
                            j += 1
                        }
                        i = j
                        continue
                    }
                } else if it[i + 1].isNumber {
                    var j = i + 1
                    while j < it.count, it[j].isNumber { j += 1 }
                    mark()
                    i = j
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return (out, first)
    }

    /// The items starting with `prefix` (any case) first, then those
    /// containing it.
    public static func filter(_ all: [EditorCompletion], prefix: String) -> [EditorCompletion] {
        guard !prefix.isEmpty else { return all }
        let p = prefix.lowercased()
        let starts = all.filter { $0.label.lowercased().hasPrefix(p) }
        let contains = all.filter { !$0.label.lowercased().hasPrefix(p) && $0.label.lowercased().contains(p) }
        return starts + contains
    }
}

extension WorkspaceShellModel {
    /// Completions at the caret of the open file: the server gets the
    /// current text first. Empty without a language server, when it fails,
    /// or after `timeout` seconds; never throws.
    public func completions(timeout: Double = 3) async -> [EditorCompletion] {
        guard let d = editor, let language = session.language, d.readOnlyReason == nil else { return [] }
        let url = URL(fileURLWithPath: d.path)
        languageUpdates.removeValue(forKey: d.path)?.cancel()
        language.change(url, text: d.buffer.text)
        let b = d.buffer
        let p = Position(line: b.caretLine, character: b.caretColumn)
        let session = session
        // A request the server never answers (it crashed, it is busy)
        // gives nothing after `timeout`; the request is left to finish.
        let items: [CompletionItem] = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            Task { @MainActor in once.resume(await session.completions(url, at: p)) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                once.resume([])
            }
        }
        return items.prefix(500).map(EditorCompletion.init)
    }
}

/// Resumes a continuation once; later results are dropped.
@MainActor
private final class ResumeOnce {
    private var cont: CheckedContinuation<[CompletionItem], Never>?
    init(_ c: CheckedContinuation<[CompletionItem], Never>) { cont = c }
    func resume(_ v: [CompletionItem]) {
        cont?.resume(returning: v)
        cont = nil
    }
}
