import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// File ▸ New ▸ File from Template… (⌘N) on Linux (P-187, L-151): the
/// macOS New File sheet, 720 × 480. The template step is the chooser
/// (`TemplateChooserViews.swift`); Next shows the save step's fields
/// (Save As, Group, Targets) in the sheet, since OpenViews' file dialog
/// takes no accessory; Create writes the files into the project.
struct NewFileSheet: View {
    @Bindable var model: NewFileShellModel
    var app: ShellAppModel
    @Environment(\.colorScheme) private var scheme
    @FocusState private var chooserFocus: TemplateChooser.Focus?
    @FocusState private var nameFocused: Bool

    typealias M = TemplateChooserMetrics

    var body: some View {
        let c = ShellColors(scheme)
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: model.step == .template ? model.heading : "Save your new file:")
                .font(.system(size: CGFloat(M.headingSize))).foregroundStyle(c.label)
            Group {
                switch model.step {
                case .template: templateStep(c)
                case .save: saveStep(c)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if let e = model.error {
                Text(verbatim: e).font(.system(size: 11)).foregroundStyle(.red)
            }
            HStack(spacing: 8) {
                Button("Cancel") { app.cancelNewFile() }.keyboardShortcut(.cancelAction).buttonStyle(.bordered).shellTarget("new file cancel")
                Spacer()
                Button("Previous") { model.previous() }.disabled(!model.isPreviousEnabled).buttonStyle(.bordered).shellTarget("new file previous")
                // P-184: Next is 96 points wide.
                Button { nextClicked() } label: { Text(verbatim: model.nextTitle).frame(minWidth: 72) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .frame(width: 96)
                    .disabled(!model.isNextEnabled)
                    .shellTarget("new file next")
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(width: CGFloat(M.sheetWidth), height: CGFloat(M.sheetHeight))
        .background(c.content)
    }

    func nextClicked() {
        if model.step == .save { app.createNewFile() } else { model.next() }
    }

    func templateStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                PlatformTabs(tabs: model.tabs, selection: model.platform) { model.setPlatform($0) }
                    .shellTarget("new file tabs")
                Spacer(minLength: 8)
                TextField("Filter", text: Binding(get: { model.filter }, set: { model.setFilter($0) }))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: CGFloat(M.filterWidth))
                    .focused($chooserFocus, equals: .filter)
                    .shellTarget("new file filter")
            }
            TemplateGrid(sections: model.sections, selectedKey: model.selected?.title, key: \.title,
                         select: { model.select($0.title) }, choose: { _ in model.next() })
                .focusable()
                .focused($chooserFocus, equals: .grid)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    guard let k = TemplateGrid.navigationKey(press.key),
                          let e = TemplateGrid.entry(moving: k, in: model.sections, selectedKey: model.selected?.title, key: \.title)
                    else { return .ignored }
                    model.select(e.title)
                    return .handled
                }
                .shellTarget("new file grid")
            if model.selected == nil {
                Text(verbatim: "No templates match “\(model.filter)”.").font(.system(size: 12)).foregroundStyle(c.secondaryLabel)
            }
        }
        .onAppear { chooserFocus = .grid }
        .onKeyPress(keys: [.tab]) { _ in
            chooserFocus = chooserFocus == .grid ? .filter : .grid
            return .handled
        }
    }

    func saveStep(_ c: ShellColors) -> some View {
        VStack(alignment: .leading, spacing: CGFloat(M.rowSpacing)) {
            row("Save As:", c) {
                TextField("", text: $model.saveAs).textFieldStyle(.roundedBorder).frame(width: CGFloat(M.fieldWidth))
                    .focused($nameFocused)
                    .shellTarget("new file save as")
            }
            row("Group:", c) {
                Picker("", selection: $model.groupIndex) {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { i, g in
                        Text(verbatim: String(repeating: "  ", count: g.depth) + g.title).tag(i)
                    }
                }
                .menuStyle(.borderlessButton)
                .frame(width: CGFloat(M.fieldWidth), height: CGFloat(M.rowHeight))
                .shellTarget("new file group")
            }
            ForEach(Array(model.targets.enumerated()), id: \.offset) { i, t in
                row(i == 0 ? "Targets:" : "", c) {
                    Toggle(t, isOn: Binding(get: { model.checkedTargets.contains(t) }, set: { model.setTarget(t, checked: $0) }))
                        .toggleStyle(.checkbox)
                        .shellTarget("new file target \(t)")
                }
            }
        }
        .padding(.top, CGFloat(M.optionsTop))
        .frame(maxWidth: .infinity)
        .onAppear { nameFocused = true }
    }

    func row<V: View>(_ label: String, _ c: ShellColors, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: CGFloat(M.labelGap)) {
            Text(verbatim: label).font(.system(size: 13)).foregroundStyle(c.label)
                .frame(width: CGFloat(M.labelColumnWidth), alignment: .trailing)
            content()
        }
        .frame(height: CGFloat(M.rowHeight))
    }
}
