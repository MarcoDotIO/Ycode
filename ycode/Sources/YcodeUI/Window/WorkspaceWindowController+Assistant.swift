import AppKit
import YcodeLanguage

/// State for the assistant modes that are not file lists.
@MainActor public final class AssistantExtraState {
    public internal(set) var customMode: String?
    /// The last call-hierarchy lookup (tests await it).
    public internal(set) var task: Task<Void, Never>?
    /// The ring Navigate ▸ Jump to Next / Previous Counterpart is cycling
    /// through (`Counterparts.step`).
    var counterpartRing: [String]?
}

/// Assistant editor modes (`specs/ide/reference-ui-4.md` §16).
extension WorkspaceWindowController {
    /// The assistant's mode pop-up: every §16 mode, unavailable ones disabled.
    func configureAssistantModes(_ a: SourceEditorController, current: String) {
        let on = AssistantModeCatalog.enabled(for: current, hasLanguageService: session.language != nil)
        let selected = assistantExtra.customMode ?? AssistantModeCatalog.title(of: assistantMode)
        a.setAssistantModes(AssistantModeCatalog.titles, selected: selected,
                            disabled: Set(AssistantModeCatalog.titles).subtracting(on)) { [weak self] t in
            self?.setAssistantModeTitle(t)
        }
    }

    /// Chooses a mode by its pop-up title.
    public func setAssistantModeTitle(_ title: String) {
        if let m = AssistantModeCatalog.fileMode(title) {
            setAssistantMode(m)
        } else {
            assistantExtra.customMode = title
            updateCounterparts()
        }
    }

    public var assistantModeTitle: String { assistantExtra.customMode ?? AssistantModeCatalog.title(of: assistantMode) }

    func showCustomAssistantMode(_ a: SourceEditorController, current: String) {
        guard let mode = assistantExtra.customMode else { return }
        let files = workspaceFiles
        let read: (String) -> String? = { [weak self] p in
            if let e = self?.editorArea.allEditors.first(where: { $0.fileURL?.path == p && $0.isDirty }) { return e.textView.string }
            return try? String(contentsOfFile: p, encoding: .utf8)
        }
        func showFiles(_ list: [String]) {
            a.setCounterparts(list.map { (URL(fileURLWithPath: $0).lastPathComponent, $0) }) { [weak self, weak a] p in
                if let self, let a { self.open(path: p, line: nil, in: a) }
            }
            if let first = list.first { if a.fileURL?.path != first { open(path: first, line: nil, in: a) } } else { a.showText("No Editor", title: "No Editor") }
        }
        switch mode {
        case "Extensions": showFiles(AssistantModeCatalog.extensions(of: current, in: files, readFile: read))
        case "User Interfaces": showFiles(AssistantModeCatalog.userInterfaces(of: current, in: files, readFile: read))
        case "Included By": showFiles(AssistantModeCatalog.includedBy(current, in: files, readFile: read))
        case "Generated Interface":
            let text = read(current).map(AssistantModeCatalog.generatedInterface) ?? ""
            a.showText(text.isEmpty ? "No Editor" : text, title: URL(fileURLWithPath: current).lastPathComponent + " (Interface)")
        case "Documentation Preview":
            let text = read(current).map(AssistantModeCatalog.documentationPreview) ?? ""
            a.showText(text.isEmpty ? "No Editor" : text, title: URL(fileURLWithPath: current).lastPathComponent + " (Documentation)")
        case "Callers", "Callees":
            let e = editor
            guard let language = session.language, let url = e.fileURL else { a.showText("No Editor", title: "No Editor"); return }
            let p = e.textView.lineIndex.position(at: e.textView.selectedRange().location)
            assistantExtra.task = Task { [weak self, weak a] in
                let items = (try? await language.client.prepareCallHierarchy(url, at: p)) ?? []
                var found: [CallHierarchyItem] = []
                for i in items {
                    if mode == "Callers" { found += ((try? await language.client.incomingCalls(i)) ?? []).map(\.caller) }
                    else { found += (try? await language.client.outgoingCalls(i)) ?? [] }
                }
                guard let self, let a, self.assistantExtra.customMode == mode else { return }
                a.setCounterparts(found.map { ($0.name, $0.url.path) }) { [weak self, weak a] path in
                    if let self, let a { self.open(path: path, line: nil, in: a) }
                }
                if let f = found.first {
                    self.open(path: f.url.standardizedFileURL.path, line: f.selection.line + 1, in: a)
                } else {
                    a.showText("No Editor", title: "No Editor")
                }
            }
        default:
            a.showText("No Editor", title: "No Editor")
        }
    }
}
