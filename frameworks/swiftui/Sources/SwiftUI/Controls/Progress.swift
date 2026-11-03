import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// ProgressView and Gauge (round R8). Golden `progress.spinner`: 20 × 20 at
// every proposal; `progress.linear`: 0 × 4 unproposed, the proposed width
// otherwise. Golden `gauge` (linear capacity, the default): the label above
// a 16-point bar row with the default spacing between them (12.33 × 46.98
// for "G" = 20.33 + 10.64 + 16; 0 × 26.64 at 0 × 0).

// MARK: - ProgressView

/// A view that shows the progress of a task, determinate or not.
public struct ProgressView<Label: View, CurrentValueLabel: View>: View {
    let fraction: Double?
    let label: Label?
    let currentValueLabel: CurrentValueLabel?
    @Environment(\._progressViewStyle) private var style

    public var body: some View {
        let c = ProgressViewStyleConfiguration(fractionCompleted: fraction,
                                               label: label.map { .init(content: AnyView($0)) },
                                               currentValueLabel: currentValueLabel.map { .init(content: AnyView($0)) })
        let fraction = fraction
        Group {
            if let style {
                style.make(c)
            } else {
                DefaultProgressViewStyle().makeBody(configuration: c)
            }
        }
        // R10 (08 §2): value as a percentage, updates frequently.
        .accessibilityControl(.progressIndicator, traits: .updatesFrequently,
                              value: { fraction.map { "\(Int(($0 * 100).rounded()))%" } },
                              rangeValue: { fraction.map { AccessibilityRangeValue(current: $0 * 100, minimum: 0, maximum: 100, step: 1) } })
    }
}

private func fractionOf<V: BinaryFloatingPoint>(_ value: V?, _ total: V) -> Double? {
    guard let value else { return nil }
    guard total > 0 else { return 0 }
    return min(max(Double(value) / Double(total), 0), 1)
}

extension ProgressView where Label == EmptyView, CurrentValueLabel == EmptyView {
    /// Indeterminate.
    public init() {
        fraction = nil
        label = nil
        currentValueLabel = nil
    }

    /// Determinate; a nil value is indeterminate.
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0) {
        fraction = fractionOf(value, total)
        label = nil
        currentValueLabel = nil
    }
}

extension ProgressView where CurrentValueLabel == EmptyView {
    public init(@ViewBuilder label: () -> Label) {
        fraction = nil
        self.label = label()
        currentValueLabel = nil
    }

    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label) {
        fraction = fractionOf(value, total)
        self.label = label()
        currentValueLabel = nil
    }
}

extension ProgressView {
    public init<V: BinaryFloatingPoint>(value: V?, total: V = 1.0, @ViewBuilder label: () -> Label,
                                        @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {
        fraction = fractionOf(value, total)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
    }
}

extension ProgressView where Label == Text, CurrentValueLabel == EmptyView {
    public init(_ titleKey: LocalizedStringKey) {
        fraction = nil
        label = Text(titleKey)
        currentValueLabel = nil
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S) {
        fraction = nil
        label = Text(title)
        currentValueLabel = nil
    }

    public init<V: BinaryFloatingPoint>(_ titleKey: LocalizedStringKey, value: V?, total: V = 1.0) {
        fraction = fractionOf(value, total)
        label = Text(titleKey)
        currentValueLabel = nil
    }

    @_disfavoredOverload
    public init<S: StringProtocol, V: BinaryFloatingPoint>(_ title: S, value: V?, total: V = 1.0) {
        fraction = fractionOf(value, total)
        label = Text(title)
        currentValueLabel = nil
    }
}

/// What a progress style draws.
public struct ProgressViewStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct CurrentValueLabel: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    /// 0…1, or nil when indeterminate.
    public let fractionCompleted: Double?
    public var label: Label?
    public var currentValueLabel: CurrentValueLabel?
}

@MainActor @preconcurrency
public protocol ProgressViewStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = ProgressViewStyleConfiguration
}

struct AnyProgressViewStyle {
    let make: @MainActor (ProgressViewStyleConfiguration) -> AnyView
}

private enum ProgressViewStyleKey: EnvironmentKey { static let defaultValue: AnyProgressViewStyle? = nil }

extension EnvironmentValues {
    var _progressViewStyle: AnyProgressViewStyle? {
        get { self[ProgressViewStyleKey.self] }
        set { self[ProgressViewStyleKey.self] = newValue }
    }
}

extension View {
    public func progressViewStyle<S: ProgressViewStyle>(_ style: S) -> some View {
        environment(\._progressViewStyle, AnyProgressViewStyle { AnyView(style.makeBody(configuration: $0)) })
    }
}

/// Indeterminate: circular; determinate: linear.
public struct DefaultProgressViewStyle: ProgressViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        if configuration.fractionCompleted == nil {
            CircularProgressViewStyle().makeBody(configuration: configuration)
        } else {
            LinearProgressViewStyle().makeBody(configuration: configuration)
        }
    }
}

/// A bar 4 points high (golden), filling the width.
public struct LinearProgressViewStyle: ProgressViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        LinearProgressBody(configuration: configuration)
    }
}

/// A 20 × 20 spinner (golden) when indeterminate, a ring when determinate.
public struct CircularProgressViewStyle: ProgressViewStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        CircularProgressBody(configuration: configuration)
    }
}

extension ProgressViewStyle where Self == DefaultProgressViewStyle {
    public static var automatic: DefaultProgressViewStyle { DefaultProgressViewStyle() }
}

extension ProgressViewStyle where Self == LinearProgressViewStyle {
    public static var linear: LinearProgressViewStyle { LinearProgressViewStyle() }
}

extension ProgressViewStyle where Self == CircularProgressViewStyle {
    public static var circular: CircularProgressViewStyle { CircularProgressViewStyle() }
}

struct LinearProgressBody: View {
    let configuration: ProgressViewStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @State private var sweep = false

    var body: some View {
        let palette = ControlPalette(scheme)
        let bar = FillWidthLayout(height: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.fill)
                    if let f = configuration.fractionCompleted {
                        Capsule().fill(.tint).frame(width: w * CGFloat(f))
                    } else {
                        // Indeterminate: a segment sweeping across (Ycode).
                        Capsule().fill(.tint).frame(width: w * 0.3)
                            .offset(x: sweep ? w * 0.7 : 0)
                    }
                }
                .frame(width: w, height: 4)
                .clipShape(Capsule())
            }
        }
        .onAppear {
            guard configuration.fractionCompleted == nil else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
        }
        if configuration.label == nil && configuration.currentValueLabel == nil {
            bar
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let label = configuration.label { label }
                bar
                if let current = configuration.currentValueLabel {
                    current.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct SpinnerShape: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                Capsule()
                    .fill(Color.primary.opacity(0.15 + 0.85 * Double(i) / 7))
                    .frame(width: 2.5, height: 6)
                    .offset(y: -6.5)
                    .rotationEffect(.degrees(Double(i) * 45))
            }
        }
        .frame(width: 20, height: 20)
    }
}

struct CircularProgressBody: View {
    let configuration: ProgressViewStyleConfiguration
    @Environment(\.colorScheme) private var scheme
    @State private var turn = false

    var body: some View {
        let palette = ControlPalette(scheme)
        let indicator = Group {
            if let f = configuration.fractionCompleted {
                ZStack {
                    Circle().stroke(palette.fill, lineWidth: 3)
                    Circle().trim(from: 0, to: CGFloat(f)).stroke(.tint, lineWidth: 3)
                        .rotationEffect(.degrees(-90))
                }
                .padding(1.5)
                .frame(width: 20, height: 20)
            } else {
                SpinnerShape()
                    .rotationEffect(.degrees(turn ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turn = true }
                    }
            }
        }
        if let label = configuration.label {
            VStack(spacing: 8) {
                indicator
                label.foregroundStyle(.secondary)
            }
        } else {
            indicator
        }
    }
}

// MARK: - Gauge

/// A view that shows a value within a range.
public struct Gauge<Label: View, CurrentValueLabel: View, BoundsLabel: View, MarkedValueLabels: View>: View {
    let fraction: Double
    let label: Label
    let currentValueLabel: CurrentValueLabel?
    let minimumValueLabel: BoundsLabel?
    let maximumValueLabel: BoundsLabel?
    @Environment(\._gaugeStyle) private var style

    public var body: some View {
        let c = GaugeStyleConfiguration(value: fraction, label: .init(content: AnyView(label)),
                                        currentValueLabel: currentValueLabel.map { .init(content: AnyView($0)) },
                                        minimumValueLabel: minimumValueLabel.map { .init(content: AnyView($0)) },
                                        maximumValueLabel: maximumValueLabel.map { .init(content: AnyView($0)) })
        if let style {
            style.make(c)
        } else {
            LinearCapacityGaugeStyle().makeBody(configuration: c)
        }
    }
}

private func gaugeFraction<V: BinaryFloatingPoint>(_ v: V, _ r: ClosedRange<V>) -> Double {
    let span = Double(r.upperBound - r.lowerBound)
    guard span > 0 else { return 0 }
    return min(max(Double(v - r.lowerBound) / span, 0), 1)
}

extension Gauge where CurrentValueLabel == EmptyView, BoundsLabel == EmptyView, MarkedValueLabels == EmptyView {
    public init<V: BinaryFloatingPoint>(value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label) {
        fraction = gaugeFraction(value, bounds)
        self.label = label()
        currentValueLabel = nil
        minimumValueLabel = nil
        maximumValueLabel = nil
    }
}

extension Gauge where BoundsLabel == EmptyView, MarkedValueLabels == EmptyView {
    public init<V: BinaryFloatingPoint>(value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label,
                                        @ViewBuilder currentValueLabel: () -> CurrentValueLabel) {
        fraction = gaugeFraction(value, bounds)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
        minimumValueLabel = nil
        maximumValueLabel = nil
    }
}

extension Gauge where MarkedValueLabels == EmptyView {
    public init<V: BinaryFloatingPoint>(value: V, in bounds: ClosedRange<V> = 0...1, @ViewBuilder label: () -> Label,
                                        @ViewBuilder currentValueLabel: () -> CurrentValueLabel,
                                        @ViewBuilder minimumValueLabel: () -> BoundsLabel,
                                        @ViewBuilder maximumValueLabel: () -> BoundsLabel) {
        fraction = gaugeFraction(value, bounds)
        self.label = label()
        self.currentValueLabel = currentValueLabel()
        self.minimumValueLabel = minimumValueLabel()
        self.maximumValueLabel = maximumValueLabel()
    }
}

public struct GaugeStyleConfiguration {
    public struct Label: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct CurrentValueLabel: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct MinimumValueLabel: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct MaximumValueLabel: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    public struct MarkedValueLabel: View {
        let content: AnyView
        public var body: AnyView { content }
    }

    /// The value as a fraction of the range (0…1).
    public var value: Double
    public var label: Label
    public var currentValueLabel: CurrentValueLabel?
    public var minimumValueLabel: MinimumValueLabel?
    public var maximumValueLabel: MaximumValueLabel?
}

@MainActor @preconcurrency
public protocol GaugeStyle {
    associatedtype Body: View
    @ViewBuilder func makeBody(configuration: Configuration) -> Body
    typealias Configuration = GaugeStyleConfiguration
}

struct AnyGaugeStyle {
    let make: @MainActor (GaugeStyleConfiguration) -> AnyView
}

private enum GaugeStyleKey: EnvironmentKey { static let defaultValue: AnyGaugeStyle? = nil }

extension EnvironmentValues {
    var _gaugeStyle: AnyGaugeStyle? {
        get { self[GaugeStyleKey.self] }
        set { self[GaugeStyleKey.self] = newValue }
    }
}

extension View {
    public func gaugeStyle<S: GaugeStyle>(_ style: S) -> some View {
        environment(\._gaugeStyle, AnyGaugeStyle { AnyView(style.makeBody(configuration: $0)) })
    }
}

/// Label above a capacity bar (the default).
public struct LinearCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        GaugeLinearBody(configuration: configuration, accessory: false)
    }
}

public struct DefaultGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        LinearCapacityGaugeStyle().makeBody(configuration: configuration)
    }
}

/// A compact bar with the label in caption size.
public struct AccessoryLinearCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        GaugeLinearBody(configuration: configuration, accessory: true)
    }
}

/// A ring with the current value inside (44 × 44, Ycode).
public struct AccessoryCircularCapacityGaugeStyle: GaugeStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        GaugeCircularBody(configuration: configuration)
    }
}

extension GaugeStyle where Self == DefaultGaugeStyle {
    public static var automatic: DefaultGaugeStyle { DefaultGaugeStyle() }
}

extension GaugeStyle where Self == LinearCapacityGaugeStyle {
    public static var linearCapacity: LinearCapacityGaugeStyle { LinearCapacityGaugeStyle() }
}

extension GaugeStyle where Self == AccessoryLinearCapacityGaugeStyle {
    public static var accessoryLinearCapacity: AccessoryLinearCapacityGaugeStyle { AccessoryLinearCapacityGaugeStyle() }
    public static var accessoryLinear: AccessoryLinearCapacityGaugeStyle { AccessoryLinearCapacityGaugeStyle() }
}

extension GaugeStyle where Self == AccessoryCircularCapacityGaugeStyle {
    public static var accessoryCircularCapacity: AccessoryCircularCapacityGaugeStyle { AccessoryCircularCapacityGaugeStyle() }
    public static var accessoryCircular: AccessoryCircularCapacityGaugeStyle { AccessoryCircularCapacityGaugeStyle() }
}

struct GaugeLinearBody: View {
    let configuration: GaugeStyleConfiguration
    let accessory: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.font) private var font

    var body: some View {
        let palette = ControlPalette(scheme)
        let rowHeight: CGFloat = accessory ? 8 : 16
        let bar = FillWidthLayout(height: rowHeight) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.fill)
                    Capsule().fill(.tint).frame(width: w * CGFloat(configuration.value))
                }
                .frame(width: w, height: 6)
                .clipShape(Capsule())
                .frame(width: w, height: rowHeight)
            }
        }
        VStack(alignment: .leading) {
            if let current = configuration.currentValueLabel {
                HStack {
                    configuration.label
                    Spacer(minLength: 8)
                    current.foregroundStyle(.secondary)
                }
            } else {
                configuration.label
            }
            if configuration.minimumValueLabel != nil || configuration.maximumValueLabel != nil {
                HStack {
                    if let lo = configuration.minimumValueLabel { lo.font(.caption).foregroundStyle(.secondary) }
                    bar
                    if let hi = configuration.maximumValueLabel { hi.font(.caption).foregroundStyle(.secondary) }
                }
            } else {
                bar
            }
        }
        .environment(\.font, accessory ? .caption : font)
    }
}

struct GaugeCircularBody: View {
    let configuration: GaugeStyleConfiguration
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        ZStack {
            Circle().stroke(palette.fill, lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(configuration.value)).stroke(.tint, lineWidth: 5)
                .rotationEffect(.degrees(-90))
            if let current = configuration.currentValueLabel {
                current.font(.caption)
            } else {
                configuration.label.font(.caption2)
            }
        }
        .padding(2.5)
        .frame(width: 44, height: 44)
    }
}
