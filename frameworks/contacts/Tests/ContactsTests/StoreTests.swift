// C-CN-STORE (plan.md §3): fresh store, containers and groups
// (interface.md §3), the save table (§5), images (§2.5), notifications
// (§6.1) and the recorded authorization levels.

import Foundation
import Testing
@testable import Contacts

@Suite("C-CN-STORE interface.md §3, simulator-baseline.md §2: fresh store")
struct FreshStoreTests {
    @Test("six seed persons, groups Friends and Work, one local container with the fixed identifier")
    func fresh() throws {
        let t = TestStore()
        let all = try t.store.unifiedContacts(matching: nil, keysToFetch: nameKeys)
        #expect(all.count == 6)
        #expect(all.allSatisfy { UUID(uuidString: $0.identifier) != nil })  // plain UUIDs for seed records
        #expect(all.filter { !$0.organizationName.isEmpty }.count == 2)
        let groups = try t.store.groups(matching: nil)
        #expect(groups.map(\.name) == ["Friends", "Work"])
        #expect(groups.map(\.identifier) == ["CCDA4756-71B4-4B25-8DD2-D3DA109F4561", "2D6515F9-AE3D-460D-98A2-EFE81516739D"])
        let containers = try t.store.containers(matching: nil)
        #expect(containers.count == 1)
        #expect(containers[0].identifier == "BC25D81B-8966-48EF-8FF9-D7389B6F89BD")
        #expect(containers[0].name == nil)
        #expect(containers[0].type == .local)
        #expect(t.store.defaultContainerIdentifier() == "BC25D81B-8966-48EF-8FF9-D7389B6F89BD")
    }

    @Test("the seed has birthdays, addresses, phones and emails (shape of simulator-baseline.md §2)")
    func seedShape() throws {
        let t = TestStore()
        let all = try t.store.unifiedContacts(matching: nil, keysToFetch: keys(
            CNContactBirthdayKey, CNContactPostalAddressesKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey))
        #expect(all.allSatisfy { !$0.phoneNumbers.isEmpty })
        #expect(all.filter { $0.birthday != nil }.count >= 3)
        #expect(all.filter { !$0.postalAddresses.isEmpty }.count >= 2)
        #expect(all.filter { !$0.emailAddresses.isEmpty }.count >= 4)
    }

    @Test("§3: container and group predicates")
    func predicates() throws {
        let t = TestStore()
        let local = t.store.defaultContainerIdentifier()
        #expect(try t.store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: local)).count == 2)
        #expect(try t.store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [seedWorkGroupIdentifier])).map(\.name) == ["Work"])
        let anyone = try t.store.unifiedContacts(matching: nil, keysToFetch: [])[0]
        #expect(try t.store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: anyone.identifier)).map(\.identifier) == [local])
        #expect(try t.store.containers(matching: CNContainer.predicateForContainers(withIdentifiers: [local, "bogus"])).count == 1)
        #expect(try t.store.containers(matching: CNContainer.predicateForContainerOfContact(withIdentifier: "bogus")).isEmpty)
        // Ycode answers with the group's container (open question C-CN-Q2).
        let g = CNMutableGroup()
        g.name = "Probe Group"
        try save(t.store) { $0.add(g, toContainerWithIdentifier: nil) }
        #expect(try t.store.containers(matching: CNContainer.predicateForContainerOfGroup(withIdentifier: g.identifier)).map(\.identifier) == [local])
        #expect(try t.store.groups(matching: CNGroup.predicateForGroupsInContainer(withIdentifier: local)).count == 3)
        let friends = try t.store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: seedFriendsGroupIdentifier), keysToFetch: [])
        #expect(friends.count == 3)
    }

    @Test("data persists across store instances (simulator-baseline.md §3 item 6)")
    func persistence() throws {
        let t = TestStore()
        let c = person("Avery", "Example")
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        let again = t.another()
        #expect(try again.unifiedContact(withIdentifier: c.identifier, keysToFetch: nameKeys).givenName == "Avery")
    }
}

@Suite("C-CN-STORE interface.md §5: save requests")
struct SaveTests {
    @Test("add 7 contacts in one request: identifiers unchanged; shouldRefetchContacts defaults to YES")
    func addSeven() throws {
        let t = TestStore()
        let made = (1...7).map { person("Probe\($0)", "Example") }
        let ids = made.map(\.identifier)
        let r = CNSaveRequest()
        #expect(r.shouldRefetchContacts)
        r.transactionAuthor = "ycode-probe"
        for c in made { r.add(c, toContainerWithIdentifier: nil) }
        try t.store.execute(r)
        #expect(made.map(\.identifier) == ids)
        #expect(try t.store.unifiedContacts(matching: CNContact.predicateForContacts(withIdentifiers: ids), keysToFetch: []).count == 7)
        #expect(try t.store.unifiedContacts(matching: nil, keysToFetch: []).count == 13)
    }

    @Test("update a fetched contact: given name changed, a phone added, labeled-value identifiers kept")
    func updateFetched() throws {
        let t = TestStore()
        let c = person("Avery", "Example")
        c.phoneNumbers = [phone("(555) 010-0601")]
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        let fetched = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(CNContactGivenNameKey, CNContactPhoneNumbersKey))
        let firstID = fetched.phoneNumbers[0].identifier
        #expect(firstID == c.phoneNumbers[0].identifier)
        let m = fetched.mutableCopy() as! CNMutableContact
        m.givenName = "Avery-Renamed"
        m.phoneNumbers.append(phone("(555) 010-0699", CNLabelWork))
        try save(t.store) { $0.update(m) }
        let back = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey))
        #expect(back.givenName == "Avery-Renamed")
        #expect(back.familyName == "Example")
        #expect(back.phoneNumbers.map(\.identifier) == [firstID, m.phoneNumbers[1].identifier])
    }

    @Test("update a partially fetched contact: unfetched properties are kept")
    func updatePartial() throws {
        let t = TestStore()
        let c = person("Avery", "Example", org: "Example Widgets LLC")
        c.emailAddresses = [email("avery@example.com")]
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        let partial = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(CNContactGivenNameKey))
        let m = partial.mutableCopy() as! CNMutableContact
        m.givenName = "Blake"
        try save(t.store) { $0.update(m) }
        let back = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey))
        #expect(back.givenName == "Blake")
        #expect(back.familyName == "Example")
        #expect(back.organizationName == "Example Widgets LLC")
        #expect(back.emailAddresses.count == 1)
    }

    @Test("add a contact that already exists: 201 with CNInvalidRecords")
    func duplicate() throws {
        let t = TestStore()
        let c = person("Avery", "Example")
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        let e = expectCode(.insertedRecordAlreadyExists) { try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) } }
        #expect((e?.affectedRecords?.first as? CNContact)?.identifier == c.identifier)
        #expect((e as NSError?)?.userInfo[CNErrorUserInfoAffectedRecordsKey] != nil)
    }

    @Test("add group + add members in the same request: 200, whole request rejected; adding the group again works")
    func groupAndMembers() throws {
        let t = TestStore()
        let member = try t.store.unifiedContacts(matching: nil, keysToFetch: [])[0]
        let extra = person("Avery", "Example")
        let g = CNMutableGroup()
        g.name = "Probe Group"
        let e = expectCode(.recordDoesNotExist) {
            try save(t.store) {
                $0.add(extra, toContainerWithIdentifier: nil)
                $0.add(g, toContainerWithIdentifier: nil)
                $0.addMember(member, to: g)
            }
        }
        #expect(e?.affectedRecords != nil)
        #expect(try t.store.groups(matching: nil).count == 2)
        expectCode(.recordDoesNotExist) { _ = try t.store.unifiedContact(withIdentifier: extra.identifier, keysToFetch: []) }

        // A request that refers to the group created by the failed request.
        expectCode(.recordDoesNotExist) {
            try save(t.store) {
                $0.addMember(member, to: g)
                $0.addMember(member, to: g)
                $0.removeMember(member, from: g)
                $0.update(g)
            }
        }

        try save(t.store) { $0.add(g, toContainerWithIdentifier: nil) }
        #expect(try t.store.groups(matching: nil).map(\.name) == ["Friends", "Work", "Probe Group"])
        // Now membership works; a second add and removing a non-member are no-ops.
        let other = try t.store.unifiedContacts(matching: nil, keysToFetch: [])[1]
        try save(t.store) {
            $0.addMember(member, to: g)
            $0.addMember(member, to: g)
            $0.removeMember(other, from: g)
        }
        #expect(try t.store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier), keysToFetch: []).map(\.identifier) == [member.identifier])
        g.name = "Renamed"
        try save(t.store) { $0.update(g) }
        #expect(try t.store.groups(matching: CNGroup.predicateForGroups(withIdentifiers: [g.identifier])).first?.name == "Renamed")
        try save(t.store) { $0.removeMember(member, from: g) }
        #expect(try t.store.unifiedContacts(matching: CNContact.predicateForContactsInGroup(withIdentifier: g.identifier), keysToFetch: []).isEmpty)
        try save(t.store) { $0.delete(g) }
        #expect(try t.store.groups(matching: nil).count == 2)
    }

    @Test("add to a bogus container: 200 with CNInvalidRecordIdentifiers")
    func bogusContainer() throws {
        let t = TestStore()
        let c = person("Avery", "Example")
        let e = expectCode(.recordDoesNotExist) { try save(t.store) { $0.add(c, toContainerWithIdentifier: "bogus-container") } }
        #expect(e?.affectedRecordIdentifiers == ["bogus-container"])
        #expect(try t.store.unifiedContacts(matching: nil, keysToFetch: []).count == 6)
    }

    @Test("delete twice succeeds; updating the deleted contact fails with 200; add + delete-missing applies the add")
    func deletes() throws {
        let t = TestStore()
        let c = person("Avery", "Example")
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        try save(t.store) { $0.delete(c) }
        try save(t.store) { $0.delete(c) }
        c.givenName = "Again"
        let e = expectCode(.recordDoesNotExist) { try save(t.store) { $0.update(c) } }
        #expect((e?.affectedRecords?.first as? CNContact)?.identifier == c.identifier)
        let fresh = person("Blake", "Example")
        try save(t.store) {
            $0.add(fresh, toContainerWithIdentifier: nil)
            $0.delete(c)
        }
        #expect(try t.store.unifiedContact(withIdentifier: fresh.identifier, keysToFetch: nameKeys).givenName == "Blake")
        expectCode(.recordDoesNotExist) { _ = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: []) }
    }

    @Test("§2.5: saving image data keeps it, makes a thumbnail and sets imageDataAvailable")
    func image() throws {
        let t = TestStore()
        let bytes = Data((0..<324).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        let c = person("Pixel", "Probe")
        c.imageData = bytes
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        let back = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(
            CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey))
        #expect(back.imageData?.count == 324)
        #expect(back.thumbnailImageData != nil)
        #expect(back.imageDataAvailable)
        let onlyFlag = try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(CNContactImageDataAvailableKey))
        #expect(onlyFlag.imageDataAvailable)
        #expect(raised { onlyFlag.imageData } != nil)
    }

    @Test("notes: without the entitlement a saved note is dropped; with it the note round-trips")
    func notes() throws {
        let t = TestStore()
        try YcodeContactsEnvironment.$notesOverride.withValue(true) {
            let c = person("Avery", "Example")
            c.note = "Bring the blue folder."
            try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
            #expect(try t.store.unifiedContact(withIdentifier: c.identifier, keysToFetch: keys(CNContactNoteKey)).note == "Bring the blue folder.")
        }
        let plain = person("Blake", "Example")
        try save(t.store) { $0.add(plain, toContainerWithIdentifier: nil) }  // saved without a note: fine
    }
}

@Suite("C-CN-STORE interface.md §6.1: change notifications")
struct NotificationTests {
    final class Recorder: @unchecked Sendable {
        let lock = NSLock()
        var saving: [(onSaveThread: Bool, info: [AnyHashable: Any])] = []
        var external: [(onMain: Bool, info: [AnyHashable: Any])] = []

        func check() {
            lock.lock(); defer { lock.unlock() }
            let rec = self
            #expect(rec.saving.count == 1)
            #expect(rec.saving.first?.onSaveThread == true)
            #expect((rec.saving.first?.info["CNNotificationSaveIdentifiersKey"] as? [String])?.count == 2)
            #expect((rec.saving.first?.info["CNNotificationSourcesKey"] as? [String])?.count == 2)
            #expect(rec.external.count >= 1)
            #expect(rec.external.allSatisfy { $0.onMain })
            #expect(rec.external.allSatisfy { ($0.info["CNNotificationSaveIdentifiersKey"] as? [String])?.isEmpty == true })
            #expect(rec.external.allSatisfy { ($0.info["CNNotificationSourcesKey"] as? [String])?.isEmpty == true })
        }
    }

    @Test("two notifications per save: on the saving thread with identifiers and sources, then on main marked external")
    func pair() async throws {
        let t = TestStore()
        let rec = Recorder()
        let saveThread = LockedBox<Thread?>(nil)
        let token = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { n in
            let info = n.userInfo ?? [:]
            #expect(n.object == nil)
            rec.lock.lock(); defer { rec.lock.unlock() }
            if let ids = info["CNNotificationSaveIdentifiersKey"] as? [String], ids.contains(t.store.storeIdentifier) {
                rec.saving.append((Thread.current === saveThread.value, info))
            } else if (info["CNNotificationOriginationExternally"] as? Int) == 1 {
                rec.external.append((onMainQueue(), info))
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let thread = Thread {
                saveThread.value = Thread.current
                try? save(t.store) { $0.add(person("Avery", "Example"), toContainerWithIdentifier: nil) }
                done.resume()
            }
            thread.start()
        }
        for _ in 0..<5 { await drainMain() }
        rec.check()
    }

    @Test("a failed save posts nothing")
    func failedSave() throws {
        let t = TestStore()
        let c = person("Avery", "Example")
        try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) }
        let count = LockedBox(0)
        let token = NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { n in
            if let ids = n.userInfo?["CNNotificationSaveIdentifiersKey"] as? [String], ids.contains(t.store.storeIdentifier) {
                count.value += 1
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        expectCode(.insertedRecordAlreadyExists) { try save(t.store) { $0.add(c, toContainerWithIdentifier: nil) } }
        #expect(count.value == 0)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

@Suite("authorization.md §2–§3 (recorded answers): access levels")
struct AccessTests {
    @Test("denied: data calls fail with 100; the container identifier and history token stay available")
    func denied() throws {
        let t = TestStore(status: .denied)
        expectCode(.authorizationDenied) { _ = try t.store.unifiedContacts(matching: nil, keysToFetch: []) }
        expectCode(.authorizationDenied) { _ = try t.store.groups(matching: nil) }
        expectCode(.authorizationDenied) { try save(t.store) { $0.add(person("A", "B"), toContainerWithIdentifier: nil) } }
        #expect(t.store.defaultContainerIdentifier() == localContainerIdentifier)
        #expect(t.store.currentHistoryToken != nil)
    }

    @Test("requestAccess answers on a global queue: granted for full and limited access")
    func request() async throws {
        for (status, expected) in [(CNAuthorizationStatus.authorized, true), (.limited, true), (.denied, false)] {
            let t = TestStore(status: status)
            let granted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                t.store.requestAccess(for: .contacts) { ok, _ in c.resume(returning: ok) }
            }
            #expect(granted == expected)
        }
        #expect(try await TestStore().store.requestAccess(for: .contacts))
    }

    @Test("limited: only the shared contacts and the app's own are visible; groups all visible")
    func limited() throws {
        let t = TestStore()
        let seed = try t.store.unifiedContacts(matching: nil, keysToFetch: [])
        let other = person("Other", "App")
        try save(t.another(bundle: "org.example.other")) { $0.add(other, toContainerWithIdentifier: nil) }
        let lim = t.another(status: .limited, limited: [seed[0].identifier, seed[2].identifier], bundle: "org.ycode.limited")
        let own = person("Own", "Contact")
        try save(lim) { $0.add(own, toContainerWithIdentifier: nil) }
        let visible = Set(try lim.unifiedContacts(matching: nil, keysToFetch: []).map(\.identifier))
        #expect(visible == [seed[0].identifier, seed[2].identifier, own.identifier])
        #expect(try lim.groups(matching: nil).count == 2)
        expectCode(.recordDoesNotExist) { _ = try lim.unifiedContact(withIdentifier: seed[1].identifier, keysToFetch: []) }
        #expect(try t.store.unifiedContacts(matching: nil, keysToFetch: []).count == 8)
    }
}
