// Action sets and triggers in the in-memory store (object-model.md §8–§9).
// Execution of action sets is here; firing timer and event triggers is the
// scheduler of plan.md R4 and not part of this round.

import Foundation

extension YcodeLocalHomeStore {
    static let builtinActionSetTypes: Set<String> = [
        HMActionSetTypeWakeUp, HMActionSetTypeSleep, HMActionSetTypeHomeDeparture, HMActionSetTypeHomeArrival,
    ]

    func handleAutomation(_ request: YcodeHomeRequest, session: Session, reply: @escaping Reply) {
        switch request {
        case .addActionSet(let h, let name):
            mutateReturning(h, session, reply) { home in
                let n = try self.checkedName(name)
                if home.actionSets.contains(where: { YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.objectWithSimilarNameExistsInHome)
                }
                let set = YcodeActionSetRecord(id: UUID(), name: n, type: HMActionSetTypeUserDefined, actions: [],
                                               lastExecutionDate: nil, isExecuting: false)
                home.actionSets.append(set)
                return (.actionSetAdded(set.id), .object(set.id))
            }
        case .removeActionSet(let h, let s):
            mutate(h, session, reply) { home in
                guard let i = home.actionSets.firstIndex(where: { $0.id == s }) else { throw HMError(.notFound) }
                if Self.builtinActionSetTypes.contains(home.actionSets[i].type) { throw HMError(.cannotRemoveBuiltinActionSet) }
                home.actionSets.remove(at: i)
                for t in home.triggers.indices { home.triggers[t].actionSetIDs.removeAll { $0 == s } }
                return .actionSetRemoved(s)
            }
        case .renameActionSet(let h, let s, let name):
            mutate(h, session, reply) { home in
                guard let i = home.actionSets.firstIndex(where: { $0.id == s }) else { throw HMError(.notFound) }
                let n = try self.checkedName(name)
                if home.actionSets.contains(where: { $0.id != s && YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.renameWithSimilarName)
                }
                home.actionSets[i].name = n
                return .actionSetName(s)
            }
        case .addAction(let h, let s, let action):
            mutate(h, session, reply) { home in
                guard let i = home.actionSets.firstIndex(where: { $0.id == s }) else { throw HMError(.notFound) }
                if let owner = home.actionSets.first(where: { $0.actions.contains { $0.id == action.id } }) {
                    throw HMError(owner.id == s ? .alreadyExists : .actionInAnotherActionSet)
                }
                if self.state.homes.contains(where: { other in
                    other.id != h && other.actionSets.contains { $0.actions.contains { $0.id == action.id } }
                }) {
                    throw HMError(.actionInAnotherActionSet)
                }
                let checked = try self.checkedActionValue(home, action.characteristicID, action.targetValue)
                if home.actionSets[i].actions.contains(where: { $0.characteristicID == action.characteristicID }) {
                    throw HMError(.alreadyExists)
                }
                var a = action
                a.targetValue = checked
                home.actionSets[i].actions.append(a)
                return .actionSetActions(s)
            }
        case .removeAction(let h, let s, let a):
            mutate(h, session, reply) { home in
                guard let i = home.actionSets.firstIndex(where: { $0.id == s }),
                      home.actionSets[i].actions.contains(where: { $0.id == a }) else { throw HMError(.notFound) }
                home.actionSets[i].actions.removeAll { $0.id == a }
                return .actionSetActions(s)
            }
        case .updateActionTarget(let h, let a, let value):
            mutate(h, session, reply) { home in
                for i in home.actionSets.indices {
                    if let j = home.actionSets[i].actions.firstIndex(where: { $0.id == a }) {
                        let cid = home.actionSets[i].actions[j].characteristicID
                        home.actionSets[i].actions[j].targetValue = try self.checkedActionValue(home, cid, value)
                        return .actionSetActions(home.actionSets[i].id)
                    }
                }
                throw HMError(.notFound)
            }
        case .executeActionSet(let h, let s):
            execute(h, s, session, reply)

        case .addTrigger(let h, let trigger):
            mutateReturning(h, session, reply) { home in
                if home.triggers.contains(where: { $0.id == trigger.id }) { throw HMError(.alreadyExists) }
                let n = try self.checkedName(trigger.name)
                if home.triggers.contains(where: { YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.objectWithSimilarNameExistsInHome)
                }
                try self.validateTriggerKind(trigger.kind, in: home)
                var t = trigger
                t.name = n
                t.isEnabled = false
                t.activationState = HMEventTriggerActivationState.disabled.rawValue
                t.actionSetIDs = t.actionSetIDs.filter { id in home.actionSets.contains { $0.id == id } }
                home.triggers.append(t)
                return (.triggerAdded(t.id), .object(t.id))
            }
        case .removeTrigger(let h, let t):
            mutate(h, session, reply) { home in
                guard let i = home.triggers.firstIndex(where: { $0.id == t }) else { throw HMError(.notFound) }
                home.triggers.remove(at: i)
                return .triggerRemoved(t)
            }
        case .renameTrigger(let h, let t, let name):
            mutate(h, session, reply) { home in
                guard let i = home.triggers.firstIndex(where: { $0.id == t }) else { throw HMError(.notFound) }
                let n = try self.checkedName(name)
                if home.triggers.contains(where: { $0.id != t && YcodeNameRules.similar($0.name, n) }) {
                    throw HMError(.renameWithSimilarName)
                }
                home.triggers[i].name = n
                return .triggerName(t)
            }
        case .enableTrigger(let h, let t, let enabled):
            mutate(h, session, reply) { home in
                guard let i = home.triggers.firstIndex(where: { $0.id == t }) else { throw HMError(.notFound) }
                if enabled {
                    if home.triggers[i].actionSetIDs.isEmpty { throw HMError(.noRegisteredActionSets) }
                    if case .timer(let fire, let recurrence) = home.triggers[i].kind, recurrence == nil, fire < Date() {
                        throw HMError(.fireDateInPast)
                    }
                }
                home.triggers[i].isEnabled = enabled
                home.triggers[i].activationState = Self.activationState(enabled: enabled, hub: home.hubState).rawValue
                return .triggerUpdated(t)
            }
        case .addActionSetToTrigger(let h, let t, let s):
            mutate(h, session, reply) { home in
                guard let i = home.triggers.firstIndex(where: { $0.id == t }),
                      home.actionSets.contains(where: { $0.id == s }) else { throw HMError(.notFound) }
                if home.triggers[i].actionSetIDs.contains(s) { throw HMError(.alreadyExists) }
                home.triggers[i].actionSetIDs.append(s)
                return .triggerUpdated(t)
            }
        case .removeActionSetFromTrigger(let h, let t, let s):
            mutate(h, session, reply) { home in
                guard let i = home.triggers.firstIndex(where: { $0.id == t }),
                      home.triggers[i].actionSetIDs.contains(s) else { throw HMError(.notFound) }
                home.triggers[i].actionSetIDs.removeAll { $0 == s }
                return .triggerUpdated(t)
            }
        case .updateTrigger(let h, let trigger):
            mutate(h, session, reply) { home in
                guard let i = home.triggers.firstIndex(where: { $0.id == trigger.id }) else { throw HMError(.notFound) }
                try self.validateTriggerKind(trigger.kind, in: home)
                home.triggers[i].kind = trigger.kind
                return .triggerUpdated(trigger.id)
            }
        default:
            reply(.failure(YcodeHomeStoreError(.operationNotSupported)))
        }
    }

    static func activationState(enabled: Bool, hub: Int) -> HMEventTriggerActivationState {
        guard enabled else { return .disabled }
        return hub == HMHomeHubState.connected.rawValue ? .enabled : .disabledNoHomeHub
    }

    /// The value of a write action, validated against its characteristic.
    func checkedActionValue(_ home: YcodeHomeRecord, _ cid: UUID, _ value: YcodeHomeValue) throws -> YcodeHomeValue {
        guard let (a, s, c) = home.characteristicPath(cid) else { throw HMError(.notFound) }
        let ch = home.accessories[a].services[s].characteristics[c]
        guard ch.properties.contains(HMCharacteristicPropertyWritable) else { throw HMError(.readOnlyCharacteristic) }
        switch YcodeValueValidation.validate(value.apiValue, metadata: ch.metadata) {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    // MARK: Trigger rules (object-model.md §9, errors.md 28, 42, 69, 70, 72)

    /// Timer recurrences: only minute, hour, day and week-of-year fields; at
    /// least 5 minutes and at most 5 weeks (Ycode's reading of the public
    /// documentation; to be confirmed by plan.md HK-A08).
    public static let minimumRecurrence: TimeInterval = 5 * 60
    public static let maximumRecurrence: TimeInterval = 5 * 7 * 86_400

    static func validateTimer(fireDate: Date, recurrence: DateComponents?, now: Date = Date()) throws {
        if fireDate < now { throw HMError(.fireDateInPast) }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.second, .nanosecond], from: fireDate)
        if (parts.second ?? 0) != 0 || abs(fireDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)) > 1e-6 {
            throw HMError(.dateMustBeOnSpecifiedBoundaries)
        }
        guard let r = recurrence else { return }
        let forbidden: [Calendar.Component] = [.era, .year, .month, .second, .nanosecond, .weekday,
                                               .weekdayOrdinal, .quarter, .weekOfMonth, .yearForWeekOfYear]
        for f in forbidden where r.value(for: f) != nil && r.value(for: f) != 0 {
            throw HMError(.recurrenceMustBeOnSpecifiedBoundaries)
        }
        let seconds = Double(r.minute ?? 0) * 60 + Double(r.hour ?? 0) * 3600 + Double(r.day ?? 0) * 86_400
            + Double(r.weekOfYear ?? 0) * 604_800
        if seconds < minimumRecurrence { throw HMError(.recurrenceTooSmall) }
        if seconds > maximumRecurrence { throw HMError(.recurrenceTooLarge) }
    }

    func validateTriggerKind(_ kind: YcodeTriggerRecord.Kind, in home: YcodeHomeRecord) throws {
        switch kind {
        case .timer(let fire, let recurrence):
            try Self.validateTimer(fireDate: fire, recurrence: recurrence)
        case .event(let events, let endEvents, _, _):
            if events.isEmpty { throw HMError(.missingParameter) }
            for e in events + endEvents {
                switch e.kind {
                case .characteristic(let cid, _), .thresholdRange(let cid, _, _):
                    if home.characteristicPath(cid) == nil { throw HMError(.notFound) }
                default: break
                }
            }
        }
    }

    // MARK: Execution (object-model.md §8; errors 25, 63, 64, 65)

    func execute(_ homeID: UUID, _ setID: UUID, _ session: Session, _ reply: @escaping Reply) {
        guard let h = state.homes.firstIndex(where: { $0.id == homeID }),
              let set = state.homes[h].actionSets.first(where: { $0.id == setID }) else {
            reply(.failure(YcodeHomeStoreError(.notFound))); return
        }
        if set.actions.isEmpty { reply(.failure(YcodeHomeStoreError(.noActionsInActionSet))); return }
        if set.isExecuting { reply(.failure(YcodeHomeStoreError(.actionSetExecutionInProgress))); return }
        setExecuting(homeID, setID, true, date: nil)
        executeStep(homeID, setID, set.actions, 0, failures: 0, reply)
    }

    /// Writes action `index` (on the store queue), then the next one.
    func executeStep(_ homeID: UUID, _ setID: UUID, _ actions: [YcodeActionRecord], _ index: Int, failures: Int,
                     _ reply: @escaping Reply) {
        guard index < actions.count else {
            setExecuting(homeID, setID, false, date: Date())
            if failures == 0 {
                reply(.success(.done))
            } else if failures == actions.count {
                reply(.failure(YcodeHomeStoreError(.actionSetExecutionFailed)))
            } else {
                reply(.failure(YcodeHomeStoreError(.actionSetExecutionPartialSuccess)))
            }
            return
        }
        let action = actions[index]
        guard let loc = locate(homeID, action.characteristicID), let endpoint = endpoint(for: loc.accessory) else {
            executeStep(homeID, setID, actions, index + 1, failures: failures + 1, reply)
            return
        }
        endpoint.write(loc.address, value: action.targetValue,
                       authorizationData: authorizationData[action.characteristicID]) { result in
            self.queue.async {
                var failed = failures
                switch result {
                case .success: self.didWrite(homeID, loc, action.targetValue, origin: nil)
                case .failure: failed += 1
                }
                self.executeStep(homeID, setID, actions, index + 1, failures: failed, reply)
            }
        }
    }

    func setExecuting(_ homeID: UUID, _ setID: UUID, _ executing: Bool, date: Date?) {
        update(homeID, change: .state) { home in
            guard let i = home.actionSets.firstIndex(where: { $0.id == setID }) else { return }
            home.actionSets[i].isExecuting = executing
            if let date { home.actionSets[i].lastExecutionDate = date }
        }
    }
}
