# Spec: build settings, xcconfig files, and resolution

Status: **implemented** in `ycode/Sources/YcodeSettings`. Conformance: see the
"Measured agreement" section at the end.

Every claim is level 3 (black-box against `xcodebuild -showBuildSettings`,
Xcode 27.1). The probes are in `research/experiments/settings/` and the
regression tests are in `ycode/Tests/YcodeSettingsTests`.

## 1. xcconfig files

- The file is processed line by line, as UTF-8.
- `//` starts a comment **anywhere on a line, including inside values**. For
  example, `X = http://a` gives `http:`. The usual workaround is `http:/$()/a`.
- A line is either a directive or an assignment:
  - `#include "path"` includes a file. `#include? "path"` includes it only if
    it exists, and is silently skipped otherwise.
  - The include is **textual**: its assignments are spliced in at that
    point.
  - A relative path is resolved against the including file's directory.
  - The prefix `<DEVELOPER_DIR>` expands to the active developer directory.
  - A missing required include produces a diagnostic, and processing
    continues.
- Assignment: `NAME[cond=pattern][cond2=pattern] = value`.
  - Several conditions may also be comma-separated inside one bracket.
  - The `=` that separates name and value is the first one **outside**
    brackets.
  - The value is trimmed, and one trailing `;` is dropped.
  - Names must match `[A-Za-z_][A-Za-z0-9_]*`.

## 2. Values (macro expressions)

| Form | Meaning |
|---|---|
| `$(NAME)`, `${NAME}`, `$NAME` | Reference. The bare form takes `[A-Za-z_][A-Za-z0-9_]*` |
| `$(A_$(B))` | Nested: the name is evaluated first |
| `$(NAME:op1:op2=arg)` | Operators, applied left to right. Arguments may contain references |
| `$$` | A literal `$` |
| `$(inherited)`, or `$(SAME_NAME)` inside SAME_NAME's own value | The next lower applicable assignment of the same setting |
| Undefined name | Empty string |

Binding is **late**: a reference evaluates the referenced setting at full
precedence, not at the level where the reference is written. A cycle
evaluates to empty.

### Operators

| Operator | Result |
|---|---|
| `quote` | Backslash-escapes only space, tab, CR, LF, `'`, `"`, and `\`. Empty stays empty |
| `lower`, `upper` | Unicode-aware case mapping |
| `identifier` | Each character not in `[A-Za-z0-9_]` becomes `_`. A leading ASCII digit is *replaced* with `_` (`9lives` → `_lives`) |
| `c99extidentifier` | Like `identifier`, but non-ASCII letters are kept |
| `rfc1034identifier` | Each character not in `[A-Za-z0-9-]` becomes `-`. A leading digit is replaced with `-` |
| `dir` | Everything up to and including the last `/`, otherwise `./` |
| `file` | Everything after the last `/` |
| `base` | `file` without its last `.suffix` (`.hidden` → empty) |
| `suffix` | From the last `.` of `file`, inclusive, otherwise empty |
| `standardizepath` | For absolute paths: resolves `.` and `..` and drops the trailing `/`. Relative paths are unchanged |
| `absolutepath` | Relative inputs observed unchanged |
| `default=X` | X when the value is empty |
| `not` | `NO` for YES/TRUE/1 (case-insensitive), otherwise `YES` |
| `relativeto=Y` | When both are absolute, the path of **Y relative to the value** (`$(/a/b:relativeto=/a/b/c/d)` = `c/d`). Otherwise the value is unchanged |
| unknown | Value unchanged |

## 3. Levels (lowest to highest)

1. Defaults (platform, SDK, and spec defaults). *Not yet modeled. Supplied
   by the caller.*
2. Built-ins: `PROJECT_DIR`, `SRCROOT`, `SOURCE_ROOT`, `PROJECT_NAME`,
   `PROJECT_FILE_PATH`, `CONFIGURATION`, `TARGET_NAME`, …
3. The project configuration's base xcconfig
4. The project configuration's `buildSettings`
5. The target configuration's base xcconfig
6. The target configuration's `buildSettings`
7. Command-line overrides
8. Derived settings (§4)

A base xcconfig is set either by `baseConfigurationReference` (a file
reference, resolved through the group tree) or by
`baseConfigurationReferenceAnchor` together with
`baseConfigurationReferenceRelativePath` (synchronized folders).

Precedence inside one level:

- **xcconfig:** the last matching line wins.
- **`buildSettings` dictionary:** a matching conditional key such as
  `X[config=Debug]` wins over a plain `X`.

Conditions:

- Parameters: `config`, `sdk`, `arch`, `variant`.
- Patterns are globs that use `*`.
- `sdk` is matched against the canonical SDK name (`macosx27.0`). That name
  comes from the `CanonicalName` in the resolved SDK's `SDKSettings.json`. If
  the SDK cannot be resolved, the literal `SDKROOT` value is used.
- An assignment whose parameter has no value in the context matches only
  the pattern `*`.

If the requested configuration is missing from the project, every level
uses the project's `defaultConfigurationName` (and so does `CONFIGURATION`).

## 4. Derived settings

These are computed after resolution and override every level. Command-line
overrides cannot get past them.

- `SDKROOT` becomes the path of the resolved SDK. The name used is the
  versioned bundle name: `…/MacOSX27.0.sdk`, even when that name is a symlink
  to `MacOSX.sdk`. An SDKROOT that cannot be resolved stays as written.
- `IS_UNOPTIMIZED_BUILD` is `YES` when `GCC_OPTIMIZATION_LEVEL` is `0` or
  `SWIFT_OPTIMIZATION_LEVEL` is `-Onone`, otherwise `NO`. User assignments
  are ignored.
- If `ENABLE_PREVIEWS` is true:
  - In an unoptimized build with `SWIFT_VERSION` set, and only when the
    product is ad-hoc signed (`CODE_SIGN_IDENTITY = -`),
    `ENABLE_HARDENED_RUNTIME = NO`.
  - Otherwise `ENABLE_PREVIEWS`, `ENABLE_DEBUG_DYLIB`, and
    `ENABLE_XOJIT_PREVIEWS` are all set to `NO`.
- For native targets (`PBXNativeTarget`), `HEADER_SEARCH_PATHS` becomes
  `$(BUILT_PRODUCTS_DIR)/include ` + value. This applies even when the
  setting is assigned without `$(inherited)`. Aggregate targets do not get
  the prefix.
- For test bundles (`…bundle.unit-test`, `…bundle.ui-testing`):
  - `OTHER_SWIFT_FLAGS` gets
    `-plugin-path $(TOOLCHAIN_DIR)/usr/lib/swift/host/plugins/testing`
    appended, separated by one space.
  - On device platforms (not macOS and not a simulator),
    `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`.

## 5. Output conventions of `xcodebuild -showBuildSettings`

- Settings with an empty value are omitted from `-json` output.
- Array-valued `buildSettings` entries are joined with single spaces.

## Measured agreement

The comparison is `research/experiments/settings/compare.py`. It covers every
target × {Debug, Release} of the 27-project local corpus. For each pair, every
setting the project assigns is compared with `xcodebuild`, and the defaults
level is taken from a settings-stripped copy of the project. The run on
2026-10-11 compared 8,788 settings. The result is recorded in
`research/notes/m2-status.md`.

## Open questions

- Defaults level: load spec defaults from the installed toolchain's
  `.xcspec` files (data files, interop), or from Swift Build's open-source
  specs.
- `[arch=…]` conditions under `-showBuildSettings`, where no arch is chosen.
- Whether two different matching conditional keys in one `buildSettings`
  dictionary resolve in key order.
- `absolutepath` on relative input against a project directory.
- An unresolvable SDK such as `macosx.internal` gives
  `EFFECTIVE_PLATFORM_NAME = -unknown` in Xcode. This is not modeled.
