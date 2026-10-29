// Ycode's own SQLite schema for the contacts database (design.md §4), the
// fresh-device seed (Ycode's made-up records; the fixed container and group
// identifiers of interface.md §2.3) and the change journal.

import Foundation

/// The local container's identifier on every fresh device (interface.md §2.3).
let localContainerIdentifier = "BC25D81B-8966-48EF-8FF9-D7389B6F89BD"
let seedFriendsGroupIdentifier = "CCDA4756-71B4-4B25-8DD2-D3DA109F4561"
let seedWorkGroupIdentifier = "2D6515F9-AE3D-460D-98A2-EFE81516739D"

// MARK: - DateComponents bridging (portable)

func dateComponents(_ ns: NSDateComponents) -> DateComponents {
    var c = DateComponents()
    c.calendar = ns.calendar
    if ns.era != NSDateComponentUndefined { c.era = ns.era }
    if ns.year != NSDateComponentUndefined { c.year = ns.year }
    if ns.month != NSDateComponentUndefined { c.month = ns.month }
    if ns.day != NSDateComponentUndefined { c.day = ns.day }
    return c
}

func nsDateComponents(_ c: DateComponents) -> NSDateComponents {
    let ns = NSDateComponents()
    ns.calendar = c.calendar
    if let v = c.era { ns.era = v }
    if let v = c.year { ns.year = v }
    if let v = c.month { ns.month = v }
    if let v = c.day { ns.day = v }
    return ns
}

// MARK: - Value encoding

enum Codec {
    static func json(_ obj: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ text: String?) -> [String: Any] {
        guard let text, let o = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [:] }
        return o
    }

    static func encode(_ c: DateComponents?) -> String? {
        guard let c else { return nil }
        var o: [String: Any] = [:]
        if let cal = c.calendar { o["calendar"] = VCardTables.calendarName(cal.identifier) }
        if let v = c.era { o["era"] = v }
        if let v = c.year { o["year"] = v }
        if let v = c.month { o["month"] = v }
        if let v = c.day { o["day"] = v }
        return json(o)
    }

    static func decodeComponents(_ text: String?) -> DateComponents? {
        guard let text else { return nil }
        let o = object(text)
        var c = DateComponents()
        if let cal = o["calendar"] as? String { c.calendar = VCardTables.calendar(named: cal) }
        c.era = o["era"] as? Int
        c.year = o["year"] as? Int
        c.month = o["month"] as? Int
        c.day = o["day"] as? Int
        return c
    }

    static func encode(_ a: CNPostalAddress) -> String {
        var o: [String: Any] = [:]
        for k in CNPostalAddress.fieldKeys { o[k] = a.field(k) }
        return json(o)
    }

    static func postal(_ text: String) -> CNPostalAddress {
        let o = object(text)
        let a = CNMutablePostalAddress()
        for k in CNPostalAddress.fieldKeys { a.setField(k, o[k] as? String ?? "") }
        // swiftlint:disable:next force_cast - copy() of a CNMutablePostalAddress is a CNPostalAddress
        return a.copy() as! CNPostalAddress
    }
}

/// The multi-valued properties: key, encode, decode.
enum MultiValue {
    static let keys = [
        CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactUrlAddressesKey,
        CNContactRelationsKey, CNContactSocialProfilesKey, CNContactInstantMessageAddressesKey, CNContactDatesKey,
    ]

    /// (identifier, label, encoded value) rows of one property.
    static func rows(_ d: ContactData, _ key: String) -> [(String, String?, String)] {
        switch key {
        case CNContactPhoneNumbersKey: return d.phoneNumbers.map { ($0.identifier, $0.label, $0.value.stringValue) }
        case CNContactEmailAddressesKey: return d.emailAddresses.map { ($0.identifier, $0.label, String(describing: $0.value)) }
        case CNContactPostalAddressesKey: return d.postalAddresses.map { ($0.identifier, $0.label, Codec.encode($0.value)) }
        case CNContactUrlAddressesKey: return d.urlAddresses.map { ($0.identifier, $0.label, String(describing: $0.value)) }
        case CNContactRelationsKey: return d.contactRelations.map { ($0.identifier, $0.label, $0.value.name) }
        case CNContactSocialProfilesKey:
            return d.socialProfiles.map {
                ($0.identifier, $0.label, Codec.json(["urlString": $0.value.urlString, "username": $0.value.username,
                                                      "userIdentifier": $0.value.userIdentifier, "service": $0.value.service]))
            }
        case CNContactInstantMessageAddressesKey:
            return d.instantMessageAddresses.map {
                ($0.identifier, $0.label, Codec.json(["username": $0.value.username, "service": $0.value.service]))
            }
        case CNContactDatesKey:
            return d.dates.map { ($0.identifier, $0.label, Codec.encode(dateComponents($0.value)) ?? "{}") }
        default: return []
        }
    }

    static func add(_ d: inout ContactData, _ key: String, _ id: String, _ label: String?, _ v: String) {
        switch key {
        case CNContactPhoneNumbersKey:
            d.phoneNumbers.append(CNLabeledValue(identifier: id, label: label, value: CNPhoneNumber(stringValue: v)))
        case CNContactEmailAddressesKey:
            d.emailAddresses.append(CNLabeledValue(identifier: id, label: label, value: NSString(string: v)))
        case CNContactPostalAddressesKey:
            d.postalAddresses.append(CNLabeledValue(identifier: id, label: label, value: Codec.postal(v)))
        case CNContactUrlAddressesKey:
            d.urlAddresses.append(CNLabeledValue(identifier: id, label: label, value: NSString(string: v)))
        case CNContactRelationsKey:
            d.contactRelations.append(CNLabeledValue(identifier: id, label: label, value: CNContactRelation(name: v)))
        case CNContactSocialProfilesKey:
            let o = Codec.object(v)
            d.socialProfiles.append(CNLabeledValue(identifier: id, label: label, value: CNSocialProfile(
                urlString: o["urlString"] as? String, username: o["username"] as? String,
                userIdentifier: o["userIdentifier"] as? String, service: o["service"] as? String)))
        case CNContactInstantMessageAddressesKey:
            let o = Codec.object(v)
            d.instantMessageAddresses.append(CNLabeledValue(identifier: id, label: label, value: CNInstantMessageAddress(
                username: o["username"] as? String ?? "", service: o["service"] as? String ?? "")))
        case CNContactDatesKey:
            if let c = Codec.decodeComponents(v) {
                d.dates.append(CNLabeledValue(identifier: id, label: label, value: nsDateComponents(c)))
            }
        default: break
        }
    }
}

/// Scalar string properties and their columns.
let scalarColumns: [(column: String, key: String, path: WritableKeyPath<ContactData, String>)] = [
    ("name_prefix", CNContactNamePrefixKey, \.namePrefix),
    ("given_name", CNContactGivenNameKey, \.givenName),
    ("middle_name", CNContactMiddleNameKey, \.middleName),
    ("family_name", CNContactFamilyNameKey, \.familyName),
    ("previous_family_name", CNContactPreviousFamilyNameKey, \.previousFamilyName),
    ("name_suffix", CNContactNameSuffixKey, \.nameSuffix),
    ("nickname", CNContactNicknameKey, \.nickname),
    ("organization_name", CNContactOrganizationNameKey, \.organizationName),
    ("department_name", CNContactDepartmentNameKey, \.departmentName),
    ("job_title", CNContactJobTitleKey, \.jobTitle),
    ("phonetic_given_name", CNContactPhoneticGivenNameKey, \.phoneticGivenName),
    ("phonetic_middle_name", CNContactPhoneticMiddleNameKey, \.phoneticMiddleName),
    ("phonetic_family_name", CNContactPhoneticFamilyNameKey, \.phoneticFamilyName),
    ("phonetic_organization_name", CNContactPhoneticOrganizationNameKey, \.phoneticOrganizationName),
    ("note", CNContactNoteKey, \.note),
]

struct StoredContact {
    let identifier: String
    let containerID: String
    let creator: String?
    var data: ContactData
}

struct StoredGroup {
    let identifier: String
    let containerID: String
    var name: String
}

struct JournalRow {
    let seq: Int64
    let txn: Int64
    let author: String?
    let kind: String      // contact, group, member
    let op: String        // add, update, delete, remove
    let recordID: String
    let groupID: String?
    let containerID: String?
}

final class ContactsDatabase {
    let conn: SQLiteConnection
    let path: String

    init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        conn = try SQLiteConnection(path: path)
        try conn.exec("PRAGMA journal_mode=WAL")
        try conn.exec("PRAGMA foreign_keys=OFF")
        try conn.exec("BEGIN IMMEDIATE")
        do {
            try createSchemaAndSeed()
            try conn.exec("COMMIT")
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }

    private func createSchemaAndSeed() throws {
        let cols = scalarColumns.map { "\($0.column) TEXT NOT NULL DEFAULT ''" }.joined(separator: ", ")
        try conn.exec("""
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS container(id TEXT PRIMARY KEY, name TEXT, type INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS contact(id TEXT PRIMARY KEY, container_id TEXT NOT NULL, creator TEXT,
                contact_type INTEGER NOT NULL DEFAULT 0, \(cols), image BLOB, thumbnail BLOB,
                birthday TEXT, non_gregorian_birthday TEXT);
            CREATE TABLE IF NOT EXISTS multivalue(contact_id TEXT NOT NULL, property TEXT NOT NULL, ordinal INTEGER NOT NULL,
                identifier TEXT NOT NULL, label TEXT, value TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS multivalue_contact ON multivalue(contact_id);
            CREATE TABLE IF NOT EXISTS grp(id TEXT PRIMARY KEY, container_id TEXT NOT NULL, name TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS member(group_id TEXT NOT NULL, contact_id TEXT NOT NULL, PRIMARY KEY(group_id, contact_id));
            CREATE TABLE IF NOT EXISTS journal(seq INTEGER PRIMARY KEY AUTOINCREMENT, txn INTEGER NOT NULL, author TEXT,
                writer TEXT, kind TEXT NOT NULL, op TEXT NOT NULL, record_id TEXT NOT NULL, group_id TEXT, container_id TEXT);
            """)
        if meta("unique_id") != nil { return }
        try setMeta("unique_id", UUID().uuidString)
        try setMeta("schema", "1")
        try conn.run("INSERT INTO container(id, name, type) VALUES (?, NULL, ?)",
                     [.text(localContainerIdentifier), .int(Int64(CNContainerType.local.rawValue))])
        for (id, data) in Seed.contacts() {
            try insertContact(id: id, containerID: localContainerIdentifier, creator: nil, data: data)
        }
        try insertGroup(StoredGroup(identifier: seedFriendsGroupIdentifier, containerID: localContainerIdentifier, name: "Friends"))
        try insertGroup(StoredGroup(identifier: seedWorkGroupIdentifier, containerID: localContainerIdentifier, name: "Work"))
        for (group, members) in Seed.memberships {
            for m in members { try addMember(group: group, contact: m) }
        }
    }

    // MARK: Meta

    func meta(_ key: String) -> String? {
        (try? conn.run("SELECT value FROM meta WHERE key = ?", [.text(key)]))?.first?.first?.text
    }

    func setMeta(_ key: String, _ value: String) throws {
        try conn.run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [.text(key), .text(value)])
    }

    // MARK: Transactions

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try conn.exec("BEGIN IMMEDIATE")
        do {
            let r = try body()
            try conn.exec("COMMIT")
            return r
        } catch {
            try? conn.exec("ROLLBACK")
            throw error
        }
    }

    // MARK: Containers

    func containers() -> [CNContainer] {
        let rows = (try? conn.run("SELECT id, name, type FROM container ORDER BY rowid")) ?? []
        return rows.map { CNContainer(identifier: $0[0].text ?? "", name: $0[1].text, type: CNContainerType(rawValue: $0[2].int ?? 1) ?? .local) }
    }

    func containerExists(_ id: String) -> Bool {
        !((try? conn.run("SELECT 1 FROM container WHERE id = ?", [.text(id)])) ?? []).isEmpty
    }

    // MARK: Contacts

    func contactExists(_ id: String) -> Bool {
        !((try? conn.run("SELECT 1 FROM contact WHERE id = ?", [.text(id)])) ?? []).isEmpty
    }

    private var selectColumns: String {
        "id, container_id, creator, contact_type, " + scalarColumns.map(\.column).joined(separator: ", ")
            + ", image, thumbnail, birthday, non_gregorian_birthday"
    }

    private func decode(_ r: [SQLValue], multi: [String: [[SQLValue]]]) -> StoredContact {
        var d = ContactData()
        d.contactType = CNContactType(rawValue: r[3].int ?? 0) ?? .person
        for (i, c) in scalarColumns.enumerated() { d[keyPath: c.path] = r[4 + i].text ?? "" }
        let base = 4 + scalarColumns.count
        d.imageData = r[base].data
        d.thumbnailImageData = r[base + 1].data
        d.birthday = Codec.decodeComponents(r[base + 2].text)
        d.nonGregorianBirthday = Codec.decodeComponents(r[base + 3].text)
        let id = r[0].text ?? ""
        for m in multi[id] ?? [] {
            MultiValue.add(&d, m[1].text ?? "", m[3].text ?? "", m[4].text, m[5].text ?? "")
        }
        return StoredContact(identifier: id, containerID: r[1].text ?? "", creator: r[2].text, data: d)
    }

    private func multiRows(_ where: String, _ args: [SQLValue]) -> [String: [[SQLValue]]] {
        let rows = (try? conn.run("SELECT contact_id, property, ordinal, identifier, label, value FROM multivalue \(`where`) ORDER BY contact_id, property, ordinal", args)) ?? []
        return Dictionary(grouping: rows) { $0[0].text ?? "" }
    }

    /// All contacts in storage order.
    func allContacts() -> [StoredContact] {
        let rows = (try? conn.run("SELECT \(selectColumns) FROM contact ORDER BY rowid")) ?? []
        let multi = multiRows("", [])
        return rows.map { decode($0, multi: multi) }
    }

    func contact(_ id: String) -> StoredContact? {
        guard let r = (try? conn.run("SELECT \(selectColumns) FROM contact WHERE id = ?", [.text(id)]))?.first else { return nil }
        return decode(r, multi: multiRows("WHERE contact_id = ?", [.text(id)]))
    }

    func insertContact(id: String, containerID: String, creator: String?, data d: ContactData) throws {
        var args: [SQLValue] = [.text(id), .text(containerID), creator.sql, .int(Int64(d.contactType.rawValue))]
        args += scalarColumns.map { .text(d[keyPath: $0.path]) }
        args += [d.imageData.sql, d.thumbnailImageData.sql, Codec.encode(d.birthday).sql, Codec.encode(d.nonGregorianBirthday).sql]
        let marks = Array(repeating: "?", count: args.count).joined(separator: ", ")
        try conn.run("INSERT INTO contact(\(selectColumns)) VALUES (\(marks))", args)
        for key in MultiValue.keys { try writeMulti(id, key, d) }
    }

    private func writeMulti(_ id: String, _ key: String, _ d: ContactData) throws {
        try conn.run("DELETE FROM multivalue WHERE contact_id = ? AND property = ?", [.text(id), .text(key)])
        for (i, row) in MultiValue.rows(d, key).enumerated() {
            try conn.run("INSERT INTO multivalue(contact_id, property, ordinal, identifier, label, value) VALUES (?, ?, ?, ?, ?, ?)",
                         [.text(id), .text(key), .int(Int64(i)), .text(row.0), row.1.sql, .text(row.2)])
        }
    }

    /// Writes the properties named by `keys`; the others stay as stored.
    func updateContact(id: String, keys: Set<String>, data d: ContactData) throws {
        var sets: [String] = []
        var args: [SQLValue] = []
        if keys.contains(CNContactTypeKey) { sets.append("contact_type = ?"); args.append(.int(Int64(d.contactType.rawValue))) }
        for c in scalarColumns where keys.contains(c.key) {
            sets.append("\(c.column) = ?")
            args.append(.text(d[keyPath: c.path]))
        }
        if keys.contains(CNContactImageDataKey) {
            sets += ["image = ?", "thumbnail = ?"]
            args += [d.imageData.sql, d.thumbnailImageData.sql]
        }
        if keys.contains(CNContactBirthdayKey) { sets.append("birthday = ?"); args.append(Codec.encode(d.birthday).sql) }
        if keys.contains(CNContactNonGregorianBirthdayKey) {
            sets.append("non_gregorian_birthday = ?")
            args.append(Codec.encode(d.nonGregorianBirthday).sql)
        }
        if !sets.isEmpty {
            try conn.run("UPDATE contact SET \(sets.joined(separator: ", ")) WHERE id = ?", args + [.text(id)])
        }
        for key in MultiValue.keys where keys.contains(key) { try writeMulti(id, key, d) }
    }

    func deleteContact(_ id: String) throws {
        try conn.run("DELETE FROM contact WHERE id = ?", [.text(id)])
        try conn.run("DELETE FROM multivalue WHERE contact_id = ?", [.text(id)])
        try conn.run("DELETE FROM member WHERE contact_id = ?", [.text(id)])
    }

    // MARK: Groups

    func groups() -> [StoredGroup] {
        let rows = (try? conn.run("SELECT id, container_id, name FROM grp ORDER BY rowid")) ?? []
        return rows.map { StoredGroup(identifier: $0[0].text ?? "", containerID: $0[1].text ?? "", name: $0[2].text ?? "") }
    }

    func group(_ id: String) -> StoredGroup? {
        guard let r = (try? conn.run("SELECT id, container_id, name FROM grp WHERE id = ?", [.text(id)]))?.first else { return nil }
        return StoredGroup(identifier: r[0].text ?? "", containerID: r[1].text ?? "", name: r[2].text ?? "")
    }

    func insertGroup(_ g: StoredGroup) throws {
        try conn.run("INSERT INTO grp(id, container_id, name) VALUES (?, ?, ?)", [.text(g.identifier), .text(g.containerID), .text(g.name)])
    }

    func renameGroup(_ id: String, _ name: String) throws {
        try conn.run("UPDATE grp SET name = ? WHERE id = ?", [.text(name), .text(id)])
    }

    func deleteGroup(_ id: String) throws {
        try conn.run("DELETE FROM grp WHERE id = ?", [.text(id)])
        try conn.run("DELETE FROM member WHERE group_id = ?", [.text(id)])
    }

    func members(of group: String) -> [String] {
        ((try? conn.run("SELECT contact_id FROM member WHERE group_id = ? ORDER BY rowid", [.text(group)])) ?? []).compactMap { $0[0].text }
    }

    func isMember(group: String, contact: String) -> Bool {
        !((try? conn.run("SELECT 1 FROM member WHERE group_id = ? AND contact_id = ?", [.text(group), .text(contact)])) ?? []).isEmpty
    }

    func addMember(group: String, contact: String) throws {
        try conn.run("INSERT OR IGNORE INTO member(group_id, contact_id) VALUES (?, ?)", [.text(group), .text(contact)])
    }

    func removeMember(group: String, contact: String) throws {
        try conn.run("DELETE FROM member WHERE group_id = ? AND contact_id = ?", [.text(group), .text(contact)])
    }

    // MARK: Journal

    func maxSeq() -> Int64 {
        Int64((try? conn.run("SELECT COALESCE(MAX(seq), 0) FROM journal"))?.first?.first?.int ?? 0)
    }

    func nextTransactionNumber() -> Int64 {
        Int64((try? conn.run("SELECT COALESCE(MAX(txn), 0) + 1 FROM journal"))?.first?.first?.int ?? 1)
    }

    func journal(txn: Int64, author: String?, writer: String, kind: String, op: String, record: String,
                 group: String? = nil, container: String? = nil) throws {
        try conn.run("INSERT INTO journal(txn, author, writer, kind, op, record_id, group_id, container_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                     [.int(txn), author.sql, .text(writer), .text(kind), .text(op), .text(record), group.sql, container.sql])
    }

    func journalRows(after seq: Int64) -> [JournalRow] {
        let rows = (try? conn.run("SELECT seq, txn, author, kind, op, record_id, group_id, container_id FROM journal WHERE seq > ? ORDER BY seq",
                                  [.int(seq)])) ?? []
        return rows.map {
            JournalRow(seq: Int64($0[0].int ?? 0), txn: Int64($0[1].int ?? 0), author: $0[2].text, kind: $0[3].text ?? "",
                       op: $0[4].text ?? "", recordID: $0[5].text ?? "", groupID: $0[6].text, containerID: $0[7].text)
        }
    }
}

// MARK: - Seed (Ycode's own made-up address book)

enum Seed {
    static let rowan = "5E2A9C14-3B7D-4F61-8A20-C1D4E7F90A11"
    static let mira = "8B6F0D22-91C4-4E3A-B5D7-2A9E6C1F3B22"
    static let theo = "0C4D7E33-A2F8-4B19-9C65-7E1B3D5A8C33"
    static let ines = "D19A2F44-6C3E-4D87-A0B4-5F8C2E7D1A44"
    static let jonah = "36E8B155-F07A-4C2D-8E91-B3A6D4C9E255"
    static let lena = "A7C3E866-4D1B-4A5F-9B08-E2F7C1D6B366"

    static let memberships: [(String, [String])] = [
        (seedFriendsGroupIdentifier, [rowan, theo, lena]),
        (seedWorkGroupIdentifier, [mira, jonah]),
    ]

    static func person(_ given: String, _ family: String, org: String = "", title: String = "",
                       phones: [(String, String)] = [], emails: [(String, String)] = [],
                       address: (String, String, String, String)? = nil, birthday: (Int?, Int, Int)? = nil) -> ContactData {
        var d = ContactData()
        d.givenName = given
        d.familyName = family
        d.organizationName = org
        d.jobTitle = title
        d.phoneNumbers = phones.map { CNLabeledValue(label: $0.0, value: CNPhoneNumber(stringValue: $0.1)) }
        d.emailAddresses = emails.map { CNLabeledValue(label: $0.0, value: NSString(string: $0.1)) }
        if let address {
            let a = CNMutablePostalAddress()
            a.street = address.0; a.city = address.1; a.state = address.2; a.postalCode = address.3
            a.country = "United States"; a.isoCountryCode = "us"
            d.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: a)]
        }
        if let birthday {
            var c = DateComponents()
            c.calendar = Calendar(identifier: .gregorian)
            c.year = birthday.0; c.month = birthday.1; c.day = birthday.2
            d.birthday = c
        }
        return d
    }

    static func contacts() -> [(String, ContactData)] {
        [
            (rowan, person("Rowan", "Ashby", phones: [(CNLabelPhoneNumberMobile, "(555) 010-1001")],
                           emails: [(CNLabelHome, "rowan.ashby@example.com")],
                           address: ("12 Maple Row", "Brookfield", "OR", "97001"), birthday: (1988, 4, 12))),
            (mira, person("Mira", "Castellanos", org: "Lumen Tide Studio", title: "Producer",
                          phones: [(CNLabelWork, "(555) 010-1002")], emails: [(CNLabelWork, "mira@lumentide.example")],
                          birthday: (1991, 11, 3))),
            (theo, person("Theo", "Brandt", phones: [(CNLabelPhoneNumberiPhone, "(555) 010-1003")],
                          emails: [(CNLabelHome, "theo.brandt@example.net")])),
            (ines, person("Ines", "Okafor", phones: [(CNLabelHome, "(555) 010-1004")],
                          emails: [(CNLabelHome, "ines.okafor@example.org")],
                          address: ("48 Harbor Lane", "Fairhaven", "WA", "98001"), birthday: (1979, 7, 21))),
            (jonah, person("Jonah", "Pereira", org: "Northbeam Logistics", title: "Dispatcher",
                           phones: [(CNLabelPhoneNumberMobile, "(555) 010-1005")])),
            (lena, person("Lena", "Varga", phones: [(CNLabelPhoneNumberMobile, "(555) 010-1006")],
                          emails: [(CNLabelHome, "lena.varga@example.com")], birthday: (nil, 2, 29))),
        ]
    }
}
