import Foundation
import HealthKit
import WatchConnectivity

/// Runs one workout session with a live builder and reports every sample and callback.
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    @Published var running = false
    @Published var status = "idle"
    @Published var lastHeartRate: Double?
    @Published var sentCount = 0
    @Published var saveToHealth = false

    private let store = HKHealthStore()
    private let link = WatchLink()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var start = Date()
    private var sessionID = ""
    private var seq = 0
    private var queries: [HKQuery] = []
    private var pending: [ProbeEvent] = []
    private var flushTimer: Timer?

    func requestAuthorization() {
        store.requestAuthorization(toShare: ProbeTypes.shareTypes, read: ProbeTypes.readTypes) { ok, _ in
            DispatchQueue.main.async { self.status = ok ? "access requested" : "access request failed" }
        }
    }

    func start(activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType) {
        let c = HKWorkoutConfiguration()
        c.activityType = activity
        c.locationType = location
        start(configuration: c)
    }

    /// Main thread only.
    func start(configuration c: HKWorkoutConfiguration) {
        guard !running else { return }
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: c)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: c)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b
            start = Date()
            sessionID = UUID().uuidString
            seq = 0
            var e = ProbeEvent(kind: "session")
            e.note = "start"
            e.activity = c.activityType.rawValue
            e.location = c.locationType.rawValue
            e.startEpoch = start.timeIntervalSince1970
            emit(e)
            s.startActivity(with: start)
            b.beginCollection(withStart: start) { ok, _ in
                self.emitNote(ok ? "collection-began" : "collection-failed")
            }
            startQueries()
            running = true
            status = "running"
            flushTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.flush() }
        } catch {
            status = "could not start a session"
        }
    }

    /// Main thread only.
    func end() {
        guard let s = session, let b = builder else { return }
        let save = saveToHealth
        status = "ending"
        s.end()
        b.endCollection(withEnd: Date()) { _, _ in
            if save {
                b.finishWorkout { workout, _ in
                    self.emitNote(workout == nil ? "finish-failed" : "finished-saved")
                    self.wrapUp()
                }
            } else {
                b.discardWorkout()
                self.emitNote("discarded")
                self.wrapUp()
            }
        }
    }

    /// Keeps the queries open for 60 s after the end, to see late samples, then stops.
    private func wrapUp() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            self.queries.forEach { self.store.stop($0) }
            self.queries.removeAll()
            self.emitNote("queries-stopped")
            self.flush()
            self.flushTimer?.invalidate()
            self.flushTimer = nil
            self.session = nil
            self.builder = nil
            self.running = false
            self.status = "done"
        }
    }

    /// Anchored queries limited to samples that start at or after the session start.
    private func startQueries() {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        for id in ProbeTypes.quantities {
            let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
                [weak self] _, samples, _, _, _ in
                guard let self else { return }
                let t0 = self.start
                let events = (samples ?? []).compactMap { $0 as? HKQuantitySample }.map {
                    ProbeTypes.event(for: $0, start: t0, kind: "querySample", origin: "watch")
                }
                DispatchQueue.main.async {
                    for e in events {
                        if e.type == HKQuantityTypeIdentifier.heartRate.rawValue { self.lastHeartRate = e.value }
                        self.emit(e, keepDelivered: true)
                    }
                }
            }
            let q = HKAnchoredObjectQuery(type: HKQuantityType(id), predicate: predicate, anchor: nil,
                                          limit: HKObjectQueryNoLimit, resultsHandler: handler)
            q.updateHandler = handler
            store.execute(q)
            queries.append(q)
        }
    }

    private func emitNote(_ note: String) {
        DispatchQueue.main.async {
            var e = ProbeEvent(kind: "session")
            e.note = note
            self.emit(e)
        }
    }

    /// Main thread only.
    private func emit(_ event: ProbeEvent, keepDelivered: Bool = false) {
        var e = event
        e.session = sessionID
        e.seq = seq
        seq += 1
        if !keepDelivered || e.deliveredOffset == nil { e.deliveredOffset = Date().timeIntervalSince(start) }
        pending.append(e)
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        link.send(batch)
        sentCount += batch.count
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState, date: Date) {
        emitNote("state-\(toState.rawValue)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        emitNote("session-failed")
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {
        let last = workoutBuilder.workoutEvents.last
        DispatchQueue.main.async {
            var e = ProbeEvent(kind: "workoutEvent")
            if let last {
                e.type = "HKWorkoutEventType-\(last.type.rawValue)"
                e.startOffset = last.dateInterval.start.timeIntervalSince(self.start)
                e.endOffset = last.dateInterval.end.timeIntervalSince(self.start)
                e.metadataKeys = last.metadata.map { Array($0.keys).sorted() } ?? []
            }
            self.emit(e)
        }
    }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        var events: [ProbeEvent] = []
        for t in collectedTypes {
            guard let qt = t as? HKQuantityType, let st = workoutBuilder.statistics(for: qt) else { continue }
            let unit = ProbeTypes.unit(for: HKQuantityTypeIdentifier(rawValue: qt.identifier))
            var e = ProbeEvent(kind: "builderStatistic")
            e.type = qt.identifier
            e.unit = unit.unitString
            if let q = st.mostRecentQuantity(), q.is(compatibleWith: unit) { e.value = q.doubleValue(for: unit) }
            if let q = st.sumQuantity(), q.is(compatibleWith: unit) { e.sum = q.doubleValue(for: unit) }
            if let iv = st.mostRecentQuantityDateInterval() {
                e.startOffset = iv.start.timeIntervalSince(start)
                e.endOffset = iv.end.timeIntervalSince(start)
            }
            events.append(e)
        }
        DispatchQueue.main.async { events.forEach { self.emit($0) } }
    }
}

/// Sends batches to the phone: a live message when the phone is reachable, otherwise
/// (or when the message fails) a queued user-info transfer.
final class WatchLink: NSObject, WCSessionDelegate {
    private var backlog: [Data] = []

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ events: [ProbeEvent]) {
        guard let data = try? JSONEncoder().encode(events) else { return }
        let s = WCSession.default
        guard s.activationState == .activated else {
            backlog.append(data)
            return
        }
        for old in backlog { s.transferUserInfo(["batch": old]) }
        backlog.removeAll()
        if s.isReachable {
            s.sendMessage(["batch": data], replyHandler: nil) { _ in s.transferUserInfo(["batch": data]) }
        } else {
            s.transferUserInfo(["batch": data])
        }
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}
}
