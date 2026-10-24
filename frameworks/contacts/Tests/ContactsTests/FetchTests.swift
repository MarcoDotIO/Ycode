// C-CN-FETCH (plan.md §3): predicate table interface.md §4.2, sort tables
// §4.3, fetch calls §4.1 (unknown identifier, note key, enumeration,
// CNFetchResult, mutable objects).

import Foundation
import Testing
@testable import Contacts

/// The probe data set of interface.md §4.2–§4.3 (made-up records) on top of
/// the seed: seven probe contacts and "Noaccess Example".
final class ProbeData {
    let t = TestStore()
    let c1: CNMutableContact, c2: CNMutableContact, c3: CNMutableContact, c4: CNMutableContact
    let c5: CNMutableContact, c6: CNMutableContact, c7: CNMutableContact, noaccess: CNMutableContact
    var store: CNContactStore { t.store }
    var probe: [CNMutableContact] { [c1, c2, c3, c4, c5, c6, c7] }

    init() throws {
        // c1: the Avery with an organization, nickname "Ave", job title
        // "ycode-probe" and a UK phone. Its phonetic names are an
        // assumption of this test (see README, spec question 3).
        c1 = person("Avery", "Example", org: "Example Widgets LLC")
        c1.nickname = "Ave"
        c1.jobTitle = "ycode-probe"
        c1.phoneticGivenName = "AY-ver-ee"
        c1.phoneticFamilyName = "ig-ZAM-pul"
        c1.phoneNumbers = [phone("+44 20 7946 0000", CNLabelWork)]
        c1.emailAddresses = [email("avery@example.com", CNLabelWork)]
        c2 = person("Avery", "Example")
        c2.phoneNumbers = [phone("(555) 010-0601")]
        c2.emailAddresses = [email("avery@example.com")]
        c3 = person("Blake", "Example")
        c3.phoneNumbers = [phone("+1 555 010 0602")]
        c4 = person("Casey", "Sample")
        c5 = person("Pixel", "Probe")
        c6 = CNMutableContact()
        c6.contactType = .organization
        c6.organizationName = "Ycode Probe Widgets"
        c7 = person("太郎", "山田")
        c7.phoneticGivenName = "たろう"
        c7.phoneticFamilyName = "やまだ"
        noaccess = person("Noaccess", "Example")
        try save(t.store) { $0.add(noaccess, toContainerWithIdentifier: nil) }
        let all = [c1, c2, c3, c4, c5, c6, c7]
        try save(t.store, author: "ycode-probe") { r in all.forEach { r.add($0, toContainerWithIdentifier: nil) } }
    }

    func ids(_ predicate: NSPredicate) throws -> Set<String> {
        Set(try store.unifiedContacts(matching: predicate, keysToFetch: nameKeys).map(\.identifier))
    }
}

@Suite("C-CN-FETCH interface.md §4.2: predicate semantics (golden)")
struct PredicateTests {
    @Test("name: case-insensitive word prefix over name, nickname, organization, job title and phonetic fields")
    func names() throws {
        let d = try ProbeData()
        let example: Set = [d.c1.identifier, d.c2.identifier, d.c3.identifier, d.noaccess.identifier]
        let averys: Set = [d.c1.identifier, d.c2.identifier]
        let byName = { (s: String) in try d.ids(CNContact.predicateForContacts(matchingName: s)) }
        #expect(try byName("Example") == example)
        #expect(try byName("exam") == example)
        #expect(try byName("xample").isEmpty)
        #expect(try byName("avery example") == averys)
        #expect(try byName("Example Avery") == averys)
        #expect(try byName("Ave") == averys)
        #expect(try byName("Widgets") == [d.c6.identifier, d.c1.identifier])
        #expect(try byName("Ycode Probe Widgets") == [d.c6.identifier, d.c1.identifier])
        #expect(try byName("山田") == [d.c7.identifier])
        #expect(try byName("やまだ") == [d.c7.identifier])
        #expect(try byName("Avéry") == averys)
        #expect(try byName("").isEmpty)
    }

    @Test("email: case-insensitive exact")
    func emails() throws {
        let d = try ProbeData()
        let both: Set = [d.c1.identifier, d.c2.identifier]
        #expect(try d.ids(CNContact.predicateForContacts(matchingEmailAddress: "avery@example.com")) == both)
        #expect(try d.ids(CNContact.predicateForContacts(matchingEmailAddress: "AVERY@EXAMPLE.COM")) == both)
        #expect(try d.ids(CNContact.predicateForContacts(matchingEmailAddress: "avery@example")).isEmpty)
    }

    @Test("phone: digits with the region's country code; no suffix matching")
    func phones() throws {
        let d = try ProbeData()
        let byPhone = { (s: String) in try d.ids(CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: s))) }
        #expect(try byPhone("5550100601") == [d.c2.identifier])
        #expect(try byPhone("+1 555-010-0601") == [d.c2.identifier])
        #expect(try byPhone("555 010 0602") == [d.c3.identifier])
        #expect(try byPhone("0100601").isEmpty)
        #expect(try byPhone("+44 20 7946 0000") == [d.c1.identifier])
    }

    @Test("identifiers (unknown ignored), container, nil predicate")
    func identifiers() throws {
        let d = try ProbeData()
        #expect(try d.ids(CNContact.predicateForContacts(withIdentifiers: [d.c2.identifier, d.c3.identifier, "bogus"]))
                == [d.c2.identifier, d.c3.identifier])
        let everything = try d.ids(CNContact.predicateForContactsInContainer(withIdentifier: d.store.defaultContainerIdentifier()))
        #expect(everything.count == 14)
        #expect(Set(try d.store.unifiedContacts(matching: nil, keysToFetch: []).map(\.identifier)) == everything)
    }

    @Test("§4.1: a plain NSPredicate is accepted (evaluated on each contact)")
    func plainPredicate() throws {
        let d = try ProbeData()
        let block = NSPredicate { obj, _ in (obj as? CNContact)?.familyName == "Sample" }
        #expect(try d.ids(block) == [d.c4.identifier])
        // The constructors' predicates also evaluate on contact objects.
        #expect(CNContact.predicateForContacts(matchingName: "pix").evaluate(with: d.c5))
        #expect(!CNContact.predicateForContacts(matchingName: "pix").evaluate(with: d.c4))
    }
}

@Suite("C-CN-FETCH interface.md §4.3: sort orders (golden)")
struct SortTests {
    func order(_ d: ProbeData, _ sort: CNContactSortOrder) throws -> [String] {
        let r = CNContactFetchRequest(keysToFetch: nameKeys)
        r.predicate = CNContact.predicateForContacts(withIdentifiers: d.probe.map(\.identifier))
        r.sortOrder = sort
        var out: [String] = []
        try d.store.enumerateContacts(with: r) { c, _ in
            out.append("\(c.givenName)/\(c.familyName)" + (c.organizationName.isEmpty ? "" : "/\(c.organizationName)"))
        }
        return out
    }

    @Test("sortOrder 2 given name")
    func givenOrder() throws {
        let d = try ProbeData()
        #expect(try order(d, .givenName) == ["Avery/Example", "Avery/Example/Example Widgets LLC", "Blake/Example",
                                             "Casey/Sample", "Pixel/Probe", "//Ycode Probe Widgets", "太郎/山田"])
    }

    @Test("sortOrder 3 family name and 1 user default (= family)")
    func familyOrder() throws {
        let d = try ProbeData()
        let expected = ["Avery/Example", "Blake/Example", "Avery/Example/Example Widgets LLC", "Pixel/Probe",
                        "Casey/Sample", "//Ycode Probe Widgets", "太郎/山田"]
        #expect(try order(d, .familyName) == expected)
        #expect(try order(d, .userDefault) == expected)
    }

    @Test("sortOrder 0 none: storage order")
    func noneOrder() throws {
        let d = try ProbeData()
        #expect(try order(d, .none).count == 7)
    }

    @Test("comparatorForNameSortOrder on unsaved contacts (case- and diacritic-insensitive; organization first, CJK last)")
    func comparator() {
        let acme = CNMutableContact()
        acme.organizationName = "Acme Org"
        let list = [person("bob", "Zed"), person("山田", "太郎"), person("Émile", "Xavier"), acme,
                    person("Alice", "young"), person("alice", "Adams")]
        func sorted(_ o: CNContactSortOrder) -> [String] {
            let cmp = CNContact.comparator(forNameSortOrder: o)
            return list.sorted { cmp($0, $1) == .orderedAscending }.map { "\($0.givenName)/\($0.familyName)" + ($0.organizationName.isEmpty ? "" : "/\($0.organizationName)") }
        }
        #expect(sorted(.givenName) == ["//Acme Org", "alice/Adams", "Alice/young", "bob/Zed", "Émile/Xavier", "山田/太郎"])
        let family = ["//Acme Org", "alice/Adams", "Émile/Xavier", "Alice/young", "bob/Zed", "山田/太郎"]
        #expect(sorted(.familyName) == family)
        #expect(sorted(.userDefault) == family)
        #expect(sorted(.none) == family)
    }
}

@Suite("C-CN-FETCH interface.md §4.1: fetch calls")
struct FetchCallTests {
    @Test("unknown identifier: error 200")
    func unknown() throws {
        let t = TestStore()
        expectCode(.recordDoesNotExist) { _ = try t.store.unifiedContact(withIdentifier: "00000000-0000-0000-0000-000000000000:ABPerson", keysToFetch: nameKeys) }
    }

    @Test("note key without the notes entitlement: 102 with CNKeyPaths [note]; with it, the note is fetched")
    func noteKey() throws {
        let t = TestStore()
        let e = expectCode(.unauthorizedKeys) { _ = try t.store.unifiedContacts(matching: nil, keysToFetch: keys(CNContactNoteKey)) }
        #expect(e?.keyPaths == ["note"])
        #expect((e as NSError?)?.userInfo[CNErrorUserInfoAffectedRecordsKey] != nil)
        let withNotes = try YcodeContactsEnvironment.$notesOverride.withValue(true) {
            try t.store.unifiedContacts(matching: nil, keysToFetch: keys(CNContactNoteKey))
        }
        #expect(withNotes.count == 6)
    }

    @Test("fetched contacts carry only the requested keys (plus the identifier)")
    func partialKeys() throws {
        let t = TestStore()
        let c = try t.store.unifiedContacts(matching: nil, keysToFetch: keys(CNContactGivenNameKey))[0]
        #expect(c.isKeyAvailable(CNContactGivenNameKey))
        #expect(c.isKeyAvailable(CNContactIdentifierKey))
        #expect(!c.isKeyAvailable(CNContactFamilyNameKey))
        #expect(raised { c.familyName } != nil)
        #expect(raised { CNContactFormatter.string(from: c, style: .fullName) } != nil)
        let full = try t.store.unifiedContacts(matching: nil, keysToFetch: [CNContactFormatter.descriptorForRequiredKeys(for: .fullName)])[0]
        #expect(CNContactFormatter.string(from: full, style: .fullName) != nil)
        let vcardReady = try t.store.unifiedContacts(matching: nil, keysToFetch: [CNContactVCardSerialization.descriptorForRequiredKeys()])
        #expect(try !CNContactVCardSerialization.data(with: vcardReady).isEmpty)
    }

    @Test("enumerateContacts: synchronous, mutableObjects, stop")
    func enumerate() throws {
        let t = TestStore()
        let r = CNContactFetchRequest(keysToFetch: nameKeys)
        r.mutableObjects = true
        r.sortOrder = .givenName
        var seen: [CNContact] = []
        try t.store.enumerateContacts(with: r) { c, stop in
            seen.append(c)
            if seen.count == 3 { stop.pointee = true }
        }
        #expect(seen.count == 3)
        #expect(seen.allSatisfy { $0 is CNMutableContact })
        #expect(r.unifyResults)
    }

    @Test("enumeratorForContactFetchRequest: CNFetchResult with an enumerator and the history token")
    func enumerator() throws {
        let t = TestStore()
        let result = try t.store.enumerator(for: CNContactFetchRequest(keysToFetch: nameKeys))
        var count = 0
        while let c = result.value.nextObject() as? CNContact {
            #expect(!c.givenName.isEmpty)
            count += 1
        }
        #expect(count == 6)
        #expect(result.currentHistoryToken == t.store.currentHistoryToken)
    }
}
