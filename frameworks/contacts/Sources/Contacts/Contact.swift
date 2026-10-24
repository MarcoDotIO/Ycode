// CNContact and CNMutableContact (interface.md §2): immutable snapshots that
// carry the set of fetched keys; reading or setting an unfetched property
// raises CNPropertyNotFetchedException (errors.md §3).

import Foundation

/// Every property of a contact (internal storage).
struct ContactData: Equatable {
    var contactType: CNContactType = .person
    var namePrefix = ""
    var givenName = ""
    var middleName = ""
    var familyName = ""
    var previousFamilyName = ""
    var nameSuffix = ""
    var nickname = ""
    var organizationName = ""
    var departmentName = ""
    var jobTitle = ""
    var phoneticGivenName = ""
    var phoneticMiddleName = ""
    var phoneticFamilyName = ""
    var phoneticOrganizationName = ""
    var note = ""
    var imageData: Data?
    var thumbnailImageData: Data?
    var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] = []
    var emailAddresses: [CNLabeledValue<NSString>] = []
    var postalAddresses: [CNLabeledValue<CNPostalAddress>] = []
    var urlAddresses: [CNLabeledValue<NSString>] = []
    var contactRelations: [CNLabeledValue<CNContactRelation>] = []
    var socialProfiles: [CNLabeledValue<CNSocialProfile>] = []
    var instantMessageAddresses: [CNLabeledValue<CNInstantMessageAddress>] = []
    var birthday: DateComponents?
    var nonGregorianBirthday: DateComponents?
    var dates: [CNLabeledValue<NSDateComponents>] = []

    /// The value of one key, as the Objective-C property would return it.
    func value(forKey key: String) -> Any? {
        switch key {
        case CNContactTypeKey: return contactType.rawValue
        case CNContactNamePrefixKey: return namePrefix
        case CNContactGivenNameKey: return givenName
        case CNContactMiddleNameKey: return middleName
        case CNContactFamilyNameKey: return familyName
        case CNContactPreviousFamilyNameKey: return previousFamilyName
        case CNContactNameSuffixKey: return nameSuffix
        case CNContactNicknameKey: return nickname
        case CNContactOrganizationNameKey: return organizationName
        case CNContactDepartmentNameKey: return departmentName
        case CNContactJobTitleKey: return jobTitle
        case CNContactPhoneticGivenNameKey: return phoneticGivenName
        case CNContactPhoneticMiddleNameKey: return phoneticMiddleName
        case CNContactPhoneticFamilyNameKey: return phoneticFamilyName
        case CNContactPhoneticOrganizationNameKey: return phoneticOrganizationName
        case CNContactNoteKey: return note
        case CNContactImageDataKey: return imageData
        case CNContactThumbnailImageDataKey: return thumbnailImageData
        case CNContactImageDataAvailableKey: return imageData != nil
        case CNContactPhoneNumbersKey: return phoneNumbers
        case CNContactEmailAddressesKey: return emailAddresses
        case CNContactPostalAddressesKey: return postalAddresses
        case CNContactUrlAddressesKey: return urlAddresses
        case CNContactRelationsKey: return contactRelations
        case CNContactSocialProfilesKey: return socialProfiles
        case CNContactInstantMessageAddressesKey: return instantMessageAddresses
        case CNContactBirthdayKey: return birthday
        case CNContactNonGregorianBirthdayKey: return nonGregorianBirthday
        case CNContactDatesKey: return dates
        default: return nil
        }
    }

    /// A copy holding only `keys` (other properties empty).
    func restricted(to keys: Set<String>) -> ContactData {
        var d = ContactData()
        func keep(_ key: String, _ body: (inout ContactData) -> Void) { if keys.contains(key) { body(&d) } }
        keep(CNContactTypeKey) { $0.contactType = contactType }
        keep(CNContactNamePrefixKey) { $0.namePrefix = namePrefix }
        keep(CNContactGivenNameKey) { $0.givenName = givenName }
        keep(CNContactMiddleNameKey) { $0.middleName = middleName }
        keep(CNContactFamilyNameKey) { $0.familyName = familyName }
        keep(CNContactPreviousFamilyNameKey) { $0.previousFamilyName = previousFamilyName }
        keep(CNContactNameSuffixKey) { $0.nameSuffix = nameSuffix }
        keep(CNContactNicknameKey) { $0.nickname = nickname }
        keep(CNContactOrganizationNameKey) { $0.organizationName = organizationName }
        keep(CNContactDepartmentNameKey) { $0.departmentName = departmentName }
        keep(CNContactJobTitleKey) { $0.jobTitle = jobTitle }
        keep(CNContactPhoneticGivenNameKey) { $0.phoneticGivenName = phoneticGivenName }
        keep(CNContactPhoneticMiddleNameKey) { $0.phoneticMiddleName = phoneticMiddleName }
        keep(CNContactPhoneticFamilyNameKey) { $0.phoneticFamilyName = phoneticFamilyName }
        keep(CNContactPhoneticOrganizationNameKey) { $0.phoneticOrganizationName = phoneticOrganizationName }
        keep(CNContactNoteKey) { $0.note = note }
        keep(CNContactImageDataKey) { $0.imageData = imageData }
        keep(CNContactThumbnailImageDataKey) { $0.thumbnailImageData = thumbnailImageData }
        if keys.contains(CNContactImageDataAvailableKey) && !keys.contains(CNContactImageDataKey) {
            // Availability without the bytes: keep a marker so imageDataAvailable answers.
            d.imageData = imageData == nil ? nil : Data()
        }
        keep(CNContactPhoneNumbersKey) { $0.phoneNumbers = phoneNumbers }
        keep(CNContactEmailAddressesKey) { $0.emailAddresses = emailAddresses }
        keep(CNContactPostalAddressesKey) { $0.postalAddresses = postalAddresses }
        keep(CNContactUrlAddressesKey) { $0.urlAddresses = urlAddresses }
        keep(CNContactRelationsKey) { $0.contactRelations = contactRelations }
        keep(CNContactSocialProfilesKey) { $0.socialProfiles = socialProfiles }
        keep(CNContactInstantMessageAddressesKey) { $0.instantMessageAddresses = instantMessageAddresses }
        keep(CNContactBirthdayKey) { $0.birthday = birthday }
        keep(CNContactNonGregorianBirthdayKey) { $0.nonGregorianBirthday = nonGregorianBirthday }
        keep(CNContactDatesKey) { $0.dates = dates }
        return d
    }
}

/// Process-wide settings that are not tied to a store.
public enum YcodeContactsEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _notes = false

    /// Whether the process has the `com.apple.developer.contacts.notes`
    /// entitlement (authorization.md §1). Default: no.
    public static var notesEntitlement: Bool {
        get {
            if let o = notesOverride { return o }
            lock.lock(); defer { lock.unlock() }
            return _notes
        }
        set { lock.lock(); _notes = newValue; lock.unlock() }
    }

    /// A task-local override of `notesEntitlement` (for tests).
    @TaskLocal public static var notesOverride: Bool?
}

func newPersonIdentifier() -> String { UUID().uuidString + ":ABPerson" }
func newGroupIdentifier() -> String { UUID().uuidString + ":ABGroup" }

/// Keys available on a contact created by the app: everything, except the
/// note without the notes entitlement (interface.md §2.2).
func keysForNewContact() -> Set<String> {
    YcodeContactsEnvironment.notesEntitlement ? allContactKeys : allContactKeys.subtracting([CNContactNoteKey])
}

public class CNContact: NSObject, NSCopying, NSMutableCopying, Identifiable, @unchecked Sendable {
    public let identifier: String
    var data: ContactData
    var available: Set<String>

    init(identifier: String, data: ContactData, available: Set<String>) {
        self.identifier = identifier
        self.data = data
        var a = available
        a.insert(CNContactIdentifierKey)
        self.available = a
    }

    /// An empty contact with a new `<UUID>:ABPerson` identifier.
    public override convenience init() {
        self.init(identifier: newPersonIdentifier(), data: ContactData(), available: keysForNewContact())
    }

    // MARK: Key availability

    public func isKeyAvailable(_ key: String) -> Bool { available.contains(key) }

    public func areKeysAvailable(_ keyDescriptors: [CNKeyDescriptor]) -> Bool {
        keySet(keyDescriptors).isSubset(of: available)
    }

    func read<T>(_ key: String, _ value: T, _ empty: T) -> T {
        if available.contains(key) { return value }
        CNException.notFetched().raise()
        return empty
    }

    /// Raises when any of `keys` is missing; returns whether all are there.
    func require(_ keys: Set<String>) -> Bool {
        if keys.isSubset(of: available) { return true }
        CNException.notFetched().raise()
        return false
    }

    // MARK: Properties

    public var contactType: CNContactType { read(CNContactTypeKey, data.contactType, .person) }
    public var namePrefix: String { read(CNContactNamePrefixKey, data.namePrefix, "") }
    public var givenName: String { read(CNContactGivenNameKey, data.givenName, "") }
    public var middleName: String { read(CNContactMiddleNameKey, data.middleName, "") }
    public var familyName: String { read(CNContactFamilyNameKey, data.familyName, "") }
    public var previousFamilyName: String { read(CNContactPreviousFamilyNameKey, data.previousFamilyName, "") }
    public var nameSuffix: String { read(CNContactNameSuffixKey, data.nameSuffix, "") }
    public var nickname: String { read(CNContactNicknameKey, data.nickname, "") }
    public var organizationName: String { read(CNContactOrganizationNameKey, data.organizationName, "") }
    public var departmentName: String { read(CNContactDepartmentNameKey, data.departmentName, "") }
    public var jobTitle: String { read(CNContactJobTitleKey, data.jobTitle, "") }
    public var phoneticGivenName: String { read(CNContactPhoneticGivenNameKey, data.phoneticGivenName, "") }
    public var phoneticMiddleName: String { read(CNContactPhoneticMiddleNameKey, data.phoneticMiddleName, "") }
    public var phoneticFamilyName: String { read(CNContactPhoneticFamilyNameKey, data.phoneticFamilyName, "") }
    public var phoneticOrganizationName: String { read(CNContactPhoneticOrganizationNameKey, data.phoneticOrganizationName, "") }
    public var note: String { read(CNContactNoteKey, data.note, "") }
    public var imageData: Data? { read(CNContactImageDataKey, data.imageData, nil) }
    public var thumbnailImageData: Data? { read(CNContactThumbnailImageDataKey, data.thumbnailImageData, nil) }
    public var imageDataAvailable: Bool { read(CNContactImageDataAvailableKey, data.imageData != nil, false) }
    public var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] { read(CNContactPhoneNumbersKey, data.phoneNumbers, []) }
    public var emailAddresses: [CNLabeledValue<NSString>] { read(CNContactEmailAddressesKey, data.emailAddresses, []) }
    public var postalAddresses: [CNLabeledValue<CNPostalAddress>] { read(CNContactPostalAddressesKey, data.postalAddresses, []) }
    public var urlAddresses: [CNLabeledValue<NSString>] { read(CNContactUrlAddressesKey, data.urlAddresses, []) }
    public var contactRelations: [CNLabeledValue<CNContactRelation>] { read(CNContactRelationsKey, data.contactRelations, []) }
    public var socialProfiles: [CNLabeledValue<CNSocialProfile>] { read(CNContactSocialProfilesKey, data.socialProfiles, []) }
    public var instantMessageAddresses: [CNLabeledValue<CNInstantMessageAddress>] {
        read(CNContactInstantMessageAddressesKey, data.instantMessageAddresses, [])
    }
    public var birthday: DateComponents? { read(CNContactBirthdayKey, data.birthday, nil) }
    public var nonGregorianBirthday: DateComponents? { read(CNContactNonGregorianBirthdayKey, data.nonGregorianBirthday, nil) }
    public var dates: [CNLabeledValue<NSDateComponents>] { read(CNContactDatesKey, data.dates, []) }

    /// The identifier's UUID part (`Identifiable`, iOS 17).
    public var id: UUID {
        let head = identifier.split(separator: ":").first.map(String.init) ?? identifier
        return UUID(uuidString: head) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    // MARK: Class members

    /// The English field name of a key (interface.md §2.4); empty for keys
    /// without a name (identifier, thumbnail, image availability).
    public class func localizedString(forKey key: String) -> String {
        Localization.contactKey(key)
    }

    /// A comparator for contacts by name (interface.md §4.3, design.md §5).
    public class func comparator(forNameSortOrder sortOrder: CNContactSortOrder) -> Comparator {
        return { a, b in
            guard let x = a as? CNContact, let y = b as? CNContact else { return .orderedSame }
            return NameSorting.compare(x, y, order: sortOrder)
        }
    }

    public class func descriptorForAllComparatorKeys() -> CNKeyDescriptor {
        CNAggregateKeyDescriptor(kind: "Comparator keys", keys: comparatorKeys)
    }

    /// Ycode treats every contact as its own unified contact; the answer is
    /// NO even for the contact's own identifier (interface.md §4.4).
    public func isUnifiedWithContact(withIdentifier contactIdentifier: String) -> Bool { false }

    // MARK: Copying and equality

    public func copy(with zone: NSZone? = nil) -> Any {
        if type(of: self) == CNContact.self { return self }
        return CNContact(identifier: identifier, data: data, available: available)
    }

    public func mutableCopy(with zone: NSZone? = nil) -> Any {
        CNMutableContact(identifier: identifier, data: data, available: available)
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let o = object as? CNContact else { return false }
        return o.identifier == identifier && o.available == available && o.data == data
    }

    public override var hash: Int { identifier.hashValue }

    public override var description: String {
        var parts = ["identifier=\(identifier)"]
        if available.contains(CNContactGivenNameKey) { parts.append("givenName=\(data.givenName)") }
        if available.contains(CNContactFamilyNameKey) { parts.append("familyName=\(data.familyName)") }
        if available.contains(CNContactOrganizationNameKey) { parts.append("organizationName=\(data.organizationName)") }
        if available.contains(CNContactPhoneNumbersKey) { parts.append("phoneNumbers=\(data.phoneNumbers.count)") }
        if available.contains(CNContactEmailAddressesKey) { parts.append("emailAddresses=\(data.emailAddresses.count)") }
        return "<\(type(of: self)): \(parts.joined(separator: ", "))>"
    }

    public var shortDebugDescription: String { "<\(type(of: self)): \(identifier)>" }
    public override var debugDescription: String { description }

    // MARK: Key-value access

    /// The value of a property by key; raises when the key was not fetched.
    func ycodeValue(forKey key: String) -> Any? {
        if key == CNContactIdentifierKey { return identifier }
        guard available.contains(key) else {
            CNException.notFetched().raise()
            return nil
        }
        return data.value(forKey: key)
    }

    #if canImport(ObjectiveC)
    public override func value(forKey key: String) -> Any? { ycodeValue(forKey: key) }
    #else
    public func value(forKey key: String) -> Any? { ycodeValue(forKey: key) }
    #endif
}

// MARK: - CNMutableContact

public final class CNMutableContact: CNContact, @unchecked Sendable {
    /// Keys set since the contact was created or fetched (what an update writes).
    var changedKeys: Set<String> = []

    override init(identifier: String, data: ContactData, available: Set<String>) {
        super.init(identifier: identifier, data: data, available: available)
    }

    func write(_ key: String, _ body: (inout ContactData) -> Void) {
        guard available.contains(key) else {
            CNException.notFetched().raise()
            return
        }
        body(&data)
        changedKeys.insert(key)
    }

    public override var contactType: CNContactType {
        get { super.contactType } set { write(CNContactTypeKey) { $0.contactType = newValue } }
    }
    public override var namePrefix: String {
        get { super.namePrefix } set { write(CNContactNamePrefixKey) { $0.namePrefix = newValue } }
    }
    public override var givenName: String {
        get { super.givenName } set { write(CNContactGivenNameKey) { $0.givenName = newValue } }
    }
    public override var middleName: String {
        get { super.middleName } set { write(CNContactMiddleNameKey) { $0.middleName = newValue } }
    }
    public override var familyName: String {
        get { super.familyName } set { write(CNContactFamilyNameKey) { $0.familyName = newValue } }
    }
    public override var previousFamilyName: String {
        get { super.previousFamilyName } set { write(CNContactPreviousFamilyNameKey) { $0.previousFamilyName = newValue } }
    }
    public override var nameSuffix: String {
        get { super.nameSuffix } set { write(CNContactNameSuffixKey) { $0.nameSuffix = newValue } }
    }
    public override var nickname: String {
        get { super.nickname } set { write(CNContactNicknameKey) { $0.nickname = newValue } }
    }
    public override var organizationName: String {
        get { super.organizationName } set { write(CNContactOrganizationNameKey) { $0.organizationName = newValue } }
    }
    public override var departmentName: String {
        get { super.departmentName } set { write(CNContactDepartmentNameKey) { $0.departmentName = newValue } }
    }
    public override var jobTitle: String {
        get { super.jobTitle } set { write(CNContactJobTitleKey) { $0.jobTitle = newValue } }
    }
    public override var phoneticGivenName: String {
        get { super.phoneticGivenName } set { write(CNContactPhoneticGivenNameKey) { $0.phoneticGivenName = newValue } }
    }
    public override var phoneticMiddleName: String {
        get { super.phoneticMiddleName } set { write(CNContactPhoneticMiddleNameKey) { $0.phoneticMiddleName = newValue } }
    }
    public override var phoneticFamilyName: String {
        get { super.phoneticFamilyName } set { write(CNContactPhoneticFamilyNameKey) { $0.phoneticFamilyName = newValue } }
    }
    public override var phoneticOrganizationName: String {
        get { super.phoneticOrganizationName }
        set { write(CNContactPhoneticOrganizationNameKey) { $0.phoneticOrganizationName = newValue } }
    }
    public override var note: String {
        get { super.note } set { write(CNContactNoteKey) { $0.note = newValue } }
    }
    public override var imageData: Data? {
        get { super.imageData }
        set {
            write(CNContactImageDataKey) {
                $0.imageData = newValue
                $0.thumbnailImageData = newValue.map(Thumbnail.make)
            }
        }
    }
    public override var phoneNumbers: [CNLabeledValue<CNPhoneNumber>] {
        get { super.phoneNumbers } set { write(CNContactPhoneNumbersKey) { $0.phoneNumbers = newValue } }
    }
    public override var emailAddresses: [CNLabeledValue<NSString>] {
        get { super.emailAddresses } set { write(CNContactEmailAddressesKey) { $0.emailAddresses = newValue } }
    }
    public override var postalAddresses: [CNLabeledValue<CNPostalAddress>] {
        get { super.postalAddresses } set { write(CNContactPostalAddressesKey) { $0.postalAddresses = newValue } }
    }
    public override var urlAddresses: [CNLabeledValue<NSString>] {
        get { super.urlAddresses } set { write(CNContactUrlAddressesKey) { $0.urlAddresses = newValue } }
    }
    public override var contactRelations: [CNLabeledValue<CNContactRelation>] {
        get { super.contactRelations } set { write(CNContactRelationsKey) { $0.contactRelations = newValue } }
    }
    public override var socialProfiles: [CNLabeledValue<CNSocialProfile>] {
        get { super.socialProfiles } set { write(CNContactSocialProfilesKey) { $0.socialProfiles = newValue } }
    }
    public override var instantMessageAddresses: [CNLabeledValue<CNInstantMessageAddress>] {
        get { super.instantMessageAddresses }
        set { write(CNContactInstantMessageAddressesKey) { $0.instantMessageAddresses = newValue } }
    }
    public override var birthday: DateComponents? {
        get { super.birthday } set { write(CNContactBirthdayKey) { $0.birthday = newValue } }
    }
    public override var nonGregorianBirthday: DateComponents? {
        get { super.nonGregorianBirthday } set { write(CNContactNonGregorianBirthdayKey) { $0.nonGregorianBirthday = newValue } }
    }
    public override var dates: [CNLabeledValue<NSDateComponents>] {
        get { super.dates } set { write(CNContactDatesKey) { $0.dates = newValue } }
    }

    public override func copy(with zone: NSZone? = nil) -> Any {
        CNContact(identifier: identifier, data: data, available: available)
    }

    // MARK: Key-value setting (the only way to put a wrongly typed value in)

    /// Sets a property by key. A multi-valued property only takes labeled
    /// values of its class; anything else raises
    /// `CNPropertyInvalidTypeException` (interface.md §2.4, errors.md §3).
    func ycodeSetValue(_ value: Any?, forKey key: String) {
        func labeled<V>(_ type: V.Type, _ expected: String) -> [CNLabeledValue<V>]? {
            guard let items = value as? [Any] else {
                if value == nil { return [] }
                invalid(value as Any, value as Any, expected)
                return nil
            }
            var out: [CNLabeledValue<V>] = []
            for item in items {
                if let lv = item as? CNLabeledValue<V> {
                    out.append(lv)
                    continue
                }
                let inner = (item as? AnyLabeledValue)?.anyValue ?? item
                invalid(item, inner, expected)
                return nil
            }
            return out
        }
        switch key {
        case CNContactPhoneNumbersKey:
            if let v = labeled(CNPhoneNumber.self, "CNPhoneNumber") { phoneNumbers = v }
        case CNContactEmailAddressesKey:
            if let v = labeled(NSString.self, "NSString") { emailAddresses = v }
        case CNContactPostalAddressesKey:
            if let v = labeled(CNPostalAddress.self, "CNPostalAddress") { postalAddresses = v }
        case CNContactUrlAddressesKey:
            if let v = labeled(NSString.self, "NSString") { urlAddresses = v }
        case CNContactRelationsKey:
            if let v = labeled(CNContactRelation.self, "CNContactRelation") { contactRelations = v }
        case CNContactSocialProfilesKey:
            if let v = labeled(CNSocialProfile.self, "CNSocialProfile") { socialProfiles = v }
        case CNContactInstantMessageAddressesKey:
            if let v = labeled(CNInstantMessageAddress.self, "CNInstantMessageAddress") { instantMessageAddresses = v }
        case CNContactDatesKey:
            if let v = labeled(NSDateComponents.self, "NSDateComponents") { dates = v }
        case CNContactTypeKey:
            if let n = value as? Int, let t = CNContactType(rawValue: n) { contactType = t }
        case CNContactImageDataKey: imageData = value as? Data
        case CNContactBirthdayKey: birthday = value as? DateComponents
        case CNContactNonGregorianBirthdayKey: nonGregorianBirthday = value as? DateComponents
        default:
            guard let s = value as? String ?? (value == nil ? "" : nil) else { return }
            switch key {
            case CNContactNamePrefixKey: namePrefix = s
            case CNContactGivenNameKey: givenName = s
            case CNContactMiddleNameKey: middleName = s
            case CNContactFamilyNameKey: familyName = s
            case CNContactPreviousFamilyNameKey: previousFamilyName = s
            case CNContactNameSuffixKey: nameSuffix = s
            case CNContactNicknameKey: nickname = s
            case CNContactOrganizationNameKey: organizationName = s
            case CNContactDepartmentNameKey: departmentName = s
            case CNContactJobTitleKey: jobTitle = s
            case CNContactPhoneticGivenNameKey: phoneticGivenName = s
            case CNContactPhoneticMiddleNameKey: phoneticMiddleName = s
            case CNContactPhoneticFamilyNameKey: phoneticFamilyName = s
            case CNContactPhoneticOrganizationNameKey: phoneticOrganizationName = s
            case CNContactNoteKey: note = s
            default: break
            }
        }
    }

    private func invalid(_ item: Any, _ inner: Any, _ expected: String) {
        let cls = (inner is NSString || inner is String) ? "NSString" : String(describing: type(of: inner))
        CNException(name: propertyInvalidTypeExceptionName,
                    reason: "Labeled value \(item) value \(inner) has incorrect type \(cls). It should be \(expected).").raise()
    }

    #if canImport(ObjectiveC)
    public override func setValue(_ value: Any?, forKey key: String) { ycodeSetValue(value, forKey: key) }
    #else
    public func setValue(_ value: Any?, forKey key: String) { ycodeSetValue(value, forKey: key) }
    #endif
}

/// The stored thumbnail (interface.md §2.5). Ycode does not decode images;
/// the thumbnail is the image data itself (deviation, see README).
enum Thumbnail {
    static func make(_ image: Data) -> Data { image }
}

/// Type-erased access to a labeled value's value.
protocol AnyLabeledValue {
    var anyValue: Any { get }
    var labeledIdentifier: String { get }
    var labeledLabel: String? { get }
}

extension CNLabeledValue: AnyLabeledValue {
    var anyValue: Any { value }
    var labeledIdentifier: String { identifier }
    var labeledLabel: String? { label }
}
