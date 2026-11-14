import Foundation
import OVPlatform
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Ycode's extension (not part of Apple's SwiftUI): a view that draws its
// own slider (a custom track and knob) is exposed to accessibility the way
// `Slider` exposes itself (R10): role slider, the given label, the value as
// a percentage of the range, increment and decrement by `step`, and a
// settable range value. Apple's SwiftUI reaches the same with
// `accessibilityRepresentation { Slider(…) }`, which OpenViews does not
// have; Ycode's Settings ▸ Appearance uses this for its colour sliders
// (`specs/ide/settings.md` R7.3).

extension View {
    public func accessibilitySliderElement(label: String, value: Binding<Double>, in bounds: ClosedRange<Double> = 0...1,
                                           step: Double) -> some View {
        accessibilityControl(.slider, value: { accessibilityPercent(value.wrappedValue, bounds) },
                             label: label,
                             adjust: { d in
                                 let n = value.wrappedValue + (d == .increment ? step : -step)
                                 value.wrappedValue = min(max(n, bounds.lowerBound), bounds.upperBound)
                             },
                             rangeValue: {
                                 AccessibilityRangeValue(current: value.wrappedValue, minimum: bounds.lowerBound,
                                                         maximum: bounds.upperBound, step: step) { v in
                                     value.wrappedValue = min(max(v, bounds.lowerBound), bounds.upperBound)
                                 }
                             },
                             children: .ignore)
    }
}
