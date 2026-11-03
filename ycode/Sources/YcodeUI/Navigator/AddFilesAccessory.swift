import AppKit
import YcodeIDECore
import YcodeProject

/// The options under Add Files…'s open panel: Action (copy, move or
/// reference), Groups (folders, groups or folder references) and one
/// checkbox per target. Ycode's own layout and wording
/// (`specs/ide/navigators.md` §Ycode implementation).
@MainActor
public final class AddFilesAccessory: NSObject {
    public let actionPopUp = NSPopUpButton()
    public let groupingPopUp = NSPopUpButton()
    public private(set) var targetBoxes: [NSButton] = []
    /// Target object IDs, in project order (one per checkbox).
    public let targetIDs: [String]
    public private(set) lazy var view: NSView = makeView()
    private let initial: AddFilesOptions
    private let targetNames: [String]

    public init(project: PBXProj?, options: AddFilesOptions) {
        initial = options
        targetIDs = project?.targets.map(\.id) ?? []
        targetNames = project?.targets.map { $0.string("name") ?? $0.id } ?? []
        super.init()
    }

    /// The options as the controls show them.
    public var options: AddFilesOptions {
        _ = view
        let action = AddFilesOptions.Action.allCases[max(0, actionPopUp.indexOfSelectedItem)]
        let grouping = AddFilesOptions.Grouping.allCases[max(0, groupingPopUp.indexOfSelectedItem)]
        let targets = zip(targetIDs, targetBoxes).filter { $0.1.state == .on }.map(\.0)
        return AddFilesOptions(action: action, grouping: grouping, targets: targets)
    }

    private func makeView() -> NSView {
        actionPopUp.addItems(withTitles: AddFilesOptions.Action.allCases.map(\.rawValue))
        actionPopUp.selectItem(at: AddFilesOptions.Action.allCases.firstIndex(of: initial.action) ?? 0)
        groupingPopUp.addItems(withTitles: AddFilesOptions.Grouping.allCases.map(\.rawValue))
        groupingPopUp.selectItem(at: AddFilesOptions.Grouping.allCases.firstIndex(of: initial.grouping) ?? 0)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Action:"), actionPopUp],
            [NSTextField(labelWithString: "Groups:"), groupingPopUp],
        ])
        targetBoxes = zip(targetIDs, targetNames).map { id, name in
            let b = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            b.state = initial.targets.contains(id) ? .on : .off
            return b
        }
        if !targetBoxes.isEmpty {
            let stack = NSStackView(views: targetBoxes)
            stack.orientation = .vertical
            stack.alignment = .leading
            grid.addRow(with: [NSTextField(labelWithString: "Targets:"), stack])
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            grid.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 20),
        ])
        box.frame.size = box.fittingSize
        return box
    }
}
