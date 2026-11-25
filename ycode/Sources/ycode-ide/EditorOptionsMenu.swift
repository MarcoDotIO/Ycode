import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The toolbar's Add Editor and Editor Options pull-downs (P-065), with the
/// macOS IDE's items (`EditorOptionsMenu`): Add Editor is Tab, a separator,
/// Editor Pane On Right and Editor Pane Below with their key equivalents;
/// Editor Options is Layout ▸ (where the canvas goes), the comparison
/// styles, Minimap, Authors, Code Coverage, Invisibles, Scope Guides, Wrap
/// Lines and Choose Workspace Theme…. Items the Linux editor does not have
/// yet show disabled (never a silent no-op): the comparison styles (no Code
/// Review on Linux) and Authors (no blame column). Code Coverage, Invisibles
/// and Scope Guides toggle the shared settings the editor draws
/// (SourceEditorView+Guides.swift); Choose Workspace Theme… opens Settings ▸
/// Appearance, as on macOS (P-065).
struct AddEditorMenuItems: View {
    var model: WorkspaceShellModel

    var body: some View {
        Button("Tab") {}.keyboardShortcut("t", modifiers: [.command]).disabled(true)   // no editor tabs on Linux (L-136)
        Divider()
        Button("Editor Pane On Right") { model.perform(.splitEditor) }
            .keyboardShortcut("t", modifiers: [.control, .command])
            .disabled(!model.isEnabled(.splitEditor))
        Button("Editor Pane Below") { model.perform(.splitEditorBelow) }
            .keyboardShortcut("t", modifiers: [.control, .option, .command])
            .disabled(!model.isEnabled(.splitEditorBelow))
    }
}

struct EditorOptionsMenuItems: View {
    var model: WorkspaceShellModel
    /// Re-read when the preferences change.
    var revision: Int
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let prefs = Preferences.shared
        Menu("Layout") {
            layout("Automatic", .canvasLayoutAutomatic)
            Divider()
            layout("Canvas on Right", .canvasLayoutRight)
            layout("Canvas on Bottom", .canvasLayoutBottom)
        }
        Divider()
        Button("Inline Comparison") {}.disabled(true)
        Button("Side By Side Comparison") {}.disabled(true)
        Divider()
        Toggle("Minimap", isOn: Binding(get: { prefs.showMinimap }, set: { prefs.showMinimap = $0 }))
            .keyboardShortcut("m", modifiers: [.control, .shift, .command])
        Toggle("Authors", isOn: .constant(false)).keyboardShortcut("a", modifiers: [.control, .shift, .command]).disabled(true)
        Toggle("Code Coverage", isOn: Binding(get: { prefs.showCodeCoverage }, set: { prefs.showCodeCoverage = $0 }))
        Divider()
        Toggle("Invisibles", isOn: Binding(get: { prefs.showInvisibles }, set: { prefs.showInvisibles = $0 }))
        Toggle("Scope Guides", isOn: Binding(get: { prefs.scopeGuides != .none }, set: { prefs.scopeGuides = $0 ? .lines : .none }))
        Toggle("Wrap Lines", isOn: Binding(get: { prefs.wrapLines }, set: { prefs.wrapLines = $0 }))
            .keyboardShortcut("l", modifiers: [.control, .shift, .command])
            .disabled(model.editor == nil)
        Divider()
        Button("Choose Workspace Theme…") {
            ShellSettingsModel.shared.select(.appearance)
            openSettings()
        }
    }

    func layout(_ title: String, _ c: ShellCommand) -> some View {
        Toggle(title, isOn: Binding(get: { model.isPreviewCommandChecked(c) ?? false }, set: { _ in model.perform(c) }))
            .disabled(!model.isEnabled(c))
    }
}
