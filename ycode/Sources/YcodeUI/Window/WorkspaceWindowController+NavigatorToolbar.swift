import AppKit
import YcodeIDECore

/// The toolbar with the navigator hidden (P-190, `window-layout.md` §5.1):
/// the Navigators / Coding Assistant group stays where it is (x 96–171)
/// and Run | Stop moves left to follow it (x 180–255), Back | Forward after
/// them; no "»" at 1400 points.
///
/// The navigator's section of an AppKit toolbar (the items before the
/// sidebar's tracking separator) is hidden with a collapsed sidebar on
/// macOS 27: council round 12 saw both items gone, Back | Forward next to
/// the traffic lights and "»" at 1400. So with the navigator hidden the
/// toolbar has no navigator section: the tracking separator and the
/// flexible space that pushes Run | Stop to the section's end leave the
/// toolbar, and the items they placed sit in one band. The switch happens
/// at the start of a hide and at the end of a show (§6.1), so the items
/// never travel with the sliding pane.
extension WorkspaceWindowController {
    /// The identifiers the navigator-shown arrangement adds after the
    /// group: the flexible space, then (after Run | Stop) the tracking
    /// separator.
    var navigatorSectionSeparator: NSToolbarItem.Identifier { FlushSidebar.separatorIdentifier }

    /// Whether the toolbar is in its navigator-hidden arrangement (tests).
    public var toolbarHasNavigatorSection: Bool {
        window?.toolbar?.items.contains { $0.itemIdentifier == navigatorSectionSeparator } ?? false
    }

    /// `updateToolbarState` on the next turn of the main queue, once for any
    /// number of requests: for observers that AppKit calls inside a layout
    /// pass, where changing toolbar items can raise.
    func scheduleToolbarStateUpdate() {
        guard !toolbarControls.stateScheduled else { return }
        toolbarControls.stateScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.toolbarControls.stateScheduled = false
                self.updateToolbarState()
            }
        }
    }

    /// Puts the toolbar in the arrangement for the navigator's state: hidden
    /// while the area is collapsed or sliding (a hide switches at its start,
    /// a show at its end).
    func syncNavigatorToolbarArrangement() {
        guard let navigatorItem else { return }
        setNavigatorToolbarHidden(navigatorItem.isCollapsed || isNavigatorSliding)
    }

    func setNavigatorToolbarHidden(_ hidden: Bool) {
        guard let toolbar = window?.toolbar else { return }
        let ids = toolbar.items.map(\.itemIdentifier)
        guard let group = ids.firstIndex(of: Self.leftPanesID), let run = ids.firstIndex(of: Self.runID) else { return }
        // Any separator on the navigator's divider counts, whatever its
        // identifier: a second one raises in AppKit.
        let separator = toolbar.items.firstIndex { item in
            item.itemIdentifier == navigatorSectionSeparator
                || ((item as? NSTrackingSeparatorToolbarItem).map { $0.splitView === mainSplit.splitView && $0.dividerIndex == 0 } ?? false)
        }
        let sectioned = separator != nil
        if hidden, let sep = separator {
            // Remove from the end so the indexes hold.
            toolbar.removeItem(at: sep)
            for i in stride(from: run - 1, to: group, by: -1) where ids[i] == .flexibleSpace { toolbar.removeItem(at: i) }
        } else if !hidden, !sectioned {
            toolbar.insertItem(withItemIdentifier: navigatorSectionSeparator, at: run + 1)
            toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: group + 1)
        } else {
            return
        }
        scheduleToolbarFit()
    }
}
