// C-CN-FORMAT formats.md §1 (CNContactFormatter, F1–F24) and §2
// (CNPostalAddressFormatter, P1–P14).

import Foundation
import Testing
@testable import Contacts

struct NameCase: CustomTestStringConvertible, Sendable {
    let id: String
    let prefix, given, middle, family, suffix: String
    var nickname = ""
    var organization = ""
    var organizationType = false
    var email = ""
    var phonetic: (given: String, middle: String, family: String, organization: String) = ("", "", "", "")
    let full: String?
    var phoneticFull: String?? = .none
    let order: CNContactDisplayNameOrder
    let delimiter: String
    let runs: [String]

    var testDescription: String { id }

    func contact() -> CNMutableContact {
        let c = CNMutableContact()
        c.namePrefix = prefix; c.givenName = given; c.middleName = middle; c.familyName = family; c.nameSuffix = suffix
        c.nickname = nickname
        c.organizationName = organization
        if organizationType { c.contactType = .organization }
        if !email.isEmpty { c.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: NSString(string: email))] }
        c.phoneticGivenName = phonetic.given; c.phoneticMiddleName = phonetic.middle
        c.phoneticFamilyName = phonetic.family; c.phoneticOrganizationName = phonetic.organization
        return c
    }
}

private func n(_ id: String, _ p: String = "", g: String = "", m: String = "", f: String = "", s: String = "",
               full: String?, order: CNContactDisplayNameOrder = .givenNameFirst, delimiter: String = " ",
               runs: [String], configure: (inout NameCase) -> Void = { _ in }) -> NameCase {
    var c = NameCase(id: id, prefix: p, given: g, middle: m, family: f, suffix: s, full: full, order: order,
                     delimiter: delimiter, runs: runs)
    configure(&c)
    return c
}

let G = CNContactGivenNameKey, F = CNContactFamilyNameKey, M = CNContactMiddleNameKey
let P = CNContactNamePrefixKey, S = CNContactNameSuffixKey, O = CNContactOrganizationNameKey

/// formats.md §1.2, rows F1–F24 (made-up input).
let nameCases: [NameCase] = [
    n("F1", g: "Avery", f: "Example", full: "Avery Example", runs: [G, F]),
    n("F2", "Dr.", g: "Avery", m: "Quinn", f: "Example", s: "Jr.", full: "Dr. Avery Quinn Example Jr.", runs: [P, G, M, F, S]),
    n("F3", g: "Avery", full: "Avery", runs: [G]),
    n("F4", f: "Example", full: "Example", runs: [F]),
    n("F5", m: "Quinn", full: "Quinn", runs: [M]),
    n("F6", full: "Ave", runs: [CNContactNicknameKey]) { $0.nickname = "Ave" },
    n("F7", full: "Example Widgets LLC", runs: [O]) { $0.organization = "Example Widgets LLC" },
    n("F8", full: "Example Widgets LLC", runs: [O]) { $0.organization = "Example Widgets LLC"; $0.organizationType = true },
    n("F9", "Ms.", f: "Example", full: "Ms. Example", runs: [P, F]),
    n("F10", g: "Avery", s: "III", full: "Avery III", runs: [G, S]),
    n("F11", g: "太郎", f: "山田", full: "山田太郎", order: .familyNameFirst, delimiter: "", runs: [F, G]),
    n("F12", g: "小明", f: "王", full: "王小明", order: .familyNameFirst, delimiter: "", runs: [F, G]),
    n("F13", g: "민준", f: "김", full: "김민준", order: .familyNameFirst, delimiter: "", runs: [F, G]),
    n("F14", g: "José", m: "Luis", f: "García", full: "José Luis García", runs: [G, M, F]),
    n("F15", g: "太郎", f: "Example", full: "太郎 Example", runs: [G, F]),
    n("F16", g: "Avery", f: "山田", full: "Avery 山田", runs: [G, F]),
    n("F17", full: nil, runs: []),
    n("F18", full: nil, runs: []) { $0.email = "avery@example.com" },
    n("F19", g: "Avery", f: "Example", full: "Avery Example", runs: [G, F]) {
        $0.phonetic = ("AY-ver-ee", "kwin", "ig-ZAM-pul", "")
        $0.phoneticFull = .some("AY-ver-ee kwin ig-ZAM-pul")
    },
    n("F20", g: "太郎", f: "山田", full: "山田太郎", order: .familyNameFirst, delimiter: "", runs: [F, G]) {
        $0.phonetic = ("たろう", "", "やまだ", "")
        $0.phoneticFull = .some("やまだ たろう")
    },
    n("F21", full: "Example Widgets LLC", runs: [O]) {
        $0.organization = "Example Widgets LLC"
        $0.phonetic = ("", "", "", "ig-ZAM-pul WID-jits")
        $0.phoneticFull = .some("ig-ZAM-pul WID-jits")
    },
    n("F22", g: " Avery ", f: "Example ", full: " Avery Example ", runs: [G, F]),
    n("F23", g: "سارة", f: "مثال", full: "سارة مثال", runs: [G, F]),
    n("F24", g: "Анна", m: "Ивановна", f: "Пример", full: "Анна Ивановна Пример", runs: [G, M, F]),
]

@Suite("C-CN-FORMAT formats.md §1.2: CNContactFormatter golden table")
struct ContactFormatterTests {
    @Test("F1–F24: full name, order, delimiter, attributed runs", arguments: nameCases)
    func golden(_ row: NameCase) {
        let c = row.contact()
        #expect(CNContactFormatter.string(from: c, style: .fullName) == row.full)
        #expect(CNContactFormatter.nameOrder(for: c) == row.order)
        #expect(CNContactFormatter.delimiter(for: c) == row.delimiter)
        let f = CNContactFormatter()
        #expect(f.string(from: c) == row.full)
        #expect(f.string(for: c) == row.full)
        let attributed = CNContactFormatter.attributedString(from: c, style: .fullName, defaultAttributes: nil)
        #expect(attributed?.string == row.full)
        var runKeys: [String] = []
        var runTexts: [String] = []
        if let attributed {
            let key = NSAttributedString.Key(CNContactPropertyAttribute)
            attributed.enumerateAttribute(key, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
                if let k = value as? String {
                    runKeys.append(k)
                    runTexts.append((attributed.string as NSString).substring(with: range))
                }
            }
        }
        #expect(runKeys == row.runs)
        if row.id == "F22" { #expect(runTexts == [" Avery ", "Example "]) }
        if case .some(let phonetic) = row.phoneticFull {
            #expect(CNContactFormatter.string(from: c, style: .phoneticFullName) == phonetic)
        } else {
            #expect(CNContactFormatter.string(from: c, style: .phoneticFullName) == nil)
        }
    }

    @Test("§1: default attributes are kept on every run; delimiter runs carry no key")
    func defaultAttributes() {
        let c = person("Avery", "Example")
        let marker = NSAttributedString.Key("ycode.test")
        let s = CNContactFormatter.attributedString(from: c, style: .fullName, defaultAttributes: [marker: 1])!
        var keyed = 0, plain = 0
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, _, _ in
            #expect(attrs[marker] as? Int == 1)
            if attrs[NSAttributedString.Key(CNContactPropertyAttribute)] == nil { plain += 1 } else { keyed += 1 }
        }
        #expect(keyed == 2)
        #expect(plain == 1)
    }
}

// MARK: - Postal addresses

struct PostalCase: CustomTestStringConvertible, Sendable {
    let id: String
    let code: String
    let street, subLocality, city, county, state, postal, country: String
    let expected: String
    var testDescription: String { id }

    func address() -> CNMutablePostalAddress {
        let a = CNMutablePostalAddress()
        a.street = street; a.subLocality = subLocality; a.city = city; a.subAdministrativeArea = county
        a.state = state; a.postalCode = postal; a.country = country; a.isoCountryCode = code
        return a
    }
}

private func p(_ id: String, _ code: String, street: String = "", subLocality: String = "", city: String = "",
               county: String = "", state: String = "", postal: String = "", country: String = "", _ expected: String) -> PostalCase {
    PostalCase(id: id, code: code, street: street, subLocality: subLocality, city: city, county: county, state: state,
               postal: postal, country: country, expected: expected)
}

/// formats.md §2, rows P1–P14 (made-up addresses).
let postalCases: [PostalCase] = [
    p("P1", "us", street: "123 Example Street\nApt 4", city: "Springfield", state: "IL", postal: "62701", country: "United States",
      "123 Example Street\nApt 4\nSpringfield IL 62701\nUnited States"),
    p("P1b", "us", street: "123 Example Street", city: "Springfield", state: "IL", postal: "62701",
      "123 Example Street\nSpringfield IL 62701"),
    p("P1c", "us", street: "123 Example Street\nApt 4", subLocality: "Downtown", city: "Springfield", county: "Sangamon",
      state: "IL", postal: "62701", country: "United States",
      "123 Example Street\nApt 4\nSpringfield IL 62701\nUnited States"),
    p("P2", "de", street: "Beispielstraße 5", city: "Berlin", postal: "10115", country: "Germany",
      "Beispielstraße 5\n10115 Berlin\nGermany"),
    p("P3", "jp", street: "千代田1-1", city: "千代田区", state: "東京都", postal: "100-0001", country: "日本",
      "100-0001\n東京都 千代田区\n千代田1-1\n日本"),
    p("P4", "gb", street: "10 Example Road", city: "London", postal: "SW1A 1AA", country: "United Kingdom",
      "10 Example Road\nLondon\nSW1A 1AA\nUnited Kingdom"),
    p("P5", "fr", street: "5 rue Exemple", city: "Paris", postal: "75001", country: "France",
      "5 rue Exemple\n75001 Paris\nFrance"),
    p("P6", "cn", street: "示例路1号", subLocality: "东城区", city: "北京市", state: "北京市", postal: "100000", country: "中国",
      "中国\n北京市\n北京市 东城区\n示例路1号\n100000"),
    p("P7", "", street: "1 Example Ave", city: "Toronto", state: "ON", postal: "M5V 2T6", country: "Canada",
      "1 Example Ave\nToronto ON M5V 2T6\nCanada"),
    p("P8", "", street: "1 Example Ave", "1 Example Ave"),
    p("P9", "br", street: "Rua Exemplo, 100", subLocality: "Centro", city: "São Paulo", state: "SP", postal: "01000-000",
      country: "Brasil", "Rua Exemplo, 100\nCentro\nSão Paulo SP\n01000-000\nBrasil"),
    p("P10", "au", street: "1 Example St", city: "Sydney", state: "NSW", postal: "2000", country: "Australia",
      "1 Example St\nSydney NSW 2000\nAustralia"),
    p("P11", "in", street: "1 Example Marg", city: "New Delhi", state: "Delhi", postal: "110001", country: "India",
      "1 Example Marg\nNew Delhi 110001\nDelhi\nIndia"),
    p("P12", "kr", street: "세종대로 1", city: "중구", state: "서울특별시", postal: "04524", country: "대한민국",
      "대한민국\n서울특별시\n중구\n세종대로 1\n04524"),
    p("P13", "xx", street: "1 Example St", city: "Exampleville", state: "EX", postal: "00000", country: "Exampleland",
      "1 Example St\nExampleville EX 00000\nExampleland"),
    p("P14", "DE", street: "Beispielstraße 5", city: "Berlin", postal: "10115", country: "Germany",
      "Beispielstraße 5\n10115 Berlin\nGermany"),
]

@Suite("C-CN-FORMAT formats.md §2: CNPostalAddressFormatter golden table")
struct PostalFormatterTests {
    @Test("P1–P14: mailing address layout per country", arguments: postalCases)
    func golden(_ row: PostalCase) {
        let a = row.address()
        #expect(CNPostalAddressFormatter.string(from: a, style: .mailingAddress) == row.expected)
        #expect(CNPostalAddressFormatter().string(from: a) == row.expected)
        #expect(CNPostalAddressFormatter().string(for: a) == row.expected)
    }

    @Test("§2: attributed runs carry CNPostalAddressPropertyAttribute with the field key")
    func attributed() {
        let a = postalCases[0].address()
        let s = CNPostalAddressFormatter.attributedString(from: a, style: .mailingAddress, withDefaultAttributes: [:])
        #expect(s.string == postalCases[0].expected)
        var keys: [String] = []
        let key = NSAttributedString.Key(CNPostalAddressPropertyAttribute)
        s.enumerateAttribute(key, in: NSRange(location: 0, length: s.length)) { value, _, _ in
            if let k = value as? String { keys.append(k) }
        }
        #expect(keys == [CNPostalAddressStreetKey, CNPostalAddressCityKey, CNPostalAddressStateKey,
                         CNPostalAddressPostalCodeKey, CNPostalAddressCountryKey])
    }
}
