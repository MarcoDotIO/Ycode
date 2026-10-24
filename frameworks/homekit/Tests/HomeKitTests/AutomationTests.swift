// Action sets, triggers and events (object-model.md §8–§9;
// simulator-baseline.md §7; plan.md T-O5, HK-A07–A09, A25–A26, HK-B13).

import Foundation
import Testing
@testable import HomeKit

@Suite("Action sets (object-model.md §8, HK-A07, HK-A25)")
@MainActor
struct ActionSetTests {
    @Test("HK-A07: built-ins exist; executing an empty set fails (25); built-ins cannot be removed (83)")
    func builtins() async throws {
        let (_, _, h) = try await homeFixture()
        let wake = try #require(h.builtinActionSet(ofType: HMActionSetTypeWakeUp))
        await expectCode(.noActionsInActionSet) { try await h.executeActionSet(wake) }
        await expectCode(.cannotRemoveBuiltinActionSet) { try await h.removeActionSet(wake) }
        let mine = try await h.addActionSet(named: "Reading")
        #expect(mine.actionSetType == HMActionSetTypeUserDefined)
        await expectCode(.objectWithSimilarNameExistsInHome) { _ = try await h.addActionSet(named: "reading") }
        try await mine.updateName("Reading Time")
        try await h.removeActionSet(mine)
        #expect(!h.actionSets.contains(mine))
    }

    @Test("Write actions: validated (43–46, 5), one action set only (30), execution writes in order, lastExecutionDate")
    func execute() async throws {
        let (store, _, h) = try await homeFixture()
        let device = YcodeTestAccessory.lightbulb()
        let acc = try await pair(device, into: h, store: store)
        let on = characteristic(acc, HMCharacteristicTypePowerState)
        let level = characteristic(acc, HMCharacteristicTypeBrightness)
        let scene = try await h.addActionSet(named: "Evening")
        let a1 = HMCharacteristicWriteAction(characteristic: on, targetValue: NSNumber(value: true))
        let a2 = HMCharacteristicWriteAction(characteristic: level, targetValue: NSNumber(value: 30))
        try await scene.addAction(a1)
        try await scene.addAction(a2)
        #expect(scene.actions == [a1, a2])
        #expect(scene.actions.contains { $0 === a1 }, "the app's own action objects are kept")
        await expectCode(.valueHigherThanMaximum) {
            try await scene.addAction(HMCharacteristicWriteAction(characteristic: level, targetValue: NSNumber(value: 300)))
        }
        await expectCode(.readOnlyCharacteristic) {
            let ro = characteristic(acc, HMCharacteristicTypeName)
            try await scene.addAction(HMCharacteristicWriteAction(characteristic: ro, targetValue: "x" as NSString))
        }
        let other = try await h.addActionSet(named: "Morning")
        await expectCode(.actionInAnotherActionSet) { try await other.addAction(a1) }

        let before = Date()
        try await h.executeActionSet(scene)
        #expect(device.writes.map(\.value) == [.bool(true), .int(30)], "actions run in the order they were added")
        #expect(scene.lastExecutionDate.map { $0 >= before } == true)
        #expect(!scene.isExecuting)

        try await a2.updateTargetValue(NSNumber(value: 60))
        #expect(a2.targetValue == 60)
        await expectCode(.valueLowerThanMinimum) { try await a2.updateTargetValue(NSNumber(value: -1)) }
        try await h.executeActionSet(scene)
        #expect(device.value(of: HMCharacteristicTypeBrightness) == .int(60))
        try await scene.removeAction(a1)
        #expect(scene.actions == [a2])
    }

    @Test("HK-A25: partial failure is 64, total failure 63; other clients see the actions")
    func partialFailure() async throws {
        let (store, _, h) = try await homeFixture()
        let lamp = YcodeTestAccessory.lightbulb(name: "Lamp")
        let plug = YcodeTestAccessory.outlet(name: "Plug")
        let lampAcc = try await pair(lamp, into: h, store: store)
        let plugAcc = try await pair(plug, into: h, store: store)
        let watcher = Recorder()
        let other = await loadedManager(store)
        other.homes.first?.delegate = watcher
        let scene = try await h.addActionSet(named: "All Off")
        try await scene.addAction(HMCharacteristicWriteAction(characteristic: characteristic(lampAcc, HMCharacteristicTypePowerState),
                                                               targetValue: NSNumber(value: false)))
        try await scene.addAction(HMCharacteristicWriteAction(characteristic: characteristic(plugAcc, HMCharacteristicTypePowerState),
                                                               targetValue: NSNumber(value: false)))
        plug.isReachable = false
        #expect(await eventually(store) { !plugAcc.isReachable })
        await expectCode(.actionSetExecutionPartialSuccess) { try await h.executeActionSet(scene) }
        lamp.forceStatus(.resourceBusy, for: HMCharacteristicTypePowerState)
        await expectCode(.actionSetExecutionFailed) { try await h.executeActionSet(scene) }
        await settle(store)
        #expect(watcher.log == ["add scene All Off", "actions All Off", "actions All Off"])
        let mirror = try #require(other.homes.first?.actionSets.first { $0.name == "All Off" })
        #expect(mirror.actions.count == 2)
        #expect(mirror.actions.allSatisfy { $0 is HMCharacteristicWriteAction<NSNumber> })
    }
}

@Suite("Triggers (object-model.md §9, HK-A08–A09)")
@MainActor
struct TriggerTests {
    /// The next whole minute at least `minutes` ahead.
    func futureMinute(_ minutes: Double = 10) -> Date {
        let t = Date().addingTimeInterval(minutes * 60).timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / 60).rounded(.up) * 60)
    }

    @Test("Unadded triggers: disabled, activation state 0, executeOnce NO, endEvents kept, time zone nil (simulator-baseline.md §7)")
    func unadded() {
        let ev = HMEventTrigger(name: "Dusk", events: [HMSignificantTimeEvent(significantEvent: .sunset, offset: nil)],
                                end: [HMDurationEvent(duration: 600)], recurrences: nil, predicate: nil)
        #expect(!ev.isEnabled)
        #expect(ev.triggerActivationState.rawValue == 0)
        #expect(!ev.executeOnce)
        #expect(ev.endEvents.count == 1)
        let timer = HMTimerTrigger(name: "Alarm", fireDate: futureMinute(), recurrence: nil)
        #expect(!timer.isEnabled)
        #expect(timer.timeZone == nil)
    }

    @Test("HK-A08: past fire date (28), seconds (70), recurrence fields (69), too small (42), too large (72)")
    func timerRules() async throws {
        let (_, _, h) = try await homeFixture()
        await expectCode(.fireDateInPast) {
            try await h.addTrigger(HMTimerTrigger(name: "Past", fireDate: Date(timeIntervalSinceNow: -3600), recurrence: nil))
        }
        await expectCode(.dateMustBeOnSpecifiedBoundaries) {
            try await h.addTrigger(HMTimerTrigger(name: "Odd", fireDate: futureMinute().addingTimeInterval(30), recurrence: nil))
        }
        await expectCode(.recurrenceMustBeOnSpecifiedBoundaries) {
            try await h.addTrigger(HMTimerTrigger(name: "Monthly", fireDate: futureMinute(), recurrence: DateComponents(month: 1)))
        }
        await expectCode(.recurrenceTooSmall) {
            try await h.addTrigger(HMTimerTrigger(name: "Often", fireDate: futureMinute(), recurrence: DateComponents(minute: 1)))
        }
        await expectCode(.recurrenceTooLarge) {
            try await h.addTrigger(HMTimerTrigger(name: "Rare", fireDate: futureMinute(), recurrence: DateComponents(weekOfYear: 6)))
        }
        let daily = HMTimerTrigger(name: "Daily", fireDate: futureMinute(), recurrence: DateComponents(day: 1))
        try await h.addTrigger(daily)
        #expect(h.triggers == [daily])
        #expect(h.triggers.first === daily, "the app's trigger object is kept")
        #expect(!daily.isEnabled)
        await expectCode(.objectWithSimilarNameExistsInHome) {
            try await h.addTrigger(HMTimerTrigger(name: "daily", fireDate: futureMinute(), recurrence: nil))
        }
        await expectCode(.alreadyExists) { try await h.addTrigger(daily) }

        let next = futureMinute(30)
        try await daily.updateFireDate(next)
        #expect(daily.fireDate == next)
        await expectCode(.recurrenceTooSmall) { try await daily.updateRecurrence(DateComponents(minute: 2)) }
        #expect(daily.recurrence == DateComponents(day: 1), "a refused update leaves the trigger unchanged")
        try await daily.updateRecurrence(DateComponents(hour: 12))
        #expect(daily.recurrence == DateComponents(hour: 12))
    }

    @Test("Enable needs action sets (26); action-set membership; rename; remove")
    func enable() async throws {
        let (_, _, h) = try await homeFixture()
        let t = HMTimerTrigger(name: "Lights On", fireDate: futureMinute(), recurrence: nil)
        try await h.addTrigger(t)
        await expectCode(.noRegisteredActionSets) { try await t.enable(true) }
        let wake = try #require(h.builtinActionSet(ofType: HMActionSetTypeWakeUp))
        try await t.addActionSet(wake)
        #expect(t.actionSets == [wake])
        await expectCode(.alreadyExists) { try await t.addActionSet(wake) }
        try await t.enable(true)
        #expect(t.isEnabled)
        try await t.updateName("Lights Up")
        #expect(t.name == "Lights Up")
        try await t.removeActionSet(wake)
        #expect(t.actionSets.isEmpty)
        try await h.removeTrigger(t)
        #expect(h.triggers.isEmpty)
    }

    @Test("HK-A09/A26: event triggers activate with the store as hub (4), stay disabled without one (1)")
    func eventTriggerActivation() async throws {
        for (hub, expected) in [(HMHomeHubState.connected, HMEventTriggerActivationState.enabled),
                                (.notAvailable, .disabledNoHomeHub)] {
            let (store, _, h) = try await homeFixture(store: newStore(hub: hub))
            let acc = try await pair(YcodeTestAccessory.temperatureSensor(), into: h, store: store)
            let temp = characteristic(acc, HMCharacteristicTypeCurrentTemperature)
            let events: [HMEvent] = [
                HMCharacteristicThresholdRangeEvent(characteristic: temp, thresholdRange: HMNumberRange(minValue: 30)),
                HMCharacteristicEvent(characteristic: temp, triggerValue: NSNumber(value: 25)),
                HMCalendarEvent(fire: DateComponents(hour: 7, minute: 30)),
                HMSignificantTimeEvent(significantEvent: .sunrise, offset: DateComponents(minute: -15)),
                HMPresenceEvent(presenceEventType: .atHome, presenceUserType: .homeUsers),
            ]
            let trigger = HMEventTrigger(name: "Hot", events: events, end: [HMDurationEvent(duration: 900)],
                                         recurrences: [DateComponents(weekday: 2)], predicate: nil)
            try await h.addTrigger(trigger)
            #expect(trigger.triggerActivationState == .disabled)
            try await trigger.addActionSet(h.builtinActionSet(ofType: HMActionSetTypeSleep)!)
            try await trigger.enable(true)
            #expect(trigger.triggerActivationState == expected)
            try await trigger.updateExecuteOnce(true)
            #expect(trigger.executeOnce)
            #expect(trigger.events.map(\.uniqueIdentifier) == events.map(\.uniqueIdentifier), "event objects kept")

            // Another client sees the same trigger with equivalent events.
            let other = await loadedManager(store)
            let mirror = try #require(other.homes.first?.triggers.first as? HMEventTrigger)
            #expect(mirror.uniqueIdentifier == trigger.uniqueIdentifier)
            #expect(mirror.events.map(\.uniqueIdentifier) == events.map(\.uniqueIdentifier))
            #expect(mirror.endEvents.first is HMDurationEvent)
            #expect((mirror.events[0] as? HMCharacteristicThresholdRangeEvent)?.thresholdRange == HMNumberRange(minValue: 30))
            #expect((mirror.events[1] as? HMCharacteristicEvent<NSNumber>)?.triggerValue == 25)
            #expect((mirror.events[3] as? HMSignificantTimeEvent)?.offset == DateComponents(minute: -15))
            #expect((mirror.events[4] as? HMPresenceEvent)?.presenceEventType == .firstEntry)
            #expect(mirror.recurrences == [DateComponents(weekday: 2)])
            #expect(mirror.executeOnce)
            #expect(mirror.triggerActivationState == expected)
        }
    }

    @Test("Event triggers need events (27) and characteristics of the home (2)")
    func eventTriggerRules() async throws {
        let (store, _, h) = try await homeFixture()
        await expectCode(.missingParameter) { try await h.addTrigger(HMEventTrigger(name: "Empty", events: [], predicate: nil)) }
        let (_, _, elsewhere) = try await homeFixture("Elsewhere", store: store)
        let acc = try await pair(YcodeTestAccessory.switch(), into: elsewhere, store: store)
        let foreign = HMCharacteristicEvent(characteristic: characteristic(acc, HMCharacteristicTypePowerState),
                                            triggerValue: NSNumber(value: true))
        await expectCode(.notFound) { try await h.addTrigger(HMEventTrigger(name: "Foreign", events: [foreign], predicate: nil)) }
    }
}

@Suite("T-O5 events and number ranges (simulator-baseline.md §7, HK-B13)")
@MainActor
struct EventObjectTests {
    func check<E: HMEvent, M: HMEvent>(_ e: E, mutable: M.Type) {
        let copy = e.copy() as AnyObject
        #expect(type(of: copy) == E.self, "copy keeps the class")
        #expect(!(copy as! HMEvent).isEqual(e), "a copy is not equal to the original")
        #expect((copy as! HMEvent).uniqueIdentifier != e.uniqueIdentifier, "a copy has a new identifier")
        let m = e.mutableCopy() as AnyObject
        #expect(type(of: m) == M.self, "mutableCopy gives the HMMutable… class")
        #expect((m as! HMEvent).uniqueIdentifier != e.uniqueIdentifier)
        let nibble = e.uniqueIdentifier.uuidString.dropFirst(14).first
        #expect(nibble == "5", "version nibble 5")
    }

    @Test("copy / mutableCopy classes, fresh identifiers, identity equality")
    func copies() async throws {
        check(HMCalendarEvent(fire: DateComponents(hour: 8)), mutable: HMMutableCalendarEvent.self)
        check(HMSignificantTimeEvent(significantEvent: .sunset, offset: nil), mutable: HMMutableSignificantTimeEvent.self)
        check(HMPresenceEvent(presenceEventType: .everyExit, presenceUserType: .currentUser), mutable: HMMutablePresenceEvent.self)
        check(HMDurationEvent(duration: 60), mutable: HMMutableDurationEvent.self)
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: 41.15, longitude: -81.36), radius: 100,
                                      identifier: "made-up place")
        check(HMLocationEvent(region: region), mutable: HMMutableLocationEvent.self)
        let (store, _, h) = try await homeFixture()
        let acc = try await pair(YcodeTestAccessory.switch(), into: h, store: store)
        let c = characteristic(acc, HMCharacteristicTypePowerState)
        check(HMCharacteristicEvent(characteristic: c, triggerValue: NSNumber(value: true)),
              mutable: HMMutableCharacteristicEvent<NSNumber>.self)
        check(HMCharacteristicThresholdRangeEvent(characteristic: c, thresholdRange: HMNumberRange(maxValue: 1)),
              mutable: HMMutableCharacteristicThresholdRangeEvent.self)
        let a = HMDurationEvent(duration: 5), b = HMDurationEvent(duration: 5)
        #expect(!a.isEqual(b), "equal content is not equality")
        let m = HMMutableDurationEvent(duration: 5)
        m.duration = 10
        #expect(m.duration == 10)
    }

    @Test("isSupported(forHome:): nil → NO except location; a connected hub supports all")
    func supported() async throws {
        #expect(!HMCalendarEvent.isSupported(forHome: nil))
        #expect(!HMSignificantTimeEvent.isSupported(forHome: nil))
        #expect(!HMPresenceEvent.isSupported(forHome: nil))
        #expect(!HMDurationEvent.isSupported(forHome: nil))
        #expect(!HMCharacteristicThresholdRangeEvent.isSupported(forHome: nil))
        #expect(HMLocationEvent.isSupported(forHome: nil))
        let (_, _, h) = try await homeFixture()
        #expect(HMCalendarEvent.isSupported(forHome: h))
        let (_, _, noHub) = try await homeFixture(store: newStore(hub: .notAvailable))
        #expect(!HMPresenceEvent.isSupported(forHome: noHub))
    }

    @Test("HMNumberRange: value equality; min greater than max accepted")
    func numberRange() {
        #expect(HMNumberRange(minValue: 1, maxValue: 5) == HMNumberRange(minValue: 1, maxValue: 5))
        #expect(HMNumberRange(minValue: 1) != HMNumberRange(maxValue: 1))
        let odd = HMNumberRange(minValue: 9, maxValue: 2)
        #expect(odd.minValue == 9 && odd.maxValue == 2)
        #expect(HMNumberRange(maxValue: 3).minValue == nil)
    }
}

@Suite("T-O6 setup payloads and the setup manager (simulator-baseline.md §6–§7)")
@MainActor
struct SetupTests {
    @Test("X-HM:// + 13 characters accepted; shorter, longer, other schemes, Matter codes and nil rejected")
    func payloads() {
        #expect(HMAccessorySetupPayload(url: URL(string: "X-HM://0023ISYWY1234")) != nil)
        #expect(HMAccessorySetupPayload(url: URL(string: "X-HM://0023ISYWY1234"),
                                        ownershipToken: HMAccessoryOwnershipToken(data: Data([0xFF, 0x00]))) != nil)
        #expect(HMAccessorySetupPayload(url: URL(string: "X-HM://")) == nil)
        #expect(HMAccessorySetupPayload(url: URL(string: "X-HM://0023ISYWY123")) == nil)
        #expect(HMAccessorySetupPayload(url: URL(string: "X-HM://0023ISYWY12345")) == nil)
        #expect(HMAccessorySetupPayload(url: URL(string: "https://example.com/0023ISYWY1234")) == nil)
        #expect(HMAccessorySetupPayload(url: URL(string: "MT:Y.K9042C00KA0648G00")) == nil)
        #expect(HMAccessorySetupPayload(url: nil) == nil)
    }

    @Test("Setup requests: properties nil by default, a copy is equal")
    func requests() {
        let r = HMAccessorySetupRequest()
        #expect(r.payload == nil && r.homeUniqueIdentifier == nil && r.suggestedRoomUniqueIdentifier == nil
            && r.suggestedAccessoryName == nil)
        r.suggestedAccessoryName = "Lamp"
        r.homeUniqueIdentifier = UUID()
        #expect(r.copy() as? HMAccessorySetupRequest == r)
    }

    @Test("HK-B12 analogue: without a setup sheet the flow ends with 23, empty userInfo, on main")
    func setupCancelled() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<(Bool, NSError?, Bool), Never>) in
            HMAccessorySetupManager().performAccessorySetup(using: HMAccessorySetupRequest()) { res, e in
                c.resume(returning: (res == nil, e as NSError?, onMainQueue()))
            }
        }
        #expect(result.0)
        #expect(result.1?.code == 23 && result.1?.domain == "HMErrorDomain")
        #expect(result.1?.userInfo.isEmpty == true)
        #expect(result.2)
    }
}
