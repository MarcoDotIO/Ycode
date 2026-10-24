import Foundation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

/// Records what views did (body evaluations, lifecycle actions), like the
/// probe's log lines.
@MainActor
final class Log {
    private(set) var entries: [String] = []

    func callAsFunction(_ s: String) { entries.append(s) }

    /// The entries since the last call.
    func take() -> [String] {
        defer { entries = [] }
        return entries
    }
}

@MainActor
extension ViewGraph {
    /// A graph for a root view, rendered once.
    static func rendered<V: View>(_ view: V, environment: EnvironmentValues = EnvironmentValues(),
                                  layout: HostLayout? = nil) -> ViewGraph {
        let g = ViewGraph(rootView: view, environment: environment, layout: layout)
        g.update()
        return g
    }
}

/// Holds bindings a test uses to drive a view's own state.
@MainActor
final class Controls<Value> {
    var binding: Binding<Value>?
    var value: Value {
        get { binding!.wrappedValue }
        set { binding!.wrappedValue = newValue }
    }
}

/// Test-only: the probe of golden-layout.md as a view modifier (a background
/// geometry reader that reports its frame under `name`; see Support/DSL.swift).
struct ProbeModifier: PrimitiveModifier {
    let name: String
    func _lower(_ content: [LayoutNode], secondary: () -> [LayoutNode], node: ViewNode) -> [LayoutNode] {
        content.map { $0.probe(name) }
    }
}

extension View {
    func probe(_ name: String) -> some View { modifier(ProbeModifier(name: name)) }
}
