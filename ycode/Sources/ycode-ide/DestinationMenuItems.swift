import SwiftUI
import YcodeBuild
import YcodeIDECore
import YcodeIDEShell

/// Product ▸ Destination (P-014, `specs/ide/popovers.md` §9), as the
/// AppKit IDE's: Choose Destination, Select Next / Previous Destination,
/// Show All Run Destinations; then the Devices, Simulators and Build
/// headings drawn as headings (small secondary type, not rows), each only
/// when it has rows, every row "<name> <OS version>" with the current one
/// checked; Incompatible ▸ (its rows enabled; empty and disabled when
/// there are none); Manage Devices…. `items` is the submenu's table
/// (`CommandTable`); its commands are drawn by `MenuSpecItems`.
struct DestinationMenuItems: View {
    var app: ShellAppModel
    let model: WorkspaceShellModel
    let items: [MenuItemSpec]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let c = ShellColors(scheme)
        let parts = Self.split(items)
        MenuSpecItems(app: app, items: parts.head)
        ForEach(Array(DestinationProductMenu.sections(groups: model.session.model.destinationGroups).enumerated()), id: \.offset) { pair in
            Divider()
            Text(verbatim: pair.element.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(c.secondaryLabel)
                .padding(.horizontal, 12).padding(.top, 2)
                .shellTarget("destination heading \(pair.element.title)")
            ForEach(Array(pair.element.destinations.enumerated()), id: \.offset) { _, d in
                Toggle(DestinationProductMenu.title(d), isOn: Binding(get: { model.destination == d }, set: { if $0 { model.destination = d } }))
            }
        }
        Divider()
        // The Linux IDE lists no destination it cannot run on (no Apple
        // platforms here), so the cascade is empty and disabled.
        Menu(DestinationMenuModel.incompatibleTitle) { EmptyView() }.disabled(true)
        Divider()
        MenuSpecItems(app: app, items: parts.tail)
    }

    /// The table's commands before the first heading, and those after
    /// Incompatible (Manage Devices…).
    static func split(_ items: [MenuItemSpec]) -> (head: [MenuItemSpec], tail: [MenuItemSpec]) {
        let first = items.firstIndex { if case .label = $0 { return true }; return false } ?? items.count
        let inc = items.firstIndex { if case .submenu(let t, _) = $0 { return t == DestinationMenuModel.incompatibleTitle }; return false }
        let head = Array(items[..<first]).filter { if case .label = $0 { return false }; return true }
        let tail = inc.map { Array(items[($0 + 1)...]) } ?? []
        return (head, tail)
    }
}
