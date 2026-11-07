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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let d = document
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: d.title).font(Font.system(size: 15, weight: .bold)).foregroundStyle(c.label)
                .shellTarget("quickhelp title")
            if let s = d.summary { paragraph(s, c) }
            if !d.declaration.isEmpty {
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
            if let f = d.file {
                Button { model.openQuickHelpFile(f) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc").font(.system(size: 11))
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
            if !d.discussion.isEmpty {
                section("Discussion", c)
                ForEach(Array(d.discussion.enumerated()), id: \.offset) { pair in paragraph(pair.element, c) }
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
            Button { model.openDocumentation(for: d.title) } label: {
                Text("Open in Developer Documentation").font(ShellFonts.small).foregroundStyle(c.accent)
            }
            .buttonStyle(.plain)
            .shellTarget("quickhelp documentation")
        }
    }

    func section(_ name: String, _ c: ShellColors) -> some View {
        Text(verbatim: name).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel)
            .padding(.top, 2)
    }

    func paragraph(_ s: String, _ c: ShellColors) -> some View {
        Text(verbatim: s).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label)
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

/// Quick Help over the editor: a popover hanging under the symbol, its
/// arrow pointing up at the symbol's start. The bubble and its arrow are one
/// outline (one fill, one edge, one shadow), so the arrow reads in both
/// appearances. The editor closes it when the insertion point moves, on
/// Escape and when it scrolls.
struct QuickHelpPopoverLayer: View {
    var model: WorkspaceShellModel
    let controller: SourceEditorController
    @Environment(\.colorScheme) private var scheme

    static let width: CGFloat = 420

    var body: some View {
        // Raised over the editor: white in light mode, a lighter grey in dark.
        let fill = scheme == .dark ? Color(.sRGB, red: 0.19, green: 0.19, blue: 0.2) : Color.white
        let edge = scheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.2)
        GeometryReader { geo in
            if let p = model.languageFeatures.popover, p.path == controller.document.path {
                let anchor = controller.symbolAnchor(p.offset)
                let place = Self.placement(anchorX: anchor.x, lineBottom: anchor.y + controller.lineHeight, width: geo.size.width)
                let bubble = PopoverBubble(arrowX: place.arrowX)
                QuickHelpContent(document: p.document, model: model)
                    .frame(width: Self.width - 28, alignment: .leading)
                    .padding(14)
                    .padding(.top, PopoverBubble.arrowSize.height)
                    .background {
                        bubble.fill(fill)
                            .shadow(color: Color.black.opacity(scheme == .dark ? 0.5 : 0.2), radius: 12, y: 4)
                            .overlay { bubble.stroke(edge, lineWidth: 1) }
                    }
                    .offset(x: place.x, y: place.y)
                    .onTapGesture {}
                    .shellTarget("quickhelp popover")
            }
        }
        .allowsHitTesting(model.languageFeatures.popover != nil)
    }

    /// The bubble's leading edge and top (the arrow's tip) in the editor,
    /// and the arrow's tip from the bubble's leading edge: the tip just
    /// under the symbol's line, at the symbol's start; the bubble 8 points
    /// before it, kept inside the editor and with the arrow clear of its
    /// rounded corners.
    static func placement(anchorX: CGFloat, lineBottom: CGFloat, width: CGFloat) -> (x: CGFloat, y: CGFloat, arrowX: CGFloat) {
        let tipX = anchorX + 6
        let x = min(max(8, tipX - 28), max(8, width - Self.width - 8))
        let inset = PopoverBubble.cornerRadius + PopoverBubble.arrowSize.width / 2 + 2
        let arrowX = min(max(tipX - x, inset), Self.width - inset)
        return (x, lineBottom + 1, arrowX)
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
        _name = State(initialValue: request.oldName)
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
            .sheet(isPresented: Binding(get: { f.rename != nil }, set: { if !$0 { model.cancelRename() } })) {
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
            HStack(spacing: 3) {
                if let s = f.caretSymbol {
                    SymbolBadge(kind: s.kind)
                    Text(verbatim: s.name).font(ShellFonts.small.weight(.medium)).foregroundStyle(c.label).lineLimit(1)
                } else {
                    Text(verbatim: WorkspaceChrome.jumpBarNoSymbol).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                        .foregroundStyle(c.secondaryLabel).lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
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
