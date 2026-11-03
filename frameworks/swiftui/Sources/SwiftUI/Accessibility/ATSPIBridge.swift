import Foundation
import OVAccessibilityATSPI
import OVPlatform
import OVText
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The AT-SPI export of OpenViews windows (R10, finished in OV-ATSPI): the
// accessibility tree (AccessibilityTree.swift) mapped onto the exporter's
// model (OVAccessibilityATSPI), and the exporter's requests run on the
// elements. Ycode's mapping; the table is in the package README
// ("AT-SPI export").
//
// - Started by `App.main()` on window-system back ends when an
//   accessibility bus exists (`OV_ATSPI=0` turns it off, `OV_ATSPI=1`
//   turns it on for the headless back end too).
// - Keys: a window is `w<n>` (n counts windows from 1), an element
//   `w<n>_<element id in hex>`.
// - The revision of a window is its graph's pass count with its size,
//   focused node and activity: the tree cannot change without one of them.
// - Requests run the element's own closures (the same as
//   `AccessibilityTree.perform`), then mark the window for a frame.

/// Maps OpenViews accessibility elements to AT-SPI roles, states and
/// actions (Ycode's table; README "AT-SPI export").
package enum ATSPIMapping {
    /// The AT-SPI role of an element. `multiline` is for text inputs,
    /// `inTree` for lists and rows of an outline, `popup` for windows.
    package static func role(_ e: AccessibilityElement, multiline: Bool = false, inTree: Bool = false,
                             popup: Bool = false) -> ATSPIRole {
        switch e.role {
        case .window: return popup ? .window : .frame
        case .group: return .panel
        case .staticText: return e.traits.contains(.isHeader) ? .heading : .label
        case .image: return .image
        case .button: return .pushButton
        case .toggle: return .toggleButton
        case .slider: return .slider
        case .stepper: return .spinButton
        case .link: return .link
        case .textField: return multiline ? .text : .entry
        case .secureTextField: return .passwordText
        case .progressIndicator: return .progressBar
        case .picker: return .comboBox
        case .menuButton: return .pushButton
        case .list: return inTree ? .tree : .list
        case .row: return inTree ? .treeItem : .listItem
        case .menuBar: return .menuBar
        case .menuBarItem, .menu: return .menu
        case .menuItem: return e.traits.contains(.isToggle) ? .checkMenuItem : .menuItem
        case .toolbar: return .toolBar
        case .dialog: return .dialog
        case .alert: return .alert
        case .tabList: return .pageTabList
        case .tab: return .pageTab
        case .scrollView: return .scrollPane
        case .splitter: return .separator
        }
    }

    static let focusableRoles: Set<AccessibilityRole> = [
        .button, .toggle, .slider, .stepper, .link, .textField, .secureTextField, .picker, .menuButton, .row,
        .menuBarItem, .menuItem, .tab, .list,
    ]

    static let clickRoles: Set<AccessibilityRole> = [
        .button, .toggle, .link, .menuItem, .menuBarItem, .tab, .menuButton, .picker,
    ]

    /// The AT-SPI states of an element. `focused` is the innermost focused
    /// element (the tree marks every ancestor of the focused view).
    package static func states(_ e: AccessibilityElement, focused: Bool, showing: Bool, multiline: Bool = false,
                               isWindow: Bool = false, active: Bool = false, popup: Bool = false) -> ATSPIStateSet {
        var s = ATSPIStateSet([.visible])
        if showing { s.insert(.showing) }
        if e.isEnabled {
            s.insert(.enabled)
            s.insert(.sensitive)
        }
        if isWindow {
            if active { s.insert(.active) }
            if !popup { s.insert(.resizable) }
            return s
        }
        if focusableRoles.contains(e.role) { s.insert(.focusable) }
        if focused { s.insert(.focused) }
        if e.traits.contains(.isToggle) {
            s.insert(.checkable)
            if e.value == "1" { s.insert(.checked) }
        }
        if e.role == .row {
            s.insert(.selectable)
        }
        if e.traits.contains(.isSelected) {
            s.insert(.selectable)
            s.insert(.selected)
        }
        if e.role == .textField || e.role == .secureTextField {
            s.insert(.editable)
            s.insert(.selectableText)
            s.insert(multiline ? .multiLine : .singleLine)
        }
        if let x = e.isExpanded {
            s.insert(.expandable)
            s.insert(x ? .expanded : .collapsed)
        }
        if e.traits.contains(.isModal) { s.insert(.modal) }
        if [.menuBarItem, .menuButton, .picker].contains(e.role) { s.insert(.hasPopup) }
        if e.role == .slider { s.insert(.horizontal) }
        if e.traits.contains(.updatesFrequently) { s.insert(.animated) }
        return s
    }

    /// AT-SPI action names for the element's actions, in its order.
    package static func actions(_ e: AccessibilityElement) -> [ATSPIAction] {
        e.actionNames.map { n in
            if n == "default" {
                let name = clickRoles.contains(e.role) ? "click" : "activate"
                return ATSPIAction(name: name, description: e.hint ?? "")
            }
            return ATSPIAction(name: n)
        }
    }
}

/// The application's AT-SPI export.
@MainActor
package final class AccessibilityExport: ATSPIProvider {
    package weak var host: AppHost?
    package private(set) var exporter: ATSPIExporter?
    private var serials: [ObjectIdentifier: Int] = [:]
    private var nextSerial = 1
    /// Elements of the last snapshot of each window, by key.
    private var elements: [String: AccessibilityElement] = [:]
    private var textStates: [String: TextFieldState] = [:]

    package init(host: AppHost) { self.host = host }

    /// Starts the export when an accessibility bus exists (`OV_ATSPI`:
    /// `0` off, `1` also on the headless back end).
    package static func start(host: AppHost, environment: [String: String] = ProcessInfo.processInfo.environment) -> AccessibilityExport? {
        let setting = environment["OV_ATSPI"]
        if setting == "0" { return nil }
        if host.backend is HeadlessBackend && setting != "1" { return nil }
        let export = AccessibilityExport(host: host)
        guard let exporter = ATSPIExporter.start(provider: export, environment: environment) else {
            host.log?("AT-SPI: no accessibility bus")
            return nil
        }
        if environment["OV_TRACE"] != nil || environment["OV_ATSPI_TRACE"] != nil {
            exporter.log = { FileHandle.standardError.write(Data("[ov-atspi] \($0)\n".utf8)) }
        }
        export.exporter = exporter
        exporter.log?("connected as \(exporter.connection.uniqueName ?? "?")")
        return export
    }

    /// Attaches an exporter made elsewhere (tests).
    package func attach(_ exporter: ATSPIExporter) { self.exporter = exporter }

    package func afterFrame() { exporter?.afterFrame() }

    // MARK: Windows

    private func serial(_ w: WindowHost) -> Int {
        let id = ObjectIdentifier(w)
        if let s = serials[id] { return s }
        let s = nextSerial
        nextSerial += 1
        serials[id] = s
        return s
    }

    package func key(of w: WindowHost) -> String { "w\(serial(w))" }

    private var openWindows: [WindowHost] { host?.windows.filter { !$0.platform.isClosed } ?? [] }

    private func window(_ key: String) -> WindowHost? {
        let w = key.split(separator: "_", maxSplits: 1).first.map(String.init) ?? key
        return openWindows.first { self.key(of: $0) == w }
    }

    private func isActive(_ w: WindowHost) -> Bool {
        guard let host else { return false }
        if host.windowFocusKnown { return host.activeWindowID == w.platform.id }
        // No focus event yet (a window system without a window manager):
        // the first main window counts as active.
        return host.windows.first { !$0.isPopup } === w
    }

    // MARK: ATSPIProvider

    package var applicationName: String { host?.appName ?? ProcessInfo.processInfo.processName }

    package func windowKeys() -> [String] { openWindows.map(key(of:)) }

    package func revision(ofWindow key: String) -> Int {
        guard let w = window(key) else { return -1 }
        var h = Hasher()
        h.combine(w.graph.passCount)
        h.combine(w.graph.needsUpdate)
        h.combine(w.size.width)
        h.combine(w.size.height)
        h.combine(w.services.focus.focusedNode.map(ObjectIdentifier.init))
        h.combine(isActive(w))
        h.combine(w.platform.title)
        return h.finalize()
    }

    package func screenOrigin(ofWindow key: String) -> (x: Int32, y: Int32)? {
        guard let o = window(key)?.platform.screenOrigin else { return nil }
        return (Int32(o.x.rounded()), Int32(o.y.rounded()))
    }

    package func snapshot(ofWindow key: String) -> ATSPIWindowSnapshot? {
        guard let w = window(key) else { return nil }
        let stale = w.graph.needsUpdate
        let tree = AccessibilityTree.build(w, title: w.isPopup ? "" : w.platform.title)
        // An update made here must still reach the screen.
        if stale { w.exposed() }
        let revision = self.revision(ofWindow: key)
        for k in elements.keys where k == key || k.hasPrefix(key + "_") { elements[k] = nil }
        for k in textStates.keys where k == key || k.hasPrefix(key + "_") { textStates[k] = nil }
        let scale = w.platform.scale
        let windowRect = CGRect(origin: .zero, size: w.size)
        // The innermost focused element.
        let focusedID = tree.flattened.last(where: { $0.isFocused && $0.id != tree.id })?.id
        var nodes: [ATSPINode] = []
        var used: Set<String> = []

        func pixels(_ r: CGRect) -> ATSPIRect {
            ATSPIRect(x: Int32((r.minX * scale).rounded()), y: Int32((r.minY * scale).rounded()),
                      width: Int32((r.width * scale).rounded()), height: Int32((r.height * scale).rounded()))
        }

        func visit(_ e: AccessibilityElement, inTree: Bool) -> String {
            let isRoot = e.id == tree.id
            var k = isRoot ? key : "\(key)_\(String(e.id, radix: 16))"
            if used.contains(k) {
                var n = 2
                while used.contains("\(k)_\(n)") { n += 1 }
                k = "\(k)_\(n)"
            }
            used.insert(k)
            elements[k] = e
            let state = (e.role == .textField || e.role == .secureTextField) ? e.node.flatMap(Self.textState) : nil
            if let state { textStates[k] = state }
            let multiline = state?.multiline ?? false
            let tree = e.role == .list ? e.children.contains { $0.isExpanded != nil } : inTree
            let childKeys = e.children.map { visit($0, inTree: tree) }
            let role = ATSPIMapping.role(e, multiline: multiline, inTree: tree, popup: w.isPopup)
            let showing = isRoot || (e.frame.width > 0 && e.frame.height > 0 && e.frame.intersects(windowRect))
            var n = ATSPINode(key: k, role: role, name: e.label ?? "", description: e.hint ?? "",
                              identifier: e.identifier ?? "",
                              states: ATSPIMapping.states(e, focused: e.id == focusedID, showing: showing, multiline: multiline,
                                                          isWindow: isRoot, active: isRoot && isActive(w), popup: w.isPopup),
                              frame: pixels(isRoot ? windowRect : e.frame), actions: ATSPIMapping.actions(e),
                              children: childKeys)
            if let level = e.headingLevel, level != .unspecified { n.attributes["level"] = "\(level.rawValue)" }
            if let state {
                n.text = Self.text(of: state, editable: e.isEnabled)
            } else if e.role == .staticText, let l = e.label {
                n.text = ATSPIText(string: l)
            }
            if let r = e.rangeValue {
                n.value = ATSPIValue(current: r.current, minimum: r.minimum, maximum: r.maximum, increment: r.step,
                                     text: e.value ?? "", isSettable: r.set != nil)
            }
            n.isSelectionContainer = e.role == .list
            nodes.append(n)
            return k
        }
        _ = visit(tree, inTree: false)
        return ATSPIWindowSnapshot(rootKey: key, nodes: nodes, revision: revision)
    }

    /// The editing state of a text input below `node`.
    static func textState(_ node: ViewNode) -> TextFieldState? {
        if let s = node.primitiveState as? TextFieldState { return s }
        for c in node.children {
            if let s = textState(c) { return s }
        }
        return nil
    }

    static func text(of state: TextFieldState, editable: Bool) -> ATSPIText {
        let chars = state.isSecure ? Array(repeating: Character("\u{2022}"), count: state.model.count) : state.model.characters
        let toScalar = { (g: Int) in Self.scalarOffset(chars, g) }
        let r = state.model.selectedRange
        return ATSPIText(string: String(chars), caret: toScalar(state.model.caret), selection: toScalar(r.lowerBound)..<toScalar(r.upperBound),
                         isEditable: editable)
    }

    /// Scalar offset of grapheme index `g`.
    static func scalarOffset(_ chars: [Character], _ g: Int) -> Int {
        chars.prefix(max(0, g)).reduce(0) { $0 + $1.unicodeScalars.count }
    }

    /// Grapheme index of scalar offset `s` (inside a grapheme: the next one).
    static func graphemeIndex(_ chars: [Character], _ s: Int) -> Int {
        var total = 0
        for (i, c) in chars.enumerated() {
            if total >= s { return i }
            total += c.unicodeScalars.count
        }
        return chars.count
    }

    // MARK: Requests

    /// Marks the window of `key` for a frame after a change.
    private func changed(_ key: String) {
        guard let w = window(key) else { return }
        w.update()
        w.exposed()
    }

    package func performAction(_ index: Int, on key: String) -> Bool {
        guard let e = elements[key], e.actionNames.indices.contains(index) else { return false }
        let name = e.actionNames[index]
        if let a = e.actions[name] {
            a()
        } else if let adjust = e.adjust, name == "increment" || name == "decrement" {
            adjust(name == "increment" ? .increment : .decrement)
        } else {
            return false
        }
        changed(key)
        return true
    }

    package func grabFocus(_ key: String) -> Bool {
        guard let w = window(key) else { return false }
        if elements[key] == nil || key == self.key(of: w) {
            // The window itself.
            w.platform.activate()
            return true
        }
        guard let node = elements[key]?.node, let target = w.services.focus.target(within: node) else { return false }
        w.services.focus.focus(target)
        changed(key)
        return w.services.focus.focusedNode === target
    }

    private func edit(_ key: String, _ body: (TextFieldState) -> Void) -> Bool {
        guard let s = textStates[key], s.node?.isAlive == true, elements[key]?.isEnabled == true else { return false }
        body(s)
        s.commit()
        changed(key)
        return true
    }

    package func setText(_ text: String, on key: String) -> Bool {
        edit(key) { $0.model.setText(text) }
    }

    package func replaceText(in range: Range<Int>, with text: String, on key: String) -> Bool {
        edit(key) { s in
            let c = s.model.characters
            s.model.replace(Self.graphemeIndex(c, range.lowerBound)..<Self.graphemeIndex(c, range.upperBound), with: text)
        }
    }

    package func setSelection(_ range: Range<Int>, on key: String) -> Bool {
        guard let s = textStates[key], s.node?.isAlive == true else { return false }
        let c = s.model.characters
        s.model.setSelection(TextSelectionRange(anchor: Self.graphemeIndex(c, range.lowerBound), head: Self.graphemeIndex(c, range.upperBound)))
        s.invalidate()
        changed(key)
        return true
    }

    package func copyText(_ range: Range<Int>, on key: String, cut: Bool) -> Bool {
        guard let s = textStates[key], !s.isSecure, let w = window(key) else { return false }
        let c = s.model.characters
        let r = Self.graphemeIndex(c, range.lowerBound)..<Self.graphemeIndex(c, range.upperBound)
        w.services.clipboard?.text = String(c[r])
        return cut ? replaceText(in: range, with: "", on: key) : true
    }

    package func pasteText(at offset: Int, on key: String) -> Bool {
        guard let w = window(key), let t = w.services.clipboard?.text, !t.isEmpty else { return false }
        return replaceText(in: offset..<offset, with: t, on: key)
    }

    package func setValue(_ value: Double, on key: String) -> Bool {
        guard let set = elements[key]?.rangeValue?.set else { return false }
        set(value)
        changed(key)
        return true
    }

    package func selectChild(_ index: Int, of key: String) -> Bool {
        guard let e = elements[key], e.children.indices.contains(index) else { return false }
        let child = e.children[index]
        guard let a = child.actions["default"] else { return false }
        a()
        changed(key)
        return true
    }
}

extension FocusSystem {
    /// The first focus target that is `node` or inside it.
    package func target(within node: ViewNode) -> ViewNode? {
        for t in registeredTargets {
            var x: ViewNode? = t
            while let y = x {
                if y === node { return t }
                x = y.parent
            }
        }
        return nil
    }
}
