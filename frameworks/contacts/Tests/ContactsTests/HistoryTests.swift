// C-CN-HISTORY (plan.md §3, interface.md §6.2): tokens, add events since a
// token, excluded authors, drop-everything from a nil token, bogus tokens,
// update and delete events, group events and the visitor.

import Foundation
import Testing
@testable import Contacts

func history(_ store: CNContactStore, from token: Data?, groups: Bool = false, excluding: [String]? = nil,
             keys extra: [CNKeyDescriptor] = nameKeys) throws -> [CNChangeHistoryEvent] {
    let r = CNChangeHistoryFetchRequest()
    r.startingToken = token
    r.includeGroupChanges = groups
    r.excludedTransactionAuthors = excluding
    r.additionalContactKeyDescriptors = extra
    let result = try store.enumerator(for: r)
    var out: [CNChangeHistoryEvent] = []
    while let e = result.value.nextObject() as? CNChangeHistoryEvent { out.append(e) }
    return out
}

final class Tally: CNChangeHistoryEventVisitor {
    var counts: [String: Int] = [:]
    func bump(_ k: String) { counts[k, default: 0] += 1 }
    func visit(_ event: CNChangeHistoryDropEverythingEvent) { bump("drop") }
    func visit(_ event: CNChangeHistoryAddContactEvent) { bump("addContact") }
    func visit(_ event: CNChangeHistoryUpdateContactEvent) { bump("updateContact") }
    func visit(_ event: CNChangeHistoryDeleteContactEvent) { bump("deleteContact") }
    func visit(_ event: CNChangeHistoryAddGroupEvent) { bump("addGroup") }
    func visit(_ event: CNChangeHistoryAddMemberToGroupEvent) { bump("addMember") }
}

@Suite("C-CN-HISTORY interface.md §6.2: change history")
struct HistoryTests {
    @Test("the token is opaque data, available before authorization, and changes with each save")
    func token() throws {
        let t = TestStore(status: .notDetermined)
        let before = try #require(t.store.currentHistoryToken)
        #expect(!before.isEmpty)
        let writer = t.another()
        try save(writer) { $0.add(person("Avery", "Example"), toContainerWithIdentifier: nil) }
        #expect(t.store.currentHistoryToken != before)
    }

    @Test("8 add events since the pre-data token; 5 with the probe's author excluded")
    func addsAndAuthors() throws {
        let t = TestStore()
        let token = t.store.currentHistoryToken
        let authored = (1...3).map { person("Authored\($0)", "Example") }
        try save(t.store, author: "ycode-probe") { r in authored.forEach { r.add($0, toContainerWithIdentifier: nil) } }
        for i in 1...5 { try save(t.store) { $0.add(person("Plain\(i)", "Example"), toContainerWithIdentifier: nil) } }
        // A later update of an added contact keeps a single add event.
        authored[0].givenName = "Authored1-Renamed"
        try save(t.store) { $0.update(authored[0]) }
        let all = try history(t.store, from: token)
        #expect(all.count == 8)
        #expect(all.allSatisfy { $0 is CNChangeHistoryAddContactEvent })
        let first = try #require(all.first as? CNChangeHistoryAddContactEvent)
        #expect(first.contact.givenName == "Authored1-Renamed")
        #expect(first.containerIdentifier == localContainerIdentifier)
        let excluded = try history(t.store, from: token, excluding: ["ycode-probe"])
        // The update of authored[0] was not authored, so it shows as an update.
        #expect(excluded.filter { $0 is CNChangeHistoryAddContactEvent }.count == 5)
        #expect(excluded.filter { $0 is CNChangeHistoryUpdateContactEvent }.count == 1)
    }

    @Test("nil token: drop everything, then an add event for every contact and group")
    func dropEverything() throws {
        let t = TestStore()
        let g = CNMutableGroup()
        g.name = "Probe Group"
        try save(t.store) {
            for i in 1...9 { $0.add(person("P\(i)", "Example"), toContainerWithIdentifier: nil) }
            $0.add(g, toContainerWithIdentifier: nil)
        }
        let events = try history(t.store, from: nil, groups: true)
        #expect(events.first is CNChangeHistoryDropEverythingEvent)
        #expect(events.filter { $0 is CNChangeHistoryAddContactEvent }.count == 15)
        #expect(events.filter { $0 is CNChangeHistoryAddGroupEvent }.count == 3)
        #expect(events.count == 19)
        let tally = Tally()
        events.forEach { $0.accept(tally) }
        #expect(tally.counts == ["drop": 1, "addContact": 15, "addGroup": 3])
    }

    @Test("bogus token: no events, no error (full access); limited access gets the complete history")
    func bogus() throws {
        let t = TestStore()
        #expect(try history(t.store, from: Data("not a token".utf8)).isEmpty)
        let lim = t.another(status: .limited, limited: [Seed.rowan])
        let events = try history(lim, from: Data("not a token".utf8))
        #expect(events.first is CNChangeHistoryDropEverythingEvent)
        #expect(events.count == 2)
    }

    @Test("updates and deletes of existing records; added-then-deleted records leave nothing; group changes")
    func updatesDeletesGroups() throws {
        let t = TestStore()
        let token = t.store.currentHistoryToken
        let seed = try t.store.unifiedContacts(matching: nil, keysToFetch: nameKeys)
        let changed = seed[0].mutableCopy() as! CNMutableContact
        changed.givenName = "Changed"
        let gone = seed[1].mutableCopy() as! CNMutableContact
        let temp = person("Temp", "Example")
        try save(t.store) { $0.update(changed); $0.delete(gone); $0.add(temp, toContainerWithIdentifier: nil) }
        try save(t.store) { $0.delete(temp) }
        let friends = try t.store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [seedFriendsGroupIdentifier]))[0]
        try save(t.store) { $0.addMember(seed[3], to: friends) }
        let contactsOnly = try history(t.store, from: token)
        #expect(contactsOnly.count == 2)
        #expect((contactsOnly[0] as? CNChangeHistoryUpdateContactEvent)?.contact.givenName == "Changed")
        #expect((contactsOnly[1] as? CNChangeHistoryDeleteContactEvent)?.contactIdentifier == gone.identifier)
        let withGroups = try history(t.store, from: token, groups: true)
        let member = try #require(withGroups.last as? CNChangeHistoryAddMemberToGroupEvent)
        #expect(member.member.identifier == seed[3].identifier)
        #expect(member.group.name == "Friends")
    }

    @Test("history events honour mutableObjects and the requested keys")
    func eventObjects() throws {
        let t = TestStore()
        let token = t.store.currentHistoryToken
        try save(t.store) { $0.add(person("Avery", "Example"), toContainerWithIdentifier: nil) }
        let r = CNChangeHistoryFetchRequest()
        r.startingToken = token
        r.mutableObjects = true
        r.additionalContactKeyDescriptors = keys(CNContactGivenNameKey)
        let result = try t.store.enumerator(for: r)
        let e = try #require(result.value.nextObject() as? CNChangeHistoryAddContactEvent)
        #expect(e.contact is CNMutableContact)
        #expect(e.contact.givenName == "Avery")
        #expect(raised { e.contact.familyName } != nil)
        #expect(result.currentHistoryToken == t.store.currentHistoryToken)
        // The token from the result starts the next request: nothing new.
        #expect(try history(t.store, from: result.currentHistoryToken).isEmpty)
    }
}
