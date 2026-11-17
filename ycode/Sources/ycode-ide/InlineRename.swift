import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell

/// Rename in place (P-084), as the macOS editor does it
/// (`SourceEditorController+Rename.swift`): an edit box exactly on the
/// identifier, in the source font on the editor's background, growing with
/// what is typed; the file's other occurrences boxed the same way by the
/// painter (`SourceEditorPainter.renameBoxes`). Return renames (a rename
/// over several files then shows its preview sheet), Escape cancels.
struct InlineRenameLayer: View {
    var model: WorkspaceShellModel
    let controller: SourceEditorController
    let palette: SourcePalette
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let f = model.languageFeatures
        GeometryReader { _ in
            if let r = f.rename, f.renamePreview == nil, r.path == controller.document.path {
                InlineRenameField(model: model, controller: controller, request: r, palette: palette, colors: ShellColors(scheme))
                    .id(r.range.location)
            }
        }
        .allowsHitTesting(f.rename != nil && f.renamePreview == nil)
    }
}

struct InlineRenameField: View {
    var model: WorkspaceShellModel
    let controller: SourceEditorController
    let request: RenameRequest
    let palette: SourcePalette
    let colors: ShellColors
    @State private var name: String
    @FocusState private var focused: Bool

    init(model: WorkspaceShellModel, controller: SourceEditorController, request: RenameRequest, palette: SourcePalette, colors: ShellColors) {
        self.model = model
        self.controller = controller
        self.request = request
        self.palette = palette
        self.colors = colors
        _name = State(initialValue: request.oldName)
    }

    var body: some View {
        let c = controller
        let _ = c.redraw.tick   // follows scrolling
        let at = c.symbolAnchor(request.range.location)
        let width = c.layout.width(ofText: name) + 2 * InlineRenameField.textInset
        TextField("", text: $name)
            .textFieldStyle(.plain)
            .font(ShellFonts.editor(c.fontSize))
            .foregroundStyle(palette.foreground.color)
            .focused($focused)
            .onSubmit {
                let n = name
                Task { await model.commitRename(to: n) }
            }
            .onKeyPress(.escape) {
                model.cancelRename()
                return .handled
            }
            .padding(.horizontal, Self.textInset)
            .frame(width: width, height: c.lineHeight, alignment: .leading)
            .background { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(palette.background.color) }
            .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(Self.boxColor(colors), lineWidth: 1) }
            .offset(x: at.x - 2, y: at.y)
            .task { focused = true }
            .shellTarget("rename field")
    }

    /// The text's inset inside the box.
    static let textInset: CGFloat = 2
    /// The boxes' outline: the secondary label colour, as the macOS boxes.
    static func boxColor(_ c: ShellColors) -> Color { c.secondaryLabel.opacity(0.6) }
}
