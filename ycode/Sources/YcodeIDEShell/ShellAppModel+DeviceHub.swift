import Foundation
import YcodeIDECore

extension ShellAppModel {
    /// The Device Hub window's scene id.
    public static let deviceHubWindowID = "device-hub"

    /// Product ▸ Destination ▸ Manage Devices… (⇧⌘2) and Ycode ▸ Open
    /// Developer Tool ▸ Device Hub: opens (or brings forward) the hub, with
    /// or without a workspace (`specs/ide/device-hub.md`, 2026-11-17).
    public func showDevices() {
        deviceHub.refresh()
        openWindow(Self.deviceHubWindowID)
    }
}
