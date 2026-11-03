import Algorithms
import SwiftUI

/// Links a remote package (swift-algorithms, Apache-2.0) resolved by Ycode.
@main
struct RemotePackageApp: App {
    static let report = "YCODE-PKG-SAMPLE remote: " + [1, 2, 3, 4, 5, 6].chunks(ofCount: 2).map { "\(Array($0))" }.joined(separator: " ")
    init() { FileHandle.standardError.write(Data((Self.report + "\n").utf8)) }
    var body: some Scene {
        WindowGroup { Text(Self.report).padding() }
    }
}
