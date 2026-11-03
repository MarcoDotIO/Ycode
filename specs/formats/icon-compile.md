# Spec: compiling `.icon` and asset catalogs (`actool` behaviour)

Status: **specification (round 0)**, 2026-10-30. Reference: `actool` 27.1
(bundle version 25098) in Xcode 27.1 (27A9269); SDKs iOS 27.1, macOS 27.0,
watchOS 27.0, visionOS 27.0, tvOS 27.0.

This spec describes what the asset-catalog compiler does with `.icon`
documents (`icon-format.md`) and with `.xcassets` app icons, as seen from
outside: its arguments, the files it writes, the partial `Info.plist`, and
the renditions it puts in `Assets.car` (container format: `assets-car.md`).
Ycode needs this to build apps whose icon shows on device and simulator, on
macOS and on Linux.

## 1. How Xcode runs the compiler

For a target whose Resources phase contains an asset catalog and an `.icon`,
the build runs three steps (all from swift-build's
`AssetCatalogCompiler.xcspec`, which is open source, Apache-2.0):

1. **GenerateAssetSymbols** — `actool <inputs…> --compile <product dir>
   --output-format human-readable-text --notices --warnings
   --export-dependency-info <tmp>/assetcatalog_dependencies
   --output-partial-info-plist <tmp>/assetcatalog_generated_info.plist
   --app-icon AppIcon --accent-color AccentColor --compress-pngs
   --enable-on-demand-resources YES --development-region en
   --target-device iphone --target-device ipad
   --minimum-deployment-target 27.0 --platform iphonesimulator
   --bundle-identifier <id> --generate-swift-asset-symbol-extensions NO
   --generate-swift-asset-symbols <DerivedSources>/GeneratedAssetSymbols.swift
   --generate-objc-asset-symbols <DerivedSources>/GeneratedAssetSymbols.h
   --generate-asset-symbol-index <DerivedSources>/GeneratedAssetSymbols-Index.plist`.
   An `.icon` adds no symbols.
2. **CompileAssetCatalogVariant thinned** — the same inputs and flags
   (without the symbol flags), compiling into
   `<tmp>/assetcatalog_output/thinned` with
   `<tmp>/assetcatalog_generated_info.plist_thinned` and
   `<tmp>/assetcatalog_dependencies_thinned`. A build for a specific run
   destination adds the thinning filters
   (`--filter-for-thinning-device-configuration`,
   `--filter-for-device-model`, `--filter-for-device-os-version`) when
   `ENABLE_ONLY_ACTIVE_RESOURCES` and `BUILD_ACTIVE_RESOURCES_ONLY` are set.
3. **LinkAssetCatalog** — a built-in task (no process) that takes the
   thinned and unthinned output folders, dependency files and partial
   plists (`--thinned …`, `--unthinned …`, `--output <product>`,
   `--plist-output <tmp>/assetcatalog_generated_info.plist`), copies the
   chosen variant's files into the product ("Emplaced …") and writes the
   final partial plist that `ProcessInfoPlistFile` merges into
   `Info.plist`.

Inputs are positional: every `.xcassets` and every `.icon` of the target, in
build-phase order. Build settings that map to flags (from the xcspec; level
1): `ASSETCATALOG_COMPILER_APPICON_NAME` → `--app-icon`,
`ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` → `--alternate-app-icon`
(repeated), `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS`,
`ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` → `--accent-color`,
`ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME`,
`ASSETCATALOG_COMPILER_STANDALONE_ICON_BEHAVIOR` → `--standalone-icon-behavior
all|none` (omitted for `default`), `COMPRESS_PNG_FILES` →
`--compress-pngs`, `RESOURCES_TARGETED_DEVICE_FAMILY` (derived from
`TARGETED_DEVICE_FAMILY`) → `--target-device`, repeated, with the values
`iphone`, `ipad`, `mac`, `watch`, `tv`, `vision`, `DEVELOPMENT_LANGUAGE` → `--development-region`, the
deployment target → `--minimum-deployment-target`, the platform name →
`--platform` (`iphoneos`, `iphonesimulator`, `macosx`, `watchos`,
`watchsimulator`, `xros`, `xrsimulator`, `appletvos`, `appletvsimulator`).

Output on standard output is in sections: `/* com.apple.actool.errors */`,
`/* com.apple.actool.notices */` (warnings and notices) and
`/* com.apple.actool.compilation-results */` (one written path per line).
`--output-format xml1` gives the same as a plist. The exit status is 1 when
there are errors.

## 2. Inputs and naming rules

- An `.icon` is a **separate input**, next to the catalogs. An `.icon`
  placed **inside** an `.xcassets` folder is ignored (with `--app-icon` set,
  that is an error: "None of the input catalogs contained a matching
  stickers icon set, app icon set, or icon stack named "AppIcon"").
- The icon name is the package name without `.icon` (`AppIcon.icon` →
  `AppIcon`). `--app-icon` must match it; otherwise the same error.
- When an `.appiconset` and an `.icon` have the same name, the `.icon` wins:
  only the `.icon` renditions are written, with no warning.
- Alternate icons: pass more `.icon` inputs and `--alternate-app-icon
  <Name>` for each. Each compiles like the primary icon (stack, groups,
  flattened images) but writes no loose PNGs.
- `supported-platforms` in the document is **not** checked: the icon is
  compiled for whatever `--platform` and `--target-device` say.

## 3. Outputs per platform

For an `.icon` named `AppIcon`:

| Platform (`--target-device`) | Files in the output folder | Partial `Info.plist` |
|---|---|---|
| iOS / iPadOS (`iphone`, `ipad`) | `Assets.car`, `AppIcon60x60@2x.png` (120 px), `AppIcon76x76@2x~ipad.png` (152 px) | `CFBundleIcons` = {`CFBundlePrimaryIcon` = {`CFBundleIconFiles` = [`AppIcon60x60`], `CFBundleIconName` = `AppIcon`}}; `CFBundleIcons~ipad` = {`CFBundlePrimaryIcon` = {`CFBundleIconFiles` = [`AppIcon60x60`, `AppIcon76x76`], `CFBundleIconName` = `AppIcon`}} |
| macOS (`mac`) | `Assets.car`, `AppIcon.icns` | `CFBundleIconFile` = `AppIcon`, `CFBundleIconName` = `AppIcon` |
| watchOS (`watch`) | `Assets.car` only | `CFBundleIcons` = {`CFBundlePrimaryIcon` = {`CFBundleIconName` = `AppIcon`}} |
| visionOS (`vision`) | nothing for the `.icon` (no error, no warning) | — |
| tvOS (`tv`) | `Assets.car` with the `.icon`'s colours and images as ordinary assets, but **no** app icon; warning "None of the input catalogs contained a matching App Icon & Top Shelf Image brand assets collection named "AppIcon"" | — |

Details:

- iOS writes both loose PNGs even when only one device family is targeted.
  The `CFBundleIconName` key is written only in the dictionary of a
  targeted family: with only `iphone`, `CFBundleIcons~ipad` has no
  `CFBundleIconName`; with only `ipad`, `CFBundleIcons` has none.
- The loose PNGs are opaque, full-bleed squares (no mask, no alpha) of the
  Default rendition. With `--compress-pngs` they are written in Apple's
  "CgBI" PNG variant (a `CgBI` chunk before `IHDR`, BGR order,
  premultiplied); without it they are ordinary PNGs. Ycode may write
  ordinary PNGs: the iOS runtime reads both (level 1: Apple's PNG
  optimisation is optional, `COMPRESS_PNG_FILES`).
- Alternate icons add `CFBundleAlternateIcons` = {`<Name>` =
  {`CFBundleIconName` = `<Name>`}} inside `CFBundleIcons` and
  `CFBundleIcons~ipad`.
- macOS `AppIcon.icns` contents depend on `--standalone-icon-behavior`:
  default and `none`: `ic13` (128@2x PNG), `ic11` (16@2x PNG), `ic04`
  (16×16 ARGB), `ic07` (128 PNG). `all`: `ic04`, `ic05`, `ic07`–`ic14`
  (every size 16–1024). For iOS the flag made no difference.
- The build writes no files for the `.icon` image assets themselves; they
  live inside `Assets.car`.

## 4. What the `.icon` becomes inside `Assets.car`

Rendition kinds, by facet name (container details in `assets-car.md`):

| Facet name | Kind (`assetutil` AssetType) | Per | Content |
|---|---|---|---|
| `<Icon>` | **IconImageStack** (`<Icon>.iconstack`) | appearance | The layered icon: canvas size, background, groups. |
| `<Icon>/<group name>` | **IconGroup** | appearance (and idiom on watchOS) | One group's layers and their positions. Unnamed groups are `Group`. |
| `<Icon>_Assets/<file name without extension>` | **Vector** (SVG kept as SVG data) or **Image** (PNG decoded to pixels) | — | The layer artwork. |
| `<Icon>_Assets/Color-<n>` | **Color** | — | Each colour used (fills, gradient stops). |
| `<Icon>_Assets/Gradient-<n>`, `system-light`, `system-dark` | **Named Gradient** | — | Gradient fills. |
| `<Icon>` | **MultiSized Image** | idiom | The list of flattened sizes. |
| `<Icon>` | **Icon Image** | idiom × appearance × size | Flattened pre-rendered icon bitmaps (§6). |

The numbering of `Color-<n>` and `Gradient-<n>` follows the compiler's
traversal and has no meaning; Ycode may number them in any order.

### 4.1 Appearances

| Platform | Stack and group appearances | Icon Image appearances |
|---|---|---|
| iOS / iPadOS | light (`UIAppearanceLight`), dark (`UIAppearanceDark`), tinted (`ISAppearanceTintable`) | any (`UIAppearanceAny`), dark, tinted |
| macOS | light (`NSAppearanceNameAqua`), dark (`NSAppearanceNameDarkAqua`), tinted (`ISAppearanceTintable`) | system (`NSAppearanceNameSystem`) only |
| watchOS | light only | any only |

Every appearance gets its own stack and group renditions, even when no
specialization differs. The values in each are the document's values
resolved for that appearance (`icon-format.md` §5: `tinted` entries go to
the tinted appearance; there is no separate "clear" appearance in the
build).

### 4.2 The stack

- Canvas: 1024 × 1024 (iOS, macOS), 1088 × 1088 (watchOS).
- Layer list, **bottom first**: the background, then each visible group from
  the last in `groups` to the first.
- Background: a reference to a Color (solid fill), a Named Gradient
  (gradients; `automatic` → `system-light`; dark with no dark fill →
  `system-dark`), or, with no `fill` at all, a white extended-gray Color
  for light and tinted.
- Per group entry: group opacity, blend mode, and the glass parameters:

| Document (group) | Compiled stack-layer field |
|---|---|
| `opacity` | layer opacity |
| `blend-mode` | layer blend mode |
| `lighting` | "gathers specular by element" flag: set for `individual` (also the default), clear for `combined` |
| `blur-material` | blur strength (0 when absent) |
| `specular` | has-specular flag (default on) |
| `translucency` | translucency value: `value` when enabled (default 0.3), 0 when disabled |
| `shadow.kind` | shadow style: `none` 0, `layer-color` 2, `neutral` 3 |
| `shadow.opacity` | shadow opacity (default 0.5) |
| `specular-highlight-placement` | placement code: absent/`automatic` 0, `outside` 2 (`inside` presumably 1) |
| `refractivity` | strength and depth when enabled, else 0 |

The background entry carries none of these (all zero, not glass).

### 4.3 Groups

- Layer list, **bottom first** (reverse of `layers`). Hidden layers are
  dropped.
- Per layer: frame in canvas points (x, y, width, height; computed as in
  `icon-format.md` §4.4, including the group's `position`), blend mode,
  opacity, a reference to the artwork rendition, and:
  - the lighting-effects flag = `glass` (default on);
  - the fill: when the layer has a Fill, the name of the Color or Gradient
    rendition that replaces the artwork colour; empty when the layer keeps
    its own colours.
- SVG artwork is stored once (as SVG data, LZFSE-compressed when that is
  smaller). PNG artwork is stored as an ordinary image rendition.

## 5. Flattened images and sizes

The compiler renders the icon to bitmaps for systems and code paths that do
not draw the layered stack:

| Platform | Sizes (MultiSized Image list, index: size) | Bitmap content |
|---|---|---|
| iOS / iPadOS | 1: 1024 × 1024 at 1x, for each of `phone` and `pad` | Opaque full-bleed square, no mask (the system applies the shape). One per appearance: any, dark, tinted. |
| watchOS | 1: 1024 × 1024, idiom `watch` | Opaque full-bleed square. |
| macOS | 1: 16, 2: 32, 3: 64, 4: 128, 5: 256, 6: 512 (each stored at 2x), 7: 1024 (1x) | The finished macOS icon: the 824 × 824 rounded rectangle at offset (100, 100) of the 1024 canvas, with its drop shadow outside it, on transparency. The three smallest are stored in a packed atlas (`assets-car.md` §7.6). |

Rendition names of the flattened bitmaps look like
`AppIcon1024x1024_<AppearanceName>_<UUID>-<number>-<hex>.png`; they differ
between runs and carry no meaning.

The renderer for these bitmaps is Icon Composer's; a Ycode renderer
(`ICON-RENDER`) only needs to be close, because current systems draw the
layered stack themselves when it is present (`assets-car.md` §9).

## 6. `.appiconset` for comparison

A single-size iOS `.appiconset` (`"idiom": "universal", "platform": "ios",
"size": "1024x1024"`) compiles to the same loose PNGs and partial plist as
an `.icon`, and in `Assets.car` to one MultiSized Image and one Icon Image
(1024, index 1) per idiom (`phone`, `pad`) — no stack, no groups. An empty
dark-appearance slot is ignored.

## 7. What Ycode's compile step must do

`ycode actool` (round `ACTOOL-COMPAT`) accepts the same positional inputs
and the flags listed in §1 (unknown flags are an error, like `actool`), and
for each `.icon` and app-icon set:

1. Resolve the icon name, match `--app-icon` and `--alternate-app-icon`,
   apply the precedence of §2.
2. For iOS/iPadOS: write `Assets.car` with at least the flattened tier
   (MultiSized Image + Icon Image per idiom), and the layered tier (stack,
   groups, artwork, colours, gradients) when the input is an `.icon`; write
   the two loose PNGs; write the partial plist of §3.
3. For macOS: the same tiers with the macOS sizes, plus `AppIcon.icns`
   (default set of four entries), and `CFBundleIconFile`/`CFBundleIconName`.
4. For watchOS: the car and `CFBundleIconName` only.
5. For visionOS and tvOS: ignore `.icon` inputs as `actool` does.
6. Print results in the three-section text format, exit 1 on errors.

On macOS Ycode may simply call Apple's `actool` (it is part of Xcode); the
own implementation is for Linux and for builds without Xcode.

## 8. Open questions

- Device builds with thinning: which renditions are dropped for a given
  device model (`--filter-for-thinning-device-configuration`).
- Whether iOS SpringBoard and the simulator accept a car with only the
  layered tier and no flattened images (macOS does; `assets-car.md` §9).
  Needs a dirty-room check on Apple's simulator (owner step, or an OBS
  agent; clean agents must not run Apple's simulator).
- `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS` with `.icon` inputs.
- Localized `.icon` assets in the build.
- watchOS idiom specializations: whether a `square` design is ever written
  for a watch build.

## Evidence

| Claim | Evidence | Level |
|---|---|---|
| Build steps, flags, settings | swift-build's `AssetCatalogCompiler.xcspec` (open source, Apache-2.0; the same file ships in Xcode); `xcodebuild` log of our own sample app (hand-written project, our own icon) | 1, 3 |
| Inputs, naming, precedence, outputs, partial plists, icns entries, PNG form | `xcrun actool` runs on our own icons and catalogs, outputs read with `plutil`, `file`, `iconutil`, and a PNG reader | 3 |
| Renditions, appearances, compiled values | `assetutil --info` on the cars from those runs, and the container fields read per `assets-car.md` (diffing one changed key at a time) | 2, 3 |
| Flattened bitmap geometry | Our own decode of the compiled bitmaps (LZFSE via the system library) | 2 |
| Not used | Disassembly or decompilation (level 5); Apple's sample icons or templates' artwork | — |
