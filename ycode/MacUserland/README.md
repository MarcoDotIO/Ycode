# MacUserland: Ycode's own macOS userland

Ycode's dynamic linker and libSystem for running macOS arm64 programs with
`ycode-simd --macos` on arm64 Linux. All code here is original Ycode code
(MIT), written from the specs:

- `specs/macos/macos-apps.md`: the design, the options and the staged plan;
- `specs/macos/dyld.md`: the dynamic linker (`dyld/`);
- `specs/macos/libsystem.md`: libSystem (`libsystem/`);
- `specs/macos/objc-runtime.md`: the Objective-C runtime (`objc/`, Rust).

No Apple binary, library or source is used. The three kernel, platform and
pthread libraries are Ycode's own from `../SimHostLibs`.

## Layout

| Path | What |
|---|---|
| `dyld/` | The dynamic linker: entry (`ydl_start.S`), loader (`ydl_main.c`), format layer (`ydl_format.c`, host-testable) |
| `libsystem/` | libSystem: initializer, malloc, strings, stdlib, stdio and printf, Blocks runtime, dispatch subset, `dlfcn` |
| `objc/` | `libobjc.A.dylib`: Ycode's Objective-C runtime in Rust (`no_std`) with `objc_msgSend` in assembly; `tests/` conformance programs, `bench/` benchmarks, `run-tests.sh` |
| `common/` | Mach-O format facts and the private dyld↔libSystem table |
| `tools/macho_tool.py` | Retag a platform, check an image has no fixups, write a `.tbd` link stub |
| `tests/` | Host unit tests of the format layer |
| `samples/` | The Milestone A programs (C and Embedded Swift) |
| `build.sh` | Builds `out/root/` (the macOS userland root) and the Swift sample, runs the host tests |
| `run-samples.sh` | Runs the samples under `ycode-simd --macos` and checks output and exit status |

## Build and run (arm64 Linux with KVM)

```sh
. ~/.local/share/swiftly/env.sh
cd ycode
swift build -c release
YCODE=$PWD/.build/release/ycode sh SimHostLibs/build.sh
sh SimShim/build.sh
sh MacUserland/build.sh
# C samples: built on a Mac with `clang -target arm64-apple-macos14.0 -O1 -o <name> samples/<name>.c`
.build/release/ycode-simd --macos <program> [--env K=V]... [--exec-args <arg>...]
sh MacUserland/run-samples.sh .build/release/ycode-simd <dir with the sample binaries>
# Objective-C: needs cargo with the aarch64-apple-darwin target (rustup target add aarch64-apple-darwin)
sh MacUserland/objc/run-tests.sh mac <out dir>          # on a Mac: builds the tests, checks both runtimes
sh MacUserland/objc/run-tests.sh simd .build/release/ycode-simd <dir with the test programs>
```
