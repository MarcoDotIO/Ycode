// Enumerations of Contacts with the raw values of
// specs/frameworks/contacts/identifiers.md ("Contacts enumerations").

import Foundation

public enum CNAuthorizationStatus: Int, Sendable {
    case notDetermined = 0
    case restricted = 1
    case denied = 2
    case authorized = 3
    case limited = 4
}

public enum CNContactDisplayNameOrder: Int, Sendable {
    case userDefault = 0
    case givenNameFirst = 1
    case familyNameFirst = 2
}

public enum CNContactFormatterStyle: Int, Sendable {
    case fullName = 0
    case phoneticFullName = 1
}

public enum CNContactSortOrder: Int, Sendable {
    case none = 0
    case userDefault = 1
    case givenName = 2
    case familyName = 3
}

public enum CNContactType: Int, Sendable {
    case person = 0
    case organization = 1
}

public enum CNContainerType: Int, Sendable {
    case unassigned = 0
    case local = 1
    case exchange = 2
    case cardDAV = 3
}

public enum CNEntityType: Int, Sendable {
    case contacts = 0
}

public enum CNPostalAddressFormatterStyle: Int, Sendable {
    case mailingAddress = 0
}

extension Notification.Name {
    /// Posted after each successful save (interface.md §6.1).
    public static let CNContactStoreDidChange = Notification.Name("CNContactStoreDidChangeNotification")
}
