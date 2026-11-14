import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax

/// Settings ▸ Appearance, as the macOS IDE's (`specs/ide/settings.md`
/// §Appearance, R5.1): a fixed top part (the Appearance card with the three
/// window-on-wallpaper thumbnails, the bordered preview with line numbers
/// and no wrapping, Theme / Fonts / Editor centred between two full-width
/// separators) over a list that scrolls on its own: Theme (a Choose…
/// push button) and Name, then the cards of R7.1 (Foreground and Background
/// sliders, Background Gradient, Customize All Colors, Plain Text and the
/// syntax rows as colour buttons), the theme file's buttons. Built-in themes
/// are read-only.
struct AppearanceSettingsPane: View {
    @State private var segment = 0
    @State private var importing = false
    @State private var exporting = false
    @State private var choosing = false
    @State private var failure: String?
    @Environment(\.colorScheme) private var scheme

    /// The preview's code (Ycode's own sample, the macOS IDE's).
    static let previewCode = """
    /// A greeting, said once.
    struct Greeter {
        let name = "Ycode" // who to greet
        #if DEBUG
        @MainActor func greet(times: Int = 1) { print("Hello, \\(name)") }
        #endif
    }
    """
    static let previewLines = SourceDocument.highlight(previewCode, language: .swift)

    var body: some View {
        let _ = ShellPreferences.shared.revision
        let prefs = Preferences.shared
        let theme = prefs.theme
        let palette = SourcePalette.forAppearance(dark: scheme == .dark, theme: theme)
        let p = SettingsPalette(scheme)
        let L = SettingsAppearanceLayout.self
        let top = SettingsLayout.titleAreaHeight
        VStack(spacing: 0) {
            // The fixed part.
            VStack(alignment: .leading, spacing: 0) {
                AppearanceCard()
                    .padding(.top, L.cardTop - top)
                    .padding(.horizontal, SettingsLayout.cardInset)
                ThemePreview(palette: palette, fontSize: ShellPreferences.fontSize)
                    .padding(.top, L.previewTop - L.cardTop - L.cardHeight)
                    .padding(.horizontal, SettingsLayout.cardInset)
                SettingsPaneSeparator(height: L.separator1Height)
                    .padding(.top, L.separator1Y - L.previewTop - L.previewHeight)
                SettingsSegments(titles: L.segmentTitles, selection: $segment, target: "settings appearance segment")
                    .frame(maxWidth: .infinity)
                    .padding(.top, L.segmentsTop - L.separator1Y - L.separator1Height)
                SettingsPaneSeparator(height: L.separator2Height)
                    .padding(.top, L.separator2Y - L.segmentsTop - L.segmentsSize.height)
            }
            .frame(height: L.listTop - top, alignment: .top)
            // The list, scrolling on its own.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch segment {
                    case 0: themeList(prefs, theme: theme, palette: palette, p)
                    case 1: fontsList(prefs, theme: theme)
                    default:
                        SettingsSection(nil) {
                            PickerRow(title: "Cursor style", selection: .constant("Vertical Bar"), options: [("Vertical Bar", "Vertical Bar")],
                                      target: "settings cursor style")
                        }
                    }
                    if let failure { SettingsNote(text: failure) }
                }
                .padding(.horizontal, SettingsLayout.cardInset)
                .padding(.bottom, SettingsLayout.cardInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .shellTarget("settings appearance list")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(p.detail)
        .fileImporter(isPresented: $importing, allowedContentTypes: ThemeDocument.readableContentTypes) { result in
            guard case .success(let url) = result else { return }
            run { try prefs.importTheme(from: url) }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? ThemeDocument(theme: theme) : nil, contentType: ThemeDocument.themeType,
                      defaultFilename: theme.fileName) { result in
            if case .failure(let e) = result { failure = "Could not export \u{201C}\(theme.name)\u{201D}: \(e.localizedDescription)" }
        }
    }

    /// Theme (Choose…) and Name; the colour rows; the theme file.
    @ViewBuilder
    func themeList(_ prefs: Preferences, theme: EditorTheme, palette: SourcePalette, _ p: SettingsPalette) -> some View {
        let builtIn = EditorTheme.builtIns.contains { $0.name == theme.name }
        let L = SettingsAppearanceLayout.self
        SettingsSection(nil, cardFollows: true) {
            SettingsFixedRow(title: "Theme", height: L.themeRowHeight, raise: SettingsAppearanceR6.themeRowRaise) {
                SettingsPushButton(title: "Choose\u{2026}", target: "settings theme choose") { choosing = true }
                    .popover(isPresented: $choosing) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(prefs.themes.map(\.name), id: \.self) { name in
                                Button { prefs.themeName = name; choosing = false } label: {
                                    HStack(spacing: 6) {
                                        Text(verbatim: name == prefs.themeName ? "\u{2713}" : " ").frame(width: 12)
                                        Text(verbatim: name)
                                    }
                                    .font(SettingsFonts.label)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 3)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .shellTarget("settings theme \(name)")
                            }
                        }
                        .padding(8)
                        .frame(minWidth: 180)
                    }
            }
            SettingsFixedRow(title: "Name", height: L.nameRowHeight) {
                Text(verbatim: theme.name).font(SettingsFonts.label).foregroundStyle(p.label).lineLimit(1).shellTarget("settings theme name")
            }
        }
        // R7.1: [Foreground, Background, Background Gradient] [Customize All
        // Colors] [Plain Text] [the syntax rows], 10 apart; the note last.
        let R = SettingsAppearanceR7.self
        let cards = R.cards(customizeAllColors: R.isOn(.customizeAllColors, in: theme))
        ForEach(Array(cards.dropLast().enumerated()), id: \.offset) { _, card in
            SettingsSection(nil, cardFollows: true) {
                ForEach(card, id: \.title) { row in listRow(row, theme: theme, palette: palette, builtIn: builtIn) }
            }
        }
        SettingsSection(nil, content: {
            ForEach(cards.last ?? [], id: \.title) { row in listRow(row, theme: theme, palette: palette, builtIn: builtIn) }
        }, footer: {
            if builtIn { FootNote(text: "Built-in themes cannot be changed; duplicate one to edit it.") }
        })
        SettingsSection("Theme File") {
            SettingsRow("") {
                HStack(spacing: 8) {
                    SettingsPushButton(title: "Duplicate", target: "settings theme duplicate") { run { try prefs.duplicate(theme) } }
                    SettingsPushButton(title: "Delete", target: "settings theme delete") { prefs.deleteTheme(named: theme.name) }.disabled(builtIn)
                    SettingsPushButton(title: "Import\u{2026}", target: "settings theme import") { importing = true }
                    SettingsPushButton(title: "Export\u{2026}", target: "settings theme export") { exporting = true }
                }
            }
        }
    }

    /// One row of the Theme list after Theme and Name (R7.1): a switch, a
    /// slider row or a colour-only row. A built-in theme's rows and switches
    /// are read-only but drawn in full.
    @ViewBuilder
    func listRow(_ row: SettingsAppearanceR7.Row, theme: EditorTheme, palette: SourcePalette, builtIn: Bool) -> some View {
        let R = SettingsAppearanceR7.self
        switch row {
        case .toggle(let sw):
            SettingsRow(sw.title, kind: .toggle) {
                SettingsSwitch(isOn: Binding(get: { R.isOn(sw, in: theme) }, set: { on in
                    guard !builtIn else { return }
                    Preferences.shared.editSelectedTheme { R.set(sw, on, in: &$0) }
                }), label: sw.title)
                .allowsHitTesting(!builtIn)
                .shellTarget("settings theme switch \(sw.rawValue)")
            }
        case .slider(let title, let key):
            ThemeColorRowView(title: title, key: key, theme: theme, shown: Self.shownColor(key, palette), editable: !builtIn, style: .slider)
                .id("\(theme.name)/\(key)/slider")
        case .color(let title, let key):
            ThemeColorRowView(title: title, key: key, theme: theme, shown: Self.shownColor(key, palette), editable: !builtIn, style: .colorOnly)
                .id("\(theme.name)/\(key)/color")
        }
    }

    /// Font sizes (the editor's, the theme's and the console's).
    @ViewBuilder
    func fontsList(_ prefs: Preferences, theme: EditorTheme) -> some View {
        let builtIn = EditorTheme.builtIns.contains { $0.name == theme.name }
        SettingsSection(nil, content: {
            DoubleStepperRow(title: "Editor font size", value: Binding(get: { ShellPreferences.fontSize }, set: { prefs.sourceFontSize = $0 }),
                             range: Preferences.fontSizeRange, format: { "\(Int($0)) pt" }, target: "settings font size")
            DoubleStepperRow(title: "Theme font size", value: Binding(get: { theme.fontSize }, set: { v in
                prefs.editSelectedTheme { $0.fontSize = v }
            }), range: Preferences.fontSizeRange, format: { "\(Int($0)) pt" }, target: "settings theme font size")
                .disabled(builtIn)
        }, footer: {
            if prefs.sourceFontSize != nil {
                Button("Use the Theme\u{2019}s Size") { prefs.sourceFontSize = nil }.shellTarget("settings font size reset")
            } else {
                FootNote(text: "The editor font size applies to every theme (View \u{25B8} Editor \u{25B8} Font Size changes it too).")
            }
        })
        SettingsSection("Console") {
            DoubleStepperRow(title: "Font size", value: Binding(get: { theme.consoleFontSize }, set: { v in
                prefs.editSelectedTheme { $0.consoleFontSize = v }
            }), range: Preferences.fontSizeRange, format: { "\(Int($0)) pt" }, target: "settings console font size")
                .disabled(builtIn)
        }
    }

    /// Runs a theme operation, showing its failure under the form.
    func run<T>(_ f: () throws -> T) {
        do {
            _ = try f()
            failure = nil
        } catch {
            failure = "The theme could not be saved or read: \(error.localizedDescription)"
        }
    }

    /// The color a row shows: the theme's, else the palette's.
    static func shownColor(_ key: String, _ p: SourcePalette) -> ThemeColor {
        switch key {
        case "foreground": p.foreground
        case "background": p.background
        case "selection": p.selection
        case "currentLine": p.currentLine
        default: SyntaxTokenKind.Role(rawValue: key).map { p.color($0) } ?? p.foreground
        }
    }
}

/// The Appearance card (R5.1): the label at the left; System, Light and
/// Dark as window-on-wallpaper thumbnails right-aligned, the chosen one
/// ringed, its caption bold and dark.
struct AppearanceCard: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let L = SettingsAppearanceLayout.self
        let current = Preferences.shared.appearance
        let m = AppearanceThumbnail.margin
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous).fill(p.card)
            // The label's ink at x 210.5 (10.5 inside the card), cap top 85.5.
            Text(verbatim: "Appearance").font(SettingsFonts.label).foregroundStyle(p.label)
                .padding(.leading, 10.5)
                .padding(.top, L.labelCapTop - L.cardTop - 3)
            HStack(alignment: .top, spacing: L.thumbnailGap - 2 * m) {
                ForEach(Preferences.Appearance.allCases, id: \.self) { a in
                    let on = a == current
                    Button { Preferences.shared.appearance = a } label: {
                        VStack(spacing: 0) {
                            AppearanceThumbnail(appearance: a, chosen: on)
                            // The caption's cap top 10 under the thumbnail (an 11-point
                            // text's cap top is about 2.5 under its frame's top).
                            Text(verbatim: a.rawValue)
                                .font(.system(size: L.captionFontSize, weight: on ? .bold : .regular))
                                .foregroundStyle(on ? p.captionSelected : p.caption)
                                .padding(.top, L.captionCapTop - L.thumbnailTop - L.thumbnailSize.height - m - 2.5)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(a.rawValue)
                    .shellTarget("settings appearance \(a.rawValue.lowercased())")
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, L.thumbnailTrailingInset - m)
            .padding(.top, L.thumbnailTop - L.cardTop - m)
        }
        .frame(height: L.cardHeight)
        .shellTarget("settings appearance card")
    }
}

/// The sample code in a palette (R5.1): a bordered box (1 point, radius 5),
/// line numbers right-aligned ending 28 inside it, the code from 43 inside
/// on an 18-point pitch, not wrapped; the box scrolls both ways.
struct ThemePreview: View {
    var palette: SourcePalette
    var fontSize: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        let L = SettingsAppearanceLayout.self
        let lines = AppearanceSettingsPane.previewLines
        let size = CGFloat(min(fontSize, 16))
        let shape = RoundedRectangle(cornerRadius: L.previewRadius, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            // The numbers, ending 28 inside the box.
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(lines.indices, id: \.self) { i in
                    Text(verbatim: "\(i + 1)").font(ShellFonts.editor(max(9, size - 1))).foregroundStyle(p.lineNumber)
                        .frame(height: L.linePitch)
                }
            }
            .frame(width: L.lineNumberEnd, alignment: .trailing)
            .padding(.top, L.firstLineTop)
            .frame(width: L.codeInset, alignment: .leading)
            ScrollView([.horizontal, .vertical]) {
                // Drawn run by run at character columns (monospaced), as the
                // editor draws: separate texts would lose their spaces.
                Canvas { ctx, _ in
                    let font = ShellFonts.editor(size)
                    let advance = ctx.resolve(Text(verbatim: "MMMMMMMMMM").font(font)).measure(in: CGSize(width: 10_000, height: 100)).width / 10
                    for (i, line) in lines.enumerated() {
                        var column = 0
                        for run in line.runs {
                            let lead = run.text.prefix { $0 == " " }.count
                            let shown = run.text.dropFirst(lead)
                            if !shown.isEmpty {
                                let text = Text(verbatim: String(shown)).font(font).foregroundStyle(palette.color(run.role).color)
                                ctx.draw(text, at: CGPoint(x: CGFloat(column + lead) * advance, y: CGFloat(i) * L.linePitch + L.linePitch / 2),
                                         anchor: .leading)
                            }
                            column += run.text.count
                        }
                    }
                }
                .frame(width: 720, height: CGFloat(lines.count) * L.linePitch)
                .padding(.top, L.firstLineTop)
            }
        }
        .frame(height: L.previewHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { shape.fill(palette.background.color) }
        .clipShape(shape)
        .overlay { shape.stroke(p.previewBorder, lineWidth: 1) }
        .shellTarget("settings theme preview")
    }
}

/// A card row of a given height: the label at the left, the control at the
/// right (10 inside), both centred, or `raise` above the centre (the Theme
/// row's content, 2.25 higher: R6.1).
struct SettingsFixedRow<Control: View>: View {
    var title: String
    var height: CGFloat
    var raise: CGFloat = 0
    @ViewBuilder var control: Control
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = SettingsPalette(scheme)
        HStack(spacing: 12) {
            Text(verbatim: title).font(SettingsFonts.label).foregroundStyle(p.label).lineLimit(1)
            Spacer(minLength: 0)
            control
        }
        .padding(.horizontal, SettingsLayout.labelInset)
        .padding(.bottom, 2 * raise)
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .background(p.card)
    }
}

/// A `.ycodetheme` file for the file dialogs.
struct ThemeDocument: FileDocument {
    static let themeType = UTType(filenameExtension: "ycodetheme", conformingTo: .json) ?? .json
    static var readableContentTypes: [UTType] { [themeType, .json] }
    var theme: EditorTheme

    init(theme: EditorTheme) { self.theme = theme }

    init(configuration: ReadConfiguration) throws {
        theme = try JSONDecoder().decode(EditorTheme.self, from: configuration.file.regularFileContents ?? Data())
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try e.encode(theme))
    }
}
