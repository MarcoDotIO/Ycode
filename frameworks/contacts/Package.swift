// swift-tools-version: 6.0
// ycode-contacts: open, Linux-buildable Contacts written from specs/frameworks/contacts/.
import PackageDescription

let package = Package(
    name: "ycode-contacts",
    platforms: [.macOS(.v14)],
    products: [
        // The library module carries the Apple framework's module name (an
        // interop identifier) so that `import Contacts` source compiles.
        .library(name: "Contacts", targets: ["Contacts"]),
    ],
    targets: [
        // The system SQLite 3 library (public domain): libsqlite3 from the
        // macOS SDK, libsqlite3-dev on Linux.
        .systemLibrary(
            name: "CSQLite",
            path: "Sources/CSQLite",
            providers: [.apt(["libsqlite3-dev"])]
        ),
        .target(
            name: "Contacts",
            dependencies: ["CSQLite"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ContactsTests",
            dependencies: ["Contacts"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
