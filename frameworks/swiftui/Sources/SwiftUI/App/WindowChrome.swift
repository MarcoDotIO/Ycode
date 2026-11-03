import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// A main window's chrome (round R11): the menu bar (MenuBar.swift) and the
// window toolbar (Toolbar.swift) above the scene's content, and a bottom bar
// below it when toolbar items ask for one. The commands host, which builds
// the commands' item views without laying them out (Commands.swift), is part
// of the window's root (AppHost.swift). Pop-up windows and the headless test
// host without a menu bar show the content alone.

/// The sidebar of a window's split view, for View > Show/Hide Sidebar.
@MainActor
@Observable
package final class SidebarController {
    package var isVisible = true
    @ObservationIgnored var toggleAction: (() -> Void)?
    package init() {}
    package func toggle() { toggleAction?() }
}

/// What a window's chrome shows.
@MainActor
struct WindowChromeConfiguration {
    var menuBar: Bool
    let commands: CommandsModel
    let actions: AppCommandActions
}
