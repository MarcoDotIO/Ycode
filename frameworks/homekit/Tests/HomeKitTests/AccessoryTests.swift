// Accessories, services and characteristics through the in-memory test
// accessory (object-model.md §5–§7; plan.md HK-A20–A24, A27, A28).

import Foundation
import Testing
@testable import HomeKit

@Suite("Discovery and pairing (object-model.md §5, HK-A20, HK-A28)")
@MainActor
struct DiscoveryTests {
    @Test("HK-B11 analogue: a browser with nothing published finds nothing and calls nothing")
    func emptyBrowse() async {
        let store = newStore()
        _ = await loadedManager(store)
        let r = Recorder()
        let b = HMAccessoryBrowser(ycodeStore: store, client: client())
        b.delegate = r
        b.startSearchingForNewAccessories()
        await settle(store)
        #expect(b.discoveredAccessories.isEmpty)
        #expect(r.log.isEmpty)
        #expect(HMAccessorySetupManager.isSupported)
    }

    @Test("HK-A28: found/removed callbacks; adding to a home removes it from browsers")
    func browse() async throws {
        let (store, _, h) = try await homeFixture()
        let r = Recorder()
        let b = HMAccessoryBrowser(ycodeStore: store, client: client())
        b.delegate = r
        b.startSearchingForNewAccessories()
        let bulb = YcodeTestAccessory.lightbulb(name: "Bulb")
        let plug = YcodeTestAccessory.outlet(name: "Plug")
        store.publish(bulb)
        store.publish(plug)
        #expect(await eventually(store) { b.discoveredAccessories.count == 2 })
        let found = try #require(b.discoveredAccessories.first { $0.name == "Bulb" })
        #expect(found.category.categoryType == HMAccessoryCategoryTypeLightbulb)
        #expect(found.home == nil)
        try await h.addAccessory(found)
        await settle(store)
        #expect(b.discoveredAccessories.map(\.name) == ["Plug"])
        store.unpublish(endpointID: plug.endpointID)
        await settle(store)
        #expect(b.discoveredAccessories.isEmpty)
        #expect(r.log.filter { $0.hasPrefix("found") }.sorted() == ["found Bulb", "found Plug"])
        #expect(r.log.filter { $0.hasPrefix("lost") }.sorted() == ["lost Bulb", "lost Plug"])
        #expect(r.offMain == 0)
        await expectCode(.objectAlreadyAssociatedToHome) { try await h.addAccessory(h.accessories[0]) }
    }

    @Test("HK-A20: the paired accessory: category, information, services, characteristic metadata and properties")
    func pairedShape() async throws {
        let (store, _, h) = try await homeFixture()
        let watcher = Recorder()
        let other = await loadedManager(store)
        other.homes.first?.delegate = watcher
        let acc = try await pair(YcodeTestAccessory.lightbulb(name: "Desk Lamp"), into: h, store: store)
        await settle(store)
        #expect(watcher.log == ["add accessory Desk Lamp"])
        #expect(acc.name == "Desk Lamp")
        #expect(acc.home === h)
        #expect(acc.room == h.roomForEntireHome, "new accessories start in the default room")
        #expect(h.roomForEntireHome.accessories == [acc])
        #expect(acc.category.categoryType == HMAccessoryCategoryTypeLightbulb)
        #expect(acc.category.localizedDescription == "Lightbulb")
        #expect(acc.manufacturer == "Ycode")
        #expect(acc.model == "Test Lightbulb")
        #expect(acc.firmwareVersion == "1.0.0")
        #expect(acc.isReachable && !acc.isBridged && !acc.isBlocked)
        #expect(acc.supportsIdentify)
        #expect(acc.hapInstanceID == 1)
        #expect(acc.matterNodeID == nil)
        #expect(acc.bridgedAccessories == nil)
        #expect(acc.services.map(\.serviceType) == [HMServiceTypeAccessoryInformation, HMServiceTypeLightbulb])
        let info = acc.services[0], light = acc.services[1]
        #expect(!info.isUserInteractive && light.isUserInteractive)
        #expect(light.isPrimaryService)
        #expect(light.localizedDescription == "Lightbulb")
        #expect(light.accessory === acc)
        let brightness = characteristic(acc, HMCharacteristicTypeBrightness)
        #expect(brightness.service === light)
        #expect(brightness.localizedDescription == "Brightness")
        #expect(brightness.properties == [HMCharacteristicPropertyReadable, HMCharacteristicPropertyWritable,
                                          HMCharacteristicPropertySupportsEventNotification])
        let md = try #require(brightness.metadata)
        #expect(md.format == HMCharacteristicMetadataFormatInt)
        #expect(md.units == HMCharacteristicMetadataUnitsPercentage)
        #expect(md.minimumValue == 0 && md.maximumValue == 100 && md.stepValue == 1)
        #expect(brightness.value == nil, "nil until read or notified")
        #expect(characteristic(acc, HMCharacteristicTypeIdentify).properties == [HMCharacteristicPropertyWritable])
        #expect(h.servicesWithTypes([HMServiceTypeLightbulb]) == [light])
        #expect(h.servicesWithTypes(["43"]) == [light], "short form accepted")
    }

    @Test("HK-A27: a bridge with children; removing a child alone fails (34); removing the bridge removes all")
    func bridge() async throws {
        let (store, _, h) = try await homeFixture()
        let bridge = YcodeTestAccessory.bridge(name: "Hub", children: [
            YcodeTestAccessory.lightbulbAccessory(name: "Porch Light"),
            YcodeTestAccessory.switchAccessory(name: "Fan Switch"),
        ])
        let watcher = Recorder()
        let other = await loadedManager(store)
        other.homes.first?.delegate = watcher
        let hub = try await pair(bridge, into: h, store: store)
        #expect(hub.category.categoryType == HMAccessoryCategoryTypeBridge)
        #expect(h.accessories.count == 3)
        let children = try #require(hub.bridgedAccessories)
        #expect(children.map(\.name) == ["Porch Light", "Fan Switch"])
        #expect(hub.uniqueIdentifiersForBridgedAccessories == children.map(\.uniqueIdentifier))
        #expect(children.allSatisfy { $0.isBridged })
        #expect(children.map(\.hapInstanceID) == [2, 3])
        #expect(children[0].category.categoryType == HMAccessoryCategoryTypeLightbulb)
        #expect(children[1].category.categoryType == HMAccessoryCategoryTypeSwitch)
        await expectCode(.cannotRemoveNonBridgeAccessory) { try await h.removeAccessory(children[0]) }
        // Bridged accessories control through the bridge's endpoint.
        try await characteristic(children[0], HMCharacteristicTypePowerState).writeValue(true)
        #expect(bridge.value(of: HMCharacteristicTypePowerState, aid: 2) == .bool(true))
        try await h.removeAccessory(hub)
        #expect(h.accessories.isEmpty)
        await settle(store)
        #expect(watcher.log == ["add accessory Hub", "add accessory Porch Light", "add accessory Fan Switch",
                                "remove accessory Hub", "remove accessory Porch Light", "remove accessory Fan Switch"])
    }

    @Test("Accessory rename, room assignment, identify, unblock; service rename and associated type (62)")
    func accessoryCalls() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.outlet(name: "Plug")
        let acc = try await pair(device, into: h, store: store)
        let other = await loadedManager(store)
        let mirrorHome = try #require(other.homes.first)
        let watcher = Recorder()
        mirrorHome.delegate = watcher
        let mirrorAcc = try #require(mirrorHome.accessories.first)
        mirrorAcc.delegate = watcher

        let office = try await h.addRoom(named: "Office")
        try await h.assignAccessory(acc, to: office)
        #expect(acc.room == office)
        #expect(office.accessories == [acc])
        try await acc.updateName("Desk Plug")
        try await acc.identify()
        #expect(device.identifyCount == 1)
        let outlet = acc.services.first { $0.serviceType == HMServiceTypeOutlet }!
        try await outlet.updateName("Heater Socket")
        try await outlet.updateAssociatedServiceType(HMServiceTypeFan)
        #expect(outlet.associatedServiceType == HMServiceTypeFan)
        try await outlet.updateAssociatedServiceType(nil)
        await expectCode(.invalidAssociatedServiceType) { try await outlet.updateAssociatedServiceType("not-a-type") }
        try await h.unblockAccessory(acc)
        await settle(store)
        #expect(watcher.log == ["add room Office", "room Office for Plug", "accessory name Desk Plug",
                                "service name Heater Socket"])
    }
}

@Suite("Characteristic I/O (object-model.md §7, HK-A21–A24)")
@MainActor
struct CharacteristicTests {
    @Test("HK-A21: read and write; bounds and type checked before I/O (44/45/43); the cache updates before the completion")
    func readWrite() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.lightbulb()
        let acc = try await pair(device, into: h, store: store)
        let on = characteristic(acc, HMCharacteristicTypePowerState)
        let brightness = characteristic(acc, HMCharacteristicTypeBrightness)
        try await brightness.readValue()
        #expect(brightness.value as? Int == 100)
        try await on.writeValue(true)
        #expect(on.value as? Bool == true)
        #expect(device.value(of: HMCharacteristicTypePowerState) == .bool(true))
        try await brightness.writeValue(NSNumber(value: 40))
        #expect(device.value(of: HMCharacteristicTypeBrightness) == .int(40))

        let writesBefore = device.writes.count
        await expectCode(.valueLowerThanMinimum) { try await brightness.writeValue(-5) }
        await expectCode(.valueHigherThanMaximum) { try await brightness.writeValue(101) }
        await expectCode(.invalidValueType) { try await brightness.writeValue("bright") }
        await expectCode(.invalidValueType) { try await on.writeValue(7) }
        #expect(device.writes.count == writesBefore, "rejected values never reach the accessory")
        #expect(brightness.value as? Int == 40)

        // Completion runs on main and sees the new value.
        let seen = await withCheckedContinuation { (c: CheckedContinuation<(Bool, Int?), Never>) in
            brightness.readValue { _ in c.resume(returning: (onMainQueue(), brightness.value as? Int)) }
        }
        #expect(seen.0 && seen.1 == 40)
    }

    @Test("HK-A23: read-only write (5), write-only read (6), no-notify subscribe (7)")
    func permissions() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.lock()
        let acc = try await pair(device, into: h, store: store)
        let current = characteristic(acc, HMCharacteristicTypeCurrentLockMechanismState)
        let controlPoint = characteristic(acc, HMCharacteristicTypeLockManagementControlPoint)
        let version = characteristic(acc, HMCharacteristicTypeVersion)
        await expectCode(.readOnlyCharacteristic) { try await current.writeValue(0) }
        await expectCode(.writeOnlyCharacteristic) { try await controlPoint.readValue() }
        await expectCode(.notificationNotSupported) { try await version.enableNotification(true) }
        try await controlPoint.writeValue(Data([0x01, 0x00]))
        #expect(controlPoint.value == nil, "write-only values are not cached")
        try await characteristic(acc, HMCharacteristicTypeTargetLockMechanismState)
            .writeValue(HMCharacteristicValueTargetLockMechanismState.unsecured.rawValue)
        #expect(device.value(of: HMCharacteristicTypeTargetLockMechanismState) == .uint(0))
    }

    @Test("HK-A22: notifications arrive on main through the accessory delegate; other clients' writes notify subscribers")
    func notifications() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.temperatureSensor()
        let acc = try await pair(device, into: h, store: store)
        let r = Recorder()
        acc.delegate = r
        let temp = characteristic(acc, HMCharacteristicTypeCurrentTemperature)
        #expect(!temp.isNotificationEnabled)
        try await temp.enableNotification(true)
        #expect(temp.isNotificationEnabled)
        #expect(device.subscribedAddresses.count == 1)
        device.simulateChange(HMCharacteristicTypeCurrentTemperature, to: .float(23.5))
        #expect(await eventually(store) { temp.value as? Double == 23.5 })
        #expect(r.log == ["value CurrentTemperature 23.5"])
        #expect(r.offMain == 0)

        // A characteristic without a subscription stays silent.
        device.simulateChange(HMCharacteristicTypeBatteryLevel, to: .uint(50))
        await settle(store)
        #expect(r.log.count == 1)

        try await temp.enableNotification(false)
        #expect(device.subscribedAddresses.isEmpty)
        device.simulateChange(HMCharacteristicTypeCurrentTemperature, to: .float(19))
        await settle(store)
        #expect(r.log.count == 1)

        // Writes by another client reach subscribers; the writer itself is not notified.
        let bulb = YcodeTestAccessory.lightbulb(name: "Shared Bulb")
        let mine = try await pair(bulb, into: h, store: store)
        let otherManager = await loadedManager(store)
        let theirs = try #require(otherManager.homes.first?.accessories.first { $0.uniqueIdentifier == mine.uniqueIdentifier })
        let mineOn = characteristic(mine, HMCharacteristicTypePowerState)
        let theirOn = characteristic(theirs, HMCharacteristicTypePowerState)
        let watch = Recorder(), self_ = Recorder()
        theirs.delegate = watch
        mine.delegate = self_
        try await theirOn.enableNotification(true)
        try await mineOn.enableNotification(true)
        try await mineOn.writeValue(true)
        await settle(store)
        #expect(watch.log == ["value PowerState 1.0"])
        #expect(theirOn.value as? Bool == true)
        #expect(self_.log.isEmpty)
    }

    @Test("HK-A24: unreachable accessory: reachability callback, reads/writes fail with 4 (no I/O)")
    func unreachable() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.switch()
        let acc = try await pair(device, into: h, store: store)
        let r = Recorder()
        acc.delegate = r
        device.isReachable = false
        #expect(await eventually(store) { !acc.isReachable })
        #expect(r.log == ["reachable false"])
        let on = characteristic(acc, HMCharacteristicTypePowerState)
        await expectCode(.accessoryNotReachable) { try await on.readValue() }
        await expectCode(.accessoryNotReachable) { try await on.writeValue(true) }
        await expectCode(.accessoryNotReachable) { try await acc.identify() }
        device.isReachable = true
        #expect(await eventually(store) { acc.isReachable })
        try await on.writeValue(true)
    }

    @Test("T-H8 (status mapping part): forced HAP statuses surface as their HMErrorCode")
    func forcedStatuses() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.lightbulb()
        let acc = try await pair(device, into: h, store: store)
        let on = characteristic(acc, HMCharacteristicTypePowerState)
        for (status, code) in [(YcodeHAPStatus.resourceBusy, HMError.Code.accessoryIsBusy),
                               (.unableToCommunicate, .communicationFailure),
                               (.insufficientPrivileges, .insufficientPrivileges),
                               (.operationTimedOut, .operationTimedOut),
                               (.outOfResources, .accessoryOutOfResources)] {
            device.forceStatus(status, for: HMCharacteristicTypePowerState)
            await expectCode(code) { try await on.readValue() }
            await expectCode(code) { try await on.writeValue(false) }
        }
        device.forceStatus(nil, for: HMCharacteristicTypePowerState)
        try await on.readValue()
    }

    @Test("Authorization data is sent with writes (RequiresAuthorizationData)")
    func authorizationData() async throws {
        let (store, _, h) = try await homeFixture()
        var template = YcodeCharacteristicDefaults.template(HMCharacteristicTypeTargetLockMechanismState)!
        template.permissions.append(.additionalAuthorization)
        let device = YcodeTestAccessory(category: 6, accessories: [.init(name: "Vault", services: [
            .init(type: HMServiceTypeLockMechanism, isPrimary: true, characteristics: [template]),
        ])])
        let acc = try await pair(device, into: h, store: store)
        let target = characteristic(acc, HMCharacteristicTypeTargetLockMechanismState)
        #expect(target.properties.contains(HMCharacteristicPropertyRequiresAuthorizationData))
        await expectCode(.invalidOrMissingAuthorizationData) { try await target.writeValue(0) }
        try await target.updateAuthorizationData(Data([0xAB]))
        try await target.writeValue(0)
        #expect(device.authorizationData(for: HMCharacteristicTypeTargetLockMechanismState) == Data([0xAB]))
    }
}
