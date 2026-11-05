import Foundation
import YcodeIDECore

extension ShellAppModel {
    /// The Organizer window's scene id.
    public static let organizerWindowID = "organizer"

    /// Window ▸ Organizer: reads the archives again and opens (or brings
    /// forward) the Organizer window on its current page.
    public func showOrganizer() {
        organizer.reload()
        openWindow(Self.organizerWindowID)
    }
}
