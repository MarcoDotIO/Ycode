// CNContactFormatter (formats.md §1) and name sorting (interface.md §4.3,
// design.md §5).

import Foundation

enum Script {
    /// Han, Kana or Hangul.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2FFFF, 0xF900...0xFAFF, 0x3005...0x3007,
             0x3040...0x309F, 0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F,
             0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F:
            return true
        default:
            return false
        }
    }

    /// True when the string has letters and every letter is CJK.
    static func isCJK(_ text: String) -> Bool {
        var sawLetter = false
        for s in text.unicodeScalars {
            if isCJK(s) { sawLetter = true; continue }
            if s.properties.isAlphabetic { return false }
        }
        return sawLetter
    }
}

public class CNContactFormatter: Formatter, @unchecked Sendable {
    public var style: CNContactFormatterStyle = .fullName

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    // MARK: Key descriptors

    public class func descriptorForRequiredKeys(for style: CNContactFormatterStyle) -> CNKeyDescriptor {
        switch style {
        case .fullName:
            return CNAggregateKeyDescriptor(kind: "Formatter style: Full name", keys: fullNameKeys.union(nameOrderKeys))
        case .phoneticFullName:
            return CNAggregateKeyDescriptor(kind: "Formatter style: Phonetic full name", keys: phoneticNameKeys.union(nameOrderKeys))
        }
    }

    public class var descriptorForRequiredKeysForNameOrder: CNKeyDescriptor {
        CNAggregateKeyDescriptor(kind: "Formatter name order", keys: nameOrderKeys)
    }

    public class var descriptorForRequiredKeysForDelimiter: CNKeyDescriptor {
        CNAggregateKeyDescriptor(kind: "Formatter delimiter", keys: nameOrderKeys)
    }

    // MARK: Order and delimiter (formats.md §1.1 rules 1–3)

    static func isFamilyFirst(_ d: ContactData) -> Bool {
        let parts = [d.givenName, d.middleName, d.familyName].filter { !$0.isEmpty }
        return !parts.isEmpty && parts.allSatisfy(Script.isCJK)
    }

    public class func nameOrder(for contact: CNContact) -> CNContactDisplayNameOrder {
        guard contact.require(nameOrderKeys) else { return .givenNameFirst }
        return isFamilyFirst(contact.data) ? .familyNameFirst : .givenNameFirst
    }

    public class func delimiter(for contact: CNContact) -> String {
        guard contact.require(nameOrderKeys) else { return " " }
        return isFamilyFirst(contact.data) ? "" : " "
    }

    // MARK: Formatting

    /// The (key, text) runs of a formatted name and the delimiter; nil when
    /// there is nothing to show.
    static func runs(for contact: CNContact, style: CNContactFormatterStyle) -> (runs: [(String, String)], delimiter: String)? {
        // swiftlint:disable:next force_cast - the descriptor for a style is always an aggregate
        let required = (descriptorForRequiredKeys(for: style) as! CNAggregateKeyDescriptor).keys
        guard contact.require(required) else { return nil }
        let d = contact.data
        let familyFirst = isFamilyFirst(d)
        switch style {
        case .fullName:
            if d.contactType == .organization && !d.organizationName.isEmpty {
                return ([(CNContactOrganizationNameKey, d.organizationName)], " ")
            }
            let parts: [(String, String)] = familyFirst
                ? [(CNContactNamePrefixKey, d.namePrefix), (CNContactFamilyNameKey, d.familyName),
                   (CNContactGivenNameKey, d.givenName), (CNContactMiddleNameKey, d.middleName),
                   (CNContactNameSuffixKey, d.nameSuffix)]
                : [(CNContactNamePrefixKey, d.namePrefix), (CNContactGivenNameKey, d.givenName),
                   (CNContactMiddleNameKey, d.middleName), (CNContactFamilyNameKey, d.familyName),
                   (CNContactNameSuffixKey, d.nameSuffix)]
            let present = parts.filter { !$0.1.isEmpty }
            if !present.isEmpty { return (present, familyFirst ? "" : " ") }
            if !d.nickname.isEmpty { return ([(CNContactNicknameKey, d.nickname)], " ") }
            if !d.organizationName.isEmpty { return ([(CNContactOrganizationNameKey, d.organizationName)], " ") }
            return nil
        case .phoneticFullName:
            if d.contactType == .organization {
                return d.phoneticOrganizationName.isEmpty
                    ? nil : ([(CNContactPhoneticOrganizationNameKey, d.phoneticOrganizationName)], " ")
            }
            let parts: [(String, String)] = familyFirst
                ? [(CNContactPhoneticFamilyNameKey, d.phoneticFamilyName), (CNContactPhoneticGivenNameKey, d.phoneticGivenName),
                   (CNContactPhoneticMiddleNameKey, d.phoneticMiddleName)]
                : [(CNContactPhoneticGivenNameKey, d.phoneticGivenName), (CNContactPhoneticMiddleNameKey, d.phoneticMiddleName),
                   (CNContactPhoneticFamilyNameKey, d.phoneticFamilyName)]
            let present = parts.filter { !$0.1.isEmpty }
            if !present.isEmpty { return (present, " ") }
            if !d.phoneticOrganizationName.isEmpty {
                return ([(CNContactPhoneticOrganizationNameKey, d.phoneticOrganizationName)], " ")
            }
            return nil
        }
    }

    /// Joins runs; no delimiter after a part that already ends with
    /// whitespace (rule 6). Returns the pieces as (key or nil, text).
    static func pieces(_ runs: [(String, String)], delimiter: String) -> [(String?, String)] {
        var out: [(String?, String)] = []
        for (i, run) in runs.enumerated() {
            if i > 0, !delimiter.isEmpty, let last = runs[i - 1].1.last, !last.isWhitespace {
                out.append((nil, delimiter))
            }
            out.append((run.0, run.1))
        }
        return out
    }

    public class func string(from contact: CNContact, style: CNContactFormatterStyle) -> String? {
        guard let r = runs(for: contact, style: style) else { return nil }
        return pieces(r.runs, delimiter: r.delimiter).map(\.1).joined()
    }

    public class func attributedString(from contact: CNContact, style: CNContactFormatterStyle,
                                       defaultAttributes attributes: [AnyHashable: Any]? = nil) -> NSAttributedString? {
        guard let r = runs(for: contact, style: style) else { return nil }
        var base: [NSAttributedString.Key: Any] = [:]
        for (k, v) in attributes ?? [:] {
            if let s = k as? String { base[NSAttributedString.Key(s)] = v }
            else if let key = k as? NSAttributedString.Key { base[key] = v }
        }
        let out = NSMutableAttributedString(string: "")
        for (key, text) in pieces(r.runs, delimiter: r.delimiter) {
            var attrs = base
            if let key { attrs[NSAttributedString.Key(CNContactPropertyAttribute)] = key }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    public func string(from contact: CNContact) -> String? {
        CNContactFormatter.string(from: contact, style: style)
    }

    public func attributedString(from contact: CNContact, defaultAttributes attributes: [AnyHashable: Any]? = nil) -> NSAttributedString? {
        CNContactFormatter.attributedString(from: contact, style: style, defaultAttributes: attributes)
    }

    public override func string(for obj: Any?) -> String? {
        guard let c = obj as? CNContact else { return nil }
        return string(from: c)
    }
}

// MARK: - Name sorting

/// Sort keys (Ycode's reading of interface.md §4.3): each name part is
/// replaced by its phonetic part when that is set; a contact without given
/// and family name (or an organization) sorts by its organization name; the
/// primary part is the family or given name per the order, then the other
/// part, then the organization. Comparison is case- and
/// diacritic-insensitive with locale collation (CJK after Latin).
enum NameSorting {
    static let locale = Locale(identifier: "en_US")

    static func key(_ d: ContactData, order: CNContactSortOrder) -> [String] {
        func pick(_ phonetic: String, _ plain: String) -> String { phonetic.isEmpty ? plain : phonetic }
        let g = pick(d.phoneticGivenName, d.givenName)
        let f = pick(d.phoneticFamilyName, d.familyName)
        let o = pick(d.phoneticOrganizationName, d.organizationName)
        if (d.contactType == .organization && !o.isEmpty) || (g.isEmpty && f.isEmpty) {
            return [o.isEmpty ? d.nickname : o]
        }
        let familyOrder = order != .givenName
        let (first, second) = familyOrder ? (f, g) : (g, f)
        return first.isEmpty ? [second, "", o] : [first, second, o]
    }

    static func compare(keys a: [String], _ b: [String]) -> ComparisonResult {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : ""
            let y = i < b.count ? b[i] : ""
            let r = x.compare(y, options: [.caseInsensitive, .diacriticInsensitive], range: nil, locale: locale)
            if r != .orderedSame { return r }
        }
        return .orderedSame
    }

    static func compare(_ a: CNContact, _ b: CNContact, order: CNContactSortOrder) -> ComparisonResult {
        compare(keys: key(a.data, order: order), key(b.data, order: order))
    }
}
