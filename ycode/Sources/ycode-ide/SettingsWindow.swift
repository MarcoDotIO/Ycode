import Foundation
import Observation
import SwiftUI
import YcodeCompletion
import YcodeIDECore
import YcodeIDEShell

/// Follows `Preferences` for the views that draw with it: editors redraw with
/// a new font, theme or tab width, and open buffers take the typing settings.
@MainActor
@Observable
final class ShellPreferences {
    static let shared = ShellPreferences()
    /// Bumped on every change of the preferences.
    private(set) var revision = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ShellPreferences.shared.changed() }
        }
    }

    private func changed() {
        revision &+= 1
        ShellApp.model.workspace?.preferencesChanged()
    }

    /// The source font's size: the user's, else the theme's.
    static var fontSize: Double { Preferences.shared.sourceFontSize ?? Preferences.shared.theme.fontSize }
}

/// The Settings window on Linux (Ctrl+,): the editor's font and theme,
/// indentation, and where predictive completion's model comes from. A small
/// subset of the macOS IDE's Settings (`specs/ide/settings.md`); the same
/// user defaults, so both IDEs and `ycode complete` read them.
struct ShellSettingsView: View {
    @State private var fontSize = ShellPreferences.fontSize
    @State private var themeName = Preferences.shared.themeName
    @State private var useTabs = Preferences.shared.indentWithTabs
    @State private var tabWidth = Preferences.shared.tabWidth
    @State private var indentWidth = Preferences.shared.indentWidth
    @State private var autoIndent = Preferences.shared.autoIndent
    @State private var closers = Preferences.shared.autoInsertClosers
    @State private var prediction = PredictiveCompletionSettings.load(from: .standard)

    var body: some View {
        Form {
            Section("Editor") {
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: Preferences.fontSizeRange, step: 1)
                    .shellTarget("settings font size")
                Picker("Theme", selection: $themeName) {
                    ForEach(Preferences.shared.themes.map(\.name), id: \.self) { Text(verbatim: $0).tag($0) }
                }
                .shellTarget("settings theme")
            }
            Section("Indentation") {
                Picker("Prefer indent using", selection: $useTabs) {
                    Text("Spaces").tag(false)
                    Text("Tabs").tag(true)
                }
                .shellTarget("settings indent using")
                Stepper("Tab width: \(tabWidth)", value: $tabWidth, in: 1...16).shellTarget("settings tab width")
                Stepper("Indent width: \(indentWidth)", value: $indentWidth, in: 1...16)
                    .disabled(useTabs)
                    .shellTarget("settings indent width")
                Toggle("Syntax-aware indenting", isOn: $autoIndent).shellTarget("settings auto indent")
                Toggle("Automatically insert closing brackets and quotes", isOn: $closers).shellTarget("settings closers")
            }
            Section {
                Toggle("Predictive code completion", isOn: $prediction.enabled).shellTarget("settings prediction")
                Picker("Model source", selection: $prediction.backend) {
                    ForEach(PredictiveCompletionSettings.Backend.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                }
                .shellTarget("settings backend")
                LabeledContent("Address") {
                    TextField("Address", text: Binding(get: { prediction.address ?? "" },
                                                       set: { prediction.address = $0.isEmpty ? nil : $0 }),
                              prompt: Text(verbatim: prediction.backend.defaultAddress))
                        .multilineTextAlignment(.trailing)
                }
                .shellTarget("settings address")
                LabeledContent("Model") {
                    TextField("Model", text: $prediction.model, prompt: Text("The server's choice"))
                        .multilineTextAlignment(.trailing)
                }
                .shellTarget("settings model")
            } header: {
                Text("Predictive Code Completion")
            } footer: {
                Text("For ycode complete and the MCP tool; the Linux editor shows no suggestions yet.")
                    .font(ShellFonts.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .onChange(of: fontSize) { _, v in Preferences.shared.sourceFontSize = v }
        .onChange(of: themeName) { _, v in Preferences.shared.themeName = v }
        .onChange(of: useTabs) { _, v in Preferences.shared.indentWithTabs = v }
        .onChange(of: tabWidth) { _, v in Preferences.shared.tabWidth = v }
        .onChange(of: indentWidth) { _, v in Preferences.shared.indentWidth = v }
        .onChange(of: autoIndent) { _, v in Preferences.shared.autoIndent = v }
        .onChange(of: closers) { _, v in Preferences.shared.autoInsertClosers = v }
        .onChange(of: prediction) { _, v in v.save(to: .standard) }
        .shellTarget("settings")
    }
}
