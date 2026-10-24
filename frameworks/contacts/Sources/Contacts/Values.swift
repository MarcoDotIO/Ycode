// Value classes and labeled values (interface.md §1, §2.3–§2.4).

import Foundation

// MARK: - CNPhoneNumber

public final class CNPhoneNumber: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    public let stringValue: String

    public init(stringValue: String) {
        self.stringValue = stringValue
    }

    @available(*, deprecated, message: "Use init(stringValue:)")
    public override convenience init() { self.init(stringValue: "") }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {
        stringValue = (coder.decodeObject(forKey: "stringValue") as? String) ?? ""
    }
    public func encode(with coder: NSCoder) { coder.encode(stringValue, forKey: "stringValue") }

    public func copy(with zone: NSZone? = nil) -> Any { self }

    public override func isEqual(_ object: Any?) -> Bool {
        (object as? CNPhoneNumber)?.stringValue == stringValue
    }
    public override var hash: Int { stringValue.hashValue }
    public override var description: String { "<CNPhoneNumber: stringValue=\(stringValue)>" }

    /// Digits of the number with the country calling code (design.md §4):
    /// "+…" numbers keep their digits; national numbers get `callingCode`
    /// in front (after dropping one trunk "0"), except NANP numbers that
    /// already start with the "1".
    func normalizedDigits(callingCode: String) -> String {
        let trimmed = stringValue.trimmingCharacters(in: .whitespaces)
        let digits = String(trimmed.filter { $0.isASCII && $0.isNumber })
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("00") {
            return trimmed.hasPrefix("00") ? String(digits.dropFirst(2)) : digits
        }
        if callingCode == "1" {
            return digits.count == 11 && digits.hasPrefix("1") ? digits : "1" + digits
        }
        let national = digits.hasPrefix("0") ? String(digits.dropFirst()) : digits
        return callingCode + national
    }
}

// MARK: - CNPostalAddress

public class CNPostalAddress: NSObject, NSCopying, NSMutableCopying, NSSecureCoding, @unchecked Sendable {
    var _street = "", _subLocality = "", _city = "", _subAdministrativeArea = ""
    var _state = "", _postalCode = "", _country = "", _isoCountryCode = ""

    public var street: String { _street }
    public var subLocality: String { _subLocality }
    public var city: String { _city }
    public var subAdministrativeArea: String { _subAdministrativeArea }
    public var state: String { _state }
    public var postalCode: String { _postalCode }
    public var country: String { _country }
    public var isoCountryCode: String { _isoCountryCode }

    override init() {}

    init(copying a: CNPostalAddress) {
        _street = a._street; _subLocality = a._subLocality; _city = a._city
        _subAdministrativeArea = a._subAdministrativeArea; _state = a._state
        _postalCode = a._postalCode; _country = a._country; _isoCountryCode = a._isoCountryCode
    }

    static let fieldKeys = [
        CNPostalAddressStreetKey, CNPostalAddressSubLocalityKey, CNPostalAddressCityKey,
        CNPostalAddressSubAdministrativeAreaKey, CNPostalAddressStateKey, CNPostalAddressPostalCodeKey,
        CNPostalAddressCountryKey, CNPostalAddressISOCountryCodeKey,
    ]

    func field(_ key: String) -> String {
        switch key {
        case CNPostalAddressStreetKey: return _street
        case CNPostalAddressSubLocalityKey: return _subLocality
        case CNPostalAddressCityKey: return _city
        case CNPostalAddressSubAdministrativeAreaKey: return _subAdministrativeArea
        case CNPostalAddressStateKey: return _state
        case CNPostalAddressPostalCodeKey: return _postalCode
        case CNPostalAddressCountryKey: return _country
        case CNPostalAddressISOCountryCodeKey: return _isoCountryCode
        default: return ""
        }
    }

    func setField(_ key: String, _ value: String) {
        switch key {
        case CNPostalAddressStreetKey: _street = value
        case CNPostalAddressSubLocalityKey: _subLocality = value
        case CNPostalAddressCityKey: _city = value
        case CNPostalAddressSubAdministrativeAreaKey: _subAdministrativeArea = value
        case CNPostalAddressStateKey: _state = value
        case CNPostalAddressPostalCodeKey: _postalCode = value
        case CNPostalAddressCountryKey: _country = value
        case CNPostalAddressISOCountryCodeKey: _isoCountryCode = value
        default: break
        }
    }

    /// Field names in English (interface.md §2.4).
    public class func localizedString(forKey key: String) -> String {
        switch key {
        case CNPostalAddressStreetKey: return "Street"
        case CNPostalAddressSubLocalityKey: return "District"
        case CNPostalAddressCityKey: return "City"
        case CNPostalAddressSubAdministrativeAreaKey: return "County"
        case CNPostalAddressStateKey: return "State"
        case CNPostalAddressPostalCodeKey: return "ZIP"
        case CNPostalAddressCountryKey: return "Country"
        case CNPostalAddressISOCountryCodeKey: return "Country code"
        default: return ""
        }
    }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {
        super.init()
        for k in CNPostalAddress.fieldKeys { setField(k, (coder.decodeObject(forKey: k) as? String) ?? "") }
    }
    public func encode(with coder: NSCoder) {
        for k in CNPostalAddress.fieldKeys { coder.encode(field(k), forKey: k) }
    }

    public func copy(with zone: NSZone? = nil) -> Any {
        type(of: self) == CNPostalAddress.self ? self : CNPostalAddress(copying: self)
    }

    public func mutableCopy(with zone: NSZone? = nil) -> Any { CNMutablePostalAddress(copying: self) }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNPostalAddress else { return false }
        return CNPostalAddress.fieldKeys.allSatisfy { field($0) == o.field($0) }
    }
    public override var hash: Int { _street.hashValue ^ _city.hashValue ^ _postalCode.hashValue }
    public override var description: String {
        "<\(type(of: self)): street=\(_street), city=\(_city), state=\(_state), postalCode=\(_postalCode), country=\(_country), countryCode=\(_isoCountryCode)>"
    }
}

public final class CNMutablePostalAddress: CNPostalAddress, @unchecked Sendable {
    public override init() { super.init() }
    override init(copying a: CNPostalAddress) { super.init(copying: a) }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    public override var street: String { get { _street } set { _street = newValue } }
    public override var subLocality: String { get { _subLocality } set { _subLocality = newValue } }
    public override var city: String { get { _city } set { _city = newValue } }
    public override var subAdministrativeArea: String { get { _subAdministrativeArea } set { _subAdministrativeArea = newValue } }
    public override var state: String { get { _state } set { _state = newValue } }
    public override var postalCode: String { get { _postalCode } set { _postalCode = newValue } }
    public override var country: String { get { _country } set { _country = newValue } }
    public override var isoCountryCode: String { get { _isoCountryCode } set { _isoCountryCode = newValue } }
}

// MARK: - CNContactRelation

public final class CNContactRelation: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    public let name: String

    public init(name: String) { self.name = name }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) { name = (coder.decodeObject(forKey: "name") as? String) ?? "" }
    public func encode(with coder: NSCoder) { coder.encode(name, forKey: "name") }
    public func copy(with zone: NSZone? = nil) -> Any { self }

    public override func isEqual(_ object: Any?) -> Bool { (object as? CNContactRelation)?.name == name }
    public override var hash: Int { name.hashValue }
    public override var description: String { "<CNContactRelation: name=\(name)>" }
}

// MARK: - CNSocialProfile

public final class CNSocialProfile: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    public let urlString: String
    public let username: String
    public let userIdentifier: String
    public let service: String

    public init(urlString: String?, username: String?, userIdentifier: String?, service: String?) {
        self.urlString = urlString ?? ""
        self.username = username ?? ""
        self.userIdentifier = userIdentifier ?? ""
        self.service = service ?? ""
    }

    public class func localizedString(forKey key: String) -> String {
        switch key {
        case CNSocialProfileURLStringKey: return "URL"
        case CNSocialProfileUsernameKey: return "Username"
        case CNSocialProfileUserIdentifierKey: return "User ID"
        case CNSocialProfileServiceKey: return "Service"
        default: return ""
        }
    }

    /// Services localize to themselves (interface.md §2.4).
    public class func localizedString(forService service: String) -> String { service }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {
        urlString = (coder.decodeObject(forKey: "urlString") as? String) ?? ""
        username = (coder.decodeObject(forKey: "username") as? String) ?? ""
        userIdentifier = (coder.decodeObject(forKey: "userIdentifier") as? String) ?? ""
        service = (coder.decodeObject(forKey: "service") as? String) ?? ""
    }
    public func encode(with coder: NSCoder) {
        coder.encode(urlString, forKey: "urlString")
        coder.encode(username, forKey: "username")
        coder.encode(userIdentifier, forKey: "userIdentifier")
        coder.encode(service, forKey: "service")
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNSocialProfile else { return false }
        return o.urlString == urlString && o.username == username && o.userIdentifier == userIdentifier && o.service == service
    }
    public override var hash: Int { urlString.hashValue ^ username.hashValue ^ service.hashValue }
    public override var description: String {
        "<CNSocialProfile: urlString=\(urlString), username=\(username), userIdentifier=\(userIdentifier), service=\(service)>"
    }
}

// MARK: - CNInstantMessageAddress

public final class CNInstantMessageAddress: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    public let username: String
    public let service: String

    public init(username: String, service: String) {
        self.username = username
        self.service = service
    }

    public class func localizedString(forKey key: String) -> String {
        switch key {
        case CNInstantMessageAddressUsernameKey: return "Username"
        case CNInstantMessageAddressServiceKey: return "Service"
        default: return ""
        }
    }

    public class func localizedString(forService service: String) -> String { service }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {
        username = (coder.decodeObject(forKey: "username") as? String) ?? ""
        service = (coder.decodeObject(forKey: "service") as? String) ?? ""
    }
    public func encode(with coder: NSCoder) {
        coder.encode(username, forKey: "username")
        coder.encode(service, forKey: "service")
    }
    public func copy(with zone: NSZone? = nil) -> Any { self }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNInstantMessageAddress else { return false }
        return o.username == username && o.service == service
    }
    public override var hash: Int { username.hashValue ^ service.hashValue }
    public override var description: String { "<CNInstantMessageAddress: username=\(username), service=\(service)>" }
}

// MARK: - CNLabeledValue

/// A (label, value) pair with its own stable identifier (interface.md §2.3).
public final class CNLabeledValue<ValueType: NSCopying & NSSecureCoding>: NSObject, NSCopying, NSSecureCoding, @unchecked Sendable {
    public let identifier: String
    public let label: String?
    public let value: ValueType

    public init(label: String?, value: ValueType) {
        identifier = UUID().uuidString
        self.label = label
        self.value = (value.copy(with: nil) as? ValueType) ?? value
    }

    init(identifier: String, label: String?, value: ValueType) {
        self.identifier = identifier
        self.label = label
        self.value = (value.copy(with: nil) as? ValueType) ?? value
    }

    /// A copy with another label; the identifier is kept.
    public func settingLabel(_ label: String?) -> CNLabeledValue<ValueType> {
        CNLabeledValue(identifier: identifier, label: label, value: value)
    }

    /// A copy with another value; the identifier is kept.
    public func settingValue(_ value: ValueType) -> CNLabeledValue<ValueType> {
        CNLabeledValue(identifier: identifier, label: label, value: value)
    }

    public func settingLabel(_ label: String?, value: ValueType) -> CNLabeledValue<ValueType> {
        CNLabeledValue(identifier: identifier, label: label, value: value)
    }

    /// English for predefined labels; custom labels unchanged.
    public class func localizedString(forLabel label: String) -> String {
        Localization.label(label)
    }

    public static var supportsSecureCoding: Bool { true }
    public required init?(coder: NSCoder) {
        guard let v = coder.decodeObject(forKey: "value") as? ValueType else { return nil }
        identifier = (coder.decodeObject(forKey: "identifier") as? String) ?? UUID().uuidString
        label = coder.decodeObject(forKey: "label") as? String
        value = v
    }
    public func encode(with coder: NSCoder) {
        coder.encode(identifier, forKey: "identifier")
        coder.encode(label, forKey: "label")
        coder.encode(value, forKey: "value")
    }

    public func copy(with zone: NSZone? = nil) -> Any { self }

    /// Equal when identifier, label and value are equal (a relabeled value
    /// is therefore not equal to the original, interface.md §2.3).
    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNLabeledValue<ValueType> else { return false }
        return o.identifier == identifier && o.label == label && ((o.value as? NSObject)?.isEqual(value as? NSObject) ?? false)
    }
    public override var hash: Int { identifier.hashValue }
    public override var description: String {
        "<CNLabeledValue: identifier=\(identifier), label=\(label ?? "(nil)"), value=\(value)>"
    }
}

// MARK: - CNContactProperty

/// One property of a contact (what the picker returns for a property selection).
public final class CNContactProperty: NSObject, @unchecked Sendable {
    public let contact: CNContact
    public let key: String
    public let value: Any?
    public let identifier: String?
    public let label: String?

    init(contact: CNContact, key: String, value: Any?, identifier: String?, label: String?) {
        self.contact = contact
        self.key = key
        self.value = value
        self.identifier = identifier
        self.label = label
    }

    public override var description: String {
        "<CNContactProperty: contact=\(contact.identifier), key=\(key), identifier=\(identifier ?? "(nil)"), label=\(label ?? "(nil)")>"
    }
}

// MARK: - CNContactsUserDefaults

public final class CNContactsUserDefaults: NSObject, @unchecked Sendable {
    private static let instance = CNContactsUserDefaults()

    public class func shared() -> CNContactsUserDefaults { instance }

    /// Family name (3) as on a fresh device (interface.md §1).
    public var sortOrder: CNContactSortOrder { .familyName }
    /// The store configuration's country code ("us" by default).
    public var countryCode: String { CNContactStore.ycodeDefaultConfiguration.countryCode }
}
