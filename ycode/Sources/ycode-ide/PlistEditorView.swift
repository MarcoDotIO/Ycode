import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The property list editor (`specs/ide/plist-editor.md`): Key | Type |
/// Value columns over the outline (Root first), the headers sort the view;
/// a click selects a row and its cells become editable; the selected row
/// has + and − beside its key; Alt+Up / Alt+Down (and the row's context
/// menu) move it among its siblings. Up and Down move the selection, Right
/// and Left open and close, Delete removes.
struct PlistEditorView: View {
    var model: PlistEditorModel
    @FocusState private var hasKeyboard: Bool
    @Environment(\.colorScheme) private var scheme

    static let rowHeight: CGFloat = 22
    static let typeWidth: CGFloat = 110

    var body: some View {
        let c = ShellColors(scheme)
        let rows = model.rows
        GeometryReader { geo in
            let keyWidth = max(180, (geo.size.width - Self.typeWidth) * 0.42)
            VStack(spacing: 0) {
                if let p = model.problem { ProblemBanner(message: p) { model.clearProblem() } }
                header(keyWidth: keyWidth, c)
                Hairline(color: c.separator)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { pair in
                            PlistRowView(model: model, row: pair.element, keyWidth: keyWidth, striped: pair.offset % 2 == 1,
                                         selected: model.selection == pair.element.path, colors: c)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.selection = pair.element.path
                                    hasKeyboard = true
                                }
                                .contextMenu { rowMenu(pair.element) }
                                .shellTarget("plist row \(pair.element.key)")
                        }
                    }
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.automatic)
                .focusable()
                .focused($hasKeyboard)
                .onKeyPress(keys: [.downArrow, .upArrow]) { press in
                    let d = press.key == .downArrow ? 1 : -1
                    // Alt+Up / Alt+Down move the item among its siblings.
                    if press.modifiers.contains(.option) { model.moveSelected(by: d) } else { move(rows, d) }
                    return .handled
                }
                .onKeyPress(.rightArrow) { open(true); return .handled }
                .onKeyPress(.leftArrow) { open(false); return .handled }
                .onKeyPress(.delete) { model.removeSelected(); return .handled }
                .onKeyPress(.deleteForward) { model.removeSelected(); return .handled }
            }
        }
        .background(c.content)
        .shellTarget("plist editor")
    }

    func header(keyWidth: CGFloat, _ c: ShellColors) -> some View {
        HStack(spacing: 0) {
            SortHeader(title: "Key", sorted: sorted(.key)) { model.sort(by: .key) }
                .frame(width: keyWidth)
            Hairline(color: c.separator, vertical: true).padding(.vertical, 4)
            SortHeader(title: "Type", sorted: sorted(.type)) { model.sort(by: .type) }
                .frame(width: Self.typeWidth)
            Hairline(color: c.separator, vertical: true).padding(.vertical, 4)
            SortHeader(title: "Value", sorted: sorted(.value)) { model.sort(by: .value) }
                .frame(maxWidth: .infinity)
        }
        .frame(height: 24)
        .background(c.sidebar)
        .shellTarget("plist header")
    }

    @ViewBuilder
    func rowMenu(_ r: PlistEditorModel.Row) -> some View {
        Button("Add Item") { model.selection = r.path; model.addItem() }
        Button("Delete") { model.selection = r.path; model.removeSelected() }.disabled(r.path.isEmpty)
        Divider()
        Button("Move Up") { model.selection = r.path; model.moveSelected(by: -1) }.disabled(r.path.isEmpty || r.path.last == 0)
        Button("Move Down") { model.selection = r.path; model.moveSelected(by: 1) }.disabled(r.path.isEmpty)
        Divider()
        Menu("Value Type") {
            ForEach(PlistTree.types, id: \.self) { t in Button(t) { model.selection = r.path; model.setType(t, at: r.path) } }
        }
        Divider()
        Button(model.showsRawKeys ? "Show Readable Keys" : "Show Raw Keys and Values") { model.showsRawKeys.toggle() }
    }

    func sorted(_ col: PlistTree.SortColumn) -> Bool? { model.sortColumn == col ? model.sortAscending : nil }

    func move(_ rows: [PlistEditorModel.Row], _ d: Int) {
        guard !rows.isEmpty else { return }
        let i = model.selection.flatMap { s in rows.firstIndex { $0.path == s } } ?? (d > 0 ? -1 : rows.count)
        model.selection = rows[min(max(i + d, 0), rows.count - 1)].path
    }

    func open(_ on: Bool) {
        guard let s = model.selection else { return }
        if !on, !model.isExpanded(s) || s.isEmpty, !s.isEmpty {
            model.selection = Array(s.dropLast())
            return
        }
        guard let r = model.rows.first(where: { $0.path == s }), r.isContainer, !s.isEmpty || !on else { return }
        if !s.isEmpty { model.setExpanded(s, on) }
    }
}

/// One row: disclosure and key, type pop-up, value. The selected row's key
/// and value are fields; other rows show text.
struct PlistRowView: View {
    var model: PlistEditorModel
    var row: PlistEditorModel.Row
    var keyWidth: CGFloat
    var striped: Bool
    var selected: Bool
    var colors: ShellColors

    var body: some View {
        let c = colors
        HStack(spacing: 0) {
            keyCell(c).frame(width: keyWidth, alignment: .leading)
            CellPopUp(title: row.type, choices: ["Array", "Dictionary", "-", "Boolean", "Data", "Date", "Number", "String"]) { t in
                model.selection = row.path
                model.setType(t, at: row.path)
            }
            .padding(.horizontal, 6)
            .frame(width: PlistEditorView.typeWidth, alignment: .leading)
            .shellTarget("plist type \(row.key)")
            valueCell(c).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .frame(height: PlistEditorView.rowHeight)
        .background {
            if selected {
                c.accent.opacity(c.dark ? 0.35 : 0.18)
            } else if striped {
                c.sidebar
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    func keyCell(_ c: ShellColors) -> some View {
        HStack(spacing: 2) {
            Group {
                if row.hasChildren && !row.path.isEmpty {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(c.chevron)
                        .frame(width: 14, height: PlistEditorView.rowHeight)
                        .contentShape(Rectangle())
                        .onTapGesture { model.setExpanded(row.path, !row.isExpanded) }
                } else {
                    Color.clear.frame(width: 14, height: PlistEditorView.rowHeight)
                }
            }
            .padding(.leading, 6 + CGFloat(row.depth) * 14)
            if selected && row.isKeyEditable {
                InlineField(text: row.key) { model.setKey($0, at: row.path) }
                    .shellTarget("plist key field")
            } else {
                Text(verbatim: row.key)
                    .font(row.path.isEmpty ? ShellFonts.smallBold : ShellFonts.small).tracking(ShellFonts.smallTracking)
                    .foregroundStyle(row.rawKey == nil && !row.path.isEmpty ? c.secondaryLabel : c.label)
                    .lineLimit(1)
                    .help(row.rawKey.map { $0 == row.key ? "" : $0 } ?? "")
            }
            Spacer(minLength: 2)
            if selected {
                // Add an item here; remove this one (not the root).
                rowButton("plus.circle", "Add Item", c) { model.addItem() }
                    .shellTarget("plist add")
                if !row.path.isEmpty {
                    rowButton("minus.circle", "Delete", c) { model.removeSelected() }
                        .shellTarget("plist remove")
                }
            }
        }
        .padding(.trailing, 4)
    }

    func rowButton(_ symbol: String, _ help: String, _ c: ShellColors, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                .frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    func valueCell(_ c: ShellColors) -> some View {
        if row.isContainer {
            Text(verbatim: row.value).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                .padding(.horizontal, 6)
        } else if row.type == "Boolean" {
            CellPopUp(title: row.value, choices: ["YES", "NO"]) { v in model.setValueText(v, at: row.path) }
                .padding(.horizontal, 6)
                .shellTarget("plist bool \(row.key)")
        } else if selected {
            InlineField(text: row.value) { model.setValueText($0, at: row.path) }
                .shellTarget("plist value field")
        } else {
            Text(verbatim: row.value).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
                .padding(.horizontal, 6)
        }
    }
}
