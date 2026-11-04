import Foundation
import Observation
import YcodeIDECore
import YcodeLanguage

/// One visible row of the Symbol navigator: a file, or a declaration in it.
public struct SymbolNavigatorRow: Identifiable, Equatable, Sendable {
    public var id: String
    public var level: Int
    public var title: String
    /// The declaration's kind; nil for a file row.
    public var kind: SymbolScanner.Symbol.Kind?
    public var path: String
    /// 1-based; nil for a file row.
    public var line: Int?
    public var isExpandable: Bool
    public var isExpanded: Bool
}

/// The Symbol navigator of the Linux IDE (⌘3; `navigators.md` §Symbols):
/// the workspace's source files that declare something, each with its
/// declarations nested as the macOS IDE groups them (`SymbolScanner`:
/// types, then their members), in file order. The filter keeps the
/// declarations whose name contains it (and the types around them); with a
/// language server running, the server's `workspace/symbol` matches join
/// them (declarations the scan does not see, such as those in a function's
/// body). Selecting a declaration opens its line.
@MainActor
@Observable
public final class SymbolNavigatorModel {
    public struct FileSymbols: Equatable, Sendable {
        public var path: String
        public var symbols: [SymbolScanner.Symbol]
    }

    /// Every file's declarations, in navigator order.
    public private(set) var files: [FileSymbols] = []
    /// The bottom bar's filter.
    public var filterText = "" { didSet { if filterText != oldValue { scheduleServerQuery() } } }
    /// The server's matches for the filter, as declarations by file.
    public private(set) var serverMatches: [String: [SymbolScanner.Symbol]] = [:]
    public private(set) var collapsed: Set<String> = []
    public var selection: String?
    public private(set) var isScanning = false
    /// The language server's `workspace/symbol` (the window sets it; nil: none).
    @ObservationIgnored public var workspaceSymbols: ((String) async -> [WorkspaceSymbol])?
    @ObservationIgnored private var scan: Task<Void, Never>?
    @ObservationIgnored private var query: Task<Void, Never>?

    public init() {}

    /// Scans the workspace's source files off the main thread (`text`
    /// gives an open file's current text); a later call replaces one
    /// still running.
    @discardableResult
    public func refresh(root: NavigatorNode, text: @escaping @Sendable (String) -> String? = { _ in nil }) -> Task<Void, Never> {
        scan?.cancel()
        isScanning = true
        let paths = Self.sourceFiles(root)
        let task = Task { [weak self] in
            let found = await Task.detached { () -> [FileSymbols] in
                paths.compactMap { path in
                    let lang = SourceTokenizer.Language(fileName: (path as NSString).lastPathComponent)
                    guard lang.isCode, let source = text(path) ?? (try? String(contentsOfFile: path, encoding: .utf8)) else { return nil }
                    let symbols = SymbolScanner.symbols(in: source, language: lang)
                    return symbols.isEmpty ? nil : FileSymbols(path: path, symbols: symbols)
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            if found != self.files { self.files = found }
            self.isScanning = false
        }
        scan = task
        return task
    }

    /// The source files under `root`, in navigator order.
    static func sourceFiles(_ node: NavigatorNode) -> [String] {
        if node.kind == .file { return node.path.map { [$0] } ?? [] }
        return node.children.flatMap(sourceFiles)
    }

    // MARK: Rows

    /// The rows shown: files, then their declarations; with a filter, only
    /// matches and the declarations that hold them, every file open.
    public var rows: [SymbolNavigatorRow] {
        let filter = filterText.trimmingCharacters(in: .whitespaces)
        var out: [SymbolNavigatorRow] = []
        func matches(_ s: SymbolScanner.Symbol) -> Bool {
            s.name.localizedCaseInsensitiveContains(filter) || s.children.contains(where: matches)
        }
        func add(_ s: SymbolScanner.Symbol, path: String, level: Int, parent: String) {
            guard filter.isEmpty || matches(s) else { return }
            let id = "\(parent)/\(s.name)@\(s.line)"
            let kids = filter.isEmpty ? s.children : s.children.filter(matches)
            let open = !filter.isEmpty || !collapsed.contains(id)
            out.append(SymbolNavigatorRow(id: id, level: level, title: s.name, kind: s.kind, path: path, line: s.line,
                                          isExpandable: !kids.isEmpty, isExpanded: open && !kids.isEmpty))
            if open { for k in kids { add(k, path: path, level: level + 1, parent: id) } }
        }
        var paths = files.map(\.path)
        for p in serverMatches.keys.sorted() where !paths.contains(p) { paths.append(p) }
        for path in paths {
            var symbols = files.first { $0.path == path }?.symbols ?? []
            // The server's matches the scan did not find (same name and line).
            if !filter.isEmpty {
                let flat = Set(DocumentSymbols.flattened(symbols).map { "\($0.symbol.name)@\($0.symbol.line)" })
                symbols += (serverMatches[path] ?? []).filter { !flat.contains("\($0.name)@\($0.line)") }
            }
            guard filter.isEmpty || symbols.contains(where: matches) else { continue }
            let fid = "file:" + path
            let open = !filter.isEmpty || !collapsed.contains(fid)
            out.append(SymbolNavigatorRow(id: fid, level: 0, title: (path as NSString).lastPathComponent, kind: nil, path: path, line: nil,
                                          isExpandable: true, isExpanded: open))
            if open { for s in symbols { add(s, path: path, level: 1, parent: fid) } }
        }
        return out
    }

    public func setExpanded(_ id: String, _ on: Bool) {
        if on { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// The server's matches for the filter, shortly after typing stops.
    private func scheduleServerQuery() {
        query?.cancel()
        let filter = filterText.trimmingCharacters(in: .whitespaces)
        guard filter.count >= 2, let ask = workspaceSymbols else {
            if !serverMatches.isEmpty { serverMatches = [:] }
            return
        }
        query = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await ask(filter)
            guard !Task.isCancelled, let self else { return }
            self.serverMatches = Self.symbolsByFile(found, filter: filter)
        }
    }

    /// Waits for the server's matches (tests, drivers).
    public func serverQuerySettled() async { await query?.value }

    /// `workspace/symbol` results as declarations by file: names that
    /// contain the filter, kinds mapped to the scan's.
    static func symbolsByFile(_ found: [WorkspaceSymbol], filter: String) -> [String: [SymbolScanner.Symbol]] {
        var out: [String: [SymbolScanner.Symbol]] = [:]
        for w in found where w.location.url.isFileURL && w.name.localizedCaseInsensitiveContains(filter) {
            let name = w.name.split(separator: "(").first.map(String.init) ?? w.name
            out[w.location.url.standardizedFileURL.path, default: []].append(SymbolScanner.Symbol(kind: kind(lsp: w.kind), name: name, line: w.location.start.line + 1))
        }
        return out.mapValues { $0.sorted { $0.line < $1.line } }
    }

    /// LSP `SymbolKind` as the scan's kind.
    static func kind(lsp k: Int) -> SymbolScanner.Symbol.Kind {
        switch k {
        case 5: .class
        case 10: .enum
        case 11: .protocol
        case 23: .struct
        case 22: .enumCase
        case 9: .initializer
        case 6, 12, 24, 25: .function
        case 26: .typealias
        default: .property
        }
    }
}

extension WorkspaceShellModel {
    /// View ▸ Navigators ▸ Symbols (⌘3) and the selector: reads the
    /// declarations again (open files as edited) and connects the filter to
    /// the language server.
    public func refreshSymbolNavigator() {
        let language = session.language
        symbols.workspaceSymbols = language.map { l in { q in (try? await l.client.workspaceSymbols(q)) ?? [] } }
        var texts: [String: String] = [:]
        for p in editedPaths { if let t = currentText(of: p) { texts[p] = t } }
        let snapshot = texts
        symbols.refresh(root: session.model.root) { snapshot[$0] }
    }

    /// A Symbol navigator row was chosen: a declaration opens at its line.
    public func openSymbolRow(_ row: SymbolNavigatorRow) {
        symbols.selection = row.id
        guard let line = row.line else { return }
        open(row.path, line: line)
        updateCaretSymbol()
        if isInspectorShown, languageFeatures.inspectorTab == .quickHelp { refreshQuickHelpInspector() }
    }
}
