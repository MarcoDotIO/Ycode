Ycode's own minimal C headers for compiling third-party sources (LLVM's
libunwind) into libSystem freestanding, on Linux or macOS, without an SDK.
They declare only what those sources use, with the public Darwin arm64
types and layouts (specs/macos/libsystem.md §13). They are not a general
SDK: programs are still compiled against the macOS SDK on a Mac.
