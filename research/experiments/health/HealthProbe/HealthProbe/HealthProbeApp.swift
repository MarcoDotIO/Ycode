import SwiftUI

@main
struct HealthProbeApp: App {
    @StateObject private var model = PhoneModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(model)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: PhoneModel

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Watch", value: m.watchState)
                    LabeledContent("Mac receiver", value: m.receiverState)
                    LabeledContent("From watch", value: "\(m.received)")
                    LabeledContent("Phone store samples", value: "\(m.phoneSamples)")
                    LabeledContent("Forwarded", value: "\(m.forwarded)")
                    if !m.status.isEmpty { Text(m.status).font(.footnote) }
                }
                Section("Actions") {
                    Button("Allow Health access") { m.requestAuthorization() }
                    Button("Start outdoor walk on watch") { m.startOnWatch(location: .outdoor) }
                    Button("Start indoor walk on watch") { m.startOnWatch(location: .indoor) }
                }
                Section {
                    Text("Keep this app open during the probe workout. It reads only samples that start after the workout begins, and sends their timings to the receiver on your Mac over the local network.")
                        .font(.footnote)
                }
            }
            .navigationTitle("HealthProbe")
        }
    }
}
