// Homes, rooms, zones, service groups, users, delegate fan-out, name rules
// and persistence (object-model.md §1–§4, §12; plan.md HK-A01–A06, A10–A11).

import Foundation
import Testing
@testable import HomeKit

@Suite("Homes (object-model.md §2–§3, HK-A01)")
@MainActor
struct HomeTests {
    @Test("addHome: completion on main with the home; first home is primary; built-in scenes, default room and owner exist")
    func addHome() async throws {
        let store = newStore()
        let m = await loadedManager(store)
        let (home, onMain) = await withCheckedContinuation { (c: CheckedContinuation<(HMHome?, Bool), Never>) in
            m.addHome(withName: "Lake House") { h, e in
                #expect(e == nil)
                c.resume(returning: (h, onMainQueue()))
            }
        }
        #expect(onMain)
        let h = try #require(home)
        #expect(h.name == "Lake House")
        #expect(h.isPrimary)
        #expect(m.homes == [h])
        #expect(m.primaryHome == nil, "deprecated, no longer supported")
        #expect(h.rooms.isEmpty, "rooms excludes the default room")
        #expect(h.roomForEntireHome != nil)
        #expect(h.homeHubState == .connected, "the store plays the home hub")
        #expect(Set(h.actionSets.map(\.actionSetType)) == [HMActionSetTypeWakeUp, HMActionSetTypeSleep,
                                                            HMActionSetTypeHomeDeparture, HMActionSetTypeHomeArrival])
        for t in [HMActionSetTypeWakeUp, HMActionSetTypeSleep, HMActionSetTypeHomeDeparture, HMActionSetTypeHomeArrival] {
            #expect(h.builtinActionSet(ofType: t)?.actionSetType == t)
        }
        #expect(h.builtinActionSet(ofType: HMActionSetTypeUserDefined) == nil)
        let me = try #require(h.currentUser)
        #expect(h.homeAccessControl(for: me).isAdministrator)

        let second = try await m.addHome(named: "City Flat")
        #expect(!second.isPrimary)
        await expectCode(.operationNotSupported) { try await asyncCall { m.updatePrimaryHome(second, completionHandler: $0) } }
    }

    @Test("Name rules: similar names (32), empty/odd starts (36), prohibited characters (35), odd ends (60), rename (33)")
    func names() async throws {
        let (_, m, h) = try await homeFixture("Main Home")
        await expectCode(.homeWithSimilarNameExists) { _ = try await m.addHome(named: "main home") }
        await expectCode(.homeWithSimilarNameExists) { _ = try await m.addHome(named: "  Main   Home ") }
        await expectCode(.homeWithSimilarNameExists) { _ = try await m.addHome(named: "Máin Home") }
        await expectCode(.nameDoesNotStartWithValidCharacters) { _ = try await m.addHome(named: "") }
        await expectCode(.nameDoesNotStartWithValidCharacters) { _ = try await m.addHome(named: "   ") }
        await expectCode(.nameDoesNotStartWithValidCharacters) { _ = try await m.addHome(named: "!!!") }
        await expectCode(.nameContainsProhibitedCharacters) { _ = try await m.addHome(named: "Two\nLines") }
        await expectCode(.nameDoesNotEndWithValidCharacters) { _ = try await m.addHome(named: "Cabin -") }
        let other = try await m.addHome(named: "  Cabin (North)  ")
        #expect(other.name == "Cabin (North)", "names are trimmed")
        await expectCode(.renameWithSimilarName) { try await other.updateName("MAIN HOME") }
        try await h.updateName("Main home")
        #expect(h.name == "Main home", "case-only rename of itself is allowed")
        let room = try await h.addRoom(named: "Main Home")
        #expect(room.name == "Main Home", "a room may be named like its home")
    }

    @Test("removeHome: gone from homes; the next home becomes primary")
    func removeHome() async throws {
        let (_, m, h) = try await homeFixture()
        let second = try await m.addHome(named: "Second")
        try await m.removeHome(h)
        #expect(m.homes == [second])
        #expect(second.isPrimary)
        await expectCode(.notFound) { try await m.removeHome(h) }
    }
}

@Suite("Rooms, zones, service groups (object-model.md §3–§4, HK-A02–A04)")
@MainActor
struct RoomZoneTests {
    @Test("HK-A02: rooms; duplicate (31); default room cannot be renamed or removed (29); rename (33)")
    func rooms() async throws {
        let (_, _, h) = try await homeFixture()
        let kitchen = try await h.addRoom(named: "Kitchen")
        #expect(h.rooms == [kitchen])
        await expectCode(.objectWithSimilarNameExistsInHome) { _ = try await h.addRoom(named: "kitchen") }
        await expectCode(.objectWithSimilarNameExistsInHome) { _ = try await h.addRoom(named: h.roomForEntireHome.name) }
        await expectCode(.roomForHomeCannotBeUpdated) { try await h.roomForEntireHome.updateName("Everywhere") }
        await expectCode(.roomForHomeCannotBeUpdated) { try await h.removeRoom(h.roomForEntireHome) }
        let den = try await h.addRoom(named: "Den")
        await expectCode(.renameWithSimilarName) { try await den.updateName("KITCHEN") }
        try await kitchen.updateName("Cookhouse")
        #expect(kitchen.name == "Cookhouse")
        try await h.removeRoom(den)
        #expect(h.rooms == [kitchen])
        await expectCode(.notFound) { try await h.removeRoom(den) }
    }

    @Test("HK-A03: zones; the default room cannot join a zone (24); a room can be in several zones")
    func zones() async throws {
        let (_, _, h) = try await homeFixture()
        let up = try await h.addZone(named: "Upstairs")
        let quiet = try await h.addZone(named: "Quiet")
        let bed = try await h.addRoom(named: "Bedroom")
        try await up.addRoom(bed)
        try await quiet.addRoom(bed)
        #expect(up.rooms == [bed])
        #expect(quiet.rooms == [bed])
        await expectCode(.alreadyExists) { try await up.addRoom(bed) }
        await expectCode(.roomForHomeCannotBeInZone) { try await up.addRoom(h.roomForEntireHome) }
        await expectCode(.objectWithSimilarNameExistsInHome) { _ = try await h.addZone(named: "upstairs") }
        try await up.removeRoom(bed)
        #expect(up.rooms.isEmpty)
        await expectCode(.notFound) { try await up.removeRoom(bed) }
        try await h.removeRoom(bed)
        #expect(quiet.rooms.isEmpty, "removing a room takes it out of its zones")
        try await h.removeZone(up)
        #expect(h.zones == [quiet])
    }

    @Test("HK-A04: service groups add, rename, membership, remove")
    func serviceGroups() async throws {
        let (store, _, h) = try await homeFixture()
        let lamp = try await pair(YcodeTestAccessory.lightbulb(name: "Lamp"), into: h, store: store)
        let light = lamp.services.first { $0.serviceType == HMServiceTypeLightbulb }!
        let g = try await h.addServiceGroup(named: "Evening")
        try await g.addService(light)
        #expect(g.services == [light])
        await expectCode(.alreadyExists) { try await g.addService(light) }
        try await g.updateName("Night")
        #expect(g.name == "Night")
        try await g.removeService(light)
        #expect(g.services.isEmpty)
        try await h.removeServiceGroup(g)
        #expect(h.serviceGroups.isEmpty)
    }
}

@Suite("Delegate fan-out and threading (object-model.md §3, §12; HK-A05/A06)")
@MainActor
struct FanOutTests {
    @Test("Changes from one manager reach the other manager's delegates on main; the originator gets only its completion")
    func fanOut() async throws {
        let store = newStore()
        let a = await loadedManager(store)
        let watcher = Recorder()
        let b = await loadedManager(store, delegate: watcher)
        let own = Recorder()
        a.delegate = own

        let h = try await a.addHome(named: "Shared")
        await settle(store)
        let mirror = try #require(b.homes.first)
        #expect(mirror.uniqueIdentifier == h.uniqueIdentifier, "compare by uniqueIdentifier")
        #expect(mirror !== h, "each manager has its own objects")
        let homeWatcher = Recorder()
        mirror.delegate = homeWatcher
        h.delegate = own

        let room = try await h.addRoom(named: "Hall")
        try await room.updateName("Hallway")
        let zone = try await h.addZone(named: "Ground")
        try await zone.addRoom(room)
        try await zone.removeRoom(room)
        try await h.updateName("Shared Home")
        let set = try await h.addActionSet(named: "Movie")
        _ = set
        try await h.removeRoom(room)
        await settle(store)

        #expect(watcher.log == ["homes 0", "add home Shared"])
        #expect(homeWatcher.log == ["add room Hall", "rename room Hallway", "add zone Ground", "add room Hallway to Ground",
                                    "remove room Hallway from Ground", "home name Shared Home", "add scene Movie",
                                    "remove room Hallway"])
        #expect(homeWatcher.offMain == 0 && watcher.offMain == 0)
        #expect(own.log.isEmpty, "own changes report through completions only")
        #expect(mirror.name == "Shared Home")

        try await a.removeHome(h)
        await settle(store)
        #expect(watcher.log.last == "remove home Shared Home")
        #expect(b.homes.isEmpty)
    }

    @Test("A home added by another client while this manager loads appears through didAdd")
    func lateJoiner() async throws {
        let store = newStore()
        let a = await loadedManager(store)
        _ = try await a.addHome(named: "One")
        let r = Recorder()
        let b = await loadedManager(store, delegate: r)
        #expect(b.homes.map(\.name) == ["One"])
        #expect(r.log == ["homes 1"])
    }
}

@Suite("Persistence (HK-A11, T-O12 groundwork)")
@MainActor
struct PersistenceTests {
    @Test("A relaunch on the same store file sees the same identifiers and names; accessories wait for their endpoint")
    func relaunch() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ycode-hk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("homes.json")
        let lamp = YcodeTestAccessory.lightbulb(name: "Desk Lamp")
        var ids: [UUID] = []
        do {
            let store = newStore(url: url)
            let m = await loadedManager(store)
            let h = try await m.addHome(named: "Persisted")
            let room = try await h.addRoom(named: "Study")
            let acc = try await pair(lamp, into: h, store: store)
            try await h.assignAccessory(acc, to: room)
            ids = [h.uniqueIdentifier, room.uniqueIdentifier, acc.uniqueIdentifier]
            await settle(store)
        }
        let store2 = newStore(url: url)
        let m2 = await loadedManager(store2)
        #expect(m2.authorizationStatus.rawValue == 5, "the prompt answer persists")
        let h2 = try #require(m2.homes.first)
        #expect(h2.uniqueIdentifier == ids[0])
        #expect(h2.name == "Persisted")
        #expect(h2.rooms.map(\.uniqueIdentifier) == [ids[1]])
        let acc2 = try #require(h2.accessories.first)
        #expect(acc2.uniqueIdentifier == ids[2])
        #expect(acc2.room?.name == "Study")
        #expect(!acc2.isReachable, "unreachable until the endpoint is published again")
        let r = Recorder()
        acc2.delegate = r
        store2.publish(lamp)
        #expect(await eventually(store2) { acc2.isReachable })
        #expect(r.log == ["reachable true"])
    }
}
