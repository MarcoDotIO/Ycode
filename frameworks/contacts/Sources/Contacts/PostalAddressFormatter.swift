// CNPostalAddressFormatter (formats.md §2). The per-country layouts are
// Ycode's own table: the rows of §2 fix the countries they cover; the
// others follow common national practice (open question in the README).

import Foundation

struct AddressLayout {
    /// Lines of (field key, separator placed before it when an earlier
    /// field of the same line is present).
    let lines: [[(String, String)]]

    static let S = CNPostalAddressStreetKey, L = CNPostalAddressSubLocalityKey, C = CNPostalAddressCityKey
    static let A = CNPostalAddressSubAdministrativeAreaKey, T = CNPostalAddressStateKey
    static let Z = CNPostalAddressPostalCodeKey, N = CNPostalAddressCountryKey

    /// street / city state postal / country (US, CA, AU; the fallback).
    static let northAmerican = AddressLayout(lines: [[(S, "")], [(C, ""), (T, " "), (Z, " ")], [(N, "")]])
    /// street / postal city / country.
    static let postalCity = AddressLayout(lines: [[(S, "")], [(Z, ""), (C, " ")], [(N, "")]])

    static let table: [String: AddressLayout] = [
        "us": northAmerican, "ca": northAmerican, "au": northAmerican, "nz": AddressLayout(lines: [[(S, "")], [(L, "")], [(C, ""), (Z, " ")], [(N, "")]]),
        "de": postalCity, "at": postalCity, "ch": postalCity, "fr": postalCity, "nl": postalCity, "be": postalCity,
        "dk": postalCity, "no": postalCity, "se": postalCity, "fi": postalCity, "pl": postalCity, "pt": postalCity,
        "es": AddressLayout(lines: [[(S, "")], [(Z, ""), (C, " ")], [(T, "")], [(N, "")]]),
        "it": AddressLayout(lines: [[(S, "")], [(Z, ""), (C, " "), (T, " ")], [(N, "")]]),
        "gb": AddressLayout(lines: [[(S, "")], [(L, "")], [(C, "")], [(Z, "")], [(N, "")]]),
        "ie": AddressLayout(lines: [[(S, "")], [(L, "")], [(C, "")], [(T, "")], [(Z, "")], [(N, "")]]),
        "jp": AddressLayout(lines: [[(Z, "")], [(T, ""), (C, " "), (L, " ")], [(S, "")], [(N, "")]]),
        "cn": AddressLayout(lines: [[(N, "")], [(T, "")], [(C, ""), (L, " ")], [(S, "")], [(Z, "")]]),
        "kr": AddressLayout(lines: [[(N, "")], [(T, "")], [(C, ""), (L, " ")], [(S, "")], [(Z, "")]]),
        "br": AddressLayout(lines: [[(S, "")], [(L, "")], [(C, ""), (T, " ")], [(Z, "")], [(N, "")]]),
        "in": AddressLayout(lines: [[(S, "")], [(L, "")], [(C, ""), (Z, " ")], [(T, "")], [(N, "")]]),
        "mx": AddressLayout(lines: [[(S, "")], [(L, "")], [(Z, ""), (C, " "), (T, ", ")], [(N, "")]]),
    ]

    static func layout(for address: CNPostalAddress) -> AddressLayout {
        let code = address.isoCountryCode.isEmpty
            ? CNContactStore.ycodeDefaultConfiguration.countryCode
            : address.isoCountryCode
        return table[code.lowercased()] ?? northAmerican
    }
}

public class CNPostalAddressFormatter: Formatter, @unchecked Sendable {
    public var style: CNPostalAddressFormatterStyle = .mailingAddress

    public override init() { super.init() }
    public required init?(coder: NSCoder) { super.init(coder: coder) }

    /// The pieces of the formatted address: (field key or nil, text).
    static func pieces(_ address: CNPostalAddress) -> [(String?, String)] {
        var out: [(String?, String)] = []
        for line in AddressLayout.layout(for: address).lines {
            var lineOut: [(String?, String)] = []
            for (key, sep) in line {
                let v = address.field(key)
                if v.isEmpty { continue }
                if !lineOut.isEmpty && !sep.isEmpty { lineOut.append((nil, sep)) }
                lineOut.append((key, v))
            }
            if lineOut.isEmpty { continue }
            if !out.isEmpty { out.append((nil, "\n")) }
            out.append(contentsOf: lineOut)
        }
        return out
    }

    public class func string(from postalAddress: CNPostalAddress, style: CNPostalAddressFormatterStyle) -> String {
        pieces(postalAddress).map(\.1).joined()
    }

    public class func attributedString(from postalAddress: CNPostalAddress, style: CNPostalAddressFormatterStyle,
                                       withDefaultAttributes attributes: [AnyHashable: Any] = [:]) -> NSAttributedString {
        var base: [NSAttributedString.Key: Any] = [:]
        for (k, v) in attributes {
            if let s = k as? String { base[NSAttributedString.Key(s)] = v }
            else if let key = k as? NSAttributedString.Key { base[key] = v }
        }
        let out = NSMutableAttributedString(string: "")
        for (key, text) in pieces(postalAddress) {
            var attrs = base
            if let key {
                attrs[NSAttributedString.Key(CNPostalAddressPropertyAttribute)] = key
                attrs[NSAttributedString.Key(CNPostalAddressLocalizedPropertyNameAttribute)] = CNPostalAddress.localizedString(forKey: key)
            }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        return out
    }

    public func string(from postalAddress: CNPostalAddress) -> String {
        CNPostalAddressFormatter.string(from: postalAddress, style: style)
    }

    public func attributedString(from postalAddress: CNPostalAddress, withDefaultAttributes attributes: [AnyHashable: Any] = [:]) -> NSAttributedString {
        CNPostalAddressFormatter.attributedString(from: postalAddress, style: style, withDefaultAttributes: attributes)
    }

    public override func string(for obj: Any?) -> String? {
        guard let a = obj as? CNPostalAddress else { return nil }
        return string(from: a)
    }
}
