// HealthCheck: Ycode's own HealthKit reader app (health-simulation.md
// "Ycode implementation", the done-criterion of HEALTH-1…3). One source for
// the iOS app and its embedded watch app. Written from Apple's public
// HealthKit documentation (HKHealthStore, HKSampleQuery, HKObserverQuery);
// no Apple sample was used.
//
// It asks for read access to the types Ycode's health tools write (the
// normal permission flow: a sheet, or Ycode's `health grant` while the device
// is shut down), then runs one HKObserverQuery per type. Each observer call
// re-runs an HKSampleQuery of that type and logs, one line each (NSLog and
// <tmp>/healthcheck.log, prefix "HEALTHCHECK <role> <unix time>"):
//   observer <type> fired (n)                 every observer call
//   samples <type> <count> sources <names…> last <value> <unit> at <date> [synthetic N]
//   auth requested ok=<bool> error=<…>
// The screen lists each type with its count, its latest value and its sources.

import Foundation
import HealthKit
import SwiftUI

struct TypeRow: Identifiable, Sendable {
    let id: String
    var title: String
    var count = 0
    var last = "—"
    var sources = ""
    var fired = 0
}

@MainActor
final class HealthCheck: ObservableObject {
    static let shared = HealthCheck()

    #if os(watchOS)
    let role = "watch"
    #else
    let role = "phone"
    #endif
    @Published var rows: [TypeRow] = []
    @Published var state = "starting"
    private let store = HKHealthStore()
    private let lock = NSLock()
    nonisolated(unsafe) private var file: FileHandle?

    /// (identifier, title, unit for display or nil for a category)
    static let watched: [(String, String, String?)] = [
        (HKQuantityTypeIdentifier.heartRate.rawValue, "Heart rate", "count/min"),
        (HKQuantityTypeIdentifier.restingHeartRate.rawValue, "Resting HR", "count/min"),
        (HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue, "HRV (SDNN)", "ms"),
        (HKQuantityTypeIdentifier.oxygenSaturation.rawValue, "Blood oxygen", "%"),
        (HKQuantityTypeIdentifier.respiratoryRate.rawValue, "Respiratory rate", "count/min"),
        (HKQuantityTypeIdentifier.stepCount.rawValue, "Steps", "count"),
        (HKQuantityTypeIdentifier.distanceWalkingRunning.rawValue, "Distance", "m"),
        (HKQuantityTypeIdentifier.activeEnergyBurned.rawValue, "Active energy", "kcal"),
        (HKQuantityTypeIdentifier.basalEnergyBurned.rawValue, "Basal energy", "kcal"),
        (HKQuantityTypeIdentifier.flightsClimbed.rawValue, "Flights", "count"),
        (HKCategoryTypeIdentifier.sleepAnalysis.rawValue, "Sleep stages", nil),
        (HKQuantityTypeIdentifier.atrialFibrillationBurden.rawValue, "AFib burden", "%"),
        (HKQuantityTypeIdentifier.appleSleepingBreathingDisturbances.rawValue, "Breathing disturbances", "count"),
        (HKCategoryTypeIdentifier.sleepApneaEvent.rawValue, "Sleep apnea events", nil),
        (HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue, "Irregular rhythm", nil),
        ("HKDataTypeIdentifierElectrocardiogram", "ECG", nil),
        ("HKWorkoutTypeIdentifier", "Workouts", nil),
    ]

    static let readOnly: Set<String> = [HKQuantityTypeIdentifier.atrialFibrillationBurden.rawValue,
                                         HKQuantityTypeIdentifier.appleSleepingBreathingDisturbances.rawValue,
                                         HKCategoryTypeIdentifier.sleepApneaEvent.rawValue,
                                         HKCategoryTypeIdentifier.irregularHeartRhythmEvent.rawValue, "HKDataTypeIdentifierElectrocardiogram"]

    nonisolated func log(_ text: String) {
        #if os(watchOS)
        let role = "watch"
        #else
        let role = "phone"
        #endif
        let line = String(format: "HEALTHCHECK %@ %.3f %@", role, Date().timeIntervalSince1970, text)
        NSLog("%@", line)
        lock.withLock {
            if file == nil {
                let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("healthcheck.log")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                file = try? FileHandle(forWritingTo: url)
                file?.seekToEndOfFile()
            }
            file?.write(Data((line + "\n").utf8))
        }
    }

    static func type(_ id: String) -> HKSampleType? {
        if id == "HKWorkoutTypeIdentifier" { return HKObjectType.workoutType() }
        if id == "HKDataTypeIdentifierElectrocardiogram" { return HKObjectType.electrocardiogramType() }
        if id.hasPrefix("HKQuantityTypeIdentifier") { return HKObjectType.quantityType(forIdentifier: HKQuantityTypeIdentifier(rawValue: id)) }
        if id.hasPrefix("HKCategoryTypeIdentifier") { return HKObjectType.categoryType(forIdentifier: HKCategoryTypeIdentifier(rawValue: id)) }
        return nil
    }

    func start() {
        rows = Self.watched.map { TypeRow(id: $0.0, title: $0.1) }
        log("start pid \(ProcessInfo.processInfo.processIdentifier) available \(HKHealthStore.isHealthDataAvailable()) tmp \(NSTemporaryDirectory())")
        let read = Set(Self.watched.compactMap { Self.type($0.0) as HKObjectType? })
        state = "asking for read access"
        store.requestAuthorization(toShare: nil, read: read) { ok, error in
            self.log("auth requested ok=\(ok) error=\(error.map { "\($0)" } ?? "none")")
            Task { @MainActor in
                self.state = ok ? "observing" : "no access: \(error?.localizedDescription ?? "?")"
                self.observeAll()
            }
        }
    }

    private func observeAll() {
        for (id, _, unit) in Self.watched {
            guard let t = Self.type(id) else { continue }
            let q = HKObserverQuery(sampleType: t, predicate: nil) { [weak self] _, done, error in
                guard let self else { done(); return }
                self.log("observer \(id) fired" + (error.map { " error \($0)" } ?? ""))
                Task { @MainActor in
                    if let i = self.rows.firstIndex(where: { $0.id == id }) { self.rows[i].fired += 1 }
                    self.refresh(id, type: t, unit: unit)
                }
                done()
            }
            store.execute(q)
        }
    }

    private func refresh(_ id: String, type: HKSampleType, unit: String?) {
        let sort = [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
        let q = HKSampleQuery(sampleType: type, predicate: nil, limit: HKObjectQueryNoLimit, sortDescriptors: sort) { [weak self] _, results, error in
            guard let self else { return }
            let samples = results ?? []
            let sources = Set(samples.map(\.sourceRevision.source.name)).sorted()
            var byDevice: [String: Int] = [:]
            for s in samples { byDevice[s.device?.model ?? "no device", default: 0] += 1 }
            let devices = byDevice.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            let synthetic = samples.filter { $0.metadata?["YcodeSynthetic"] != nil }.count
            var last = "—"
            if let s = samples.first {
                if let q = s as? HKQuantitySample, let unit {
                    var v = q.quantity.doubleValue(for: HKUnit(from: unit))
                    var u = unit
                    if unit == "%" { v *= 100 }
                    if unit == "count/min" { u = "bpm" }
                    if u == "count" { u = id.hasSuffix("StepCount") ? "steps" : "" }
                    last = String(format: v.rounded() == v || v >= 10 ? "%.0f %@" : "%.2f %@", v, u).trimmingCharacters(in: .whitespaces)
                } else if let c = s as? HKCategorySample {
                    last = "value \(c.value)"
                } else if let e = s as? HKElectrocardiogram {
                    last = "class \(e.classification.rawValue), \(e.averageHeartRate.map { String(format: "%.0f bpm", $0.doubleValue(for: HKUnit(from: "count/min"))) } ?? "no HR"), \(e.numberOfVoltageMeasurements) points"
                } else if let w = s as? HKWorkout {
                    last = String(format: "%.0f min", w.duration / 60)
                }
            }
            let when = samples.first.map { ISO8601DateFormatter().string(from: $0.startDate) } ?? "-"
            self.log("samples \(id) \(samples.count) sources \(sources.joined(separator: ",")) devices \(devices.replacingOccurrences(of: " ", with: ":")) last \(last) at \(when) synthetic \(synthetic)"
                + (error.map { " error \($0)" } ?? ""))
            Task { @MainActor in
                guard let i = self.rows.firstIndex(where: { $0.id == id }) else { return }
                self.rows[i].count = samples.count
                self.rows[i].last = last
                self.rows[i].sources = devices
                // Types with data first, in the table's order.
                let order = Dictionary(uniqueKeysWithValues: Self.watched.enumerated().map { ($1.0, $0) })
                self.rows.sort { ($0.count > 0 ? 0 : 1, order[$0.id] ?? 0) < ($1.count > 0 ? 0 : 1, order[$1.id] ?? 0) }
            }
        }
        store.execute(q)
    }
}

@main
struct HealthCheckApp: App {
    @StateObject private var model = HealthCheck.shared

    var body: some Scene {
        WindowGroup {
            #if os(watchOS)
            List(model.rows) { r in
                VStack(alignment: .leading) {
                    Text(r.title).font(.headline)
                    Text("\(r.count) · \(r.last)").font(.caption)
                }
            }
            .onAppear { if model.rows.isEmpty { model.start() } }
            #else
            NavigationStack {
                List {
                    Section("Read-only types (seeded by Ycode)") {
                        ForEach(model.rows.filter { HealthCheck.readOnly.contains($0.id) }) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.title).font(.headline)
                                    Spacer()
                                    Text("\(r.count)").monospacedDigit()
                                }
                                Text(r.last + (r.sources.isEmpty ? "" : " · " + r.sources)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section("Written by Ycode's health agent") {
                        ForEach(model.rows.filter { !HealthCheck.readOnly.contains($0.id) }) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(r.title).font(.headline)
                                    Spacer()
                                    Text("\(r.count)").monospacedDigit()
                                }
                                Text(r.last + (r.sources.isEmpty ? "" : " · " + r.sources)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section { Text(model.state).font(.caption) }
                }
                .navigationTitle("Health Check")
            }
            .onAppear { if model.rows.isEmpty { model.start() } }
            #endif
        }
    }
}
