import Foundation
import SwiftUI
import YcodeEditorKit
import YcodeIDECore
import YcodeIDEShell
import YcodeLanguage
#if os(Linux)
import OVPlatform
#endif

// The language features' views (`specs/ide/language.md` §Features,
// `specs/ide/refactoring.md`): Quick Help in a popover and in the
// inspector, the rename sheet with its preview, and a short notice when a
// request finds nothing. The state is `WorkspaceShellModel.languageFeatures`.

/// Quick Help's sections in the order of `reference-ui-4.md` §7: the title
/// and summary, the declaration box, the defining file, Parameters, Return
/// Value, Throws, Discussion, callouts, then "Open in Developer
/// Documentation". The inspector and the popover both show it.
struct QuickHelpContent: View {
    var document: QuickHelpDocument
    var model: WorkspaceShellModel
    /// The popover's look (`popovers.md` §4.2): a borderless 385-wide
    /// declaration box with modifiers on their own line, the file's glyph.
    var popover = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if popover && document.isModule { moduleBody } else { symbolBody }
    }

    var symbolBody: some View {
        let c = ShellColors(scheme)
        let d = document
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: d.title).font(Font.system(size: 15, weight: .bold)).foregroundStyle(c.label)
                .shellTarget("quickhelp title")
            if let s = d.summary { paragraph(s, c) }
            if !d.declaration.isEmpty, popover {
                QuickHelpDeclarationBox(declaration: d.declaration)
                    .contextMenu { Button("Copy") { ShellPasteboard.copy(d.declaration) } }
                    .padding(.bottom, CGFloat(QuickHelpPopoverMetrics.declarationToFile - 8))
                    .shellTarget("quickhelp declaration")
            } else if !d.declaration.isEmpty {
                Text(verbatim: d.declaration).font(Font.system(size: 11, design: .monospaced)).foregroundStyle(c.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.tertiaryLabel.opacity(0.12))
                            .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(c.tertiaryLabel.opacity(0.35), lineWidth: 1) }
                    }
                    // The macOS IDE's declaration is selectable text with
                    // the text menu's Copy; here the box's own menu copies it.
                    .contextMenu { Button("Copy") { ShellPasteboard.copy(d.declaration) } }
                    .shellTarget("quickhelp declaration")
            }
            if let f = d.file, d.showsFileLink {
                Button { model.openQuickHelpFile(f) } label: {
                    HStack(spacing: 4) {
                        if popover {
                            // The file's own glyph in its type's tint (§4.2).
                            FileGlyphImage(fileName: (f as NSString).lastPathComponent, box: (11.5, 11.5)).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "doc").font(.system(size: 11))
                        }
                        Text(verbatim: (f as NSString).lastPathComponent).font(ShellFonts.small)
                    }
                    .foregroundStyle(c.accent)
                }
                .buttonStyle(.plain)
                .help(f)
                .shellTarget("quickhelp file")
            }
            if !d.parameters.isEmpty {
                section("Parameters", c)
                ForEach(Array(d.parameters.enumerated()), id: \.offset) { pair in
                    Text(verbatim: pair.element.name).font(Font.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(c.label)
                        .contextMenu { Button("Copy") { ShellPasteboard.copy(pair.element.name) } }
                    paragraph(pair.element.text, c)
                }
            }
            if let r = d.returns {
                section("Return Value", c)
                paragraph(r, c)
            }
            if let t = d.throwsText {
                section("Throws", c)
                paragraph(t, c)
            }
            if !d.discussionBlocks.isEmpty {
                section("Discussion", c)
                ForEach(Array(d.discussionBlocks.enumerated()), id: \.offset) { pair in QuickHelpBlockView(block: pair.element, colors: c) }   // QuickHelpBlocks.swift
            }
            ForEach(Array(d.callouts.enumerated()), id: \.offset) { pair in
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: pair.element.title).font(ShellFonts.smallBold).foregroundStyle(c.label)
                    paragraph(pair.element.text, c)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.accent.opacity(0.10))
                        .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(c.accent.opacity(0.35), lineWidth: 1) }
                }
            }
            if d.showsDocumentationLink {
                Button { model.openDocumentation(for: d.title) } label: {
                    Text("Open in Developer Documentation").font(ShellFonts.small).foregroundStyle(c.accent)
                }
                .buttonStyle(.plain)
                .shellTarget("quickhelp documentation")
            }
        }
    }

    /// A module's Quick Help (§4.1): the title, the abstract, a hairline,
    /// Overview and its text, then the documentation link at the bottom
    /// right; no declaration box or file link.
    var moduleBody: some View {
        let c = ShellColors(scheme)
        let d = document
        let m = QuickHelpPopoverMetrics.self
        return VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: d.title).font(Font.system(size: CGFloat(m.titleFontSize), weight: .bold)).foregroundStyle(c.label)
                .shellTarget("quickhelp title")
            if let s = d.summary {
                QuickHelpText.text(document.runs(for: s)).font(Font.system(size: CGFloat(m.bodyFontSize))).foregroundStyle(c.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !d.overview.isEmpty {
                Rectangle().fill(Color(popoverHex: m.hairline(dark: scheme == .dark))).frame(height: 1)
                    .padding(.bottom, 4)
                    .shellTarget("quickhelp hairline")
                Text("Overview").font(Font.system(size: CGFloat(m.overviewFontSize), weight: .bold)).foregroundStyle(c.label)
                    .shellTarget("quickhelp heading")
                ForEach(Array(d.overview.enumerated()), id: \.offset) { pair in QuickHelpBlockView(block: pair.element, colors: c) }
            }
            HStack {
                Spacer(minLength: 0)
                Button { model.openDocumentation(for: d.title) } label: {
                    Text("Open in Developer Documentation").font(Font.system(size: CGFloat(m.linkFontSize))).foregroundStyle(c.accent)
                }
                .buttonStyle(.plain)
                .shellTarget("quickhelp documentation")
            }
            .padding(.top, 4)
        }
    }

    func section(_ name: String, _ c: ShellColors) -> some View {
        Text(verbatim: name).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
            .padding(.top, 2)
    }

    func paragraph(_ s: String, _ c: ShellColors) -> some View {
        QuickHelpText.text(document.runs(for: s)).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The Quick Help inspector tab (⌥⌘3): the symbol at the insertion point,
/// or "No Quick Help" centered.
struct QuickHelpInspector: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        if let d = model.languageFeatures.inspectorHelp, model.document != nil {
            ScrollView {
                QuickHelpContent(document: d, model: model)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
                    .padding(.top, CGFloat(WorkspaceChrome.inspectorContentTopInset))
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            .shellTarget("quickhelp inspector")
        } else {
            Text("No Quick Help").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, -(CGFloat(WorkspaceChrome.toolbarHeight) + CGFloat(WorkspaceChrome.selectorHeight)))
                .shellTarget("quickhelp inspector empty")
        }
    }
}

/// Quick Help over the editor (`popovers.md` §4, P-083): an anchored
/// popover always **above** the symbol, its arrow pointing down with the
/// tip 3 points over the symbol's line, centred on the symbol; never
/// flipped below and never clipped to the editor (it grows upward over the
/// jump bar and toolbar). Drawn by `AnchoredPopoverBackground`
/// (PopoverOverlay.swift) in Quick Help's material. The editor closes it
/// when the insertion point moves, on Escape and when it scrolls.
struct QuickHelpPopoverLayer: View {
    var model: WorkspaceShellModel
    let controller: SourceEditorController
    @Environment(\.colorScheme) private var scheme

    static let width = CGFloat(QuickHelpPopoverMetrics.width)

    var body: some View {
        let dark = scheme == .dark
        GeometryReader { geo in
            if let p = model.languageFeatures.popover, p.path == controller.document.path {
                let a = controller.symbolAnchor(p.offset)
                let word = TextCommands.identifierRange(in: controller.buffer.text, at: p.offset)
                let endX = word.map { controller.symbolAnchor($0.location + $0.length).x } ?? a.x + 8
                let startX = word.map { controller.symbolAnchor($0.location).x } ?? a.x
                let place = Self.placement(symbol: CGRect(x: startX, y: a.y, width: max(1, endX - startX), height: controller.lineHeight),
                                           width: geo.size.width)
                // Bottom-aligned at the arrow's tip, so a tall popover near
                // the top grows upward past the editor instead of flipping.
                QuickHelpContent(document: p.document, model: model, popover: true)
                    .frame(width: Self.width - CGFloat(2 * QuickHelpPopoverMetrics.sideInset), alignment: .leading)
                    .padding(.horizontal, CGFloat(QuickHelpPopoverMetrics.sideInset))
                    .padding(.top, CGFloat(QuickHelpPopoverMetrics.topInset))
                    .padding(.bottom, CGFloat(QuickHelpPopoverMetrics.bottomInset))
                    .padding(.bottom, CGFloat(PopoverMetrics.arrowHeight))
                    .background {
                        AnchoredPopoverBackground(edge: .above, arrowTipX: CGFloat(place.arrowTipX), fill: PopoverMaterial.quickHelpBody(dark: dark), dark: dark)
                    }
                    .onTapGesture {}
                    .shellTarget("quickhelp popover")
                    .offset(x: place.body.minX)
                    .frame(width: geo.size.width, height: max(1, place.arrowTip.y), alignment: .bottomLeading)
            }
        }
        .allowsHitTesting(model.languageFeatures.popover != nil)
    }

    /// The popover's place for a symbol's rectangle in the editor: centred
    /// on it, above it (`PopoverPlacement`), kept inside the editor's width.
    static func placement(symbol: CGRect, width: CGFloat) -> PopoverPlacement {
        PopoverPlacement.place(anchor: symbol, bodySize: CGSize(width: Self.width, height: 0), edge: .above,
                               gap: PopoverMetrics.textAnchorGap, bounds: CGRect(x: 8, y: 0, width: max(Self.width, width - 16), height: 0))
    }
}

/// A popover's outline: a rounded rectangle with an arrow on its top edge
/// whose tip is `arrowX` from the leading edge, at the shape's top. The
/// rectangle starts `arrowSize.height` below the top.
struct PopoverBubble: Shape {
    static let arrowSize = CGSize(width: 20, height: 10)
    static let cornerRadius: CGFloat = 10

    var arrowX: CGFloat

    func path(in r: CGRect) -> Path {
        let a = Self.arrowSize, k = Self.cornerRadius
        let top = r.minY + a.height
        let tip = min(max(r.minX + arrowX, r.minX + k + a.width / 2), r.maxX - k - a.width / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + k, y: top))
        p.addLine(to: CGPoint(x: tip - a.width / 2, y: top))
        p.addLine(to: CGPoint(x: tip, y: r.minY))
        p.addLine(to: CGPoint(x: tip + a.width / 2, y: top))
        p.addLine(to: CGPoint(x: r.maxX - k, y: top))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: top), tangent2End: CGPoint(x: r.maxX, y: top + k), radius: k)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - k))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - k, y: r.maxY), radius: k)
        p.addLine(to: CGPoint(x: r.minX + k, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - k), radius: k)
        p.addLine(to: CGPoint(x: r.minX, y: top + k))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: top), tangent2End: CGPoint(x: r.minX + k, y: top), radius: k)
        p.closeSubpath()
        return p
    }
}

/// A request that found nothing ("No definition found"): a capsule at the
/// editor's top for two seconds.
struct LanguageNotice: View {
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        VStack {
            if let n = model.languageFeatures.notice {
                Text(verbatim: n).font(ShellFonts.small).foregroundStyle(c.label)
                    .padding(.horizontal, 12)
                    .frame(height: 24)
                    .background {
                        Capsule(style: .continuous).fill(c.content)
                            .overlay { Capsule(style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                    }
                    .padding(.top, 10)
                    .shellTarget("language notice")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}

/// Editor ▸ Refactor ▸ Rename…: the new name, then (several files) the
/// preview of every changed line, file by file; Rename applies the edits,
/// one undo step per open file.
struct RenameSheet: View {
    var model: WorkspaceShellModel
    let request: RenameRequest
    @State private var name: String
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    init(model: WorkspaceShellModel, request: RenameRequest) {
        self.model = model
        self.request = request
        _name = State(initialValue: model.languageFeatures.renamePreview?.newName ?? request.oldName)
    }

    var body: some View {
        let c = ShellColors(scheme)
        let f = model.languageFeatures
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: "Rename “\(request.oldName)”").font(ShellFonts.rowBold).foregroundStyle(c.label)
            HStack(spacing: 8) {
                Text("New name:").font(ShellFonts.row).foregroundStyle(c.secondaryLabel)
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(ShellFonts.editor(12))
                    .focused($fieldFocused)
                    .onSubmit(commit)
                    .disabled(f.renamePreview != nil)
                    .shellTarget("rename field")
            }
            if let p = f.renamePreview {
                Text(verbatim: p.summary).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    .shellTarget("rename summary")
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(p.files.enumerated()), id: \.offset) { pair in
                            fileRows(pair.element, p, c)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 240)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.fieldFill)
                        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                }
                .shellTarget("rename preview")
            } else {
                Text(verbatim: "Occurrences in this file are highlighted. A rename that changes several files shows them here first.")
                    .font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if f.isRenaming {
                    Text("Renaming…").font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
                }
                Spacer()
                Button("Cancel") { model.cancelRename() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.bordered).shellTarget("rename cancel")
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(f.isRenaming || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .shellTarget("rename go")
            }
        }
        .padding(18)
        .frame(width: 520)
        .task { fieldFocused = true }
        .shellTarget("rename sheet")
    }

    private func commit() {
        if model.languageFeatures.renamePreview != nil {
            model.applyRenamePreview()
        } else {
            let n = name
            Task { await model.commitRename(to: n) }
        }
    }

    @ViewBuilder
    private func fileRows(_ file: RenamePreview.File, _ p: RenamePreview, _ c: ShellColors) -> some View {
        HStack(spacing: 6) {
            Image(systemName: WorkspaceChrome.fileSymbol(file.name)).font(.system(size: 12)).foregroundStyle(c.accent)
            Text(verbatim: file.name).font(ShellFonts.rowBold).foregroundStyle(c.label)
            Text(verbatim: file.countText).font(ShellFonts.small).foregroundStyle(c.secondaryLabel)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        ForEach(Array(file.lines.enumerated()), id: \.offset) { pair in
            let l = pair.element
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: "\(l.line)").font(Font.system(size: 10).monospacedDigit()).foregroundStyle(c.secondaryLabel)
                    .frame(width: 30, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: l.before).font(ShellFonts.editor(11)).foregroundStyle(c.secondaryLabel).lineLimit(1)
                    Text(verbatim: l.after).font(ShellFonts.editor(11)).foregroundStyle(c.label).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
        }
    }
}

/// The language sheets of a workspace window, and the app's link opener.
struct LanguageSheets: ViewModifier {
    var model: WorkspaceShellModel
    var app: ShellAppModel

    func body(content: Content) -> some View {
        let f = model.languageFeatures
        content
            // The new name is typed in place (InlineRename.swift, P-084);
            // the sheet shows a rename over several files before it applies.
            .sheet(isPresented: Binding(get: { f.rename != nil && f.renamePreview != nil }, set: { if !$0 { model.cancelRename() } })) {
                if let r = f.rename { RenameSheet(model: model, request: r) }
            }
            .onAppear { f.openExternally = { [weak app] url in app?.openExternally(url) } }
    }
}

/// The jump bar's symbol component (`navigators.md` §Symbols): the
/// declaration the insertion point is in, with its letter badge, or "No
/// Selection"; a click lists the file's declarations (Show Document Items)
/// and choosing one goes to its line.
struct DocumentItemsMenu: View {
    var model: WorkspaceShellModel
    /// The pane has the focus (its path in the label colour, else grey).
    var isActive = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let f = model.languageFeatures
        Menu {
            if f.documentSymbols.isEmpty {
                Button("No Items") {}.disabled(true)
            }
            ForEach(Array(DocumentSymbols.flattened(f.documentSymbols).enumerated()), id: \.offset) { pair in
                let s = pair.element.symbol
                Button(String(repeating: "    ", count: pair.element.depth) + "\(DocumentSymbols.badge(s.kind))  \(s.name)") { model.openSymbol(s) }
            }
        } label: {
            // Plain text after the chevron, as the macOS jump bar: the
            // symbol's name, or "No Selection", in the path's colour
            // (`editor-area.md` H.4, row 145).
            Text(verbatim: f.caretSymbol?.name ?? WorkspaceChrome.jumpBarNoSymbol).font(ShellFonts.small)
                .foregroundStyle(isActive ? c.label : c.secondaryLabel).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Show Document Items")
        .shellTarget("jump bar symbol")
    }
}

/// A declaration's letter in a small rounded square, tinted by kind.
struct SymbolBadge: View {
    var kind: SymbolScanner.Symbol.Kind

    var body: some View {
        Text(verbatim: DocumentSymbols.badge(kind))
            .font(Font.system(size: 9, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 13, height: 13)
            .background { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Self.tint(kind)) }
    }

    static func tint(_ k: SymbolScanner.Symbol.Kind) -> Color {
        switch k {
        case .class, .struct, .enum, .protocol, .actor, .typealias, .interface, .implementation:
            Color(.sRGB, red: 0.62, green: 0.36, blue: 0.85)
        case .extension: Color(.sRGB, red: 0.95, green: 0.55, blue: 0.2)
        case .function, .initializer, .macro: Color(.sRGB, red: 0.2, green: 0.6, blue: 0.75)
        case .property, .enumCase: Color(.sRGB, red: 0.3, green: 0.65, blue: 0.4)
        }
    }
}

// MARK: - The editor's part

extension SourceEditorController {
    /// The top-left of the character at `offset` in the editor's coordinates.
    func symbolAnchor(_ offset: Int) -> CGPoint {
        let b = buffer
        let o = min(max(0, offset), b.length)
        let n = b.document.line(containing: o)
        let p = position(ofOffset: o, line: n)   // wrapped rows (+Wrap.swift)
        return CGPoint(x: textOrigin + p.x - left, y: lineTop(n) + CGFloat(p.row) * lineHeight - top)
    }
}

/// Clicks with a modifier on a symbol (`language.md` §Features): ⌥-click
/// shows Quick Help; ⌘-click (the Super key) or Ctrl-click jumps to the
/// definition. True when the click was one of them.
@MainActor
enum SymbolClick {
    #if os(Linux)
    static func handle(_ p: CGPoint, modifiers m: KeyModifiers, controller c: SourceEditorController, model: WorkspaceShellModel) -> Bool {
        guard p.x >= c.gutterWidth, !m.contains(.shift) else { return false }
        let option = m.contains(.option), jump = m.contains(.control) || m.contains(.command)
        guard option != jump else { return false }
        let o = c.offset(at: p)
        c.buffer.setCaret(o)
        c.noteActivity(reveal: false)
        if option {
            Task { await model.showQuickHelp(at: o) }
        } else {
            Task { await model.jumpToDefinition(at: o) }
        }
        return true
    }
    #endif
}

/// The popover's declaration box (§4.2): 385 × (17.5 per line + 15), no
/// border, corners 6, #262626 in dark; the declaration in the editor's
/// face, syntax-coloured, attributes and modifiers on their own line.
struct QuickHelpDeclarationBox: View {
    var declaration: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let m = QuickHelpPopoverMetrics.self
        let lines = QuickHelpDeclarationLines.lines(declaration)
        let runs = MergeSheetLayout.highlight(lines, fileName: "Declaration.swift")
        let palette = SourcePalette.forAppearance(dark: scheme == .dark, theme: Preferences.shared.theme)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(runs.enumerated()), id: \.offset) { pair in
                pair.element.reduce(Text(verbatim: "")) { t, r in
                    t + Text(verbatim: r.text).foregroundStyle(palette.color(r.role).color)
                }
                .font(Font.system(size: CGFloat(m.declarationFontSize), design: .monospaced))
                .lineLimit(1)
                .frame(height: CGFloat(m.declarationLinePitch), alignment: .leading)
            }
        }
        .padding(.horizontal, CGFloat(m.declarationHorizontalPadding))
        .frame(width: CGFloat(m.declarationWidth), height: CGFloat(m.declarationHeight(lines: lines.count)), alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: CGFloat(m.declarationRadius), style: .continuous)
                .fill(Color(popoverHex: m.declarationFill(dark: scheme == .dark)))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lines.joined(separator: "\n"))
    }
}
