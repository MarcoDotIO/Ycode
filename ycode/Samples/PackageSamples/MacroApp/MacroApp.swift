import GreetMacros
import SwiftUI

/// Uses a Swift macro from a local package; the macro runs in the compiler.
@main
struct MacroApp: App {
    static let report = "YCODE-PKG-SAMPLE macro: " + #greeting("Ycode")
    init() { FileHandle.standardError.write(Data((Self.report + "\n").utf8)) }
    var body: some Scene {
        WindowGroup { Text(Self.report).padding() }
    }
}
