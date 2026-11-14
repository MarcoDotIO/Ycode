import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell

/// The editor panes of the Linux IDE, as the macOS IDE's editor area splits
/// them (`specs/ide/editor-area.md` E.2; `cross-platform-parity.md` §4): one
/// pane, or several side by side or one below the other, equal shares, a
/// 1-point divider between them; each pane has its own jump bar (with a
/// close button while split) and shows its own file; the new pane takes
/// focus, a click in a pane focuses it, and the focused pane is the one
/// the window's commands, the find bar and the banner belong to. The split
/// appears in one frame, with no animation (E.2 item 1).
struct EditorPanesView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let p = model.panes
        let c = ShellColors(scheme)
        let panes = Array(p.panes.enumerated())
        let n = CGFloat(panes.count)
        // Equal shares, as the macOS editor area equalizes its splits.
        GeometryReader { geo in
            let along = p.sideBySide ? geo.size.width : geo.size.height
            let share = max(0, (along - (n - 1)) / n).rounded(.down)
            if p.sideBySide {
                HStack(spacing: 0) {
                    ForEach(panes, id: \.element.id) { pair in
                        if pair.offset > 0 { Hairline(color: c.separator, vertical: true) }
                        EditorPaneView(model: model, pane: pair.element, closable: p.isSplit)
                            .frame(width: pair.offset == panes.count - 1 ? max(0, along - (n - 1) * (share + 1)) : share)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(panes, id: \.element.id) { pair in
                        if pair.offset > 0 { Hairline(color: c.separator) }
                        EditorPaneView(model: model, pane: pair.element, closable: p.isSplit)
                            .frame(height: pair.offset == panes.count - 1 ? max(0, along - (n - 1) * (share + 1)) : share)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: p.panes.map(\.id)) { _, ids in PaneControllers.keep(panes: Set(ids)) }
    }
}

/// One editor pane: its jump bar and its 2-point rule, the find bar and the
/// banner when it has focus, then its file: the source editor and minimap,
/// a structured editor, the image editor, or why the file cannot be shown.
struct EditorPaneView: View {
    var model: WorkspaceShellModel
    let pane: ShellEditorPane
    var closable = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let focused = model.panes.isFocused(pane)
        let prefs = ShellPreferences.shared.revision
        let palette = SourcePalette.forAppearance(dark: colorScheme == .dark, theme: Preferences.shared.theme)
        let c = ShellColors(colorScheme)
        VStack(spacing: 0) {
            JumpBar(model: model, pane: closable ? pane : nil, isActive: focused || !closable, closable: closable)
            JumpBarRule()
            if focused, model.findBar.isShown, model.editor != nil {
                EditorFindBarView(bar: model.findBar, model: model)
                Hairline(color: c.separator)
            }
            if focused, let editor = model.editor {
                EditorBanner(model: model, document: editor)
            }
            Group {
                if focused {
                    focusedContent(palette: palette, prefs: prefs, colors: c)
                } else {
                    otherContent(palette: palette, prefs: prefs, colors: c)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background.color)
            .overlay { if focused { LanguageNotice(model: model) } }
            .overlay { if focused { DebugEditorOverlay(model: model) } }   // DebugEditors.swift
        }
        .shellTarget(closable ? "editor pane \(pane.id)" : "editor pane")
    }

    /// The focused pane: the window's document.
    @ViewBuilder func focusedContent(palette: SourcePalette, prefs: Int, colors c: ShellColors) -> some View {
        if let doc = model.document {
            if let s = model.structuredEditor, s.path == doc.path {
                StructuredEditorView(model: model, editor: s)
            } else if let image = model.imagePath {
                ImageEditorView(path: image, palette: palette)
                    .id(image)
            } else if let message = doc.message {
                Text(verbatim: message).font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let editor = model.editor {
                let controller = PaneControllers.controller(pane: pane.id, document: editor, focused: true)
                PreviewEditorSplit(canvas: model.previewCanvas) {   // PreviewCanvasView.swift
                    SourcePaneText(model: model, pane: pane, controller: controller, palette: palette, prefs: prefs, focused: true)
                        .overlay { QuickHelpPopoverLayer(model: model, controller: controller) }
                }
            }
        } else {
            // Nothing open: the editor's background alone, no minimap,
            // separator or scroll lane (editor-area.md E.5, row 74; "No
            // Selection" is the jump bar's).
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.focusPane(pane.id) }
                .shellTarget("no selection")
        }
    }

    /// A pane without focus: its own file, drawn as the focused pane draws
    /// it; a click focuses it.
    @ViewBuilder func otherContent(palette: SourcePalette, prefs: Int, colors c: ShellColors) -> some View {
        switch model.content(of: pane) {
        case .text(let d):
            let controller = PaneControllers.controller(pane: pane.id, document: d, focused: false)
            SourcePaneText(model: model, pane: pane, controller: controller, palette: palette, prefs: prefs, focused: false)
        case .image(let path):
            ImageEditorView(path: path, palette: palette)
                .id(path)
                .contentShape(Rectangle())
                .onTapGesture { model.focusPane(pane.id) }
        case .message(let m):
            Text(verbatim: m).font(Font.system(size: 15)).foregroundStyle(c.secondaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.focusPane(pane.id) }
        case .none:
            Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { model.focusPane(pane.id) }
        }
    }
}

/// A pane's text and minimap: the minimap keeps its share of the pane
/// (E.6) and the text wraps 10 before it, from the pane's own width
/// (row 115).
struct SourcePaneText: View {
    var model: WorkspaceShellModel
    let pane: ShellEditorPane
    let controller: SourceEditorController
    let palette: SourcePalette
    let prefs: Int
    let focused: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let c = ShellColors(colorScheme)
        let paneID = pane.id
        let model = model
        GeometryReader { geo in
            HStack(spacing: 0) {
                SourceEditorView(controller: controller, model: model, palette: palette, preferences: prefs, isFocusedPane: focused)
                    .id("\(paneID)|\(controller.document.path)")
                Minimap(controller: controller, colors: c, palette: palette, width: Minimap.width(forPane: geo.size.width))
            }
        }
        .onAppear {
            controller.onPointerDown = { [weak model] in model?.focusPane(paneID) }
            PaneRestore.paneAppeared(model: model, pane: paneID, controller: controller)   // W7.1
        }
    }
}

/// The controllers of the panes' editors: each pane keeps its own scroll
/// position and caret for each file it shows. The focused pane's is the
/// document's own (`SourceEditorController.of`), so the window's commands,
/// the caret position and Quick Help act on it.
@MainActor
enum PaneControllers {
    private static var table: [String: SourceEditorController] = [:]

    static func controller(pane: Int, document: EditorDocument, focused: Bool) -> SourceEditorController {
        let key = "\(pane)|\(document.path)"
        let c: SourceEditorController
        if let found = table[key], found.document === document {
            c = found
        } else if let own = document.viewState as? SourceEditorController, !table.values.contains(where: { $0 === own }) {
            // The first pane to show a document takes its controller.
            c = own
        } else {
            c = SourceEditorController(document: document)
        }
        table[key] = c
        if focused, (document.viewState as? SourceEditorController) !== c { document.viewState = c }
        return c
    }

    /// The controller of a pane showing `path`, when it has one (W7.1).
    static func existing(pane: Int, path: String) -> SourceEditorController? { table["\(pane)|\(path)"] }

    /// Forgets the controllers of panes that are gone.
    static func keep(panes ids: Set<Int>) {
        table = table.filter { k, _ in Int(k.split(separator: "|").first ?? "").map(ids.contains) ?? false }
    }
}

/// The jump bar's 2-point rule (`EditorMetrics.jumpBarSeparator`), in the
/// macOS editor's colours: #E5E5E5 light, #404040 dark.
struct JumpBarRule: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Rectangle().fill(scheme == .dark ? Color(red: 0x40 / 255, green: 0x40 / 255, blue: 0x40 / 255)
            : Color(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xE5 / 255))
            .frame(height: CGFloat(EditorMetrics.jumpBarSeparator))
    }
}

/// The jump bar's split-pane layout from the pane's leading edge
/// (`editor-area.md` E.2 item 3), and its icons' colours.
enum JumpBarPaneLayout {
    static let closeX = 14.0
    static let closeWidth = 11.0
    static let gridX = 36.0
    static let dividerX = 58.0
    static let pathX = 71.5
    /// The path's rise above the band's centre (macOS `JumpBar.pathRaise`, rounded).
    static let pathRaise = -2.0

    /// A path icon's colour in the focused pane: the navigator's tint for
    /// its kind (package and project blue, folders light blue, Swift
    /// files orange, images blue, other files the accent), as the macOS
    /// jump bar draws it.
    static func tint(_ symbol: String, _ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        func rgb(_ r: Int, _ g: Int, _ b: Int) -> Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
        let blue = dark ? rgb(0x0A, 0x84, 0xFF) : rgb(0x00, 0x7A, 0xFF)
        // The navigator's measured tints (`FileGlyphs.tint`, round 9), as
        // the macOS jump bar (`JumpBar.iconTint(symbol:title:)`).
        let t: WorkspaceChrome.IconTint? = switch symbol {
        case "folder.badge.gearshape", "shippingbox", "square.stack.3d.up", WorkspaceChrome.fileSymbol("a.png"), WorkspaceChrome.fileSymbol("a.xcassets"):
            .blue
        case "folder.fill", "folder": .lightBlue
        case WorkspaceChrome.fileSymbol("a.swift"): .orange
        default: nil
        }
        return t.flatMap(FileGlyphs.tint).map { FileGlyphView.color($0, dark: dark) } ?? blue
    }
}

/// The issue stepper at the jump bar's right end (`IssueStepper`; G.8,
/// row 139): ‹, the workspace's most severe issue kind, ›; shown whenever
/// the workspace has errors or warnings (the toolbar capsule's counts).
struct IssueStepperView: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let counts = model.issueCounts
        if let kind = IssueStepper.kind(errors: counts.errors, warnings: counts.warnings) {
            // H.5 (row 161): #7F7F7F in light, #9D9D9D in dark.
            let chevron = IssueSymbol.color(IssueStepper.chevronColor(dark: scheme == .dark))
            HStack(spacing: CGFloat(IssueStepper.spacing)) {
                Button { model.perform(.previousIssue) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11)).foregroundStyle(chevron)
                        .frame(width: CGFloat(IssueStepper.chevronWidth), height: CGFloat(IssueStepper.chevronHeight))
                }
                .buttonStyle(.plain).help("Show Previous Issue")
                IssueKindSymbol(kind: kind)
                    .help(kind == .error ? "Errors" : "Issues")
                Button { model.perform(.nextIssue) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(chevron)
                        .frame(width: CGFloat(IssueStepper.chevronWidth), height: CGFloat(IssueStepper.chevronHeight))
                }
                .buttonStyle(.plain).help("Show Next Issue")
            }
            .frame(width: CGFloat(IssueStepper.width))
            .shellTarget("issue stepper")
        }
    }
}

/// An issue kind's symbol in its colours: a yellow triangle with a white
/// mark, a red circle with a white cross (the symbol's mark is cut out of
/// the fill, so white shows through it).
struct IssueKindSymbol: View {
    let kind: IssueStepper.Kind
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let w = CGFloat(IssueStepper.symbolWidth), h = CGFloat(IssueStepper.symbolHeight)
        ZStack {
            Rectangle().fill(Color.white).frame(width: w * 0.45, height: h * 0.55).offset(y: kind == .warning ? h * 0.12 : 0)
            Image(systemName: kind.symbol).resizable()
                .foregroundStyle(IssueSymbol.color(IssueStepper.symbolFill(kind, dark: scheme == .dark)))
                .frame(width: w, height: h)
        }
        .frame(width: w, height: h)
    }
}

/// The image editor (`editor-area.md` §C.6, E.3, F.8; `ImageEditorMetrics`),
/// as the macOS IDE's: the image scaled down to fit and centred on the
/// editor's background, a flat button under it that opens the file in the
/// desktop's image viewer. The editor shows at once; the image when the
/// file has been read (in the same frame for an ordinary file);
/// "Loading…" only if it still has not after 450 ms.
struct ImageEditorView: View {
    let path: String
    let palette: SourcePalette
    @State private var info: ShellImageFile?
    @State private var isReady: Bool
    @State private var showsLoading = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL

    init(path: String, palette: SourcePalette) {
        self.path = path
        self.palette = palette
        // An ordinary file is read before the editor shows (a header of a
        // few hundred bytes), so the swap is one frame with the image.
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? Int.max
        if size <= 24 * 1024 * 1024 {
            _info = State(initialValue: ShellImageFile.read(path: path))
            _isReady = State(initialValue: true)
        } else {
            _isReady = State(initialValue: false)
        }
    }

    /// The title of the button (the macOS IDE names its image viewer).
    static let openTitle = "Open with Image Viewer"

    var decodable: Bool { ShellImageFile.decodableExtensions.contains((path as NSString).pathExtension.lowercased()) }

    var body: some View {
        let c = ShellColors(scheme)
        GeometryReader { geo in
            let box = ImageEditorMetrics.fitBox(width: Double(geo.size.width), height: Double(geo.size.height))
            ZStack(alignment: .topLeading) {
                palette.background.color
                if isReady, let info, decodable {
                    let r = ImageEditorMetrics.fittedRect(imageWidth: Double(info.pointSize.width), imageHeight: Double(info.pointSize.height), box: box)
                    Image((path as NSString).lastPathComponent.split(separator: ".").dropLast().joined(separator: "."),
                          bundle: Bundle(path: (path as NSString).deletingLastPathComponent))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: CGFloat(r.width), height: CGFloat(r.height))
                        .offset(x: CGFloat(r.x), y: CGFloat(r.y))
                        .accessibilityLabel((path as NSString).lastPathComponent)
                        .shellTarget("image")
                } else if isReady || showsLoading {
                    Text(verbatim: isReady ? ImageEditorMetrics.failureText : "Loading…")
                        .font(.system(size: 13)).foregroundStyle(c.secondaryLabel)
                        .frame(width: CGFloat(box.width), height: CGFloat(box.height))
                        .offset(x: CGFloat(box.x), y: CGFloat(box.y))
                }
                openButton(c)
                    .frame(width: geo.size.width)
                    .offset(y: geo.size.height - CGFloat(ImageEditorMetrics.buttonBottomGap + ImageEditorMetrics.buttonHeight))
            }
        }
        .task(id: path) {
            guard !isReady else { return }
            let path = path
            async let read = Task.detached { ShellImageFile.read(path: path) }.value
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(ImageEditorMetrics.loadingDelay * 1e9))
                if !isReady { showsLoading = true }
            }
            info = await read
            isReady = true
            showsLoading = false
        }
        .shellTarget("image editor")
    }

    func openButton(_ c: ShellColors) -> some View {
        let fill = scheme == .dark ? Color(white: 0.25) : Color(white: 0xEC / 255)
        return Button { openURL(URL(fileURLWithPath: path)) } label: {
            Text(verbatim: Self.openTitle).font(.system(size: CGFloat(ImageEditorMetrics.buttonFontSize))).foregroundStyle(c.label)
                .padding(.horizontal, CGFloat(ImageEditorMetrics.buttonTitleInset))
                .frame(height: CGFloat(ImageEditorMetrics.buttonHeight))
                .background(RoundedRectangle(cornerRadius: CGFloat(ImageEditorMetrics.buttonCornerRadius)).fill(fill))
        }
        .buttonStyle(.plain)
        .shellTarget("open with image viewer")
    }
}
