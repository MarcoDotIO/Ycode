import Foundation
import YcodeAssistant
import YcodeBuild
import YcodeIDECore
import YcodeProject
import YcodeSettings
import YcodeWorkspace

extension YcodeMCPHost {
    var workspaceTools: [MCPTool] {
        [
            tool("workspace_open", "Open workspace",
                 "Opens a Swift package (its folder or Package.swift), an .xcodeproj or an .xcworkspace, and describes it (schemes, targets, destinations).",
                 input: Schema.object(["path": Schema.string("The package folder, Package.swift, .xcodeproj or .xcworkspace.")], required: ["path"]),
                 output: Self.describeSchema) { h, call in
                let path = (try call.require("path") as NSString).expandingTildeInPath
                var url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
                if url.pathExtension.isEmpty, url.lastPathComponent != "Package.swift", let found = Self.discoverWorkspace(in: url) { url = found }
                do {
                    try h.open(url)
                } catch let e as MCPToolError {
                    throw e
                } catch {
                    throw MCPToolError("cannot open \(path): it is not a package folder, Package.swift, .xcodeproj or .xcworkspace (\(error.localizedDescription))")
                }
                let d = try h.describe(h.session(for: MCPToolCall(name: "", arguments: [:])))
                return .structured(d, summary: "Opened \(d["name"]?.string ?? path).")
            },
            tool("workspace_describe", "Describe workspace",
                 "The open workspace: kind, folder, schemes, targets, configurations, run destinations (including the Ycode Simulator when set up), the selected scheme and destination, and test plans.",
                 input: Schema.object(["workspace": Schema.workspace]), output: Self.describeSchema) { h, call in
                .structured(try h.describe(h.session(for: call)))
            },
            tool("file_list", "List files",
                 "The workspace's files (as the project navigator shows them, plus files in folders), relative to the workspace folder.",
                 input: Schema.object(["workspace": Schema.workspace,
                                       "glob": Schema.string("Optional pattern the relative path must match (fnmatch, e.g. \"Sources/*.swift\" or \"*Tests*\")."),
                                       "limit": Schema.integer("At most this many paths (default 500).", minimum: 1)]),
                 output: Schema.output(["files": Schema.array(Schema.str, "Relative paths."), "truncated": Schema.bool])) { h, call in
                try h.listFiles(call)
            },
            tool("file_read", "Read file",
                 "A text file of the workspace, with line numbers. In the IDE, an open editor's unsaved text is read.",
                 input: Schema.object(["workspace": Schema.workspace, "path": Schema.string("Relative to the workspace folder."),
                                       "startLine": Schema.integer("First line to read (1-based; default 1).", minimum: 1),
                                       "lineCount": Schema.integer("Number of lines (default: to the end, at most 2000).", minimum: 1)],
                                      required: ["path"]),
                 output: Schema.output(["path": Schema.str, "startLine": Schema.int, "endLine": Schema.int, "lineCount": Schema.int, "text": Schema.str])) { h, call in
                try h.readFile(call)
            },
            tool("search", "Search workspace",
                 "Searches every text file of the workspace (Ycode's Find in Workspace): plain text by default, or a regular expression.",
                 input: Schema.object(["workspace": Schema.workspace, "query": Schema.string("The text or pattern."),
                                       "regex": Schema.boolean("Treat the query as a regular expression."),
                                       "ignoreCase": Schema.boolean("Ignore case (default true)."),
                                       "wholeWord": Schema.boolean("Match whole words only."),
                                       "limit": Schema.integer("At most this many matches (default 200).", minimum: 1)],
                                      required: ["query"]),
                 output: Schema.output(["matches": Schema.anyArray, "matchCount": Schema.int, "truncated": Schema.bool])) { h, call in
                try await h.search(call)
            },
            tool("issues", "Issues",
                 "The workspace's current issues: the last build's or test run's errors and warnings, and project problems, with file, line and fix-its.",
                 input: Schema.object(["workspace": Schema.workspace]),
                 output: Schema.output(["issues": Schema.anyArray, "errors": Schema.int, "warnings": Schema.int])) { h, call in
                let s = try h.session(for: call)
                let root = Self.folder(of: s.model).path
                let issues = s.displayedIssues
                let errors = issues.filter { $0.severity == .error }.count, warnings = issues.filter { $0.severity == .warning }.count
                return .structured(["issues": .array(issues.prefix(500).map { Self.issueJSON($0, relativeTo: root) }),
                                    "errors": .int(errors), "warnings": .int(warnings)],
                                   summary: "\(errors) errors, \(warnings) warnings.")
            },
            tool("build_settings", "Build settings",
                 "A project target's resolved build settings for a configuration (projects and workspaces; Swift packages have none).",
                 input: Schema.object(["workspace": Schema.workspace, "target": Schema.string("The target (default: the first)."),
                                       "configuration": Schema.string("The configuration (default: the project's default)."),
                                       "names": Schema.array(Schema.str, "Only these settings (default: all).")]),
                 output: Schema.output(["target": Schema.str, "configuration": Schema.str, "settings": Schema.anyObject])) { h, call in
                try h.buildSettings(call)
            },
            tool("symbol_search", "Find symbol documentation",
                 "Declarations in the workspace's Swift sources whose name contains the query (types, functions, properties), with their documentation comments. Apple SDK documentation is not searched.",
                 input: Schema.object(["workspace": Schema.workspace, "query": Schema.string("Part of the symbol's name."),
                                       "limit": Schema.integer("At most this many symbols (default 50).", minimum: 1)],
                                      required: ["query"]),
                 output: Schema.output(["symbols": Schema.anyArray])) { h, call in
                try await h.symbolSearch(call)
            },
        ]
    }

    static let describeSchema = Schema.output([
        "name": Schema.str, "kind": Schema.str, "path": Schema.str, "folder": Schema.str, "schemes": Schema.anyArray,
        "targets": Schema.anyArray, "configurations": Schema.anyArray, "destinations": Schema.anyArray,
        "selectedScheme": ["type": ["string", "null"]], "selectedDestination": ["type": ["object", "null"]], "testPlans": Schema.anyArray,
        "remoteSimulator": Schema.bool,
    ])

    func describe(_ s: WorkspaceSession) throws -> AnyJSON {
        let m = s.model
        var targets: [AnyJSON] = []
        for (path, proj) in m.projects.sorted(by: { $0.key < $1.key }) {
            for t in proj.targets {
                targets.append(["name": .optional(t.string("name")), "productType": .optional(t.string("productType")),
                                "project": .string(relative(path, in: s))])
            }
        }
        if m.kind == .package { targets = Self.packageTargets(m.url).map { ["name": .string($0), "productType": "swiftpm"] } }
        let kind: String = switch m.kind { case .package: "package"; case .project: "project"; case .workspace: "workspace" }
        return [
            "name": .string(m.displayName), "kind": .string(kind), "path": .string(m.url.path), "folder": .string(Self.folder(of: m).path),
            "schemes": .strings(m.schemeNames), "targets": .array(targets), "configurations": .strings(m.kind == .package ? ["debug", "release"] : m.configurationNames),
            "destinations": .array(m.destinations.map(Self.destinationJSON)), "selectedScheme": .optional(s.scheme),
            "selectedDestination": s.destination.map(Self.destinationJSON) ?? .null, "testPlans": .strings(s.testPlanNames),
            "remoteSimulator": .bool(remoteSimulator?.isConfigured ?? false),
        ]
    }

    /// The target folders of a package (`Sources/*`, `Tests/*`).
    nonisolated static func packageTargets(_ dir: URL) -> [String] {
        let fm = FileManager.default
        return ["Sources", "Tests"].flatMap { sub -> [String] in
            let items = (try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent(sub).path)) ?? []
            return items.filter { !$0.hasPrefix(".") }.sorted()
        }
    }

    /// Every file path of the workspace (navigator order).
    func workspaceFiles(_ s: WorkspaceSession) -> [String] {
        var seen = Set<String>()
        return FindScopeResolver(root: s.model.root).candidates(for: .workspace).map(\.path).filter { seen.insert($0).inserted }
    }

    func listFiles(_ call: MCPToolCall) throws -> MCPToolResult {
        let s = try session(for: call)
        let limit = call.int("limit") ?? 500
        var files = workspaceFiles(s).map { relative($0, in: s) }
        if let g = call.string("glob") { files = files.filter { Self.matches(glob: g, $0) } }
        let truncated = files.count > limit
        files = Array(files.prefix(limit))
        return MCPToolResult(content: [.textBlock(files.joined(separator: "\n") + (truncated ? "\n… (more; narrow with glob)" : ""))],
                             structured: ["files": .strings(files), "truncated": .bool(truncated)])
    }

    /// fnmatch-style matching; a pattern without "/" also matches the file name.
    nonisolated static func matches(glob: String, _ path: String) -> Bool {
        func m(_ p: String, _ s: String) -> Bool { fnmatch(p, s, 0) == 0 }
        return m(glob, path) || (!glob.contains("/") && m(glob, (path as NSString).lastPathComponent))
    }

    func readFile(_ call: MCPToolCall) throws -> MCPToolResult {
        let s = try session(for: call)
        let url = try resolve(try call.require("path"), in: s)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) || delegate?.mcpHostText(ofOpenFile: url.path) != nil else {
            throw MCPToolError("\(relative(url.path, in: s)) does not exist")
        }
        guard !isDir.boolValue else { throw MCPToolError("\(relative(url.path, in: s)) is a folder; use file_list") }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 8 << 20 {
            throw MCPToolError("\(relative(url.path, in: s)) is larger than 8 MB")
        }
        guard let text = text(of: url) else { throw MCPToolError("\(relative(url.path, in: s)) is not UTF-8 text") }
        var lines = text.components(separatedBy: "\n")
        if text.hasSuffix("\n") { lines.removeLast() }
        let start = max(1, call.int("startLine") ?? 1)
        let count = min(call.int("lineCount") ?? 2000, 2000)
        let end = min(lines.count, start + count - 1)
        let slice = start <= lines.count ? Array(lines[(start - 1)..<end]) : []
        let numbered = slice.enumerated().map { String(format: "%6d\t", start + $0.offset) + $0.element }.joined(separator: "\n")
        let more = end < lines.count ? "\n… (\(lines.count - end) more lines; read on with startLine \(end + 1))" : ""
        return MCPToolResult(content: [.textBlock(numbered + more)],
                             structured: ["path": .string(relative(url.path, in: s)), "startLine": .int(start), "endLine": .int(max(end, start - 1)),
                                          "lineCount": .int(lines.count), "text": .string(slice.joined(separator: "\n"))])
    }

    func search(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let query = try call.require("query")
        guard !query.isEmpty else { throw MCPToolError("the query is empty") }
        let options = WorkspaceSearch.Options(regularExpression: call.bool("regex") ?? false, wholeWord: call.bool("wholeWord") ?? false,
                                              ignoreCase: call.bool("ignoreCase") ?? true)
        let limit = call.int("limit") ?? 200
        let root = s.model.root
        let results = await Task.detached { WorkspaceSearch.search(query, in: root, options: options, limit: limit + 1) }.value
        var matches: [AnyJSON] = []
        var lines: [String] = []
        for f in results {
            let rel = relative(f.path, in: s)
            for m in f.matches where matches.count < limit {
                matches.append(["path": .string(rel), "line": .int(m.line), "column": .int(m.column), "text": .string(m.text)])
                lines.append("\(rel):\(m.line):\(m.column): \(m.text)")
            }
        }
        let total = results.reduce(0) { $0 + $1.matches.count }
        return MCPToolResult(content: [.textBlock(lines.isEmpty ? "No matches." : lines.joined(separator: "\n"))],
                             structured: ["matches": .array(matches), "matchCount": .int(min(total, limit)), "truncated": .bool(total > limit)])
    }

    func buildSettings(_ call: MCPToolCall) throws -> MCPToolResult {
        let s = try session(for: call)
        guard s.model.kind != .package else {
            throw MCPToolError("Swift packages have no build settings; their settings are in Package.swift (read it with file_read)")
        }
        let wanted = call.string("target")
        let projects = s.model.projects.sorted { $0.key < $1.key }
        guard let (path, proj) = projects.first(where: { p in wanted.map { w in p.value.targets.contains { $0.string("name") == w } } ?? true }) else {
            throw MCPToolError("no target \"\(wanted ?? "")\" in the workspace's projects")
        }
        let xcodeproj = URL(fileURLWithPath: path)
        var builder = ProjectSettingsBuilder(proj: proj, xcodeprojURL: xcodeproj)
        builder.developerDirectory = Workspace.activeDeveloperDirectory()
        if let dev = builder.developerDirectory {
            let catalog = SDKCatalog(developerDirectory: dev)
            builder.sdkLookup = { catalog.lookup($0) }
        }
        let config = call.string("configuration")
            ?? proj.objects[proj.project?.string("buildConfigurationList") ?? ""]?.string("defaultConfigurationName") ?? "Release"
        let target = wanted ?? proj.targets.first?.string("name")
        let resolved: ProjectSettingsBuilder.Resolved
        do { resolved = try builder.resolve(target: target, configuration: config) } catch {
            throw MCPToolError("cannot resolve the settings of \(target ?? "the project") (\(config)): \(error)")
        }
        var names = resolved.settings.names
        if let only = call.strings("names"), !only.isEmpty { names = names.filter { only.contains($0) } }
        var dict: [String: AnyJSON] = [:]
        for n in names { dict[n] = .string(resolved.settings[n]) }
        return MCPToolResult(content: [.textBlock(names.map { "\($0) = \(resolved.settings[$0])" }.joined(separator: "\n"))],
                             structured: ["target": .optional(target), "configuration": .string(config), "settings": .object(dict)])
    }

    func symbolSearch(_ call: MCPToolCall) async throws -> MCPToolResult {
        let s = try session(for: call)
        let query = try call.require("query")
        let limit = call.int("limit") ?? 50
        let files = workspaceFiles(s).filter { $0.hasSuffix(".swift") }
        let found = await Task.detached { SymbolDocs.search(query, files: files, limit: limit) }.value
        let json: [AnyJSON] = found.map { d in
            ["name": .string(d.name), "kind": .string(d.kind), "path": .string(relative(d.path, in: s)), "line": .int(d.line),
             "declaration": .string(d.declaration), "documentation": .string(d.documentation)]
        }
        let text = found.map { d in
            "\(relative(d.path, in: s)):\(d.line): \(d.declaration)" + (d.documentation.isEmpty ? "" : "\n    " + d.documentation.replacingOccurrences(of: "\n", with: "\n    "))
        }.joined(separator: "\n")
        return MCPToolResult(content: [.textBlock(text.isEmpty ? "No declarations match \"\(query)\"." : text)], structured: ["symbols": .array(json)])
    }
}

/// Declarations and their `///` or `/** */` comments, read from source
/// text (no index: names containing the query, in file order).
enum SymbolDocs {
    struct Symbol: Sendable {
        var name: String
        var kind: String
        var path: String
        var line: Int
        var declaration: String
        var documentation: String
    }

    static let keywords = ["func", "class", "struct", "enum", "protocol", "actor", "extension", "var", "let", "typealias", "case", "init", "macro"]

    static func search(_ query: String, files: [String], limit: Int) -> [Symbol] {
        let q = query.lowercased()
        var out: [Symbol] = []
        for f in files {
            guard out.count < limit, let text = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
            out += declarations(in: text, path: f).filter { $0.name.lowercased().contains(q) }.prefix(limit - out.count)
        }
        return out
    }

    static func declarations(in text: String, path: String) -> [Symbol] {
        let lines = text.components(separatedBy: "\n")
        var out: [Symbol] = []
        var doc: [String] = []
        var inBlock = false
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if inBlock {
                if line.hasSuffix("*/") { inBlock = false; doc.append(String(line.dropLast(2))) } else { doc.append(line.hasPrefix("*") ? String(line.dropFirst()) : line) }
                continue
            }
            if line.hasPrefix("///") { doc.append(String(line.dropFirst(3))); continue }
            if line.hasPrefix("/**") {
                let rest = String(line.dropFirst(3))
                if rest.hasSuffix("*/") { doc.append(String(rest.dropLast(2))) } else { inBlock = true; doc.append(rest) }
                continue
            }
            if line.hasPrefix("@") && !line.contains(" func ") && !line.contains(" var ") && !line.contains(" struct ") && !line.contains(" class ") { continue }
            if let (kind, name) = declaration(line) {
                out.append(Symbol(name: name, kind: kind, path: path, line: i + 1, declaration: line.hasSuffix("{") ? String(line.dropLast()).trimmingCharacters(in: .whitespaces) : line,
                                  documentation: doc.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if !line.isEmpty { doc = [] }
        }
        return out
    }

    /// The keyword and name a declaration line starts with (after
    /// attributes and modifiers), if it is one.
    static func declaration(_ line: String) -> (String, String)? {
        let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for (i, w) in words.enumerated() {
            if w.hasPrefix("@") || ["public", "private", "fileprivate", "internal", "open", "package", "static", "final", "override", "mutating",
                                    "nonisolated", "convenience", "required", "indirect", "lazy", "weak", "dynamic", "async"].contains(w)
                || w.hasPrefix("private(") || w.hasPrefix("public(") || w.hasPrefix("internal(") || w.hasPrefix("fileprivate(") || w.hasPrefix("package(") { continue }
            if w == "init" || w.hasPrefix("init(") || w.hasPrefix("init?(") || w.hasPrefix("init<") { return ("init", "init") }
            guard keywords.contains(w), i + 1 < words.count else { return nil }
            let rawName = words[i + 1]
            let name = String(rawName.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." })
            return name.isEmpty ? nil : (w, name)
        }
        return nil
    }
}
