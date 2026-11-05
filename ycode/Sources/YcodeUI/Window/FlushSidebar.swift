import AppKit

/// The workspace's navigator flush with the window's edges on every system:
/// it runs the window's full height from its leading edge, with no floating
/// panel (`liquid-glass.md` G2, `specs/ide/metrics.md` §14.1).
///
/// macOS 15 and 27 draw a sidebar split item (`sidebarWithViewController:`)
/// flush. macOS 26 draws it as a glass panel floating 8 points inside the
/// window's leading, top and bottom edges, with a toolbar section of its own
/// whose items are smaller (28 points tall): the navigator measured x 8, 282
/// wide, and Run | Stop x 225 instead of 208.5. On macOS 26 Ycode therefore
/// uses a plain split item that behaves like a sidebar (it collapses, holds
/// its width when the window resizes), puts the system's sidebar material
/// behind its content, and tracks its divider with a tracking separator of
/// its own; the toolbar then lays out as on the other systems.
///
/// Device Hub keeps the system's item: its window shows its title, which
/// the toolbar puts after the sidebar's section, and without a sidebar item
/// at its leading end, ahead of the sidebar's group (`metrics.md` §14.1).
@MainActor
enum FlushSidebar {
    /// Tests set it to try either layout on any system; nil follows the
    /// system.
    static var forced: Bool?

    /// Whether the plain item replaces the system's sidebar item.
    static var isActive: Bool {
        forced ?? (ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26)
    }

    /// The sidebar's holding priority: a sidebar keeps its width while the
    /// window resizes, the content takes the change.
    static let holdingPriority = NSLayoutConstraint.Priority(rawValue: 260)

    /// The split item for a sidebar showing `content`: the system's sidebar
    /// item, or on macOS 26 a plain item over the sidebar material. With an
    /// `overhang` the content and its material reach that far past the item
    /// over the divider, as the system's sidebar runs to the next area with
    /// no divider of its own: the item is then that much narrower than the
    /// sidebar (`width(of:)`).
    static func item(for content: NSViewController, overhang: CGFloat = 0) -> NSSplitViewItem {
        guard isActive else { return NSSplitViewItem(sidebarWithViewController: content) }
        let item = NSSplitViewItem(viewController: FlushSidebarController(content: content, overhang: overhang))
        item.canCollapse = true
        item.canCollapseFromWindowResize = true
        item.holdingPriority = holdingPriority
        return item
    }

    /// The divider position that gives the sidebar `width`.
    static func position(forWidth width: CGFloat, of item: NSSplitViewItem) -> CGFloat {
        width - ((item.viewController as? FlushSidebarController)?.overhang ?? 0)
    }

    /// The toolbar's separator over the sidebar's divider: the system's
    /// sidebar tracking separator, or ours for the plain item.
    static var separatorIdentifier: NSToolbarItem.Identifier { isActive ? trackingSeparatorID : .sidebarTrackingSeparator }
    nonisolated static let trackingSeparatorID = NSToolbarItem.Identifier("YcodeSidebarTrackingSeparator")

    /// The tracking separator for `id` (nil for any other identifier): it
    /// follows the first divider of `splitView`.
    static func trackingSeparator(_ id: NSToolbarItem.Identifier, splitView: NSSplitView) -> NSToolbarItem? {
        guard id == trackingSeparatorID else { return nil }
        return NSTrackingSeparatorToolbarItem(identifier: id, splitView: splitView, dividerIndex: 0)
    }
}

/// A plain split item's content over the system's sidebar material, as the
/// sidebar item draws it (Reduce Transparency, Increase Contrast and the
/// inactive look are the material's own). Both reach `overhang` points past
/// the item's trailing edge, over the divider; the split view still takes
/// the divider's drags there (it hit-tests its dividers before its
/// subviews).
@MainActor
final class FlushSidebarController: NSViewController {
    let content: NSViewController
    let overhang: CGFloat

    init(content: NSViewController, overhang: CGFloat) {
        self.content = content
        self.overhang = overhang
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()
        root.clipsToBounds = false
        view = root
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState
        addChild(content)
        for v in [background, content.view] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: root.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: overhang),
            ])
        }
    }
}
