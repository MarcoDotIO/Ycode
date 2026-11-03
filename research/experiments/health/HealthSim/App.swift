// HealthSim app shell (original Ycode code). The probe logic is in core.m.
import SwiftUI

#if PHONE
let hsSide = "phone"
#else
let hsSide = "watch"
#endif

@main
struct HealthSimApp: App {
    init() { HSStart(CommandLine.arguments, hsSide) }
    var body: some Scene {
        WindowGroup { Text("HealthSim \(hsSide)") }
    }
}
