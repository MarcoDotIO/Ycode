import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

// The toolbar's issue capsule and its room-recovery steps, as the AppKit
// IDE draws them (`editor-area.md` G.4, G.8; council rows 134 and 138;
// `cross-platform-parity.md` §2).

/// The issue capsule right after the scheme capsule (G.8, row 138): per
/// kind with issues, errors first, its symbol and its count (symbols only
/// in a narrow window); hidden without issues. Its sizes are
/// `IssueSummary.Capsule`'s, shared with the AppKit IDE. Each part opens
/// the Issue navigator.
struct IssueCapsule: View {
    var summary: IssueSummary
    var symbolsOnly = false
    var action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let k = IssueSummary.Capsule.self
        let parts = summary.parts
        if !parts.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { pair in
                    let part = pair.element
                    if pair.offset > 0 { Color.clear.frame(width: CGFloat(k.gap(symbolsOnly: symbolsOnly)), height: 1) }
                    Button(action: action) {
                        HStack(spacing: CGFloat(k.symbolToCount)) {
                            IssueSymbol(kind: part.kind)
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
                    .help(part.kind.title)
                    .accessibilityLabel(part.kind.title)
                    .shellTarget("tb issues \(part.kind.title.lowercased())")
                }
            }
            .padding(.leading, CGFloat(k.leading))
            .padding(.trailing, CGFloat(symbolsOnly ? k.trailingSymbolOnly : k.trailing))
            .frame(height: CGFloat(k.height))
            .background { GlassCapsule(height: CGFloat(k.height), fill: c.capsuleFill) }
            .fixedSize()
            .shellTarget("tb issues")
        }
    }
}

/// An issue kind's symbol in OpenViews' own drawing: a filled triangle
/// (17.5 × 15.5) with a white exclamation mark for warnings, a filled
/// circle with a white cross for errors and test failures (G.8).
struct IssueSymbol: View {
    var kind: IssueSummary.Kind
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
