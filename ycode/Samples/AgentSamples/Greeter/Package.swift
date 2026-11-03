// swift-tools-version: 5.9
// A small package the Ycode MCP server's tests drive like an agent would
// (specs/ide/coding-assistant.md, "Ycode implementation"): build, read an
// issue, fix it, test, run.
import PackageDescription

let package = Package(
    name: "Greeter",
    products: [.executable(name: "greet", targets: ["greet"])],
    targets: [
        .target(name: "Greeter"),
        .executableTarget(name: "greet", dependencies: ["Greeter"]),
        .testTarget(name: "GreeterTests", dependencies: ["Greeter"]),
    ]
)
