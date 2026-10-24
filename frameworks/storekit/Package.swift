// swift-tools-version:6.0
//
// ycode-storekit: an open, Linux-buildable StoreKit Testing stack written from
// specs/frameworks/storekit/ under the clean-room protocol of AGENTS.md.
//
// Modules (plan.md rounds):
//   StoreKitConfiguration  R2  the `.storekit` file model (Ycode-named; an
//                              IDE dependency, not an Apple API)
//   StoreKitEngine         R7  the open local store (catalog, per-app store,
//                              subscription scheduler, offers, Ask to Buy,
//                              refunds, failures) with an injectable clock
//   StoreKitSigning        R8  per-device P-256 identity, X.509, JWS builders
//                              and verifier, product JSON, payloads, receipt
//   StoreKit, StoreKitTest R9  the client APIs over the engine; they carry the
//                              Apple framework module names (interop
//                              identifiers) so `import StoreKit` source compiles
import PackageDescription

let package = Package(
    name: "ycode-storekit",
    platforms: [.macOS(.v15), .iOS(.v18), .tvOS(.v18), .watchOS(.v11), .visionOS(.v2)],
    products: [
        .library(name: "StoreKitConfiguration", targets: ["StoreKitConfiguration"]),
        .library(name: "StoreKitEngine", targets: ["StoreKitEngine"]),
        .library(name: "StoreKitSigning", targets: ["StoreKitSigning"]),
        .library(name: "StoreKit", targets: ["StoreKit"]),
        .library(name: "StoreKitTest", targets: ["StoreKitTest"]),
    ],
    dependencies: [
        // Apache-2.0. P-256 ECDSA, SHA-1/256/384 for JWS signing and the receipt.
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")
    ],
    targets: [
        .target(name: "StoreKitConfiguration", path: "Sources/StoreKitConfiguration"),
        .target(
            name: "StoreKitEngine",
            dependencies: ["StoreKitConfiguration"],
            path: "Sources/StoreKitEngine"
        ),
        .target(
            name: "StoreKitSigning",
            dependencies: [
                "StoreKitConfiguration", "StoreKitEngine",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/StoreKitSigning"
        ),
        .target(
            name: "StoreKit",
            dependencies: ["StoreKitConfiguration", "StoreKitEngine", "StoreKitSigning"],
            path: "Sources/StoreKit"
        ),
        .target(
            name: "StoreKitTest",
            dependencies: ["StoreKit", "StoreKitConfiguration", "StoreKitEngine"],
            path: "Sources/StoreKitTest"
        ),
        .testTarget(
            name: "StoreKitConfigurationTests",
            dependencies: ["StoreKitConfiguration"],
            path: "Tests/StoreKitConfigurationTests",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "StoreKitEngineTests",
            dependencies: ["StoreKitEngine", "StoreKitConfiguration"],
            path: "Tests/StoreKitEngineTests"
        ),
        .testTarget(
            name: "StoreKitSigningTests",
            dependencies: [
                "StoreKitSigning", "StoreKitEngine", "StoreKitConfiguration",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/StoreKitSigningTests"
        ),
        .testTarget(
            name: "StoreKitAPITests",
            dependencies: ["StoreKit", "StoreKitTest", "StoreKitEngine", "StoreKitSigning", "StoreKitConfiguration"],
            path: "Tests/StoreKitAPITests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
