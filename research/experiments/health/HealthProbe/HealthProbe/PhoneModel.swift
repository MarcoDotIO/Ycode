import Foundation
import HealthKit
import WatchConnectivity

/// Receives the watch's batches, observes when the session's samples reach the phone's
/// HealthKit store, and forwards both to the receiver on the Mac.
final class PhoneModel: NSObject, ObservableObject {
    @Published var watchState = "not activated"
    @Published var receiverState = "searching"
    @Published var received = 0
    @Published var phoneSamples = 0
    @Published var forwarded = 0
    @Published var status = ""

    private let store = HKHealthStore()
    private let sender = LANSender()
    private var sessionID = ""
    private var start: Date?
    private var seq = 0
    private var queries: [HKQuery] = []

    override init() {
        super.init()
        sender.onState = { [weak self] s in DispatchQueue.main.async { self?.receiverState = s } }
        sender.start()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func requestAuthorization() {
        store.requestAuthorization(toShare: ProbeTypes.shareTypes, read: ProbeTypes.readTypes) { ok, _ in
            DispatchQueue.main.async { self.status = ok ? "access requested" : "access request failed" }
        }
    }

    func startOnWatch(location: HKWorkoutSessionLocationType) {
        let c = HKWorkoutConfiguration()
        c.activityType = .walking
        c.locationType = location
        store.startWatchApp(with: c) { ok, _ in
            DispatchQueue.main.async { self.status = ok ? "watch app asked to start" : "could not start the watch app" }
        }
    }

    // MARK: watch batches

    private func handle(_ data: Data?, transport: String) {
        guard let data, let events = try? JSONDecoder().decode([ProbeEvent].self, from: data) else { return }
        DispatchQueue.main.async {
            for var e in events {
                if e.kind == "session", e.note == "start", let epoch = e.startEpoch {
                    self.beginSession(id: e.session, start: Date(timeIntervalSince1970: epoch))
                }
                e.startEpoch = nil  // the absolute time never leaves the phone
                e.transport = transport
                if let s = self.start, e.session == self.sessionID {
                    e.phoneReceivedOffset = Date().timeIntervalSince(s)
                }
                self.forward(e)
                self.received += 1
            }
        }
    }

    // MARK: phone-side store observation (only samples that start inside the session)

    private func beginSession(id: String, start: Date) {
        queries.forEach { store.stop($0) }
        queries.removeAll()
        sessionID = id
        self.start = start
        seq = 0
        let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
        for qid in ProbeTypes.quantities {
            let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
                [weak self] _, samples, _, _, _ in
                let list = (samples ?? []).compactMap { $0 as? HKQuantitySample }
                DispatchQueue.main.async {
                    guard let self, let t0 = self.start else { return }
                    for s in list {
                        var e = ProbeTypes.event(for: s, start: t0, kind: "phoneStoreSample", origin: "phone")
                        e.session = self.sessionID
                        e.seq = self.seq
                        self.seq += 1
                        self.forward(e)
                        self.phoneSamples += 1
                    }
                }
            }
            let q = HKAnchoredObjectQuery(type: HKQuantityType(qid), predicate: predicate, anchor: nil,
                                          limit: HKObjectQueryNoLimit, resultsHandler: handler)
            q.updateHandler = handler
            store.execute(q)
            queries.append(q)
        }
        let wh: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = {
            [weak self] _, samples, _, _, _ in
            let list = (samples ?? []).compactMap { $0 as? HKWorkout }
            DispatchQueue.main.async {
                guard let self, let t0 = self.start else { return }
                for w in list {
                    var e = ProbeEvent(kind: "phoneStoreWorkout")
                    e.origin = "phone"
                    e.session = self.sessionID
                    e.seq = self.seq
                    self.seq += 1
                    e.type = "HKWorkoutActivityType-\(w.workoutActivityType.rawValue)"
                    e.startOffset = w.startDate.timeIntervalSince(t0)
                    e.endOffset = w.endDate.timeIntervalSince(t0)
                    e.deliveredOffset = Date().timeIntervalSince(t0)
                    e.value = w.duration
                    e.seriesCount = w.workoutEvents?.count
                    e.metadataKeys = w.metadata.map { Array($0.keys).sorted() } ?? []
                    self.forward(e)
                }
            }
        }
        let wq = HKAnchoredObjectQuery(type: HKObjectType.workoutType(), predicate: predicate, anchor: nil,
                                       limit: HKObjectQueryNoLimit, resultsHandler: wh)
        wq.updateHandler = wh
        store.execute(wq)
        queries.append(wq)
    }

    private func forward(_ e: ProbeEvent) {
        var out = e
        out.startEpoch = nil
        guard var line = try? JSONEncoder().encode(out) else { return }
        line.append(0x0A)
        sender.send(line)
        forwarded += 1
    }
}

extension PhoneModel: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        let paired = session.isPaired, installed = session.isWatchAppInstalled
        DispatchQueue.main.async {
            self.watchState = "activated, paired \(paired), watch app installed \(installed)"
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        DispatchQueue.main.async { self.watchState = "reachable \(r)" }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message["batch"] as? Data, transport: "message")
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo["batch"] as? Data, transport: "userInfo")
    }
}
