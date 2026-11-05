import Foundation
import YcodeEditorKit
import YcodeIDECore
import YcodePreviews

/// The preview canvas's hooks (`PreviewCanvasShellModel`; `specs/ide/previews.md`
/// §Linux, "The Linux canvas"): the focused file and its edits go to the
/// canvas; Editor ▸ Canvas and Editor ▸ Layout come here.
extension WorkspaceShellModel {
    /// Wires the canvas to this workspace (called once from `init`).
    func connectPreviewCanvas() {
        let c = previewCanvas
        let model = session.model
        c.locator = { PreviewModuleLocator(kind: model.kind, directory: model.url, projects: model.projects) }
        c.makeEngine = { OpenViewsPreviewEngine.standard(workspace: model.url) }
        c.makeSimulatorEngine = { SimulatorPreviewEngine.standard(workspace: model.url) }
        c.reveal = { [weak self] path, line in self?.open(path, line: line) }
        if let s = ProcessInfo.processInfo.environment["YCODE_PREVIEW_DELAY"], let d = Double(s) { c.refreshDelay = d }
    }

    /// The editor shows another file (or none).
    func previewCanvasFocusChanged() {
        guard let e = editor, structuredEditor == nil else {
            previewCanvas.focus(path: nil, text: nil)
            return
        }
        previewCanvas.focus(path: e.path, text: e.buffer.text)
    }

    /// The focused file was edited.
    func previewCanvasEdited(_ d: EditorDocument) {
        guard d === editor, d.path.hasSuffix(".swift") else { return }
        previewCanvas.edited(path: d.path, text: d.buffer.text)
    }

    /// Editor ▸ Canvas and Editor ▸ Layout: enabled for source files.
    func isPreviewCommandEnabled(_ c: ShellCommand) -> Bool {
        structuredEditor == nil && editor != nil
    }

    func performPreviewCommand(_ c: ShellCommand) {
        switch c {
        case .toggleCanvas: previewCanvas.toggleMode()
        case .canvasLayoutAutomatic: previewCanvas.setLayout(.automatic)
        case .canvasLayoutRight: previewCanvas.setLayout(.right)
        case .canvasLayoutBottom: previewCanvas.setLayout(.bottom)
        default: break
        }
    }

    /// The check marks of Editor ▸ Canvas and Editor ▸ Layout.
    public func isPreviewCommandChecked(_ c: ShellCommand) -> Bool? {
        switch c {
        case .toggleCanvas: previewCanvas.isModeOn
        case .canvasLayoutAutomatic: previewCanvas.layoutChoice == .automatic
        case .canvasLayoutRight: previewCanvas.layoutChoice == .right
        case .canvasLayoutBottom: previewCanvas.layoutChoice == .bottom
        default: nil
        }
    }
}

extension ShellCommand {
    /// Editor ▸ Canvas and Editor ▸ Layout's items.
    public var isPreviewCommand: Bool { [.toggleCanvas, .canvasLayoutAutomatic, .canvasLayoutRight, .canvasLayoutBottom].contains(self) }
}
