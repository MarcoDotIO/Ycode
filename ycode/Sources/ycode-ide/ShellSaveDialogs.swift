import Foundation
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
import YcodeIDECore
import YcodeIDEShell

/// The save dialogs of File ▸ Save As…, Export… and Save As Workspace… on
/// Linux (beta 5, B5-MENUS2, P-001): the toolkit's save dialog for
/// `ShellFileCommands.request`; the model writes at the chosen place
/// (`ShellAppModel.completeSave`). Installed on the workspace window with
/// `.shellSaveDialogs(app:)`; the commands are enabled once it is.
struct ShellSaveDialogs: ViewModifier {
    var app: ShellAppModel

    func body(content: Content) -> some View {
        let commands = ShellFileCommands.shared
        let request = commands.request
        return content
            .fileExporter(isPresented: Binding(get: { commands.request != nil }, set: { if !$0 { commands.request = nil } }),
                          document: request.map(SaveDialogPlaceholder.init), contentType: .item, defaultFilename: request?.defaultName) { result in
                guard let request, case .success(let url) = result else { return }
                do {
                    try app.completeSave(request, to: url)
                } catch {
                    app.notice = ShellNotice("The file couldn\u{2019}t be saved.", error.localizedDescription)
                }
            }
            .onAppear { commands.dialogsInstalled = true }
            .background(ShellAlternateShortcuts(app: app))
    }
}

extension View {
    /// The menu bar's window support (P-001): File ▸ Save As…, Export…
    /// and Save As Workspace…'s dialogs, and the ⌥ alternates' shortcuts.
    func shellMenuSupport(app: ShellAppModel) -> some View { modifier(ShellSaveDialogs(app: app)) }
}

/// The shortcuts of the menu bar's alternates (Save All ⌥⌘S under Save,
/// P-001): the toolkit's menus do not list alternates yet (L-048), so their
/// keys are taken here, by hidden buttons, while the item can be performed.
struct ShellAlternateShortcuts: View {
    var app: ShellAppModel

    static let alternates: [MenuCommand] = CommandTable.allCommands.filter { $0.isAlternate && !$0.key.isEmpty && $0.isAvailable }

    var body: some View {
        let _ = ShellPreferences.shared.revision
        let pass = ShellMenuModel.Pass(app)
        ZStack {
            ForEach(Array(Self.alternates.enumerated()), id: \.offset) { pair in
                let c = pair.element
                if ShellMenuModel.isEnabled(c, in: pass), let s = ShellShortcut(command: KeyBindings.effective(c))?.keyboardShortcut {
                    Button("") { ShellMenuModel.perform(c, app: app) }
                        .keyboardShortcut(s)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
    }
}

/// What the save dialog writes first (an empty file, or an empty folder
/// for a workspace); `completeSave` then writes the contents.
struct SaveDialogPlaceholder: FileDocument {
    static var readableContentTypes: [UTType] { [.item] }
    var isFolder = false

    init(_ request: ShellFileCommands.Request) { isFolder = request.kind == .workspace }

    init(configuration: ReadConfiguration) throws {}

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        isFolder ? FileWrapper(directoryWithFileWrappers: [:]) : FileWrapper(regularFileWithContents: Data())
    }
}
