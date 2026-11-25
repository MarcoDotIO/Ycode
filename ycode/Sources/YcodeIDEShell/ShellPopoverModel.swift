import Foundation
import Observation
import YcodeBuild
import YcodeIDECore
import YcodeWorkspace

/// The Linux IDE's popovers and in-window panels (`specs/ide/popovers.md`
/// §11), as the AppKit IDE's: the scheme and destination choosers anchored
/// under the capsule's halves (P-111, P-113), Quick Actions and Quick New
/// Project capsules (P-086, P-180), Jump to Line's capsule (P-086; its
/// flag is `WorkspaceShellModel.isJumpToLineShown`) and the New Scheme
/// sheet (P-112). The views (`ycode-ide/PopoverOverlay.swift`) draw them
/// from this state and the shared `PopoverMetrics`.
@MainActor
@Observable
public final class ShellPopoverModel {
    public enum Chooser: Sendable, Equatable { case scheme, destination }

    /// The chooser shown, if any.
    public private(set) var chooser: Chooser?
    /// Each capsule half's frame in the window (from the view's geometry).
    public var anchors: [Chooser: CGRect] = [:]
    public private(set) var filter = ""
    public private(set) var expanded = false
    public internal(set) var list = ChooserList(rows: [])
    /// Hover moves the highlight only once the pointer has moved since the
    /// chooser opened (`popovers.md` §2.7).
    @ObservationIgnored public internal(set) var pointerGate = ChooserPointerGate()
    /// Bumped when a popover or panel opens, so the view focuses its field.
    public private(set) var focusCount = 0

    /// Quick Actions (nil: closed).
    public internal(set) var quickActions: PaletteList<QuickAction>?
    /// Quick New Project (nil: closed).
    public internal(set) var quickNewProject: PaletteList<QuickNewProject.Row>?
    /// The New Scheme sheet's model (nil: closed).
    public var newScheme: NewSchemeModel?
    /// The last New Scheme failure.
    public internal(set) var newSchemeError: NewSchemeModel.Failure?
    /// Jump to Line's field.
    public var jumpText = ""
    /// Jump to Line is fading out after Escape (`Motion.jumpToLineFadeOut`).
    public internal(set) var jumpFading = false

    public init() {}

    /// The chooser's placement under its half (§2.2).
    public func placement(_ c: Chooser, bounds: CGRect? = nil) -> PopoverPlacement? {
        guard let a = anchors[c] else { return nil }
        let w = c == .scheme ? PopoverMetrics.schemeBodyWidth : PopoverMetrics.destinationBodyWidth
        return PopoverPlacement.place(anchor: a, bodySize: CGSize(width: w, height: list.bodyHeight), edge: .below, bounds: bounds)
    }

    func open(_ c: Chooser, expanded: Bool) {
        chooser = c
        filter = ""
        pointerGate = ChooserPointerGate()
        self.expanded = expanded
        focusCount += 1
    }

    func set(filter f: String) { filter = f }
    func set(expanded e: Bool) { expanded = e }

    public func closeChooser() { chooser = nil }

    func bumpFocus() { focusCount += 1 }
}

/// A command Quick Actions lists: its title, its menu path ("Product"),
/// its shortcut and what runs it.
public struct QuickAction: Sendable, Equatable {
    public var title: String
    public var path: String
    public var shortcut: String
    public var command: MenuCommand
    /// The menus above it, top first (`popovers.md` §5.1's rows).
    public var menuPath: [String] = []

    /// The row model both IDEs draw.
    public var entry: QuickActionEntry { QuickActionEntry(menuPath: menuPath, title: title, shortcut: shortcut) }
}

extension WorkspaceShellModel {
    // MARK: The choosers (P-111, P-113)

    /// Opens the scheme chooser under the scheme half.
    public func showSchemeChooser() {
        popovers.open(.scheme, expanded: false)
        reloadChooser()
    }

    /// Opens the destination chooser; `expanded` lists the incompatible
    /// destinations in place.
    public func showDestinationChooser(expanded: Bool = false) {
        popovers.open(.destination, expanded: expanded)
        reloadChooser()
    }

    /// Lists the open chooser's rows for its filter and expansion.
    func reloadChooser() {
        let p = popovers
        switch p.chooser {
        case .scheme?:
            p.list = SchemeChooser.list(schemes: schemes, current: scheme, filter: p.filter, canEdit: false, canManage: false)
        case .destination?:
            let groups = session.model.destinationGroups
            let extras = p.filter.isEmpty && containerKind != .package && !destinations.contains(where: { ShellRemoteRun.target(of: $0) != nil })
                ? [ChooserRow(kind: .command, title: Self.setUpSimulatorTitle, trailing: ExperimentalNotice.label, key: Self.setUpSimulatorKey)] : []
            p.list = DestinationChooser.list(sections: DestinationChooser.sections(groups: groups, current: destination, filter: p.filter),
                                             incompatible: [], current: destination, expanded: p.expanded, extras: extras,
                                             manageDevicesEnabled: false)
        case nil:
            p.list = ChooserList(rows: [])
        }
    }

    public static let setUpSimulatorTitle = "Set Up Ycode Simulator…"
    public static let setUpSimulatorKey = "command:setUpSimulator"

    /// Types into the chooser's Filter field.
    public func setChooserFilter(_ text: String) {
        popovers.set(filter: text)
        reloadChooser()
    }

    /// Up and Down.
    public func moveChooserHighlight(_ delta: Int) { popovers.list.move(delta) }

    /// Hover over row `i`.
    public func hoverChooserRow(_ i: Int?) { popovers.list.hover(i) }

    /// The pointer at `y` in the chooser's body (`p` its place in any fixed
    /// coordinates): the row there is highlighted once the pointer has
    /// moved since opening (§2.7).
    public func chooserPointer(at p: CGPoint, bodyY y: Double) {
        guard popovers.pointerGate.admit(p) else { return }
        let i = popovers.list.row(atY: y)
        if i != popovers.list.highlighted { popovers.list.hover(i) }
    }

    /// Right on Incompatible expands it in place (§2.4); Left collapses it.
    public func setChooserExpanded(_ on: Bool) {
        guard popovers.chooser == .destination, on != popovers.expanded else { return }
        let key = popovers.list.current?.key
        popovers.set(expanded: on)
        reloadChooser()
        if let key, let i = popovers.list.rows.firstIndex(where: { $0.key == key }) { popovers.list.highlighted = i }
    }

    /// Return: the highlighted row.
    public func chooseHighlightedRow() -> ChooserOutcome? {
        guard let h = popovers.list.highlighted else { return nil }
        return chooseChooserRow(h)
    }

    /// What choosing a row asked the view layer to do (commands that open
    /// sheets or windows the model does not own).
    public enum ChooserOutcome: Equatable, Sendable {
        case chose, toggled, editScheme, newScheme, manageSchemes, manageDevices, setUpSimulator
    }

    /// Chooses row `i` (a click or Return): a scheme or destination becomes
    /// the active one; Incompatible toggles; a command closes the chooser
    /// and is returned for the view to run.
    @discardableResult
    public func chooseChooserRow(_ i: Int) -> ChooserOutcome? {
        let p = popovers
        guard p.list.rows.indices.contains(i) else { return nil }
        let r = p.list.rows[i]
        guard r.isSelectable else { return nil }
        if DestinationChooser.isIncompatible(r) {
            p.list.highlighted = i
            setChooserExpanded(!p.expanded)
            return .toggled
        }
        let which = p.chooser
        p.closeChooser()
        if which == .scheme {
            switch SchemeChooser.command(r) {
            case .edit?: return .editScheme
            case .new?: showNewScheme(); return .newScheme
            case .manage?: return .manageSchemes
            case nil:
                if let name = r.key, schemes.contains(name) { scheme = name }
                return .chose
            }
        }
        switch r.key {
        case DestinationChooser.manageDevicesKey?: return .manageDevices
        case Self.setUpSimulatorKey?: return .setUpSimulator
        case let key?:
            if let d = destinations.first(where: { DestinationChooser.key($0) == key }) { destination = d }
            return .chose
        case nil: return nil
        }
    }

    // MARK: New Scheme (P-112)

    /// Opens the New Scheme sheet (nothing for a package).
    public func showNewScheme() {
        guard containerKind != .package else { return }
        popovers.newSchemeError = nil
        popovers.newScheme = NewSchemeModel(model: session.model, preferring: scheme)
    }

    /// OK: writes the scheme, lists it and makes it active. False (the
    /// sheet stays) when it cannot be written.
    @discardableResult
    public func createNewScheme() -> Bool {
        guard let m = popovers.newScheme else { return false }
        do {
            let s = try m.create(in: session.model)
            let names = session.model.loadSchemes().map(\.name)
            if !names.isEmpty { session.model.schemeNames = names }
            setSchemeNames(session.model.schemeNames)
            scheme = s.name
            popovers.newScheme = nil
            return true
        } catch let f as NewSchemeModel.Failure {
            popovers.newSchemeError = f
        } catch {}
        return false
    }

    // MARK: Quick Actions (P-086)

    /// Opens the Quick Actions capsule over `commands` (the enabled menu
    /// commands, from the view layer's menu model).
    public func showQuickActions(_ commands: [QuickAction]) {
        closePalettes()
        // §5.1's ranking: titles beginning with the query, then sub-menu
        // commands whose own title does, in menu order.
        popovers.quickActions = PaletteList(commands, emptyQueryShowsAll: false,
                                            rank: { all, q in QuickActionRanking.rank(all.map(\.entry), query: q) }) { $0.title }
        popovers.bumpFocus()
    }

    // MARK: Quick New Project (P-180)

    public func showQuickNewProject() {
        closePalettes()
        popovers.quickNewProject = QuickNewProject.list()
        popovers.bumpFocus()
    }

    // MARK: Jump to Line (P-086)

    /// Opens the Jump to Line capsule with an empty field.
    public func showJumpToLine() {
        closePalettes()
        popovers.jumpText = ""
        popovers.jumpFading = false
        isJumpToLineShown = true
        popovers.bumpFocus()
    }

    /// Escape: Jump to Line fades out; the view ends it with `endJumpFade`.
    public func cancelJumpToLine() {
        popovers.jumpFading = true
    }

    public func endJumpFade() {
        isJumpToLineShown = false
        popovers.jumpFading = false
        focusEditor()
    }

    /// Whether a palette, a chooser or Open Quickly has the keyboard: the
    /// editor's text surface takes no typing meanwhile (it would otherwise
    /// take the keys the field takes).
    public var overlayHasKeyboard: Bool {
        isJumpToLineShown || popovers.quickActions != nil || popovers.quickNewProject != nil || popovers.chooser != nil
            || popovers.newScheme != nil || openQuickly.isShown
    }

    /// Closes every palette and the chooser (one is shown at a time).
    public func closePalettes() {
        popovers.quickActions = nil
        popovers.quickNewProject = nil
        popovers.closeChooser()
        isJumpToLineShown = false
    }

    public func setQuickActionsQuery(_ q: String) { popovers.quickActions?.setQuery(q) }
    public func setQuickNewProjectQuery(_ q: String) { popovers.quickNewProject?.setQuery(q) }
    public func moveQuickActions(_ d: Int) { popovers.quickActions?.move(d) }
    public func moveQuickNewProject(_ d: Int) { popovers.quickNewProject?.move(d) }
}

/// The commands Quick Actions lists on Linux: every enabled command of the
/// menu bar, in menu order, with its menu path and shortcut (as the AppKit
/// `QuickActions.collect`), Show Quick Actions itself left out.
@MainActor
public enum ShellQuickActions {
    public static func collect(app: ShellAppModel) -> [QuickAction] {
        var out: [QuickAction] = []
        func walk(_ items: [MenuItemSpec], _ path: [String]) {
            for i in ShellMenuModel.shown(items, app: app) {
                switch i {
                case .separator, .label: continue
                case .submenu(let t, let sub): walk(ShellMenuModel.submenuItems(t, sub, app: app), path + [t])
                case .command(let c):
                    guard c.action != "showQuickActions:", ShellMenuModel.isEnabled(c, app: app) else { continue }
                    out.append(QuickAction(title: ShellMenuModel.title(c, app: app), path: path.joined(separator: " ▸ "),
                                           shortcut: ShellMenuModel.shortcut(c), command: c, menuPath: path))
                }
            }
        }
        for (menu, _) in CommandTable.menus { walk(ShellMenuModel.items(menu, app: app), [menu]) }
        return out
    }
}
