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

    /// The macOS IDE's words on both IDEs (the reference's wording, true on
    /// Linux too).
    static let lineEndings = "macOS / Unix (LF)"
    static let textEncoding = "Unicode (UTF-8)"

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
        // R4.1: the navigation rows' card, text encoding alone in a card,
        // then line endings and the convert switch, 10 apart with no
        // header. Ycode reads and writes UTF-8 with LF only, so each
        // pop-up offers the one value.
        SettingsForm(startsWithCard: true) {
            SettingsSection(cardFollows: true) {
                SettingsNavigationRow(title: "Display", icon: .display, target: "settings editing display") { model.editingPage = .display }
                SettingsNavigationRow(title: "Completion", icon: .completion, target: "settings editing completion") { model.editingPage = .completion }
                SettingsNavigationRow(title: "Indentation", icon: .indentation, target: "settings editing indentation") {
                    model.editingPage = .indentation
                }
            }
            SettingsSection(cardFollows: true) {
                PickerRow(title: "Default text encoding", selection: .constant(Self.textEncoding), options: [(Self.textEncoding, Self.textEncoding)],
                          target: "settings text encoding")
            }
            SettingsSection {
                PickerRow(title: "Default line endings", selection: .constant(Self.lineEndings), options: [(Self.lineEndings, Self.lineEndings)],
                          target: "settings line endings")
                CheckRow(title: "Convert existing files on save", isOn: setting(\.convertExistingFilesOnSave), target: "settings convert on save")
            }
            SettingsSection("When Editing") {
                CheckRow(title: "Automatically trim trailing whitespace", isOn: setting(\.trimTrailingWhitespace), target: "settings trim whitespace")
                CheckRow(title: "Trim whitespace-only lines", isOn: setting(\.trimWhitespaceOnlyLines), target: "settings trim whitespace lines")
                    .disabled(!Preferences.shared.trimTrailingWhitespace)
                CheckRow(title: "Predictive code completion", isOn: setting(\.predictiveCompletion.enabled), target: "settings prediction main")
            }
            SettingsSection("Localized Strings") {
                CheckRow(title: "Automatically generate string catalog comments", isOn: setting(\.generateStringCatalogComments),
                         target: "settings catalog comments")
            }
        }
    }

    var display: some View {
        SettingsForm {
            BackRow(title: "Editing", target: "settings editing back") { model.editingPage = .main }
            SettingsSection("Display") {
                CheckRow(title: "Line numbers", isOn: setting(\.showLineNumbers), target: "settings line numbers")
                CheckRow(title: "Code folding ribbon", isOn: setting(\.showFoldingRibbon), target: "settings folding ribbon")
                CheckRow(title: "Code structure headers", isOn: setting(\.showCodeStructureHeaders), target: "settings structure headers")
                CheckRow(title: "MARK separators", isOn: setting(\.showMarkSeparators), target: "settings mark separators")
                CheckRow(title: "Code coverage iteration counts", isOn: setting(\.showCoverageCounts), target: "settings coverage counts")
                CheckRow(title: "Condition on #endif lines", isOn: setting(\.showEndifConditions), target: "settings endif conditions")
                CasePicker(title: "Scope guides", selection: setting(\.scopeGuides), target: "settings scope guides")
                IntStepperRow(title: "Reformat code at column", value: setting(\.reformatColumn), range: 1...400, target: "settings reformat column")
                CheckRow(title: "Show reformatting guide", isOn: setting(\.showReformattingGuide), target: "settings reformat guide")
                CheckRow(title: "Automatically reformat when completing", isOn: setting(\.reformatWhenCompleting), target: "settings reformat completing")
                CheckRow(title: "Dim inactive code", isOn: setting(\.dimInactiveCode), target: "settings dim inactive")
                CheckRow(title: "Highlight instances of selected symbol", isOn: setting(\.highlightSelectedSymbol), target: "settings highlight symbol")
                DoubleStepperRow(title: "Highlighting delay", value: setting(\.highlightDelay), range: 0...5, step: 0.05,
                                 format: { String(format: "%.2f s", $0) }, target: "settings highlight delay")
                    .disabled(!Preferences.shared.highlightSelectedSymbol)
                CasePicker(title: "Editor overscroll", selection: setting(\.editorOverscroll), target: "settings overscroll")
            }
            SettingsSection("Line Wrapping") {
                CheckRow(title: "Wrap lines to editor width", isOn: setting(\.wrapLines), target: "settings wrap lines")
                IntStepperRow(title: "Indent wrapped lines by", value: setting(\.wrappedLineIndent), range: 0...16, suffix: " spaces",
                              target: "settings wrapped indent")
                    .disabled(!Preferences.shared.wrapLines)
            }
            SettingsSection("Documentation Comments") {
                CheckRow(title: "Fade delimiters", isOn: setting(\.fadeDocCommentDelimiters), target: "settings fade doc delimiters")
                CheckRow(title: "Fade comment delimiters", isOn: setting(\.fadeCommentDelimiters), target: "settings fade delimiters")
            }
        }
    }

    var indentation: some View {
        SettingsForm {
            BackRow(title: "Editing", target: "settings editing back") { model.editingPage = .main }
            SettingsSection("Indentation") {
                PickerRow(title: "Prefer indent using", selection: setting(\.indentWithTabs), options: [(false, "Spaces"), (true, "Tabs")],
                          target: "settings indent using")
                IntStepperRow(title: "Tab width", value: setting(\.tabWidth), range: 1...16, suffix: " spaces", target: "settings tab width")
                IntStepperRow(title: "Indent width", value: setting(\.indentWidth), range: 1...16, suffix: " spaces", target: "settings indent width")
                    .disabled(Preferences.shared.indentWithTabs)
                PickerRow(title: "Tab key", selection: setting(\.tabKeyBehavior), options: TabKeyBehavior.allCases.map { ($0, $0.title) },
                          target: "settings tab key")
            }
            SettingsSection("Typing") {
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
            BackRow(title: "Editing", target: "settings editing back", action: back)
            SettingsSection("Code Completion") {
                CheckRow(title: "Suggest completions after a period", isOn: $whileTyping, target: "settings completion",
                         help: "Ctrl+Space or Escape asks at any time. Completions come from sourcekit-lsp, which must be on the PATH.")
            }
            SettingsSection("Predictive Code Completion", content: {
                CheckRow(title: "Predictive code completion", isOn: $prediction.enabled, target: "settings prediction")
                PickerRow(title: "Model source", selection: $prediction.backend,
                          options: PredictiveCompletionSettings.Backend.allCases.map { ($0, $0.displayName) }, target: "settings backend")
                SettingsRow("Address") {
                    TextField("Address", text: Binding(get: { prediction.address ?? "" },
                                                       set: { prediction.address = $0.isEmpty ? nil : $0 }),
                              prompt: Text(verbatim: prediction.backend.defaultAddress))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260)
                }
                .shellTarget("settings address")
                SettingsRow("Model") {
                    TextField("Model", text: $prediction.model, prompt: Text("The server's choice"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 260)
                }
                .shellTarget("settings model")
            }, footer: {
                FootNote(text: "Used by ycode complete and the MCP tool; the Linux editor does not show predictions yet.")
            })
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
