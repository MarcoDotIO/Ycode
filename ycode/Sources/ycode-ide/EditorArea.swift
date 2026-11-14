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

    /// The editor panes (EditorPanes.swift), then the debug bar.
    @ViewBuilder var sourceEditor: some View {
        VStack(spacing: 0) {
            EditorPanesView(model: model)
            DebugBar(model: model)
        }
        .shellTarget("editor")
    }
}

/// The path of a pane's file (`reference-ui-6.md` §4.1, `editor-area.md`
/// E.2, as the macOS IDE's jump bar): in a split, the pane's close button,
/// then Related Items and a divider; workspace › groups › file (names as
/// the navigator shows them), then the symbol ("No Selection" outside a
/// declaration); 11 points. The focused pane draws its path in the label
/// colour with the icons in their kinds' colours, the other panes in grey;
/// a middle component gives way first. The issue stepper at the right end
/// (`IssueStepper`, G.8).
struct JumpBar: View {
    var model: WorkspaceShellModel
    /// The pane (nil: the focused one).
    var pane: ShellEditorPane?
    var isActive = true
    var closable = false
    @Environment(\.colorScheme) private var scheme

    var path: String? { pane.map(\.path) ?? model.document?.path }
    var isFocusedPane: Bool { pane.map { model.panes.isFocused($0) } ?? true }

    var body: some View {
        let c = ShellColors(scheme)
        let palette = SourcePalette.forAppearance(dark: scheme == .dark, theme: Preferences.shared.theme)
        HStack(spacing: 2) {
            if closable, let pane {
                // +14 to +25: the pane's close button; Related Items at +36,
                // a divider at +58, the path from +71.5 (E.2 item 3).
                Button { model.closePane(pane.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(c.secondaryLabel)
                        .frame(width: CGFloat(JumpBarPaneLayout.closeWidth))
                }
                .buttonStyle(.plain).help("Close this Editor Pane")
                .padding(.leading, CGFloat(JumpBarPaneLayout.closeX) - 6)
                .shellTarget("jump bar close")
            }
            // Ycode's grid, 13 × 13 at 13 in (round 10, row 247; JumpBarLeading).
            JumpBarGridGlyph()
                .padding(.leading, closable ? CGFloat(JumpBarPaneLayout.gridX - JumpBarPaneLayout.closeX - JumpBarPaneLayout.closeWidth) - 2
                    : CGFloat(JumpBarLeading.gridX) - 6)
                .help("Navigate to Related Items")
            if !closable, path != nil {
                // With a file: the 1 × 12 divider at 35, the path's ink from 49.
                JumpBarDividerLine()
                    .padding(.leading, CGFloat(JumpBarLeading.dividerX - JumpBarLeading.gridX - JumpBarLeading.gridSide) - 2)
                    .padding(.trailing, CGFloat(JumpBarLeading.pathX - JumpBarLeading.dividerX - JumpBarLeading.dividerWidth - JumpBarEmpty.pathLead) - 2)
            }
            if closable {
                Rectangle().fill(c.separator).frame(width: 1, height: 14)
                    .padding(.leading, CGFloat(JumpBarPaneLayout.dividerX - JumpBarPaneLayout.gridX - JumpBarLeading.gridSide) - 2)
                    .padding(.trailing, CGFloat(JumpBarPaneLayout.pathX - JumpBarPaneLayout.dividerX - 1) - 2)
            }
            if path != nil {
                // The path, spaced and collapsed by the shared model
                // (JumpBarPath.swift; H.4, rows 143–145): the last item is
                // the declaration at the insertion point (its menu lists the
                // file's, LanguageViews.swift), "No Selection" for an image,
                // and in a pane without focus what it showed last.
                let focusedLast = isFocusedPane && (model.editor != nil || model.imagePath != nil)
                let lastTitle = isFocusedPane ? nil : pane?.symbolTitle
                JumpBarPathView(components: model.jumpPath(for: path), isActive: isActive,
                                edited: path.map { model.editedPaths.contains($0) } ?? false, background: palette.background.color,
                                last: {
                                    if focusedLast, model.editor != nil {
                                        DocumentItemsMenu(model: model, isActive: isActive)
                                    } else {
                                        Text(verbatim: lastTitle ?? WorkspaceChrome.jumpBarNoSymbol).font(ShellFonts.small)
                                            .foregroundStyle(isActive ? c.label : c.secondaryLabel).lineLimit(1).fixedSize()
                                            .shellTarget("jump bar symbol")
                                    }
                                }, hasLast: focusedLast || lastTitle != nil, fileName: path.map { ($0 as NSString).lastPathComponent })
            } else {
                // No file open: a 1-point divider after the grid button, then
                // "No Selection" in the bar's text colour from 47.5 in
                // (editor-area.md F.10, row 111).
                HStack(spacing: 0) {
                    if !closable {
                        Rectangle().fill(c.separator).frame(width: 1, height: 14)
                            .padding(.leading, CGFloat(JumpBarEmpty.dividerX - JumpBarLeading.gridX - JumpBarLeading.gridSide) - 2)
                    }
                    Text("No Selection").font(ShellFonts.small).foregroundStyle(c.label)
                        .padding(.leading, closable ? 0 : CGFloat(JumpBarEmpty.textX - JumpBarEmpty.dividerX - 1))
                        .offset(y: CGFloat(JumpBarPaneLayout.pathRaise))
                }
                Spacer(minLength: 0)
            }
            if isFocusedPane, let path, StructuredEditor.hasSourceView(path) { OpenAsSwitch(model: model) }
            // The issue stepper whenever the workspace has issues (G.8, row 139).
            IssueStepperView(model: model)
        }
        .padding(.leading, 6)
        .padding(.trailing, CGFloat(IssueStepper.trailingInset))
        .frame(height: CGFloat(WorkspaceChrome.jumpBarBandHeight))
        .background(palette.background.color)
        // The toolbar's edge: the band's first line (the AppKit window's
        // scroll-edge line under the toolbar).
        .overlay(alignment: .top) { Hairline(color: c.separator) }
        .shellTarget(pane == nil || isFocusedPane ? "jump bar" : "jump bar \(pane?.id ?? 0)")
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
                // "Line: N  Col: N", the branch, then the debug-area toggle
                // (grey in both states), as the AppKit bar (parity §6).
                if let editor = model.editor, model.sourceControl.pane == nil {
                    CaretPositionLabel(controller: SourceEditorController.of(editor), color: c.label)
                        .shellTarget("caret position")
                }
                if let branch = model.currentBranch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                        Text(verbatim: branch).font(ShellFonts.small).tracking(ShellFonts.smallTracking).lineLimit(1)
                    }
                    .foregroundStyle(c.barIcon)
                    .help("The current branch")
                    .shellTarget("debug bar branch")
                }
                Button { model.perform(.toggleDebugArea) } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled").font(.system(size: 13))
                        .foregroundStyle(c.barIcon)
                }
                .buttonStyle(.plain)
                .help(model.isDebugAreaShown ? "Hide the Debug Area" : "Show the Debug Area")
                .shellTarget("debug toggle")
            }
            .padding(.leading, 13)   // the tag at x 304 with the editor at 290 (F.9)
            .padding(.trailing, 10)
            .frame(height: CGFloat(WorkspaceChrome.debugBarHeight) - 1)
        }
        .background(c.content)
        .shellTarget("debug bar")
    }
}

/// The minimap, as the macOS editor draws it (`editor-area.md` §C.5, §D.6,
/// E.6, G.3; checklist rows 77 and 116): a 1-point separator, then the text
/// at 1/6 scale, one 2-point bar on a 3-point pitch per **visual** row (the
/// text's own wrapping), in its tokens' colours at about 35 %, with a shade
/// over what the editor shows; it scrolls in proportion to the editor when
/// the file is taller than it. It meets the 11-point scroll lane at the
/// pane's right edge (the macOS editor's scroller), so the text column is
/// as wide as the macOS editor's.
struct Minimap: View {
    let controller: SourceEditorController
    let colors: ShellColors
    let palette: SourcePalette
    var width: CGFloat = 143

    /// The column (separator, minimap and lane) for an editor pane `pane`
    /// points wide (`EditorMetrics.minimapWidth`, as the macOS editor).
    static func width(forPane pane: CGFloat) -> CGFloat {
        CGFloat(EditorMetrics.minimapWidth(editorWidth: Double(pane)) + EditorMetrics.minimapSeparator + EditorMetrics.scrollerLane)
    }

    var lane: CGFloat { CGFloat(EditorMetrics.scrollerLane - EditorMetrics.minimapStrip) }
    var pitch: CGFloat { CGFloat(EditorMetrics.minimapLinePitch) }
    var scale: CGFloat { CGFloat(EditorMetrics.minimapScale) }
    var topInset: CGFloat { SourceEditorController.topInset * scale }

    var body: some View {
        let c = controller
        #if !os(Linux)
        let _ = c.redraw.tick
        #endif
        GeometryReader { geo in
            Canvas { ctx, size in
                // Read when drawing: the editor's redraws draw this too.
                let count = c.minimapRowCount
                let sep = CGFloat(EditorMetrics.minimapSeparator)
                let content = CGFloat(count) * pitch + topInset
                let offset = self.offset(content: content, height: size.height)
                let barWidth = size.width - lane
                // What the editor shows: a full-width shade.
                if c.contentHeight > c.viewport.height {
                    ctx.fill(Path(CGRect(x: sep, y: c.top * scale - offset, width: barWidth - sep, height: c.viewport.height * scale)),
                             with: .color(colors.label.opacity(0.07)))
                }
                let inset = sep + CGFloat(EditorMetrics.minimapTextInset)
                let cw = c.layout.advance * scale
                let bar = CGFloat(EditorMetrics.minimapBarHeight)
                let ink = EditorMetrics.minimapInk
                let first = max(0, Int((offset - topInset) / pitch))
                let last = min(count, Int((offset + size.height) / pitch) + 1)
                if first < last {
                    for i in first..<last {
                        let y = topInset + CGFloat(i) * pitch - offset
                        for r in c.minimapBars(row: i) {
                            let x = inset + CGFloat(r.column) * cw
                            guard x < barWidth else { continue }
                            ctx.fill(Path(CGRect(x: x, y: y, width: min(CGFloat(r.length) * cw, barWidth - x), height: bar)),
                                     with: .color(palette.color(r.key).color.opacity(ink)))
                        }
                    }
                }
                ctx.fill(Path(CGRect(x: 0, y: 0, width: sep, height: size.height)), with: .color(colors.separator))
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onChanged { v in
                // The document point under the pointer goes to the middle of the editor.
                let content = CGFloat(c.minimapRowCount) * pitch + topInset
                let docY = (v.location.y + offset(content: content, height: geo.size.height)) / scale
                c.scroll(x: c.left, y: docY - c.viewport.height / 2)
            })
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Minimap")
        .shellTarget("minimap")
    }

    /// The minimap's own scroll offset (`EditorMetrics.minimapOffset`).
    func offset(content: CGFloat, height: CGFloat) -> CGFloat {
        let c = controller
        let fraction = c.top / max(1, c.contentHeight - c.viewport.height)
        return CGFloat(EditorMetrics.minimapOffset(contentHeight: Double(content), viewHeight: Double(height), fraction: Double(fraction)))
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

/// The empty jump bar's layout from the bar's leading edge (`editor-area.md`
/// F.10): the grid button, the divider, "No Selection" from 47.5.
enum JumpBarEmpty {
    static let dividerX = 33.5
    static let textX = 47.5
    /// From the path view's start to its first icon's ink (measured on the
    /// x86 parity shots).
    static let pathLead = 0.0
}

/// The Related Items grid (round 10, row 247): Ycode's four 6 × 6
/// squares in the reference's grey, on the pixel grid, as the macOS
/// `JumpBarGridButton`.
struct JumpBarGridGlyph: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let v = JumpBarLeading.gridColor(dark: scheme == .dark)
        FileGlyphView(drawing: JumpBarLeading.grid,
                      color: Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255))
            .accessibilityLabel("Related Items")
            .shellTarget("jump bar grid")
    }
}

/// The 1 × 12 divider after the grid (#E6E6E6 / #3C3C3C), as the macOS
/// `JumpBarDividerView`.
struct JumpBarDividerLine: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let v = JumpBarLeading.dividerColor(dark: scheme == .dark)
        Rectangle().fill(Color(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255))
            .frame(width: CGFloat(JumpBarLeading.dividerWidth), height: CGFloat(JumpBarLeading.dividerHeight))
            .shellTarget("jump bar divider")
    }
}
