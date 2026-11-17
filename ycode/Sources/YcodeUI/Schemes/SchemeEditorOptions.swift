import AppKit
import YcodeWorkspace

/// How a scheme editor control maps to one attribute of an action element
/// (parity inventory P-109; `specs/ide/schemes.md` §Options).
public struct SchemeOptionBinding: Sendable {
    public enum Kind: Sendable {
        /// A checkbox: `on` / `off` are the values written (nil removes the
        /// attribute); an absent attribute reads as `defaultOn`.
        case flag(on: String?, off: String?, defaultOn: Bool)
        /// A pop-up or radio group: titles and the value each writes (nil
        /// removes the attribute; an absent attribute selects that item).
        case choice([Choice])
    }

    public struct Choice: Sendable, Equatable {
        public var title: String
        public var value: String?
        public init(_ title: String, _ value: String?) { self.title = title; self.value = value }
    }

    public var attribute: String
    public var kind: Kind

    public init(_ attribute: String, _ kind: Kind) {
        self.attribute = attribute
        self.kind = kind
    }

    /// The checkbox state the scheme has.
    public func isOn(in scheme: Scheme, element: String) -> Bool {
        guard case .flag(let on, let off, let defaultOn) = kind else { return false }
        guard let v = scheme.attribute(attribute, of: element) else { return defaultOn }
        if let on { return v == on }
        return v != off
    }

    /// The selected choice's index.
    public func selectedIndex(in scheme: Scheme, element: String) -> Int {
        guard case .choice(let items) = kind else { return 0 }
        let v = scheme.attribute(attribute, of: element)
        return items.firstIndex { $0.value == v } ?? items.firstIndex { $0.value == nil } ?? 0
    }

    /// Writes a checkbox state.
    public func set(_ on: Bool, in scheme: inout Scheme, element: String) {
        guard case .flag(let onValue, let offValue, _) = kind else { return }
        scheme.setAttribute(attribute, on ? onValue : offValue, of: element)
    }

    /// Writes a choice.
    public func choose(_ index: Int, in scheme: inout Scheme, element: String) {
        guard case .choice(let items) = kind, items.indices.contains(index) else { return }
        scheme.setAttribute(attribute, items[index].value, of: element)
    }
}

extension SchemeOptionBinding {
    /// Checkbox titles of Run ▸ Options and Run ▸ Diagnostics that write an
    /// attribute of the launch action (sources in schemes.md §Options).
    public static let checkboxes: [String: SchemeOptionBinding] = [
        "Allow Location Simulation": .init("allowLocationSimulation", .flag(on: "YES", off: "NO", defaultOn: true)),
        "Launch app without state restoration": .init("ignoresPersistentStateOnLaunch", .flag(on: "YES", off: "NO", defaultOn: false)),
        "Allow debugging when browsing versions": .init("debugDocumentVersioning", .flag(on: "YES", off: "NO", defaultOn: true)),
        "Show non-localized strings": .init("showNonLocalizedStrings", .flag(on: "YES", off: nil, defaultOn: false)),
        "Main Thread Checker": .init("disableMainThreadChecker", .flag(on: nil, off: "YES", defaultOn: true)),
        "Thread Performance Checker": .init("disablePerformanceAntipatternChecker", .flag(on: nil, off: "YES", defaultOn: true)),
        "API Validation": .init("enableGPUValidationMode", .flag(on: nil, off: "1", defaultOn: true)),
        "Shader Validation": .init("enableGPUShaderValidationMode", .flag(on: "2", off: nil, defaultOn: false)),
        "Metal Performance HUD": .init("showGraphicsOverview", .flag(on: "Yes", off: nil, defaultOn: false)),
        "Log Graphics Overview": .init("logGraphicsOverview", .flag(on: "Yes", off: nil, defaultOn: false)),
    ]

    /// Pop-up rows of Run ▸ Options that write an attribute.
    public static let popUps: [String: SchemeOptionBinding] = [
        "GPU Frame Capture": .init("enableGPUFrameCaptureMode", .choice([.init("Automatically", nil), .init("Metal", "1"), .init("Disabled", "3")])),
        "App Language": .init("language", .choice([.init("System Language", nil), .init("English", "en"), .init("French", "fr"),
                                                   .init("German", "de"), .init("Japanese", "ja"), .init("Spanish", "es"),
                                                   .init("Chinese, Simplified", "zh-Hans")])),
        "App Region": .init("region", .choice([.init("System Region", nil), .init("United States", "US"), .init("United Kingdom", "GB"),
                                               .init("France", "FR"), .init("Germany", "DE"), .init("Japan", "JP"), .init("Spain", "ES"),
                                               .init("China mainland", "CN")])),
    ]

    /// Build ▸ Build Order (`parallelizeBuildables`).
    public static let buildOrder = SchemeOptionBinding("parallelizeBuildables",
                                                      .choice([.init("Dependency Order", "YES"), .init("Manual Order (Deprecated)", "NO")]))
    /// Build ▸ Override Architectures (`buildArchitectures`).
    public static let overrideArchitectures = SchemeOptionBinding("buildArchitectures",
                                                                 .choice([.init("Use Target Settings", nil), .init("Match Run Destination", "Automatic"),
                                                                          .init("Universal", "All")]))
    /// Run / Test ▸ Debug Process As (`debugAsWhichUser`).
    public static func debugProcessAs(user: String) -> SchemeOptionBinding {
        .init("debugAsWhichUser", .choice([.init("Me (\(user))", nil), .init("root", "root")]))
    }
    /// Run ▸ Info ▸ Launch (`launchStyle`).
    public static let launchStyle = SchemeOptionBinding("launchStyle",
                                                       .choice([.init("Automatically", "0"), .init("Wait for the executable to be launched", "1")]))
    /// Archive ▸ Reveal Archive in Organizer.
    public static let revealArchive = SchemeOptionBinding("revealArchiveInOrganizer", .flag(on: "YES", off: "NO", defaultOn: true))
}

/// A control that reports its own changes to a closure (the scheme
/// editor's bound rows).
@MainActor
final class SchemeOptionButton: NSButton {
    var onChange: ((NSButton) -> Void)?

    static func checkbox(_ title: String, on: Bool, _ change: @escaping (Bool) -> Void) -> SchemeOptionButton {
        let b = SchemeOptionButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        b.target = b
        b.action = #selector(fire)
        b.onChange = { change($0.state == .on) }
        return b
    }

    static func radio(_ title: String, on: Bool, _ choose: @escaping () -> Void) -> SchemeOptionButton {
        let b = SchemeOptionButton(radioButtonWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        b.target = b
        b.action = #selector(fire)
        b.onChange = { _ in choose() }
        return b
    }

    @objc func fire() { onChange?(self) }
}

@MainActor
final class SchemeOptionPopUp: NSPopUpButton {
    var onChoose: ((Int) -> Void)?

    convenience init(_ titles: [String], selected: Int, _ choose: @escaping (Int) -> Void) {
        self.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        selectItem(at: selected)
        target = self
        action = #selector(fire)
        onChoose = choose
    }

    @objc func fire() { onChoose?(indexOfSelectedItem) }
}

@MainActor
final class SchemeOptionField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?

    convenience init(_ value: String, placeholder: String, _ commit: @escaping (String) -> Void) {
        self.init(string: value)
        placeholderString = placeholder
        onCommit = commit
        delegate = self
    }

    func controlTextDidEndEditing(_ obj: Notification) { onCommit?(stringValue) }
}
