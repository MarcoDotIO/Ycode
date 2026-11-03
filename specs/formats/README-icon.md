# App icons and compiled asset catalogs — specification index and rounds

Status: **round 0 (specification)**, 2026-10-30. Closes the specification
part of gap #15 in `docs/PARITY.md` (".icon is the default app-icon
format") and supplies the dirty-room `Assets.car` spec that gap #9
(**RES-ACTOOL**) waits for.

## Files

| File | Content |
|---|---|
| `icon-format.md` | The `.icon` package: files, every `icon.json` key, value grammars, defaults, appearance and idiom specializations, the six renditions, the `ictool` renderer as a reference |
| `icon-compile.md` | What `actool` does with `.icon` and `.appiconset` inputs: Xcode's invocation, inputs and naming, outputs and partial `Info.plist` per platform, the renditions written, flattened sizes and geometry, what Ycode's compile step must do |
| `assets-car.md` | The `Assets.car` container: BOM blocks and trees, CoreUI header blocks, keys, the CSI rendition record, TLVs, payloads (colour, gradient, multisize, pixels, SVG, layer records), and the minimal set Ycode must write — with what our proof files showed the runtime accepts |

Dirty-room notes behind these: `research/notes/obs-icon-2026-10-30.md`.

## Rounds (one clean agent each)

Every round below is **clean-room**: the agent reads only `specs/`, public
documentation and permissively licensed open source. It must **not** open
the reference tools folder (the Xcode copy, Ghidra, the IPSW),
`research/dirty/`, Ghidra projects, Icon Composer, `ictool`, Apple's
simulator or the Xcode GUI. Running Apple's `actool` and `assetutil` as
black-box comparators is **not** allowed for clean agents either; the
comparisons marked "dirty check" are done by an OBS agent or the owner.

### ICON-READER — read and write `.icon` (S)

**Done 2026-10-30 (ICON-CAR):** module `YcodeIcon` (the brief's name for
`YcodeIconFormat`); `icon-format.md` "Ycode implementation".

- Module: a portable `YcodeIconFormat` library (Foundation only; builds on
  Linux).
- Model: Document, Group, Layer, Fill, Color, Position, BlendMode,
  Specialization<T> exactly as `icon-format.md` §3–§6; unknown keys kept and
  written back.
- Reader: tolerant (any JSON layout, unknown keys, empty groups, missing
  images). Errors for the invalid cases the spec lists (bad blend mode,
  fill, colour space, lighting, appearance, idiom, platform; missing
  `groups`; more than two gradient colours).
- Writer: Icon Composer's layout (`icon-format.md` §2): sorted keys,
  `"key" : value`, two-space indent, five-decimal colours.
- Resolver: `value(for: key, appearance:, idiom:)` per §5, and the layer
  frame maths of §4.4 (including group position).
- Tests: our own sample documents written in the tests; round-trip
  stability; frame examples from §4.4; resolution table of §5.

### ICON-RENDER — render an `.icon` to bitmaps (M–L)

- Input: the ICON-READER model. Output: RGBA bitmaps for the six renditions
  (`icon-format.md` §7) and the compile sizes (`icon-compile.md` §5): iOS
  full-bleed 1024 squares; macOS 824-pt rounded rectangle at (100, 100) with
  a drop shadow, at 16–1024; watchOS 1088 canvas circle.
- Uses OpenViews' renderer when it exists (R5); until then a small software
  compositor is acceptable. SVG rasterization from an open-source library
  with a compatible licence (for example resvg, MIT/Apache-2.0; lunasvg,
  MIT; nanosvg, zlib) — check the licence of the exact version adopted.
- Liquid Glass look: an approximation (specular rim, translucency, shadow
  styles, blur, the tinted and clear monochrome looks) is enough; pixel
  identity is a non-goal (`docs/PARITY.md` §5.5). Current systems draw the
  layered stack themselves (`assets-car.md` §9), so these bitmaps matter
  mainly for older systems, loose PNGs and previews.
- Tests: geometry (layer frames, masks, canvas sizes), blend modes, opacity,
  hidden layers, fills replacing artwork colour. Dirty check (OBS agent):
  mean pixel difference against `ictool` renders of the same documents.

### CAR-WRITER — write `Assets.car` (M)

**Phase 1 done 2026-10-30 (ICON-CAR):** module `YcodeAssetCatalog` (BOM,
car writer and reader, LZFSE, PNG, ICNS, the compiler `ycode assets
compile`, and a small build hook ahead of ACTOOL-COMPAT);
`assets-car.md` §I. Phase 2 (the layered tier) is open.

- Module: a portable `YcodeAssetCatalogCompiler` library (or `YcodeCAR` for
  the container and a separate compiler module), Linux and macOS.
- BOM writer (blocks, variables, trees with leaf splitting and a branch
  root), CoreUI blocks, rendition keys, CSI records, TLVs and payloads per
  `assets-car.md`. LZFSE through the open-source reference implementation
  (BSD-3-Clause) or the system library on macOS.
- Phase 1: tier 1 of `assets-car.md` §9 (images, colours, multisize and icon
  images for iOS, iPadOS, macOS, watchOS keys). Phase 2: tier 2 (stack,
  groups, vectors, gradients, colours) from the ICON-READER model, per
  `icon-compile.md` §4.
- A reader for the same container (for tests and for Ycode's own previews)
  is part of this round.
- Tests: write-then-read round trips; structure checks against the spec
  tables. Dirty check (OBS agent): `assetutil --info` on Ycode's files
  versus `actool`'s for the same inputs, and the macOS runtime loads
  (`NSImage`, `NSColor`, `NSWorkspace` icon) as in `assets-car.md` §9.

### ACTOOL-COMPAT — the build step on macOS and Linux (M)

- A `ycode actool` command with `actool`'s command line (`icon-compile.md`
  §1, §7) and its three-section output; wired into the Linux build path
  (swift-build's `CompileAssetCatalogVariant`/`LinkAssetCatalog` tasks, or
  the fallback engine) in place of Apple's `actool` when Xcode is absent.
- Inputs: `.xcassets` (image sets, colour sets, app-icon sets, per
  `specs/ide/asset-catalog.md`) and `.icon` packages. Outputs per platform:
  `Assets.car`, loose PNGs, `AppIcon.icns`, the partial `Info.plist`.
- `.icns` writing (`ic04`/`ic07`/`ic11`/`ic13` default set): the ICNS
  container is publicly documented; write PNG entries and the 16×16 ARGB
  entry.
- On macOS with Xcode installed, the default stays Apple's `actool`; the
  own tool is selectable for testing.
- Acceptance: an app built on Linux shows its icon on the Ycode simulator,
  and (dirty check / owner step) on Apple's simulator and a device.

### ICON-EDITOR — edit `.icon` in the IDE (L, later)

- On OpenViews, after R11/R12. A canvas with the group and layer list,
  the inspector for every key of `icon-format.md` §3 (with per-appearance
  editing through specializations), appearance and platform previews from
  ICON-RENDER, drag-in of SVG/PNG into `Assets/`.
- Before that: a read-only `.icon` viewer in the macOS IDE (preview of the
  six renditions) is a small first step (part of **ICON-1** in
  `docs/PARITY.md`).

### Dependencies

    ICON-READER ──► ICON-RENDER ──► (tier-1 bitmaps) ─┐
         │                                            ├─► ACTOOL-COMPAT
         └──────────► CAR-WRITER (phase 1, 2) ────────┘
    ICON-READER + ICON-RENDER + OpenViews R11/R12 ──► ICON-EDITOR

CAR-WRITER phase 1 does not need ICON-READER and can start at once.

## Dirty-room follow-ups (not clean rounds)

- **Owner step:** save a few icons from Icon Composer's GUI to confirm the
  JSON for the controls we could not exercise (`icon-format.md` §10).
- **OBS check:** install a test app with a Ycode-written car (tier 1 only,
  then tier 2 only) on Apple's iOS simulator and confirm the home-screen
  icon (`assets-car.md` §11).
- **OBS check:** `ictool` and `actool` comparisons for ICON-RENDER and
  CAR-WRITER acceptance.

## Evidence

The three specs carry their own Evidence sections. Summary: levels 1
(swift-build's xcspec, public write-ups, MIT-licensed reader), 2 (files
written by Apple's tools from our own inputs, studied as formats; the Xcode
file templates and third-party `.icon` files as format samples), 3
(`actool`, `assetutil`, `ictool`, AppKit as black boxes) and 4 (key and
value names from Icon Composer's framework strings). Level 5 was not used.
