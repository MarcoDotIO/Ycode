// `health seed` (health-simulation.md §8.6 H-13…H-15, round HEALTH-3): the
// read-only types (sleep apnea events, breathing disturbances, AFib burden,
// irregular-rhythm events, ECG classifications) written into a shut-down
// device's store under its own system source, after a backup of the store
// (HealthSeed.swift has the rows). Apps read them through the public API
// after the next boot. ECGs have no waveform (H-14). Live insertion into a
// running device is not offered (H-15).

import Foundation
import YcodeHealthStore
import YcodeSimFeatures

enum HealthSeeding {
    static let ecgGap = "seeded ECGs have a classification, an average heart rate and symptoms but no voltage measurements "
        + "(the waveform's store format is not known; health-simulation.md H-14)"

    static func handle(_ command: HealthCommand, files: HealthDeviceFiles, now: Date) -> String {
        let store = files.store
        guard store.exists else { return "error health seed: the device has no health store yet (boot it once)" }
        let samples: [HealthSample]
        switch command {
        case .seedFile(let path):
            do {
                let f = try HealthImport.read(path: path, now: now, seeding: true)
                samples = f.readOnly + f.samples
            } catch {
                return "error \(path): \(error)"
            }
        case let .seedScenario(name, date, days, seed):
            // Without --date: ending with the last complete day (no sample in the future).
            var o = HealthScenarioOptions(date: date.flatMap { HealthCommand.parseDay($0, timeZone: .current) } ?? now.addingTimeInterval(-86400 * Double(days)))
            o.days = days
            o.seed = seed
            o.withReadOnly = true
            do { samples = try HealthScenarios.generate(name, o).seeded } catch { return "error \(error)" }
        default:
            return "error not a seed command"
        }
        guard !samples.isEmpty else { return "error health seed: nothing to seed" }
        let family = DeviceLayout.recordedDeviceType(in: files.dev).flatMap { DeviceType.named($0)?.family }
        let model = family == .watch ? "Watch" : "iPhone"
        do {
            let backup = try store.backup(into: files.backupsPath, reason: "seed", now: now)
            let r = try store.seed(samples, model: model, now: now)
            var line = "ok \(r); backup \(backup); apps read them after the next boot"
            if samples.contains(where: { $0.type == HealthTypes.ecg }) { line += "; " + ecgGap }
            return line
        } catch {
            return "error health seed: \(error) (the store is unchanged)"
        }
    }
}
