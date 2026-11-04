import Foundation
import SwiftUI
import YcodeCompletion
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax

/// Settings ▸ Editing, with its Display, Completion and Indentation pages
/// (reference-ui-5.md §9.3; the macOS IDE's `TextEditingSettingsPane`).
struct EditingSettingsPane: View {
    @Bindable var model: ShellSettingsModel

    enum Page: String { case main = "Editing", display = "Display", completion = "Completion", indentation = "Indentation" }

    #if os(Linux)
    static let lineEndings = "Unix (LF)"
    #else
    static let lineEndings = "macOS / Unix (LF)"
    #endif

    var body: some View {
        let _ = ShellPreferences.shared.revision
        switch model.editingPage {
        case .main: main
        case .display: display
        case .completion: CompletionSettingsPage { model.editingPage = .main }
        case .indentation: indentation
        }
    }

    var main: some View {
        SettingsForm {
            Section {
                DrillRow(title: "Display", detail: "Line numbers, wrapping, guides", target: "settings editing display") { model.editingPage = .display }
                DrillRow(title: "Completion", detail: Preferences.shared.predictiveCompletion.enabled ? "Predictive on" : "",
                         target: "settings editing completion") { model.editingPage = .completion }
                DrillRow(title: "Indentation", detail: Preferences.shared.indentWithTabs ? "Tabs" : "\(Preferences.shared.indentWidth) spaces",
                         target: "settings editing indentation") { model.editingPage = .indentation }
            }
            Section("Files") {
                LabeledContent("Default text encoding") { Text(verbatim: "Unicode (UTF-8)") }
                LabeledContent("Default line endings") { Text(verbatim: Self.lineEndings) }
                CheckRow(title: "Convert existing files on save", isOn: setting(\.convertExistingFilesOnSave), target: "settings convert on save")
            }
            Section("When Editing") {
                CheckRow(title: "Automatically trim trailing whitespace", isOn: setting(\.trimTrailingWhitespace), target: "settings trim whitespace")
                CheckRow(title: "Including whitespace-only lines", isOn: setting(\.trimWhitespaceOnlyLines), target: "settings trim whitespace lines")
                    .disabled(!Preferences.shared.trimTrailingWhitespace)
                CheckRow(title: "Predictive code completion", isOn: setting(\.predictiveCompletion.enabled), target: "settings prediction main")
            }
            Section("Localized Strings") {
                CheckRow(title: "Automatically generate string catalog comments", isOn: setting(\.generateStringCatalogComments),
                         target: "settings catalog comments")
            }
        }
    }

    var display: some View {
        SettingsForm {
            Section {
                BackRow(title: "Editing", target: "settings editing back") { model.editingPage = .main }
            }
            Section("Display") {
                CheckRow(title: "Line numbers", isOn: setting(\.showLineNumbers), target: "settings line numbers")
                CheckRow(title: "Code folding ribbon", isOn: setting(\.showFoldingRibbon), target: "settings folding ribbon")
                CheckRow(title: "Code structure headers", isOn: setting(\.showCodeStructureHeaders), target: "settings structure headers")
                CheckRow(title: "MARK separators", isOn: setting(\.showMarkSeparators), target: "settings mark separators")
                CheckRow(title: "Code coverage iteration counts", isOn: setting(\.showCoverageCounts), target: "settings coverage counts")
                CheckRow(title: "Condition on #endif lines", isOn: setting(\.showEndifConditions), target: "settings endif conditions")
                CasePicker(title: "Scope guides", selection: setting(\.scopeGuides), target: "settings scope guides")
                Stepper("Reformat code at column: \(Preferences.shared.reformatColumn)", value: setting(\.reformatColumn), in: 1...400)
                    .shellTarget("settings reformat column")
                CheckRow(title: "Show reformatting guide", isOn: setting(\.showReformattingGuide), target: "settings reformat guide")
                CheckRow(title: "Automatically reformat when completing", isOn: setting(\.reformatWhenCompleting), target: "settings reformat completing")
                CheckRow(title: "Dim inactive code", isOn: setting(\.dimInactiveCode), target: "settings dim inactive")
                CheckRow(title: "Highlight instances of selected symbol", isOn: setting(\.highlightSelectedSymbol), target: "settings highlight symbol")
                Stepper("Highlighting delay: \(String(format: "%.2f", Preferences.shared.highlightDelay)) s", value: setting(\.highlightDelay),
                        in: 0...5, step: 0.05)
                    .disabled(!Preferences.shared.highlightSelectedSymbol)
                    .shellTarget("settings highlight delay")
                CasePicker(title: "Editor overscroll", selection: setting(\.editorOverscroll), target: "settings overscroll")
            }
            Section("Line Wrapping") {
                CheckRow(title: "Wrap lines to editor width", isOn: setting(\.wrapLines), target: "settings wrap lines")
                Stepper("Indent wrapped lines by: \(Preferences.shared.wrappedLineIndent) spaces", value: setting(\.wrappedLineIndent), in: 0...16)
                    .disabled(!Preferences.shared.wrapLines)
                    .shellTarget("settings wrapped indent")
            }
            Section("Documentation Comments") {
                CheckRow(title: "Fade delimiters", isOn: setting(\.fadeDocCommentDelimiters), target: "settings fade doc delimiters")
                CheckRow(title: "Fade comment delimiters", isOn: setting(\.fadeCommentDelimiters), target: "settings fade delimiters")
            }
        }
    }

    var indentation: some View {
        SettingsForm {
            Section {
                BackRow(title: "Editing", target: "settings editing back") { model.editingPage = .main }
            }
            Section("Indentation") {
                Picker("Prefer indent using", selection: setting(\.indentWithTabs)) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
                .shellTarget("settings indent using")
                Stepper("Tab width: \(Preferences.shared.tabWidth) spaces", value: setting(\.tabWidth), in: 1...16)
                    .shellTarget("settings tab width")
                Stepper("Indent width: \(Preferences.shared.indentWidth) spaces", value: setting(\.indentWidth), in: 1...16)
                    .disabled(Preferences.shared.indentWithTabs)
                    .shellTarget("settings indent width")
                Picker("Tab key", selection: setting(\.tabKeyBehavior)) {
                    ForEach(TabKeyBehavior.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                .shellTarget("settings tab key")
            }
            Section("Typing") {
                CheckRow(title: "Syntax-aware indenting", isOn: setting(\.autoIndent), target: "settings auto indent")
                CheckRow(title: "Automatically insert closing brackets and quotes", isOn: setting(\.autoInsertClosers), target: "settings closers")
                CheckRow(title: "Enclose selection in matching delimiters", isOn: setting(\.encloseSelection), target: "settings enclose selection")
            }
        }
    }
}

/// Editing ▸ Completion: completion while typing, and where predictive
/// completion's model comes from (`specs/ide/predictive-completion.md` §5).
struct CompletionSettingsPage: View {
    var back: () -> Void
    @State private var prediction = Preferences.shared.predictiveCompletion
    @State private var whileTyping = ShellPreferences.completionWhileTyping

    var body: some View {
        SettingsForm {
            Section {
                BackRow(title: "Editing", target: "settings editing back", action: back)
            }
            Section {
                CheckRow(title: "Suggest completions after a period", isOn: $whileTyping, target: "settings completion")
            } header: {
                Text("Code Completion")
            } footer: {
                FootNote(text: "Ctrl+Space or Escape asks at any time. Completions come from sourcekit-lsp, which must be on the PATH.")
            }
            Section {
                CheckRow(title: "Predictive code completion", isOn: $prediction.enabled, target: "settings prediction")
                Picker("Model source", selection: $prediction.backend) {
                    ForEach(PredictiveCompletionSettings.Backend.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                }
                .shellTarget("settings backend")
                LabeledContent("Address") {
                    TextField("Address", text: Binding(get: { prediction.address ?? "" },
                                                       set: { prediction.address = $0.isEmpty ? nil : $0 }),
                              prompt: Text(verbatim: prediction.backend.defaultAddress))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 280)
                }
                .shellTarget("settings address")
                LabeledContent("Model") {
                    TextField("Model", text: $prediction.model, prompt: Text("The server's choice"))
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 280)
                }
                .shellTarget("settings model")
            } header: {
                Text("Predictive Code Completion")
            } footer: {
                FootNote(text: "Used by ycode complete and the MCP tool; the Linux editor does not show predictions yet.")
            }
        }
        .onChange(of: prediction) { _, v in
            v.save(to: Preferences.shared.defaults)
            ShellPreferences.persist()
        }
        .onChange(of: whileTyping) { _, v in
            UserDefaults.standard.set(v, forKey: ShellPreferences.completionKey)
            ShellPreferences.shared.touch()
        }
    }
}
