import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if os(Linux)
import OVPlatform
#endif

// The Project navigator's file operations in the Linux window (B5-NAVIGATOR:
// P-041 context menus, P-043 rename in place, P-042 drag to move, P-052
// Delete's question and Add Files…). The work is the model's
// (`WorkspaceShellModel+FileOperations.swift`).

// MARK: Context menus (P-041)

/// A project row's context menu: `ProjectRowMenu.entries(for:)` for its
/// kind, acting on the selection when the row is in it, else on the row
/// alone; the row's selection does not change.
struct ProjectRowContextMenu: View {
    var model: WorkspaceShellModel
    var row: OutlineRow

    var body: some View {
        let kind = model.root.find(id: row.id).map { ProjectRowMenu.kind(of: $0.kind) } ?? .file
        ProjectRowMenuItems(model: model, entries: ProjectRowMenu.entries(for: kind), rows: model.rowsForMenu(on: row.id), kind: kind)
    }
}

/// Menu items from `ProjectRowMenu` entries (the context menus and the
/// bottom bar's "+"); commands Ycode cannot do on Linux are disabled.
struct ProjectRowMenuItems: View {
    var model: WorkspaceShellModel
    var entries: [ProjectRowMenu.Entry]
    /// The rows the commands act on (empty: the selection).
    var rows: [String]
    var kind: ProjectRowMenu.RowKind

    var body: some View {
        let project = projectName
        ForEach(Array(entries.enumerated()), id: \.offset) { pair in
            switch pair.element {
            case .command(let c):
                Button(ProjectRowMenu.title(c, projectName: project, kind: kind)) { model.performNavigatorCommand(c, rows: rows) }
                    .disabled(!model.isNavigatorCommandEnabled(c, rows: rows))
            case .separator:
                Divider()
            case .submenu(let title, let kids):
                Menu(title) { AnyView(ProjectRowMenuItems(model: model, entries: kids, rows: rows, kind: kind)) }
            }
        }
    }

    /// Add Files to “<project>”…: the project of the rows (the workspace's
    /// first project without one).
    var projectName: String? {
        if model.containerKind == .package { return model.workspaceName }
        let path = rows.first.flatMap(model.projectPath(ofRow:)) ?? model.session.model.projects.keys.sorted().first
        return path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
    }
}

// MARK: Rename in place (P-043)

/// A row's name edited in place: plain text on the row's band, no border,
/// only as wide as the name (what follows the name stays visible). Return
/// renames, Escape cancels, leaving the field renames.
struct NavigatorRenameField: View {
    var model: WorkspaceShellModel
    var row: OutlineRow
    var colors: ShellColors
    @State private var name: String
    @State private var done = false
    @FocusState private var focused: Bool

    init(model: WorkspaceShellModel, row: OutlineRow, colors: ShellColors) {
        self.model = model
        self.row = row
        self.colors = colors
        _name = State(initialValue: model.root.find(id: row.id)?.name ?? row.title)
    }

    var body: some View {
        TextField("", text: $name)
            .textFieldStyle(.plain)
            .font(ShellFonts.row)
            .foregroundStyle(colors.navigatorLabel)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 24, alignment: .leading)
            .frame(height: CGFloat(WorkspaceChrome.rowHeight))
            .focused($focused)
            .onSubmit { commit() }
            .onKeyPress(.escape) {
                done = true
                model.cancelNavigatorRename()
                return .handled
            }
            .onChange(of: focused) { _, on in if !on { commit() } }
            .task { focused = true }
            .accessibilityLabel("Name")
            .shellTarget("navigator rename field")
    }

    func commit() {
        guard !done, model.navigatorState.renaming == row.id else { return }
        done = true
        model.renameNavigatorRow(row.id, to: name)
    }
}

// MARK: Delete's question, Add Files…, errors (P-052)

/// The Project navigator's alerts and dialogs: Delete's question ("Move to
/// Trash", "Remove References", "Cancel"), Add Files…'s file dialog, an
/// operation's error; and Show in Files through the desktop's file manager.
struct ProjectNavigatorPresentations: ViewModifier {
    var model: WorkspaceShellModel
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        let s = model.navigatorState
        content
            .alert(s.deletePrompt?.title ?? "", isPresented: Binding(get: { s.deletePrompt != nil }, set: { if !$0 { s.deletePrompt = nil } })) {
                ForEach(s.deletePrompt?.buttons ?? [], id: \.self) { title in
                    Button(title, role: title == ShellNavigatorState.DeletePrompt.cancel ? .cancel
                                        : title == ShellNavigatorState.DeletePrompt.moveToTrash ? .destructive : nil) {
                        model.answerDeletePrompt(title)
                    }
                }
            } message: {
                Text(verbatim: s.deletePrompt?.message ?? "")
            }
            .alert("The operation could not be completed.", isPresented: Binding(get: { s.lastError != nil && s.deletePrompt == nil },
                                                                                 set: { if !$0 { s.lastError = nil } })) {
                Button("OK") { s.lastError = nil }
            } message: {
                Text(verbatim: s.lastError ?? "")
            }
            .fileImporter(isPresented: Binding(get: { s.isAddFilesShown }, set: { s.isAddFilesShown = $0 }), allowedContentTypes: [.item, .folder],
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { model.addFilesToNavigator(urls) }
            }
            .fileDialogConfirmationLabel("Add")
            .onAppear {
                s.revealInFiles = { url in DesktopFiles.reveal(url) { openURL($0) } }   // OrganizerWindow.swift
            }
    }
}

// MARK: Drag to move (P-042)

/// Where dragged project rows would go, from the pointer's place over the
/// rows (22-point rows from `WorkspaceChrome.firstRowGap`).
@MainActor
enum ProjectDrag {
    static var gap: CGFloat { CGFloat(WorkspaceChrome.firstRowGap) }
    static var height: CGFloat { CGFloat(WorkspaceChrome.rowHeight) }

    /// The row under a y in the outline's content.
    static func row(at y: CGFloat, rows: [OutlineRow]) -> Int? {
        let i = Int(((y - gap) / height).rounded(.down))
        return rows.indices.contains(i) ? i : nil
    }

    /// The drop target or insertion gap under the pointer. Over a group or
    /// folder's middle the rows go into it; near a row's top or bottom
    /// edge (a file's halves) they go between rows. Never into a dragged
    /// row or one under it.
    static func update(_ drag: ShellNavigatorState.Drag, location: CGPoint, rows: [OutlineRow], model: WorkspaceShellModel) -> ShellNavigatorState.Drag {
        var d = drag
        d.location = location
        d.target = nil
        d.insertAfter = nil
        let y = location.y
        guard !rows.isEmpty else { return d }
        let i = row(at: y, rows: rows) ?? (y < gap ? 0 : rows.count - 1)
        let r = rows[i]
        let frac = (y - gap) / height - CGFloat(i)
        if r.level == 0 {
            d.target = r.id
        } else if r.isExpandable && frac > 0.25 && frac < 0.75 {
            d.target = r.id
        } else if frac < (r.isExpandable ? 0.25 : 0.5) {
            if i > 0 {
                d.insertAfter = rows[i - 1].id
                d.insertLevel = r.level
            } else {
                d.target = r.id
            }
        } else if r.isExpandable && r.isExpanded {
            d.insertAfter = r.id
            d.insertLevel = r.level + 1
        } else {
            d.insertAfter = r.id
            d.insertLevel = r.level
        }
        // Not into itself.
        let dest = destination(d, rows: rows)?.parent
        if let dest, d.rows.contains(where: { id in model.root.ancestry(ofID: dest)?.contains { $0.id == id } == true }) {
            d.target = nil
            d.insertAfter = nil
        }
        return d
    }

    /// The group or folder the rows go into, and where among its children.
    static func destination(_ d: ShellNavigatorState.Drag, rows: [OutlineRow]) -> (parent: String, index: Int?)? {
        if let t = d.target { return (t, nil) }
        guard let after = d.insertAfter, let a = rows.firstIndex(where: { $0.id == after }) else { return nil }
        // The nearest row at or above the gap one level up is the parent.
        var p = a
        while p >= 0, rows[p].level >= d.insertLevel { p -= 1 }
        guard p >= 0 else { return nil }
        let index = rows[(p + 1)...a].filter { $0.level == d.insertLevel }.count
        return (rows[p].id, index)
    }

    /// The drop: `ProjectFileOperations.move` through the model.
    static func drop(_ d: ShellNavigatorState.Drag, rows: [OutlineRow], model: WorkspaceShellModel) {
        guard let dest = destination(d, rows: rows) else { return }
        model.moveNavigatorRows(d.rows, to: dest.parent, at: dest.index)
    }
}

/// The drag's drawing: the source rows keep a grey band (their row view),
/// a group or folder under the pointer is outlined and tinted in the
/// accent colour, a blue insertion line with a small ring marks the gap
/// between rows, and a translucent image of the dragged rows follows the
/// pointer.
struct ProjectDragOverlay: View {
    var model: WorkspaceShellModel
    var drag: ShellNavigatorState.Drag
    var rows: [OutlineRow]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let h = ProjectDrag.height
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let t = drag.target, let i = rows.firstIndex(where: { $0.id == t }) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.accent.opacity(0.18))
                        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(c.accent, lineWidth: 2) }
                        .frame(width: max(0, geo.size.width - 20), height: h)
                        .offset(x: 10, y: ProjectDrag.gap + CGFloat(i) * h)
                        .shellTarget("navigator drop target")
                }
                if let a = drag.insertAfter, let i = rows.firstIndex(where: { $0.id == a }) {
                    let x = CGFloat(WorkspaceChrome.disclosureX) + CGFloat(WorkspaceChrome.indentationPerLevel) * CGFloat(drag.insertLevel) + 13
                    let y = ProjectDrag.gap + CGFloat(i + 1) * h
                    HStack(spacing: 0) {
                        Circle().stroke(c.accent, lineWidth: 2).frame(width: 7, height: 7)
                        Rectangle().fill(c.accent).frame(height: 2)
                    }
                    .frame(width: max(0, geo.size.width - x - 10), height: 7)
                    .offset(x: x - 3.5, y: y - 3.5)
                    .shellTarget("navigator insertion line")
                }
                dragImage(c)
                    .offset(x: drag.location.x + 10, y: drag.location.y - h / 2)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }

    /// The dragged rows' icon and name, translucent.
    func dragImage(_ c: ShellColors) -> some View {
        let first = rows.first { $0.id == drag.rows.first }
        return HStack(spacing: 4) {
            if let first {
                NavigatorRowIconView(row: first, tint: c.tint(first.tint), unfocusedSelection: false)
                    .frame(width: 16, height: ProjectDrag.height)
                Text(verbatim: drag.rows.count > 1 ? "\(first.title) and \(drag.rows.count - 1) more" : first.title)
                    .font(ShellFonts.row).foregroundStyle(c.navigatorLabel)
            }
        }
        .padding(.horizontal, 6)
        .background { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.navigatorBand) }
        .opacity(0.65)
        .fixedSize()
        .shellTarget("navigator drag image")
    }
}

// MARK: Modifier keys of a click

/// The modifier keys held at the last click (⇧-click and Ctrl-click in the
/// Project navigator; P-051). OpenViews keeps them for text surfaces, so
/// the outline connects a disabled one to read them.
@MainActor
final class PointerModifierProbe {
    #if os(Linux)
    var connection: TextSurfaceConnection?
    #endif
    struct Keys: OptionSet {
        let rawValue: Int
        static let shift = Keys(rawValue: 1)
        static let control = Keys(rawValue: 2)
        static let command = Keys(rawValue: 4)
    }

    var current: Keys {
        #if os(Linux)
        guard let m = connection?.pointerModifiers else { return [] }
        var k: Keys = []
        if m.contains(.shift) { k.insert(.shift) }
        if m.contains(.control) { k.insert(.control) }
        if m.contains(.command) { k.insert(.command) }
        return k
        #else
        return []
        #endif
    }
}

#if os(Linux)
extension PointerModifierProbe: TextSurfaceClient {
    func surfaceConnected(_ connection: TextSurfaceConnection?) { self.connection = connection }
    func surfaceInsertText(_ text: String) {}
    func surfaceSetMarkedText(_ text: String, cursor: Int) {}
    func surfaceHandleKey(_ event: KeyEvent) -> Bool { false }
    var surfaceCaretRect: CGRect { .zero }
    func surfaceFocusChanged(_ focused: Bool) {}
    func surfaceCanPerform(_ command: TextSurfaceCommand) -> Bool { false }
    func surfacePerform(_ command: TextSurfaceCommand) {}
}
#endif

/// A zero-size view that connects the probe (never focused).
struct PointerModifierProbeView: View {
    var probe: PointerModifierProbe

    var body: some View {
        #if os(Linux)
        Color.clear.frame(width: 0, height: 0).textSurface(probe, isEnabled: false).allowsHitTesting(false)
        #else
        Color.clear.frame(width: 0, height: 0)
        #endif
    }
}
