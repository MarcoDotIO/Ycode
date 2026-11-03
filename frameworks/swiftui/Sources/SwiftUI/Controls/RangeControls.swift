import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Slider and Stepper (round R8). Golden `slider`: 0 × 31 unproposed, the
// proposed width otherwise. 06 §4: a tap on the slider's track does not
// change the value (only dragging the thumb does). Golden `stepper`:
// label + 8 + a 94 × 32 control, filling a proposed width (fit[0×0] = 102).
// 06 §4: a tap on "+" increments by 1 (the step).

// MARK: - Slider

/// "30%": a value's place in a range, as accessibility reads it (08 §2).
func accessibilityPercent(_ v: Double, _ r: ClosedRange<Double>) -> String {
    let span = r.upperBound - r.lowerBound
    let f = span > 0 ? (v - r.lowerBound) / span : 0
    return "\(Int((f * 100).rounded()))%"
}

/// Slider geometry (Ycode; the height is the golden 31).
enum SliderMetrics {
    static let height: CGFloat = 31
    static let thumb: CGFloat = 24
    static let track: CGFloat = 6
    /// Extra distance around the thumb that still grabs it.
    static let grabSlop: CGFloat = 4
}

/// A control that selects a value from a range by dragging its thumb.
public struct Slider<Label: View, ValueLabel: View>: View {
    let value: Binding<Double>
    let bounds: ClosedRange<Double>
    let step: Double?
    let onEditingChanged: (Bool) -> Void
    let label: Label
    let minimumValueLabel: ValueLabel?
    let maximumValueLabel: ValueLabel?

    public var body: some View {
        let value = value, bounds = bounds, step = step
        SliderBody(value: value, bounds: bounds, step: step, onEditingChanged: onEditingChanged,
                   minimumValueLabel: minimumValueLabel.map { AnyView($0) },
                   maximumValueLabel: maximumValueLabel.map { AnyView($0) })
        // R10 (08 §2): adjustable, the value as a percentage of the range;
        // a step (or a tenth of the range) per adjustment.
        .accessibilityControl(.slider, value: { accessibilityPercent(value.wrappedValue, bounds) },
                              label: (label as? Text)?.plainString,
                              adjust: { d in
                                  let s = step ?? (bounds.upperBound - bounds.lowerBound) / 10
                                  let n = value.wrappedValue + (d == .increment ? s : -s)
                                  value.wrappedValue = min(max(n, bounds.lowerBound), bounds.upperBound)
                              },
                              rangeValue: {
                                  AccessibilityRangeValue(current: value.wrappedValue, minimum: bounds.lowerBound,
                                                          maximum: bounds.upperBound,
                                                          step: step ?? (bounds.upperBound - bounds.lowerBound) / 10) { v in
                                      value.wrappedValue = min(max(v, bounds.lowerBound), bounds.upperBound)
                                  }
                              },
                              children: .ignore)
    }
}

private func doubleBinding<V: BinaryFloatingPoint>(_ b: Binding<V>) -> Binding<Double> {
    Binding(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = V($0) })
}

extension Slider where Label == EmptyView, ValueLabel == EmptyView {
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: doubleBinding(value), bounds: Double(bounds.lowerBound)...Double(bounds.upperBound), step: nil,
                  onEditingChanged: onEditingChanged, label: EmptyView(), minimumValueLabel: nil, maximumValueLabel: nil)
    }

    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: doubleBinding(value), bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
                  step: Double(step), onEditingChanged: onEditingChanged, label: EmptyView(),
                  minimumValueLabel: nil, maximumValueLabel: nil)
    }
}

extension Slider where ValueLabel == EmptyView {
    /// The label is not shown (as on the reference outside forms); it names
    /// the slider for accessibility.
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V> = 0...1,
                                        @ViewBuilder label: () -> Label,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: doubleBinding(value), bounds: Double(bounds.lowerBound)...Double(bounds.upperBound), step: nil,
                  onEditingChanged: onEditingChanged, label: label(), minimumValueLabel: nil, maximumValueLabel: nil)
    }

    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride,
                                        @ViewBuilder label: () -> Label,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: doubleBinding(value), bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
                  step: Double(step), onEditingChanged: onEditingChanged, label: label(),
                  minimumValueLabel: nil, maximumValueLabel: nil)
    }
}

extension Slider {
    /// With labels for the minimum and maximum at the ends of the track.
    public init<V: BinaryFloatingPoint>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1,
                                        @ViewBuilder label: () -> Label,
                                        @ViewBuilder minimumValueLabel: () -> ValueLabel,
                                        @ViewBuilder maximumValueLabel: () -> ValueLabel,
                                        onEditingChanged: @escaping (Bool) -> Void = { _ in }) where V.Stride: BinaryFloatingPoint {
        self.init(value: doubleBinding(value), bounds: Double(bounds.lowerBound)...Double(bounds.upperBound),
                  step: Double(step), onEditingChanged: onEditingChanged, label: label(),
                  minimumValueLabel: minimumValueLabel(), maximumValueLabel: maximumValueLabel())
    }
}

struct SliderBody: View {
    let value: Binding<Double>
    let bounds: ClosedRange<Double>
    let step: Double?
    let onEditingChanged: (Bool) -> Void
    let minimumValueLabel: AnyView?
    let maximumValueLabel: AnyView?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var grab: CGFloat?
    @State private var isFocused = false

    private var span: Double { bounds.upperBound - bounds.lowerBound }

    private func fraction(_ v: Double) -> Double {
        span > 0 ? min(max((v - bounds.lowerBound) / span, 0), 1) : 0
    }

    /// The value for a fraction, snapped to the step and clamped.
    func snapped(_ f: Double) -> Double {
        var v = bounds.lowerBound + min(max(f, 0), 1) * span
        if let step, step > 0 {
            v = bounds.lowerBound + ((v - bounds.lowerBound) / step).rounded() * step
            v = min(max(v, bounds.lowerBound), bounds.upperBound)
        }
        return v
    }

    private func set(_ v: Double) {
        let c = min(max(v, bounds.lowerBound), bounds.upperBound)
        if value.wrappedValue != c { value.wrappedValue = c }
    }

    private var keyStep: Double { step ?? (span / 20) }

    var body: some View {
        let palette = ControlPalette(scheme)
        let track = FillWidthLayout(height: SliderMetrics.height) {
            GeometryReader { g in
                let w = g.size.width
                let t = SliderMetrics.thumb
                let usable = max(1, w - t)
                let cx = t / 2 + CGFloat(fraction(value.wrappedValue)) * usable
                let cy = SliderMetrics.height / 2
                ZStack(alignment: .topLeading) {
                    Capsule().fill(palette.fill)
                        .frame(width: max(0, w - 4), height: SliderMetrics.track)
                        .offset(x: 2, y: cy - SliderMetrics.track / 2)
                    Capsule().fill(.tint)
                        .frame(width: max(0, cx - 2), height: SliderMetrics.track)
                        .offset(x: 2, y: cy - SliderMetrics.track / 2)
                    Circle().fill(palette.thumb)
                        .overlay { Circle().stroke(palette.thumbBorder, lineWidth: 0.5) }
                        .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                        .frame(width: t, height: t)
                        .focusRing(isFocused, Circle())
                        .offset(x: cx - t / 2, y: cy - t / 2)
                }
                .frame(width: w, height: SliderMetrics.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .gesture(ControlTrackGesture(accepts: { p in
                    abs(p.x - cx) <= t / 2 + SliderMetrics.grabSlop && abs(p.y - cy) <= t / 2 + SliderMetrics.grabSlop
                }, handler: { e in
                    switch e {
                    case .down(let p, _):
                        grab = p.x - cx
                        onEditingChanged(true)
                    case .moved(let p, _):
                        let g0 = grab ?? 0
                        set(snapped(Double((p.x - g0 - t / 2) / usable)))
                    case .up, .cancelled:
                        grab = nil
                        onEditingChanged(false)
                    }
                }))
            }
        }
        .controlFocus($isFocused) { k in
            guard k.isDown else { return false }
            switch k.key {
            case .leftArrow, .downArrow: set(value.wrappedValue - keyStep)
            case .rightArrow, .upArrow: set(value.wrappedValue + keyStep)
            case .home: set(bounds.lowerBound)
            case .end: set(bounds.upperBound)
            default: return false
            }
            return true
        }
        Group {
            if minimumValueLabel != nil || maximumValueLabel != nil {
                HStack {
                    if let minimumValueLabel { minimumValueLabel }
                    track
                    if let maximumValueLabel { maximumValueLabel }
                }
            } else {
                track
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
    }
}

// MARK: - Stepper

enum StepperMetrics {
    static let size = CGSize(width: 94, height: 32)
}

/// A control that increments or decrements a value.
public struct Stepper<Label: View>: View {
    let label: Label
    let onIncrement: (() -> Void)?
    let onDecrement: (() -> Void)?
    let onEditingChanged: (Bool) -> Void
    let canIncrement: () -> Bool
    let canDecrement: () -> Bool
    @Environment(\._labelsHidden) private var labelsHidden

    public init(@ViewBuilder label: () -> Label, onIncrement: (() -> Void)?, onDecrement: (() -> Void)?,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label()
        self.onIncrement = onIncrement
        self.onDecrement = onDecrement
        self.onEditingChanged = onEditingChanged
        canIncrement = { onIncrement != nil }
        canDecrement = { onDecrement != nil }
    }

    public init<V: Strideable>(value: Binding<V>, in bounds: ClosedRange<V>, step: V.Stride = 1,
                               @ViewBuilder label: () -> Label, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label()
        self.onEditingChanged = onEditingChanged
        onIncrement = {
            let n = value.wrappedValue.advanced(by: step)
            value.wrappedValue = min(n, bounds.upperBound)
        }
        onDecrement = {
            let n = value.wrappedValue.advanced(by: -step)
            value.wrappedValue = max(n, bounds.lowerBound)
        }
        canIncrement = { value.wrappedValue < bounds.upperBound }
        canDecrement = { value.wrappedValue > bounds.lowerBound }
    }

    public init<V: Strideable>(value: Binding<V>, step: V.Stride = 1, @ViewBuilder label: () -> Label,
                               onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.label = label()
        self.onEditingChanged = onEditingChanged
        onIncrement = { value.wrappedValue = value.wrappedValue.advanced(by: step) }
        onDecrement = { value.wrappedValue = value.wrappedValue.advanced(by: -step) }
        canIncrement = { true }
        canDecrement = { true }
    }

    public var body: some View {
        let inc = onIncrement, dec = onDecrement
        ControlRowLayout {
            if !labelsHidden { label }
            StepperControl(onIncrement: onIncrement, onDecrement: onDecrement, onEditingChanged: onEditingChanged,
                           canIncrement: canIncrement(), canDecrement: canDecrement())
                .accessibilityHidden(true)
        }
        // R10: an adjustable element with the label (the reference's stepper
        // element was not found, 10-plan.md §4 question 6; Ycode's choice).
        .accessibilityControl(.stepper, adjust: { d in if d == .increment { inc?() } else { dec?() } })
    }
}

extension Stepper where Label == Text {
    public init<V: Strideable>(_ titleKey: LocalizedStringKey, value: Binding<V>, in bounds: ClosedRange<V>,
                               step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(value: value, in: bounds, step: step, label: { Text(titleKey) }, onEditingChanged: onEditingChanged)
    }

    @_disfavoredOverload
    public init<S: StringProtocol, V: Strideable>(_ title: S, value: Binding<V>, in bounds: ClosedRange<V>,
                                                  step: V.Stride = 1, onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(value: value, in: bounds, step: step, label: { Text(title) }, onEditingChanged: onEditingChanged)
    }

    public init<V: Strideable>(_ titleKey: LocalizedStringKey, value: Binding<V>, step: V.Stride = 1,
                               onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(value: value, step: step, label: { Text(titleKey) }, onEditingChanged: onEditingChanged)
    }

    @_disfavoredOverload
    public init<S: StringProtocol, V: Strideable>(_ title: S, value: Binding<V>, step: V.Stride = 1,
                                                  onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(value: value, step: step, label: { Text(title) }, onEditingChanged: onEditingChanged)
    }

    public init(_ titleKey: LocalizedStringKey, onIncrement: (() -> Void)?, onDecrement: (() -> Void)?,
                onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        self.init(label: { Text(titleKey) }, onIncrement: onIncrement, onDecrement: onDecrement,
                  onEditingChanged: onEditingChanged)
    }
}

/// The − / + pair (94 × 32, golden): two 47-point halves on a capsule.
struct StepperControl: View {
    let onIncrement: (() -> Void)?
    let onDecrement: (() -> Void)?
    let onEditingChanged: (Bool) -> Void
    let canIncrement: Bool
    let canDecrement: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    @State private var pressed: Int?
    @State private var isFocused = false

    private func half(_ index: Int, symbol: String, enabled: Bool, action: (() -> Void)?) -> some View {
        let palette = ControlPalette(scheme)
        let on = enabled && isEnabled && action != nil
        let editing = onEditingChanged
        return Image(systemName: symbol)
            .foregroundStyle(on ? AnyShapeStyle(Color.primary) : AnyShapeStyle(palette.placeholder))
            .frame(width: StepperMetrics.size.width / 2, height: StepperMetrics.size.height)
            .background { if pressed == index { palette.subtleFill } }
            .contentShape(Rectangle())
            .gesture(ControlPressGesture(onPressed: { p in
                guard on else { return }
                pressed = p ? index : nil
                editing(p)
            }, onAction: { if on { action?() } }))
    }

    var body: some View {
        let palette = ControlPalette(scheme)
        HStack(spacing: 0) {
            half(0, symbol: "minus", enabled: canDecrement, action: onDecrement)
            half(1, symbol: "plus", enabled: canIncrement, action: onIncrement)
        }
        .overlay { Rectangle().fill(palette.separator).frame(width: 1, height: 18).allowsHitTesting(false) }
        .frame(width: StepperMetrics.size.width, height: StepperMetrics.size.height)
        .background(palette.fill, in: Capsule())
        .clipShape(Capsule())
        .focusRing(isFocused, Capsule())
        .controlFocus($isFocused) { k in
            guard k.isDown else { return false }
            switch k.key {
            case .upArrow, .rightArrow, .character("+"), .character("="):
                if canIncrement { onIncrement?() }
            case .downArrow, .leftArrow, .character("-"):
                if canDecrement { onDecrement?() }
            default: return false
            }
            return true
        }
    }
}
