import Foundation

/// The options step of New Project ("Choose options for your new
/// project:", `specs/ide/templates.md` § "Options step"): a template's
/// fields, their order, defaults and forced values, the values derived
/// from other fields (the bundle identifier), the requirements that
/// enable a field or allow one of its values, and the checks that keep
/// Next disabled. Both IDEs and `ycode new` drive the same model.

/// A requirement: another option's value is one of `values` (or, negated,
/// none of them).
public struct TemplateCondition: Equatable, Sendable {
    public var option: String
    public var values: [String]
    public var negated: Bool

    public init(_ option: String, in values: [String], negated: Bool = false) {
        self.option = option
        self.values = values
        self.negated = negated
    }

    public static func not(_ option: String, _ value: String) -> TemplateCondition { TemplateCondition(option, in: [value], negated: true) }
    public static func `is`(_ option: String, _ value: String) -> TemplateCondition { TemplateCondition(option, in: [value]) }
}

/// One value of a pop-up: what is stored, what is shown, and when it is
/// allowed (rule 4).
public struct TemplateChoice: Equatable, Sendable, ExpressibleByStringLiteral {
    public var value: String
    public var title: String
    public var requires: [TemplateCondition]
    /// Why Ycode does not generate this value yet (drawn disabled).
    public var unavailableReason: String?

    public init(_ value: String, title: String? = nil, requires: [TemplateCondition] = [], unavailable: String? = nil) {
        self.value = value
        self.title = title ?? value
        self.requires = requires
        unavailableReason = unavailable
    }

    public init(stringLiteral value: String) { self.init(value) }
}

/// One row of the options step.
public struct TemplateOptionField: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A text field (`placeholder` shown while empty).
        case text
        /// A pop-up of these values.
        case popUp([TemplateChoice])
        /// A checkbox titled with the label; its value is "true" or "false".
        case checkbox
        /// Grey text computed from other options (the bundle identifier).
        case derived
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var defaultValue: String
    public var placeholder: String
    /// Rule 2: shown by ascending key (none = 0; Product Name −2).
    public var sortKey: Int
    /// Rule 3: enabled only while every requirement holds.
    public var requirements: [TemplateCondition]
    /// Rule 1: a forced value hides the option.
    public var forcedValue: String?
    /// Rule 1: an option with no label is hidden.
    public var isHidden: Bool
    /// Rule 5: must be non-empty.
    public var isRequired: Bool
    /// § Persistence: stored for the next New Project.
    public var isPersisted: Bool

    public init(_ id: String, _ label: String, _ kind: Kind, default value: String = "", placeholder: String = "", sortKey: Int = 0,
                requires: [TemplateCondition] = [], forced: String? = nil, hidden: Bool = false, required: Bool = false,
                persisted: Bool = true) {
        self.id = id
        self.label = label
        self.kind = kind
        defaultValue = value
        self.placeholder = placeholder
        self.sortKey = sortKey
        requirements = requires
        forcedValue = forced
        isHidden = hidden
        isRequired = required
        isPersisted = persisted
    }

    public var choices: [TemplateChoice] {
        if case .popUp(let c) = kind { return c }
        return []
    }

    /// The pop-up's values.
    public var values: [String] { choices.map(\.value) }

    /// A copy with another default, forced value, sort key, choices,
    /// label or requirements.
    public func with(default d: String? = nil, forced: String? = nil, sortKey k: Int? = nil, choices: [TemplateChoice]? = nil,
                     label l: String? = nil, requires r: [TemplateCondition]? = nil) -> TemplateOptionField {
        var f = self
        if let d { f.defaultValue = d }
        if let forced { f.forcedValue = forced }
        if let k { f.sortKey = k }
        if let choices { f.kind = .popUp(choices) }
        if let l { f.label = l }
        if let r { f.requirements = r }
        return f
    }
}

/// Option identifiers (`templates.md` § "Common options").
public enum TemplateOptionID {
    public static let productName = "productName"
    public static let organizationIdentifier = "bundleIdentifierPrefix"
    public static let bundleIdentifier = "bundleIdentifier"
    public static let interface = "userInterface"
    public static let lifecycle = "appLifecycle"
    public static let language = "languageChoice"
    public static let testingSystem = "testingSystem"
    public static let storage = "storageType"
    public static let documentStorage = "storageTypeDocument"
    public static let hostInCloudKit = "hostInCloudKit"
    public static let hasDocumentation = "hasDocumentation"
    public static let gameTechnology = "gameType"
    public static let integrateGameplayKit = "integrateGK"
    public static let contentTechnology = "contentType"
    public static let iOSPlatform = "iOSPlatform"
    public static let visionOSPlatform = "visionOSPlatform"
    public static let tvOSPlatform = "tvOSPlatform"
    public static let macOSPlatform = "OSXPlatform"
    public static let initialScene = "primarySceneType"
    public static let immersiveSpaceRenderer = "secondarySceneType"
    public static let immersiveSpace = "immersiveSpaceStyle"
    public static let watchAppType = "companionAppStyle"
    public static let safariExtensionType = "safariExtensionType"
    public static let libraryFramework = "libraryFramework"
    public static let libraryType = "libraryType"
    public static let apiLevel = "apiLevel"
    public static let bundleExtension = "bundleExtension"
    public static let buildTool = "buildToolPath"
    public static let organizationName = "ORGANIZATIONNAME"
    public static let audioUnitType = "audioUnitType"
    public static let subtypeCode = "audioUnitSubtypeCode"
    public static let manufacturerCode = "audioUnitManufacturerCode"
    public static let hasUserInterface = "hasUserInterface"
    /// Not a template option: the IDE's Team pop-up (rule 8).
    public static let team = "team"
}

/// The common fields (`templates.md` § "Common options").
public enum TemplateFields {
    typealias ID = TemplateOptionID
    /// The titles of app templates' Testing System.
    public static let testingChoices = ["None", "XCTest for Unit and UI Tests", "Swift Testing with XCTest UI Tests"]

    public static let productName = TemplateOptionField(ID.productName, "Product Name", .text, sortKey: -2, required: true, persisted: false)
    /// Rule 8: right after Product Name.
    public static let team = TemplateOptionField(ID.team, "Team", .popUp(["None"]), default: "None", sortKey: -2)
    public static let organization = TemplateOptionField(ID.organizationIdentifier, "Organization Identifier", .text,
                                                         placeholder: "com.yourcompany", sortKey: -1, required: true)
    public static let bundleIdentifier = TemplateOptionField(ID.bundleIdentifier, "Bundle Identifier", .derived, sortKey: -1, persisted: false)
    public static let identity = [productName, team, organization, bundleIdentifier]

    static let swiftOnly = [TemplateCondition.is(ID.language, "Swift")]
    /// The Testing System of app templates (unit and UI tests).
    public static let testing = TemplateOptionField(ID.testingSystem, "Testing System", .popUp([
        TemplateChoice("None"), TemplateChoice("XCTest", title: "XCTest for Unit and UI Tests"),
        TemplateChoice("Swift Testing", title: "Swift Testing with XCTest UI Tests", requires: swiftOnly),
    ]), default: "None")
    /// Unit tests only (frameworks, libraries, visionOS).
    public static let unitTesting = TemplateOptionField(ID.testingSystem, "Testing System", .popUp([
        "None", "XCTest", TemplateChoice("Swift Testing", requires: swiftOnly),
    ]), default: "None")
    public static let interface = TemplateOptionField(ID.interface, "Interface", .popUp(["SwiftUI", "Storyboard"]), default: "SwiftUI")
    /// The hidden lifecycle: SwiftUI with the SwiftUI interface, else Cocoa.
    public static let lifecycle = TemplateOptionField(ID.lifecycle, "", .popUp([
        TemplateChoice("SwiftUI", requires: [.is(ID.interface, "SwiftUI")]),
        TemplateChoice("Cocoa", requires: [.not(ID.interface, "SwiftUI")]),
    ]), default: "SwiftUI", hidden: true)
    /// Objective-C only with the Cocoa lifecycle (apps).
    public static let appLanguage = TemplateOptionField(ID.language, "Language", .popUp([
        "Swift", TemplateChoice("Objective-C", requires: [.is(ID.lifecycle, "Cocoa")]),
    ]), default: "Swift")
    public static let language = TemplateOptionField(ID.language, "Language", .popUp(["Swift", "Objective-C"]), default: "Swift")
    public static let swiftLanguage = language.with(forced: "Swift")
    public static let storage = TemplateOptionField(ID.storage, "Storage", .popUp([
        "None", TemplateChoice("SwiftData", requires: [.is(ID.lifecycle, "SwiftUI")]), "Core Data",
    ]), default: "None")
    public static let cloudKit = TemplateOptionField(ID.hostInCloudKit, "Host in CloudKit", .checkbox, default: "false",
                                                     requires: [TemplateCondition(ID.storage, in: ["SwiftData", "Core Data"])])
    public static let documentation = TemplateOptionField(ID.hasDocumentation, "Include Documentation", .checkbox, default: "true")
}

/// A template's options while the step is shown.
public struct TemplateOptionsForm: Equatable, Sendable {
    public let fields: [TemplateOptionField]
    /// The stored values (what the user chose); `value(_:)` applies the rules.
    public private(set) var values: [String: String]

    /// Starts each option at `initial`'s value when allowed (persisted
    /// values, rule 7), else at its default.
    public init(fields: [TemplateOptionField], values initial: [String: String] = [:]) {
        self.fields = fields
        var v: [String: String] = [:]
        for f in fields where f.kind != .derived { v[f.id] = f.defaultValue }
        values = v
        // Two passes, so values that depend on others settle.
        for _ in 0..<2 { for (k, value) in initial.sorted(by: { $0.key < $1.key }) { set(k, value) } }
    }

    public func field(_ id: String) -> TemplateOptionField? { fields.first { $0.id == id } }

    func holds(_ c: TemplateCondition, depth: Int) -> Bool {
        // A requirement on an option the template does not have holds.
        guard field(c.option) != nil else { return true }
        let hit = c.values.contains(effectiveValue(c.option, depth: depth + 1))
        return c.negated ? !hit : hit
    }

    /// Rule 3.
    public func isEnabled(_ id: String) -> Bool {
        guard let f = field(id), f.kind != .derived, f.forcedValue == nil else { return false }
        return f.requirements.allSatisfy { holds($0, depth: 0) }
    }

    /// Rule 4: whether a pop-up value is available now.
    public func isAllowed(_ id: String, _ value: String) -> Bool { isAllowed(id, value, depth: 0) }
    func isAllowed(_ id: String, _ value: String, depth: Int) -> Bool {
        guard let f = field(id), case .popUp(let choices) = f.kind else { return true }
        guard let c = choices.first(where: { $0.value == value }), c.unavailableReason == nil else { return false }
        return depth > 8 || c.requires.allSatisfy { holds($0, depth: depth) }
    }

    func firstAllowed(_ f: TemplateOptionField, depth: Int) -> String {
        switch f.kind {
        case .checkbox: return "false"
        case .popUp(let choices): return choices.first { isAllowed(f.id, $0.value, depth: depth) }?.value ?? choices.first?.value ?? ""
        default: return f.defaultValue
        }
    }

    /// The value an option has under the rules.
    public func value(_ id: String) -> String { effectiveValue(id, depth: 0) }

    func effectiveValue(_ id: String, depth: Int) -> String {
        if id == TemplateOptionID.bundleIdentifier { return bundleIdentifier }
        guard let f = field(id) else { return values[id] ?? "" }
        if let forced = f.forcedValue { return forced }
        let stored = values[id] ?? f.defaultValue
        if depth > 8 { return stored }
        if f.requirements.contains(where: { !holds($0, depth: depth) }) {
            // Disabled: the first allowed value ("None" where it exists).
            return f.values.contains("None") ? "None" : firstAllowed(f, depth: depth)
        }
        if case .popUp = f.kind, !isAllowed(id, stored, depth: depth) { return firstAllowed(f, depth: depth) }
        return stored
    }

    public func bool(_ id: String) -> Bool { ["true", "yes", "1"].contains(value(id).lowercased()) }

    /// Sets an option. A pop-up takes one of its values or titles
    /// (case-insensitively); a checkbox takes true/false, YES/NO, 1/0.
    /// Derived options cannot be set. Values for options the template
    /// does not offer are kept unchecked (`ycode new --option`).
    public mutating func set(_ id: String, _ raw: String) {
        guard let f = field(id) else { values[id] = raw; return }
        switch f.kind {
        case .derived: return
        case .text: values[id] = raw
        case .popUp(let choices):
            guard let c = choices.first(where: { $0.value == raw || $0.title == raw })
                ?? choices.first(where: { $0.value.caseInsensitiveCompare(raw) == .orderedSame || $0.title.caseInsensitiveCompare(raw) == .orderedSame })
            else { return }
            values[id] = c.value
        case .checkbox:
            values[id] = ["yes", "true", "1", "on"].contains(raw.lowercased()) ? "true" : "false"
        }
        // A value that is no longer allowed moves to the first allowed one.
        for g in fields where g.id != id {
            if case .popUp = g.kind, let v = values[g.id], !isAllowed(g.id, v) { values[g.id] = firstAllowed(g, depth: 0) }
        }
    }

    /// The options shown, in order (rules 1 and 2).
    public var visibleFields: [TemplateOptionField] {
        fields.enumerated().filter { !$0.element.isHidden && $0.element.forcedValue == nil && !$0.element.label.isEmpty }
            .sorted { ($0.element.sortKey, $0.offset) < ($1.element.sortKey, $1.offset) }.map(\.element)
    }

    public func isVisible(_ id: String) -> Bool { visibleFields.contains { $0.id == id } }

    public var productName: String { value(TemplateOptionID.productName).trimmingCharacters(in: .whitespaces) }
    public var organizationIdentifier: String { value(TemplateOptionID.organizationIdentifier).trimmingCharacters(in: .whitespaces) }

    /// `B` (§ Notation): the organization with forbidden characters
    /// removed, ".", and the name with every character other than A–Z,
    /// a–z, 0–9, "-" and "." replaced by "-". Empty parts read
    /// "com.yourcompany" and "ProductName" (rule 6).
    public var bundleIdentifier: String {
        TemplateOptionsForm.bundleIdentifier(organization: organizationIdentifier, name: productName)
    }

    public static func bundleIdentifier(organization: String, name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        let id = n.isEmpty ? "ProductName" : rfc1034(n)
        let org = String(organization.filter(isBundleCharacter))
        return "\(org.isEmpty ? "com.yourcompany" : org).\(id)"
    }

    static func isBundleCharacter(_ c: Character) -> Bool { (c.isASCII && (c.isLetter || c.isNumber)) || c == "-" || c == "." }
    static func rfc1034(_ s: String) -> String { String(s.map { isBundleCharacter($0) ? $0 : "-" }) }

    public var isBundleIdentifierPlaceholder: Bool { productName.isEmpty }

    /// Why Next is disabled; empty when it is enabled (rule 5).
    public var issues: [String] {
        var out: [String] = []
        for f in fields where f.isRequired && f.kind == .text && f.forcedValue == nil
            && value(f.id).trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(f.id == TemplateOptionID.productName ? "Enter a product name." : "Enter a value for \(f.label).")
        }
        if field(TemplateOptionID.productName) != nil, productName.contains("/") || productName.contains(":") || productName.hasPrefix(".") {
            out.append("A product name cannot contain “/” or “:” or start with “.”.")
        }
        for (id, name) in [(TemplateOptionID.subtypeCode, "subtype"), (TemplateOptionID.manufacturerCode, "manufacturer")] where field(id) != nil {
            let v = value(id)
            if !v.isEmpty, v.utf8.count != 4 { out.append("The \(name) code must be exactly four characters.") }
            if id == TemplateOptionID.manufacturerCode, !v.isEmpty, !v.contains(where: \.isUppercase) {
                out.append("The manufacturer code needs at least one upper-case letter.")
            }
        }
        return out
    }

    public var isNextEnabled: Bool { issues.isEmpty }

    /// The values the next New Project starts from (§ Persistence).
    public var persistedValues: [String: String] {
        var out: [String: String] = [:]
        for f in fields where f.isPersisted && f.kind != .derived && f.forcedValue == nil && !f.isHidden && f.id != TemplateOptionID.team {
            out[f.id] = value(f.id)
        }
        return out
    }
}

extension String {
    /// `T` (§ Notation): the C-identifier form of a product name.
    var templateTypeName: String { templateModuleName }

    /// Characters other than letters, digits and "_" become "_"; a
    /// leading digit gets a "_" in front.
    var templateModuleName: String {
        var s = String(map { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "_" ? $0 : "_" })
        if s.first?.isNumber ?? true { s = "_" + s }
        return s
    }

    /// The text as a Swift (or C) string literal's contents.
    var swiftLiteral: String {
        replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The text as XML attribute contents.
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
