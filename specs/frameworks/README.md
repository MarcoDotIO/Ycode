# Framework specifications (open-frameworks track)

Clean-room specifications of Apple frameworks that Ycode reimplements as open
source, buildable on Linux (see `docs/FUTURE.md`), written under the
clean-room protocol of `AGENTS.md`. Each framework has its own directory:

    specs/frameworks/<framework>/      lowercase framework name, e.g. arkit, realitykit
        README.md                      scope, file index, status, evidence summary

The rest of the layout is up to each framework. A framework spec should cover
the public interface (type and member names are interop facts; descriptions
are in our own words, never copied documentation or declarations), observed
behavior, the reference simulator's behavior as a baseline, an implementation
plan in rounds, and an Evidence section per file (levels from `AGENTS.md`
rule 4).

| Directory | Framework |
|---|---|
| `arkit/` | ARKit |
| `realitykit/` | RealityKit |
| `homekit/` | HomeKit |
| `weatherkit/` | WeatherKit (with the Core Location pieces weather apps need) |
| `swiftui/` | SwiftUI |
| `healthkit/` | HealthKit |
| `mapkit/` | MapKit (with the Core Location pieces map apps need) |
| `eventkit/` | EventKit and EventKitUI |
| `contacts/` | Contacts and ContactsUI |
| `storekit/` | StoreKit (StoreKit 2 and 1 against the local test store, StoreKit Testing, the `.storekit` file and Xcode's StoreKit tooling) |
