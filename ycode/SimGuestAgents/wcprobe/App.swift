// WCProbe's app entry (both sides): a SwiftUI app that starts the probe
// (Probe.swift) when it launches. The phone shows one line of text; the watch
// a list of 60 rows (round W3b, watchos.md §12: the Digital Crown scrolls it)
// whose scroll offset is logged ("scroll offset …", at most every 0.5 s),
// below a button that is the primary action of the watch's double tap
// (logged "primary action …", watchos.md §13).

import SwiftUI

@main
struct WCProbeApp: App {
    init() { Probe.shared.start() }

    var body: some Scene {
        WindowGroup {
            #if os(watchOS)
            List {
                // watchos.md §5.2, §13: the system's double tap (a GenericGesture
                // HandTap event) runs the primary action; the probe logs it.
                Button("Primary action") { Probe.shared.primaryAction() }
                    .handGestureShortcut(.primaryAction)
                ForEach(1...60, id: \.self) { n in
                    Text(n == 1 ? "WCProbe watch" : "Row \(n)")
                }
            }
            .onScrollGeometryChange(for: Double.self, of: { Double($0.contentOffset.y) }) { _, y in
                Probe.shared.scrolled(to: y)
            }
            #else
            Text("WCProbe " + Probe.shared.role)
            #endif
        }
    }
}
