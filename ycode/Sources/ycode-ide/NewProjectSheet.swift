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

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(verbatim: model.heading).font(.system(size: 13, weight: .bold)).foregroundStyle(c.label)
                Spacer()
                if model.step == .template {
                    TextField("Filter", text: Binding(get: { model.flow.filter }, set: { model.setFilter($0) }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .shellTarget("new project filter")
                }
            }
            Group {
                switch model.step {
                case .template: templateStep(c)
                case .options: optionsStep(c)
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
                Button(model.nextTitle) {
                    if model.step == .save { app.createNewProject() } else { model.next() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!model.isNextEnabled)
                .shellTarget("new project next")
            }
        }
        .padding(16)
        .frame(width: 760, height: 540)
        .background(c.content)
        .fileImporter(isPresented: $model.isFolderDialogShown, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.location = url.path }
        }
    }

    // MARK: Template step

    func templateStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { model.flow.platform }, set: { model.setPlatform($0) })) {
                ForEach(model.flow.tabs, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .pickerStyle(.segmented)
            .shellTarget("new project tabs")
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.flow.sections, id: \.title) { section in
                        Text(verbatim: section.title).font(.system(size: 11, weight: .bold)).foregroundStyle(c.secondaryLabel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        // Six to a row; a catalog tab has a few dozen at most.
                        ForEach(Array(stride(from: 0, to: section.entries.count, by: 6)), id: \.self) { start in
                            HStack(spacing: 4) {
                                ForEach(section.entries[start..<min(start + 6, section.entries.count)], id: \.templateID) { tile($0, c) }
                            }
                        }
                    }
                }
                .padding(8)
            }
            .background(c.sidebar)
            Text(verbatim: model.flow.templateCaption).font(.system(size: 12))
                .foregroundStyle(model.flow.selected?.isAvailable == false ? Color.orange : c.secondaryLabel)
        }
    }

    func tile(_ e: TemplateEntry, _ c: ShellColors) -> some View {
        let selected = model.flow.selected?.id == e.templateID
        return VStack(spacing: 4) {
            symbol(e.symbol).font(.system(size: 28)).foregroundStyle(selected ? Color.white : Color.accentColor).frame(height: 40)
            Text(verbatim: e.title).font(.system(size: 11)).multilineTextAlignment(.center).lineLimit(2)
                .foregroundStyle(selected ? Color.white : c.label)
        }
        .frame(width: 104, height: 92)
        .background { if selected { RoundedRectangle(cornerRadius: 6).fill(Color.accentColor) } }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.select(e.templateID); model.next() }
        .onTapGesture { model.select(e.templateID) }
        .shellTarget("template \(e.title)")
    }

    // MARK: Options step

    func optionsStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.flow.form.visibleFields, id: \.id) { f in
                HStack(spacing: 8) {
                    Text(verbatim: f.kind == .checkbox ? "" : f.label + ":").font(.system(size: 13))
                        .foregroundStyle(model.flow.form.isEnabled(f.id) || f.kind == .derived || f.id == TemplateOptionID.team ? c.label : c.tertiaryLabel)
                        .frame(width: 170, alignment: .trailing)
                    field(f, c)
                }
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder func field(_ f: TemplateOptionField, _ c: ShellColors) -> some View {
        let enabled = f.id == TemplateOptionID.team || model.flow.form.isEnabled(f.id)
        switch f.kind {
        case .text:
            TextField(f.placeholder, text: Binding(get: { model.flow.form.value(f.id) }, set: { model.setOption(f.id, $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .disabled(!enabled)
                .shellTarget("option \(f.id)")
        case .popUp(let choices):
            Picker("", selection: Binding(get: { f.id == TemplateOptionID.team ? model.flow.team : model.flow.form.value(f.id) },
                                          set: { model.setOption(f.id, $0) })) {
                ForEach(choices.filter { f.id == TemplateOptionID.team || model.flow.form.isAllowed(f.id, $0.value) }, id: \.value) {
                    Text(verbatim: $0.title).tag($0.value)
                }
            }
            .frame(width: 300)
            .disabled(!enabled)
            .shellTarget("option \(f.id)")
        case .checkbox:
            Toggle(f.label, isOn: Binding(get: { model.flow.form.bool(f.id) }, set: { model.setOption(f.id, $0 ? "true" : "false") }))
                .toggleStyle(.checkbox)
                .frame(width: 300, alignment: .leading)
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
            row("Source Control:", c) { Toggle("Create Git repository on this computer", isOn: $model.createGitRepository).toggleStyle(.checkbox).shellTarget("save git") }
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
