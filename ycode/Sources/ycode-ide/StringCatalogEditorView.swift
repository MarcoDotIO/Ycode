import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The String Catalog editor (`specs/ide/string-catalog.md` §Editor): the
/// languages at the left (the source language first, then each with its
/// percentage translated, "+" to add one), the table of strings at the
/// right — Key, Default Localization, Comment, the language's translation
/// (not for the source language) and State — with the headers' sort, the
/// filter, Add Key, "−" and Refresh from Source under it.
struct StringCatalogEditorView: View {
    var model: StringCatalogEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            if let p = model.problem { ProblemBanner(message: p) { model.clearProblem() } }
            HStack(spacing: 0) {
                LanguageList(model: model)
                    .frame(width: 210)
                    .background(c.sidebar)
                Hairline(color: c.separator, vertical: true)
                VStack(spacing: 0) {
                    StringTable(model: model)
                    Hairline(color: c.separator)
                    bottomBar(c)
                }
            }
        }
        .background(c.content)
        .shellTarget("string catalog editor")
    }

    func bottomBar(_ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            EditorListBar(removeEnabled: model.selectedKey != nil, remove: { model.removeSelectedKey() }, filter: model.filter,
                          setFilter: { model.setFilter($0) }, target: "strings") {
                PlusButton(help: "Add Key", target: "strings add") { model.addKey() }
            }
            .frame(maxWidth: 380)
            Spacer(minLength: 4)
            if let r = model.refreshText {
                Text(verbatim: r).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    .shellTarget("strings refresh result")
            }
            Text(verbatim: model.countText).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
            Button("Refresh from Source") { model.refreshFromSource() }
                .controlSize(.small)
                .help("Extract the strings of this table from the source code and add the new ones")
                .shellTarget("strings refresh")
        }
        .padding(.trailing, 10)
    }
}

/// The languages: name, "Source" or the percentage, a progress bar.
struct LanguageList: View {
    var model: StringCatalogEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.languages, id: \.self) { code in
                        row(code, c)
                            .contentShape(Rectangle())
                            .onTapGesture { model.select(language: code) }
                            .shellTarget("language \(code)")
                    }
                }
                .padding(.vertical, 6)
            }
            Hairline(color: c.separator)
            HStack(spacing: 6) {
                Menu {
                    ForEach(StringCatalogEditorModel.commonLanguages.filter { !model.languages.contains($0) }, id: \.self) { code in
                        Button("\(StringCatalogEditorModel.displayName(code)) (\(code))") { model.addLanguage(code) }
                    }
                } label: {
                    HStack(spacing: 1) {
                        Image(systemName: "plus").font(.system(size: 12))
                        Image(systemName: "chevron.down").font(.system(size: 7))
                    }
                    .foregroundStyle(c.toolbarIcon)
                    .frame(width: 30, height: 20)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .hidingMenuIndicator()
                .fixedSize()
                .help("Add a language")
                .shellTarget("languages add")
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
        }
        .shellTarget("languages")
    }

    func row(_ code: String, _ c: ShellColors) -> some View {
        let selected = code == model.language
        let isSource = code == model.catalog.sourceLanguage
        let progress = isSource ? 100 : model.catalog.progress(language: code)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "globe").font(.system(size: 11)).foregroundStyle(selected ? c.accent : c.secondaryLabel)
                Text(verbatim: StringCatalogEditorModel.displayName(code)).font(ShellFonts.row).foregroundStyle(c.label).lineLimit(1)
                Spacer(minLength: 4)
                Text(verbatim: model.sidebarDetail(code)).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                    .foregroundStyle(isSource ? c.secondaryLabel : (progress == 100 ? Color.green : c.secondaryLabel))
            }
            if !isSource {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous).fill(c.separator)
                        Capsule(style: .continuous).fill(progress == 100 ? Color.green : c.accent)
                            .frame(width: g.size.width * CGFloat(progress) / 100)
                    }
                }
                .frame(height: 3)
                .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            if selected { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.rowSelection).padding(.horizontal, 6) }
        }
    }
}

/// The table of strings.
struct StringTable: View {
    var model: StringCatalogEditorModel
    @FocusState private var hasKeyboard: Bool
    @Environment(\.colorScheme) private var scheme

    static let stateWidth: CGFloat = 112

    var body: some View {
        let c = ShellColors(scheme)
        let rows = model.rows
        let showTranslation = !model.isSourceLanguage
        // Plural or device variations of the source language, by key.
        let sourceVariations = Dictionary(model.catalog.rows(language: model.catalog.sourceLanguage).map { ($0.key, $0.variations) },
                                          uniquingKeysWith: { a, _ in a })
        GeometryReader { geo in
            let flexible = max(400, geo.size.width - Self.stateWidth)
            let cols: [CGFloat] = showTranslation ? [0.22, 0.26, 0.22, 0.30].map { $0 * flexible } : [0.3, 0.4, 0.3].map { $0 * flexible }
            VStack(spacing: 0) {
                header(cols, showTranslation, c)
                Hairline(color: c.separator)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.key) { pair in
                            StringRowView(model: model, row: pair.element, sourceVariations: sourceVariations[pair.element.key] ?? [],
                                          cols: cols, showTranslation: showTranslation,
                                          selected: model.selectedKey == pair.element.key, striped: pair.offset % 2 == 1, colors: c)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    model.select(key: pair.element.key)
                                    hasKeyboard = true
                                }
                                .contextMenu { menu(pair.element) }
                                .shellTarget("string row \(pair.element.key)")
                        }
                        if rows.isEmpty {
                            Text(verbatim: model.filter.isEmpty ? "No Strings" : "No Matches").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                                .frame(maxWidth: .infinity).padding(.top, 40)
                        }
                    }
                    .padding(.bottom, 10)
                }
                .focusable()
                .focused($hasKeyboard)
                .onKeyPress(.downArrow) { step(rows, 1); return .handled }
                .onKeyPress(.upArrow) { step(rows, -1); return .handled }
                .onKeyPress(.delete) { model.removeSelectedKey(); return .handled }
                .onKeyPress(.deleteForward) { model.removeSelectedKey(); return .handled }
            }
        }
        .shellTarget("strings table")
    }

    @ViewBuilder
    func menu(_ r: StringCatalog.Row) -> some View {
        if !model.isSourceLanguage {
            Button("Mark for Review") { model.setNeedsReview(true, key: r.key) }.disabled(r.state != .translated)
            Button("Mark as Reviewed") { model.setNeedsReview(false, key: r.key) }.disabled(r.state != .needsReview)
            Divider()
        }
        Button("Delete") { model.select(key: r.key); model.removeSelectedKey() }
    }

    func step(_ rows: [StringCatalog.Row], _ d: Int) {
        guard !rows.isEmpty else { return }
        let i = model.selectedKey.flatMap { k in rows.firstIndex { $0.key == k } } ?? (d > 0 ? -1 : rows.count)
        model.select(key: rows[min(max(i + d, 0), rows.count - 1)].key)
    }

    func header(_ cols: [CGFloat], _ showTranslation: Bool, _ c: ShellColors) -> some View {
        HStack(spacing: 0) {
            column(.key, "Key", cols[0], c)
            column(.defaultValue, "Default Localization", cols[1], c)
            column(.comment, "Comment", cols[2], c)
            if showTranslation { column(.translation, "\(StringCatalogEditorModel.displayName(model.language)) (\(model.language))", cols[3], c) }
            SortHeader(title: "State", sorted: sorted(.state)) { model.sort(by: .state) }.frame(width: Self.stateWidth)
        }
        .frame(height: 24)
        .background(c.sidebar)
        .shellTarget("strings header")
    }

    func column(_ col: StringCatalogEditorModel.Column, _ title: String, _ w: CGFloat, _ c: ShellColors) -> some View {
        HStack(spacing: 0) {
            SortHeader(title: title, sorted: sorted(col)) { model.sort(by: col) }
            Hairline(color: c.separator, vertical: true).padding(.vertical, 4)
        }
        .frame(width: w)
    }

    func sorted(_ col: StringCatalogEditorModel.Column) -> Bool? { model.sortColumn == col ? model.sortAscending : nil }
}

struct StringRowView: View {
    var model: StringCatalogEditorModel
    var row: StringCatalog.Row
    var sourceVariations: [String]
    var cols: [CGFloat]
    var showTranslation: Bool
    var selected: Bool
    var striped: Bool
    var colors: ShellColors

    var body: some View {
        let c = colors
        HStack(spacing: 0) {
            text(row.key, c).frame(width: cols[0], alignment: .leading)
            Group {
                if sourceVariations.isEmpty {
                    cell(row.defaultValue, editable: true, c) { model.setDefaultValue($0, key: row.key) }
                } else {
                    text(sourceVariations.joined(separator: "; "), c, secondary: true)
                }
            }
                .frame(width: cols[1], alignment: .leading)
                .shellTarget("string default \(row.key)")
            cell(row.comment, editable: true, placeholder: "Comment", c) { model.setComment($0, key: row.key) }
                .frame(width: cols[2], alignment: .leading)
                .shellTarget("string comment \(row.key)")
            if showTranslation {
                Group {
                    if !row.variations.isEmpty {
                        text(row.variations.joined(separator: "; "), c, secondary: true)
                    } else if row.state == .dontTranslate {
                        text("Don't Translate", c, secondary: true)
                    } else {
                        cell(row.translation, editable: true, placeholder: StringCatalogEditorModel.displayName(model.language), c) {
                            model.setTranslation($0, key: row.key)
                        }
                    }
                }
                .frame(width: cols[3], alignment: .leading)
                .shellTarget("string translation \(row.key)")
            }
            StateBadge(state: row.state, colors: c).frame(width: StringTable.stateWidth, alignment: .leading).padding(.leading, 6)
        }
        .frame(minHeight: 24)
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
    func cell(_ value: String, editable: Bool, placeholder: String = "", _ c: ShellColors, commit: @escaping (String) -> Void) -> some View {
        if selected && editable {
            InlineField(text: value, placeholder: placeholder, commit: commit).padding(.horizontal, 2)
        } else {
            text(value.isEmpty ? placeholder : value, c, secondary: value.isEmpty)
        }
    }

    func text(_ s: String, _ c: ShellColors, secondary: Bool = false) -> some View {
        Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(secondary ? c.tertiaryLabel : c.label)
            .lineLimit(1).padding(.horizontal, 6)
    }
}

/// A row's state: a colored dot and its name.
struct StateBadge: View {
    var state: StringCatalog.State
    var colors: ShellColors

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(verbatim: StringCatalogEditorModel.stateTitle(state)).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                .foregroundStyle(colors.label).lineLimit(1)
        }
    }

    var tint: Color {
        switch state {
        case .translated, .variesByPlural: Color.green
        case .needsReview, .stale: Color.orange
        case .new: colors.error
        case .dontTranslate: colors.tertiaryLabel
        }
    }
}
