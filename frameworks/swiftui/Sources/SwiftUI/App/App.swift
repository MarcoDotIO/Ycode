import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// The app model (round R7; 06-app-and-components.md §1): `App`, `Scene`,
// `WindowGroup`, `Window`, scene modifiers, `onOpenURL`, and the actions that
// open and dismiss windows. `App.main()` runs the application host
// (AppHost.swift) on the default platform back end.

/// An application: a value whose `body` lists its scenes. `@main` on a type
/// conforming to `App` starts it.
@MainActor @preconcurrency
public protocol App {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Body { get }
    @MainActor @preconcurrency init()
}

extension App {
    /// Starts the application: creates it, connects its first scene to a
    /// window and runs the main loop until it quits.
    @MainActor @preconcurrency
    public static func main() {
        AppHost.runMain(Self.self)
    }
}

/// Part of an application's user interface with its own lifecycle (a window
/// group, a window).
@MainActor @preconcurrency
public protocol Scene {
    associatedtype Body: Scene
    @SceneBuilder @MainActor @preconcurrency var body: Body { get }
}

extension Never: Scene {}

extension Scene where Body == Never {
    public var body: Never { fatalError("\(Self.self) is a primitive scene") }
}

/// Builds scenes from the statements of an `App.body`.
@MainActor @resultBuilder
public struct SceneBuilder {
    public static func buildExpression<Content: Scene>(_ content: Content) -> Content { content }
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { content }
    public static func buildBlock<each Content: Scene>(_ content: repeat each Content) -> _TupleScene<(repeat each Content)> {
        _TupleScene((repeat each content))
    }
    public static func buildOptional<Content: Scene>(_ content: Content?) -> Content? { content }
    public static func buildLimitedAvailability<Content: Scene>(_ content: Content) -> Content { content }
}

// MARK: - Scene descriptions

/// What the host needs to know about one scene.
package struct SceneDescription {
    package enum Kind: Equatable { case windowGroup, window, settings }
    package var kind: Kind
    package var id: String?
    package var title: String
    package var content: @MainActor () -> any View
    package var defaultSize: CGSize?
    package var resizable = true
    package var environment: [(inout EnvironmentValues) -> Void] = []
    package var changeObservers: [SceneChangeObserver] = []
    /// `commands` of the scene (R11; merged into the app's menu bar).
    package var commands: [any Commands] = []
}

/// A scene-level `onChange(of:)`.
package struct SceneChangeObserver {
    package let value: Any
    package let equal: (Any, Any) -> Bool
    package let initial: Bool
    package let action: (Any, Any) -> Void
}

/// Flattens scene values.
@MainActor
package protocol PrimitiveScene: Scene {
    func _collect(into scenes: inout [SceneDescription])
}

@MainActor
package enum SceneCollector {
    package static func collect<S: Scene>(_ scene: S) -> [SceneDescription] {
        var out: [SceneDescription] = []
        collect(scene, into: &out)
        return out
    }

    package static func collect<S: Scene>(_ scene: S, into out: inout [SceneDescription]) {
        if let p = scene as? any PrimitiveScene {
            p._collect(into: &out)
        } else {
            collect(scene.body, into: &out)
        }
    }

    static func collectAny(_ scene: any Scene, into out: inout [SceneDescription]) {
        func open<S: Scene>(_ s: S) { collect(s, into: &out) }
        open(scene)
    }
}

/// Several scenes built by one `SceneBuilder` block.
public struct _TupleScene<T>: Scene {
    public var value: T
    public init(_ value: T) { self.value = value }
    public typealias Body = Never
}

extension _TupleScene: PrimitiveScene {
    package func _collect(into scenes: inout [SceneDescription]) {
        for child in Mirror(reflecting: value).children {
            if let s = child.value as? any Scene { SceneCollector.collectAny(s, into: &scenes) }
        }
    }
}

extension Optional: Scene where Wrapped: Scene {
    public typealias Body = Never
}

extension Optional: PrimitiveScene where Wrapped: Scene {
    package func _collect(into scenes: inout [SceneDescription]) {
        if let s = self { SceneCollector.collect(s, into: &scenes) }
    }
}

private func plainString(_ text: Text) -> String { text.segments.map(\.string).joined() }

/// A group of identical windows; on Linux the first group opens one window
/// at launch and `openWindow(id:)` opens more.
public struct WindowGroup<Content: View>: Scene {
    package let id: String?
    package let title: String
    package let content: @MainActor () -> Content

    public init(@ViewBuilder content: @escaping @MainActor () -> Content) {
        id = nil
        title = ""
        self.content = content
    }

    public init(id: String, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        title = ""
        self.content = content
    }

    public init(_ title: Text, id: String? = nil, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = plainString(title)
        self.content = content
    }

    public init(_ titleKey: LocalizedStringKey, id: String? = nil, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.init(Text(titleKey), id: id, content: content)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, id: String? = nil, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = String(title)
        self.content = content
    }

    public typealias Body = Never
}

extension WindowGroup: PrimitiveScene {
    package func _collect(into scenes: inout [SceneDescription]) {
        let content = content
        scenes.append(SceneDescription(kind: .windowGroup, id: id, title: title, content: { content() }))
    }
}

/// A single, unique window (a desktop scene: opened at launch when it is the
/// first scene, otherwise with `openWindow(id:)`).
public struct Window<Content: View>: Scene {
    package let id: String
    package let title: String
    package let content: @MainActor () -> Content

    public init(_ title: Text, id: String, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = plainString(title)
        self.content = content
    }

    public init(_ titleKey: LocalizedStringKey, id: String, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.init(Text(titleKey), id: id, content: content)
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, id: String, @ViewBuilder content: @escaping @MainActor () -> Content) {
        self.id = id
        self.title = String(title)
        self.content = content
    }

    public typealias Body = Never
}

extension Window: PrimitiveScene {
    package func _collect(into scenes: inout [SceneDescription]) {
        let content = content
        scenes.append(SceneDescription(kind: .window, id: id, title: title, content: { content() }))
    }
}

// MARK: - Scene modifiers

/// A scene whose descriptions are changed by `transform`.
public struct _ModifiedScene<Content: Scene>: Scene {
    package let content: Content
    package let transform: @MainActor (inout SceneDescription) -> Void
    public typealias Body = Never
}

extension _ModifiedScene: PrimitiveScene {
    package func _collect(into scenes: inout [SceneDescription]) {
        var inner: [SceneDescription] = []
        SceneCollector.collect(content, into: &inner)
        for i in inner.indices { transform(&inner[i]) }
        scenes += inner
    }
}

/// How a window may be resized.
public struct WindowResizability: Sendable, Equatable {
    let kind: Int
    public static let automatic = WindowResizability(kind: 0)
    public static let contentSize = WindowResizability(kind: 1)
    public static let contentMinSize = WindowResizability(kind: 2)
}

extension Scene {
    private func modified(_ t: @escaping @MainActor (inout SceneDescription) -> Void) -> _ModifiedScene<Self> {
        _ModifiedScene(content: self, transform: t)
    }

    /// The size of new windows of the scene (points).
    public func defaultSize(width: CGFloat, height: CGFloat) -> _ModifiedScene<Self> {
        modified { $0.defaultSize = CGSize(width: width, height: height) }
    }

    public func defaultSize(_ size: CGSize) -> _ModifiedScene<Self> {
        modified { $0.defaultSize = size }
    }

    public func windowResizability(_ resizability: WindowResizability) -> _ModifiedScene<Self> {
        modified { $0.resizable = resizability != .contentSize }
    }

    /// Sets an environment value for the scene's views.
    public func environment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>, _ value: V) -> _ModifiedScene<Self> {
        modified { $0.environment.append { $0[keyPath: keyPath] = value } }
    }

    public func transformEnvironment<V>(_ keyPath: WritableKeyPath<EnvironmentValues, V>,
                                        transform: @escaping (inout V) -> Void) -> _ModifiedScene<Self> {
        modified { $0.environment.append { transform(&$0[keyPath: keyPath]) } }
    }

    /// Runs `action` when `value` differs between two evaluations of the
    /// app's body (the old and new values).
    public func onChange<V: Equatable>(of value: V, initial: Bool = false,
                                       _ action: @escaping (_ oldValue: V, _ newValue: V) -> Void) -> _ModifiedScene<Self> {
        modified {
            $0.changeObservers.append(SceneChangeObserver(value: value, equal: { ($0 as? V) == ($1 as? V) },
                                                          initial: initial) { old, new in
                // swiftlint:disable:next force_cast - stored with type V above
                action(old as! V, new as! V)
            })
        }
    }

    public func onChange<V: Equatable>(of value: V, initial: Bool = false,
                                       _ action: @escaping () -> Void) -> _ModifiedScene<Self> {
        onChange(of: value, initial: initial) { _, _ in action() }
    }
}

// MARK: - Window actions

private enum OpenWindowKey: EnvironmentKey {
    static let defaultValue = OpenWindowAction(open: { _ in })
}

private enum DismissWindowKey: EnvironmentKey {
    static let defaultValue = DismissWindowAction(dismiss: { _ in })
}

/// Opens a window of a scene: `openWindow(id: "inspector")`.
public struct OpenWindowAction: Sendable {
    package let open: @MainActor @Sendable (String?) -> Void

    @MainActor public func callAsFunction(id: String) { open(id) }
    @MainActor public func callAsFunction<D: Hashable & Codable>(value: D) { open(nil) }
    @MainActor public func callAsFunction<D: Hashable & Codable>(id: String, value: D) { open(id) }
}

/// Closes the window that shows the view, or the windows of a scene.
public struct DismissWindowAction: Sendable {
    package let dismiss: @MainActor @Sendable (String?) -> Void

    @MainActor public func callAsFunction() { dismiss(nil) }
    @MainActor public func callAsFunction(id: String) { dismiss(id) }
}

extension EnvironmentValues {
    public var openWindow: OpenWindowAction {
        get { self[OpenWindowKey.self] }
        set { self[OpenWindowKey.self] = newValue }
    }

    public var dismissWindow: DismissWindowAction {
        get { self[DismissWindowKey.self] }
        set { self[DismissWindowKey.self] = newValue }
    }
}

// MARK: - onOpenURL

final class OpenURLHandlerState {
    var action: (URL) -> Void = { _ in }
    weak var services: WindowServices?
}

struct OpenURLModifier: PrimitiveModifier {
    let action: (URL) -> Void

    private func sync(_ node: ViewNode) {
        let s = (node.primitiveState as? OpenURLHandlerState) ?? OpenURLHandlerState()
        node.primitiveState = s
        s.action = action
        if let services = node.environment._windowServices {
            services.urlHandlers.removeAll { $0 === s }
            services.urlHandlers.append(s)
            s.services = services
        }
    }

    func _inserted(node: ViewNode) { sync(node) }
    func _updated(old: OpenURLModifier, node: ViewNode) { sync(node) }
    func _removed(node: ViewNode) {
        guard let s = node.primitiveState as? OpenURLHandlerState else { return }
        s.services?.urlHandlers.removeAll { $0 === s }
    }
}

extension View {
    /// Runs `action` when the application is asked to open a URL.
    public func onOpenURL(perform action: @escaping (URL) -> Void) -> some View {
        modifier(OpenURLModifier(action: action))
    }
}
