// CNContactVCardSerialization (formats.md §3): Ycode's own vCard 3.0 writer
// and a lenient reader for vCard 2.1, 3.0 and 4.0 (RFC 2426, RFC 6350).

import Foundation

public final class CNContactVCardSerialization: NSObject {
    /// The keys the writer reads: every property except note and images.
    public class func descriptorForRequiredKeys() -> CNKeyDescriptor {
        CNAggregateKeyDescriptor(kind: "vCard", keys: vCardKeys)
    }

    /// vCard 3.0 data for the contacts (UTF-8, CRLF). A contact without
    /// the required keys is not written: the call logs and throws
    /// (formats.md §3; Apple returns nil there).
    public class func data(with contacts: [Any]) throws -> Data {
        var out = ""
        for item in contacts {
            guard let contact = item as? CNContact else { continue }
            guard vCardKeys.isSubset(of: contact.available) else {
                let msg = "Exception writing contacts to vCard (data): \(CNException.notFetched())\n"
                FileHandle.standardError.write(msg.data(using: .utf8)!)
                throw CNError(.vCardSummarizationError)
            }
            var writer = VCardWriter(contact.data)
            out += writer.card()
        }
        return out.data(using: .utf8)!
    }

    /// Contacts read from vCard data. Unreadable input gives no contacts
    /// and no error (I8–I10).
    public class func contacts(with data: Data) throws -> [CNContact] {
        VCardReader.read(data).map { d in
            CNContact(identifier: newPersonIdentifier(), data: d, available: allContactKeys)
        }
    }
}

// MARK: - Shared tables

enum VCardTables {
    /// Known instant-message services: X- property name and URI scheme.
    /// AIM and Jabber are the spec's; the rest are Ycode's choice.
    static let imServices: [(service: String, property: String, scheme: String)] = [
        (CNInstantMessageServiceAIM, "X-AIM", "aim"),
        (CNInstantMessageServiceJabber, "X-JABBER", "xmpp"),
        (CNInstantMessageServiceICQ, "X-ICQ", "aim"),
        (CNInstantMessageServiceMSN, "X-MSN", "msnim"),
        (CNInstantMessageServiceYahoo, "X-YAHOO", "ymsgr"),
        (CNInstantMessageServiceSkype, "X-SKYPE", "skype"),
        (CNInstantMessageServiceQQ, "X-QQ", "x-apple"),
        (CNInstantMessageServiceGoogleTalk, "X-GOOGLE-TALK", "xmpp"),
        (CNInstantMessageServiceFacebook, "X-FACEBOOK", "xmpp"),
        (CNInstantMessageServiceGaduGadu, "X-GADUGADU", "x-apple"),
    ]

    static let socialServices: [String] = [
        CNSocialProfileServiceFacebook, CNSocialProfileServiceFlickr, CNSocialProfileServiceGameCenter,
        CNSocialProfileServiceLinkedIn, CNSocialProfileServiceMySpace, CNSocialProfileServiceSinaWeibo,
        CNSocialProfileServiceTencentWeibo, CNSocialProfileServiceTwitter, CNSocialProfileServiceYelp,
    ]

    /// Phone label → vCard types (formats.md §3.1; work fax and pager are Ycode's).
    static let phoneTypes: [String: [String]] = [
        CNLabelPhoneNumberMobile: ["CELL", "VOICE"],
        CNLabelHome: ["HOME", "VOICE"],
        CNLabelPhoneNumberiPhone: ["IPHONE", "CELL", "VOICE"],
        CNLabelWork: ["WORK", "VOICE"],
        CNLabelPhoneNumberHomeFax: ["HOME", "FAX"],
        CNLabelPhoneNumberWorkFax: ["WORK", "FAX"],
        CNLabelPhoneNumberMain: ["MAIN"],
        CNLabelPhoneNumberPager: ["PAGER"],
    ]

    static let homeWork: [String: [String]] = [CNLabelHome: ["HOME"], CNLabelWork: ["WORK"]]

    static let calendarNames: [(Calendar.Identifier, String)] = [
        (.gregorian, "gregorian"), (.buddhist, "buddhist"), (.chinese, "chinese"), (.coptic, "coptic"),
        (.ethiopicAmeteMihret, "ethiopic"), (.ethiopicAmeteAlem, "ethiopic-amete-alem"), (.hebrew, "hebrew"),
        (.indian, "indian"), (.islamic, "islamic"), (.islamicCivil, "islamic-civil"),
        (.islamicTabular, "islamic-tbla"), (.islamicUmmAlQura, "islamic-umalqura"), (.japanese, "japanese"),
        (.persian, "persian"), (.republicOfChina, "roc"),
    ]

    static func calendarName(_ id: Calendar.Identifier) -> String {
        calendarNames.first { $0.0 == id }?.1 ?? "gregorian"
    }

    static func calendar(named name: String) -> Calendar? {
        calendarNames.first { $0.1 == name.lowercased() }.map { Calendar(identifier: $0.0) }
    }
}

// MARK: - Writer

struct VCardWriter {
    let d: ContactData
    var lines: [String] = []
    var item = 0

    init(_ d: ContactData) { self.d = d }

    static let productID = "-//Ycode//Ycode Contacts 1.0//EN"

    static func escape(_ s: String, structured: Bool = false) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r\n": out += "\\n"
            case ";" where structured: out += "\\;"
            case "," where structured: out += "\\,"
            default: out.append(ch)
            }
        }
        return out
    }

    mutating func nextGroup() -> String {
        item += 1
        return "item\(item)."
    }

    static func params(_ types: [String]) -> String {
        types.map { ";type=\($0)" }.joined()
    }

    /// A labeled line: predefined labels with vCard types become types,
    /// any other label goes into an itemN group with X-ABLabel.
    mutating func labeled(_ name: String, base: [String], label: String?, types: [String: [String]],
                          pref: Bool, value: String, extra: [String] = []) {
        let prefType = pref ? ["pref"] : []
        if let label, let t = types[label] {
            lines.append(name + VCardWriter.params(base + t + prefType) + ":" + value)
            lines.append(contentsOf: extra)
        } else if label == nil || label == "" {
            lines.append(name + VCardWriter.params(base + prefType) + ":" + value)
            lines.append(contentsOf: extra)
        } else {
            let g = nextGroup()
            lines.append(g + name + VCardWriter.params(base + prefType) + ":" + value)
            lines.append(contentsOf: extra.map { g + $0 })
            lines.append(g + "X-ABLabel:" + label!)
        }
    }

    static func dateText(_ c: DateComponents) -> (String, omitYear: Bool) {
        let month = c.month ?? 1, day = c.day ?? 1
        if let year = c.year, year != NSDateComponentUndefined {
            return (String(format: "%04d-%02d-%02d", year, month, day), false)
        }
        return (String(format: "1604-%02d-%02d", month, day), true)
    }

    mutating func card() -> String {
        lines = ["BEGIN:VCARD", "VERSION:3.0", "PRODID:" + VCardWriter.productID]
        let n = [d.familyName, d.givenName, d.middleName, d.namePrefix, d.nameSuffix]
        lines.append("N:" + n.map { VCardWriter.escape($0, structured: true) }.joined(separator: ";"))
        let full = CNContact(identifier: "", data: d, available: allContactKeys)
        if let fn = CNContactFormatter.string(from: full, style: .fullName) {
            lines.append("FN:" + VCardWriter.escape(fn))
        }
        func text(_ name: String, _ v: String) {
            if !v.isEmpty { lines.append(name + ":" + VCardWriter.escape(v)) }
        }
        text("NICKNAME", d.nickname)
        text("X-MAIDENNAME", d.previousFamilyName)
        text("X-PHONETIC-FIRST-NAME", d.phoneticGivenName)
        text("X-PHONETIC-MIDDLE-NAME", d.phoneticMiddleName)
        text("X-PHONETIC-LAST-NAME", d.phoneticFamilyName)
        text("X-PHONETIC-ORG", d.phoneticOrganizationName)
        if !d.organizationName.isEmpty || !d.departmentName.isEmpty {
            lines.append("ORG:" + VCardWriter.escape(d.organizationName, structured: true) + ";"
                         + VCardWriter.escape(d.departmentName, structured: true))
        }
        text("TITLE", d.jobTitle)

        for (i, lv) in d.emailAddresses.enumerated() {
            labeled("EMAIL", base: ["INTERNET"], label: lv.label, types: VCardTables.homeWork, pref: i == 0,
                    value: VCardWriter.escape(String(describing: lv.value)))
        }
        for (i, lv) in d.phoneNumbers.enumerated() {
            labeled("TEL", base: [], label: lv.label, types: VCardTables.phoneTypes, pref: i == 0,
                    value: VCardWriter.escape(lv.value.stringValue))
        }
        for (i, lv) in d.postalAddresses.enumerated() {
            let a = lv.value
            let parts = ["", "", a.street, a.city, a.state, a.postalCode, a.country]
            let value = parts.map { VCardWriter.escape($0, structured: true) }.joined(separator: ";")
            let g = nextGroup()
            var types: [String] = []
            var custom: String?
            if let label = lv.label, let t = VCardTables.homeWork[label] { types = t } else if let label = lv.label, !label.isEmpty { custom = label }
            if i == 0 { types.append("pref") }
            lines.append(g + "ADR" + VCardWriter.params(types) + ":" + value)
            if !a.isoCountryCode.isEmpty { lines.append(g + "X-ABADR:" + a.isoCountryCode.lowercased()) }
            if let custom { lines.append(g + "X-ABLabel:" + custom) }
        }
        for lv in d.socialProfiles {
            let p = lv.value
            var params = ""
            if !p.service.isEmpty {
                let known = VCardTables.socialServices.contains { $0.caseInsensitiveCompare(p.service) == .orderedSame }
                params += ";type=" + (known ? p.service.lowercased() : p.service)
            }
            if !p.username.isEmpty { params += ";x-user=" + p.username }
            if !p.userIdentifier.isEmpty { params += ";x-userid=" + p.userIdentifier }
            let value = p.urlString.isEmpty ? "x-apple:" + p.username : p.urlString
            lines.append("X-SOCIALPROFILE" + params + ":" + value)
        }
        for (i, lv) in d.urlAddresses.enumerated() {
            labeled("URL", base: [], label: lv.label, types: VCardTables.homeWork, pref: i == 0,
                    value: VCardWriter.escape(String(describing: lv.value)))
        }
        if let b = d.birthday {
            let (t, omit) = VCardWriter.dateText(b)
            lines.append(omit ? "BDAY;X-APPLE-OMIT-YEAR=1604:" + t : "BDAY:" + t)
        }
        if let b = d.nonGregorianBirthday {
            let cal = VCardTables.calendarName(b.calendar?.identifier ?? .gregorian)
            let number = String(format: "%04d%02d%02d", b.year ?? 0, b.month ?? 0, b.day ?? 0)
            lines.append("X-ALTBDAY;CALSCALE=\(cal):-" + number)
        }
        for (i, lv) in d.instantMessageAddresses.enumerated() {
            let im = lv.value
            let known = VCardTables.imServices.first { $0.service.caseInsensitiveCompare(im.service) == .orderedSame }
            var types: [String] = []
            var custom: String?
            if let label = lv.label, let t = VCardTables.homeWork[label] { types = t } else if let label = lv.label, !label.isEmpty { custom = label }
            if i == 0 { types.append("pref") }
            let user = VCardWriter.escape(im.username)
            if let known {
                lines.append(known.property + VCardWriter.params(types) + ":" + user)
            }
            let impp = "IMPP;X-SERVICE-TYPE=\(known?.service ?? im.service)" + VCardWriter.params(types)
                + ":\(known?.scheme ?? "x-apple"):" + user
            if let custom {
                let g = nextGroup()
                lines.append(g + impp)
                lines.append(g + "X-ABLabel:" + custom)
            } else {
                lines.append(impp)
            }
        }
        for (i, lv) in d.dates.enumerated() {
            let (t, omit) = VCardWriter.dateText(dateComponents(lv.value))
            let g = nextGroup()
            let params = (omit ? ";X-APPLE-OMIT-YEAR=1604" : "") + (i == 0 ? ";type=pref" : "")
            lines.append(g + "X-ABDATE" + params + ":" + t)
            if let label = lv.label { lines.append(g + "X-ABLabel:" + label) }
        }
        for (i, lv) in d.contactRelations.enumerated() {
            let g = nextGroup()
            lines.append(g + "X-ABRELATEDNAMES" + (i == 0 ? ";type=pref" : "") + ":" + VCardWriter.escape(lv.value.name))
            if let label = lv.label { lines.append(g + "X-ABLabel:" + label) }
        }
        if d.contactType == .organization { lines.append("X-ABShowAs:COMPANY") }
        lines.append("END:VCARD")
        return lines.map { $0 + "\r\n" }.joined()
    }
}

// MARK: - Reader

struct VCardLine {
    var group: String?
    var name: String          // upper case
    var params: [(name: String, value: String?)]
    var value: String

    func param(_ n: String) -> String? {
        params.first { $0.name.caseInsensitiveCompare(n) == .orderedSame }?.value ?? nil
    }

    /// TYPE values (`type=…`, comma lists, quotes) and bare 2.1 tokens, upper case.
    var types: [String] {
        var out: [String] = []
        for p in params {
            if let v = p.value {
                if p.name.caseInsensitiveCompare("TYPE") == .orderedSame {
                    out += v.replacingOccurrences(of: "\"", with: "").split(separator: ",").map { $0.uppercased() }
                }
            } else {
                out.append(p.name.uppercased())
            }
        }
        return out
    }

    static let knownParams: Set<String> = ["TYPE", "PREF", "CHARSET", "ENCODING", "X-SERVICE-TYPE", "X-APPLE-OMIT-YEAR",
                                           "CALSCALE", "X-USER", "X-USERID", "X-ABLABEL"]

    /// The first NAME=value parameter the reader does not know; a lenient
    /// reading turns it into the label (formats.md §3.2 I2).
    var unknownParameterName: String? {
        params.first { $0.value != nil && !VCardLine.knownParams.contains($0.name.uppercased()) }?.name
    }
}

enum VCardReader {
    static func read(_ data: Data) -> [ContactData] {
        guard !data.isEmpty else { return [] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let physical = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        // Unfold (RFC 2425 §5.8.1): a line starting with a space or tab continues the previous one.
        var logical: [String] = []
        for line in physical {
            if let first = line.first, first == " " || first == "\t", !logical.isEmpty {
                logical[logical.count - 1] += String(line.dropFirst())
            } else {
                logical.append(line)
            }
        }
        // Quoted-printable soft breaks: a QP value ending in "=" continues.
        var joined: [String] = []
        var i = 0
        while i < logical.count {
            var line = logical[i]
            if line.uppercased().contains("QUOTED-PRINTABLE") {
                while line.hasSuffix("="), i + 1 < logical.count {
                    line = String(line.dropLast()) + logical[i + 1]
                    i += 1
                }
            }
            joined.append(line)
            i += 1
        }

        var cards: [ContactData] = []
        var current: [VCardLine]?
        for raw in joined {
            guard let line = parse(raw) else { continue }
            if line.name == "BEGIN" && line.value.caseInsensitiveCompare("VCARD") == .orderedSame {
                current = []
            } else if line.name == "END" && line.value.caseInsensitiveCompare("VCARD") == .orderedSame {
                if let c = current { cards.append(build(c)) }
                current = nil
            } else {
                current?.append(line)
            }
        }
        return cards
    }

    static func parse(_ raw: String) -> VCardLine? {
        // Split at the first ':' outside quotes.
        var inQuote = false
        var colon: String.Index?
        for idx in raw.indices {
            let ch = raw[idx]
            if ch == "\"" { inQuote.toggle() }
            if ch == ":" && !inQuote { colon = idx; break }
        }
        guard let colon else { return nil }
        let head = String(raw[..<colon])
        var value = String(raw[raw.index(after: colon)...])
        var pieces: [String] = []
        var cur = ""
        inQuote = false
        for ch in head {
            if ch == "\"" { inQuote.toggle() }
            if ch == ";" && !inQuote { pieces.append(cur); cur = ""; continue }
            cur.append(ch)
        }
        pieces.append(cur)
        var nameField = pieces.removeFirst()
        var group: String?
        if let dot = nameField.firstIndex(of: ".") {
            group = String(nameField[..<dot])
            nameField = String(nameField[nameField.index(after: dot)...])
        }
        let params: [(name: String, value: String?)] = pieces.filter { !$0.isEmpty }.map { p in
            if let eq = p.firstIndex(of: "=") {
                return (String(p[..<eq]), String(p[p.index(after: eq)...]))
            }
            return (p, nil)
        }
        var line = VCardLine(group: group?.lowercased(), name: nameField.uppercased(), params: params, value: value)
        if let enc = line.param("ENCODING"), enc.caseInsensitiveCompare("QUOTED-PRINTABLE") == .orderedSame {
            value = decodeQuotedPrintable(value, charset: line.param("CHARSET"))
            line.value = value
        } else if line.params.contains(where: { $0.value == nil && $0.name.caseInsensitiveCompare("QUOTED-PRINTABLE") == .orderedSame }) {
            line.value = decodeQuotedPrintable(value, charset: line.param("CHARSET"))
        }
        return line
    }

    static func decodeQuotedPrintable(_ s: String, charset: String?) -> String {
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        func hex(_ b: UInt8) -> UInt8? {
            switch b {
            case 48...57: return b - 48
            case 65...70: return b - 55
            case 97...102: return b - 87
            default: return nil
            }
        }
        while i < u.count {
            if u[i] == 61, i + 2 < u.count, let h = hex(u[i + 1]), let l = hex(u[i + 2]) {
                bytes.append(h << 4 | l)
                i += 3
            } else {
                bytes.append(u[i])
                i += 1
            }
        }
        if let cs = charset?.uppercased(), cs.contains("8859") || cs.contains("LATIN") {
            return String(data: Data(bytes), encoding: .isoLatin1) ?? s
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let ch = it.next() {
            if ch == "\\" {
                guard let n = it.next() else { out.append(ch); break }
                switch n {
                case "n", "N": out.append("\n")
                default: out.append(n)
                }
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Splits a structured value at unescaped ';' and unescapes the parts.
    static func components(_ s: String) -> [String] {
        var parts: [String] = []
        var cur = ""
        var escaped = false
        for ch in s {
            if escaped { cur.append("\\"); cur.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == ";" { parts.append(unescape(cur)); cur = ""; continue }
            cur.append(ch)
        }
        if escaped { cur.append("\\") }
        parts.append(unescape(cur))
        return parts
    }

    static func parseDate(_ s: String, omitYear: Bool) -> DateComponents? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if let tIdx = t.firstIndex(of: "T") { t = String(t[..<tIdx]) }
        var year: Int?, month: Int?, day: Int?
        if t.hasPrefix("--") {
            let digits = t.dropFirst(2).filter(\.isNumber)
            guard digits.count == 4 else { return nil }
            month = Int(digits.prefix(2)); day = Int(digits.suffix(2))
        } else {
            let digits = t.filter(\.isNumber)
            guard digits.count == 8 else { return nil }
            year = Int(digits.prefix(4)); month = Int(digits.dropFirst(4).prefix(2)); day = Int(digits.suffix(2))
        }
        if omitYear { year = nil }
        var c = DateComponents()
        c.calendar = Calendar(identifier: .gregorian)
        c.year = year
        c.month = month
        c.day = day
        return c
    }

    static func phoneLabel(_ types: [String]) -> String {
        let t = Set(types)
        if t.contains("IPHONE") { return CNLabelPhoneNumberiPhone }
        if t.contains("FAX") {
            if t.contains("HOME") { return CNLabelPhoneNumberHomeFax }
            if t.contains("WORK") { return CNLabelPhoneNumberWorkFax }
            return CNLabelPhoneNumberOtherFax
        }
        if t.contains("CELL") || t.contains("MOBILE") { return CNLabelPhoneNumberMobile }
        if t.contains("PAGER") { return CNLabelPhoneNumberPager }
        if t.contains("MAIN") { return CNLabelPhoneNumberMain }
        if t.contains("HOME") { return CNLabelHome }
        if t.contains("WORK") { return CNLabelWork }
        if t.contains("OTHER") { return CNLabelOther }
        return ""
    }

    static func homeWorkLabel(_ types: [String]) -> String? {
        let t = Set(types)
        if t.contains("HOME") { return CNLabelHome }
        if t.contains("WORK") { return CNLabelWork }
        if t.contains("OTHER") { return CNLabelOther }
        return nil
    }

    static func build(_ lines: [VCardLine]) -> ContactData {
        var d = ContactData()
        var groupLabels: [String: String] = [:]
        var groupCountry: [String: String] = [:]
        for l in lines {
            guard let g = l.group else { continue }
            if l.name == "X-ABLABEL" { groupLabels[g] = unescape(l.value) }
            if l.name == "X-ABADR" { groupCountry[g] = l.value }
        }
        func label(_ l: VCardLine, _ fromTypes: String?) -> String? {
            if let g = l.group, let lab = groupLabels[g] { return lab }
            if let unknown = l.unknownParameterName { return unknown }
            return fromTypes
        }
        var fn: String?
        var sawName = false
        var ims: [CNLabeledValue<CNInstantMessageAddress>] = []
        func addIM(_ service: String, _ user: String, _ lab: String?) {
            if ims.contains(where: { $0.value.service.caseInsensitiveCompare(service) == .orderedSame && $0.value.username == user }) { return }
            ims.append(CNLabeledValue(label: lab, value: CNInstantMessageAddress(username: user, service: service)))
        }

        for l in lines {
            let v = l.value
            switch l.name {
            case "N":
                let c = components(v)
                func at(_ i: Int) -> String { i < c.count ? c[i] : "" }
                d.familyName = at(0); d.givenName = at(1); d.middleName = at(2); d.namePrefix = at(3); d.nameSuffix = at(4)
                sawName = sawName || c.contains { !$0.isEmpty }
            case "FN": fn = unescape(v)
            case "NICKNAME": d.nickname = unescape(v)
            case "X-MAIDENNAME": d.previousFamilyName = unescape(v)
            case "X-PHONETIC-FIRST-NAME": d.phoneticGivenName = unescape(v)
            case "X-PHONETIC-MIDDLE-NAME": d.phoneticMiddleName = unescape(v)
            case "X-PHONETIC-LAST-NAME": d.phoneticFamilyName = unescape(v)
            case "X-PHONETIC-ORG": d.phoneticOrganizationName = unescape(v)
            case "ORG":
                let c = components(v)
                d.organizationName = c.first ?? ""
                d.departmentName = c.count > 1 ? c[1] : ""
            case "TITLE": d.jobTitle = unescape(v)
            case "NOTE": d.note = unescape(v)
            case "EMAIL":
                d.emailAddresses.append(CNLabeledValue(label: label(l, homeWorkLabel(l.types)) ?? "", value: NSString(string: unescape(v))))
            case "TEL":
                d.phoneNumbers.append(CNLabeledValue(label: label(l, phoneLabel(l.types)), value: CNPhoneNumber(stringValue: unescape(v))))
            case "ADR":
                let c = components(v)
                func at(_ i: Int) -> String { i < c.count ? c[i] : "" }
                let a = CNMutablePostalAddress()
                a.street = [at(2), at(1), at(0)].filter { !$0.isEmpty }.joined(separator: "\n")
                a.city = at(3); a.state = at(4); a.postalCode = at(5); a.country = at(6)
                if let g = l.group, let iso = groupCountry[g] { a.isoCountryCode = iso }
                d.postalAddresses.append(CNLabeledValue(label: label(l, homeWorkLabel(l.types)) ?? "", value: a))
            case "URL":
                d.urlAddresses.append(CNLabeledValue(label: label(l, homeWorkLabel(l.types)) ?? "", value: NSString(string: unescape(v))))
            case "X-SOCIALPROFILE":
                let service = l.param("TYPE")?.replacingOccurrences(of: "\"", with: "") ?? ""
                var url = unescape(v)
                var user = l.param("X-USER") ?? ""
                if url.lowercased().hasPrefix("x-apple:") {
                    if user.isEmpty { user = String(url.dropFirst("x-apple:".count)) }
                    url = ""
                }
                let p = CNSocialProfile(urlString: url, username: user, userIdentifier: l.param("X-USERID"), service: service)
                d.socialProfiles.append(CNLabeledValue(label: "", value: p))
            case "BDAY":
                d.birthday = parseDate(v, omitYear: l.param("X-APPLE-OMIT-YEAR") != nil)
            case "X-ALTBDAY":
                let digits = v.filter(\.isNumber)
                if digits.count >= 5, let cal = VCardTables.calendar(named: l.param("CALSCALE") ?? "") {
                    var c = DateComponents()
                    c.calendar = cal
                    c.year = Int(digits.dropLast(4))
                    c.month = Int(digits.suffix(4).prefix(2))
                    c.day = Int(digits.suffix(2))
                    d.nonGregorianBirthday = c
                }
            case "IMPP":
                let raw = unescape(v)
                let user = raw.firstIndex(of: ":").map { String(raw[raw.index(after: $0)...]) } ?? raw
                let scheme = raw.firstIndex(of: ":").map { String(raw[..<$0]).lowercased() } ?? ""
                let service = l.param("X-SERVICE-TYPE")
                    ?? VCardTables.imServices.first { $0.scheme == scheme }?.service ?? scheme
                addIM(service, user, label(l, homeWorkLabel(l.types)))
            case "X-ABDATE":
                if let c = parseDate(v, omitYear: l.param("X-APPLE-OMIT-YEAR") != nil) {
                    d.dates.append(CNLabeledValue(label: label(l, homeWorkLabel(l.types)), value: nsDateComponents(c)))
                }
            case "X-ABRELATEDNAMES":
                d.contactRelations.append(CNLabeledValue(label: label(l, homeWorkLabel(l.types)),
                                                         value: CNContactRelation(name: unescape(v))))
            case "X-ABSHOWAS":
                if v.uppercased() == "COMPANY" { d.contactType = .organization }
            case "PHOTO":
                var payload = v
                if payload.lowercased().hasPrefix("data:"), let comma = payload.firstIndex(of: ",") {
                    payload = String(payload[payload.index(after: comma)...])
                }
                if let data = Data(base64Encoded: payload.filter { !$0.isWhitespace }) { d.imageData = data }
            default:
                if let known = VCardTables.imServices.first(where: { $0.property == l.name }) {
                    addIM(known.service, unescape(v), label(l, homeWorkLabel(l.types)))
                }
            }
        }
        d.instantMessageAddresses = ims
        if !sawName, let fn, d.contactType == .person {
            let words = fn.split(whereSeparator: \.isWhitespace).map(String.init)
            if words.count == 1 { d.givenName = words[0] }
            if words.count >= 2 {
                d.givenName = words[0]
                d.familyName = words[words.count - 1]
                d.middleName = words.dropFirst().dropLast().joined(separator: " ")
            }
        }
        return d
    }
}
