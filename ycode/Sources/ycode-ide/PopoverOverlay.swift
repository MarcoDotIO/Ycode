import Foundation
import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

// The Linux IDE's half of `specs/ide/popovers.md` §11 (beta 5,
// B5-POPOVERS): the anchored popover (its arrow and body as one outline),
// the scheme and destination choosers drawn from the shared `ChooserList`
// (P-111, P-113), the in-window capsules (Jump to Line, Quick Actions,
// Quick New Project: P-086, P-180), the New Scheme sheet (P-112) and the
// Product ▸ Destination rows (P-014). Everything is drawn in the
// workspace window itself, so the window keeps its active look (P-031),
// and opens and closes in one frame except Jump to Line's fade (P-195).
// Geometry and colours are the AppKit IDE's (`PopoverMetrics`,
// `InWindowPanel`, `PopoverMaterial`).

extension Color {
    /// An sRGB colour from 0xRRGGBB.
    init(popoverHex v: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: opacity)
    }
}

/// A popover's outline: a rounded rectangle (radius 17) with the 26 × 11
/// arrow on its top edge (`edge` below the anchor) or its bottom edge
/// (above), the tip `arrowTipX` from the left. The rectangle leaves the
/// arrow's height free on the arrow's side.
struct AnchoredPopoverShape: Shape {
    var edge: PopoverEdge
    var arrowTipX: CGFloat

    func path(in r: CGRect) -> Path {
        let m = PopoverMetrics.self
        let aw = CGFloat(m.arrowWidth), ah = CGFloat(m.arrowHeight)
        // Not laid out yet (or too small for the arrow): nothing to draw,
        // rather than arcs of a negative size.
        guard r.width.isFinite, r.height.isFinite, r.width >= aw + 4, r.height > ah + 4 else { return Path() }
        let k = min(CGFloat(m.cornerRadius), (r.width - aw) / 2, (r.height - ah) / 2)
        let body = edge == .below ? CGRect(x: r.minX, y: r.minY + ah, width: r.width, height: r.height - ah)
            : CGRect(x: r.minX, y: r.minY, width: r.width, height: r.height - ah)
        let tip = min(max(r.minX + arrowTipX, body.minX + k + aw / 2), body.maxX - k - aw / 2)
        var p = Path()
        p.move(to: CGPoint(x: body.minX + k, y: body.minY))
        if edge == .below {
            p.addLine(to: CGPoint(x: tip - aw / 2, y: body.minY))
            p.addLine(to: CGPoint(x: tip, y: r.minY))
            p.addLine(to: CGPoint(x: tip + aw / 2, y: body.minY))
        }
        p.addLine(to: CGPoint(x: body.maxX - k, y: body.minY))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.maxX, y: body.minY + k), radius: k)
        p.addLine(to: CGPoint(x: body.maxX, y: body.maxY - k))
        p.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX - k, y: body.maxY), radius: k)
        if edge == .above {
            p.addLine(to: CGPoint(x: tip + aw / 2, y: body.maxY))
            p.addLine(to: CGPoint(x: tip, y: r.maxY))
            p.addLine(to: CGPoint(x: tip - aw / 2, y: body.maxY))
        }
        p.addLine(to: CGPoint(x: body.minX + k, y: body.maxY))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.minX, y: body.maxY - k), radius: k)
        p.addLine(to: CGPoint(x: body.minX, y: body.minY + k))
        p.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX + k, y: body.minY), radius: k)
        p.closeSubpath()
        return p
    }
}

/// The popover's material: one fill, one edge and one shadow for the body
/// and its arrow.
struct AnchoredPopoverBackground: View {
    var edge: PopoverEdge
    var arrowTipX: CGFloat
    var fill: UInt32
    var dark: Bool

    var body: some View {
        let shape = AnchoredPopoverShape(edge: edge, arrowTipX: arrowTipX)
        shape.fill(Color(popoverHex: fill))
            .shadow(color: Color.black.opacity(dark ? 0.45 : 0.18), radius: 14, y: 5)
            .overlay { shape.stroke(Color(popoverHex: PopoverMaterial.popoverEdge(dark: dark)), lineWidth: 1) }
    }
}

// MARK: - The choosers (P-111, P-113)

/// The open chooser over the whole window: a click outside closes it; the
/// popover hangs under its half of the capsule, centred on it.
struct ChooserPopoverLayer: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel
    @State private var windowWidth: CGFloat = 1400

    var body: some View {
        let p = model.popovers
        if let which = p.chooser {
            // The layer covers the window from its origin, the frame the
            // anchors are measured in. (Without a geometry reader: its first
            // pass gave the popover an undefined position.)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.popovers.closeChooser() }
                    .shellTarget("chooser outside")
                if let place = p.placement(which, bounds: CGRect(x: 8, y: 0, width: max(0, windowWidth - 16), height: 0)) {
                    ChooserPopoverView(model: model, app: app, which: which, arrowTipX: CGFloat(place.arrowTipX))
                        .padding(.leading, max(0, place.body.minX))
                        .padding(.top, max(0, place.body.minY - CGFloat(PopoverMetrics.arrowHeight)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { w in if w.isFinite && w > 0 { windowWidth = w } }
        }
    }
}

extension ChooserPopoverLayer {
    /// A window point, or the origin for a null or unbounded frame's.
    static func sane(_ p: CGPoint) -> CGPoint {
        p.x.isFinite && p.y.isFinite && abs(p.x) < 100_000 && abs(p.y) < 100_000 ? p : .zero
    }
}

/// One chooser: the Filter field, then its rows (§2.2–§2.3).
struct ChooserPopoverView: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel
    var which: ShellPopoverModel.Chooser
    var arrowTipX: CGFloat
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var bodyWidth: CGFloat { CGFloat(which == .scheme ? PopoverMetrics.schemeBodyWidth : PopoverMetrics.destinationBodyWidth) }

    var body: some View {
        let m = PopoverMetrics.self
        let list = model.popovers.list
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: 0) {
            filterField(dark)
                .padding(.horizontal, CGFloat(m.filterInset))
                .padding(.top, CGFloat(m.filterInset))
                .padding(.bottom, CGFloat(m.filterGap))
            ForEach(Array(list.rows.enumerated()), id: \.offset) { pair in
                ChooserRowView(row: pair.element, lit: pair.offset == list.highlighted && pair.element.isSelectable, which: which, model: model)
                    .frame(width: bodyWidth, height: CGFloat(pair.element.height))
                    .contentShape(Rectangle())
                    .onTapGesture { run(model.chooseChooserRow(pair.offset)) }
                    .shellTarget("chooser row \(pair.offset)")
            }
            Spacer(minLength: 0)
        }
        .frame(width: bodyWidth, height: CGFloat(list.bodyHeight), alignment: .top)
        // §2.7: hover moves the highlight only once the pointer has moved
        // since the chooser opened on the current row.
        .onContinuousHover { phase in
            if case .active(let p) = phase { model.chooserPointer(at: p, bodyY: Double(p.y)) }
        }
        .padding(.top, CGFloat(m.arrowHeight))
        .background { AnchoredPopoverBackground(edge: .below, arrowTipX: arrowTipX, fill: PopoverMaterial.chooserBody(dark: dark), dark: dark) }
        .onTapGesture {}
        .onAppear { fieldFocused = true }
        .onChange(of: model.popovers.focusCount) { _, _ in fieldFocused = true }
        .shellTarget(which == .scheme ? "scheme chooser" : "destination chooser")
    }

    func filterField(_ dark: Bool) -> some View {
        let c = ShellColors(scheme)
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                .accessibilityHidden(true)
            TextField(text: Binding(get: { model.popovers.filter }, set: { model.setChooserFilter($0) }),
                      prompt: Text(verbatim: PopoverMetrics.filterPlaceholder)) {
                Text(verbatim: PopoverMetrics.filterPlaceholder)
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($fieldFocused)
            .onSubmit { run(model.chooseHighlightedRow()) }
            .onKeyPress(.downArrow) { model.moveChooserHighlight(1); return .handled }
            .onKeyPress(.upArrow) { model.moveChooserHighlight(-1); return .handled }
            .onKeyPress(.rightArrow) {
                guard model.popovers.list.current?.isDisclosure == true else { return .ignored }
                model.setChooserExpanded(true)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard model.popovers.list.current?.isDisclosure == true, model.popovers.expanded else { return .ignored }
                model.setChooserExpanded(false)
                return .handled
            }
            .onKeyPress(.escape) { model.popovers.closeChooser(); return .handled }
            .shellTarget("chooser filter")
        }
        .padding(.horizontal, 10)
        .frame(height: CGFloat(PopoverMetrics.filterHeight))
        .background { Capsule(style: .continuous).fill(c.label.opacity(dark ? 0.1 : 0.06)) }
    }

    /// What the view layer runs for a chosen command.
    func run(_ outcome: WorkspaceShellModel.ChooserOutcome?) {
        if outcome == .setUpSimulator { app.explainSimulator() }
    }
}

/// One chooser row (§2.3): a heading, a checked choice with its glyph and
/// OS version, a command, a separator or the Incompatible disclosure; the
/// highlight an accent rounded rectangle 12 inside the body, white text.
struct ChooserRowView: View {
    var row: ChooserRow
    var lit: Bool
    var which: ShellPopoverModel.Chooser
    var model: WorkspaceShellModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let m = PopoverMetrics.self
        let c = ShellColors(scheme)
        let ink = lit ? Color.white : row.isEnabled ? c.label : c.tertiaryLabel
        ZStack(alignment: .leading) {
            if lit {
                RoundedRectangle(cornerRadius: CGFloat(m.highlightRadius), style: .continuous)
                    .fill(Color(popoverHex: PopoverMaterial.highlight(dark: scheme == .dark)))
                    .padding(.horizontal, CGFloat(m.highlightInset))
            }
            switch row.kind {
            case .separator:
                Rectangle().fill(c.separator).frame(height: 1).padding(.horizontal, CGFloat(m.separatorInset))
            case .heading:
                Text(verbatim: row.title).font(.system(size: CGFloat(m.headingFontSize), weight: .semibold)).foregroundStyle(c.secondaryLabel)
                    .padding(.leading, CGFloat(m.checkX))
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .choice, .command, .disclosure:
                HStack(spacing: 0) {
                    Text(verbatim: row.isChecked ? "✓" : "").font(.system(size: CGFloat(m.titleFontSize), weight: .semibold)).foregroundStyle(ink)
                        .frame(width: CGFloat(m.glyphX - m.checkX), alignment: .leading)
                    glyph(ink).frame(width: CGFloat(m.glyphSide), height: CGFloat(m.glyphSide))
                    Spacer().frame(width: CGFloat(m.titleX - m.glyphX - m.glyphSide))
                    Text(verbatim: row.title).font(.system(size: CGFloat(m.titleFontSize))).foregroundStyle(ink).lineLimit(1)
                    Spacer(minLength: 8)
                    if let t = row.trailing {
                        Text(verbatim: t).font(.system(size: CGFloat(m.titleFontSize))).foregroundStyle(lit ? Color.white.opacity(0.85) : c.secondaryLabel)
                    }
                    if case .disclosure(let open) = row.kind {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(lit ? Color.white : c.secondaryLabel)
                    }
                }
                .padding(.leading, CGFloat(m.checkX))
                .padding(.trailing, CGFloat(m.trailingInset))
            }
        }
    }

    /// The row's glyph: the scheme's app icon, this computer's laptop, or
    /// OpenViews' own artwork of the shared symbol name.
    @ViewBuilder
    func glyph(_ ink: Color) -> some View {
        if row.kind != .choice {
            Color.clear
        } else if which == .scheme {
            SchemeGlyph(appIcon: SchemeCapsuleIcons.appIconURL(scheme: row.title, model: model.session.model))   // ToolbarChrome.swift
        } else if row.symbol == "laptopcomputer" {
            HostDestinationGlyph(fallbackColor: ink)   // ToolbarChrome.swift (row 199)
        } else {
            Image(systemName: Self.linuxSymbol(row.symbol)).font(.system(size: 12)).foregroundStyle(ink)
        }
    }

    /// OpenViews' artwork for a shared symbol name it does not draw.
    static func linuxSymbol(_ s: String?) -> String {
        switch s {
        case "candybarphone"?: "iphone"
        case "square.dashed"?, "eyeglasses"?: "app.dashed"
        case let s?: s
        case nil: "app.dashed"
        }
    }
}

/// One half of the scheme capsule: its title (after its glyph), opening
/// its chooser on mouse-down (§2.1) and keeping a pressed tint while it is
/// open; the half's frame in the window is the chooser's anchor.
struct ChooserCapsuleHalf<Label: View>: View {
    var model: WorkspaceShellModel
    var which: ShellPopoverModel.Chooser
    @ViewBuilder var label: () -> Label
    @State private var pressed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let open = model.popovers.chooser == which
        label()
            .padding(.horizontal, 4)
            .frame(height: CGFloat(WorkspaceChrome.toolbarItemHeight))
            // P-198: only the hovered half shows its bezel (ControlStateViews.swift).
            .hoverBezel(.toolbarChooserHalf, radius: 14, height: ControlStates.toolbarBezelHeight)
            .background {
                if open { Capsule(style: .continuous).fill(Color(popoverHex: PopoverMaterial.pressedHalf(dark: scheme == .dark))) }
            }
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { r in
                if !r.isNull, ChooserPopoverLayer.sane(r.origin) == r.origin, r.width < 10_000 { model.popovers.anchors[which] = r }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                guard !pressed else { return }
                pressed = true
                if open { model.popovers.closeChooser() } else if which == .scheme { model.showSchemeChooser() } else { model.showDestinationChooser() }
            }.onEnded { _ in pressed = false })
    }
}

// MARK: - In-window capsules (P-086, P-180)

/// Jump to Line, Quick Actions and Quick New Project over the window,
/// centred on it under the toolbar; a click outside closes them.
struct InWindowPanelLayer: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel

    var body: some View {
        let p = model.popovers
        let spec: InWindowPanel? = model.isJumpToLineShown ? .jumpToLine : p.quickActions != nil ? .quickActions : p.quickNewProject != nil ? .quickNewProject : nil
        if let spec {
            ZStack(alignment: .top) {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.closePalettes() }
                    .shellTarget("palette outside")
                Group {
                    if model.isJumpToLineShown {
                        JumpToLineCapsule(model: model)
                    } else if p.quickActions != nil {
                        QuickActionsCapsule(model: model, app: app)
                    } else {
                        QuickNewProjectPanel(model: model, app: app)
                    }
                }
                .padding(.top, CGFloat(InWindowPanel.toolbarBottom + spec.topBelowToolbar))
            }
        }
    }
}

/// The capsule's shape and material: 55 tall, fully rounded, a 1-point rim.
struct InWindowCapsuleBackground: View {
    var radius: CGFloat
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color(popoverHex: PopoverMaterial.capsuleFill(dark: dark)))
            .shadow(color: Color.black.opacity(dark ? 0.45 : 0.16), radius: 16, y: 6)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color(popoverHex: PopoverMaterial.capsuleRim(dark: dark)), lineWidth: 1)
            }
    }
}

/// The capsule's top band: the magnifier (or +) and the borderless field.
struct InWindowField: View {
    var spec: InWindowPanel
    var symbol = "magnifyingglass"
    var text: Binding<String>
    var focusCount: Int
    var target: String
    var onSubmit: () -> Void
    var onMove: (Int) -> Void = { _ in }
    var onEscape: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let dark = scheme == .dark
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: CGFloat(InWindowPanel.magnifierSize), height: CGFloat(InWindowPanel.magnifierSize))
                .foregroundStyle(Color(popoverHex: OpenQuicklyLayout.magnifier(dark: dark)))
                .padding(.leading, CGFloat(InWindowPanel.magnifierX))
                .accessibilityHidden(true)
            TextField(text: text, prompt: Text(verbatim: spec.placeholder)) { Text(verbatim: spec.placeholder) }
                .textFieldStyle(.plain)
                .font(.system(size: CGFloat(InWindowPanel.fieldFontSize)))
                .foregroundStyle(c.label)
                .focused($focused)
                .onSubmit(onSubmit)
                .onKeyPress(.downArrow) { onMove(1); return .handled }
                .onKeyPress(.upArrow) { onMove(-1); return .handled }
                .onKeyPress(.escape) { onEscape(); return .handled }
                .frame(width: CGFloat(spec.fieldWidth), height: CGFloat(InWindowPanel.fieldHeight))
                .padding(.leading, CGFloat(InWindowPanel.fieldX - InWindowPanel.magnifierX - InWindowPanel.magnifierSize))
                .shellTarget(target)
            Spacer(minLength: 0)
        }
        .frame(width: CGFloat(spec.width), height: CGFloat(spec.height))
        .onAppear { focused = true }
        .onChange(of: focusCount) { _, _ in focused = true }
    }
}

/// Navigate ▸ Jump to Line… (⌘L): "Line Number"; Return jumps and closes
/// in one frame; Escape fades it out over `Motion.jumpToLineFadeOut`.
struct JumpToLineCapsule: View {
    var model: WorkspaceShellModel

    var body: some View {
        let spec = InWindowPanel.jumpToLine
        InWindowField(spec: spec, text: Binding(get: { model.popovers.jumpText }, set: { model.popovers.jumpText = $0 }),
                      focusCount: model.popovers.focusCount, target: "jump field",
                      // After the Return key's event is done: jumping focuses the
                      // editor, which would otherwise take the same Return.
                      onSubmit: { Task { @MainActor in _ = model.jumpToLine(model.popovers.jumpText) } },
                      onEscape: { fadeOut() })
            .background { InWindowCapsuleBackground(radius: CGFloat(spec.cornerRadius)) }
            .opacity(model.popovers.jumpFading ? 0 : 1)
            .animation(.easeIn(duration: Motion.jumpToLineFadeOut), value: model.popovers.jumpFading)
            .onTapGesture {}
            .onAppear { model.popovers.jumpText = "" }
            .shellTarget("jump to line")
    }

    func fadeOut() {
        model.cancelJumpToLine()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Motion.jumpToLineFadeOut * 1_000_000_000))
            model.endJumpFade()
        }
    }
}

/// View ▸ Show Quick Actions… (⇧⌘A): "Quick Actions"; nothing listed until
/// something is typed, then (§5.1) a hairline under the field and the
/// matching commands as two-line 56-point rows, the panel growing downward
/// to 495 points with the list scrolling inside it.
struct QuickActionsCapsule: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel
    @State private var query = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let spec = InWindowPanel.quickActions
        let m = QuickActionRowMetrics.self
        let list = model.popovers.quickActions
        let rows = list?.shown ?? []
        let dark = scheme == .dark
        VStack(spacing: 0) {
            InWindowField(spec: spec, text: Binding(get: { query }, set: { query = $0; model.setQuickActionsQuery($0) }),
                          focusCount: model.popovers.focusCount, target: "quick actions field",
                          onSubmit: { perform(list?.current) }, onMove: { model.moveQuickActions($0) },
                          onEscape: { model.closePalettes() })
            if !rows.isEmpty {
                Rectangle().fill(Color(popoverHex: m.hairline(dark: dark))).frame(height: 1)
                    .padding(.top, CGFloat(m.hairlineY - spec.height))
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(0..<rows.count, id: \.self) { i in
                                QuickActionRowView(entry: rows[i].entry, query: query, lit: i == (list?.selected ?? 0))
                                    .frame(height: CGFloat(m.rowHeight))
                                    .contentShape(Rectangle())
                                    .onTapGesture { perform(rows[i]) }
                                    .id(i)
                                    .shellTarget("palette row \(i)")
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: CGFloat(m.listHeight(count: rows.count)))
                    .onChange(of: list?.selected ?? 0) { _, i in proxy.scrollTo(i) }
                }
                .padding(.top, CGFloat(m.rowsTop - m.hairlineY - 1))
            }
        }
        .frame(width: CGFloat(spec.width), height: CGFloat(m.panelHeight(count: rows.count)), alignment: .top)
        .background { InWindowCapsuleBackground(radius: CGFloat(spec.cornerRadius)) }
        .onTapGesture {}
        .shellTarget("quick actions")
    }

    func perform(_ a: QuickAction?) {
        guard let a else { return }
        model.closePalettes()
        ShellMenuModel.perform(a.command, app: app)
    }
}

/// One Quick Actions row (§5.1): the glyph centred 33 from the panel's
/// left, the title at 64 (the match semibold) over the menu path, the key
/// equivalent at the right; the selected row a rounded accent rectangle
/// (radius 14, inset 8 and 21) with everything white.
struct QuickActionRowView: View {
    var entry: QuickActionEntry
    var query: String
    var lit: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let m = QuickActionRowMetrics.self
        let dark = scheme == .dark
        let white = Color.white
        ZStack(alignment: .topLeading) {
            if lit {
                RoundedRectangle(cornerRadius: CGFloat(m.highlightRadius), style: .continuous)
                    .fill(Color(popoverHex: m.highlight(dark: dark)))
                    .padding(.leading, CGFloat(m.highlightLeft))
                    .padding(.trailing, CGFloat(m.highlightRight))
            }
            Image(systemName: entry.symbol)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: CGFloat(m.glyphPointSize), height: CGFloat(m.glyphPointSize))
                .foregroundStyle(lit ? white : Color(popoverHex: m.glyph(dark: dark)))
                .frame(width: CGFloat(m.glyphColumn), height: CGFloat(m.rowHeight))
                .offset(x: CGFloat(m.glyphCenterX - m.glyphColumn / 2))
                .accessibilityHidden(true)
            HStack(alignment: .top, spacing: 12) {
                // The lines' centres 18 and 39 below the row's top.
                ZStack(alignment: .topLeading) {
                    title(dark)
                        .lineLimit(1)
                        .frame(height: 24, alignment: .leading)
                        .offset(y: CGFloat(m.titleCenterY) - 12)
                    Text(verbatim: entry.subtitle).font(.system(size: CGFloat(m.subtitleFontSize)))
                        .foregroundStyle(lit ? white : Color(popoverHex: m.subtitle(dark: dark)))
                        .lineLimit(1)
                        .frame(height: 20, alignment: .leading)
                        .offset(y: CGFloat(m.subtitleCenterY) - 10)
                }
                .frame(height: CGFloat(m.rowHeight), alignment: .topLeading)
                Spacer(minLength: 0)
                if !entry.shortcut.isEmpty {
                    Text(verbatim: entry.shortcut).font(.system(size: CGFloat(m.keyFontSize)))
                        .foregroundStyle(lit ? white : Color(popoverHex: m.key(dark: dark)))
                        .frame(height: 20)
                        .offset(y: CGFloat(m.titleCenterY) - 10)
                }
            }
            .padding(.leading, CGFloat(m.textX))
            .padding(.trailing, CGFloat(m.highlightRight + m.keyRightInset))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.displayTitle)
    }

    /// The title, the matched part semibold.
    func title(_ dark: Bool) -> Text {
        let m = QuickActionRowMetrics.self
        let chars = Array(entry.displayTitle)
        let ranges = QuickActionRanking.matchedRanges(entry, query: query)
        let rest = lit ? Color.white : Color(popoverHex: m.title(dark: dark))
        let match = lit ? Color.white : Color(popoverHex: m.match(dark: dark))
        let size = CGFloat(m.titleFontSize)
        var pieces: [Text] = []
        var i = 0
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where r.lowerBound >= i && r.upperBound <= chars.count {
            if r.lowerBound > i { pieces.append(Text(verbatim: String(chars[i..<r.lowerBound])).font(.system(size: size)).foregroundStyle(rest)) }
            pieces.append(Text(verbatim: String(chars[r])).font(.system(size: size, weight: .semibold)).foregroundStyle(match))
            i = r.upperBound
        }
        if i < chars.count { pieces.append(Text(verbatim: String(chars[i...])).font(.system(size: size)).foregroundStyle(rest)) }
        return pieces.reduce(Text(verbatim: ""), +)
    }
}

/// Quick New Project (P-180): 640 × 355, a + and the field over the
/// compact picker's five rows with their glyphs and subtitles.
struct QuickNewProjectPanel: View {
    var model: WorkspaceShellModel
    var app: ShellAppModel
    @State private var query = ""

    var body: some View {
        let spec = InWindowPanel.quickNewProject
        let list = model.popovers.quickNewProject
        let rows = list?.shown ?? []
        VStack(spacing: 0) {
            InWindowField(spec: spec, symbol: QuickNewProject.headerSymbol,
                          text: Binding(get: { query }, set: { query = $0; model.setQuickNewProjectQuery($0) }),
                          focusCount: model.popovers.focusCount, target: "quick new project field",
                          onSubmit: { choose(list?.current) }, onMove: { model.moveQuickNewProject($0) },
                          onEscape: { model.closePalettes() })
            if !rows.isEmpty {
                PaletteRowsList(count: rows.count, selected: list?.selected ?? 0, rowHeight: QuickNewProject.rowHeight) { i, lit in
                    PaletteRowLabel(title: rows[i].title, detail: rows[i].subtitle, trailing: "", symbol: rows[i].symbol, lit: lit, twoLines: true)
                } onChoose: { i in choose(rows[i]) }
            }
        }
        .frame(width: CGFloat(spec.width), height: CGFloat(QuickNewProject.height(rows: rows.count)), alignment: .top)
        .background { InWindowCapsuleBackground(radius: CGFloat(spec.cornerRadius)) }
        .onTapGesture {}
        .shellTarget("quick new project")
    }

    func choose(_ r: QuickNewProject.Row?) {
        guard let r else { return }
        model.closePalettes()
        app.showNewProject(row: r.index)
    }
}

/// A palette's rows, 10 inside the panel, the selected one highlighted.
struct PaletteRowsList<Row: View>: View {
    var count: Int
    var selected: Int
    var rowHeight: Double
    @ViewBuilder var row: (Int, Bool) -> Row
    var onChoose: (Int) -> Void

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { i in
                    row(i, i == selected)
                        .frame(height: CGFloat(rowHeight))
                        .contentShape(Rectangle())
                        .onTapGesture { onChoose(i) }
                        .shellTarget("palette row \(i)")
                }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: CGFloat(Double(min(count, InWindowPanel.maximumVisibleRows)) * rowHeight))
        .padding(.horizontal, CGFloat(InWindowPanel.resultInset))
        .padding(.top, CGFloat(InWindowPanel.resultInset))
    }
}

/// A palette row: a glyph, the title and its detail (a second line, or a
/// column and a shortcut), white on the accent highlight.
struct PaletteRowLabel: View {
    var title: String
    var detail: String
    var trailing: String
    var symbol: String?
    var lit: Bool
    var twoLines: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let ink = lit ? Color.white : c.label, dim = lit ? Color.white.opacity(0.85) : c.secondaryLabel
        HStack(spacing: 0) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: twoLines ? 20 : 13)).foregroundStyle(ink)
                    .frame(width: twoLines ? 40 : 24, alignment: .leading)
            }
            if twoLines {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(dim).lineLimit(1)
                }
            } else {
                // Columns as the macOS rows: the title, the menu from 55 %, the shortcut.
                Text(verbatim: title).font(.system(size: 14)).foregroundStyle(ink).lineLimit(1)
                    .frame(width: 260, alignment: .leading)
                Text(verbatim: detail).font(.system(size: 12)).foregroundStyle(dim).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: trailing).font(.system(size: 12)).foregroundStyle(dim).frame(width: 64, alignment: .trailing)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if lit {
                RoundedRectangle(cornerRadius: twoLines ? CGFloat(QuickNewProject.rowCornerRadius) : 8, style: .continuous)
                    .fill(Color(popoverHex: PopoverMaterial.highlight(dark: scheme == .dark)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - New Scheme (P-112)

/// The New Scheme sheet: 493 × 122, "Target:" and a pop-up of the
/// targets, "Name:" and the field (the target's name, selected), Cancel
/// and OK (the default button) at the bottom right.
struct NewSchemeSheetView: View {
    typealias M = NewSchemeSheetMetrics
    var model: WorkspaceShellModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        let m = model.popovers.newScheme
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Text(verbatim: NewSchemeModel.targetLabel + ":").frame(width: CGFloat(M.labelRight), alignment: .trailing)
                Picker("", selection: Binding(get: { m?.selected ?? 0 }, set: { model.popovers.newScheme?.select($0) })) {
                    ForEach(Array((m?.targets ?? []).enumerated()), id: \.offset) { pair in
                        Text(verbatim: pair.element.name).tag(pair.offset)
                    }
                }
                .labelsHidden()
                .frame(width: CGFloat(M.popUpWidth), alignment: .leading)
                .shellTarget("new scheme target")
            }
            .frame(height: 22)
            .padding(.top, CGFloat(M.targetRowY))
            HStack(spacing: 5) {
                Text(verbatim: NewSchemeModel.nameLabel + ":").frame(width: CGFloat(M.labelRight), alignment: .trailing)
                TextField(NewSchemeModel.nameLabel, text: Binding(get: { m?.name ?? "" }, set: { model.popovers.newScheme?.name = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: CGFloat(M.fieldWidth), height: CGFloat(M.fieldHeight))
                    .focused($nameFocused)
                    .onSubmit { model.createNewScheme() }
                    .shellTarget("new scheme name")
            }
            .padding(.top, CGFloat(M.nameRowY - M.targetRowY - 22))
            Spacer(minLength: 0)
            HStack(spacing: CGFloat(M.buttonGap)) {
                Spacer()
                Button { model.popovers.newScheme = nil } label: { Text("Cancel").frame(width: CGFloat(M.buttonWidth) - 20) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                    .shellTarget("new scheme cancel")
                Button { model.createNewScheme() } label: { Text("OK").frame(width: CGFloat(M.buttonWidth) - 20) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!(m?.canCreate ?? false))
                    .shellTarget("new scheme ok")
            }
            .frame(height: CGFloat(M.buttonHeight))
            .padding(.trailing, CGFloat(M.buttonRight))
            .padding(.bottom, CGFloat(M.buttonBottom))
        }
        .frame(width: CGFloat(M.width), height: CGFloat(M.height))
        .task { nameFocused = true }
        .shellTarget("new scheme sheet")
    }
}

/// The window's popovers, capsules and the New Scheme sheet (one modifier
/// on the workspace view).
struct WorkspacePopovers: ViewModifier {
    var model: WorkspaceShellModel
    var app: ShellAppModel

    func body(content: Content) -> some View {
        ShellTooltips.apply()
        return content
            .overlay(alignment: .top) { InWindowPanelLayer(model: model, app: app) }
            .overlay { ChooserPopoverLayer(model: model, app: app) }
            .sheet(isPresented: Binding(get: { model.popovers.newScheme != nil }, set: { if !$0 { model.popovers.newScheme = nil } })) {
                NewSchemeSheetView(model: model)
            }
    }
}
