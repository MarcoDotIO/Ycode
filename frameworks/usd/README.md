# ycode-usd

A Swift-native USD library: layers, the USDA text format, the USDC crate
binary format, USDZ packages, a composed stage, and UsdShade/MaterialX
networks. It builds on macOS and Linux with the Swift 6.4 toolchain and no
other dependencies. It serves the Ycode Scene Composer (`composer/`) and,
later, the open RealityKit's asset loading. Design: `docs/SCENE-COMPOSER.md`.

Clean-room status: written from Pixar's public OpenUSD documentation and
open source (Tomorrow Open Source Technology License 1.0, Apache-2.0-based),
used as format descriptions, and from the MaterialX specification and
libraries (Apache-2.0). No Apple code or Apple sample content. Pixar's
`usd-core` was used only as a black-box oracle to produce test fixtures and
expected values.

## Modules

| Module | Content |
|---|---|
| `USDCore` | `Path`, `Value` (all value types; arrays as flat component buffers), `TypeName`, `Spec`, `Layer` (value type; create/remove/move/copy specs, variants, children lists), list ops, references, payloads, layer offsets; `USDAReader`/`USDAWriter`, `USDCReader`/`USDCWriter`, `USDZArchive`, `LayerIO`, `LZ4`, `IntegerCoding` |
| `USDStage` | `Stage`, prim indexes, `Prim`, `Attribute`, `LayerResolver` (`FileLayerResolver` with USDZ package paths, `MemoryLayerResolver`), `flatten()` |
| `USDShade` | `ShadeNetwork` (read from a layer or a stage, write, validate), `MaterialXLibrary` (bundled MaterialX definitions, type and value mapping) |

## Coverage

**USDA.** Header; layer metadata (comment, `doc`, `subLayers` with
offsets, `reorder rootPrims`, generic and list-op metadata); prims (`def`,
`over`, `class`, typed and typeless, dotted type names), prim metadata
(`references`, `payload`, `inherits`, `specializes`, `variantSets`,
`variants`, `permission`, `kind`, dictionaries, list ops with
`add`/`delete`/`prepend`/`append`/`reorder`); `reorder nameChildren` /
`properties`; variant sets with metadata on variants, nested; attributes
(`custom`, `uniform`/`config`, every scalar, vector, matrix, quaternion,
role and array type, `None`, `.timeSamples`, `.connect` with list ops,
metadata); relationships (`custom`, `varying`, targets with list ops,
`.default`); comments `#`, `//`, `/* */`; `;` separators; all string
quoting and escape forms; `@…@` and `@@@…@@@` asset paths. Not yet:
splines, array edits, `AnimationBlock`, relocates, relationship target
specs (reported as errors).
Writer: authored order (exact round trip) or OpenUSD order — the latter
reproduces usd-core's output byte for byte on `scene.usda`.

**USDC.** Reads crate versions 0.4.0–0.10.0 (bootstrap, TOC, compressed
tokens/fields/field sets/paths/specs, inlined values, all scalar and array
types, compressed integer arrays, `'i'` and `'t'` compressed float arrays,
dictionaries, list ops, references, payloads, time samples, variant
selections, vectors). Writes 0.8.0 (0.9.0 with timecodes, 0.10.0 with path
expressions) with compressed structural sections and compressed
int/int64/float arrays. Not yet: splines, array edits, relocates; crate
versions before 0.4.0.

**USDZ.** Reads and writes stored ZIP archives; data on 64-byte
boundaries (padding in a local extra field), root layer first, CRC checked.
No ZIP64, no compressed entries (USDZ forbids them).

**Composition.** Sublayers with offsets and cycle detection; references
and payloads (external and internal, default-prim targets, layer offsets);
inherits; specializes (as weakest local arcs); variant selections (strongest
opinion, stage fallbacks); LIVRPS order with direct arcs stronger than
ancestral arcs of the same type; child/property names composed weakest
first with `reorder`; value resolution with time samples, linear
interpolation and layer offsets; dictionary merging; targets and
connections mapped to stage namespace; `flatten()`. Not yet: instancing
prototypes, implied inherits across references, relocates, value clips,
specializes moved globally to the weakest position.

## Tests

`swift build && swift test` — 44 tests (USDCore 30, USDStage 9, USDShade 5).

| Round 1 results | macOS (arm64) | Linux x86-64 (Ubuntu 26.04) | Linux arm64 (Thor, Ubuntu 24.04) |
|---|---|---|---|
| `swift test` | 44 passed | 44 passed | 44 passed |

Fixtures (`Tests/USDCoreTests/Fixtures`):

| File | Origin |
|---|---|
| `scene.usda`, `props.usda` | hand-written for this package (repository licence) |
| `scene.canonical.usda`, `scene.usdc`, `props.usdz` | written by usd-core 26.11 (OpenUSD) from the files above with `Scripts/make_fixtures.py`; derived from our files |

Composition and transform tests carry expected values read from usd-core
composing the same layers.

## Third-party data

| Item | Version | Licence | Use |
|---|---|---|---|
| MaterialX `stdlib_defs.mtlx`, `pbrlib_defs.mtlx`, `standard_surface.mtlx`, `usd_preview_surface.mtlx`, `open_pbr_surface.mtlx`, `gltf_pbr.mtlx` | 1.39.5 | Apache-2.0 (`Sources/USDShade/Resources/MaterialX/LICENSE`) | node definitions; unmodified |

RealityKit's own node definitions (`ND_realitykit_*`) are published by
Apple under MIT in `apple/plugins-for-godot` (licence checked on GitHub,
2026-10-29); they are added in round SC-MATERIALS.
