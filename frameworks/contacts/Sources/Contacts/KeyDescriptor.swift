// Key descriptors (interface.md §2.1): plain key strings and the composite
// descriptors that formatters, vCard serialization and sorting hand out.

import Foundation

/// Something that names contact keys to fetch: a key string (`String` or
/// `NSString`) or a composite descriptor.
public protocol CNKeyDescriptor {
    /// The plain keys this descriptor stands for (Ycode-internal).
    var _cnKeys: Set<String> { get }
}

extension String: CNKeyDescriptor {
    public var _cnKeys: Set<String> { [self] }
}

extension NSString: CNKeyDescriptor {
    public var _cnKeys: Set<String> { [String(describing: self)] }
}

/// A composite descriptor; describes itself as
/// `<CNAggregateKeyDescriptor: 0x…: kind=…>`.
final class CNAggregateKeyDescriptor: NSObject, CNKeyDescriptor {
    let kind: String
    let keys: Set<String>

    init(kind: String, keys: Set<String>) {
        self.kind = kind
        self.keys = keys
    }

    init(kind: String, descriptors: [CNKeyDescriptor]) {
        self.kind = kind
        self.keys = descriptors.reduce(into: Set<String>()) { $0.formUnion($1._cnKeys) }
    }

    var _cnKeys: Set<String> { keys }

    override var description: String {
        let address = String(UInt(bitPattern: ObjectIdentifier(self).hashValue), radix: 16)
        return "<CNAggregateKeyDescriptor: 0x\(address): kind=\(kind)>"
    }
}

func keySet(_ descriptors: [CNKeyDescriptor]) -> Set<String> {
    descriptors.reduce(into: Set<String>()) { $0.formUnion($1._cnKeys) }
}

/// Every property key of a contact.
let allContactKeys: Set<String> = [
    CNContactIdentifierKey, CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey,
    CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactPreviousFamilyNameKey, CNContactNameSuffixKey,
    CNContactNicknameKey, CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
    CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
    CNContactPhoneticOrganizationNameKey, CNContactNoteKey, CNContactImageDataKey,
    CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey, CNContactPhoneNumbersKey,
    CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
    CNContactRelationsKey, CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey,
    CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactDatesKey,
]

let fullNameKeys: Set<String> = [
    CNContactTypeKey, CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
    CNContactFamilyNameKey, CNContactNameSuffixKey, CNContactNicknameKey, CNContactOrganizationNameKey,
]

let phoneticNameKeys: Set<String> = [
    CNContactTypeKey, CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey,
    CNContactPhoneticFamilyNameKey, CNContactPhoneticOrganizationNameKey,
]

/// Keys read by name ordering and the delimiter (the scripts of the name parts).
let nameOrderKeys: Set<String> = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey]

/// Keys the vCard writer reads (everything it exports; not note, not images).
let vCardKeys: Set<String> = allContactKeys.subtracting([
    CNContactNoteKey, CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
])

/// Keys used by the name sort comparator (design.md §5).
let comparatorKeys: Set<String> = fullNameKeys.union(phoneticNameKeys)
