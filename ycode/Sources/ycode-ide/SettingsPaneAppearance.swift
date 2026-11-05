import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax

/// Settings ▸ Appearance: System, Light or Dark; the editor theme with a
/// live preview; the selected user theme's colors and font sizes;
/// Duplicate, Delete, Import… and Export… (`specs/ide/settings.md`
/// §Appearance). Built-in themes are read-only.
struct AppearanceSettingsPane: View {
    @State private var importing = false
    @State private var exporting = false
    @State private var failure: String?
    @Environment(\.colorScheme) private var scheme

    /// The color rows: a title and the theme entry it edits (token kinds by
    /// raw name; "foreground", "background", "selection", "currentLine"
    /// are the theme's own colors).
    static let colorRows: [(title: String, key: String)] = [
        ("Plain Text", "foreground"), ("Comments", "comment"), ("Documentation Comments", "docComment"), ("Strings", "string"),
        ("Numbers", "number"), ("Keywords", "keyword"), ("Preprocessor Statements", "preprocessor"), ("Attributes", "attribute"),
        ("Type Names", "typeName"), ("Background", "background"), ("Selection", "selection"), ("Current Line", "currentLine"),
    ]

    /// The preview's code (Ycode's own sample).
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
        let builtIn = EditorTheme.builtIns.contains { $0.name == theme.name }
        let palette = SourcePalette.forAppearance(dark: scheme == .dark, theme: theme)
        SettingsForm {
            Section {
                AppearanceChooser()
            }
            Section("Theme") {
                Picker(formLabel("Theme"), selection: setting(\.themeName)) {
                    ForEach(prefs.themes.map(\.name), id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .shellTarget("settings theme")
                ThemePreview(palette: palette, fontSize: ShellPreferences.fontSize)
                LabeledContent(formLabel("Theme file")) {
                    HStack(spacing: 6) {
                        Button("Duplicate") { run { try prefs.duplicate(theme) } }.shellTarget("settings theme duplicate")
                        Button("Delete") { prefs.deleteTheme(named: theme.name) }.disabled(builtIn).shellTarget("settings theme delete")
                        Button("Import…") { importing = true }.shellTarget("settings theme import")
                        Button("Export…") { exporting = true }.shellTarget("settings theme export")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Section {
                ForEach(Self.colorRows, id: \.key) { row in
                    ThemeColorRow(title: row.title, key: row.key, theme: theme, shown: Self.shownColor(row.key, palette), editable: !builtIn)
                        .id("\(theme.name)/\(row.key)")
                }
            } header: {
                Text("Colors")
            } footer: {
                FootNote(text: builtIn ? "Built-in themes cannot be changed; duplicate one to edit it."
                    : "Colors are #RRGGBB; an empty field uses the system color.")
            }
            Section {
                Stepper("Editor font size: \(Int(ShellPreferences.fontSize)) pt", value: Binding(get: { ShellPreferences.fontSize },
                                                                                             set: { prefs.sourceFontSize = $0 }),
                        in: Preferences.fontSizeRange, step: 1)
                    .shellTarget("settings font size")
                Stepper("Theme font size: \(Int(theme.fontSize)) pt", value: Binding(get: { theme.fontSize }, set: { v in
                    prefs.editSelectedTheme { $0.fontSize = v }
                }), in: Preferences.fontSizeRange, step: 1)
                    .disabled(builtIn)
                    .shellTarget("settings theme font size")
                Stepper("Console font size: \(Int(theme.consoleFontSize)) pt", value: Binding(get: { theme.consoleFontSize }, set: { v in
                    prefs.editSelectedTheme { $0.consoleFontSize = v }
                }), in: Preferences.fontSizeRange, step: 1)
                    .disabled(builtIn)
                    .shellTarget("settings console font size")
            } header: {
                Text("Fonts")
            } footer: {
                if prefs.sourceFontSize != nil {
                    Button("Use the Theme\u{2019}s Size") { prefs.sourceFontSize = nil }.shellTarget("settings font size reset")
                } else {
                    FootNote(text: "The editor font size applies to every theme (View \u{25B8} Editor \u{25B8} Font Size changes it too).")
                }
            }
            if let failure {
                Section {} footer: { FootNote(text: failure) }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ThemeDocument.readableContentTypes) { result in
            guard case .success(let url) = result else { return }
            run { try prefs.importTheme(from: url) }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? ThemeDocument(theme: theme) : nil, contentType: ThemeDocument.themeType,
                      defaultFilename: theme.fileName) { result in
            if case .failure(let e) = result { failure = "Could not export \u{201C}\(theme.name)\u{201D}: \(e.localizedDescription)" }
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

    /// The color a row's swatch shows: the theme's, else the palette's.
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

/// System / Light / Dark as three small window pictures.
struct AppearanceChooser: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let current = Preferences.shared.appearance
        HStack(spacing: 22) {
            Text("Appearance").foregroundStyle(c.label)
            Spacer(minLength: 0)
            ForEach(Preferences.Appearance.allCases, id: \.self) { a in
                Button { Preferences.shared.appearance = a } label: {
                    VStack(spacing: 5) {
                        Self.thumbnail(a)
                            .frame(width: 66, height: 42)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(a == current ? c.accent : c.fieldStroke, lineWidth: a == current ? 3 : 1)
                            }
                        Text(verbatim: a.rawValue).font(ShellFonts.small).foregroundStyle(a == current ? c.label : c.secondaryLabel)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .shellTarget("settings appearance \(a.rawValue.lowercased())")
            }
        }
        .padding(.vertical, 8)
    }

    /// A window drawn light, dark or split (System).
    @ViewBuilder static func thumbnail(_ a: Preferences.Appearance) -> some View {
        let light = Color(.sRGB, red: 0.93, green: 0.93, blue: 0.94)
        let dark = Color(.sRGB, red: 0.18, green: 0.18, blue: 0.2)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        switch a {
        case .light: shape.fill(light)
        case .dark: shape.fill(dark)
        case .system:
            HStack(spacing: 0) {
                Rectangle().fill(light)
                Rectangle().fill(dark)
            }
            .clipShape(shape)
        }
    }
}

/// The sample code in a palette.
struct ThemePreview: View {
    var palette: SourcePalette
    var fontSize: Double

    var body: some View {
        let size = CGFloat(min(fontSize, 16))
        let lineHeight = (size * 1.45).rounded()
        let lines = AppearanceSettingsPane.previewLines
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
                        ctx.draw(text, at: CGPoint(x: CGFloat(column + lead) * advance, y: CGFloat(i) * lineHeight), anchor: .topLeading)
                    }
                    column += run.text.count
                }
            }
        }
        .frame(height: CGFloat(lines.count) * lineHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.background.color) }
        .padding(.vertical, 8)
        .shellTarget("settings theme preview")
    }
}

/// One color of the selected theme: a swatch and its #RRGGBB text,
/// editable for user themes (a valid value is saved as typed).
struct ThemeColorRow: View {
    var title: String
    var key: String
    var theme: EditorTheme
    var shown: ThemeColor
    var editable: Bool
    @State private var text: String
    @Environment(\.colorScheme) private var scheme

    init(title: String, key: String, theme: EditorTheme, shown: ThemeColor, editable: Bool) {
        self.title = title
        self.key = key
        self.theme = theme
        self.shown = shown
        self.editable = editable
        _text = State(initialValue: Self.value(key, in: theme) ?? "")
    }

    var body: some View {
        let c = ShellColors(scheme)
        let valid = text.isEmpty || ThemeColor(hex: text) != nil
        LabeledContent(formLabel(title)) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill((ThemeColor(hex: text) ?? shown).color)
                    .frame(width: 30, height: 16)
                    .overlay { RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                TextField(title, text: $text, prompt: Text("System"))
                    .labelsHidden()
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 92)
                    .disabled(!editable)
                    .foregroundStyle(valid ? c.label : c.error)
                    .shellTarget("settings color \(key)")
            }
        }
        .onChange(of: text) { _, v in
            guard editable else { return }
            let t = v.trimmingCharacters(in: .whitespaces)
            if t.isEmpty {
                Preferences.shared.editSelectedTheme { Self.set(key, nil, in: &$0) }
            } else if let color = ThemeColor(hex: t) {
                Preferences.shared.editSelectedTheme { Self.set(key, color.hex, in: &$0) }
            }
        }
    }

    static func value(_ key: String, in t: EditorTheme) -> String? {
        switch key {
        case "foreground": t.foreground
        case "background": t.background
        case "selection": t.selection
        case "currentLine": t.currentLine
        default: t.tokens[key]
        }
    }

    static func set(_ key: String, _ hex: String?, in t: inout EditorTheme) {
        switch key {
        case "foreground": t.foreground = hex
        case "background": t.background = hex
        case "selection": t.selection = hex
        case "currentLine": t.currentLine = hex
        default: t.tokens[key] = hex
        }
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
