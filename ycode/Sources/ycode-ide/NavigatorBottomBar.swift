import Foundation
import SwiftUI
import YcodeIDECore
import YcodeIDEShell

/// The navigators' bottom bar (P-037, P-040; `NavigatorBars.specs`): the
/// left pull-down in a circle ("+" or the action "…"), then the filter
/// capsule: the options pull-down (accent-coloured with its chevron while
/// the filter is active; its menu the recent filters and Clear Recents),
/// the field, and the navigator's in-field toggles, which filter.
struct NavigatorFilterBar: View {
    var model: WorkspaceShellModel
    var navigator: Int
    var spec: NavigatorBarSpec
    /// A navigator Ycode does not have yet: the bar is drawn, disabled.
    var isPlaceholder = false
    @FocusState private var fieldFocused: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let h = CGFloat(WorkspaceChrome.filterBarHeight)
        HStack(spacing: CGFloat(WorkspaceChrome.plusToFilter)) {
            if spec.left != .none {
                Menu { leftMenu } label: {
                    // "…" in the circle (the macOS bar's ellipsis.circle; OpenViews draws the ellipsis).
                    Image(systemName: spec.left == .more ? "ellipsis" : "plus").font(.system(size: 13))
                        .foregroundStyle(isPlaceholder ? c.tertiaryLabel : c.secondaryLabel)
                        .frame(width: CGFloat(WorkspaceChrome.plusCircleWidth), height: h)
                        .background { PaneCapsule(height: h) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isPlaceholder)
                .help(leftToolTip)
                .shellTarget("navigator add")
            }
            HStack(spacing: 3.5) {
                optionsMenu(c)
                TextField(NavigatorBars.filterPlaceholder, text: Binding(get: { model.filterText(navigator) },
                                                                        set: { model.setFilterText($0, navigator: navigator) }))
                    .textFieldStyle(.plain)
                    .font(ShellFonts.row)
                    .focused($fieldFocused)
                    .disabled(isPlaceholder)
                    .onSubmit { model.noteFilterRecent(navigator) }
                    .accessibilityLabel(NavigatorBars.filterPlaceholder)
                    .accessibilityValue(model.filterText(navigator))
                    .shellTarget("navigator filter")
                ForEach(Array(spec.toggles.enumerated()), id: \.offset) { pair in
                    let on = model.isFilterToggleOn(pair.offset, navigator: navigator)
                    Button { model.setFilterToggle(pair.offset, on: !on, navigator: navigator) } label: {
                        Image(systemName: pair.element.symbol).font(.system(size: 12))
                            .foregroundStyle(on ? c.accent : c.tertiaryLabel)
                    }
                    .buttonStyle(.plain)
                    .disabled(isPlaceholder)
                    .help(pair.element.toolTip)
                    .accessibilityLabel(pair.element.title)
                    .accessibilityValue(on ? "on" : "off")
                    .shellTarget("navigator toggle \(pair.offset)")
                }
            }
            .padding(.leading, 6.5)
            .padding(.trailing, 9)
            .frame(height: h)
            .background { PaneCapsule(height: h) }
        }
        .padding(.leading, CGFloat(WorkspaceChrome.filterBarLeading))
        .padding(.trailing, CGFloat(WorkspaceChrome.filterBarTrailing))
        .padding(.bottom, CGFloat(WorkspaceChrome.filterBarBottomInset))
        .padding(.top, 4)
        // The filter is remembered once the field is left.
        .onChange(of: fieldFocused) { _, on in if !on { model.noteFilterRecent(navigator) } }
    }

    /// The options pull-down: the lines in a circle and a chevron 1.5 after
    /// it; "Filter" begins 33.5 in (metrics.md §15). Accent-coloured while
    /// the filter is active (P-037).
    func optionsMenu(_ c: ShellColors) -> some View {
        let active = model.isFilterActive(navigator)
        return Menu {
            ForEach(Array(model.filterMenu(navigator).enumerated()), id: \.offset) { pair in
                switch pair.element {
                case .recent(let t): Button(t) { model.chooseRecentFilter(t, navigator: navigator) }
                case .separator: Divider()
                case .clearRecents(let enabled):
                    Button(NavigatorFilterModel.clearRecents) { model.clearFilterRecents(navigator) }.disabled(!enabled)
                }
            }
        } label: {
            HStack(spacing: 1.5) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 13, weight: .light))
                Image(systemName: "chevron.down").font(.system(size: 6))
            }
            // #ABABAC in dark (editor-area.md F.9, row 110), #777777 in
            // light (H.9, row 165); the accent while filtering.
            .foregroundStyle(active ? c.accent : IssueSymbol.color(WorkspaceChrome.filterGlyph(dark: scheme == .dark)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isPlaceholder)
        .help("Filter options")
        .shellTarget("navigator filter options")
    }

    var leftToolTip: String {
        if case .add(let t) = spec.left { return t ?? "Add" }
        return "More"
    }

    /// The left pull-down's items (P-040): the Project navigator's "+"
    /// (`ProjectRowMenu.addMenu`), Breakpoints' kinds, the action menus of
    /// Source Control, Tests and Reports.
    @ViewBuilder
    var leftMenu: some View {
        switch ShellNavigator.allCases.first(where: { $0.selectorIndex == navigator }) {
        case .project?:
            ProjectRowMenuItems(model: model, entries: ProjectRowMenu.addMenu, rows: [], kind: .project)   // ProjectNavigatorViews.swift
        case .breakpoints?:
            BreakpointAddMenuItems(model: model)   // DebugEditors.swift
        case .sourceControl?:
            Button("Commit…") { model.perform(.scmCommit) }.disabled(!model.isEnabled(.scmCommit))
            Button("Refresh File Status") { model.perform(.scmRefresh) }.disabled(!model.isEnabled(.scmRefresh))
            Button("Fetch Changes") { model.perform(.scmFetch) }.disabled(!model.isEnabled(.scmFetch))
        case .tests?:
            // The Test navigator's add items (Ycode cannot make test targets on Linux yet).
            Button("New Unit Test Target…") {}.disabled(true)
            Button("New UI Test Target…") {}.disabled(true)
            Button("New Unit Test Class…") { model.navigatorState.newFileFromTemplate?() }
                .disabled(model.navigatorState.newFileFromTemplate == nil)
        case .reports?:
            Button(Self.showBuildFolderTitle) {}.disabled(true)
        default:
            EmptyView()
        }
    }

    static let showBuildFolderTitle = OrganizerState.showInFilesTitle.replacingOccurrences(of: "Show in", with: "Show Build Folder in")
}
