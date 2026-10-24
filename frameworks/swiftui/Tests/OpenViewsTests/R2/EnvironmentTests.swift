import Foundation
import Observation
import Testing
#if OPENVIEWS_RENAMED
@testable import OpenViewsCore
@testable import OpenViews
#else
@testable import SwiftUICore
@testable import SwiftUI
#endif

// Environment propagation: 03 §3 (per-key dependencies), §6 (inner
// environment modifiers override outer ones), §7; 08 §1 (defaults);
// `@Environment(Type.self)` for `@Observable` objects; `@EnvironmentObject`.

struct ReadsScheme: View {
    let log: Log
    @Environment(\.colorScheme) var scheme
    var body: some View {
        let _ = log("scheme \(scheme)")
        Color.red
    }
}

struct ReadsDirection: View {
    let log: Log
    @Environment(\.layoutDirection) var direction
    var body: some View {
        let _ = log("direction \(direction)")
        Color.red
    }
}

struct ReadsNothing: View {
    let log: Log
    var body: some View {
        let _ = log("nothing")
        Color.red
    }
}

struct SchemeTree: View {
    let log: Log
    var body: some View {
        VStack {
            ReadsScheme(log: log)
            ReadsDirection(log: log)
            ReadsNothing(log: log)
        }
    }
}

struct InnerOverride: View {
    let log: Log
    var body: some View {
        VStack {
            ReadsScheme(log: log)
            ReadsScheme(log: log).environment(\.colorScheme, .light)
        }
        .environment(\.colorScheme, .dark)
    }
}

@Observable
final class EnvModel {
    var a = 0
    var b = 0
}

struct EnvModelReaderA: View {
    let log: Log
    @Environment(EnvModel.self) var model
    var body: some View {
        let _ = log("readerA \(model.a)")
        Color.red
    }
}

struct EnvModelReaderB: View {
    let log: Log
    @Environment(EnvModel.self) var model
    var body: some View {
        let _ = log("readerB \(model.b)")
        Color.red
    }
}

struct OptionalModelReader: View {
    let log: Log
    @Environment(EnvModel.self) var model: EnvModel?
    var body: some View {
        let _ = log("optional \(model == nil ? "nil" : "set")")
        Color.red
    }
}

final class Settings: ObservableObject {
    @Published var name = "a"
}

struct SettingsReader: View {
    let log: Log
    @EnvironmentObject var settings: Settings
    var body: some View {
        let _ = log("settings \(settings.name)")
        Color.red
    }
}

@MainActor
@Suite("Environment (03 §3, §6, §7; 08 §1)")
struct EnvironmentTests {
    let log = Log()

    @Test("08 §1: defaults at the root")
    func defaults() {
        let env = EnvironmentValues()
        #expect(env.colorScheme == .light)
        #expect(env.colorSchemeContrast == .standard)
        #expect(env.dynamicTypeSize == .large)
        #expect(env.legibilityWeight == .regular)
        #expect(env.layoutDirection == .leftToRight)
        #expect(env.locale.identifier == "en_US")
        #expect(env.calendar.identifier == .gregorian)
        #expect(env.displayScale == 3)
        #expect(env.pixelLength == 1.0 / 3)
        #expect(env.horizontalSizeClass == .compact)
        #expect(env.verticalSizeClass == .regular)
        #expect(!env.accessibilityReduceMotion && !env.accessibilityReduceTransparency
                && !env.accessibilityDifferentiateWithoutColor && !env.accessibilityInvertColors
                && !env.accessibilityShowButtonShapes && !env.accessibilityVoiceOverEnabled
                && !env.accessibilitySwitchControlEnabled && !env.accessibilityEnabled)
        #expect(env.isEnabled)
        #expect(env.lineLimit == nil)
        #expect(env.multilineTextAlignment == .leading)
        #expect(env.truncationMode == .tail)
        #expect(env.defaultMinListRowHeight == 52)
        #expect(env.defaultMinListHeaderHeight == nil)
        #expect(env.controlSize == .regular)
        #expect(env.imageScale == .medium)
        #expect(env.redactionReasons.isEmpty)
        #expect(!env.isLuminanceReduced && !env.supportsMultipleWindows && !env.isSceneCaptured)
        #expect(env.font == nil)
    }

    @Test("a root environment change re-runs only the readers of the changed key")
    func perKey() {
        let g = ViewGraph.rendered(SchemeTree(log: log))
        #expect(log.take() == ["scheme light", "direction leftToRight", "nothing"])
        g.updateEnvironment { $0.colorScheme = .dark }
        g.update()
        #expect(log.take() == ["scheme dark"])
        g.updateEnvironment { $0.layoutDirection = .rightToLeft }
        g.update()
        #expect(log.take() == ["direction rightToLeft"])
        // A new environment with equal values re-runs nothing.
        g.updateEnvironment { $0.colorScheme = .dark }
        g.update()
        #expect(log.take() == [])
    }

    @Test("03 §6: inner environment modifiers override outer ones")
    func innerOverrides() {
        _ = ViewGraph.rendered(InnerOverride(log: log))
        #expect(log.take() == ["scheme dark", "scheme light"])
    }

    @Test("03 §6: .font on a stack, .font on a child → the child keeps its own font")
    func fontOverride() {
        let node = ViewGraph.layoutNode(for: VStack {
            Text("a")
            Text("b").font(.caption)
        }.font(.title))
        let fonts = node.children.compactMap { ($0.behavior as? TextLeaf)?.font.textStyle }
        #expect(fonts == [.title, .caption])
    }

    @Test("@Environment(Type.self): dependencies stay per property of the object")
    func observableObjectInEnvironment() {
        let model = EnvModel()
        let g = ViewGraph.rendered(VStack {
            EnvModelReaderA(log: log)
            EnvModelReaderB(log: log)
            OptionalModelReader(log: log)
        }.environment(model))
        #expect(log.take() == ["readerA 0", "readerB 0", "optional set"])
        model.a = 1
        g.update()
        #expect(log.take() == ["readerA 1"])
        model.b = 1
        g.update()
        #expect(log.take() == ["readerB 1"])
    }

    @Test("@Environment(Type.self) optional form reads nil without an object")
    func optionalObject() {
        _ = ViewGraph.rendered(OptionalModelReader(log: log))
        #expect(log.take() == ["optional nil"])
    }

    @Test("@EnvironmentObject: observes the object supplied by an ancestor")
    func environmentObject() {
        let settings = Settings()
        let g = ViewGraph.rendered(VStack {
            SettingsReader(log: log)
            ReadsNothing(log: log)
        }.environmentObject(settings))
        #expect(log.take() == ["settings a", "nothing"])
        settings.name = "b"
        g.update()
        #expect(log.take() == ["settings b"])
        // Supplying another object re-runs the reader.
        let other = Settings()
        other.name = "other"
        g.setRootView(VStack {
            SettingsReader(log: log)
            ReadsNothing(log: log)
        }.environmentObject(other))
        g.update()
        #expect(log.take() == ["settings other"])
    }

    @Test("transformEnvironment and disabled(_:) compose with outer values")
    func transform() {
        struct ReadsEnabled: View {
            let log: Log
            @Environment(\.isEnabled) var enabled
            var body: some View {
                let _ = log("enabled \(enabled)")
                Color.red
            }
        }
        _ = ViewGraph.rendered(VStack {
            ReadsEnabled(log: log).disabled(false)
            ReadsEnabled(log: log)
        }.disabled(true))
        #expect(log.take() == ["enabled false", "enabled false"])
    }
}
