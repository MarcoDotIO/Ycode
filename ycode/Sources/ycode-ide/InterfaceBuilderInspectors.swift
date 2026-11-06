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
                if tab == .attributes, !model.document.isFlippedRuntime, let state = model.controlState {
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
            keyed(l, c) { field(value, placeholder: ph, c, target: "ib field \(l.isEmpty ? attr : l)") { model.setAttribute(attr, $0, of: target) } }
        case .toggle(let l, _, _, let on, _, _):
            keyed("", c) { check(l, on, c, target: "ib toggle \(l)") { model.setToggle(r, on: $0) } }
        case .edgeToggle(let l, _, let edge, let on):
            keyed(edge == "top" ? "Extend Edges" : "", c) { check(l, on, c, target: "ib toggle \(l)") { model.setToggle(r, on: $0) } }
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
        case .check(let key, let title, _, let attr, let on, _, _):
            keyed(key, c) { check(title, on, c, target: "ib check \(attr)") { model.setToggle(r, on: $0) } }
        case .popUp(let key, _, let attr, let values, let titles, let value):
            keyed(key, c) {
                CellPopUp(title: values.firstIndex(of: value).map { titles[$0] } ?? value, choices: titles) { model.setChoice(r, $0) }
                    .shellTarget("ib popup \(attr)")
            }
        case .number(let key, let target, let attr, let value, let ph):
            keyed(key, c) { numberField(value, ph, c, target: target, attribute: attr) }
        case .numbers(let key, let fields):
            keyed(key, c) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Array(fields.enumerated()), id: \.offset) { pair in
                        VStack(spacing: 1) {
                            field(pair.element.value, placeholder: pair.element.placeholder, c, target: "ib number \(pair.element.attribute)") {
                                model.setAttribute(pair.element.attribute, $0, of: pair.element.target)
                            }
                            Text(verbatim: pair.element.caption).font(.system(size: 9)).foregroundStyle(c.secondaryLabel).lineLimit(1)
                        }
                    }
                }
            }
        case .combo(let key, let target, let attr, let value, let ph):
            keyed(key, c) {
                HStack(spacing: 2) {
                    field(value, placeholder: ph, c, target: "ib combo \(attr)") { model.setAttribute(attr, $0, of: target) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(c.secondaryLabel).frame(width: 12)
                }
            }
        case .color(let key, _, let colorKey, let value):
            keyed(key, c) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous).fill(IBLibraryPanel.swatch(value)).frame(width: 22, height: 14)
                        .overlay { RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(c.fieldStroke, lineWidth: 1) }
                    CellPopUp(title: value, choices: IBDocument.colorChoices.map(\.title)) { model.setColor(r, $0) }
                }
                .shellTarget("ib color \(colorKey)")
            }
        case .icons(let key, _, let attr, let values, let titles, let value):
            keyed(key, c) {
                HStack(spacing: 2) {
                    ForEach(Array(values.enumerated()), id: \.offset) { pair in
                        Button { model.setChoice(r, pair.element) } label: {
                            Group {
                                // Ycode's own glyph for the choice (IBLibraryObjects.swift).
                                if let g = IBIcon.choiceGlyph(attribute: attr, value: pair.element, ink: pair.element == value ? .white : (scheme == .dark ? .lightGray : .dark)) {
                                    IBIconView(icon: g).frame(width: 14, height: 14)
                                } else {
                                    Text(verbatim: String(titles[pair.offset].prefix(1))).font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(pair.element == value ? Color.white : c.label)
                                }
                            }
                                .frame(width: 20, height: 18)
                                .background {
                                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(pair.element == value ? c.accent : c.popUpFill)
                                }
                        }
                        .buttonStyle(.plain)
                        .help(titles[pair.offset])
                        .accessibilityLabel(titles[pair.offset])
                        .accessibilityValue(pair.element == value ? "on" : "off")
                        .shellTarget("ib icon \(attr) \(titles[pair.offset])")
                    }
                }
            }
        case .subheading(let t):
            Text(verbatim: t).font(ShellFonts.smallBold).foregroundStyle(c.secondaryLabel).padding(.top, 4)
        case .list(let key, let items):
            keyed(key, c) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { Text(verbatim: $0.element).font(ShellFonts.small).foregroundStyle(c.label).lineLimit(1) }
                    HStack(spacing: 4) {
                        Image(systemName: "plus").font(.system(size: 9, weight: .semibold))
                        Image(systemName: "minus").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(c.tertiaryLabel)
                }
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

    /// A number field with its stepper (one step up or down from the value).
    func numberField(_ value: String, _ ph: String, _ c: ShellColors, target: String, attribute: String) -> some View {
        let v = Double(value) ?? Double(ph) ?? 0
        func text(_ x: Double) -> String { x == x.rounded() ? String(Int(x)) : String(x) }
        return HStack(spacing: 4) {
            field(value, placeholder: ph, c, target: "ib number \(attribute)") { model.setAttribute(attribute, $0, of: target) }
            stepper(c, up: { model.setAttribute(attribute, text(v + 1), of: target) }, down: { model.setAttribute(attribute, text(v - 1), of: target) })
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
