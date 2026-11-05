# Spec: the Swift runtime and Foundation in Ycode's macOS userland

Status: **implemented for stage B, part 1 (1.0.0-beta.3, #87)**: the full
(non-embedded) Swift runtime and standard library, Concurrency, and
swift-foundation's FoundationEssentials run under `ycode-simd --macos` on
the arm64 Linux host. URLSession and the rest of `Foundation` are not done
yet (`macos-apps.md` §9.4 says why and what it takes). Ycode design, clean
room.

Sources: the open Swift repository (`swiftlang/swift`, tag
`swift-6.4.0-RELEASE`: the runtime build in `Runtimes/`, the runtime's own
source for how it uses the Objective-C runtime and libSystem), LLVM
(`swiftlang/llvm-project` at the same tag: libc++, libc++abi, libunwind,
libc, compiler-rt), `swift-foundation`, `swift-collections` 1.1.6 and
`swift-experimental-string-processing`, all Apache-2.0 (LLVM's with the
LLVM exception, Swift's with the Runtime Library Exception); the macOS
SDK's public C headers for declarations, constants and layouts; and the
Ycode specs `libsystem.md`, `dyld.md` and `objc-runtime.md`. No Apple
binary is linked into or copied into the userland, and no Objective-C
runtime source was read.

## 1. What runs

A Swift program built for `arm64-apple-macos` against Ycode's macOS SDK
(§5) loads, under Ycode's dyld, Ycode's libSystem and libobjc, LLVM's
libc++, and these libraries in `/usr/lib/swift`:

| Library | From | Contents |
|---|---|---|
| `libswiftCore.dylib` | Swift `Runtimes/Core` | The runtime and the standard library |
| `libswiftSwiftOnoneSupport.dylib` | Swift `Runtimes/Core` | Pre-specializations that `-Onone` code imports |
| `libswift_Concurrency.dylib` | Swift `Runtimes/Core` | async/await, tasks, actors; global executor on dispatch |
| `libswiftSynchronization.dylib`, `libswiftObservation.dylib` | Swift `Runtimes/Supplemental` | `Mutex`, atomics; Observation |
| `libswift_StringProcessing.dylib`, `libswift_RegexParser.dylib`, `libswiftRegexBuilder.dylib` | Swift `Runtimes/Supplemental` + string-processing | Regex |
| `libswiftDarwin.dylib` | §4 | The Darwin overlay |
| `libswiftos.dylib` | §4 | The `os` overlay (logging) |
| `libFoundationEssentials.dylib` | swift-foundation | `Date`, `Data`, `URL`, `JSONEncoder`/`JSONDecoder`, property lists, `FileManager`, `ProcessInfo`, `Calendar` (Gregorian), `TimeZone` (GMT and fixed offsets), `Locale` (en_US_POSIX), format styles that need no ICU, `UUID`, `Predicate`, `NotificationCenter` |

The stage-B sample (`ycode/MacUserland/samples/foundation.swift`) uses
`Date`, `JSONEncoder`/`JSONDecoder` with ISO 8601 dates, and `FileManager`
(create, write, read, list, walk, copy, move, remove); its output on the
arm64 Linux host matches `samples/foundation.expected` (§9).

## 2. Objective-C interop: both configurations, and the choice

On Darwin targets the Swift compiler and runtime normally run with
Objective-C interoperability: Swift classes are Objective-C classes
(`SwiftObject` is an Objective-C root class), `AnyObject` dynamic casts and
the error bridge go through the Objective-C runtime, and the compiler
emits `objc_opt_self`, `_objc_empty_cache` and class-list sections for
every Swift class. The runtime build has a switch for it
(`SwiftCore_ENABLE_OBJC_INTEROP`).

Both were built and run (2026-11-05, the Thor):

| Configuration | Build | Hello-world class/generic/closure program |
|---|---|---|
| Without interop (`SwiftCore_ENABLE_OBJC_INTEROP=OFF`, C/C++ `-DSWIFT_OBJC_INTEROP=0`, Swift `-Xfrontend -disable-objc-interop` for the stdlib and every client) | Builds; the C++ side needs the explicit `SWIFT_OBJC_INTEROP=0`, because the runtime's `Config.h` turns interop on for every `__APPLE__` target | Runs. 115 imports, none from libobjc |
| With interop (the Apple default) on Ycode's Rust Objective-C runtime | Builds unchanged | Runs, after the runtime gained the Swift entry points (`objc-runtime.md` §15). Classes, generic classes (instantiated through `objc_readClassPair`), inheritance, `deinit`, weak references, `as?`/`is` casts to classes and protocols, `Mirror`, thrown errors all behave as on a Mac |

**Decision: Ycode ships the interop configuration.** It is the
configuration every Swift binary built for macOS by Apple's toolchain
assumes (a binary built without interop cannot run on a Mac, and the
reverse), so only it keeps the door open for programs built elsewhere.
The no-interop build stays a documented fallback.

## 3. The runtime build

`Runtimes/Core` (the new CMake build of the runtime), with the Apple
vendor caches (`arm64-MacOSX.cmake`, `Darwin.toolchain.cmake`), deployment
target macOS 14.0, and these changes from the caches' defaults:

| Setting | Value | Why |
|---|---|---|
| `SwiftCore_ENABLE_CONCURRENCY` | ON | Swift Concurrency; its global executor is dispatch's (Ycode's, `libsystem.md` §7.3) |
| `SwiftCore_ENABLE_CRASH_REPORTER_CLIENT` | OFF | Apple's CrashReporterClient is not there |
| `SwiftCore_ENABLE_STDLIB_TRACING` | OFF | `os_signpost` tracing |
| `SwiftCore_ENABLE_BACKTRACING` | OFF | The backtracer is a separate program; not built |
| `SwiftCore_HAS_DARWIN_LIBMALLOC` | OFF | Uses malloc zone introspection Ycode does not have |
| `SwiftCore_ENABLE_BACKDEPLOYMENT_SUPPORT`, `..._RUNTIME_FUNCTION_COUNTERS`, `..._STRICT_AVAILABILITY`, `SwiftCore_OPTIMIZATION_REMARKS` | OFF | Not needed |
| `CMAKE_DISABLE_FIND_PACKAGE_SwiftSwiftDirectRuntime` | TRUE | The build otherwise links `libswiftSwiftDirectRuntime.a` from the toolchain, an Apple binary |
| `CMAKE_OSX_SYSROOT` | Ycode's SDK (§5) | Headers from the macOS SDK, link stubs from Ycode: a libSystem function Ycode lacks fails the link |
| `-iframework` for C, C++, Objective-C and Objective-C++ | The macOS SDK's `System/Library/Frameworks` | The interop sources (`SwiftObject.mm`, `ErrorObject.mm`, ...) include CoreFoundation's and Foundation's public headers (and through them CoreGraphics') for declarations. Nothing from any framework is linked: the runtime looks Foundation's classes up by name, and only if a Foundation is loaded. The Swift side never sees these frameworks |

`Runtimes/Supplemental` builds Synchronization, Observation and
StringProcessing (its sources come from swift-experimental-string-processing
through the repository's `Resync.cmake`) against the Core build.

Every dylib gets the install name `/usr/lib/swift/<leaf>` (as on a Mac),
and every `@rpath/` reference between them is rewritten the same way, so
programs need no run path.

## 4. Overlays

The open Swift repository no longer contains the Darwin overlays (they
ship with Apple's SDK). Ycode builds its own:

- **Darwin** (`libswiftDarwin.dylib`): the Swift project's shared platform
  sources (`Platform.swift`, `Math.swift`, `TiocConstants.swift`,
  `tgmath.swift.gyb`), patched for Darwin
  (`swift/patches/swift-platform-darwin.patch`: Darwin's `stdin`/`stdout`
  are `__stdinp`/`__stdoutp`; `SEM_FAILED` is `-1`; `<math.h>` is the
  explicit submodule `_DarwinFoundation1._math` of the SDK's module maps,
  which Ycode's `Darwin.swift` imports), plus Ycode's `Darwin.swift`:
  `POSIXErrorCode` with Darwin's errno values, `DarwinBoolean`, the signal
  handler constants, `MAP_FAILED`.
- **os** (`libswiftos.dylib`): Ycode's own `Logger`, `OSLog`, `OSLogType`,
  `OSLogMessage` (string interpolation with the `privacy:`, `format:` and
  `align:` arguments), `os_log`. Ycode keeps no log store: messages are
  dropped unless `YCODE_OS_LOG` is set, then written to standard error.

## 5. Ycode's macOS SDK

`out/sdk` is what programs compile against:

| Path | Content |
|---|---|
| `usr/include` | The macOS SDK's `usr/include` (a link; public headers only) |
| `usr/lib/libSystem.tbd`, `libobjc.tbd`, `libc++.tbd` | Ycode's link stubs |
| `usr/lib/swift` | The modules and dylibs of §1, `shims/`, `_FoundationCShims/` (the C shim module map FoundationEssentials' clients need) |
| `SDKSettings.json` | Ycode's own, minimal (platform macOS, version 27.0) |

Compile:

```sh
swiftc -target arm64-apple-macos26.0 -sdk out/sdk -runtime-compatibility-version none \
  -Xcc -Iout/sdk/usr/lib/swift/_FoundationCShims main.swift
```

`-runtime-compatibility-version none` keeps the driver from linking the
toolchain's compatibility archives (Apple binaries). The driver still
names the toolchain's `libclang_rt.osx.a` on the link line; Ycode's
libSystem exports the helpers programs reach it for, so no member of it is
pulled in (checked with `-Xlinker -why_load`).

FoundationEssentials needs deployment target 26.0 or later (its own
availability floor); the runtime libraries are built for 14.0.

## 6. libc++

LLVM's libc++ and libc++abi, built as static archives for arm64 macOS 14.0
with the SDK's C headers, and linked whole (`-all_load`) into
`/usr/lib/libc++.1.dylib` against Ycode's libSystem stub. libc++abi's
exceptions use the `_Unwind_*` interface of LLVM's libunwind, which is in
libSystem (`libsystem.md` §13). Its exception globals are a C++
`thread_local`, served by libSystem's thread-local variables (§14 there).

## 7. swift-foundation

swift-foundation's own CMake build, pointed at Ycode's SDK, target
FoundationEssentials only. Two adjustments:

- `SwiftFoundation_MACRO` names an empty directory: FoundationEssentials
  declares the `#Predicate` and `#Expression` macros but expands none, so
  the macro plugin (a host program built from swift-syntax) is not needed
  to build it. Programs that use those macros need the plugin (§10).
- `swift/patches/swift-foundation-modern-data-abi.patch` adds the option
  `SwiftFoundation_MODERN_DATA_ABI`: for Darwin targets the CMake build
  defines `DATA_LEGACY_ABI` (the layout Apple's Foundation keeps for binary
  compatibility) but does not list the source file that implements it.
  Ycode uses the modern layout, as Linux does; nothing Ycode runs depends
  on the legacy one.

## 8. Build

`MacUserland/swift/build.sh`, on a Mac, after `MacUserland/build.sh` (which
produces libSystem, libobjc and their stubs, on Linux or a Mac):
`sources.sh` fetches the projects at their tags; the patches are applied;
then libc++, the runtime, the Supplemental libraries, the overlays and
FoundationEssentials are built, installed into `out/sdk` and
`out/root/usr/lib`, each project's `LICENSE` and `NOTICE` are copied to
`out/root/usr/share/licenses/<project>/`, and the stage-B samples
(`foundation`, `concurrency`) are built.
About 20 minutes on an M3 Max.

## 9. Results (2026-11-05, the Thor)

| Program | Result |
|---|---|
| Hello world with classes, generics, closures, dictionaries (no interop and interop) | Expected output, exit 0 |
| Language test: generic classes, inheritance and `deinit`, `AnyObject` identity, protocol casts, `Mirror`, errors, weak references, Unicode strings, `Double(String)` | Expected output, exit 0 |
| `samples/foundation.swift` (FoundationEssentials) | Matches `foundation.expected`, exit 0 |
| `samples/concurrency.swift` (actors, a task group of 100 tasks, `Task.sleep` on a dispatch timer, a detached task, `MainActor.run`) | Matches `concurrency.expected`, exit 0 |
| Milestone A samples and the Objective-C conformance tests, against the grown libSystem and runtime | Unchanged results (`run-samples.sh`: 8 of 8 with the two above; `objc/run-tests.sh`: 5 of 5 under `ycode-simd`, 10 of 10 on the Mac) |

`tools/check_imports.py` confirms that every import of the program and of
every library in the root is exported by the library it names.

## 10. Not done yet

- `Foundation` as a module (swift-corelibs-foundation: CoreFoundation,
  `NSObject`-based classes, `URLSession` in FoundationNetworking) and
  FoundationInternationalization (ICU): `macos-apps.md` §9.4.
- The `Dispatch` Swift overlay (`import Dispatch`): it needs most of the
  libdispatch API (§9.4 there).
- The Foundation macros plugin.
- Swift classes whose `class_ro` carries a Swift metadata initializer
  (classes with resilient ancestry): `objc-runtime.md` §15.
- Binaries built by Apple's toolchain against Apple's SDK: they link
  Apple's install names (`/System/Library/Frameworks/Foundation.framework`,
  `/usr/lib/swift/libswiftFoundation.dylib`) and the legacy `Data` layout.

## Evidence

| Claim | Level (AGENTS.md rule 4) |
|---|---|
| Runtime build options, overlay sources, swift-foundation build, how the runtime uses the Objective-C runtime | 1 (the open Swift, LLVM and swift-foundation sources) |
| Header layouts and constants (errno values, `sig_t`, the `_math` submodule) | 1 (macOS SDK public headers) |
| Imports of each built library | 2 (Ycode's own builds, inspected with `nm`/`otool`) |
| Run results | 3 (Ycode's own programs under `ycode-simd --macos`) |
| Everything else (the SDK layout, the os overlay, the build) | Ycode design |
