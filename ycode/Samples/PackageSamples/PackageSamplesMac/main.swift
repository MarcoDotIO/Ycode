import Algorithms
import Codegen
import GreetMacros
import LocalKit
import LocalKitDynamicCore

// The package samples' macOS command-line tool: every kind of package
// product in one target.
print("YCODE-PKG-SAMPLE mac local: \(LocalKit.greeting); \(LocalKitDynamicCore.describe())")
print("YCODE-PKG-SAMPLE mac remote: " + [1, 2, 3, 4].chunks(ofCount: 2).map { "\(Array($0))" }.joined(separator: " "))
print("YCODE-PKG-SAMPLE mac macro: " + #greeting("Mac"))
print("YCODE-PKG-SAMPLE mac plugin: \(Codegen.message)")
