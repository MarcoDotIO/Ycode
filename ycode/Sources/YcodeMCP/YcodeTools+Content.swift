import Foundation
import YcodeAssistant
import YcodeIDECore
import YcodePreviews

extension YcodeMCPHost {
    var contentTools: [MCPTool] {
        let write = MCPToolAnnotations(readOnly: false, destructive: true)
        return [
            tool("preview_list", "List previews",
                 "The #Preview and PreviewProvider declarations of a Swift file.",
                 input: Schema.object(["workspace": Schema.workspace, "path": Schema.string("A Swift file, relative to the workspace folder.")], required: ["path"]),
                 output: Schema.output(["previews": Schema.anyArray])) { h, call in
                let s = try h.session(for: call)
                let url = try h.resolve(try call.require("path"), in: s)
                guard let text = h.text(of: url) else { throw MCPToolError("cannot read \(h.relative(url.path, in: s))") }
                let list: [AnyJSON] = PreviewDiscovery.previews(in: text).map { p in
                    let kind: String = switch p.kind { case .macro: "#Preview"; case .provider: "PreviewProvider" }
                    return ["name": .string(p.name), "line": .int(p.line), "kind": .string(kind), "traits": .strings(p.traits)]
                }
                return .structured(["previews": .array(list)], summary: list.isEmpty ? "No previews in this file." : "\(list.count) previews.")
            },
            tool("preview_render", "Render preview",
                 "Renders one #Preview of a Swift file to a PNG image headlessly (Ycode's open SwiftUI port; the file must build on its own with SwiftUI). Slow the first time: the renderer is built.",
                 input: Schema.object(["workspace": Schema.workspace, "path": Schema.string("A Swift file, relative to the workspace folder."),
                                       "name": Schema.string("The preview's name (default: the first preview).")], required: ["path"])) { h, call in
                try await h.renderPreview(call)
            },
            tool("strings_catalogs", "List String Catalogs",
                 "The workspace's String Catalogs (.xcstrings) with their languages and how much of each is translated.",
                 input: Schema.object(["workspace": Schema.workspace]), output: Schema.output(["catalogs": Schema.anyArray])) { h, call in
                try h.catalogs(call)
            },
            tool("strings_list", "List strings",
                 "A String Catalog's strings for one language: key, source text, comment, translation and state. With missingOnly, only the strings still to translate.",
                 input: Schema.object(["workspace": Schema.workspace,
                                       "catalog": Schema.string("The .xcstrings file (default: the only one)."),
                                       "language": Schema.string("A language code, e.g. de or pt-BR."),
                                       "missingOnly": Schema.boolean("Only strings that are not translated yet (new, needs review, stale).")],
                                      required: ["language"]),
                 output: Schema.output(["catalog": Schema.str, "language": Schema.str, "progress": Schema.int, "strings": Schema.anyArray])) { h, call in
                try h.listStrings(call)
            },
            tool("strings_set", "Set translation",
                 "Writes one translation into a String Catalog (state translated); an empty value removes it. A write: refused when the server is read-only, reviewed in the IDE.",
                 input: Schema.object(["workspace": Schema.workspace, "catalog": Schema.string("The .xcstrings file (default: the only one)."),
                                       "key": Schema.string("The string's key."), "language": Schema.string("A language code."),
                                       "value": Schema.string("The translation.")], required: ["key", "language", "value"]),
                 output: Schema.output(["catalog": Schema.str, "key": Schema.str, "language": Schema.str, "progress": Schema.int]),
                 annotations: MCPToolAnnotations(readOnly: false, idempotent: true), writes: true) { h, call in
                try await h.setString(call)
            },
            tool("file_write", "Write file",
                 "Creates a file or replaces its whole contents. A write: refused when the server is read-only; in the IDE the user reviews it as a proposal first.",
                 input: Schema.object(["workspace": Schema.workspace, "path": Schema.string("Relative to the workspace folder."),
                                       "content": Schema.string("The file's complete new text.")], required: ["path", "content"]),
                 output: Schema.output(["path": Schema.str, "created": Schema.bool, "lineCount": Schema.int]), annotations: write, writes: true) { h, call in
                try await h.writeFile(call)
            },
            tool("file_edit", "Edit file",
                 "Replaces an exact piece of a file's text (it must occur once, unless replaceAll). A write: refused when the server is read-only; in the IDE the user reviews it as a proposal first.",
                 input: Schema.object(["workspace": Schema.workspace, "path": Schema.string("Relative to the workspace folder."),
                                       "oldText": Schema.string("The exact text to replace (with its indentation)."),
                                       "newText": Schema.string("The replacement."),
                                       "replaceAll": Schema.boolean("Replace every occurrence.")], required: ["path", "oldText", "newText"]),
                 output: Schema.output(["path": Schema.str, "replacements": Schema.int]), annotations: write, writes: true) { h, call in
                try await h.editFile(call)
            },
        ]
    }

    // MARK: Previews

    func renderPreview(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try resolve(try call.require("path"), in: s)
        let name = call.string("name")
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let starts = [Self.folder(of: s.model), URL(fileURLWithPath: CommandLine.arguments.first ?? "/").deletingLastPathComponent(),
                      Bundle.main.bundleURL, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        let progress = call.progress
        progress.report(0, message: "Building the preview renderer")
        let result = await Task.detached { PreviewRenderRunner.render(file: url.path, name: name, output: out.path, starts: starts) { progress.report(1, message: $0) } }.value
        switch result {
        case .success(let png):
            guard let data = try? Data(contentsOf: png) else { throw MCPToolError("the renderer wrote no image") }
            return MCPToolResult(content: [.imageBlock(data), .textBlock("\(relative(url.path, in: s)) · \(name ?? "first preview")")])
        case .failure(let f):
            throw MCPToolError(f.description + (f.log.isEmpty ? "" : "\n" + String(f.log.suffix(4000))))
        }
    }

    // MARK: String Catalogs

    func catalogPaths(_ s: WorkspaceSession) -> [String] { workspaceFiles(s).filter { $0.hasSuffix(".xcstrings") } }

    func catalogURL(_ call: MCPToolCall, _ s: WorkspaceSession) throws -> URL {
        if let c = call.string("catalog") { return try resolve(c, in: s) }
        let all = catalogPaths(s)
        guard all.count == 1 else {
            throw MCPToolError(all.isEmpty ? "the workspace has no String Catalog (.xcstrings)"
                                           : "name the catalog: \(all.map { relative($0, in: s) }.joined(separator: ", "))")
        }
        return URL(fileURLWithPath: all[0])
    }

    func loadCatalog(_ url: URL) throws -> StringCatalog {
        guard let text = text(of: url) else { throw MCPToolError("cannot read \(url.lastPathComponent)") }
        do { return try StringCatalog(data: Data(text.utf8)) } catch { throw MCPToolError("\(url.lastPathComponent) is not a valid String Catalog: \(error)") }
    }

    func catalogs(_ call: MCPToolCall) throws -> MCPToolResult {
        let s = try session(for: call)
        var list: [AnyJSON] = []
        var lines: [String] = []
        for p in catalogPaths(s) {
            guard let c = try? loadCatalog(URL(fileURLWithPath: p)) else { continue }
            let langs: [AnyJSON] = c.languages.map { ["language": .string($0), "progress": .int(c.progress(language: $0))] }
            list.append(["path": .string(relative(p, in: s)), "sourceLanguage": .string(c.sourceLanguage), "keys": .int(c.keys.count), "languages": .array(langs)])
            lines.append("\(relative(p, in: s)): \(c.keys.count) keys; " + c.languages.map { "\($0) \(c.progress(language: $0))%" }.joined(separator: ", "))
        }
        return MCPToolResult(content: [.textBlock(lines.isEmpty ? "No String Catalogs." : lines.joined(separator: "\n"))], structured: ["catalogs": .array(list)])
    }

    func listStrings(_ call: MCPToolCall) throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try catalogURL(call, s)
        let c = try loadCatalog(url)
        let lang = try call.require("language")
        var rows = c.rows(language: lang)
        if call.bool("missingOnly") == true {
            rows = rows.filter { [.new, .needsReview, .stale].contains($0.state) || ($0.translation.isEmpty && $0.state != .dontTranslate && $0.state != .variesByPlural) }
        }
        let json: [AnyJSON] = rows.map { r in
            ["key": .string(r.key), "source": .string(r.defaultValue), "comment": .string(r.comment), "translation": .string(r.translation),
             "state": .string(r.state.rawValue), "variations": .strings(r.variations)]
        }
        let text = rows.map { "\($0.key) [\($0.state.rawValue)]: \($0.translation.isEmpty ? "—" : $0.translation)" }.joined(separator: "\n")
        return MCPToolResult(content: [.textBlock("\(lang): \(c.progress(language: lang))% translated\n" + text)],
                             structured: ["catalog": .string(relative(url.path, in: s)), "language": .string(lang),
                                          "progress": .int(c.progress(language: lang)), "strings": .array(json)])
    }

    func setString(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try catalogURL(call, s)
        var c = try loadCatalog(url)
        let key = try call.require("key"), lang = try call.require("language"), value = try call.require("value")
        guard c.keys.contains(key) else { throw MCPToolError("the catalog has no key \"\(key)\"") }
        let original = text(of: url)
        c.addLanguage(lang)
        c.setTranslation(value, key: key, language: lang)
        let proposed = String(decoding: c.data(), as: UTF8.self)
        try await commit(MCPChange(tool: call.name, path: url.path, relativePath: relative(url.path, in: s), original: original, proposed: proposed,
                                   summary: "Translate \"\(key)\" into \(lang)"), call: call, session: s)
        return .structured(["catalog": .string(relative(url.path, in: s)), "key": .string(key), "language": .string(lang),
                            "progress": .int(c.progress(language: lang))], summary: "Set \(lang) for \"\(key)\".")
    }

    // MARK: Writes

    /// Asks the write policy, then writes the file (unless the review
    /// already put the same text on disk) and tells the session.
    func commit(_ change: MCPChange, call: MCPToolCall, session s: WorkspaceSession) async throws {
        guard await call.approve(change) else { throw MCPToolError(MCPServer.rejectedMessage) }
        let url = URL(fileURLWithPath: change.path)
        if (try? String(contentsOf: url, encoding: .utf8)) != change.proposed {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try change.proposed.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                throw MCPToolError("cannot write \(change.relativePath): \(error.localizedDescription)")
            }
        }
        s.noteFileEdited(url.path)
        delegate?.mcpHostDidWrite(url.path)
    }

    func writeFile(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try resolve(try call.require("path"), in: s)
        let content = try call.require("content")
        let original = text(of: url)
        let rel = relative(url.path, in: s)
        try await commit(MCPChange(tool: call.name, path: url.path, relativePath: rel, original: original, proposed: content,
                                   summary: original == nil ? "Create \(rel)" : "Replace \(rel)"), call: call, session: s)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return .structured(["path": .string(rel), "created": .bool(original == nil), "lineCount": .int(lines)],
                           summary: original == nil ? "Created \(rel)." : "Wrote \(rel).")
    }

    func editFile(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try resolve(try call.require("path"), in: s)
        let rel = relative(url.path, in: s)
        guard let original = text(of: url) else { throw MCPToolError("\(rel) does not exist (create it with file_write)") }
        let old = try call.require("oldText"), new = try call.require("newText")
        guard !old.isEmpty else { throw MCPToolError("oldText is empty") }
        let count = original.components(separatedBy: old).count - 1
        guard count > 0 else { throw MCPToolError("oldText does not occur in \(rel); read the file again (file_read) and copy the text exactly") }
        let all = call.bool("replaceAll") ?? false
        guard count == 1 || all else { throw MCPToolError("oldText occurs \(count) times in \(rel); add surrounding lines to make it unique, or set replaceAll") }
        let proposed: String
        if all {
            proposed = original.replacingOccurrences(of: old, with: new)
        } else {
            let r = original.range(of: old)!
            proposed = original.replacingCharacters(in: r, with: new)
        }
        try await commit(MCPChange(tool: call.name, path: url.path, relativePath: rel, original: original, proposed: proposed,
                                   summary: "Edit \(rel)"), call: call, session: s)
        return .structured(["path": .string(rel), "replacements": .int(all ? count : 1)], summary: "Edited \(rel).")
    }
}

/// The resources: the workspace's files (`file://` URIs), the last build
/// log and the issue list.
struct YcodeResources: MCPResourceSource {
    weak var host: YcodeMCPHost?

    static let buildLogURI = "ycode://workspace/build-log"
    static let issuesURI = "ycode://workspace/issues"

    func resources() async -> [MCPResource] {
        await MainActor.run {
            guard let host, let s = host.session else { return [] }
            var out = [MCPResource(uri: Self.buildLogURI, name: "build-log", title: "Last build log", mimeType: "text/plain"),
                       MCPResource(uri: Self.issuesURI, name: "issues", title: "Issues", mimeType: "application/json")]
            for p in host.workspaceFiles(s).prefix(2000) {
                out.append(MCPResource(uri: URL(fileURLWithPath: p).absoluteString, name: host.relative(p, in: s), mimeType: Self.mimeType(p)))
            }
            return out
        }
    }

    func templates() async -> [AnyJSON] {
        [["uriTemplate": "file:///{path}", "name": "workspace-file", "title": "A file of the open workspace", "mimeType": "text/plain"]]
    }

    func read(_ uri: String) async throws -> [AnyJSON]? {
        try await MainActor.run { () throws -> [AnyJSON]? in
            guard let host, let s = host.session else { return nil }
            switch uri {
            case Self.buildLogURI:
                return [["uri": .string(uri), "mimeType": "text/plain", "text": .string(s.buildLog.joined(separator: "\n"))]]
            case Self.issuesURI:
                let root = YcodeMCPHost.folder(of: s.model).path
                return [["uri": .string(uri), "mimeType": "application/json",
                         "text": .string(AnyJSON.array(s.displayedIssues.map { YcodeMCPHost.issueJSON($0, relativeTo: root) }).text)]]
            default:
                guard let url = URL(string: uri), url.isFileURL else { return nil }
                guard YcodeMCPHost.isInside(url, YcodeMCPHost.folder(of: s.model)) else {
                    throw JSONRPCError.invalidParams("\(url.path) is outside the workspace folder")
                }
                guard let text = host.text(of: url) else { return nil }
                return [["uri": .string(uri), "mimeType": .string(Self.mimeType(url.path)), "text": .string(text)]]
            }
        }
    }

    static func mimeType(_ path: String) -> String {
        switch (path as NSString).pathExtension {
        case "swift": "text/x-swift"
        case "json", "xcstrings": "application/json"
        case "md": "text/markdown"
        case "plist", "xcscheme", "xml": "application/xml"
        default: "text/plain"
        }
    }
}
