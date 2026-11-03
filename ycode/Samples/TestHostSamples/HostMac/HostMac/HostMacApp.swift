import SwiftUI

/// What the hosted tests check: code that lives in the app, not in a framework.
enum Arithmetic {
    static func add(_ a: Int, _ b: Int) -> Int { a + b }
}

/// Set once the app has finished launching (hosted tests run after that).
@MainActor enum LaunchState {
    static var launched = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { LaunchState.launched = true }
    }
}

@main
struct HostMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            Text("HostMac \(Arithmetic.add(2, 3))")
                .padding(40)
        }
    }
}
