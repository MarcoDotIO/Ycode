import AppKit
import YcodeIDECore
import YcodeSimFeatures

/// The Debug menu's Ycode-simulator items (`specs/ide/debug.md`
/// §Environment Overrides and Simulate Location): Simulate Location ▸ (the
/// debug bar's menu), View Debugging ▸ Disable All Environment Overrides
/// and Appearance ▸. They act on the app running on the Ycode simulator
/// through the same control commands as the debug bar, and are disabled
/// without such a run.
extension WorkspaceWindowController {
    /// A run on the Ycode simulator takes overrides and locations.
    var simulatorRunTakesOverrides: Bool {
        debugArea.syncWithRun()
        return debugArea.applyEnvironmentOverrides != nil && debugArea.simulatorRunKey?() != nil
    }

    /// Debug ▸ View Debugging ▸ Disable All Environment Overrides.
    @objc public func disableAllEnvironmentOverrides(_ sender: Any?) { disableAllOverrides() }

    @discardableResult
    public func disableAllOverrides() -> Task<(Bool, String), Never>? { sendEnvironmentOverrides(EnvironmentOverrides()) }

    @objc public func debugAppearanceSystem(_ sender: Any?) { _ = chooseDebugAppearance(0) }
    @objc public func debugAppearanceLight(_ sender: Any?) { _ = chooseDebugAppearance(1) }
    @objc public func debugAppearanceDark(_ sender: Any?) { _ = chooseDebugAppearance(2) }
    @objc public func debugAppearanceHighContrastLight(_ sender: Any?) { _ = chooseDebugAppearance(3) }
    @objc public func debugAppearanceHighContrastDark(_ sender: Any?) { _ = chooseDebugAppearance(4) }

    /// Debug ▸ View Debugging ▸ Appearance ▸ <item>.
    @discardableResult
    public func chooseDebugAppearance(_ index: Int) -> Task<(Bool, String), Never>? {
        debugArea.syncWithRun()
        return sendEnvironmentOverrides(DebugAppearanceMenu.apply(index, to: debugArea.environmentOverrides))
    }

    /// Applies overrides to the running app as the pop-over does.
    func sendEnvironmentOverrides(_ o: EnvironmentOverrides) -> Task<(Bool, String), Never>? {
        guard simulatorRunTakesOverrides, let apply = debugArea.applyEnvironmentOverrides else { NSSound.beep(); return nil }
        debugArea.environmentOverrides = o
        return Task { await apply(o) }
    }

    /// Enablement and check marks of these items; nil = not one of them.
    func validateSimulatorDebugMenuItem(_ item: NSMenuItem) -> Bool? {
        guard let a = item.action else { return nil }
        let name = NSStringFromSelector(a)
        if let i = DebugAppearanceMenu.actions.firstIndex(of: name) {
            let on = simulatorRunTakesOverrides
            item.state = on && DebugAppearanceMenu.checkedIndex(debugArea.environmentOverrides) == i ? .on : .off
            return on
        }
        if name == "disableAllEnvironmentOverrides:" { return simulatorRunTakesOverrides && !debugArea.environmentOverrides.isEmpty }
        return nil
    }
}

extension DynamicMenus {
    /// Debug ▸ Simulate Location ▸: the debug bar's Simulate Location menu
    /// (`specs/ide/debug.md`), rebuilt each time it is shown.
    static func fillSimulateLocation(_ m: NSMenu, controller wc: WorkspaceWindowController?) {
        m.removeAllItems()
        m.autoenablesItems = false
        guard let wc else {
            let note = NSMenuItem(title: "Location simulation needs a run on the Ycode simulator", action: nil, keyEquivalent: "")
            note.isEnabled = false
            m.addItem(note)
            return
        }
        let source = wc.debugArea.simulateLocationMenu()
        for item in source.items {
            source.removeItem(item)
            m.addItem(item)
        }
    }
}
