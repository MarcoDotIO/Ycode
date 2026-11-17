import Foundation
#if OPENVIEWS_RENAMED
import OpenViewsCore
#else
import SwiftUICore
#endif

// Alerts on a desktop host (P-214, L-180): drawn as the macOS IDE's alerts
// are (its NSAlert sheets, measured from Ycode's own macOS recordings of the
// 2026-11-15 parity run): a 260-point card (330 with a text field) with the
// app's icon (64 points, 20 from the top), a bold 13-point title and a
// 13-point message, both left-aligned 20 from the sides; the alert's text
// fields below them, full width; then the buttons, 28-point capsules: two
// side by side with equal widths in a 228-point row centred in the card
// (cancel leading, the default trailing in the accent colour), otherwise one
// per row (the default first, cancel last); 15 points below them. The
// corners are 20 points round. Return chooses the default button and
// Escape the cancel button (`AlertKeys`).

enum DesktopAlertMetrics {
    static let width: CGFloat = 260
    static let widthWithField: CGFloat = 330
    static let cornerRadius: CGFloat = 20
    static let iconSize: CGFloat = 64
    static let top: CGFloat = 20
    static let textInset: CGFloat = 20
    static let fieldInset: CGFloat = 16
    static let iconToTitle: CGFloat = 14
    static let titleToMessage: CGFloat = 10
    static let textToButtons: CGFloat = 16
    static let buttonHeight: CGFloat = 28
    static let buttonSpacing: CGFloat = 8
    static let buttonRowWidth: CGFloat = 228
    static let bottom: CGFloat = 15
}

struct DesktopAlertCard: View {
    let title: Text?
    let message: AnyView
    let hasMessage: Bool
    let buttons: [any View]
    let keys: AlertKeys
    let dismiss: () -> Void
    @Environment(\._alertIcon) private var icon

    typealias M = DesktopAlertMetrics

    var body: some View {
        let fields = buttons.indices.filter { AlertKeys.isTextField(buttons[$0]) }
        let pressable = buttons.indices.filter { !fields.contains($0) }
        let width = fields.isEmpty ? M.width : M.widthWithField
        let order = Self.order(pressable, keys: keys)
        let dismiss = dismiss
        return VStack(alignment: .leading, spacing: 0) {
            if let icon {
                icon.frame(width: M.iconSize, height: M.iconSize)
                    .padding(.leading, M.textInset - 1)
                    .padding(.bottom, M.iconToTitle)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: M.titleToMessage) {
                if let title {
                    title.font(.system(size: 13, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                }
                if hasMessage {
                    message.font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, M.textInset)
            ForEach(fields, id: \.self) { i in
                AnyView(_fromValue: buttons[i])!
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, M.fieldInset)
                    .padding(.top, M.textToButtons - 2)
            }
            buttonRow(order, width: width)
                .padding(.top, M.textToButtons)
        }
        .padding(.top, M.top)
        .padding(.bottom, M.bottom)
        .frame(width: width, alignment: .leading)
        .buttonStyle(DesktopAlertButtonStyle(dismiss: dismiss))
        .environment(\._afterButtonAction, { dismiss() })
    }

    /// Two buttons: cancel leading, the other trailing; more: the default
    /// first, the cancel button last.
    static func order(_ pressable: [Int], keys: AlertKeys) -> [Int] {
        var rest = pressable.filter { $0 != keys.defaultIndex && $0 != keys.cancel }
        if pressable.count == 2 {
            let cancel = keys.cancel ?? pressable.first { $0 != keys.defaultIndex } ?? pressable[0]
            return [cancel] + pressable.filter { $0 != cancel }
        }
        if let d = keys.defaultIndex, pressable.contains(d) { rest.insert(d, at: 0) }
        if let c = keys.cancel, pressable.contains(c), c != keys.defaultIndex { rest.append(c) }
        return rest
    }

    @ViewBuilder
    private func buttonRow(_ order: [Int], width: CGFloat) -> some View {
        let rowWidth = min(width - 32, M.buttonRowWidth)
        Group {
            if order.count == 2 {
                HStack(spacing: M.buttonSpacing) {
                    ForEach(order, id: \.self) { i in button(i) }
                }
            } else {
                VStack(spacing: M.buttonSpacing) {
                    ForEach(order, id: \.self) { i in button(i) }
                }
            }
        }
        .frame(width: rowWidth)
        .frame(maxWidth: .infinity)
    }

    private func button(_ i: Int) -> some View {
        keys.apply(i, to: buttons[i])
            .environment(\._alertButtonIsDefault, i == keys.defaultIndex)
            .frame(maxWidth: .infinity)
            .frame(height: M.buttonHeight)
    }
}

/// The desktop alert's push buttons (choosing one dismisses the alert).
struct DesktopAlertButtonStyle: PrimitiveButtonStyle {
    let dismiss: () -> Void
    func makeBody(configuration: Configuration) -> some View {
        let d = dismiss
        let c = PrimitiveButtonStyleConfiguration(role: configuration.role, label: configuration.label,
                                                  action: { configuration.trigger(); d() })
        return ButtonBehavior(configuration: c, ring: AnyShape(Capsule())) { s in
            DesktopAlertButtonLook(configuration: s)
        }
    }
}

struct DesktopAlertButtonLook: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\._alertButtonIsDefault) private var isDefault
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = ControlPalette(scheme)
        let prominent = isDefault && isEnabled
        let ink: AnyShapeStyle = prominent ? AnyShapeStyle(Color.white)
            : configuration.role == .destructive ? AnyShapeStyle(Color.red) : AnyShapeStyle(Color.primary)
        configuration.label
            .font(.system(size: 13))
            .lineLimit(1)
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if prominent {
                    Capsule().fill(.tint)
                } else {
                    Capsule().fill(palette.fill)
                }
            }
            .overlay {
                if configuration.isPressed { Capsule().fill(Color.black.opacity(0.15)) }
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

private enum AlertIconKey: EnvironmentKey { static let defaultValue: AnyView? = nil }
private enum AlertButtonIsDefaultKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The icon desktop alerts show (`_alertIcon(_:)`).
    package var _alertIcon: AnyView? {
        get { self[AlertIconKey.self] }
        set { self[AlertIconKey.self] = newValue }
    }

    /// The button is its alert's default button (drawn in the accent).
    var _alertButtonIsDefault: Bool {
        get { self[AlertButtonIsDefaultKey.self] }
        set { self[AlertButtonIsDefaultKey.self] = newValue }
    }
}

extension View {
    /// OpenViews: the icon that alerts presented from this view show on a
    /// desktop host (the app's icon, as macOS alerts show it; OpenViews has
    /// no app icon of its own). Set it at the root of a window's content.
    public func _alertIcon<V: View>(_ icon: V) -> some View {
        environment(\._alertIcon, AnyView(icon))
    }
}
