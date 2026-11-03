// The device buttons as HID usage pairs, per device family: the one table
// that turns a display-stream button (§5.3), or a named watch button of the
// control socket, into the consumer-page (or vendor) usage pair that the
// guest's HID bundle dispatches from its buttons service (hid-input.md §5.5;
// watchos.md §5.2). ycode-simd's input bridge and its `button` command use
// it; viewers pick the DisplayButton and read `buttons(for:)` from the hello.

/// A HID usage page and usage.
public struct HIDUsagePair: Hashable, Sendable, CustomStringConvertible {
    public var page: UInt32
    public var usage: UInt32

    public init(page: UInt32, usage: UInt32) { (self.page, self.usage) = (page, usage) }

    public var description: String { String(format: "0x%X/0x%X", page, usage) }
}

public enum DeviceButtonTable {
    /// The input family of a device: a watch has no volume buttons and
    /// (on the Ultra types) an Action button of its own usage.
    public enum Family: Equatable, Sendable {
        /// iPhone, iPad and the other non-watch families.
        case phone
        /// A watch; `actionButton` on the Ultra types (watchos.md §5.2).
        case watch(actionButton: Bool)
    }

    /// Crown press (watchos.md §5.2: on the face the app grid, in an app the
    /// face; held, Siri). Also the Home button of the other families.
    public static let home = HIDUsagePair(page: 0x0C, usage: 0x40)
    /// Sleep/Wake on a phone; on a watch the screen toggle (off / on), not a
    /// watch hardware button (watchos.md §5.2).
    public static let lock = HIDUsagePair(page: 0x0C, usage: 0x30)
    /// The side button (watchos.md §5.2: Control Center; held, the power-off
    /// sheet); on a phone the Action button's provisional usage.
    public static let side = HIDUsagePair(page: 0x0C, usage: 0x95)
    public static let volumeUp = HIDUsagePair(page: 0x0C, usage: 0xE9)
    public static let volumeDown = HIDUsagePair(page: 0x0C, usage: 0xEA)
    /// The Ultra watches' Action button (watchos.md §5.2), a vendor page.
    public static let watchAction = HIDUsagePair(page: 0xFF01, usage: 0x200)

    /// The usage pair a display-stream button sends on a device of this
    /// family, or nil when the device has no such button (the input is
    /// dropped).
    public static func usage(of button: DisplayButton, for family: Family) -> HIDUsagePair? {
        switch family {
        case .phone:
            switch button {
            case .home: home
            case .lock: lock
            case .side, .action: side
            case .volumeUp: volumeUp
            case .volumeDown: volumeDown
            }
        case .watch(let actionButton):
            switch button {
            case .home: home
            case .lock: lock
            case .side: side
            case .action: actionButton ? watchAction : nil
            case .volumeUp, .volumeDown: nil
            }
        }
    }

    /// The buttons a server of this family lists in its hello.
    public static func buttons(for family: Family) -> [DisplayButton] {
        DisplayButton.allCases.filter { usage(of: $0, for: family) != nil }
    }

    /// The pairs a watch's HID bundle accepts from the host (watchos.md
    /// §5.2: unknown sources are ignored, never dispatched).
    public static func watchAccepts(_ pair: HIDUsagePair, actionButton: Bool) -> Bool {
        pair == home || pair == side || pair == lock || (actionButton && pair == watchAction)
    }

    /// The watch's buttons by name, for the control socket's `button` command.
    public enum WatchButton: String, CaseIterable, Sendable {
        /// The Digital Crown pressed.
        case crown
        /// The side button.
        case side
        /// The Action button (Ultra types only).
        case action
        /// Lock / wake the screen (the screen toggle).
        case screen

        public var displayButton: DisplayButton {
            switch self {
            case .crown: .home
            case .side: .side
            case .action: .action
            case .screen: .lock
            }
        }

        /// The name or one of its aliases.
        public init?(named name: String) {
            switch name.lowercased() {
            case "crown", "home", "crown-press": self = .crown
            case "side", "side-button": self = .side
            case "action", "action-button": self = .action
            case "screen", "lock", "wake": self = .screen
            default: return nil
            }
        }
    }
}
