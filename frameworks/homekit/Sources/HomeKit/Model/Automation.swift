// Actions, action sets and triggers (object-model.md §8–§9).

import Foundation

// MARK: - Actions

/// Abstract action.
open class HMAction: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    weak var actionSet: HMActionSet?

    init(id: UUID = UUID()) { uniqueIdentifier = id }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMAction)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    func apply(_ r: YcodeActionRecord, characteristic: HMCharacteristic?) {}
    func record() -> Result<YcodeActionRecord, HMError> { .failure(HMError(.invalidClass)) }

    /// A mirror for an action another client created.
    static func make(_ r: YcodeActionRecord, characteristic: HMCharacteristic?) -> HMAction {
        guard let c = characteristic else { return HMAction(id: r.id) }
        switch r.targetValue {
        case .string(let s): return HMCharacteristicWriteAction(id: r.id, characteristic: c, targetValue: s as NSString)
        case .data(let d): return HMCharacteristicWriteAction(id: r.id, characteristic: c, targetValue: d as NSData)
        default:
            let n = r.targetValue.apiValue as? NSNumber ?? NSNumber(value: 0)
            return HMCharacteristicWriteAction(id: r.id, characteristic: c, targetValue: n)
        }
    }
}

/// Writes `targetValue` to `characteristic` when its action set runs.
/// An action belongs to one action set (30 otherwise).
open class HMCharacteristicWriteAction<TargetValueType: NSCopying>: HMAction, @unchecked Sendable {
    public private(set) var characteristic: HMCharacteristic
    public private(set) var targetValue: TargetValueType

    public init(characteristic: HMCharacteristic, targetValue: TargetValueType) {
        self.characteristic = characteristic
        self.targetValue = targetValue
        super.init()
    }

    init(id: UUID, characteristic: HMCharacteristic, targetValue: TargetValueType) {
        self.characteristic = characteristic
        self.targetValue = targetValue
        super.init(id: id)
    }

    override func apply(_ r: YcodeActionRecord, characteristic c: HMCharacteristic?) {
        if let c { characteristic = c }
        if let v = r.targetValue.apiValue as? TargetValueType { targetValue = v }
    }

    override func record() -> Result<YcodeActionRecord, HMError> {
        YcodeValueValidation.validate(targetValue, metadata: characteristic.metadata?.record).map {
            YcodeActionRecord(id: uniqueIdentifier, characteristicID: characteristic.uniqueIdentifier, targetValue: $0)
        }
    }

    /// Changes the value (validated against the characteristic's metadata).
    public func updateTargetValue(_ targetValue: TargetValueType, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home = actionSet?.home else {
            self.targetValue = targetValue
            onMain { completion(nil) }
            return
        }
        let checked: YcodeHomeValue
        switch YcodeValueValidation.validate(targetValue, metadata: characteristic.metadata?.record) {
        case .success(let v): checked = v
        case .failure(let e): onMain { completion(e) }; return
        }
        home.connection.simple(.updateActionTarget(home: home.uniqueIdentifier, action: uniqueIdentifier, value: checked)) { error in
            if error == nil { self.targetValue = targetValue }
            completion(error)
        }
    }

    public func updateTargetValue(_ targetValue: TargetValueType) async throws {
        try await asyncCall { updateTargetValue(targetValue, completionHandler: $0) }
    }
}

// MARK: - Action sets

open class HMActionSet: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public private(set) var name = ""
    /// `HMActionSetType…` string.
    public private(set) var actionSetType = HMActionSetTypeUserDefined
    public private(set) var isExecuting = false
    public private(set) var lastExecutionDate: Date?
    /// The actions, in the order they were added (execution order).
    var actionList: [HMAction] = []
    weak var home: HMHome?

    public var actions: Set<HMAction> { Set(actionList) }

    init(id: UUID, home: HMHome) {
        uniqueIdentifier = id
        self.home = home
    }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMActionSet)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    func apply(_ r: YcodeActionSetRecord) {
        name = r.name
        actionSetType = r.type
        isExecuting = r.isExecuting
        lastExecutionDate = r.lastExecutionDate
    }

    public func updateName(_ name: String, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.renameActionSet(home: home.uniqueIdentifier, actionSet: uniqueIdentifier, name: name), completion)
    }

    /// Adds a write action; its value is validated before any I/O (43–46).
    public func addAction(_ action: HMAction, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        if let owner = action.actionSet, owner !== self { fail(completion, .actionInAnotherActionSet); return }
        let record: YcodeActionRecord
        switch action.record() {
        case .success(let r): record = r
        case .failure(let e): onMain { completion(e) }; return
        }
        home.pendingActions[action.uniqueIdentifier] = action
        home.connection.simple(.addAction(home: home.uniqueIdentifier, actionSet: uniqueIdentifier, action: record)) { error in
            if error != nil, action.actionSet == nil { home.pendingActions[action.uniqueIdentifier] = nil }
            completion(error)
        }
    }

    public func removeAction(_ action: HMAction, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.removeAction(home: home.uniqueIdentifier, actionSet: uniqueIdentifier,
                                             action: action.uniqueIdentifier)) { error in
            if error == nil { action.actionSet = nil }
            completion(error)
        }
    }

    public func updateName(_ name: String) async throws { try await asyncCall { updateName(name, completionHandler: $0) } }
    public func addAction(_ action: HMAction) async throws { try await asyncCall { addAction(action, completionHandler: $0) } }
    public func removeAction(_ action: HMAction) async throws { try await asyncCall { removeAction(action, completionHandler: $0) } }
}

// MARK: - Triggers

/// Base trigger. Apps create `HMTimerTrigger` or `HMEventTrigger` objects and
/// add them with `HMHome.addTrigger`; until then updates apply locally.
open class HMTrigger: NSObject, @unchecked Sendable {
    public let uniqueIdentifier: UUID
    public internal(set) var name: String
    public internal(set) var isEnabled = false
    public internal(set) var actionSets: [HMActionSet] = []
    @available(iOS, deprecated: 17.0)
    public var lastFireDate: Date? { nil }
    weak var home: HMHome?

    init(id: UUID = UUID(), name: String) {
        uniqueIdentifier = id
        self.name = name
    }

    open override func isEqual(_ object: Any?) -> Bool { (object as? HMTrigger)?.uniqueIdentifier == uniqueIdentifier }
    open override var hash: Int { uniqueIdentifier.hashValue }

    func record() -> YcodeTriggerRecord? { nil }

    func apply(_ r: YcodeTriggerRecord, home: HMHome) {
        name = r.name
        isEnabled = r.isEnabled
        actionSets = r.actionSetIDs.compactMap { id in home.actionSets.first { $0.uniqueIdentifier == id } }
    }

    static func make(_ r: YcodeTriggerRecord) -> HMTrigger {
        switch r.kind {
        case .timer(let fire, let recurrence):
            return HMTimerTrigger(id: r.id, name: r.name, fireDate: fire, recurrence: recurrence)
        case .event:
            return HMEventTrigger(id: r.id, name: r.name)
        }
    }

    /// Sends an update of an added trigger (the new state goes to the store;
    /// the mirror changes when the store confirms), or applies it locally.
    func change(_ completion: @escaping (Error?) -> Void, apply: () -> Void, revert: () -> Void) {
        guard let home else { apply(); onMain { completion(nil) }; return }
        apply()
        let r = record()
        revert()
        guard let r else { fail(completion, .invalidClass); return }
        home.connection.simple(.updateTrigger(home: home.uniqueIdentifier, trigger: r), completion)
    }

    public func updateName(_ name: String, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { self.name = name; onMain { completion(nil) }; return }
        home.connection.simple(.renameTrigger(home: home.uniqueIdentifier, trigger: uniqueIdentifier, name: name), completion)
    }

    public func addActionSet(_ actionSet: HMActionSet, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.addActionSetToTrigger(home: home.uniqueIdentifier, trigger: uniqueIdentifier,
                                                      actionSet: actionSet.uniqueIdentifier), completion)
    }

    public func removeActionSet(_ actionSet: HMActionSet, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.removeActionSetFromTrigger(home: home.uniqueIdentifier, trigger: uniqueIdentifier,
                                                           actionSet: actionSet.uniqueIdentifier), completion)
    }

    /// Enabling needs at least one action set (26).
    public func enable(_ enable: Bool, completionHandler completion: @escaping (Error?) -> Void) {
        guard let home else { fail(completion, .objectNotAssociatedToAnyHome); return }
        home.connection.simple(.enableTrigger(home: home.uniqueIdentifier, trigger: uniqueIdentifier, enabled: enable), completion)
    }

    public func updateName(_ name: String) async throws { try await asyncCall { updateName(name, completionHandler: $0) } }
    public func addActionSet(_ actionSet: HMActionSet) async throws { try await asyncCall { addActionSet(actionSet, completionHandler: $0) } }
    public func removeActionSet(_ actionSet: HMActionSet) async throws {
        try await asyncCall { removeActionSet(actionSet, completionHandler: $0) }
    }
    public func enable(_ enable: Bool) async throws { try await asyncCall { self.enable(enable, completionHandler: $0) } }
}

/// Fires at `fireDate`, optionally repeating (object-model.md §9).
open class HMTimerTrigger: HMTrigger, @unchecked Sendable {
    public private(set) var fireDate: Date
    public private(set) var recurrence: DateComponents?
    /// Always nil (the time-zone variant is deprecated; simulator-baseline.md §7).
    public var timeZone: TimeZone? { nil }
    public var recurrenceCalendar: Calendar? { nil }

    public init(name: String, fireDate: Date, recurrence: DateComponents?) {
        self.fireDate = fireDate
        self.recurrence = recurrence
        super.init(name: name)
    }

    @available(iOS, deprecated: 16.4)
    public convenience init(name: String, fireDate: Date, timeZone: TimeZone?, recurrence: DateComponents?,
                            recurrenceCalendar: Calendar?) {
        self.init(name: name, fireDate: fireDate, recurrence: recurrence)
    }

    init(id: UUID, name: String, fireDate: Date, recurrence: DateComponents?) {
        self.fireDate = fireDate
        self.recurrence = recurrence
        super.init(id: id, name: name)
    }

    override func record() -> YcodeTriggerRecord? {
        YcodeTriggerRecord(id: uniqueIdentifier, name: name, isEnabled: isEnabled, actionSetIDs: actionSets.map(\.uniqueIdentifier),
                           kind: .timer(fireDate: fireDate, recurrence: recurrence), activationState: 0)
    }

    override func apply(_ r: YcodeTriggerRecord, home: HMHome) {
        super.apply(r, home: home)
        if case .timer(let f, let rec) = r.kind { fireDate = f; recurrence = rec }
    }

    /// Past dates fail (28); dates must be on a whole minute (70).
    public func updateFireDate(_ fireDate: Date, completionHandler completion: @escaping (Error?) -> Void) {
        let old = self.fireDate
        change(completion, apply: { self.fireDate = fireDate }, revert: { self.fireDate = old })
    }

    /// Recurrence limits: 69, 42, 72 (object-model.md §9).
    public func updateRecurrence(_ recurrence: DateComponents?, completionHandler completion: @escaping (Error?) -> Void) {
        let old = self.recurrence
        change(completion, apply: { self.recurrence = recurrence }, revert: { self.recurrence = old })
    }

    public func updateFireDate(_ fireDate: Date) async throws { try await asyncCall { updateFireDate(fireDate, completionHandler: $0) } }
    public func updateRecurrence(_ recurrence: DateComponents?) async throws {
        try await asyncCall { updateRecurrence(recurrence, completionHandler: $0) }
    }
}

/// Fires on events, optionally ending on end events, limited to recurrences
/// and a predicate (object-model.md §9). Runs on the home hub, which the
/// store plays (`homeHubState` connected); without one it stays disabled.
open class HMEventTrigger: HMTrigger, @unchecked Sendable {
    public private(set) var events: [HMEvent] = []
    public private(set) var endEvents: [HMEvent] = []
    public private(set) var recurrences: [DateComponents]?
    /// Kept by this client only in this round (not stored; README "Deferred").
    public private(set) var predicate: NSPredicate?
    public private(set) var executeOnce = false
    public private(set) var triggerActivationState: HMEventTriggerActivationState = .disabled

    public init(name: String, events: [HMEvent], end endEvents: [HMEvent]?, recurrences: [DateComponents]?,
                predicate: NSPredicate?) {
        self.events = events
        self.endEvents = endEvents ?? []
        self.recurrences = recurrences
        self.predicate = predicate
        super.init(name: name)
    }

    public convenience init(name: String, events: [HMEvent], predicate: NSPredicate?) {
        self.init(name: name, events: events, end: nil, recurrences: nil, predicate: predicate)
    }

    override init(id: UUID, name: String) { super.init(id: id, name: name) }

    override func record() -> YcodeTriggerRecord? {
        let es = events.compactMap { $0.record() }
        let ends = endEvents.compactMap { $0.record() }
        guard es.count == events.count, ends.count == endEvents.count else { return nil }
        return YcodeTriggerRecord(id: uniqueIdentifier, name: name, isEnabled: isEnabled,
                                  actionSetIDs: actionSets.map(\.uniqueIdentifier),
                                  kind: .event(events: es, endEvents: ends, recurrences: recurrences, executeOnce: executeOnce),
                                  activationState: triggerActivationState.rawValue)
    }

    override func apply(_ r: YcodeTriggerRecord, home: HMHome) {
        super.apply(r, home: home)
        triggerActivationState = HMEventTriggerActivationState(rawValue: r.activationState) ?? .disabled
        guard case .event(let es, let ends, let rec, let once) = r.kind else { return }
        events = merge(events, es, home)
        endEvents = merge(endEvents, ends, home)
        recurrences = rec
        executeOnce = once
    }

    private func merge(_ old: [HMEvent], _ records: [YcodeEventRecord], _ home: HMHome) -> [HMEvent] {
        records.compactMap { r in
            if let e = old.first(where: { $0.uniqueIdentifier == r.id }) { return e }
            return HMEvent.make(r, home: home)
        }
    }

    public func updateEvents(_ events: [HMEvent], completionHandler completion: @escaping (Error?) -> Void) {
        let old = self.events
        change(completion, apply: { self.events = events }, revert: { self.events = old })
    }

    public func updateEndEvents(_ endEvents: [HMEvent], completionHandler completion: @escaping (Error?) -> Void) {
        let old = self.endEvents
        change(completion, apply: { self.endEvents = endEvents }, revert: { self.endEvents = old })
    }

    public func updateRecurrences(_ recurrences: [DateComponents]?, completionHandler completion: @escaping (Error?) -> Void) {
        let old = self.recurrences
        change(completion, apply: { self.recurrences = recurrences }, revert: { self.recurrences = old })
    }

    public func updateExecuteOnce(_ executeOnce: Bool, completionHandler completion: @escaping (Error?) -> Void) {
        let old = self.executeOnce
        change(completion, apply: { self.executeOnce = executeOnce }, revert: { self.executeOnce = old })
    }

    /// The predicate stays with this client in this round.
    public func updatePredicate(_ predicate: NSPredicate?, completionHandler completion: @escaping (Error?) -> Void) {
        self.predicate = predicate
        onMain { completion(nil) }
    }

    public func updateEvents(_ events: [HMEvent]) async throws { try await asyncCall { updateEvents(events, completionHandler: $0) } }
    public func updateEndEvents(_ events: [HMEvent]) async throws {
        try await asyncCall { updateEndEvents(events, completionHandler: $0) }
    }
    public func updateRecurrences(_ recurrences: [DateComponents]?) async throws {
        try await asyncCall { updateRecurrences(recurrences, completionHandler: $0) }
    }
    public func updateExecuteOnce(_ executeOnce: Bool) async throws {
        try await asyncCall { updateExecuteOnce(executeOnce, completionHandler: $0) }
    }
}
