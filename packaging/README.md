# Packaging

How a clean checkout becomes `Ycode-<version>.dmg` and
`Ycode-<version>-<arch>.flatpak`. The version comes from one place,
[`ycode/VERSION`](../ycode/VERSION). `YcodeReleaseTests` fails when the Swift
constant or the Flatpak metainfo disagrees with it, or when a packaging script
states a version of its own. To change the version, edit `ycode/VERSION`,
`YcodeRelease.version` and the newest `<release>` in the metainfo.

Ycode is not affiliated with or endorsed by Apple Inc. Neither package contains
files from Xcode, an SDK or a simulator runtime, and nothing here downloads or
decrypts Apple's archives.

## Everything the scripts take

| Script | Run on | Output |
|---|---|---|
| `ycode/scripts/make-app.sh [dir]` | macOS | `<dir>/Ycode.app` (default `.build-ide/app`) |
| `ycode/scripts/make-dmg.sh [dir]` | macOS | `<dir>/Ycode-<version>.dmg` and `.sha256` (default `.build-ide/dist`) |
| `packaging/macos/verify-dmg.sh <dmg>` | macOS | checks a built image; `make-dmg.sh` runs it |
| `packaging/flatpak/build-flatpak.sh [dir]` | Linux, x86-64 or aarch64 | `<dir>/Ycode-<version>-<arch>.flatpak`, `<dir>/Ycode-<version>-<arch>.tar.xz`, and a `.sha256` for each (default `packaging/flatpak/out`) |
| `ycode/scripts/version.sh` | any | prints the version |
| `packaging/generate-notices.py` | any | rewrites `THIRD_PARTY_NOTICES.md` |
| `packaging/flatpak/generate-swift-dependencies.py` | any | rewrites `swift-dependencies.json` after a `Package.resolved` changes |

All are non-interactive and exit nonzero on failure.

### macOS variables (all optional)

| Variable | Meaning |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64`, `MACOS_CERTIFICATE_PASSWORD` | A Developer ID Application certificate. It goes into a temporary keychain that is removed at the end. |
| `YCODE_SIGN_IDENTITY` | An identity already in a keychain. Wins over the P12. |
| `NOTARY_KEY_P8_BASE64`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID` | An App Store Connect API key. All three, plus a real identity, turn on notarizing and stapling. |
| `APPLE_TEAM_ID` | When set with a real identity, the script checks the app is signed by this team. |
| `YCODE_ARCHS` | The architectures. `make-dmg.sh` defaults to `arm64 x86_64` (universal); `make-app.sh` alone defaults to `arm64`. |
| `YCODE_BUILD_NUMBER` | `CFBundleVersion`, default 1. |
| `YCODE_BUILD_ROOT` | SwiftPM scratch folder, default `.build-release`. |
| `YCODE_SWB_BUILD_ROOT` | Scratch folder for the swift-build helper, default `/tmp/ycode-release-<uid>`. Its path ends up in the binaries, so it must name nobody. |
| `YCODE_ICON_ICNS` | The icon, default `packaging/icon/Ycode.icns`. |
| `YCODE_APP_MINIMAL=1` | `make-app.sh` only: a quick development app with `ycode-bsp` as its only helper. |
| `YCODE_DMG_SKIP_APP=1` | `make-dmg.sh` only: package the app already in `<dir>/stage`. |
| `YCODE_VERIFY_REQUIRE_GATEKEEPER=1` | `verify-dmg.sh` only: fail when `spctl` rejects the app. Set it in a release that has the secrets. |

With no signing variable the same path gives an ad-hoc signed image, which
Gatekeeper rejects. The scripts never print a secret's value.

### Flatpak variables (all optional)

| Variable | Meaning |
|---|---|
| `YCODE_SOURCE_REF` | The commit to package, default `HEAD`. Only committed files are packaged. |
| `YCODE_SOURCE_TAR` | A tar of the same paths, for a machine without the repository's history. |
| `YCODE_FLATPAK_WORK` | The work folder, default `packaging/flatpak/.work`. |

## The macOS app

```text
Ycode.app/Contents/
  MacOS/Ycode                     the IDE
  Helpers/ycode                   the command line, the MCP server, `ycode sim remote`
  Helpers/ycodebuild              the build tool for projects and workspaces
  Helpers/ycode-bsp               the build server for sourcekit-lsp
  Helpers/ycode-swb               the helper that talks to swift-build
  Helpers/SWBBuildServiceBundle   swift-build's service
  Helpers/SwiftBuild_*.bundle     swift-build's specifications (open source)
  Helpers/ycode-sim-viewer        a window on a simulator device (experimental)
  Helpers/ycode-simhost           a simulator host's service (experimental)
  Helpers/libYcodeTestAgent.dylib the agent for tests hosted in a Mac app
  Resources/simulator-host/       ycode-sim and ycode-sim-serve, to copy to a Linux host
  Resources/Ycode.icns, LICENSE, THIRD_PARTY_NOTICES.md
```

At launch the app puts `Contents/Helpers` first on its `PATH`
(`YcodeRelease.adoptBundledHelpers`), so every tool lookup finds the bundled copy
wherever the app was copied. Helpers are not in `Contents/MacOS` because `ycode`
and `Ycode` are the same name on a case-insensitive disk.

The app needs a developer toolchain on the Mac; it does not ship one.

**Architectures.** The image is universal. Each architecture is a separate SwiftPM
build merged with `lipo`, so it takes about twice as long as one. Set
`YCODE_ARCHS=arm64` for a quicker, smaller image.

**Signing.** Inside out: each helper, then the app. Every executable has the
hardened runtime, and there are **no entitlements**. The app has no JIT and loads
no plug-ins: a preview runs in its own host program, which the toolchain signs. A
tool that needs an exception later must add it here with the reason.

**The image's window** needs no Finder: `packaging/macos/make-dsstore.py` writes the
`.DS_Store` directly, so the build works with nobody logged in and never takes
over a screen. `make-dmg-background.swift` draws the committed
`dmg-background.tiff`.

**`verify-dmg.sh`** mounts the image, copies the app to an empty folder, then
checks the signature with `codesign --verify --deep --strict`, reports `spctl`'s
answer, runs each tool's `--version` with an empty environment, checks linkage and
search paths, searches the binaries for machine paths, and starts the app hidden.
It does not look at the window: open the image once by hand to check the layout.

## The Flatpak

The manifest is `flatpak/io.github.MarcoDotIO.Ycode.yml`, on freedesktop 26.08.
Every download is pinned by SHA-256, and the build itself has no network. The Swift
dependencies are commit archives listed in `flatpak/swift-dependencies.json`;
`prepare-swift-deps.py` turns them into local git repositories for SwiftPM.

A build machine needs `flatpak` and `flatpak-builder`, and user namespaces. On
Ubuntu 24.04, unprivileged user namespaces are restricted by default, so a CI job
first runs `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`.

### It is not really sandboxed

**The Flatpak uses the Swift toolchain installed on your computer, through
`flatpak-spawn --host`. That permission lets Ycode run any program on the host as
you, so this package is a convenient way to install Ycode, not a security
boundary.** Treat it like any other program you run outside a sandbox.

| Permission | Why |
|---|---|
| `--talk-name=org.freedesktop.Flatpak` | `flatpak-spawn --host` reaches the host's toolchain, git and ssh |
| `--filesystem=home`, `--filesystem=/tmp` | Projects. The host's toolchain must see them at the same paths. |
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | The window and the GPU |
| `--socket=pulseaudio` | Sound from a simulator device |
| `--share=network`, `--socket=ssh-auth` | Packages, coding assistants, the link to a simulator host |
| `--device=kvm` (aarch64 only) | `ycode-simd` runs guests under KVM |

`libexec/ycode-host` comes first on the `PATH`. It holds a wrapper for each
host tool (`swift`, `swiftc`, `sourcekit-lsp`, `lldb-dap`, `git`, `ssh`, ...). The
wrapper finds the tool through a login shell (your own shell from the password
database, so a profile written for bash still works where `sh` is dash) and
swiftly's folders. If the tool is missing it says what to install, and the message
reaches the build log.

Projects outside your home folder and `/tmp` are not visible to the app. Add them
with `flatpak override --user --filesystem=<path> io.github.MarcoDotIO.Ycode`.

### What each architecture contains

Both: `ycode-ide`, `ycode`, `ycodebuild`, `ycode-bsp`, `ycode-swb`,
`SWBBuildServiceBundle`, swift-build's and the UI's resources, `ycode-sim-viewer`,
`libYcodeGaugeAgent.so`, `scripts/ycode-ios-build-linux`, SDL 3, the Swift runtime
libraries the tools load (unmodified from swift.org's toolchain), libxml2 2.13 and
libcurl 8.23 for Foundation (the runtime's copies have another soname or no
versioned symbols), 7-Zip 26.05's `7zz` (built from its own source without the RAR
code; a runtime download reads the runtime's disk image with it, as a separate
program), the host-tool wrappers, and the notices.

Both also carry libjpeg (libjpeg-turbo, the SDK's `libjpeg.so.62`) in `lib/`: the
display stream loads it at run time by the soname its header names, and many
distributions have only `libjpeg.so.8`.

aarch64 also: the simulator tools, labelled experimental, in
`/app/lib/ycode-sim`, laid out like the source tree the scripts expect:
`ycode-simd`, `ycode-simhost`, `ycode-airc`, the `SimShim` guest binaries, the
`SimHostLibs` clean-room libraries, `SimGuestFrameworks`, the guest tools, and
`ycode-sim`.

- `ycode-airc` lives in `lib/ycode-sim/airc/` with its own libraries: libLLVM 22,
  a libxml2 2.15 built without ICU, and the runtime's dynamic loader, C library,
  libstdc++, libffi, zlib and zstd (`copy-private-runtime.py`).
  `.build/release/ycode-airc` is a wrapper that starts it under that loader, so
  it runs on a distribution whose C library is older than freedesktop 26.08's
  (libLLVM takes `sinh` and `cosh` at `GLIBC_2.44`; Ubuntu 24.04 has 2.39).
- The guest tools (`ylaunch` and the guest agents of `SimGuestAgents`) are iOS-
  and watchOS-simulator programs, so they build on a Mac with the simulator SDKs:
  `packaging/flatpak/build-guest-tools.sh <dir>`, then
  `YCODE_GUEST_TOOLS=<dir> build-flatpak.sh` puts them in
  `lib/ycode-sim/SimShim/out/guest-tests/stage7`, where `ycode-simd` and
  `ycode-simhost` look first. The release workflow builds them in its
  `guest-tools` job. Without them a device boots but cannot install or launch
  an app.

The simulator needs a runtime from your own copy of the platform tools. No package
contains one.

### The relocatable tarball

`Ycode-<version>-<arch>.tar.xz` holds the same files as the Flatpak's `/app`, under
one top folder (`bin/`, `lib/`, `libexec/`, `share/`), and runs from wherever it is
unpacked:

- Binaries find their libraries through `$ORIGIN` search paths.
- Tools find each other relative to themselves. `YcodeRelease.adoptBundledHelpers`
  puts the package's tools on `PATH` at start, and inside a Flatpak (`FLATPAK_ID`
  set) puts the `libexec/ycode-host` wrappers first.
- `flatpak-spawn --host` is used in one file only, `flatpak/host-tool.sh`. A package
  that wraps this tarball declares `--talk-name=org.freedesktop.Flatpak` for it, for
  the reason given above.

It is built against freedesktop 26.08 (glibc 2.44), so most of it needs that
runtime, or a host with that glibc or newer. The aarch64 simulator tree is the
exception: `ycode-simhost`, `ycode-simd` and the libraries they load need glibc
2.38 or newer, and `ycode-airc` brings its own (above), so the tree runs on a
plain Ubuntu 24.04 host. `ycode`, the IDE and the viewer do not run there (libcurl
needs glibc 2.43 and OpenSSL 3.2, SDL 3 glibc 2.43). Outside a Flatpak the wrappers
are not used and tools come from the host's `PATH`.

`packaging/flatpak/check-sim-tree.sh <tarball> [--runtime-root DIR]` checks the
simulator tree on a host with nothing from the build: the layout and guest
tools, that every simulator program loads, the translator's self-test, the
display stream's JPEG and zlib, `ycode-simhost` check, serve, identity and pair
on a test port, and with a runtime and `/dev/kvm` a device that boots, streams
JPEG frames with tiles, takes a screenshot and stops. The release runs it on
`ubuntu-24.04-arm` (without a runtime).

### Testing the installed package

```sh
flatpak install --user --bundle Ycode-<version>-x86_64.flatpak
flatpak run --user --command=ycode io.github.MarcoDotIO.Ycode --version
# In a Swift package folder under the home folder: builds with the host's SwiftPM.
flatpak run --user --command=ycode io.github.MarcoDotIO.Ycode build
# Under Xvfb on a desktop that also runs Wayland, ask for X11 for the test:
DISPLAY=:97 flatpak run --user --socket=x11 --nosocket=wayland \
    --env=YCODE_IDE_WALK=$HOME/walk io.github.MarcoDotIO.Ycode [<package>]
```

`YCODE_IDE_WALK` (see `ycode/Sources/ycode-ide/ShellDriver.swift`) walks Welcome,
About, Clone and New Project, and with a package path also Build, Test and Run,
writing a screenshot for each step.

## Third-party licences

`THIRD_PARTY_NOTICES.md` is generated and included in each package. Texts that are
in no checkout or vendored folder are in `licenses/`.
