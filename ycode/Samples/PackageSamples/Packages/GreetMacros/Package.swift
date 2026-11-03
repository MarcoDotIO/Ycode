// swift-tools-version: 5.9
// A macro package for the package samples: `#greeting("name")` expands to a
// string literal at compile time. The macro implementation is built for the
// host and loaded by the compiler (swift-syntax, Apache-2.0, is fetched by
// SwiftPM).
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "GreetMacros",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GreetMacros", targets: ["GreetMacros"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0")],
    targets: [
        .macro(name: "GreetMacrosPlugin", dependencies: [
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
        ]),
        .target(name: "GreetMacros", dependencies: ["GreetMacrosPlugin"]),
    ]
)
