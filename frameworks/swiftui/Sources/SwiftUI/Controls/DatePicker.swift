import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// DatePicker, compact style (round R8). 06 §4 and golden
// `datePicker.compact`: the label, 8 points, and a compact button holding the
// formatted date with the bordered padding (12 × 7; 34.33 high at body),
// filling a proposed width like a toggle row (fit[0×0] = 130.67 = 8 + the
// button). The date is formatted in the environment's locale, calendar and
// time zone (medium date style; short time style). A click opens a pop-up:
// a month calendar for the date, steppers for the time (Ycode).

/// Which parts of a date a picker edits.
public struct DatePickerComponents: OptionSet, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }
    public static let hourAndMinute = DatePickerComponents(rawValue: 1 << 0)
    public static let date = DatePickerComponents(rawValue: 1 << 1)
}

/// A control that selects a date.
public struct DatePicker<Label: View>: View {
    public typealias Components = DatePickerComponents
    let selection: Binding<Date>
    let range: ClosedRange<Date>?
    let components: DatePickerComponents
    let label: Label
    @Environment(\._labelsHidden) private var labelsHidden
    @Environment(\._formColumnWidth) private var columnWidth
    @Environment(\._datePickerStyle) private var style

    public init(selection: Binding<Date>, displayedComponents: Components = [.hourAndMinute, .date],
                @ViewBuilder label: () -> Label) {
        self.selection = selection
        range = nil
        components = displayedComponents
        self.label = label()
    }

    public init(selection: Binding<Date>, in range: ClosedRange<Date>, displayedComponents: Components = [.hourAndMinute, .date],
                @ViewBuilder label: () -> Label) {
        self.selection = selection
        self.range = range
        components = displayedComponents
        self.label = label()
    }

    public var body: some View {
        let control = Group {
            if style == 1 {
                CalendarGrid(selection: selection, range: range, onPick: {})
            } else {
                CompactDateButtons(selection: selection, range: range, components: components)
            }
        }
        ControlRowLayout(columnWidth: columnWidth) {
            if !labelsHidden { label.modifier(ColumnLabelAlignment(inColumn: columnWidth != nil)) }
            control
        }
    }
}

extension DatePicker where Label == Text {
    public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, displayedComponents: Components = [.hourAndMinute, .date]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(titleKey) }
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S, selection: Binding<Date>, displayedComponents: Components = [.hourAndMinute, .date]) {
        self.init(selection: selection, displayedComponents: displayedComponents) { Text(title) }
    }

    public init(_ titleKey: LocalizedStringKey, selection: Binding<Date>, in range: ClosedRange<Date>,
                displayedComponents: Components = [.hourAndMinute, .date]) {
        self.init(selection: selection, in: range, displayedComponents: displayedComponents) { Text(titleKey) }
    }
}

// MARK: - Styles

@MainActor @preconcurrency
public protocol DatePickerStyle {
    /// Ycode's style identifier: 0 compact, 1 graphical.
    var _ovStyleKind: Int { get }
}

public struct DefaultDatePickerStyle: DatePickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct CompactDatePickerStyle: DatePickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

public struct GraphicalDatePickerStyle: DatePickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 1 }
}

/// Shown compact (Linux has no wheel).
public struct WheelDatePickerStyle: DatePickerStyle {
    public init() {}
    public var _ovStyleKind: Int { 0 }
}

extension DatePickerStyle where Self == DefaultDatePickerStyle {
    public static var automatic: DefaultDatePickerStyle { DefaultDatePickerStyle() }
}

extension DatePickerStyle where Self == CompactDatePickerStyle {
    public static var compact: CompactDatePickerStyle { CompactDatePickerStyle() }
}

extension DatePickerStyle where Self == GraphicalDatePickerStyle {
    public static var graphical: GraphicalDatePickerStyle { GraphicalDatePickerStyle() }
}

extension DatePickerStyle where Self == WheelDatePickerStyle {
    public static var wheel: WheelDatePickerStyle { WheelDatePickerStyle() }
}

private enum DatePickerStyleKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    var _datePickerStyle: Int {
        get { self[DatePickerStyleKey.self] }
        set { self[DatePickerStyleKey.self] = newValue }
    }
}

extension View {
    public func datePickerStyle<S: DatePickerStyle>(_ style: S) -> some View {
        environment(\._datePickerStyle, style._ovStyleKind)
    }
}

// MARK: - Formatting

/// The compact button's text for `date`.
func formattedDate(_ date: Date, time: Bool, locale: Locale, calendar: Calendar, timeZone: TimeZone) -> String {
    let f = DateFormatter()
    f.locale = locale
    f.calendar = calendar
    f.timeZone = timeZone
    f.dateStyle = time ? .none : .medium
    f.timeStyle = time ? .short : .none
    return f.string(from: date)
}

// MARK: - Compact buttons

struct CompactDateButtons: View {
    let selection: Binding<Date>
    let range: ClosedRange<Date>?
    let components: DatePickerComponents
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        HStack(spacing: 6) {
            if components.contains(.date) || components.isEmpty {
                CompactDateButton(text: formattedDate(selection.wrappedValue, time: false, locale: locale, calendar: calendar, timeZone: timeZone)) {
                    CalendarGrid(selection: selection, range: range, onPick: {})
                }
            }
            if components.contains(.hourAndMinute) {
                CompactDateButton(text: formattedDate(selection.wrappedValue, time: true, locale: locale, calendar: calendar, timeZone: timeZone)) {
                    TimeSteppers(selection: selection)
                }
            }
        }
    }
}

/// A bordered-style button holding a formatted part of the date; opens
/// `popup` below itself.
struct CompactDateButton<Popup: View>: View {
    let text: String
    let popup: () -> Popup
    @Environment(\._windowServices) private var services
    @Environment(\.colorScheme) private var scheme
    @State private var ref = NodeRef()
    @State private var box = PopupBox()

    init(text: String, @ViewBuilder popup: @escaping () -> Popup) {
        self.text = text
        self.popup = popup
    }

    var body: some View {
        let services = services, ref = ref, box = box
        let content = AnyView(popup().padding(10))
        Button(action: {
            openPopup(services: services, ref: ref, box: box, submenu: false, minWidth: 0, content: content)
        }) {
            Text(verbatim: text).foregroundStyle(box.isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.primary))
        }
        .buttonStyle(BorderedButtonStyle())
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .modifier(NodeCaptureModifier(ref: ref))
    }
}

// MARK: - Calendar

/// A month calendar: the month and year with previous/next buttons, the
/// weekday initials and the days; the selected day is filled with the tint.
struct CalendarGrid: View {
    let selection: Binding<Date>
    let range: ClosedRange<Date>?
    let onPick: () -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.locale) private var locale
    @Environment(\._dismissPopup) private var dismiss
    @State private var monthOffset = 0

    private var cal: Calendar {
        var c = calendar
        c.timeZone = timeZone
        c.locale = locale
        return c
    }

    var body: some View {
        let cal = cal
        let selected = selection.wrappedValue
        let base = cal.date(byAdding: .month, value: monthOffset, to: selected) ?? selected
        let comps = cal.dateComponents([.year, .month], from: base)
        let first = cal.date(from: comps) ?? base
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        let title: String = {
            let f = DateFormatter()
            f.locale = locale
            f.timeZone = timeZone
            f.calendar = cal
            f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
            return f.string(from: first)
        }()
        let symbols: [String] = {
            let s = cal.veryShortWeekdaySymbols
            return (0..<7).map { s[(($0 + cal.firstWeekday - 1) % 7)] }
        }()
        let selDay = cal.dateComponents([.year, .month, .day], from: selected)
        VStack(spacing: 6) {
            HStack {
                Text(verbatim: title).font(.headline)
                Spacer(minLength: 12)
                Button { monthOffset -= 1 } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(BorderlessButtonStyle())
                Button { monthOffset += 1 } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(BorderlessButtonStyle())
            }
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(0..<7, id: \.self) { i in
                        Text(verbatim: symbols[i]).font(.caption).foregroundStyle(.secondary).frame(width: 30)
                    }
                }
                ForEach(0..<6, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { col in
                            let day = week * 7 + col - lead + 1
                            if day >= 1 && day <= days {
                                let isSelected = selDay.year == comps.year && selDay.month == comps.month && selDay.day == day
                                DayCell(day: day, isSelected: isSelected) {
                                    var c = cal.dateComponents([.hour, .minute, .second], from: selected)
                                    c.year = comps.year
                                    c.month = comps.month
                                    c.day = day
                                    if var d = cal.date(from: c) {
                                        if let range { d = min(max(d, range.lowerBound), range.upperBound) }
                                        selection.wrappedValue = d
                                    }
                                    monthOffset = 0
                                    onPick()
                                    dismiss?()
                                }
                            } else {
                                Color.clear.frame(width: 30, height: 28)
                            }
                        }
                    }
                }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .environment(\._inMenu, false)
    }
}

struct DayCell: View {
    let day: Int
    let isSelected: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: "\(day)")
                .font(.callout)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(Color.primary))
                .frame(width: 30, height: 28)
                .background { if isSelected { Circle().fill(.tint).frame(width: 28, height: 28) } }
        }
    }
}

/// Hour and minute steppers (Ycode's time pop-up).
struct TimeSteppers: View {
    let selection: Binding<Date>
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        var cal = calendar
        cal.timeZone = timeZone
        let d = selection.wrappedValue
        let hour = cal.component(.hour, from: d), minute = cal.component(.minute, from: d)
        func shift(_ c: Calendar.Component, _ by: Int) {
            if let n = cal.date(byAdding: c, value: by, to: selection.wrappedValue) { selection.wrappedValue = n }
        }
        return VStack(alignment: .leading, spacing: 8) {
            Stepper(label: { Text(verbatim: String(format: "%02d h", hour)).monospacedDigit() },
                    onIncrement: { shift(.hour, 1) }, onDecrement: { shift(.hour, -1) })
            Stepper(label: { Text(verbatim: String(format: "%02d min", minute)).monospacedDigit() },
                    onIncrement: { shift(.minute, 1) }, onDecrement: { shift(.minute, -1) })
        }
        .frame(width: 200)
        .environment(\._inMenu, false)
    }
}
