import AppKit

/// View ▸ Navigators ▸ <navigator> (⌘1–⌘9) on the navigator already shown
/// hides the navigator area; the next press shows it again
/// (`specs/ide/parity-inventory.md` P-036: the reference toggles).
extension WorkspaceWindowController {
    /// Hides the left area when `sender` (a menu item, as from ⌘1–⌘9) asks
    /// for the navigator it already shows; true when it did.
    func hidesNavigatorShown(by sender: Any?) -> Bool {
        guard let item = sender as? NSMenuItem, !navigatorItem.isCollapsed, !navigator.showsCodingAssistant,
              navigator.selectedIndex == item.tag else { return false }
        toggleNavigator(sender)   // the area slides closed, as Hide Navigator
        return true
    }
}
