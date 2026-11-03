import Foundation

// A sandboxed macOS app signed ad hoc with its entitlements
// (specs/ide/signing.md §4): inside the App Sandbox the home folder is the
// app's container. Prints one line and exits.
let home = NSHomeDirectory()
let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil || home.contains("/Library/Containers/")
let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Bundle.main.bundleIdentifier.map { $0 + ".shared" } ?? "")
print("YCODE-SIGNING-SAMPLE sandboxed=\(sandboxed) appGroupContainer=\(group == nil ? "none" : "yes")")
