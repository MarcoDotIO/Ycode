import HealthKit
import SwiftUI
import WatchKit

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// Called when the phone starts the probe through HKHealthStore.startWatchApp(with:).
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        DispatchQueue.main.async { WorkoutManager.shared.start(configuration: workoutConfiguration) }
    }
}

@main
struct HealthProbeWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate
    @StateObject private var manager = WorkoutManager.shared

    var body: some Scene {
        WindowGroup {
            WatchView().environmentObject(manager)
        }
    }
}

struct WatchView: View {
    @EnvironmentObject var m: WorkoutManager

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("HealthProbe").font(.headline)
                Text(m.status).font(.footnote).foregroundStyle(.secondary)
                if m.running {
                    Text(m.lastHeartRate.map { String(format: "%.0f bpm", $0) } ?? "-- bpm").font(.title2)
                    Text("sent \(m.sentCount)").font(.footnote)
                    Button("End", role: .destructive) { m.end() }
                } else {
                    Button("Allow Health access") { m.requestAuthorization() }
                    Toggle("Save to Health", isOn: $m.saveToHealth)
                    Button("Outdoor walk") { m.start(activity: .walking, location: .outdoor) }
                    Button("Indoor walk") { m.start(activity: .walking, location: .indoor) }
                    Button("Outdoor run") { m.start(activity: .running, location: .outdoor) }
                    Button("Other") { m.start(activity: .other, location: .unknown) }
                }
            }
        }
    }
}
