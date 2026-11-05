import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// Interface Builder's Identity, Attributes, Size and Connections
/// inspectors in the inspector column (`interface-builder.md` §Layout,
/// reference-ui-4.md §13). The sections and rows come from the shared
/// model (`IBInspectorModel.swift`), as in the macOS inspector; every edit
/// writes the attribute the row names. Attributes ends with the Control
/// block (Title, Placeholder, Alignment, Enabled, Hidden); Size lists the
/// selected view's constraints with an editable constant.
struct IBInspectorView: View {
    var model: InterfaceBuilderShellModel
    var tab: IBInspectorTab
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let sections = model.inspectorSections(tab)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.selected == nil {
                    Text(verbatim: "No Selection").font(Font.system(size: 13)).foregroundStyle(c.secondaryLabel)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                }
                ForEach(Array(sections.enumerated()), id: \.offset) { pair in
                    if pair.offset > 0 { Hairline(color: c.separator).padding(.top, 10).padding(.bottom, 8) }
                    section(pair.element, c)
                }
                if tab == .attributes, let state = model.controlState {
                    Hairline(color: c.separator).padding(.top, 10).padding(.bottom, 8)
                    controlBlock(state, c)
                }
                if tab == .size, let o = model.selected, o.isView {
                    let cs = model.document.constraints(involving: o.id)
                    if !cs.isEmpty {
                        Hairline(color: c.separator).padding(.top, 10).padding(.bottom, 8)
                        constants(cs, c)
                    }
                }
                Spacer(minLength: 12)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat(WorkspaceChrome.inspectorContentInset))
            .padding(.top, CGFloat(WorkspaceChrome.inspectorContentTopInset))
        }
        .shellTarget("ib inspector \(tab.title)")
    }

    func heading(_ t: String, _ c: ShellColors) -> some View {
        Text(verbatim: t).font(ShellFonts.smallBold).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).padding(.bottom, 2)
    }

    func keyed<V: View>(_ key: String, _ c: ShellColors, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .center, spacing: CGFloat(WorkspaceChrome.inspectorKeyToValue)) {
            Text(verbatim: key).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.secondaryLabel).lineLimit(1)
                .frame(width: CGFloat(WorkspaceChrome.inspectorKeyColumnWidth), alignment: .trailing)
            value().frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 22, alignment: .leading)
    }

    func field(_ text: String, placeholder: String = "", _ c: ShellColors, target: String, commit: @escaping (String) -> Void) -> some View {
        InlineField(text: text, placeholder: placeholder, commit: commit)
            .frame(height: 22)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            }
            .shellTarget(target)
    }

    func check(_ title: String, _ on: Bool, _ c: ShellColors, target: String, toggle: @escaping (Bool) -> Void) -> some View {
        Button { toggle(!on) } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 12)).foregroundStyle(on ? c.accent : c.secondaryLabel)
                Text(verbatim: title).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
        .shellTarget(target)
    }

    func section(_ s: IBInspectorSection, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !s.title.isEmpty { heading(s.title, c) }
            ForEach(Array(s.rows.enumerated()), id: \.offset) { pair in
                row(pair.element, c)
            }
            if s.title == "User Defined Runtime Attributes" {
                HStack(spacing: 8) {
                    PlusButton(help: "Add a runtime attribute", target: "ib runtime add") { model.addRuntimeAttribute() }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    func row(_ r: IBInspectorRow, _ c: ShellColors) -> some View {
        switch r {
        case .text(let l, let target, let attr, let value, let ph):
            keyed(l, c) { field(value, placeholder: ph, c, target: "ib field \(l)") { model.setAttribute(attr, $0, of: target) } }
        case .toggle(let l, _, _, let on, _, _):
            keyed("", c) { check(l, on, c, target: "ib toggle \(l)") { model.setToggle(r, on: $0) } }
        case .edgeToggle(let l, _, _, let on):
            keyed("", c) { check(l, on, c, target: "ib toggle \(l)") { model.setToggle(r, on: $0) } }
        case .choice(let l, _, _, let options, let value):
            keyed(l, c) {
                CellPopUp(title: value, choices: options) { model.setChoice(r, $0) }.shellTarget("ib choice \(l)")
            }
        case .info(let l, let v):
            if v.isEmpty {
                Text(verbatim: l).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
            } else {
                keyed(l, c) { Text(verbatim: v).font(ShellFonts.small).tracking(ShellFonts.smallTracking).foregroundStyle(c.label).lineLimit(2) }
            }
        case .runtimeAttribute(let k, let t, let v):
            HStack(spacing: 6) {
                Text(verbatim: "\(k) | \(t) | \(v)").font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                Spacer(minLength: 0)
                Button { model.removeRuntimeAttribute(k) } label: {
                    Image(systemName: "minus").font(.system(size: 10, weight: .semibold)).foregroundStyle(c.secondaryLabel).frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Remove \(k)")
            }
        case .constraint(let text, _):
            HStack(spacing: 6) {
                Image(systemName: "ruler").font(.system(size: 10)).foregroundStyle(c.secondaryLabel)
                Text(verbatim: text).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
            }
        case .connection(let name, let other, let id):
            HStack(spacing: 6) {
                Text(verbatim: name).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
                if !other.isEmpty {
                    Button { if let id { model.disconnect(id) } } label: {
                        HStack(spacing: 4) {
                            Text(verbatim: other).font(ShellFonts.small).lineLimit(1)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(c.label)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background { Capsule(style: .continuous).fill(c.popUpFill) }
                    }
                    .buttonStyle(.plain)
                    .help("Disconnect \(other)")
                }
                Spacer(minLength: 0)
                Image(systemName: other.isEmpty ? "circle" : "circle.fill").font(.system(size: 10)).foregroundStyle(other.isEmpty ? c.secondaryLabel : c.accent)
            }
        case .frameValue(let l, let target, let component, let value):
            keyed(l, c) {
                HStack(spacing: 4) {
                    field(value, c, target: "ib frame \(l)") { if let v = Double($0) { model.setFrameComponent(component, CGFloat(v), of: target) } }
                        .frame(width: 70)
                    stepper(c, up: { model.setFrameComponent(component, CGFloat((Double(value) ?? 0) + 1), of: target) },
                            down: { model.setFrameComponent(component, CGFloat((Double(value) ?? 0) - 1), of: target) })
                }
            }
        }
    }

    func stepper(_ c: ShellColors, up: @escaping () -> Void, down: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Button(action: up) { Image(systemName: "chevron.up").font(.system(size: 7, weight: .bold)).frame(width: 14, height: 10) }.buttonStyle(.plain)
            Button(action: down) { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).frame(width: 14, height: 10) }.buttonStyle(.plain)
        }
        .foregroundStyle(c.secondaryLabel)
        .background { Capsule(style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
    }

    /// Title, Placeholder (text fields), Alignment, Enabled and Hidden.
    func controlBlock(_ s: IBControlState, _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Control", c)
            if let t = s.title { keyed("Title", c) { field(t, c, target: "ib control title") { model.setTitle($0) } } }
            if let p = s.placeholder { keyed("Placeholder", c) { field(p, c, target: "ib control placeholder") { model.setPlaceholder($0) } } }
            if let a = s.alignment {
                keyed("Alignment", c) { CellPopUp(title: a, choices: IBControlState.alignments) { model.setAlignment($0) }.shellTarget("ib control alignment") }
            }
            keyed("State", c) { check("Enabled", s.isEnabled, c, target: "ib control enabled") { model.setEnabled($0) } }
            keyed("Drawing", c) { check("Hidden", s.isHidden, c, target: "ib control hidden") { model.setHidden($0) } }
        }
    }

    /// Each constraint mentioning the view, with its constant (0 removes it).
    func constants(_ cs: [IBDocument.Constraint], _ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("Constraint Constants", c)
            ForEach(cs, id: \.id) { con in
                Text(verbatim: con.text(model.document.name)).font(.system(size: 10)).foregroundStyle(c.secondaryLabel).lineLimit(2)
                keyed("Constant", c) {
                    field(con.constant, c, target: "ib constant \(con.id)") { if let v = Double($0) { model.setConstant(CGFloat(v), ofConstraint: con.id) } }
                }
            }
        }
    }
}

// MARK: Library

/// The Library (`library.md`) over the Interface Builder editor: the
/// Objects tab with its filter, the list (Ycode's own icons, name and
/// description) and the detail area. Double-click or Return inserts the
/// object into the selected view; Escape closes the panel.
struct IBLibraryPanel: View {
    var model: InterfaceBuilderShellModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var hasKeyboard: Bool

    var body: some View {
        let c = ShellColors(scheme)
        let list = model.libraryObjects
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: "Objects").font(ShellFonts.smallBold).foregroundStyle(c.label)
                    .padding(.horizontal, 12).frame(height: 22)
                    .background { Capsule(style: .continuous).fill(c.selectorPill) }
                Spacer(minLength: 0)
                Button { model.isLibraryShown = false } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(c.secondaryLabel).frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Close the Library")
                .shellTarget("ib library close")
            }
            .padding(8)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                InlineField(text: model.libraryFilter, placeholder: "Filter") { model.libraryFilter = $0 }
                    .shellTarget("ib library filter")
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            }
            .padding(.horizontal, 8)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(list, id: \.self) { o in item(o, selected: model.librarySelection == o, c) }
                }
                .padding(.vertical, 6)
            }
            .focusable()
            .focused($hasKeyboard)
            .onKeyPress(.downArrow) { model.moveLibrarySelection(1); return .handled }
            .onKeyPress(.upArrow) { model.moveLibrarySelection(-1); return .handled }
            .onKeyPress(.return) { model.insertFromLibrary(); return .handled }
            .onKeyPress(.escape) { model.isLibraryShown = false; return .handled }
            Hairline(color: c.separator)
            Text(verbatim: model.libraryDetail).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                .padding(10)
                .shellTarget("ib library detail")
        }
        .frame(width: 340, height: 420)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.content)
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .onAppear { hasKeyboard = true }
        .shellTarget("ib library")
    }

    func item(_ o: IBDocument.NewObject, selected: Bool, _ c: ShellColors) -> some View {
        HStack(spacing: 8) {
            IBObjectIcon(object: o, accent: c.accent).frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: o.rawValue).font(Font.system(size: 12, weight: .bold)).foregroundStyle(c.label)
                Text(verbatim: o.summary).font(ShellFonts.small).foregroundStyle(c.secondaryLabel).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 40)
        .background { if selected { RoundedRectangle(cornerRadius: 6, style: .continuous).fill(c.rowSelection) } }
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.insertFromLibrary(o) }
        .onTapGesture { model.librarySelection = o; hasKeyboard = true }
        .accessibilityLabel(o.rawValue)
        .shellTarget("ib library \(o.rawValue)")
    }
}

/// A Library object's icon, drawn from the shared shapes
/// (`IBLibraryObjects.swift`) in the accent colour.
struct IBObjectIcon: View {
    var object: IBDocument.NewObject
    var accent: Color

    var body: some View {
        let shapes = object.iconShapes
        Canvas { ctx, size in
            ctx.scaleBy(x: size.width / 26, y: size.height / 26)
            for s in shapes {
                switch s {
                case .backdrop(let r, let radius): ctx.fill(Path(roundedRect: r, cornerRadius: radius, style: .continuous), with: .color(accent.opacity(0.12)))
                case .fillRoundedRect(let r, let radius): ctx.fill(Path(roundedRect: r, cornerRadius: radius, style: .continuous), with: .color(accent))
                case .strokeRect(let r): ctx.stroke(Path(r), with: .color(accent), lineWidth: 1)
                case .fillRect(let r): ctx.fill(Path(r), with: .color(accent))
                case .fillOval(let r): ctx.fill(Path(ellipseIn: r), with: .color(accent))
                case .fillPolygon(let pts):
                    var p = Path()
                    p.addLines(pts)
                    p.closeSubpath()
                    ctx.fill(p, with: .color(accent))
                case .text(let t, let at, let size):
                    ctx.draw(Text(verbatim: t).font(.system(size: size, weight: .bold)).foregroundStyle(accent), at: at, anchor: .topLeading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Add New Constraints

/// Editor ▸ Add New Constraints… (§Constraints): spacing to the nearest
/// neighbor on each side (prefilled from the layout), Width and Height
/// (prefilled from the frame), and centering in the container.
struct IBAddConstraintsPanel: View {
    var model: InterfaceBuilderShellModel
    @State private var spacing: [IBDocument.Edge: String] = [:]
    @State private var edges: Set<IBDocument.Edge> = []
    @State private var width = ""
    @State private var height = ""
    @State private var useWidth = false
    @State private var useHeight = false
    @State private var centerX = false
    @State private var centerY = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let suggested = model.session.suggestedConstraints
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: "Add New Constraints").font(Font.system(size: 12, weight: .bold)).foregroundStyle(c.label)
            ForEach(IBDocument.Edge.allCases, id: \.self) { e in
                HStack(spacing: 6) {
                    toggle("Spacing to nearest neighbor: \(e.rawValue) (\(suggested?.spacing[e]?.neighbor ?? "-"))", edges.contains(e), c, target: "ib pin \(e.rawValue)") {
                        if $0 { edges.insert(e) } else { edges.remove(e) }
                    }
                    Spacer(minLength: 4)
                    numberField(Binding(get: { spacing[e] ?? "" }, set: { spacing[e] = $0 }), c, target: "ib pin value \(e.rawValue)")
                }
            }
            HStack { toggle("Width", useWidth, c, target: "ib pin width") { useWidth = $0 }; Spacer(minLength: 4); numberField($width, c, target: "ib pin width value") }
            HStack { toggle("Height", useHeight, c, target: "ib pin height") { useHeight = $0 }; Spacer(minLength: 4); numberField($height, c, target: "ib pin height value") }
            toggle("Horizontally in Container", centerX, c, target: "ib pin center x") { centerX = $0 }
            toggle("Vertically in Container", centerY, c, target: "ib pin center y") { centerY = $0 }
            HStack {
                Button("Cancel") { model.isAddConstraintsShown = false }.shellTarget("ib pin cancel")
                Spacer(minLength: 8)
                Button("Add Constraints") { model.addConstraints(spec) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChecks)
                    .shellTarget("ib pin add")
            }
            .padding(.top, 4)
        }
        .padding(14)
        .frame(width: 380)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(c.content)
                .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(c.capsuleStroke, lineWidth: 1) }
                .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        }
        .onAppear {
            if let s = suggested {
                for e in IBDocument.Edge.allCases { spacing[e] = IBDocument.number(s.spacing[e]?.value ?? 0) }
                width = IBDocument.number(s.size.width)
                height = IBDocument.number(s.size.height)
            }
        }
        .onKeyPress(.escape) { model.isAddConstraintsShown = false; return .handled }
        .shellTarget("ib add constraints")
    }

    /// Whether any box is checked (Add Constraints adds nothing otherwise).
    var hasChecks: Bool { !edges.isEmpty || useWidth || useHeight || centerX || centerY }

    var spec: IBDocument.NewConstraints {
        var s = IBDocument.NewConstraints()
        for e in edges { s.spacing[e] = CGFloat(Double(spacing[e] ?? "") ?? 0) }
        if useWidth { s.width = CGFloat(Double(width) ?? 0) }
        if useHeight { s.height = CGFloat(Double(height) ?? 0) }
        s.centerX = centerX
        s.centerY = centerY
        return s
    }

    func toggle(_ title: String, _ on: Bool, _ c: ShellColors, target: String, set: @escaping (Bool) -> Void) -> some View {
        Button { set(!on) } label: {
            HStack(spacing: 6) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 12)).foregroundStyle(on ? c.accent : c.secondaryLabel)
                Text(verbatim: title).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
        .shellTarget(target)
    }

    func numberField(_ text: Binding<String>, _ c: ShellColors, target: String) -> some View {
        TextField("", text: text)
            .textFieldStyle(.plain)
            .font(ShellFonts.small)
            .padding(.horizontal, 4)
            .frame(width: 56, height: 20)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(c.fieldFill)
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
            }
            .shellTarget(target)
    }
}
