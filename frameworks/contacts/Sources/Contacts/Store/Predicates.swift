// Predicates and their matching rules (interface.md §4.2, design.md §4).

import Foundation

/// The predicates built by the Contacts constructors. They are NSPredicate
/// subclasses so that they can be passed wherever an NSPredicate is
/// expected; the store recognizes them and matches with its own rules.
final class CNStorePredicate: NSPredicate {
    enum Kind {
        case name(String)
        case email(String)
        case phone(CNPhoneNumber)
        case contactIdentifiers([String])
        case contactsInGroup(String)
        case contactsInContainer(String)
        case groupIdentifiers([String])
        case groupsInContainer(String)
        case containerIdentifiers([String])
        case containerOfContact(String)
        case containerOfGroup(String)
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
        #if canImport(ObjectiveC)
        super.init()
        #else
        super.init(value: false)
        #endif
    }

    required init?(coder: NSCoder) { nil }

    /// Evaluates name, email, phone and identifier predicates on a contact
    /// object (group and container predicates need the store).
    override func evaluate(with object: Any?) -> Bool {
        guard let c = object as? CNContact else { return false }
        return Matching.matches(kind, identifier: c.identifier, data: c.data, countryCode: CNContactStore.ycodeDefaultConfiguration.countryCode)
    }

    override var description: String {
        switch kind {
        case .name(let s): return "name MATCHES \"\(s)\""
        case .email(let s): return "emailAddress == \"\(s)\""
        case .phone(let p): return "phoneNumber == \"\(p.stringValue)\""
        case .contactIdentifiers(let ids): return "identifier IN \(ids)"
        case .contactsInGroup(let g): return "group == \(g)"
        case .contactsInContainer(let c): return "container == \(c)"
        case .groupIdentifiers(let ids): return "group.identifier IN \(ids)"
        case .groupsInContainer(let c): return "group.container == \(c)"
        case .containerIdentifiers(let ids): return "container.identifier IN \(ids)"
        case .containerOfContact(let c): return "container CONTAINS contact \(c)"
        case .containerOfGroup(let g): return "container CONTAINS group \(g)"
        }
    }
}

extension CNContact {
    public class func predicateForContacts(matchingName name: String) -> NSPredicate {
        CNStorePredicate(.name(name))
    }

    public class func predicateForContacts(matchingEmailAddress emailAddress: String) -> NSPredicate {
        CNStorePredicate(.email(emailAddress))
    }

    public class func predicateForContacts(matching phoneNumber: CNPhoneNumber) -> NSPredicate {
        CNStorePredicate(.phone(phoneNumber))
    }

    public class func predicateForContacts(withIdentifiers identifiers: [String]) -> NSPredicate {
        CNStorePredicate(.contactIdentifiers(identifiers))
    }

    public class func predicateForContactsInGroup(withIdentifier groupIdentifier: String) -> NSPredicate {
        CNStorePredicate(.contactsInGroup(groupIdentifier))
    }

    public class func predicateForContactsInContainer(withIdentifier containerIdentifier: String) -> NSPredicate {
        CNStorePredicate(.contactsInContainer(containerIdentifier))
    }
}

enum Matching {
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Words of a string: runs of letters and digits, folded.
    static func words(_ s: String) -> [String] {
        fold(s).split { !($0.isLetter || $0.isNumber) }.map(String.init)
    }

    /// The fields searched by name (design.md §4; job title per §4.2).
    static func nameFields(_ d: ContactData) -> [String] {
        [d.givenName, d.middleName, d.familyName, d.nickname, d.organizationName, d.jobTitle,
         d.phoneticGivenName, d.phoneticMiddleName, d.phoneticFamilyName, d.phoneticOrganizationName,
         d.familyName + d.givenName, d.phoneticFamilyName + d.phoneticGivenName]
    }

    /// Every word of the query must be a prefix of some word of the fields.
    static func matchesName(_ query: String, _ d: ContactData) -> Bool {
        let q = words(query)
        guard !q.isEmpty else { return false }
        let fieldWords = nameFields(d).flatMap(words)
        return q.allSatisfy { qw in fieldWords.contains { $0.hasPrefix(qw) } }
    }

    static func matchesEmail(_ query: String, _ d: ContactData) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return d.emailAddresses.contains { String(describing: $0.value).trimmingCharacters(in: .whitespaces).lowercased() == q }
    }

    /// Country calling codes by region (a small Ycode table).
    static let callingCodes: [String: String] = [
        "us": "1", "ca": "1", "gb": "44", "de": "49", "fr": "33", "jp": "81", "cn": "86", "kr": "82",
        "in": "91", "au": "61", "br": "55", "mx": "52", "es": "34", "it": "39", "nl": "31", "ch": "41",
    ]

    static func matchesPhone(_ query: CNPhoneNumber, _ d: ContactData, countryCode: String) -> Bool {
        let cc = callingCodes[countryCode.lowercased()] ?? "1"
        let q = query.normalizedDigits(callingCode: cc)
        guard q.count > cc.count else { return false }
        return d.phoneNumbers.contains { $0.value.normalizedDigits(callingCode: cc) == q }
    }

    static func matches(_ kind: CNStorePredicate.Kind, identifier: String, data: ContactData, countryCode: String) -> Bool {
        switch kind {
        case .name(let s): return matchesName(s, data)
        case .email(let s): return matchesEmail(s, data)
        case .phone(let p): return matchesPhone(p, data, countryCode: countryCode)
        case .contactIdentifiers(let ids): return ids.contains(identifier)
        default: return false
        }
    }
}
