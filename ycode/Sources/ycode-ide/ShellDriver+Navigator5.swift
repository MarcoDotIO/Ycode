import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if os(Linux)
import OVPlatform
#endif

// YCODE_IDE_NAVIGATOR5=<prefix>: B5-NAVIGATOR (1.0.0-beta.5) on the Linux
// IDE. Open a project with a group that has a folder ("Nav": main, Model,
// ToolMain, a group "Support"), a synchronized folder ("Shared") and
// README.md (the core's navigator sample); trashed items go to
// <prefix's folder>/nav5-trash, not the desktop's Trash.
//
//   tree             the Project navigator, every group open
//   menu-file        P-041: a file row's context menu (no selection change)
//   menu-project     the project row's (no Delete)
//   new-group        P-052/P-043: New Group in Nav, its name edited in place
//   renamed          typed "Things", Return: the folder and the project follow
//   delete-alert     Delete on README: Move to Trash / Remove References / Cancel
//   multi            P-051: a click, then Shift-click: three rows selected
//   type-select      typing "r" selects README
//   option-right     ⌥→ on Nav: Nav and Support open
//   filter-mod       P-037: "mod" filters, the match bold, the glyph accent
//   filter-none      "zzz": No Filter Results, the inspector No Selection
//   filter-menu      the options menu: recent filters, Clear Recents
//   filter-toggle    the recent-files toggle on
//   scm-empty        P-039: No Git Repositories (the scratch is not in git)
//   scm-more / tests-more / project-plus / find-scope
//                    P-040: the action menus, the "+" menu, "In Workspace"
//   add-files        Add Files…'s file dialog
//   drag-into / drag-insert
//                    P-042: a group under the pointer, the insertion line
//   drop / drop-undo P-042: the moved file open with the editor focused;
//                    Ctrl+Z after it changes nothing
//   timing           P-199: click → file shown, per file
//
// Each state writes <prefix>-<state>.png and prints a "nav5 …" line.
extension ShellDriver {
    #if os(Linux)
    static func navigator5Walk(_ app: ShellAppModel, prefix: String) async {
        guard let w = app.workspace else { say("nav5: no workspace"); return }
        let trash = URL(fileURLWithPath: prefix).deletingLastPathComponent().appendingPathComponent("nav5-trash")
        w.navigatorState.trashBin = .folder(trash)
        w.navigatorState.revealInFiles = { say("nav5 reveal \($0.lastPathComponent)") }
        func shot(_ state: String, popups: Bool = false, settle: Double = 0.5) async {
            await pause(settle)
            let path = "\(prefix)-\(state).png"
            say("nav5 \(state): " + (popups ? OpenViewsAutomation.screenshotWithPopups(to: path) : OpenViewsAutomation.screenshot(to: path)))
        }
        func frame(_ name: String) -> CGRect? {
            let all = OpenViewsAutomation.identifiedFrames()
            return all[name] ?? all[name.replacingOccurrences(of: " ", with: "_")]
        }
        func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
        func row(_ name: String) -> OutlineRow? { w.filteredProjectRows.first { $0.level > 0 && ($0.title == name || $0.title + ".swift" == name) } }
        // A row's frame: from the first row's, by its place (titles repeat: the project and its group "Nav").
        func rowFrame(_ r: OutlineRow) -> CGRect? {
            let rows = w.filteredProjectRows
            guard let first = rows.first, let f = frame("row \(first.title)"), let i = rows.firstIndex(where: { $0.id == r.id }) else { return nil }
            return f.offsetBy(dx: 0, dy: CGFloat(i) * CGFloat(WorkspaceChrome.rowHeight))
        }
        func click(_ name: String, button: Int = 1, modifiers: KeyModifiers = []) async {
            guard let r = row(name), let f = rowFrame(r) else { say("nav5: no row \(name)"); return }
            await OpenViewsAutomation.click(at: CGPoint(x: f.minX + 60, y: f.midY), button: button, modifiers: modifiers)
            await pause(0.25)
        }
        func popupTexts() -> [String] { OpenViewsAutomation.texts().filter(\.inPopup).map(\.text) }
        func clickText(_ t: String, popup: Bool? = nil) async -> Bool {
            guard let item = OpenViewsAutomation.texts().last(where: { $0.text == t && (popup == nil || $0.inPopup == popup!) }) else { return false }
            await OpenViewsAutomation.click(at: center(item.frame))
            await pause(0.3)
            return true
        }
        let pbx = w.session.model.url.appendingPathComponent("project.pbxproj")
        func pbxproj() -> String { (try? String(contentsOf: pbx, encoding: .utf8)) ?? "" }
        let base = pbxproj()

        w.navigator = .project
        for r in w.projectRows where r.isExpandable { w.setExpanded(r.id, true) }
        for r in w.projectRows where r.isExpandable { w.setExpanded(r.id, true) }
        await shot("tree", settle: 1.0)
        say("nav5 rows: \(w.projectRows.map { "\(String(repeating: " ", count: $0.level))\($0.title)" })")

        // P-041: context menus.
        await click("main")
        let before = w.projectSelection
        await click("Model", button: 3)
        await shot("menu-file", popups: true)
        let fileMenu = popupTexts()
        say("nav5 menu file: \(fileMenu) selection unchanged=\(w.projectSelection == before)")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)
        if let first = w.filteredProjectRows.first, let f = rowFrame(first) {
            await OpenViewsAutomation.click(at: CGPoint(x: f.minX + 60, y: f.midY), button: 3)
        }
        await shot("menu-project", popups: true)
        let projectMenu = popupTexts()
        say("nav5 menu project: \(projectMenu) delete=\(projectMenu.contains("Delete"))")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)

        // P-052, P-043: New Group, renamed in place.
        await pause(0.3)
        await click("Nav")
        say("nav5 selected for New Group: \(w.projectSelection.flatMap { w.root.find(id: $0) }.map { "\($0.name) (\($0.kind))" } ?? "-")")
        let added = w.performProjectNavigatorAction("newGroup:")
        await shot("new-group", settle: 0.8)
        say("nav5 new group: \(added) renaming=\(w.navigatorState.renaming.flatMap { w.root.find(id: $0)?.name } ?? "-") "
            + "open=\(w.navigatorState.renaming.map { w.expanded.contains($0) } ?? false) field=\(frame("navigator rename field").map { "\($0)" } ?? "-")")
        // The field took the keyboard with its name selected: typing replaces it.
        OpenViewsAutomation.type("Things")
        OpenViewsAutomation.press(.return)
        await shot("renamed", settle: 0.8)
        let dir = w.session.model.url.deletingLastPathComponent()
        say("nav5 renamed: folder=\(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Nav/Things").path)) "
            + "project=\(pbxproj().contains("path = Things;")) undo=\(w.navigatorUndoTitle ?? "-")")
        // Ctrl+Z in the navigator undoes the rename, then the group.
        await click("Things")
        OpenViewsAutomation.press(.character("z"), modifiers: [.control])
        await pause(0.3)
        OpenViewsAutomation.press(.character("z"), modifiers: [.control])
        await pause(0.3)
        say("nav5 undo: back to the original file=\(pbxproj() == base) folder gone=\(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Nav/New Group").path)) redo=\(w.navigatorRedoTitle ?? "-")")

        // Delete's question.
        await click("README")
        OpenViewsAutomation.press(.backspace)
        await shot("delete-alert", popups: true)
        say("nav5 delete: prompt=\(w.navigatorState.deletePrompt.map { "\($0.title) \($0.buttons)" } ?? "-")")
        let removed = await clickText("Remove References", popup: nil)
        await pause(0.3)
        say("nav5 delete: clicked=\(removed) reference gone=\(!pbxproj().contains("README.md")) file kept=\(FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))")
        if w.navigatorState.deletePrompt != nil { w.answerDeletePrompt("Remove References") }
        w.undoNavigatorEdit()
        say("nav5 delete undone: \(pbxproj() == base)")

        // P-051: multiple selection, type-select, ⌥→.
        await click("main")
        await click("ToolMain", modifiers: [.shift])
        await shot("multi")
        say("nav5 multi: \(w.selectedProjectRowIDs.compactMap { w.root.find(id: $0)?.name })")
        OpenViewsAutomation.press(.character("r"))
        await shot("type-select")
        say("nav5 type-select r: \(w.projectSelection.flatMap { w.root.find(id: $0)?.name } ?? "-")")
        if let nav = row("Nav"), let support = row("Support") {
            w.setExpanded(support.id, false)
            w.setExpanded(nav.id, false)
            await click("Nav")
            OpenViewsAutomation.press(.rightArrow, modifiers: [.option])
            await shot("option-right")
            say("nav5 option-right: Nav open=\(w.expanded.contains(nav.id)) Support open=\(w.expanded.contains(support.id))")
        }

        // P-037: the filter.
        if let f = frame("navigator filter") {
            await OpenViewsAutomation.click(at: center(f))
            OpenViewsAutomation.type("mod")
            let typed = Date()
            while w.appliedFilter(0) != "mod", Date().timeIntervalSince(typed) < 1 { await pause(0.005) }
            if let k = w.navigatorState.lastFilterKeyAt, let a = w.navigatorState.lastFilterAppliedAt {
                say(String(format: "nav5 filter: the rows follow %.0f ms after the last key", a.timeIntervalSince(k) * 1000))
            }
            await shot("filter-mod")
            say("nav5 filter mod: rows=\(w.filteredProjectRows.map { "\($0.title)\($0.filterMatch.map { "[\($0.match)]" } ?? "")\($0.isFilterContext ? "(dim)" : "")" }) "
                + "active=\(w.isFilterActive(0))")
            for _ in 0..<3 { OpenViewsAutomation.press(.backspace) }
            OpenViewsAutomation.type("zzz")
            await pause(0.3)
            await shot("filter-none")
            say("nav5 filter zzz: noResults=\(w.navigatorFilterLeavesNoRows) texts=\(OpenViewsAutomation.texts().map(\.text).filter { $0 == "No Filter Results" || $0 == "No Selection" })")
            OpenViewsAutomation.press(.return)
            await pause(0.2)
            await OpenViewsAutomation.click(at: center(f))
            for _ in 0..<3 { OpenViewsAutomation.press(.backspace) }
            OpenViewsAutomation.type("help")
            await pause(0.2)
            OpenViewsAutomation.press(.return)
            await pause(0.2)
            if let o = frame("navigator filter options") {
                await OpenViewsAutomation.click(at: center(o))
                await shot("filter-menu", popups: true)
                let menu = OpenViewsAutomation.texts().filter(\.inPopup)
                say("nav5 filter menu: \(menu.map(\.text)) top=\(menu.map(\.frame.minY).min() ?? -1) glyph=\(o.minY)")
                OpenViewsAutomation.press(.escape)
                await pause(0.2)
            }
            w.setFilterText("", navigator: 0)
            await pause(0.2)
        }
        if let t = frame("navigator toggle 0") {
            await OpenViewsAutomation.click(at: center(t))
            await shot("filter-toggle")
            say("nav5 toggle recent: rows=\(w.filteredProjectRows.filter(\.opens).map(\.title))")
            await OpenViewsAutomation.click(at: center(t))
        }

        // P-039, P-040: empty states and bottom bars.
        w.perform(.showSourceControlNavigator)
        await shot("scm-empty", settle: 1.2)
        say("nav5 scm: \(OpenViewsAutomation.texts().map(\.text).filter { $0.hasPrefix("No ") })")
        if let plus = frame("navigator add") {
            await OpenViewsAutomation.click(at: center(plus))
            await shot("scm-more", popups: true)
            say("nav5 scm more: \(popupTexts())")
            OpenViewsAutomation.press(.escape)
        }
        w.perform(.showTestNavigator)
        await pause(0.8)
        if let plus = frame("navigator add") {
            await OpenViewsAutomation.click(at: center(plus))
            await shot("tests-more", popups: true)
            say("nav5 tests more: \(popupTexts())")
            OpenViewsAutomation.press(.escape)
        }
        w.perform(.showIssueNavigator)
        await shot("issues-empty")
        w.perform(.showFindNavigator)
        await shot("find-scope")
        say("nav5 find scope: \(OpenViewsAutomation.texts().map(\.text).filter { $0.hasPrefix("In ") })")
        w.perform(.showProjectNavigator)
        await pause(0.4)
        if let plus = frame("navigator add") {
            await OpenViewsAutomation.click(at: center(plus))
            await shot("project-plus", popups: true)
            say("nav5 project +: \(popupTexts())")
            OpenViewsAutomation.press(.escape)
            await pause(0.2)
        }

        // Add Files…: the file dialog (Escape cancels).
        w.showAddFiles()
        await shot("add-files", popups: true, settle: 0.8)
        say("nav5 add files: shown=\(w.navigatorState.isAddFilesShown)")
        OpenViewsAutomation.press(.escape)
        await pause(0.3)

        // P-042: drag to move (the overlay from the drag state; the move).
        let rows = w.filteredProjectRows
        if let helpers = rows.first(where: { $0.title.hasPrefix("Helpers") }), let navIndex = rows.firstIndex(where: { $0.title == "Nav" && $0.level > 0 }) {
            let gap = CGFloat(WorkspaceChrome.firstRowGap), h = CGFloat(WorkspaceChrome.rowHeight)
            var d = ShellNavigatorState.Drag(rows: [helpers.id], location: .zero)
            d = ProjectDrag.update(d, location: CGPoint(x: 120, y: gap + (CGFloat(navIndex) + 0.5) * h), rows: rows, model: w)
            w.navigatorState.drag = d
            await shot("drag-into")
            say("nav5 drag into: target=\(d.target.flatMap { w.root.find(id: $0)?.name } ?? "-")")
            if let readme = rows.firstIndex(where: { $0.title.hasPrefix("README") }) {
                d = ProjectDrag.update(d, location: CGPoint(x: 120, y: gap + (CGFloat(readme) + 0.1) * h), rows: rows, model: w)
                w.navigatorState.drag = d
                await shot("drag-insert")
                say("nav5 drag insert: after=\(d.insertAfter.flatMap { w.root.find(id: $0)?.name } ?? "-") level=\(d.insertLevel) "
                    + "dest=\(ProjectDrag.destination(d, rows: rows).map { "\(w.root.find(id: $0.parent)?.name ?? "?") @\($0.index.map(String.init) ?? "end")" } ?? "-")")
                w.navigatorState.drag = nil
                ProjectDrag.drop(d, rows: rows, model: w)
                await pause(0.3)
                // P-042 (B5-FIX-NAV): the moved file opens with the editor
                // focused; Ctrl+Z leaves the move in place.
                await shot("drop")
                say("nav5 drop: undo=\(w.navigatorUndoTitle ?? "-") open=\(w.document?.name ?? "-") \(w.navigatorState.lastError ?? "")")
                let moved = pbxproj()
                w.undoNavigatorEdit()
                await shot("drop-undo")
                say("nav5 drop after undo: kept=\(pbxproj() == moved) base=\(pbxproj() == base)")
            }
        }

        // P-199: the model's selection → file shown (as motion8 measures
        // w.open): the call, then the first frame presented after it.
        MainThreadSampler.startIfAsked()   // YCODE_IDE_SAMPLE=<file>: where the frames' time goes
        defer { MainThreadSampler.stop() }
        for name in ["Model", "main", "Support", "ToolMain", "Model", "Support", "main", "ToolMain"] {
            guard let r = row(name), let p = w.root.find(id: r.id)?.path else { continue }
            let frames0 = OpenViewsAutomation.presentedFrames()
            OpenViewsAutomation.frameDurations = []
            let start = Date()
            w.clickProjectRow(r.id, rows: w.filteredProjectRows)
            let call = Date().timeIntervalSince(start) * 1000
            while OpenViewsAutomation.presentedFrames() == frames0, Date().timeIntervalSince(start) < 2 { await pause(0.001) }
            let first = Date().timeIntervalSince(start) * 1000
            say(String(format: "nav5 select %@: call %.1f ms (shown=%@), first frame after %.1f ms; frame work %@ ms", name, call,
                       r.opens ? (w.document?.path == p ? "yes" : "no") : "a group", first,
                       (OpenViewsAutomation.frameDurations ?? []).prefix(4).map { String(format: "%.1f", $0 * 1000) }.joined(separator: ", ")))
            await pause(0.6)
        }
        // P-199: click → file shown.
        for name in ["Model", "main", "ToolMain", "Model"] {
            guard let r = row(name), let f = rowFrame(r), let p = w.root.find(id: r.id)?.path else { say("nav5 timing: no row \(name)"); continue }
            let frames0 = OpenViewsAutomation.presentedFrames()
            OpenViewsAutomation.frameDurations = []
            let start = Date()
            await OpenViewsAutomation.click(at: CGPoint(x: f.minX + 60, y: f.midY))
            while w.document?.path != p, Date().timeIntervalSince(start) < 2 { await pause(0.001) }
            // From the release (the tap), not the press 50 ms before it.
            let tap = w.navigatorState.lastSelectStarted ?? start
            let shown = Date().timeIntervalSince(tap) * 1000
            while OpenViewsAutomation.presentedFrames() == frames0, Date().timeIntervalSince(start) < 2 { await pause(0.001) }
            let first = Date().timeIntervalSince(tap) * 1000
            say(String(format: "nav5 timing %@: shown in the model %.1f ms after the tap (selection and open: %.1f ms of work), "
                       + "first frame %.1f ms after the tap (its work %.1f ms)",
                       name, shown, (w.navigatorState.lastSelectModelTime ?? 0) * 1000, first, (OpenViewsAutomation.frameDurations?.first ?? 0) * 1000))
            await pause(0.5)
        }
        OpenViewsAutomation.frameDurations = nil
        await shot("timing")
    }
    #endif
}
