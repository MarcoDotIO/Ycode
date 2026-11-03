import LocalKit
import LocalKitDynamicCore
import SwiftUI

/// Links a local package's static product (with a resource bundle) and its
/// dynamic product. Prints one line for the run log, then shows the same.
@main
struct LocalPackageApp: App {
    static let report = "YCODE-PKG-SAMPLE local: \(LocalKit.greeting); \(LocalKitDynamicCore.describe())"
    init() { FileHandle.standardError.write(Data((Self.report + "\n").utf8)) }
    var body: some Scene {
        WindowGroup { Text(Self.report).padding() }
    }
}
