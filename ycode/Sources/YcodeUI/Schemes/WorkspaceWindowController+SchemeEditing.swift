import AppKit
import YcodeIDECore
import YcodeWorkspace

// Edit Scheme… and Manage Schemes… for every scheme the toolbar lists,
// autocreated ones included (parity inventory P-108).
extension WorkspaceWindowController {
    /// A scheme editor for `scheme`, wired to this window: it reopens on
    /// the last action and tab, opens files, shows Manage Schemes, and
    /// reloads the scheme list when it writes an autocreated scheme or a
    /// duplicate.
    public func configuredSchemeEditor(_ scheme: Scheme) -> SchemeEditorController {
        let editor = SchemeEditorController(scheme: scheme, configurations: session.model.configurationNames)
        editor.startSelection = schemeEditorState.selection
        editor.availableTargets = SchemeEditorController.buildableTargets(projects: session.model.projects, container: session.model.url)
        editor.onOpenFile = { [weak self] in self?.open(path: $0.path, line: nil) }
        editor.onSelect = { [weak self] a, t in self?.schemeEditorState.selection = (a, t) }
        editor.onManage = { [weak self, weak editor] in
            guard let self else { return }
            editor?.presentAsSheet(self.manageSchemesController())
        }
        editor.onAutocreatedSaved = { [weak self] s in
            self?.session.model.writeAutocreatedSiblings(of: s)
            self?.reloadSchemeNames()
        }
        editor.onDuplicate = { [weak self] _ in self?.reloadSchemeNames() }
        return editor
    }

    /// Re-reads the scheme names after a scheme file was written.
    func reloadSchemeNames() {
        let names = session.model.loadSchemes().map(\.name)
        if !names.isEmpty { session.model.schemeNames = names }
        reloadSchemes()
    }
}
