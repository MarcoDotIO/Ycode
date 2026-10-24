// English names for predefined labels and contact keys (interface.md §2.4).
// The listed words are the spec's; the relation labels that the spec does
// not list are rendered by Ycode's own rule (camel-case words, lower case,
// "InLaw" as "-in-law", "Elder" as "older", the qualifying tail dropped).

import Foundation

enum Localization {
    private static let fixed: [String: String] = [
        CNLabelHome: "home",
        CNLabelWork: "work",
        CNLabelSchool: "school",
        CNLabelOther: "other",
        CNLabelURLAddressHomePage: "homepage",
        CNLabelDateAnniversary: "anniversary",
        CNLabelPhoneNumberMobile: "mobile",
        CNLabelPhoneNumberMain: "main",
        CNLabelPhoneNumberHomeFax: "home fax",
        CNLabelPhoneNumberWorkFax: "work fax",
        CNLabelPhoneNumberOtherFax: "other fax",
        CNLabelPhoneNumberPager: "pager",
        CNLabelPhoneNumberiPhone: "iPhone",
        CNLabelEmailiCloud: "iCloud",
        CNLabelPhoneNumberAppleWatch: "Apple Watch",
    ]

    private static let relations: [String: String] = {
        var out: [String: String] = [:]
        for (_, value) in ycodeAllLabelConstants where value.hasPrefix("_$!<") && value.hasSuffix(">!$_") {
            if fixed[value] != nil { continue }
            let inner = String(value.dropFirst(4).dropLast(4))
            out[value] = relationWords(inner)
        }
        return out
    }()

    /// Splits "AuntFathersBrothersWife" into words and keeps the head
    /// relation: "aunt". "ParentsSibling" → "parent's sibling",
    /// "SisterInLaw…" → "sister-in-law", "GirlfriendOrBoyfriend" →
    /// "girlfriend or boyfriend".
    static func relationWords(_ camel: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in camel {
            if ch.isUppercase && !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let qualifiers: Set<String> = ["Fathers", "Mothers", "Parents", "Husbands", "Wifes", "Spouses", "Brothers",
                                       "Sisters", "Daughters", "Sons", "Grandparents", "Siblings", "Elder", "Younger"]
        var out: [String] = []
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "Or" {
                out.append("or")
            } else if qualifiers.contains(w) && !out.isEmpty && out.last != "or" {
                // The qualifying tail (whose side of the family) is dropped,
                // up to an "Or" alternative.
                while i < words.count && words[i] != "Or" { i += 1 }
                continue
            } else if w == "In", i + 1 < words.count, words[i + 1] == "Law", let last = out.popLast() {
                out.append(last + "-in-law")
                i += 2
                continue
            } else if w == "Elder" {
                out.append("older")
            } else if w.hasSuffix("s") && ["Parents", "Siblings", "Grandparents"].contains(w) {
                out.append(String(w.dropLast()).lowercased() + "'s")
            } else {
                out.append(w.lowercased())
            }
            i += 1
        }
        return out.joined(separator: " ")
    }

    static func label(_ label: String) -> String {
        if let f = fixed[label] { return f }
        if let r = relations[label] { return r }
        return label
    }

    static func contactKey(_ key: String) -> String {
        switch key {
        case CNContactTypeKey: return "Contact type"
        case CNContactNamePrefixKey: return "Prefix"
        case CNContactGivenNameKey: return "First name"
        case CNContactMiddleNameKey: return "Middle name"
        case CNContactFamilyNameKey: return "Last name"
        case CNContactPreviousFamilyNameKey: return "Maiden name"
        case CNContactNameSuffixKey: return "Suffix"
        case CNContactNicknameKey: return "Nickname"
        case CNContactOrganizationNameKey: return "Company"
        case CNContactDepartmentNameKey: return "Department"
        case CNContactJobTitleKey: return "Job title"
        case CNContactPhoneticGivenNameKey: return "Phonetic first name"
        case CNContactPhoneticMiddleNameKey: return "Phonetic middle name"
        case CNContactPhoneticFamilyNameKey: return "Phonetic last name"
        case CNContactPhoneticOrganizationNameKey: return "Phonetic company name"
        case CNContactNoteKey: return "Notes"
        case CNContactImageDataKey: return "Photo"
        case CNContactPhoneNumbersKey: return "Phone"
        case CNContactEmailAddressesKey: return "Email"
        case CNContactPostalAddressesKey: return "Address"
        case CNContactUrlAddressesKey: return "URL"
        case CNContactRelationsKey: return "Related name"
        case CNContactSocialProfilesKey: return "Social profile"
        case CNContactInstantMessageAddressesKey: return "Instant message"
        case CNContactBirthdayKey: return "Birthday"
        case CNContactNonGregorianBirthdayKey: return "Alternate calendar birthday"
        case CNContactDatesKey: return "Date"
        default: return ""  // identifier, thumbnailImageData, imageDataAvailable: no name
        }
    }
}
