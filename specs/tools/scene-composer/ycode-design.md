# Scene composer 9: Ycode design decisions

> **Ycode-original decisions.** This file records how Ycode's tool
> implements the boundary specs in this folder. It is not a description of
> the reference. Architecture and rationale: `docs/SCENE-COMPOSER.md`.

Status: round 1 (COMPOSER-CORE, 2026-10-29).

## 1. Names

| Item | Name |
|---|---|
| Tool | Ycode Scene Composer |
| Command-line tool | `ycode-scene` |
| USD library | package `ycode-usd` (`frameworks/usd/`), modules `USDCore`, `USDStage`, `USDShade` |
| Composer core | package `ycode-scene-composer` (`composer/`), modules `SceneComposerCore`, `SceneComposerCLI` |
| `customLayerData` creator | `"Ycode Scene Composer"` (`scene-usd.md` §1) |

## 2. Files Ycode writes

1. Scene layers follow `scene-usd.md` §1: `#usda 1.0`, `defaultPrim =
   "Root"`, `metersPerUnit = 1`, `upAxis = "Y"`, `Root` is an `Xform`.
2. Text layout is OpenUSD's (four-space indentation, metadata sorted by
   field name, blank lines between prims, LF). Properties and variants are
   written in **authored order** so that a no-op save is byte-stable; a
   sorted mode reproduces OpenUSD's writer exactly.
3. Transforms: `xformOp:translate` (`double3`), `xformOp:orient`
   (`quatf`), `xformOp:scale` (`float3`), `xformOpOrder` in that order;
   any other `xformOp:` attributes on the edited spec are removed. Existing
   op attributes keep their value types.
4. Material bindings: `prepend apiSchemas = ["MaterialBindingAPI"]` and
   `rel material:binding` with `bindMaterialAs = "weakerThanDescendants"`.
5. Imports: typeless prims with `active = true` and a prepended reference
   (`scene-usd.md` §2).
6. Components: `RealityKitComponent` child prims per `scene-usd.md` §4.1;
   a new component carries the catalogue's `alwaysWrite` fields at their
   editor defaults and nothing else (§4.4). The catalogue is the data file
   `composer/Sources/SceneComposerCore/Resources/components.json`.
7. USDC output is crate 0.8.0 (0.9.0 with timecode values, 0.10.0 with
   path expressions). USDZ output is a stored ZIP with the root layer
   first (as crate data) and entry data aligned to 64 bytes.

## 3. Reading and preserving

1. Every spec, field and value read from USDA or USDC is kept; unknown
   prims, component prims, fields and metadata are written back unchanged
   (`scene-usd.md` §7).
2. Required property fields follow OpenUSD's data model: attributes always
   carry `custom` and `variability`; relationships carry `variability`
   (`uniform` unless `varying rel`) and `custom` only when declared.
3. Not supported yet (reported as errors on read): attribute splines,
   array edits, `AnimationBlock`, relocates, relationship target specs.

## 4. Editing semantics

1. Every change is one undoable step holding the before/after specs it
   touched; grouped steps merge.
2. Deleting a prim that a weaker site (reference, payload, inherit,
   variant, sublayer) also defines authors `over` + `active = false`
   instead of removing specs.
3. Rename and move rewrite relationship targets, connections, inherits and
   specializes in the edited layer that point into the moved subtree; other
   layers are not touched.
4. Copy takes the edited layer's specs (arcs included) or, for prims that
   exist only through composition, their flattened form; paste picks
   unique names (`Name_1`, `Name_2`) and remaps internal paths.

## 5. Validation

`ycode-scene validate` reports, with stable codes: `load` (syntax),
`default-prim`, `up-axis`, `meters-per-unit`, `composition` (missing
layers, unresolved targets, cycles), `target`, `connection`, `type`,
`xform`, `mesh`, `geometry` (`Plane`), `variant`, `material` (MaterialX
interface errors), `material-node` (the `_v2` PBR node; RealityKit nodes
not yet in the bundled library), `component` (unknown ids and fields,
wrong types, token values outside the catalogue, unverified fields,
custom ids on `RealityKitComponent` prims), `usdz` (root layer, alignment).
Exit status 1 when any error is reported (`--strict`: any warning).

## Evidence

| Decision | Basis |
|---|---|
| §2.1, §2.3–§2.6 | `scene-usd.md` §1–§4 (OBS-RCP) |
| §2.2 text layout | OpenUSD open source (level 1); our writer's sorted mode matches usd-core 26.11 byte for byte on our fixtures |
| §2.7 crate and USDZ | OpenUSD open source and USDZ specification (level 1); our files read back identically in usd-core |
| §3.2 required fields | OpenUSD (level 1); usd-core's crate output of our fixtures |
| §5 | `compile.md` §2.5, `materials.md` §5 (OBS-RCP) |
