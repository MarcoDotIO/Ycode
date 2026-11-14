import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// The toolbar's issue capsule and its room-recovery steps, as the AppKit
// IDE draws them (`editor-area.md` G.4, G.8; council rows 134 and 138;
// `cross-platform-parity.md` §2).

/// The issue capsule right after the scheme capsule (G.8, row 138): per
/// kind with issues, errors first, its symbol and its count; in a narrow
/// window the most severe kind's glyph alone (an error's octagon) in a
/// round capsule 39 wide (row 198); hidden without issues. Its sizes are
/// `IssueSummary.Capsule`'s, shared with the AppKit IDE. Each part opens
/// the Issue navigator.
struct IssueCapsule: View {
    var summary: IssueSummary
    var symbolsOnly = false
    /// Under the merge alert or sheet (the window draws at the text tone):
    /// the symbols and counts at the glyphs' disabled tone instead
    /// (`workspace-window.md` W7.2, row 188), as the AppKit IDE dims them.
    var underSheet = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let k = IssueSummary.Capsule.self
        let parts = IssueSummary.Capsule.shownParts(summary.parts, symbolsOnly: symbolsOnly)
        let symbolX = CGFloat(k.collapsedSymbolX())
        if !parts.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { pair in
                    let part = pair.element
                    if pair.offset > 0 { Color.clear.frame(width: CGFloat(k.gap(symbolsOnly: symbolsOnly)), height: 1) }
                    Button(action: action) {
                        HStack(spacing: CGFloat(k.symbolToCount)) {
                            IssueSymbol(kind: part.kind, collapsed: symbolsOnly)
                            if !symbolsOnly {
                                Text(verbatim: "\(part.count)").font(.system(size: CGFloat(k.countSize)))
                                    .foregroundStyle(IssueSymbol.color(k.countColor(dark: scheme == .dark))).lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .frame(height: CGFloat(k.height))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(symbolsOnly ? summary.parts.map { "\($0.count) \($0.kind.title)" }.joined(separator: ", ") : part.kind.title)
                    .accessibilityLabel(part.kind.title)
                    .shellTarget("tb issues \(part.kind.title.lowercased())")
                }
            }
            .padding(.leading, symbolsOnly ? symbolX : CGFloat(k.leading))
            .padding(.trailing, symbolsOnly ? CGFloat(k.collapsedWidth - k.symbolWidth) - symbolX : CGFloat(k.trailing))
            .frame(height: CGFloat(k.height))
            .opacity(underSheet ? MergeModalTone.glyph / MergeModalTone.text : 1)   // the parts only, not the glass
            .background { GlassCapsule(height: CGFloat(k.height), fill: c.capsuleFill) }
            .fixedSize()
            .shellTarget("tb issues")
        }
    }
}

/// An issue kind's symbol in OpenViews' own drawing: a filled triangle
/// (17.5 × 15.5) with a white exclamation mark for warnings, a filled
/// circle with a white cross for errors and test failures (G.8); in the
/// collapsed capsule an error is a filled octagon with the cross (row 198).
struct IssueSymbol: View {
    var kind: IssueSummary.Kind
    var collapsed = false
    @Environment(\.colorScheme) private var scheme

    static func color(_ rgb: UInt32) -> Color {
        Color(.sRGB, red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    var body: some View {
        let fill = Self.color(kind.fill(dark: scheme == .dark))
        let w = CGFloat(IssueSummary.Capsule.symbolWidth)
        ZStack {
            switch kind {
            case .warning:
                IssueTriangle().fill(fill)
                    .overlay { IssueTriangle().stroke(fill, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)) }
                    .frame(width: w - 1.5, height: 14)
                VStack(spacing: 1.6) {
                    Capsule(style: .continuous).fill(Color.white).frame(width: 1.9, height: 6.2)
                    Circle().fill(Color.white).frame(width: 2.1, height: 2.1)
                }
                .offset(y: 1.6)
            case .error where collapsed:
                IssueOctagon().fill(fill).frame(width: 15.5, height: 15.5)
                IssueCross().stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 6.5, height: 6.5)
            case .error, .testFailure:
                Circle().fill(fill).frame(width: 15.5, height: 15.5)
                IssueCross().stroke(Color.white, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 6.5, height: 6.5)
            }
        }
        .frame(width: w, height: 15.5)
    }
}

/// A triangle pointing up, filling its frame.
struct IssueTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A regular octagon filling its frame (flat top and sides).
struct IssueOctagon: Shape {
    func path(in r: CGRect) -> Path {
        let k = min(r.width, r.height) / (2 + CGFloat(2).squareRoot())   // a regular octagon's corner cut in its square
        var p = Path()
        p.move(to: CGPoint(x: r.minX + k, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + k))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
        p.addLine(to: CGPoint(x: r.maxX - k, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - k))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + k))
        p.closeSubpath()
        return p
    }
}

/// Two diagonals across the frame.
struct IssueCross: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        return p
    }
}

/// The toolbar's overflow control (G.4): a glass circle with "»" whose
/// menu holds the items that left the toolbar (the editor modes, as
/// "Editor Modes" with its three modes), at full size from its first frame.
struct ToolbarOverflowMenu: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        Menu {
            Menu("Editor Modes") {
                Button("Canvas") { model.perform(.toggleCanvas) }.disabled(!model.isEnabled(.toggleCanvas))
                Button("Assistant") {}.disabled(true)
                Button("Code Review") {}.disabled(true)
            }
        } label: {
            Text(verbatim: "\u{00BB}").font(.system(size: 17)).foregroundStyle(c.toolbarIcon)
                .frame(width: CGFloat(WorkspaceChrome.toolbarItemHeight), height: CGFloat(WorkspaceChrome.toolbarItemHeight))
                .background { Circle().fill(c.capsuleFill) }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show more toolbar items")
        .shellTarget("tb overflow")
    }
}

/// Add Editor and Editor Options in one capsule (81 wide with its rim, as
/// the AppKit toolbar's). Add Editor is a pull-down, as the AppKit item's
/// (`EditorOptionsMenu.addItems`): Add Editor Tab (the Linux IDE has no
/// editor tabs), Add Editor Pane on Right, Add Editor Pane Below
/// (WorkspaceShellModel+Panes.swift). Editor Options is not in the beta.
struct AddEditorGroup: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    static let segmentWidth: CGFloat = 31.5

    var body: some View {
        let c = ShellColors(scheme)
        let canSplit = model.isEnabled(.splitEditor)
        let w = Self.segmentWidth + 6, h = CGFloat(WorkspaceChrome.toolbarItemHeight)
        HStack(spacing: 0) {
            Menu {
                Button("Add Editor Tab") {}.disabled(true)
                Button("Add Editor Pane on Right") { model.perform(.splitEditor) }.disabled(!canSplit)
                Button("Add Editor Pane Below") { model.perform(.splitEditorBelow) }.disabled(!model.isEnabled(.splitEditorBelow))
            } label: {
                Image(systemName: WorkspaceChrome.addEditor.symbols[0]).font(.system(size: 15)).foregroundStyle(c.toolbarIcon)
                    .opacity(canSplit ? 1 : ShellColors.disabledGlyphOpacity)
                    .frame(width: w, height: h)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(WorkspaceChrome.addEditor.toolTips[0])
            .accessibilityLabel("Add Editor")
            .shellTarget("tb add editor")
            Button {} label: {
                Image(systemName: WorkspaceChrome.editorOptions.symbols[0]).font(.system(size: 15)).foregroundStyle(c.toolbarIcon)
                    .opacity(ShellColors.disabledGlyphOpacity)
                    .frame(width: w, height: h)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .help(ShellText.notInBeta(WorkspaceChrome.editorOptions.toolTips[0]))
            .accessibilityLabel("Editor Options")
            .shellTarget("tb editor options")
        }
        .padding(.horizontal, 4)
        .background { GlassCapsule(fill: c.capsuleFill) }
    }
}

// MARK: The scheme capsule's glyphs (council round 8, row 199)

/// The scheme's glyph: its target's app icon (the asset catalog's picture,
/// rounded) or Ycode's plain app tile, as the AppKit capsule draws them
/// (`SchemeCapsuleIcons`, `SchemeAppTile`).
struct SchemeGlyph: View {
    var appIcon: URL?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let side = CGFloat(SchemeAppTile.side), corner = CGFloat(SchemeAppTile.corner)
        Group {
            if let appIcon, let bundle = Bundle(path: appIcon.deletingLastPathComponent().path) {
                Image(appIcon.deletingPathExtension().lastPathComponent, bundle: bundle)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            } else {
                let g = SchemeAppTile.gradient(dark: scheme == .dark)
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(LinearGradient(colors: [IssueSymbol.color(g.top), IssueSymbol.color(g.bottom)], startPoint: .top, endPoint: .bottom))
                    RoundedRectangle(cornerRadius: corner, style: .continuous).stroke(IssueSymbol.color(g.rim), lineWidth: 0.5)
                    ForEach(Array(SchemeAppTile.bars.enumerated()), id: \.offset) { pair in
                        let b = pair.element
                        Capsule(style: .continuous).fill(Color.white.opacity(0.85))
                            .frame(width: CGFloat(b.w), height: CGFloat(b.h))
                            .offset(x: CGFloat(b.x), y: CGFloat(b.y))
                    }
                }
                .frame(width: side, height: side)
            }
        }
        .frame(width: 16, height: 16)
        .accessibilityLabel(appIcon == nil ? "App" : "App Icon")
    }
}

/// This computer's destination glyph: a laptop (Ycode's own drawing, the
/// toolkit has no laptop symbol) tinted the system blue on a laptop, the
/// desktop symbol otherwise (row 199, as the AppKit capsule).
struct HostDestinationGlyph: View {
    var form = SchemeCapsuleIcons.currentHostForm
    var fallbackColor: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if form == .laptop {
            let tint = IssueSymbol.color(SchemeCapsuleIcons.hostGlyphTint(.laptop, dark: scheme == .dark) ?? 0)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).stroke(tint, lineWidth: 1.3)
                    .frame(width: 12, height: 8.5)
                    .offset(y: -2.6)
                Capsule(style: .continuous).fill(tint).frame(width: 16, height: 1.6)
            }
            .frame(width: 16, height: 13)
            .accessibilityLabel("My Mac")
        } else {
            Image(systemName: form.symbol).font(.system(size: 12)).foregroundStyle(fallbackColor)
        }
    }
}
