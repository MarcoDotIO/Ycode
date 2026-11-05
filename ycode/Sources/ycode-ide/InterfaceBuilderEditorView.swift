import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The Interface Builder editor (`specs/ide/interface-builder.md`): the
/// jump bar strip with the path to the selection, the Document Outline
/// (Filter at its bottom), the canvas and its bottom bar. The Library
/// (⇧⌘L, or + in the bar) and Add New Constraints show over the canvas.
/// The inspectors are in the window's inspector column
/// (InterfaceBuilderInspectors.swift). Everything reads and edits
/// `InterfaceBuilderShellModel`, which shares the macOS editor's model.
struct InterfaceBuilderEditorView: View {
    var model: InterfaceBuilderShellModel
    @Environment(\.colorScheme) private var scheme

    static let outlineWidth: CGFloat = 230

    var body: some View {
        let c = ShellColors(scheme)
        VStack(spacing: 0) {
            if let p = model.problem { ProblemBanner(message: p) {} }
            IBJumpBar(path: model.jumpBarPath, colors: c)
            Hairline(color: c.separator)
            HStack(spacing: 0) {
                if model.isOutlineShown {
                    IBOutlineColumn(model: model, colors: c)
                        .frame(width: Self.outlineWidth)
                    Hairline(color: c.separator, vertical: true)
                }
                VStack(spacing: 0) {
                    IBCanvasArea(model: model, colors: c)
                    Hairline(color: c.separator)
                    IBCanvasBar(model: model, colors: c)
                }
            }
        }
        .background(c.content)
        .overlay(alignment: .top) {
            if model.isLibraryShown { IBLibraryPanel(model: model).padding(.top, 34) }
        }
        .overlay(alignment: .bottomTrailing) {
            if model.isAddConstraintsShown { IBAddConstraintsPanel(model: model).padding(.trailing, 12).padding(.bottom, 36) }
        }
        .shellTarget("ib editor")
    }
}

/// The strip above the outline and canvas: the file, then the outline path
/// down to the selection, separated by chevrons.
struct IBJumpBar: View {
    var path: [String]
    var colors: ShellColors

    var body: some View {
        let c = colors
        HStack(spacing: 4) {
            ForEach(Array(path.enumerated()), id: \.offset) { pair in
                if pair.offset > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(c.tertiaryLabel) }
                Text(verbatim: pair.element).font(ShellFonts.small).tracking(ShellFonts.smallTracking)
                    .foregroundStyle(pair.offset == path.count - 1 ? c.label : c.secondaryLabel).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .shellTarget("ib jump bar")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(path.joined(separator: " › "))
    }
}

// MARK: Outline

/// The Document Outline: scenes, objects, the view hierarchy, Constraints
/// groups and the entry point; the selection follows the canvas. Up and
/// Down move it, Delete removes the selected view or constraint.
struct IBOutlineColumn: View {
    var model: InterfaceBuilderShellModel
    var colors: ShellColors
    @FocusState private var hasKeyboard: Bool

    static let rowHeight: CGFloat = 22

    var body: some View {
        let c = colors
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.visibleRows) { v in
                        row(v, c)
                    }
                }
                .padding(.vertical, 4)
            }
            .focusable()
            .focused($hasKeyboard)
            .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
            .onKeyPress(.delete) { model.deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { model.deleteSelection(); return .handled }
            Hairline(color: c.separator)
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
                InlineField(text: model.outlineFilter, placeholder: "Filter") { model.outlineFilter = $0 }
                    .shellTarget("ib outline filter")
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
        }
        .background(c.sidebar)
        .shellTarget("ib outline")
    }

    func symbol(_ r: IBOutlineRow) -> String {
        switch r.kind {
        case .scene: "rectangle.on.rectangle"
        case .view: "square.dashed"
        case .object: "cube"
        case .constraints, .constraint: "ruler"
        case .entryPoint: "arrow.right"
        }
    }

    func row(_ v: InterfaceBuilderShellModel.VisibleRow, _ c: ShellColors) -> some View {
        let r = v.row
        let on = model.isSelected(r)
        return HStack(spacing: 4) {
            Group {
                if r.children.isEmpty {
                    Color.clear
                } else {
                    Image(systemName: v.isExpanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(c.chevron)
                        .contentShape(Rectangle())
                        .onTapGesture { model.setExpanded(r.id, !v.isExpanded) }
                }
            }
            .frame(width: 12, height: 16)
            Image(systemName: symbol(r)).font(.system(size: 11)).foregroundStyle(r.kind == .scene ? c.warning : c.accent)
                .frame(width: 16)
            Text(verbatim: r.title).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
            if let b = r.badge {
                Text(verbatim: b).font(.system(size: 9, weight: .medium)).foregroundStyle(c.secondaryLabel)
                    .padding(.horizontal, 4)
                    .background { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(c.popUpFill) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 6 + CGFloat(v.depth) * 14)
        .padding(.trailing, 6)
        .frame(height: Self.rowHeight)
        .background {
            if on { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.rowSelection).padding(.horizontal, 4) }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(row: r)
            hasKeyboard = true
        }
        .contextMenu {
            Button("Delete") { model.select(row: r); model.deleteSelection() }
                .disabled(!(r.kind == .constraint || (r.kind == .view && model.document.byID[r.objectID ?? ""]?.parent?.isView == true)))
            if r.kind == .view, let id = r.objectID {
                Menu("Move Into") {
                    ForEach(moveTargets(id), id: \.0) { t in Button(t.1) { model.move(id, into: t.0) } }
                }
            }
        }
        .shellTarget("ib row \(r.title)")
    }

    /// Views a view can move into (Document Outline drag on macOS): the
    /// other views of its scene, not itself or its descendants.
    func moveTargets(_ id: String) -> [(String, String)] {
        let d = model.document
        guard let o = d.byID[id], let root = d.rootView(of: o) else { return [] }
        var out: [(String, String)] = []
        root.walk { v in
            guard v.isView, v.key != "cell", v.id != o.parent?.id else { return }
            var p: IBDocument.Object? = v
            while let q = p { if q.id == id { return }; p = q.parent }
            out.append((v.id, d.outlineTitle(v)))
        }
        return out
    }
}

// MARK: Canvas

/// The canvas: scenes at their canvas locations, each with its title bar,
/// the device bezel (iOS), the top view as a white box and every subview as
/// a labeled rectangle; segue curves, the entry-point arrow, the
/// selection's accent outline and eight handles, and dashed guides for its
/// constraints. A press selects the deepest view; dragging its body moves
/// it, dragging a handle resizes it.
struct IBCanvasArea: View {
    var model: InterfaceBuilderShellModel
    var colors: ShellColors
    @State private var pressed = false
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        let layout = model.layout
        let zoom = model.zoom
        let size = layout.canvasSize
        // Read here, so the canvas redraws when they change.
        let drawing = IBCanvasDrawing(layout: layout, selectedID: model.selectedID, selectedConstraint: model.selectedConstraint,
                                      preview: model.dragPreview, colors: colors, dark: model.canvasIsDark)
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                Canvas { ctx, _ in
                    ctx.scaleBy(x: zoom, y: zoom)
                    drawing.draw(&ctx)
                }
                .frame(width: size.width * zoom, height: size.height * zoom)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Interface Builder canvas")
                .shellTarget("ib canvas content")
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        let p = CGPoint(x: v.location.x / zoom, y: v.location.y / zoom)
                        if !pressed {
                            pressed = true
                            hasKeyboard = true
                            model.pointerDown(at: CGPoint(x: v.startLocation.x / zoom, y: v.startLocation.y / zoom))
                        }
                        model.pointerDragged(to: p)
                    }
                    .onEnded { v in
                        pressed = false
                        model.pointerUp(at: CGPoint(x: v.location.x / zoom, y: v.location.y / zoom))
                    })
            }
            .focusable()
            .focused($hasKeyboard)
            .onKeyPress(.delete) { model.deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { model.deleteSelection(); return .handled }
            .onKeyPress(phases: .down) { press in Self.shortcut(press, model: model, viewport: geo.size) }
        }
        .background(colors.sidebar)
        .overlay(alignment: .topTrailing) { IBCanvasOverview(layout: layout, colors: colors).padding(10) }
        .shellTarget("ib canvas")
    }

    /// ⌘+ / ⌘− / ⌘0 zoom, ⌘Z / ⇧⌘Z undo and redo (Ctrl on Linux).
    static func shortcut(_ press: KeyPress, model: InterfaceBuilderShellModel, viewport: CGSize) -> KeyPress.Result {
        guard press.modifiers.contains(.command) || press.modifiers.contains(.control) else { return .ignored }
        switch press.characters.lowercased() {
        case "=", "+": model.zoomIn()
        case "-": model.zoomOut()
        case "0": model.zoomToFit(viewport)
        case "z": if press.modifiers.contains(.shift) { model.redo() } else { model.undo() }
        default: return .ignored
        }
        return .handled
    }
}

/// The canvas overview at the canvas's top right (reference-ui-4.md §13
/// item 6): every scene as a small box.
struct IBCanvasOverview: View {
    var layout: IBCanvasLayout
    var colors: ShellColors
    static let size = CGSize(width: 150, height: 96)

    var body: some View {
        let (_, boxes) = layout.overview(in: Self.size)
        Canvas { ctx, _ in
            for b in boxes {
                ctx.fill(Path(roundedRect: b, cornerRadius: 2, style: .continuous), with: .color(colors.content))
                ctx.stroke(Path(roundedRect: b, cornerRadius: 2, style: .continuous), with: .color(colors.secondaryLabel), lineWidth: 1)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.popUpFill.opacity(0.92))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(colors.capsuleStroke, lineWidth: 1) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Draws the canvas from the shared layout (`IBCanvasLayout`), in canvas
/// points. Colours: the scene boxes follow the canvas appearance toggle.
struct IBCanvasDrawing {
    var layout: IBCanvasLayout
    var selectedID: String?
    var selectedConstraint: String?
    var preview: CGRect?
    var colors: ShellColors
    var dark: Bool

    var paper: Color { dark ? Color(white: 0.12) : .white }
    var ink: Color { dark ? Color(white: 0.92) : Color(white: 0.1) }
    var accent: Color { colors.accent }
    var muted: Color { colors.secondaryLabel }

    func draw(_ ctx: inout GraphicsContext) {
        let d = layout.document
        for p in layout.placements {
            sceneBar(p, &ctx)
            if d.isFlippedRuntime {
                let outer = p.box.insetBy(dx: -12, dy: -12)
                var bezel = Path(roundedRect: outer, cornerRadius: 36, style: .continuous)
                bezel.addPath(Path(roundedRect: p.box, cornerRadius: 26, style: .continuous))
                ctx.fill(bezel, with: .color(Color(white: 0.15)), style: FillStyle(eoFill: true))
            }
            if p.titleBar > 0 {
                ctx.fill(Path(roundedRect: p.full, cornerRadius: 8, style: .continuous), with: .color(dark ? Color(white: 0.22) : Color(white: 0.93)))
                for i in 0..<3 {
                    ctx.fill(Path(ellipseIn: CGRect(x: p.full.minX + 10 + CGFloat(i) * 18, y: p.full.minY + 8, width: 12, height: 12)), with: .color(Color(white: 0.6)))
                }
            }
            ctx.fill(Path(p.box), with: .color(paper))
            ctx.stroke(Path(p.full), with: .color(colors.separator), lineWidth: 1)
            p.view.walk { v in
                guard v !== p.view, v.isView, v.key != "cell", let r = layout.rect(of: v) else { return }
                ctx.fill(Path(r), with: .color(accent.opacity(d.isHidden(v.id) ? 0.02 : 0.06)))
                ctx.stroke(Path(r.insetBy(dx: 0.5, dy: 0.5)), with: .color(accent.opacity(0.5)), lineWidth: 1)
                var clipped = ctx
                clipped.clip(to: Path(r))
                clipped.draw(Text(verbatim: d.outlineTitle(v)).font(.system(size: 10)).foregroundStyle(ink), at: CGPoint(x: r.minX + 3, y: r.minY + 2), anchor: .topLeading)
            }
        }
        for s in layout.segueLines { segue(s.from, s.to, &ctx) }
        if let e = layout.entryPoint {
            var line = Path()
            line.move(to: e.from)
            line.addLine(to: e.to)
            ctx.stroke(line, with: .color(muted), lineWidth: 3)
            arrowHead(at: e.to, right: true, &ctx)
        }
        if let id = selectedID, let o = layout.document.byID[id] {
            for g in layout.constraintGuides(for: o) {
                var line = Path()
                line.move(to: g.from)
                line.addLine(to: g.to)
                ctx.stroke(line, with: .color(g.id == selectedConstraint ? accent : colors.warning), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        if let p = preview {
            ctx.fill(Path(p), with: .color(accent.opacity(0.15)))
            ctx.stroke(Path(p), with: .color(accent), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if let id = selectedID, let o = layout.document.byID[id], let r = layout.rect(of: o) {
            ctx.stroke(Path(r.insetBy(dx: -1, dy: -1)), with: .color(accent), lineWidth: 2)
            if o.parent?.isView == true {
                for h in IBCanvasLayout.handles(r) {
                    ctx.fill(Path(ellipseIn: h.rect), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: h.rect), with: .color(accent), lineWidth: 1)
                }
            }
        }
    }

    /// A scene's title bar: a rounded strip with the controller's icon and
    /// title; while the controller is selected, the scene's objects as
    /// icons on its right (reference-ui-4.md §13 item 6).
    func sceneBar(_ p: IBCanvasLayout.Placement, _ ctx: inout GraphicsContext) {
        let bar = layout.sceneBar(p)
        let shape = Path(roundedRect: bar, cornerRadius: 6, style: .continuous)
        ctx.fill(shape, with: .color(colors.popUpFill))
        ctx.stroke(shape, with: .color(colors.separator), lineWidth: 1)
        ctx.fill(Path(roundedRect: CGRect(x: bar.minX + 6, y: bar.minY + 6, width: 12, height: 12), cornerRadius: 3, style: .continuous), with: .color(colors.warning))
        ctx.draw(Text(verbatim: p.title).font(.system(size: 11, weight: .medium)).foregroundStyle(colors.label), at: CGPoint(x: bar.minX + 24, y: bar.midY), anchor: .leading)
        for icon in layout.sceneBarIcons(p, selected: selectedID) {
            ctx.draw(Image(systemName: icon.symbol), in: icon.rect)
        }
    }

    func segue(_ from: CGPoint, _ to: CGPoint, _ ctx: inout GraphicsContext) {
        var path = Path()
        path.move(to: from)
        let mid = (from.x + to.x) / 2
        path.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y))
        ctx.stroke(path, with: .color(muted), lineWidth: 1.5)
        arrowHead(at: to, right: to.x >= from.x, &ctx)
        let c = CGRect(x: mid - 9, y: (from.y + to.y) / 2 - 9, width: 18, height: 18)
        ctx.fill(Path(ellipseIn: c), with: .color(paper))
        ctx.stroke(Path(ellipseIn: c), with: .color(muted), lineWidth: 1)
    }

    func arrowHead(at p: CGPoint, right: Bool, _ ctx: inout GraphicsContext) {
        let d: CGFloat = right ? -1 : 1
        var head = Path()
        head.move(to: p)
        head.addLine(to: CGPoint(x: p.x + 10 * d, y: p.y - 6))
        head.addLine(to: CGPoint(x: p.x + 10 * d, y: p.y + 6))
        head.closeSubpath()
        ctx.fill(head, with: .color(muted))
    }
}

// MARK: Bottom bar

/// The canvas bottom bar (§Layout): outline toggle, + (Library), issues,
/// appearance, orientation, layout; the device pop-up; zoom − n% +; update
/// frames, align, add constraints (pin), resolve, embed in. Align, Resolve,
/// Embed In and Layout list their commands disabled.
struct IBCanvasBar: View {
    var model: InterfaceBuilderShellModel
    var colors: ShellColors

    var body: some View {
        let c = colors
        HStack(spacing: 10) {
            button("sidebar.left", model.isOutlineShown ? "Hide Document Outline" : "Show Document Outline", on: model.isOutlineShown) { model.isOutlineShown.toggle() }
            button("plus", "Library", on: model.isLibraryShown) { model.isLibraryShown.toggle() }
            button("checkmark.circle", "No Issues") {}
            button("moon", "Appearance", on: model.canvasIsDark) { model.canvasIsDark.toggle() }
            button("iphone", "Orientation", on: model.isLandscape) { model.isLandscape.toggle() }
            disabledMenu("rectangle.split.2x1", "Layout", ["Portrait", "Landscape"])
            Spacer(minLength: 8)
            CellPopUp(title: model.device, choices: model.deviceChoices) { model.device = $0 }
                .frame(width: 150)
                .shellTarget("ib device")
            button("minus", "Zoom Out") { model.zoomOut() }
            Text(verbatim: model.zoomText).font(ShellFonts.small).monospacedDigit().foregroundStyle(c.label).frame(width: 40)
                .shellTarget("ib zoom")
            button("plus", "Zoom In") { model.zoomIn() }
            Spacer(minLength: 8)
            button("arrow.clockwise", "Update Frames") { model.perform("updateCanvasFrames:", tag: 0) }
            disabledMenu("line.3.horizontal", "Align", ["Leading Edges", "Trailing Edges", "Top Edges", "Bottom Edges", "Horizontal Centers",
                                                        "Vertical Centers", "Baselines", "Horizontally in Container", "Vertically in Container"])
            button("plus.rectangle.on.rectangle", "Add New Constraints", on: model.isAddConstraintsShown) {
                if model.isAddConstraintsShown { model.isAddConstraintsShown = false } else { model.perform("showAddConstraints:", tag: 0) }
            }
            disabledMenu("exclamationmark.triangle", "Resolve Auto Layout Issues",
                         ["Update Constraint Constants", "Add Missing Constraints", "Reset to Suggested Constraints", "Clear Constraints"])
            disabledMenu("square.stack.3d.up", "Embed In", ["View", "Scroll View", "Stack View", "Navigation Controller", "Tab Bar Controller"])
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(c.sidebar)
        .shellTarget("ib canvas bar")
    }

    func button(_ symbol: String, _ help: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(on ? colors.accent : colors.toolbarIcon)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .shellTarget("ib bar \(help)")
    }

    func disabledMenu(_ symbol: String, _ help: String, _ items: [String]) -> some View {
        Menu {
            ForEach(items, id: \.self) { Button($0) {}.disabled(true) }
        } label: {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(colors.toolbarIcon).frame(width: 20, height: 20)
        }
        .menuStyle(.borderlessButton)
        .hidingMenuIndicator()
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .shellTarget("ib bar \(help)")
    }
}
