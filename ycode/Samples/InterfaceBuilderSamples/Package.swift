// swift-tools-version:5.9
// A small package holding Interface Builder documents written for Ycode's
// tests and drivers (specs/ide/interface-builder.md). The documents are in
// Interface/, outside the target, so building the package ignores them.
import PackageDescription

let package = Package(
    name: "IBSample",
    targets: [.target(name: "IBSample")]
)
