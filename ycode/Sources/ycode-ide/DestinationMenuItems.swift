import SwiftUI
import YcodeBuild
import YcodeIDEShell

/// The run destination pop-up's items (docs/SIMULATOR-UX.md, "Choose a
/// destination"): one section per group with its title (My Computer, each
/// simulator host), the chosen destination checked. Destinations of one host
/// share a specifier, so items are keyed by position, not by specifier.
struct DestinationMenuItems: View {
    let model: WorkspaceShellModel
    let groups: [DestinationGroup]
    let secondary: Color

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.offset) { gi, group in
            if gi > 0 { Divider() }
            if groups.count > 1 {
                Text(verbatim: group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(secondary)
                    .padding(.horizontal, 12).padding(.top, 2)
            }
            ForEach(Array(group.destinations.enumerated()), id: \.offset) { _, d in
                Toggle(d.name, isOn: Binding(get: { model.destination == d }, set: { if $0 { model.destination = d } }))
            }
        }
    }
}
