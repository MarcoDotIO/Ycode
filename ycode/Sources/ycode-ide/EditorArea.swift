import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell
import YcodeSyntax

/// The editor area (`metrics.md` §4): the jump bar (a 31-point band and
/// its separator), the open file read-only with `YcodeSyntax` highlighting
/// (L1; EditorKit replaces it in L2) and the minimap, then the debug bar.
struct EditorArea: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = SourcePalette.forAppearance(dark: colorScheme == .dark, theme: Preferences.shared.theme)
        let c = ShellColors(colorScheme)
        VStack(spacing: 0) {
            JumpBar(model: model)
            Hairline(color: c.separator)
            Group {
                if let doc = model.document {
                    if let message = doc.message {
                        Text(verbatim: message).font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        HStack(spacing: 0) {
                            SourceView(document: doc, markedLine: model.markedLine, revealCount: model.revealCount, palette: palette)
                            Hairline(color: c.separator, vertical: true)
                            Minimap(document: doc, palette: palette, colors: c)
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
                chevron(c)
                Text(verbatim: WorkspaceChrome.jumpBarNoSymbol).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
            } else {
                Text("No Selection").font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
            }
            Spacer(minLength: 0)
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
                Image(systemName: "tag").font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
                    .help("Activate Breakpoints")
                Spacer()
                if model.document != nil {
                    Text(verbatim: "Line: \(model.markedLine ?? 1)  Col: 1").font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
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

/// The source text: a 48-point gutter with the line numbers (10 points,
/// right-aligned 28 from its start), then each line's colored runs from 9
/// points after the gutter, 15 points apart, built lazily; the marked line
/// has the current-line color and is scrolled to.
struct SourceView: View {
    let document: SourceDocument
    let markedLine: Int?
    let revealCount: Int
    let palette: SourcePalette

    static let lineHeight: CGFloat = 15
    /// The numbers end 25 points into the gutter (the AppKit gutter's
    /// numbers end there: right-aligned in its 36-point number column, less
    /// its padding).
    static let numberWidth: CGFloat = 26
    /// Where the text's first glyph is drawn after its layout origin here
    /// (the run's side bearing and the line's leading padding); taken off the
    /// inset so the ink starts where the AppKit editor's does.
    static let glyphOrigin: CGFloat = 1

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.lines) { line in
                        row(line)
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: revealCount) { _, _ in
                proxy.scrollTo(markedLine ?? 1, anchor: markedLine == nil ? .top : .center)
            }
            .onChange(of: document.path) { _, _ in
                proxy.scrollTo(markedLine ?? 1, anchor: markedLine == nil ? .top : .center)
            }
        }
        .shellTarget("source")
    }

    func row(_ line: SourceLine) -> some View {
        let current = line.number == (markedLine ?? 1)
        return HStack(alignment: .center, spacing: 0) {
            Text(verbatim: "\(line.number)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(current ? palette.foreground.color : palette.lineNumber.color)
                .frame(width: Self.numberWidth, alignment: .trailing)
            Color.clear.frame(width: CGFloat(WorkspaceChrome.gutterWidth) - Self.numberWidth, height: 1)
            HStack(spacing: 0) {
                text(line)
                    .font(ShellFonts.editor(CGFloat(Preferences.shared.theme.fontSize)))
                    .lineLimit(1)
                    .padding(.leading, CGFloat(WorkspaceChrome.textInset) - Self.glyphOrigin)
                Spacer(minLength: 0)
            }
            .frame(height: Self.lineHeight)
            .background(current ? palette.currentLine.color : Color.clear)
        }
        .frame(height: Self.lineHeight)
        .id(line.number)
    }

    func text(_ line: SourceLine) -> Text {
        guard !line.runs.isEmpty else { return Text(verbatim: " ") }
        return line.runs.reduce(Text(verbatim: "")) { t, r in
            let piece = Text(verbatim: r.text).foregroundStyle(palette.color(r.role).color)
            return t + (r.role == .keyword ? piece.bold() : piece)
        }
    }
}

/// The minimap (`reference-ui-5.md` §6.5): the file in miniature, 13.3 %
/// of the editor's width, each line's runs as short bars.
struct Minimap: View {
    let document: SourceDocument
    let palette: SourcePalette
    let colors: ShellColors

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let pitch: CGFloat = 1.6, cw: CGFloat = 0.8
                var y: CGFloat = 4
                for line in document.lines {
                    var x: CGFloat = 6
                    for r in line.runs {
                        let n = CGFloat(r.text.count)
                        let lead = CGFloat(r.text.prefix { $0 == " " }.count)
                        let body = n - lead - CGFloat(r.text.reversed().prefix { $0 == " " }.count)
                        if body > 0 {
                            let rect = CGRect(x: x + lead * cw, y: y, width: body * cw, height: 1)
                            if rect.minX < size.width { ctx.fill(Path(rect), with: .color(colors.minimapText)) }
                        }
                        x += n * cw
                    }
                    y += pitch
                    if y > size.height { break }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(width: 112)
        .frame(maxHeight: .infinity)
        .shellTarget("minimap")
    }
}
