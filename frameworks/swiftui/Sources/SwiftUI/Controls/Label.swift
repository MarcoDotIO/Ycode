import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Label, Link and LabeledContent (round R8). Golden `label`: the icon, the
// standard 8-point gap, the title, aligned on their first text baselines
// (63 × 20.99 for "Title" with `star`; 30 × 20.67 at 0 × 0). Golden `link`:
// the title's size, in the tint colour.

// MARK: - Label

/// The title-and-symbol label `Button(_:systemImage:action:)` uses.
public typealias _TitleAndIconLabel = Label<Text, Image>

/// A title with an icon.
public struct Label<Title: View, Icon: View>: View {
    let title: Title
    let icon: Icon
    @Environment(\._labelStyle) private var style

    public init(@ViewBuilder title: () -> Title, @ViewBuilder icon: () -> Icon) {
        self.title = title()
        self.icon = icon()
    }

    public var body: some View {
        // R10: a label is read by its title (the icon is not an element).
        // R13: an icon shown alone is read by the title.
        let c = LabelStyleConfiguration(title: .init(content: AnyView(title)),
                                        icon: .init(content: AnyView(icon.accessibilityHidden(true))),
                                        accessibilityTitle: (title as? Text)?.plainString, visibleIcon: AnyView(icon))
        if let style {
            style.make(c)
        } else {
            DefaultLabelStyle().makeBody(configuration: c)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    public init(_ titleKey: LocalizedStringKey, systemImage name: String) {
        self.init(title: { Text(titleKey) }, icon: { Image(systemName: name) })
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, systemImage name: String) {
        self.init(title: { Text(title) }, icon: { Image(systemName: name) })
    }

    public init(_ titleKey: LocalizedStringKey, image name: String) {
        self.init(title: { Text(titleKey) }, icon: { Image(name) })
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, image name: String) {
        self.init(title: { Text(title) }, icon: { Image(name) })
    }
}

/// What a label style draws.
public struct LabelStyleConfiguration {
    public struct Title: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct Icon: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public var title: Title
    public var icon: Icon
    /// The title as text (for an icon shown without it).
    package var accessibilityTitle: String?
    /// The icon, not hidden from accessibility.
    package var visibleIcon: AnyView?
}

@MainActor @preconcurrency
public protocol LabelStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = LabelStyleConfiguration
}

struct AnyLabelStyle {
    let make: @MainActor (LabelStyleConfiguration) -> AnyView
}

private enum LabelStyleKey: EnvironmentKey { static let defaultValue: AnyLabelStyle? = nil }

extension EnvironmentValues {
    var _labelStyle: AnyLabelStyle? {
        get { self[LabelStyleKey.self] }
        set { self[LabelStyleKey.self] = newValue }
    }
}

extension View {
    public func labelStyle<S: LabelStyle>(_ style: S) -> some View {
        environment(\._labelStyle, AnyLabelStyle { AnyView(style.makeBody(configuration: $0)) })
    }
}

/// Icon then title, on the first text baseline.
public struct DefaultLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline) {
            configuration.icon
            configuration.title
        }
    }
}

public struct TitleAndIconLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        DefaultLabelStyle().makeBody(configuration: configuration)
    }
}

public struct TitleOnlyLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View { configuration.title }
}

public struct IconOnlyLabelStyle: LabelStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        if let t = configuration.accessibilityTitle, let icon = configuration.visibleIcon {
            icon.accessibilityLabel(Text(verbatim: t))
        } else {
            configuration.icon
        }
    }
}

extension LabelStyle where Self == DefaultLabelStyle {
    public static var automatic: DefaultLabelStyle { DefaultLabelStyle() }
}

extension LabelStyle where Self == TitleAndIconLabelStyle {
    public static var titleAndIcon: TitleAndIconLabelStyle { TitleAndIconLabelStyle() }
}

extension LabelStyle where Self == TitleOnlyLabelStyle {
    public static var titleOnly: TitleOnlyLabelStyle { TitleOnlyLabelStyle() }
}

extension LabelStyle where Self == IconOnlyLabelStyle {
    public static var iconOnly: IconOnlyLabelStyle { IconOnlyLabelStyle() }
}

// MARK: - Link

/// A control that opens a URL (through the environment's `openURL`).
public struct Link<Label: View>: View {
    let destination: URL
    let label: Label
    @Environment(\.openURL) private var openURL

    public init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination
        self.label = label()
    }

    public var body: some View {
        let open = openURL, url = destination
        Button(action: { open(url) }) { label }
            .accessibilityControl(.link, traits: .isLink, actions: ["default": { open(url) }])
    }
}

extension Link where Label == Text {
    public init(_ titleKey: LocalizedStringKey, destination: URL) {
        self.init(destination: destination) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, destination: URL) {
        self.init(destination: destination) { Text(title) }
    }
}

// MARK: - LabeledContent

/// A label beside a value or a control.
public struct LabeledContent<Label: View, Content: View>: View {
    let label: Label
    let content: Content
    @Environment(\._labeledContentStyle) private var style
    @Environment(\._labelsHidden) private var labelsHidden

    public init(@ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.content = content()
        self.label = label()
    }

    public var body: some View {
        let c = LabeledContentStyleConfiguration(label: .init(content: AnyView(label)),
                                                 content: .init(content: AnyView(content)))
        if labelsHidden {
            c.content
        } else if let style {
            style.make(c)
        } else {
            AutomaticLabeledContentStyle().makeBody(configuration: c)
        }
    }
}

extension LabeledContent where Label == Text {
    public init(_ titleKey: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, @ViewBuilder content: () -> Content) {
        self.init(content: content) { Text(title) }
    }
}

extension LabeledContent where Label == Text, Content == Text {
    public init<S: StringProtocol>(_ titleKey: LocalizedStringKey, value: S) {
        self.init(content: { Text(value) }) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S1: StringProtocol, S2: StringProtocol>(_ title: S1, value: S2) {
        self.init(content: { Text(value) }) { Text(title) }
    }
}

public struct LabeledContentStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct Content: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public let label: Label
    public let content: Content
}

@MainActor @preconcurrency
public protocol LabeledContentStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = LabeledContentStyleConfiguration
}

struct AnyLabeledContentStyle {
    let make: @MainActor (LabeledContentStyleConfiguration) -> AnyView
}

private enum LabeledContentStyleKey: EnvironmentKey { static let defaultValue: AnyLabeledContentStyle? = nil }

extension EnvironmentValues {
    var _labeledContentStyle: AnyLabeledContentStyle? {
        get { self[LabeledContentStyleKey.self] }
        set { self[LabeledContentStyleKey.self] = newValue }
    }
}

extension View {
    public func labeledContentStyle<S: LabeledContentStyle>(_ style: S) -> some View {
        environment(\._labeledContentStyle, AnyLabeledContentStyle { AnyView(style.makeBody(configuration: $0)) })
    }
}

/// The label at the leading edge, the content (secondary colour) at the
/// trailing edge.
public struct AutomaticLabeledContentStyle: LabeledContentStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            configuration.content.foregroundStyle(.secondary)
        }
    }
}

extension LabeledContentStyle where Self == AutomaticLabeledContentStyle {
    public static var automatic: AutomaticLabeledContentStyle { AutomaticLabeledContentStyle() }
}
