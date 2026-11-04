import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// Pieces the property list, asset catalog and String Catalog editors share:
// the editor for the open file's type, column headers that sort, a cell
// that edits in place, the problem banner, small pop-ups.

/// The structured editor for the open file (`StructuredEditors.swift`).
struct StructuredEditorView: View {
    var model: WorkspaceShellModel
    var editor: StructuredEditor

    var body: some View {
        switch editor {
        case .propertyList(let m): PlistEditorView(model: m)
        case .assetCatalog(let m): AssetCatalogEditorView(model: m)
        case .stringCatalog(let m): StringCatalogEditorView(model: m)
        }
    }
}

/// The jump bar's Open As switch for files with a structured editor and a
/// text form: the structured editor's icon, then the source code's; the
/// shown one is on.
struct OpenAsSwitch: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let source = model.isShowingSourceView
        let title = model.document.flatMap { StructuredEditor.open($0.path)?.title } ?? "Structured"
        HStack(spacing: 2) {
            button("list.bullet.rectangle", "Open As \(title)", on: !source, c) { model.setShowsSourceView(false) }
                .shellTarget("open as structured")
            button("chevron.left.forwardslash.chevron.right", "Open As Source Code", on: source, c) { model.setShowsSourceView(true) }
                .shellTarget("open as source")
        }
        .padding(.horizontal, 2)
        .frame(height: 22)
        .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
    }

    func button(_ symbol: String, _ help: String, on: Bool, _ c: ShellColors, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(on ? c.accent : c.secondaryLabel)
                .frame(width: 24, height: 18)
                .background { if on { Capsule(style: .continuous).fill(c.selectorPill) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A column header: its title, and the sort arrow when it sorts the view.
struct SortHeader: View {
    var title: String
    var sorted: Bool?
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Button(action: action) {
            HStack(spacing: 4) {
                Text(verbatim: title).font(ShellFonts.small.weight(.semibold)).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
                    .lineLimit(1)
                if let up = sorted {
                    Image(systemName: up ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(c.secondaryLabel)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Sort by \(title)")
    }
}

/// A one-line text cell that edits in place: Return or leaving the field
/// commits, Escape gives the edit up.
struct InlineField: View {
    var text: String
    var placeholder = ""
    var font: Font = ShellFonts.small
    var commit: (String) -> Void
    @State private var draft: String
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    init(text: String, placeholder: String = "", font: Font = ShellFonts.small, commit: @escaping (String) -> Void) {
        self.text = text
        self.placeholder = placeholder
        self.font = font
        self.commit = commit
        _draft = State(initialValue: text)
    }

    var body: some View {
        let c = ShellColors(scheme)
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(c.label)
            .focused($focused)
            .onSubmit { if draft != text { commit(draft) } }
            .onChange(of: focused) { was, now in if was && !now && draft != text { commit(draft) } }
            .onChange(of: text) { _, new in draft = new }
            .onKeyPress(.escape) {
                draft = text
                focused = false
                return .handled
            }
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(c.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(focused ? c.accent : c.fieldStroke, lineWidth: 1) }
            }
    }
}

/// A yellow strip at the editor's top saying why the last edit failed.
struct ProblemBanner: View {
    var message: String
    var dismiss: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(c.warning)
            Text(verbatim: message).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(2)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(c.secondaryLabel)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(c.warning.opacity(c.dark ? 0.18 : 0.14))
        .shellTarget("editor problem")
    }
}

/// A borderless pop-up for table cells: the value and the up/down chevrons.
struct CellPopUp: View {
    var title: String
    var choices: [String]
    var choose: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Menu {
            ForEach(choices, id: \.self) { choice in
                if choice == "-" { Divider() } else { Button(choice) { choose(choice) } }
            }
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: title).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(c.secondaryLabel)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .hidingMenuIndicator()
        .fixedSize()
    }
}

/// The bottom bar of an editor's list: a "+" (button or pull-down), "−",
/// and a filter field (`navigators.md` bars, at the editor's scale).
struct EditorListBar<Add: View>: View {
    var removeEnabled: Bool
    var remove: () -> Void
    var filter: String?
    var setFilter: ((String) -> Void)?
    var target: String
    @ViewBuilder var add: () -> Add
    @State private var text = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 6) {
            add()
            Button(action: remove) {
                Image(systemName: "minus").font(.system(size: 12)).foregroundStyle(c.toolbarIcon).opacity(removeEnabled ? 1 : 0.35)
                    .frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!removeEnabled)
            .help("Remove")
            .shellTarget("\(target) remove")
            if let setFilter {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(c.tertiaryLabel)
                    TextField("Filter", text: $text)
                        .textFieldStyle(.plain)
                        .font(ShellFonts.small)
                        .onChange(of: text) { _, v in setFilter(v) }
                        .shellTarget("\(target) filter")
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                .onAppear { text = filter ?? "" }
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

/// The "+" of a list bar as a plain button.
struct PlusButton: View {
    var help: String
    var target: String
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Button(action: action) {
            Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(c.toolbarIcon)
                .frame(width: 22, height: 20).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .shellTarget(target)
    }
}

extension View {
    /// No pull-down arrow beside a menu's label (OpenViews draws none for
    /// a borderless menu).
    @ViewBuilder
    func hidingMenuIndicator() -> some View {
        #if os(Linux)
        self
        #else
        menuIndicator(.hidden)
        #endif
    }
}
