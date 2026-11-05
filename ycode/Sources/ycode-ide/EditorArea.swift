import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax

/// The editor area (`metrics.md` §4): the jump bar (a 31-point band and
/// its separator), the find bar when shown, a banner when the file changed on
/// disk, the source editor (`SourceEditorView`) and the minimap, then the
/// debug bar.
struct EditorArea: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // The commit editor or a history replaces the source editor.
        if model.sourceControl.pane != nil {
            SourceControlPaneView(model: model)
        } else if model.testing.shownReport != nil {
            ReportPaneView(model: model)
        } else {
            sourceEditor
        }
    }

    @ViewBuilder var sourceEditor: some View {
        let prefs = ShellPreferences.shared.revision
        let palette = SourcePalette.forAppearance(dark: colorScheme == .dark, theme: Preferences.shared.theme)
        let c = ShellColors(colorScheme)
        VStack(spacing: 0) {
            JumpBar(model: model)
            Hairline(color: c.separator)
            if model.findBar.isShown, model.editor != nil {
                EditorFindBarView(bar: model.findBar, model: model)
                Hairline(color: c.separator)
            }
            if let editor = model.editor {
                EditorBanner(model: model, document: editor)
            }
            Group {
                if let doc = model.document {
                    if let s = model.structuredEditor, s.path == doc.path {
                        StructuredEditorView(model: model, editor: s)
                    } else if let message = doc.message {
                        Text(verbatim: message).font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let editor = model.editor {
                        let controller = SourceEditorController.of(editor)
                        PreviewEditorSplit(canvas: model.previewCanvas) {   // PreviewCanvasView.swift
                            HStack(spacing: 0) {
                                SourceEditorView(controller: controller, model: model, palette: palette, preferences: prefs)
                                    .id(editor.path)
                                Hairline(color: c.separator, vertical: true)
                                Minimap(controller: controller, colors: c)
                            }
                            .overlay { QuickHelpPopoverLayer(model: model, controller: controller) }
                        }
                    }
                } else {
                    // Nothing open: the empty editor with its minimap column,
                    // as the AppKit editor shows it ("No Selection" is the
                    // jump bar's).
                    HStack(spacing: 0) {
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Hairline(color: c.separator, vertical: true)
                        Color.clear.frame(width: 112)
                    }
                    .shellTarget("no selection")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background.color)
            .overlay { LanguageNotice(model: model) }
            .overlay { DebugEditorOverlay(model: model) }   // DebugEditors.swift
            DebugBar(model: model)
        }
        .shellTarget("editor")
    }
}

/// The path of the open file (`reference-ui-6.md` §4.1): Related Items,
/// then workspace › groups › file (names as the navigator shows them), then
/// the symbol ("No Selection" outside a declaration); 11 points.
struct JumpBar: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        HStack(spacing: 4) {
            Image(systemName: "square.grid.2x2").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                .help("Navigate to Related Items")
            if model.document != nil {
                ForEach(Array(model.jumpPath.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 { chevron(c) }
                    HStack(spacing: 3) {
                        Image(systemName: pair.element.symbol).font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                        Text(verbatim: pair.element.title).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label).lineLimit(1)
                    }
                }
                if let path = model.document?.path, model.editedPaths.contains(path) {
                    // The unsaved changes' mark.
                    Circle().fill(c.secondaryLabel).frame(width: 6, height: 6)
                        .help("Unsaved changes")
                        .shellTarget("edited mark")
                }
                chevron(c)
                // The declaration at the insertion point; its menu lists the file's (LanguageViews.swift).
                DocumentItemsMenu(model: model)
            } else {
                Text("No Selection").font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
            }
            Spacer(minLength: 0)
            if let path = model.document?.path, StructuredEditor.hasSourceView(path) { OpenAsSwitch(model: model) }
            // The issue stepper (reference-ui-5.md §6.1) once there are issues.
            if model.issueCounts.errors + model.issueCounts.warnings > 0 {
                HStack(spacing: 8) {
                    Button { model.perform(.previousIssue) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                    }
                    .buttonStyle(.plain).help("Jump to Previous Issue")
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(c.label)
                    Button { model.perform(.nextIssue) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                    }
                    .buttonStyle(.plain).help("Jump to Next Issue")
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: CGFloat(WorkspaceChrome.jumpBarBandHeight))
        // The toolbar's edge: the band's first line (the AppKit window's
        // scroll-edge line under the toolbar).
        .overlay(alignment: .top) { Hairline(color: c.separator) }
        .shellTarget("jump bar")
    }

    func chevron(_ c: ShellColors) -> some View {
        Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(c.tertiaryLabel)
    }
}

/// The debug bar under the editor (`liquid-glass.md` §2.6): 36 points with
/// its separator; the breakpoints toggle at the left, the cursor position
/// and the debug-area toggle at the right.
struct DebugBar: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            Hairline(color: c.separator)
            HStack(spacing: 10) {
                DebugBarItems(model: model)
                Spacer()
                if let branch = model.currentBranch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                        Text(verbatim: branch).font(ShellFonts.small).tracking(ShellFonts.smallTracking).lineLimit(1)
                    }
                    .foregroundStyle(c.secondaryLabel)
                    .help("The current branch")
                    .shellTarget("debug bar branch")
                }
                if let editor = model.editor, model.sourceControl.pane == nil {
                    CaretPositionLabel(controller: SourceEditorController.of(editor), color: c.label)
                        .shellTarget("caret position")
                }
                Button { model.perform(.toggleDebugArea) } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled").font(.system(size: 13))
                        .foregroundStyle(model.isDebugAreaShown ? c.accent : c.secondaryLabel)
                }
                .buttonStyle(.plain)
                .help(model.isDebugAreaShown ? "Hide the Debug Area" : "Show the Debug Area")
                .shellTarget("debug toggle")
            }
            .padding(.leading, 9)
            .padding(.trailing, 10)
            .frame(height: CGFloat(WorkspaceChrome.debugBarHeight) - 1)
        }
        .background(c.content)
        .shellTarget("debug bar")
    }
}

/// The minimap (`reference-ui-5.md` §6.5): the file in miniature, each
/// line a bar from its first to its last ink; a band marks what the editor
/// shows, and dragging moves it. A file taller than the column scrolls with
/// the editor.
struct Minimap: View {
    let controller: SourceEditorController
    let colors: ShellColors

    static let pitch: CGFloat = 1.6
    static let cell: CGFloat = 0.8

    var body: some View {
        let c = controller
        #if !os(Linux)
        let _ = c.redraw.tick
        #endif
        GeometryReader { geo in
            Canvas { ctx, size in
                // Read when drawing: the editor's redraws draw this too.
                let top = c.top, viewport = c.viewport, content = c.contentHeight
                let doc = c.buffer.document
                let u = doc.units
                let (first, count) = window(height: size.height, top: top)
                var y: CGFloat = 4
                for n in first..<min(doc.lineCount, first + count) {
                    let r = doc.lineRange(n)
                    var a = r.lowerBound, z = r.upperBound
                    var lead = 0
                    while a < z, u[a] == 32 || u[a] == 9 {
                        lead += u[a] == 9 ? 4 : 1
                        a += 1
                    }
                    while z > a, u[z - 1] == 32 || u[z - 1] == 9 { z -= 1 }
                    if z > a {
                        let rect = CGRect(x: 6 + CGFloat(lead) * Self.cell, y: y, width: min(CGFloat(z - a) * Self.cell, size.width), height: 1)
                        ctx.fill(Path(rect), with: .color(colors.minimapText))
                    }
                    y += Self.pitch
                }
                // What the editor shows.
                if content > viewport.height {
                    let lh = c.lineHeight
                    let bandTop = 4 + (top / lh - CGFloat(first)) * Self.pitch
                    let bandHeight = viewport.height / lh * Self.pitch
                    ctx.fill(Path(CGRect(x: 0, y: bandTop, width: size.width, height: bandHeight)), with: .color(colors.minimapText.opacity(0.22)))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { v in
                // The line under the pointer goes to the middle of the editor.
                let (first, _) = window(height: geo.size.height, top: c.top)
                let line = CGFloat(first) + (v.location.y - 4) / Self.pitch
                c.scroll(x: c.left, y: line * c.lineHeight - c.viewport.height / 2)
            })
        }
        .frame(width: 112)
        .frame(maxHeight: .infinity)
        .shellTarget("minimap")
    }

    /// The first line the column shows, and how many fit.
    private func window(height: CGFloat, top: CGFloat) -> (first: Int, count: Int) {
        let c = controller
        let count = Int(max(0, height - 8) / Self.pitch) + 1
        let lines = c.buffer.lineCount
        guard lines > count else { return (0, count) }
        let scrollable = max(1, c.contentHeight - c.viewport.height)
        return (Int(CGFloat(lines - count) * min(1, top / scrollable)), count)
    }
}

/// "Line: 12  Col: 8" in the debug bar, drawn from the editor's state when the
/// editor redraws (no view update per keystroke).
struct CaretPositionLabel: View {
    let controller: SourceEditorController
    let color: Color

    var body: some View {
        let c = controller
        #if !os(Linux)
        let _ = c.redraw.tick
        #endif
        return Canvas { ctx, size in
            let b = c.buffer
            let t = Text(verbatim: "Line: \(b.caretLine + 1)  Col: \(b.caretColumn + 1)")
                .font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(color)
            ctx.draw(t, at: CGPoint(x: size.width, y: size.height / 2), anchor: .trailing)
        }
        .frame(width: 130, height: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Insertion Point")
    }
}
