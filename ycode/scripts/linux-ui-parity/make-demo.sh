#!/bin/sh
# Writes the "Greeter" package that both IDEs open for the paired
# screenshots of docs/PARITY.md §5.10: a library, an executable that uses
# it and a test target. main.swift ends with a deliberate error, so a build
# fails with one issue (the Issue navigator, the bezel, the build log).
#
#     make-demo.sh <folder>        # writes <folder>/Greeter
set -e
[ -n "$1" ] || { echo "usage: $0 <folder>" >&2; exit 2; }
P="$1/Greeter"
rm -rf "$P"
mkdir -p "$P/Sources/GreeterCore" "$P/Sources/Greeter" "$P/Tests/GreeterCoreTests"
cat > "$P/Package.swift" <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Greeter",
    targets: [
        .target(name: "GreeterCore"),
        .executableTarget(name: "Greeter", dependencies: ["GreeterCore"]),
        .testTarget(name: "GreeterCoreTests", dependencies: ["GreeterCore"]),
    ]
)
EOF
cat > "$P/Sources/GreeterCore/Greeting.swift" <<'EOF'
/// A greeting for one person.
public struct Greeting: Sendable {
    public var name: String
    public var exclaims = true

    public init(name: String) {
        self.name = name
    }

    /// "Hello, <name>!" (or with a full stop).
    public var text: String {
        let mark = exclaims ? "!" : "."
        return "Hello, \(name)\(mark)"
    }
}
EOF
cat > "$P/Sources/Greeter/main.swift" <<'EOF'
import GreeterCore

// Prints a greeting for each argument.
let names = CommandLine.arguments.dropFirst()
for name in names.isEmpty ? ["world"] : Array(names) {
    print(Greeting(name: name).text)
}
let count: Int = "three"  // deliberate error
EOF
cat > "$P/Tests/GreeterCoreTests/GreetingTests.swift" <<'EOF'
import Testing
@testable import GreeterCore

@Test func greetsByName() {
    #expect(Greeting(name: "Ada").text == "Hello, Ada!")
}
EOF
echo "$P"
