import Foundation
import Observation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Commands (round R11, docs/PARITY.md §5.4; public API names: `Commands`,
// `CommandsBuilder`, `CommandMenu`, `CommandGroup`, `CommandGroupPlacement`,
// `EmptyCommands`, `SidebarCommands`, `ToolbarCommands`,
// `TextEditingCommands`, `TextFormattingCommands`, `InspectorCommands`, the
// scene modifiers `commands(content:)`, `commandsRemoved()`,
// `commandsReplaced(content:)`).
//
// Design (Ycode's): the commands of every scene are merged into one menu
// model for the application (as on desktop systems with one menu bar). Each
// window evaluates the merged commands inside its own view graph, below an
// unlaid-out host: a custom `Commands` type is a graph node like a view (its
// `@FocusedValue`, `@State`, `@Environment` and observed models work, and its
// body runs again when they change), and the item views of menus and groups
// are built there too, so the keyboard shortcuts of their buttons register
// with the window (at a lower priority than the shortcuts of the window's
// own views). The menu bar (MenuBar.swift) reads the contributions in tree
// order and shows each menu's items in a pop-up when it opens.

/// A set of menu commands: `CommandMenu`, `CommandGroup`, or a type whose
/// `body` lists others.
@MainActor @preconcurrency
public protocol Commands {
    associatedtype Body: Commands
    @CommandsBuilder @MainActor @preconcurrency var body: Body { get }
}

extension Never: Commands {}

extension Commands where Body == Never {
    public var body: Never { fatalError("\(Self.self) is primitive commands") }
}

/// Builds commands from the statements of a `commands` block.
@MainActor @resultBuilder
public struct CommandsBuilder {
    public static func buildExpression<Content: Commands>(_ content: Content) -> Content { content }
    public static func buildBlock() -> EmptyCommands { EmptyCommands() }
    public static func buildBlock<Content: Commands>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: Commands>(_ content: repeat each Content) -> _TupleCommands {
        var items: [any Commands] = []
        repeat items.append(each content)
        return _TupleCommands(items: items)
    }
    /// (An existential: the branch that is not taken gives no type; R13.)
    public static func buildOptional(_ content: (any Commands)?) -> _TupleCommands {
        _TupleCommands(items: content.map { [$0] } ?? [])
    }
    public static func buildEither<First: Commands>(first: First) -> _TupleCommands { _TupleCommands(items: [first]) }
    public static func buildEither<Second: Commands>(second: Second) -> _TupleCommands { _TupleCommands(items: [second]) }
    public static func buildLimitedAvailability<Content: Commands>(_ content: Content) -> _TupleCommands {
        _TupleCommands(items: [content])
    }
}

/// No commands.
public struct EmptyCommands: Commands {
    public init() {}
    public typealias Body = Never
}

/// Several commands of one builder block.
public struct _TupleCommands: Commands {
    let items: [any Commands]
    public typealias Body = Never
}

// MARK: - Placements

/// A standard group of menu items, used to place, replace or extend it.
public struct CommandGroupPlacement: Sendable, Hashable {
    let id: String
    init(_ id: String) { self.id = id }

    // App menu.
    public static let appInfo = CommandGroupPlacement("appInfo")
    public static let appSettings = CommandGroupPlacement("appSettings")
    public static let systemServices = CommandGroupPlacement("systemServices")
    public static let appVisibility = CommandGroupPlacement("appVisibility")
    public static let appTermination = CommandGroupPlacement("appTermination")
    // File menu.
    public static let newItem = CommandGroupPlacement("newItem")
    public static let saveItem = CommandGroupPlacement("saveItem")
    public static let importExport = CommandGroupPlacement("importExport")
    public static let printItem = CommandGroupPlacement("printItem")
    // Edit menu.
    public static let undoRedo = CommandGroupPlacement("undoRedo")
    public static let pasteboard = CommandGroupPlacement("pasteboard")
    public static let textEditing = CommandGroupPlacement("textEditing")
    public static let textFormatting = CommandGroupPlacement("textFormatting")
    // View menu.
    public static let toolbar = CommandGroupPlacement("toolbar")
    public static let sidebar = CommandGroupPlacement("sidebar")
    // Window menu.
    public static let windowSize = CommandGroupPlacement("windowSize")
    public static let windowArrangement = CommandGroupPlacement("windowArrangement")
    public static let windowList = CommandGroupPlacement("windowList")
    public static let singleWindowList = CommandGroupPlacement("singleWindowList")
    // Help menu.
    public static let help = CommandGroupPlacement("help")
}

// MARK: - Primitive commands

/// What one primitive command value adds to the menus.
package enum CommandContribution {
    package enum Position: Sendable { case before, after, replacing }
    case menu(title: String, content: AnyView)
    case group(placement: CommandGroupPlacement, position: Position, content: AnyView)
    /// A standard command set (sidebar, toolbar, text editing, …).
    case standard(String)
    /// `commandsRemoved()`: the scene's default commands are not shown.
    case removeDefaults
}

@MainActor
package protocol PrimitiveCommands: Commands {
    /// The contribution and the item views (built, unlaid out, so their
    /// shortcuts register).
    func _contribution() -> CommandContribution?
    func _children() -> [(AnyHashable, any Commands)]
}

extension PrimitiveCommands {
    package func _contribution() -> CommandContribution? { nil }
    package func _children() -> [(AnyHashable, any Commands)] { [] }
}

extension EmptyCommands: PrimitiveCommands {}

extension _TupleCommands: PrimitiveCommands {
    package func _children() -> [(AnyHashable, any Commands)] {
        items.enumerated().map { (AnyHashable($0.offset), $0.element) }
    }
}

/// A menu of its own in the menu bar (after View, before Window).
public struct CommandMenu<Content: View>: Commands, PrimitiveCommands {
    let title: String
    let content: Content

    public init(_ nameKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        title = Text(nameKey).plainString
        self.content = content()
    }

    public init(_ name: Text, @ViewBuilder content: () -> Content) {
        title = name.plainString
        self.content = content()
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ name: S, @ViewBuilder content: () -> Content) {
        title = String(name)
        self.content = content()
    }

    public typealias Body = Never

    package func _contribution() -> CommandContribution? { .menu(title: title, content: AnyView(content)) }
}

/// Items placed before or after a standard group, or replacing it.
public struct CommandGroup<Content: View>: Commands, PrimitiveCommands {
    let placement: CommandGroupPlacement
    let position: CommandContribution.Position
    let content: Content

    public init(before group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        placement = group
        position = .before
        content = addition()
    }

    public init(after group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        placement = group
        position = .after
        content = addition()
    }

    public init(replacing group: CommandGroupPlacement, @ViewBuilder addition: () -> Content) {
        placement = group
        position = .replacing
        content = addition()
    }

    public typealias Body = Never

    package func _contribution() -> CommandContribution? {
        .group(placement: placement, position: position, content: AnyView(content))
    }
}

/// Show Sidebar / Hide Sidebar in the View menu.
public struct SidebarCommands: Commands, PrimitiveCommands {
    public init() {}
    public typealias Body = Never
    package func _contribution() -> CommandContribution? { .standard("sidebar") }
}

/// Show Toolbar / Hide Toolbar in the View menu (present by default when a
/// window has a toolbar).
public struct ToolbarCommands: Commands, PrimitiveCommands {
    public init() {}
    public typealias Body = Never
    package func _contribution() -> CommandContribution? { .standard("toolbar") }
}

/// Find items for text views (accepted; the Edit menu's standard items are
/// always present).
public struct TextEditingCommands: Commands, PrimitiveCommands {
    public init() {}
    public typealias Body = Never
    package func _contribution() -> CommandContribution? { .standard("textEditing") }
}

/// A Format menu (accepted; rich text is not implemented).
public struct TextFormattingCommands: Commands, PrimitiveCommands {
    public init() {}
    public typealias Body = Never
    package func _contribution() -> CommandContribution? { .standard("textFormatting") }
}

/// Show Inspector / Hide Inspector (accepted).
public struct InspectorCommands: Commands, PrimitiveCommands {
    public init() {}
    public typealias Body = Never
    package func _contribution() -> CommandContribution? { .standard("inspector") }
}

/// Accepted for source compatibility.
public struct ImportFromDevicesCommands: Commands, PrimitiveCommands {
    public init() {}
    public typealias Body = Never
}

struct RemoveDefaultCommands: Commands, PrimitiveCommands {
    typealias Body = Never
    func _contribution() -> CommandContribution? { .removeDefaults }
}

// MARK: - Scene modifiers

extension Scene {
    /// Adds commands (menus, menu items with keyboard shortcuts) to the
    /// application's menu bar.
    public func commands<Content: Commands>(@CommandsBuilder content: () -> Content) -> _ModifiedScene<Self> {
        let c = content()
        return _ModifiedScene(content: self) { $0.commands.append(c) }
    }

    /// Leaves out the default commands of this scene type (the standard
    /// menus keep their titles; their default items go).
    public func commandsRemoved() -> _ModifiedScene<Self> {
        _ModifiedScene(content: self) { $0.commands.append(RemoveDefaultCommands()) }
    }

    /// Replaces the default commands with `content`.
    public func commandsReplaced<Content: Commands>(@CommandsBuilder content: () -> Content) -> _ModifiedScene<Self> {
        let c = content()
        return _ModifiedScene(content: self) {
            $0.commands.append(RemoveDefaultCommands())
            $0.commands.append(c)
        }
    }
}

// MARK: - Evaluation in the window graph

/// The contributions of the commands evaluated in one window.
@MainActor
@Observable
package final class CommandsModel {
    /// Bumped when a contribution changes (the menu bar depends on it).
    package private(set) var revision = 0
    @ObservationIgnored private var contributions: [ObjectIdentifier: (node: WeakNode, value: CommandContribution)] = [:]
    @ObservationIgnored weak var root: ViewNode?

    package init() {}

    func set(_ node: ViewNode, _ c: CommandContribution?) {
        let id = ObjectIdentifier(node)
        if let c { contributions[id] = (WeakNode(node), c) } else if contributions[id] != nil { contributions[id] = nil }
        revision += 1
    }

    /// The contributions in tree order.
    package var ordered: [CommandContribution] {
        guard let root else { return [] }
        var out: [CommandContribution] = []
        root.forEachNode { n in
            if let c = contributions[ObjectIdentifier(n)], c.node.node === n { out.append(c.value) }
        }
        return out
    }
}

private enum InCommandHostKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True for the item views of commands built in the window's (unlaid
    /// out) commands host: their shortcuts register as menu commands, and
    /// the standard Edit items draw nothing there.
    package var _inCommandHost: Bool {
        get { self[InCommandHostKey.self] }
        set { self[InCommandHostKey.self] = newValue }
    }
}

/// One commands value as a graph node.
struct CommandsNodeView<C: Commands>: View, PrimitiveView {
    let commands: C
    let model: CommandsModel
    typealias Body = Never

    private func build(_ node: ViewNode, first: Bool, transaction: Transaction) {
        if let p = commands as? any PrimitiveCommands {
            let contribution = p._contribution()
            model.set(node, contribution)
            var items: [(AnyHashable, any View)] = p._children().map { key, child in
                (key, makeCommandsNode(child, model))
            }
            switch contribution {
            case .menu(_, let content)?, .group(_, _, let content)?:
                items.append((AnyHashable("items"), content.environment(\._inCommandHost, true)))
            default: break
            }
            node.reconcileChildren(items, transaction: transaction)
        } else {
            let c = commands, m = model
            node.updateTracked(inputs: c, inputsChanged: first, transaction: transaction) {
                makeCommandsNode(c.body, m)
            }
        }
    }

    func _makeChildren(node: ViewNode, old: CommandsNodeView?, transaction: Transaction) {
        build(node, first: true, transaction: transaction)
    }

    func _refresh(node: ViewNode, environmentChanged: Bool, transaction: Transaction) {
        if commands is any PrimitiveCommands {
            node.refreshChildren(transaction: transaction)
        } else {
            build(node, first: false, transaction: transaction)
        }
    }

    func _lower(node: ViewNode) -> [LayoutNode] { [] }

    func _removed(node: ViewNode) { model.set(node, nil) }
}

extension CommandsNodeView: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}

@MainActor
func makeCommandsNode(_ c: any Commands, _ model: CommandsModel) -> any View {
    func open<C: Commands>(_ c: C) -> any View { CommandsNodeView(commands: c, model: model) }
    return open(c)
}

/// The unlaid-out root of a window's commands.
struct CommandsHostView: View, PrimitiveView {
    let commands: [any Commands]
    let model: CommandsModel
    let actions: AppCommandActions
    typealias Body = Never

    func _makeChildren(node: ViewNode, old: CommandsHostView?, transaction: Transaction) {
        model.root = node
        var items: [(AnyHashable, any View)] = commands.enumerated().map {
            (AnyHashable($0.offset), makeCommandsNode($0.element, model))
        }
        items.append((AnyHashable("standard"), StandardCommandsHost(model: model, actions: actions)))
        node.reconcileChildren(items, transaction: transaction)
    }

    func _lower(node: ViewNode) -> [LayoutNode] { [] }
}

extension CommandsHostView: GraphInputComparable {
    nonisolated func _isGraphInputEqual(to other: Any) -> Bool { false }
}
