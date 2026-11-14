import AppKit
import YcodeIDECore

/// Restoring the workspace window on reopen (`workspace-window.md` W7.1,
/// council row 186): the editors of the selected tab (each pane's document,
/// first visible line and selection, the split's direction and
/// proportions, the active pane) and the inspector (shown or hidden, its
/// tab) are kept in the per-workspace user data when the window closes or
/// the app quits, and come back when the workspace opens, whatever the
/// system's window restoration does. The window title follows the active
/// pane. The Linux IDE keeps and reads the same values.
extension WorkspaceWindowController {
    /// Saves the layout when the window closes and when the app quits.
    func observeCloseForRestore() {
        guard let window else { return }
        let center = NotificationCenter.default
        let save: @Sendable (Notification) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.saveWindowLayout() } }
        leftAreaObservation.tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main, using: save))
        leftAreaObservation.tokens.append(center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main, using: save))
    }

    /// The editors of the selected tab as they are now (the assistant,
    /// which follows the focused pane, is not kept).
    public var currentEditorLayout: WorkspaceEditorLayout {
        let t = editorArea.tab
        let editors = t.editors.filter { $0 !== t.assistant }
        let panes = editors.map { e -> WorkspaceEditorLayout.Pane in
            let path = e.fileURL?.path ?? e.auxiliaryFile?.path
            guard e.fileURL != nil else { return .init(path: path) }
            let s = e.textView.selectedRange()
            return .init(path: path, topLine: e.firstVisibleLine, selectionStart: s.location, selectionLength: s.length)
        }
        let vertical = t.split.isVertical
        let sizes = editors.map { e -> Double in
            let f = e.view.frame
            return Double(vertical ? f.width : f.height)
        }
        let focusedEditor = t.focusedEditor
        let focused = editors.firstIndex { $0 === focusedEditor } ?? 0
        return WorkspaceEditorLayout(panes: panes, sideBySide: t.sideBySide, fractions: WorkspaceEditorLayout.fractions(sizes: sizes), focused: focused)
    }

    /// The inspector as it is now.
    public var currentInspectorState: WorkspaceInspectorState {
        WorkspaceInspectorState(isShown: !inspectorItem.isCollapsed, tab: inspector.selectedIndex)
    }

    /// Writes the editors and the inspector into the user data.
    public func saveWindowLayout() {
        let layout = currentEditorLayout, inspectorState = currentInspectorState
        updateUserState {
            $0.editorLayout = layout
            $0.inspector = inspectorState
        }
    }

    /// Brings back the saved editors and inspector (nothing saved: the
    /// window opens as it always did, with nothing selected).
    func restoreWindowLayout() {
        if let saved = userState.inspector {
            inspectorItem.isCollapsed = !saved.isShown
            inspector.select(saved.tab(clampedTo: 3))
        }
        guard let saved = userState.editorLayout else { return }
        let layout = saved.restorable()
        var editors: [SourceEditorController] = []
        for (i, pane) in layout.panes.enumerated() {
            let e = i == 0 ? editorArea.tab.editors[0] : editorArea.split(sideBySide: layout.sideBySide)
            editors.append(e)
            if let p = pane.path {
                // The navigator selects no row on reopen (navigators.md
                // round 7 §4): the file opens in its pane only.
                recordRecentFile(p)
                open(path: p, line: nil, in: e)
            } else if i > 0 {
                showEmptyEditor(e)
            }
        }
        let focused = editors[layout.focused]
        editorArea.focus(focused)
        editorArea.pendingFractions = layout.fractions
        editorArea.view.needsLayout = true
        // Selections and first lines once the panes have their sizes.
        let apply = { [weak self] in
            guard let self else { return }
            self.editorArea.applyPendingFractions()
            for (e, pane) in zip(editors, layout.panes) where e.fileURL != nil {
                let length = (e.textView.string as NSString).length
                e.textView.setSelectedRange(pane.selection(clampedTo: length))
                e.scroll(toTopLine: pane.topLine)
            }
        }
        apply()
        DispatchQueue.main.async(execute: apply)
        // The first lines hold through what comes after the restore (the
        // window's first layout on screen, the language server's first
        // recolouring): a pane put back at its document's top in the
        // first seconds is scrolled to its saved line again (row 202).
        editorArea.restoreBox.guardTopLines(zip(editors, layout.panes).compactMap { e, pane in
            e.fileURL != nil && pane.topLine > 1 ? (e, pane.topLine) : nil
        })
        updateWindowTitle()
        updateToolbarState()
    }

    /// Notes a file in Recent Files without opening it in the focused pane.
    private func recordRecentFile(_ path: String) {
        var recent = navigator.recentFiles
        recent.removeAll { $0 == path }
        navigator.recentFiles = recent + [path]
        updateUserState { $0.noteRecentFile(path) }
    }
}

extension EditorAreaController {
    /// Shares to give the selected tab's panes once it has a size.
    var pendingFractions: [Double]? {
        get { restoreBox.fractions }
        set { restoreBox.fractions = newValue }
    }

    /// Places the selected tab's dividers at the pending shares.
    func applyPendingFractions() {
        guard isViewLoaded, let fractions = pendingFractions else { return }
        let t = tab
        let along = Double(t.split.isVertical ? t.split.bounds.width : t.split.bounds.height)
        guard along > 0, fractions.count == t.editors.count else { return }
        let layout = WorkspaceEditorLayout(panes: t.editors.map { _ in .init(path: nil) }, fractions: fractions)
        for (i, x) in layout.dividerPositions(total: along, divider: Double(t.split.dividerThickness)).enumerated() {
            t.split.setPosition(CGFloat(x), ofDividerAt: i)
        }
        t.split.layoutSubtreeIfNeeded()
        pendingFractions = nil
    }
}

/// The editor area's restore state (an extension cannot add stored properties).
@MainActor
final class EditorAreaRestoreBox {
    var fractions: [Double]?
    /// How long after a restore a pane found back at its top is scrolled to
    /// its saved line again (council round 8, row 202: the left pane
    /// reopened at line 1 in the app, though the restore had scrolled it).
    static let topLineGuard: TimeInterval = 4
    private var guarded: [(editor: WeakEditor, line: Int)] = []
    private var deadline = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    final class WeakEditor {
        weak var editor: SourceEditorController?
        init(_ e: SourceEditorController) { editor = e }
    }

    /// Watches the panes' scroll positions for `topLineGuard` seconds.
    func guardTopLines(_ list: [(SourceEditorController, Int)]) {
        stopGuard()
        guard !list.isEmpty else { return }
        guarded = list.map { (WeakEditor($0.0), $0.1) }
        deadline = Date().addingTimeInterval(Self.topLineGuard)
        for (e, _) in list {
            let clip = e.scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        }
        // The window's first display on screen comes after the restore.
        if let w = list.first?.0.view.window {
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                })
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.topLineGuard + 0.1) { [weak self] in
            MainActor.assumeIsolated { self?.stopGuard() }
        }
    }

    /// A guarded pane at its document's top again goes back to its line
    /// (on the next turn: not from inside the clip view's own change).
    func check() {
        guard Date() < deadline else { return stopGuard() }
        for g in guarded {
            guard let e = g.editor.editor, e.isViewLoaded, e.firstVisibleLine == 1 else { continue }
            let clip = e.scrollView.contentView
            guard clip.bounds.minY <= -e.scrollView.contentInsets.top + 0.5 else { continue }
            let line = g.line
            // The run loop's next pass (it also runs inside a nested run loop).
            RunLoop.main.perform(inModes: [.common]) { [weak e] in
                MainActor.assumeIsolated { e?.scroll(toTopLine: line) }
            }
        }
    }

    func stopGuard() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        guarded = []
        deadline = .distantPast
    }

    /// Whether panes are watched (tests).
    var isGuarding: Bool { !guarded.isEmpty && Date() < deadline }
}

extension SourceEditorController {
    /// The first logical line whose row shows below the bars (1-based).
    public var firstVisibleLine: Int {
        guard isViewLoaded, let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return 1 }
        let clip = scrollView.contentView
        let top = max(0, clip.bounds.minY + scrollView.contentInsets.top - textView.textContainerOrigin.y)
        tlm.ensureLayout(for: NSRect(x: 0, y: 0, width: max(1, textView.bounds.width), height: top + clip.bounds.height))
        guard let frag = tlm.textLayoutFragment(for: NSPoint(x: 1, y: top + 0.5)) else { return 1 }
        let offset = tcm.offset(from: tcm.documentRange.location, to: frag.rangeInElement.location)
        let line = textView.lineIndex.line(at: offset)
        // A row more than half under the bars counts as scrolled past.
        let f = frag.layoutFragmentFrame
        if f.height > 0, f.maxY - top < f.height / 2, line < textView.lineIndex.lineCount { return line + 1 }
        return line
    }

    /// Scrolls so that `line`'s top meets the bars (line 1: the document's top).
    public func scroll(toTopLine line: Int) {
        guard isViewLoaded else { return }
        let clip = scrollView.contentView
        let insets = scrollView.contentInsets
        var y = -insets.top
        if line > 1, let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
           let r = textView.lineIndex.range(ofLine: line),
           let loc = tcm.location(tcm.documentRange.location, offsetBy: r.location) {
            tlm.ensureLayout(for: NSTextRange(location: tcm.documentRange.location, end: loc) ?? tlm.documentRange)
            if let frag = tlm.textLayoutFragment(for: loc) {
                textView.layoutSubtreeIfNeeded()
                let top = frag.layoutFragmentFrame.minY + textView.textContainerOrigin.y
                let maxY = max(-insets.top, textView.frame.height - clip.bounds.height + insets.bottom)
                y = min(top - insets.top, maxY)
            }
        }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
