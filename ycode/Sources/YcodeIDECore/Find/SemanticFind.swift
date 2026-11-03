import Foundation
import YcodeLanguage

/// The language-server requests the semantic find kinds use. `LSPClient`
/// provides them; tests can stand in.
public protocol SemanticFindService: Sendable {
    func workspaceSymbols(_ query: String) async throws -> [WorkspaceSymbol]
    func references(_ url: URL, at p: Position) async throws -> [Location]
    func prepareCallHierarchy(_ url: URL, at p: Position) async throws -> [CallHierarchyItem]
    func incomingCalls(_ item: CallHierarchyItem) async throws -> [(caller: CallHierarchyItem, ranges: [Position])]
    func prepareTypeHierarchy(_ url: URL, at p: Position) async throws -> [TypeHierarchyItem]
    func supertypes(_ item: TypeHierarchyItem) async throws -> [TypeHierarchyItem]
    func subtypes(_ item: TypeHierarchyItem) async throws -> [TypeHierarchyItem]
}

extension LSPClient: SemanticFindService {}

/// A row of the Find navigator's results: a heading, a file, a match or a
/// symbol, with where selecting it goes.
public struct FindResultNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case heading, file, match, symbol }
    public var kind: Kind
    public var title: String
    public var detail: String?
    public var path: String?
    /// 1-based.
    public var line: Int?
    /// LSP `SymbolKind` of a symbol row.
    public var symbolKind: Int?
    public var children: [FindResultNode]

    public init(kind: Kind, title: String, detail: String? = nil, path: String? = nil, line: Int? = nil, symbolKind: Int? = nil,
                children: [FindResultNode] = []) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.path = path
        self.line = line
        self.symbolKind = symbolKind
        self.children = children
    }

    /// Rows below this one, depth-first (tests, counts).
    public var flattened: [FindResultNode] { [self] + children.flatMap(\.flattened) }
}

/// The Find navigator's semantic kinds (Symbols ▸ Definitions and
/// References, Call Hierarchy, Ancestor, Descendent and Conforming Types)
/// through the language server. A query names the symbol; the editor's
/// commands start from the caret instead. See `specs/ide/navigators.md`
/// §Find navigator, "Ycode implementation".
public enum SemanticFind {
    public struct Result: Equatable, Sendable {
        /// "Greeter — 3 references", "Callers of greet(times:)", …
        public var heading: String
        public var nodes: [FindResultNode]
        /// Results counted for the heading (references, definitions, types, callers).
        public var count: Int
        /// Why there is nothing to show (no server, no symbol, unsupported).
        public var message: String?
        public init(heading: String, nodes: [FindResultNode] = [], count: Int = 0, message: String? = nil) {
            self.heading = heading
            self.nodes = nodes
            self.count = count
            self.message = message
        }
    }

    /// A symbol to start from: its file, the position of its name, its name.
    public struct Seed: Equatable, Sendable {
        public var url: URL
        public var position: Position
        public var name: String
        public var kind: Int
        public init(url: URL, position: Position, name: String, kind: Int = 0) {
            self.url = url
            self.position = position
            self.name = name
            self.kind = kind
        }
    }

    /// At most this many symbols are expanded for one query.
    public static let maxSeeds = 20
    /// Call hierarchy depth shown (callers of callers).
    public static let callerDepth = 2
    /// Type hierarchy depth followed.
    public static let typeDepth = 8

    /// Reads one line of a file (0-based), for row text.
    public typealias LineReader = @Sendable (String, Int) -> String?

    public static let diskLines: LineReader = { path, line in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\n")
        return line < lines.count ? lines[line] : nil
    }

    /// The symbol's base name: "greet(times:)" → "greet".
    public static func baseName(_ name: String) -> String {
        String(name.prefix { $0 != "(" && $0 != "<" && $0 != " " })
    }

    /// Whether a symbol name matches the query's text, match style and case.
    public static func nameMatches(_ name: String, _ q: FindQuery) -> Bool {
        let base = baseName(name)
        let a = q.ignoreCase ? base.lowercased() : base, b = q.ignoreCase ? q.text.lowercased() : q.text
        let full = q.ignoreCase ? name.lowercased() : name
        guard !b.isEmpty else { return false }
        switch q.match {
        case .containing: return a.contains(b) || full.contains(b)
        case .matchingWord: return a == b || full == b
        case .startingWith: return a.hasPrefix(b)
        case .endingWith: return a.hasSuffix(b) || full.hasSuffix(b)
        }
    }

    /// The symbols a query names, best first: exact names, then the rest
    /// by name. The position is moved onto the name in its line.
    public static func seeds(_ q: FindQuery, service: SemanticFindService, lines: LineReader = diskLines,
                             where keep: (WorkspaceSymbol) -> Bool = { _ in true }) async throws -> [Seed] {
        let symbols = try await service.workspaceSymbols(q.text).filter { nameMatches($0.name, q) && keep($0) }
        let exact = q.ignoreCase ? q.text.lowercased() : q.text
        let sorted = symbols.sorted { a, b in
            let ea = (q.ignoreCase ? baseName(a.name).lowercased() : baseName(a.name)) == exact
            let eb = (q.ignoreCase ? baseName(b.name).lowercased() : baseName(b.name)) == exact
            if ea != eb { return ea }
            return (a.name, a.location.url.path, a.location.start.line) < (b.name, b.location.url.path, b.location.start.line)
        }
        return sorted.prefix(maxSeeds).map { s in
            Seed(url: s.location.url, position: namePosition(s.name, at: s.location.start, path: s.location.url.path, lines: lines),
                 name: s.name, kind: s.kind)
        }
    }

    /// The position of `name`'s first occurrence on the line at or after
    /// `p` (a declaration's range can start at its keywords).
    static func namePosition(_ name: String, at p: Position, path: String, lines: LineReader) -> Position {
        guard let line = lines(path, p.line) else { return p }
        let units = Array(line.utf16), base = Array(baseName(name).utf16)
        guard !base.isEmpty, units.count >= base.count else { return p }
        var i = min(p.character, units.count)
        while i + base.count <= units.count {
            if Array(units[i..<(i + base.count)]) == base { return Position(line: p.line, character: i) }
            i += 1
        }
        return p
    }

    // MARK: Running a query

    /// Runs a semantic query from the Find navigator.
    public static func run(_ q: FindQuery, service: SemanticFindService?, lines: LineReader = diskLines) async -> Result {
        guard let service else { return Result(heading: q.text, message: "No language server") }
        guard q.kind.isSemantic, !q.text.isEmpty else { return Result(heading: q.text) }
        do {
            let keep: (WorkspaceSymbol) -> Bool
            switch q.kind {
            case .callHierarchy: keep = { $0.isCallable }
            case .ancestorTypes, .descendentTypes: keep = { $0.isType }
            case .conformingTypes: keep = { $0.kind == 11 }
            default: keep = { _ in true }
            }
            if q.kind == .symbols && q.symbolRole == .definitions {
                let syms = try await service.workspaceSymbols(q.text).filter { nameMatches($0.name, q) }
                return definitions(q.text, syms, lines: lines)
            }
            let s = try await seeds(q, service: service, lines: lines, where: keep)
            guard !s.isEmpty else { return Result(heading: q.text, message: "No symbol named \u{201C}\(q.text)\u{201D}") }
            return try await expand(q.kind, seeds: q.kind == .symbols ? s.filter { baseName($0.name) == baseName(s[0].name) } : s,
                                    service: service, lines: lines)
        } catch {
            return Result(heading: q.text, message: Self.describe(error, kind: q.kind))
        }
    }

    /// Runs a kind from the editor's caret (Find Selected Symbol in
    /// Workspace, Find Call Hierarchy, Find Ancestor Types, …).
    public static func run(_ kind: FindQuery.Kind, at seed: Seed, service: SemanticFindService?, lines: LineReader = diskLines) async -> Result {
        guard let service else { return Result(heading: seed.name, message: "No language server") }
        do {
            return try await expand(kind, seeds: [seed], service: service, lines: lines)
        } catch {
            return Result(heading: seed.name, message: Self.describe(error, kind: kind))
        }
    }

    static func describe(_ error: Error, kind: FindQuery.Kind) -> String {
        if let e = error as? LSPClient.ResponseError, e.code == -32601 {
            return "The language server does not support \(kind.title.lowercased())"
        }
        return "\(error)"
    }

    static func expand(_ kind: FindQuery.Kind, seeds: [Seed], service: SemanticFindService, lines: LineReader) async throws -> Result {
        switch kind {
        case .callHierarchy: return try await callers(seeds, service: service)
        case .ancestorTypes, .descendentTypes, .conformingTypes: return try await types(kind, seeds, service: service)
        default: return try await references(seeds, service: service, lines: lines)
        }
    }

    // MARK: Kinds

    /// Symbols ▸ Definitions: the declarations, by file.
    static func definitions(_ text: String, _ syms: [WorkspaceSymbol], lines: LineReader) -> Result {
        let byFile = Dictionary(grouping: syms) { $0.location.url.standardizedFileURL.path }
        let nodes = byFile.keys.sorted().map { path in
            let list = byFile[path]!.sorted { $0.location.start.line < $1.location.start.line }
            return FindResultNode(kind: .file, title: (path as NSString).lastPathComponent, detail: "(\(list.count))", path: nil,
                                  children: list.map { s in
                                      FindResultNode(kind: .symbol, title: s.name, detail: s.containerName, path: path, line: s.location.start.line + 1,
                                                     symbolKind: s.kind)
                                  })
        }
        return Result(heading: "\(text) — \(plural(syms.count, "definition"))", nodes: nodes, count: syms.count,
                      message: syms.isEmpty ? "No symbol named \u{201C}\(text)\u{201D}" : nil)
    }

    /// References (with the declarations), merged for every seed, by file
    /// then line; rows read "line: text".
    static func references(_ seeds: [Seed], service: SemanticFindService, lines: LineReader) async throws -> Result {
        var seen = Set<String>()
        var refs: [Location] = []
        for s in seeds {
            for l in try await service.references(s.url, at: s.position) where seen.insert("\(l.url.standardizedFileURL.path):\(l.start.line):\(l.start.character)").inserted {
                refs.append(l)
            }
        }
        let byFile = Dictionary(grouping: refs) { $0.url.standardizedFileURL.path }
        let nodes = byFile.keys.sorted().map { path in
            let list = byFile[path]!.sorted { ($0.start.line, $0.start.character) < ($1.start.line, $1.start.character) }
            return FindResultNode(kind: .file, title: (path as NSString).lastPathComponent, detail: "(\(list.count))",
                                  children: list.map { l in
                                      let text = lines(path, l.start.line)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                      return FindResultNode(kind: .match, title: "\(l.start.line + 1): \(text)", path: path, line: l.start.line + 1)
                                  })
        }
        let name = seeds.first.map { baseName($0.name) } ?? ""
        return Result(heading: "\(name) — \(plural(refs.count, "reference"))", nodes: nodes, count: refs.count)
    }

    /// Call Hierarchy: each function, then its callers, `callerDepth` levels.
    static func callers(_ seeds: [Seed], service: SemanticFindService) async throws -> Result {
        var nodes: [FindResultNode] = []
        var count = 0
        func node(_ i: CallHierarchyItem, depth: Int, visited: Set<String>) async throws -> FindResultNode {
            var kids: [FindResultNode] = []
            let key = "\(i.url.path):\(i.selection.line):\(i.name)"
            if depth < callerDepth, !visited.contains(key) {
                for (caller, _) in try await service.incomingCalls(i) {
                    if depth == 0 { count += 1 }
                    kids.append(try await node(caller, depth: depth + 1, visited: visited.union([key])))
                }
            }
            return FindResultNode(kind: .symbol, title: i.name, detail: i.detail, path: i.url.standardizedFileURL.path, line: i.selection.line + 1,
                                  symbolKind: 12, children: kids)
        }
        for s in seeds {
            for item in try await service.prepareCallHierarchy(s.url, at: s.position) {
                nodes.append(try await node(item, depth: 0, visited: []))
            }
        }
        let name = nodes.count == 1 ? nodes[0].title : (seeds.first.map { baseName($0.name) } ?? "")
        return Result(heading: "Callers of \(name)", nodes: nodes, count: count,
                      message: nodes.isEmpty ? "No function at the symbol" : nil)
    }

    /// Ancestor Types (supertypes), Descendent Types (subtypes) and
    /// Conforming Types (the types that adopt a protocol), followed
    /// `typeDepth` levels without repeating a type.
    static func types(_ kind: FindQuery.Kind, _ seeds: [Seed], service: SemanticFindService) async throws -> Result {
        var count = 0
        func key(_ i: TypeHierarchyItem) -> String { "\(i.url.path):\(i.selection.line):\(i.name)" }
        func next(_ i: TypeHierarchyItem) async throws -> [TypeHierarchyItem] {
            let list = kind == .ancestorTypes ? try await service.supertypes(i) : try await service.subtypes(i)
            switch kind {
            // Protocols refine protocols; other types adopt them.
            case .conformingTypes: return list.filter { $0.kind != 11 }
            case .descendentTypes where i.kind == 11: return list.filter { $0.kind == 11 }
            default: return list
            }
        }
        func node(_ i: TypeHierarchyItem, depth: Int, visited: inout Set<String>) async throws -> FindResultNode {
            var kids: [FindResultNode] = []
            if depth < typeDepth {
                for t in try await next(i) where visited.insert(key(t)).inserted {
                    count += 1
                    kids.append(try await node(t, depth: depth + 1, visited: &visited))
                }
            }
            return FindResultNode(kind: .symbol, title: i.name, detail: i.detail, path: i.url.standardizedFileURL.path, line: i.selection.line + 1,
                                  symbolKind: i.kind, children: kids)
        }
        var nodes: [FindResultNode] = []
        for s in seeds {
            for item in try await service.prepareTypeHierarchy(s.url, at: s.position) {
                var visited: Set<String> = [key(item)]
                nodes.append(try await node(item, depth: 0, visited: &visited))
            }
        }
        let name = nodes.first?.title ?? (seeds.first.map { baseName($0.name) } ?? "")
        let what: String
        switch kind {
        case .ancestorTypes: what = "Ancestor types of"
        case .conformingTypes: what = "Types conforming to"
        default: what = "Descendent types of"
        }
        return Result(heading: "\(what) \(name)", nodes: nodes, count: count, message: nodes.isEmpty ? "No type at the symbol" : nil)
    }

    static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
}
