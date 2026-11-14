import Foundation
import Observation
import YcodeIDECore

/// File ▸ Open Quickly… (⇧⌘O) on the Linux IDE (`specs/ide/open-quickly.md`;
/// council round 9, row 215): the same candidates, matching and keys as the
/// AppKit `OpenQuicklyController`: typing updates the results (none for an
/// empty query), Up and Down move the selection, Return opens the selected
/// file or symbol at its line, Escape closes. The panel is drawn by
/// `ycode-ide/OpenQuicklyPanel.swift` from `OpenQuicklyLayout`.
@MainActor
@Observable
public final class ShellOpenQuicklyModel {
    public var isShown = false
    public var query = "" { didSet { if query != oldValue { search() } } }
    public private(set) var results: [FuzzyMatch.Candidate] = []
    public private(set) var selectedIndex = 0
    /// Bumped when the panel opens, so the view focuses its field.
    public private(set) var focusCount = 0
    @ObservationIgnored var candidates: [FuzzyMatch.Candidate] = []
    @ObservationIgnored var indexTask: Task<Void, Never>?

    public init() {}

    /// The selected result, if any.
    public var selected: FuzzyMatch.Candidate? { results.indices.contains(selectedIndex) ? results[selectedIndex] : nil }

    /// The panel's height for the results (`OpenQuicklyLayout.height`).
    public var panelHeight: Double { OpenQuicklyLayout.height(results: results.count) }

    /// Opens the panel with an empty query over `root`'s files and
    /// symbols, read off the main thread; the results follow when they arrive.
    public func show(root: NavigatorNode) {
        query = ""
        results = []
        selectedIndex = 0
        isShown = true
        focusCount += 1
        indexTask?.cancel()
        indexTask = Task { [weak self] in
            let fresh = await Task.detached { FuzzyMatch.candidates(in: root) }.value
            guard let self, !Task.isCancelled else { return }
            self.candidates = fresh
            self.search()
            self.indexTask = nil
        }
    }

    /// Waits for the candidates (tests, drivers).
    public func indexIdle() async {
        while let t = indexTask { await t.value }
    }

    public func close() {
        isShown = false
        indexTask?.cancel()
        indexTask = nil
    }

    func search() {
        results = query.trimmingCharacters(in: .whitespaces).isEmpty ? [] : FuzzyMatch.search(query, in: candidates)
        selectedIndex = 0
    }

    /// Up (-1) and Down (+1).
    public func move(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    public func select(_ index: Int) {
        if results.indices.contains(index) { selectedIndex = index }
    }

    /// The glyph colour of the result at `index` when it is a file Ycode
    /// draws with its own glyph (`OpenQuicklyLayout.fileGlyphColor`):
    /// white on the selected row, else the type's tint; nil for a symbol,
    /// a file shown with a system symbol, or a tint that is the accent.
    public func fileGlyphColor(at index: Int) -> GlyphColor? {
        guard results.indices.contains(index), results[index].kind == .file,
              OpenQuicklyLayout.fileGlyph(results[index].title) != nil else { return nil }
        return OpenQuicklyLayout.fileGlyphColor(results[index].title, selected: index == selectedIndex)
    }
}

extension WorkspaceShellModel {
    /// File ▸ Open Quickly…: the panel over the workspace's files and symbols.
    public func showOpenQuickly() {
        openQuickly.show(root: session.model.root)
    }

    /// Return in the panel: opens the selected result (a symbol at its
    /// line) and closes the panel.
    public func openQuicklySelected() {
        guard let c = openQuickly.selected else { return }
        openQuickly.close()
        open(c.path, line: c.line)
    }
}
