# M2 status: workspace, schemes, and build settings (2026-10-11)

## Conformance

| Check | Corpus | Result |
|---|---|---|
| `.xcscheme` / `contents.xcworkspacedata` byte-exact round trip | 50 files (49 written by Xcode) | 49/49 Xcode-written files identical. The 1 tool-written file is rewritten in canonical form |
| Scheme discovery vs `xcodebuild -list -json` | 10 projects with shared schemes | 6 identical. The other 4 lack only local-Swift-package schemes (M3) |
| Build-setting resolution vs `xcodebuild -showBuildSettings` (assigned settings, defaults level probed) | 27 projects, 132 target × configuration pairs | **8,788 / 8,788 settings identical** |

The settings comparison started at 98.3% agreement (6,709/6,828). Closing
the gap found:

- 2 Ycode bugs:
  - an xcconfig `=` inside a condition bracket was taken as the
    assignment `=`;
  - missing-include diagnostics were swallowed.
- 7 undocumented Xcode behaviors, each isolated by a probe and written in
  `specs/build-settings.md` §3–4:
  - the SDKROOT path uses the versioned bundle name;
  - a missing configuration falls back to the project default;
  - `IS_UNOPTIMIZED_BUILD` is derived and ignores user values;
  - previews are gated on an unoptimized Swift build;
  - hardened runtime is dropped for previews only when the product is
    ad-hoc signed;
  - native targets get the `BUILT_PRODUCTS_DIR/include` header-path
    prefix;
  - test bundles get the swift-testing plugin path, and on device
    platforms they are forced to dSYMs.

## Limits of the method

- The defaults level comes from a stripped copy of each project (`ycode
  _strip-settings`), not from Ycode. A real defaults level, built from
  xcspec data, is the next settings task.
- Only settings that the project assigns are compared. Defaults themselves
  are not checked.

## Platforms

`swift build && swift test` pass on macOS arm64 and on Ubuntu 26.04 x86-64
(Swift 6.4): 48 tests. The corpus suite is skipped on Linux because there
is no corpus there.
