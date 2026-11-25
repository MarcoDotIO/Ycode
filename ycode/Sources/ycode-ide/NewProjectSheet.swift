import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// File ▸ New ▸ Project… on Linux (`templates.md` § Ycode implementation):
/// the core's flow as a sheet — platform tabs, a filter, the sectioned
/// grid with pinned section headers and the template's summary; the
/// options form; then the save step (Save As, Where with the toolkit's
/// folder dialog, Create Git repository, Add to, Group).
struct NewProjectSheet: View {
    @Bindable var model: NewProjectShellModel
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme
    /// The focused text field's option (P-178: Product Name on arrival).
    @FocusState private var focusedOption: String?
    /// The template step's focus: the grid on arrival (P-181).
    @FocusState private var chooserFocus: TemplateChooser.Focus?
    /// The options step fades in after Next (P-181).
    @State private var optionsOpacity = 1.0

    typealias M = TemplateChooserMetrics

    var body: some View {
        let c = ShellColors(scheme)
        Group {
            if model.step == .picker { picker(c).background(c.content) } else { pages(c).background(c.content) }
        }
        .fileImporter(isPresented: $model.isFolderDialogShown, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.location = url.path }
        }
    }

    func pages(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // P-181, P-182: the heading is regular weight.
            Text(verbatim: model.heading).font(.system(size: CGFloat(M.headingSize))).foregroundStyle(c.label)
            Group {
                switch model.step {
                case .picker, .template: templateStep(c)
                case .options: optionsStep(c).opacity(optionsOpacity)
                case .save: saveStep(c)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let e = model.error {
                Text(verbatim: e).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Cancel") { app.cancelNewProject() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).shellTarget("new project cancel")
                Spacer()
                Button("Previous") { model.previous() }.disabled(!model.isPreviousEnabled).buttonStyle(.bordered).shellTarget("new project previous")
                Button(model.nextTitle) { nextClicked() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.isNextEnabled)
                    .shellTarget("new project next")
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        // The macOS sheet's size (P-187: 720 × 480).
        .frame(width: CGFloat(M.sheetWidth), height: CGFloat(M.sheetHeight))
    }

    func nextClicked() {
        if model.step == .save {
            app.createNewProject()
            return
        }
        let wasTemplate = model.step == .template
        model.next()
        guard wasTemplate, model.step == .options else { return }
        // P-181: the options step fades in over about 190 ms.
        optionsOpacity = 0
        withAnimation(.easeOut(duration: M.optionsFadeDuration)) { optionsOpacity = 1 }
    }

    // MARK: Compact picker (P-187)

    /// File ▸ New ▸ Project…'s compact picker, as the macOS one: "+ New
    /// Project", the rows with their subtitles, then Cancel.
    func picker(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "+ " + NewProjectPicker.header).font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
            ForEach(Array(NewProjectPicker.rows.enumerated()), id: \.offset) { i, r in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: r.title).font(.system(size: 13, weight: .medium)).foregroundStyle(c.label)
                    Text(verbatim: r.subtitle).font(.system(size: 11)).foregroundStyle(c.secondaryLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { app.chooseNewProjectRow(i) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { app.chooseNewProjectRow(i) }
                .shellTarget("new project row \(r.title)")
            }
            Button("Cancel") { app.cancelNewProject() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered)
                .padding(.top, 8)
                .shellTarget("new project cancel")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(width: 340, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Template step

    func templateStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // P-181: small tabs at the left, the 202-point filter at the right.
            HStack(spacing: 8) {
                PlatformTabs(tabs: model.flow.tabs, selection: model.flow.platform) { model.setPlatform($0) }
                    .shellTarget("new project tabs")
                Spacer(minLength: 8)
                TextField("Filter", text: Binding(get: { model.flow.filter }, set: { model.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: CGFloat(M.filterWidth))
                    .focused($chooserFocus, equals: .filter)
                    .shellTarget("new project filter")
            }
            TemplateGrid(sections: model.flow.sections, selectedKey: model.flow.selected?.id, key: \.templateID,
                         select: { model.select($0.templateID) },
                         choose: { _ in nextClicked() })
                .focusable()
                .focused($chooserFocus, equals: .grid)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard let k = TemplateGrid.navigationKey(press.key),
                          let e = TemplateGrid.entry(moving: k, in: model.flow.sections, selectedKey: model.flow.selected?.id, key: \.templateID)
                    else { return .ignored }
                    model.select(e.templateID)
                    return .handled
                }
                .shellTarget("new project grid")
            // P-181: no description line; only the filter's empty state.
            if model.flow.selected == nil {
                Text(verbatim: model.flow.templateCaption).font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
            }
        }
        .onAppear { chooserFocus = .grid }
        // P-181: Tab goes between the filter and the grid.
        .onKeyPress(keys: [.tab]) { _ in
            chooserFocus = chooserFocus == .grid ? .filter : .grid
            return .handled
        }
    }

    // MARK: Options step

    func optionsStep(_ c: ShellColors) -> some View {
        // P-182: rows 20 tall on a 33-point pitch; labels in a 170-point
        // column, the controls 267 wide 8 points after it.
        VStack(alignment: .leading, spacing: CGFloat(M.rowSpacing)) {
            ForEach(model.flow.form.visibleFields, id: \.id) { f in
                HStack(spacing: CGFloat(M.labelGap)) {
                    Text(verbatim: f.kind == .checkbox ? "" : f.label + ":").font(.system(size: 13))
                        .foregroundStyle(model.flow.form.isEnabled(f.id) || f.kind == .derived || f.id == TemplateOptionID.team ? c.label : c.tertiaryLabel)
                        .frame(width: CGFloat(M.labelColumnWidth), alignment: .trailing)
                    field(f, c)
                }
                .frame(height: CGFloat(M.rowHeight))
                .help(f.help)   // P-178: every control has a help tag
                .shellTarget("option row \(f.id)")
            }
        }
        .padding(.top, CGFloat(M.optionsTop))
        .frame(maxWidth: .infinity)
        .onAppear { focusedOption = model.flow.form.visibleFields.first { $0.kind == .text }?.id }
        // P-178: Tab moves between the text fields only (Product Name ↔
        // Organization Identifier), as the AppKit sheet's key-view loop.
        .onKeyPress(keys: [.tab]) { press in
            let ids = model.flow.form.visibleFields.filter { $0.kind == .text && model.flow.form.isEnabled($0.id) }.map(\.id)
            guard ids.count > 1, let current = focusedOption, let i = ids.firstIndex(of: current) else { return .ignored }
            focusedOption = ids[(i + (press.modifiers.contains(.shift) ? ids.count - 1 : 1)) % ids.count]
            return .handled
        }
    }

    @ViewBuilder func field(_ f: TemplateOptionField, _ c: ShellColors) -> some View {
        let enabled = f.id == TemplateOptionID.team || model.flow.form.isEnabled(f.id)
        switch f.kind {
        case .text where f.id == TemplateOptionID.productName:
            // P-182: Product Name is borderless, without a focus ring.
            TextField(f.placeholder, text: Binding(get: { model.flow.form.value(f.id) }, set: { model.setOption(f.id, $0) }))
                .textFieldStyle(.plain)
                .frame(width: CGFloat(M.fieldWidth))
                .disabled(!enabled)
                .focused($focusedOption, equals: f.id)
                .shellTarget("option \(f.id)")
        case .text:
            TextField(f.placeholder, text: Binding(get: { model.flow.form.value(f.id) }, set: { model.setOption(f.id, $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: CGFloat(M.fieldWidth))
                .disabled(!enabled)
                .focused($focusedOption, equals: f.id)
                .shellTarget("option \(f.id)")
        case .popUp(let choices):
            Picker("", selection: Binding(get: { f.id == TemplateOptionID.team ? model.flow.team : model.flow.form.value(f.id) },
                                          set: { model.setOption(f.id, $0) })) {
                ForEach(choices.filter { f.id == TemplateOptionID.team || model.flow.form.isAllowed(f.id, $0.value) }, id: \.value) {
                    Text(verbatim: $0.title).tag($0.value)
                }
            }
            // P-182: 267 wide and 20 tall, the value at the start and the
            // chevrons at the end, as the AppKit pop-ups.
            .menuStyle(.borderlessButton)
            .frame(width: CGFloat(M.fieldWidth), height: CGFloat(M.rowHeight))
            .disabled(!enabled)
            .shellTarget("option \(f.id)")
        case .checkbox:
            Toggle(f.label, isOn: Binding(get: { model.flow.form.bool(f.id) }, set: { model.setOption(f.id, $0 ? "true" : "false") }))
                .toggleStyle(.checkbox)
                .frame(width: CGFloat(M.fieldWidth), alignment: .leading)
                .disabled(!enabled)
                .shellTarget("option \(f.id)")
        case .derived:
            Text(verbatim: model.flow.form.value(f.id)).font(.system(size: 13))
                .foregroundStyle(model.flow.form.isBundleIdentifierPlaceholder ? c.tertiaryLabel : c.secondaryLabel)
        }
    }

    // MARK: Save step

    func saveStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Save As:", c) { TextField("", text: $model.saveAs).textFieldStyle(.roundedBorder).frame(width: 300).shellTarget("save as") }
            row("Where:", c) {
                HStack {
                    TextField("", text: $model.location).textFieldStyle(.roundedBorder).frame(width: 300).shellTarget("save where")
                    Button("Choose…") { model.isFolderDialogShown = true }.buttonStyle(.bordered)
                }
            }
            row("Source Control:", c) { Toggle("Create Git repository on my computer", isOn: $model.createGitRepository).toggleStyle(.checkbox).shellTarget("save git") }
            row("Add to:", c) {
                Picker("", selection: $model.addToOpenContainer) {
                    Text(verbatim: "Don't add to any project or workspace").tag(false)
                    if let w = model.openContainer { Text(verbatim: w.lastPathComponent).tag(true) }
                }
                .frame(width: 300)
            }
            row("Group:", c) {
                Picker("", selection: $model.group) {
                    ForEach(model.groups, id: \.title) { g in Text(verbatim: String(repeating: "  ", count: g.depth) + g.title).tag(g.key) }
                }
                .frame(width: 300)
                .disabled(model.groups.isEmpty)
            }
            // L-154: as the macOS accessory, Add to = a project offers a new
            // workspace for both projects.
            row("", c) {
                Toggle("Save both projects in a new workspace", isOn: $model.newWorkspaceForProject)
                    .toggleStyle(.checkbox)
                    .disabled(!model.offersNewWorkspace)
                    .shellTarget("save new workspace")
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    func row<V: View>(_ label: String, _ c: ShellColors, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(c.label).frame(width: 170, alignment: .trailing)
            content()
        }
    }
}
