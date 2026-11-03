# Spec: the `Assets.car` container (compiled asset catalog)

Status: **specification (round 0)**, 2026-10-30. Reference: files written by
`actool` 27.1 (CoreUI 1010, storage version 17, schema 2) and read by
`assetutil` (dump tool 1011.4) on macOS 27. Tier 1 is implemented in Ycode
(`YcodeAssetCatalog`, §I).

`Assets.car` is the compiled asset catalog that the runtime (CoreUI, used
by UIKit, AppKit, SwiftUI and the icon services) reads. This spec covers the
container at the level needed to **write** a file that the runtime accepts
for app icons (flattened and layered), simple image sets and colours. It is
not a full description of every rendition kind.

All multi-byte numbers below say their byte order. The container (BOM) is
**big-endian**; the CoreUI structures inside it are **little-endian**.
"Tag `ABCD`" means the four bytes as they appear in the file.

## 1. Sources

This spec combines public write-ups with our own black-box study of files
that `actool` wrote from our own sample inputs:

- Timac, "Reverse engineering the .car file format (compiled Asset
  Catalogs)", 2018 (blog.timac.org) — BOM use, CARHEADER, EXTENDED_METADATA,
  KEYFORMAT, FACETKEYS, the CSI header, the rendition types. No licence is
  stated for its sample code; we used the prose only.
- ordinal0, "A deep dive into Apple's .car file format", 2026 (dbg.re),
  licensed CC BY-SA 4.0 — BOM header, trees, CSI header, TLV list, layouts,
  compression kinds, KCBC chunks, COLR. Its attribute-number table is off
  by the placeholder slot; §4 gives the numbering that matches `assetutil`.
- blacktop/ipsw, `pkg/bom` and `pkg/car` (MIT licence) — a reader; used to
  confirm the BOM tree entry order (value before key), the CSI header,
  the layer-reference and multisize records.

Not read: `bomutils` (GPL-2.0), `cartool` (no licence), `osxbom` (no clear
licence). Nothing from any of these is copied; the layouts below are
restated and were each re-checked against our own files (§10).

## 2. BOM container

### 2.1 Header (offset 0, 32 bytes, big-endian)

| Offset | Size | Field | Value |
|---|---|---|---|
| 0 | 8 | magic | `BOMStore` |
| 8 | 4 | version | 1 |
| 12 | 4 | number of blocks | count of used block-table entries, not counting entry 0 |
| 16 | 4 | index offset | file offset of the block table |
| 20 | 4 | index length | byte length of the block table |
| 24 | 4 | variables offset | file offset of the variables table |
| 28 | 4 | variables length | byte length of the variables table |

### 2.2 Blocks

A block is a byte range addressed by its **block number**. The block table
(big-endian) is:

    u32 count                         -- number of entries (actool: at least 256)
    count × { u32 offset; u32 length }
    20 zero bytes                     -- written by actool; readers ignore

Entry 0 is always `(0, 0)` (block number 0 means "none"). Unused trailing
entries are `(0, 0)`. `actool` starts the first block at offset 512 and
aligns every block to 16 bytes; the variables table and then the block table
follow the last block. Whether alignment is required is not known; aligning
costs nothing, so writers should do it.

### 2.3 Variables (named blocks)

Big-endian:

    u32 count
    count × { u32 block; u8 nameLength; nameLength bytes of ASCII name (no NUL) }

Names used by app-icon catalogs:

| Name | Kind | Required for the runtime | Content |
|---|---|---|---|
| `CARHEADER` | block | yes | §3.1 |
| `KEYFORMAT` | block | yes | §3.3 |
| `RENDITIONS` | tree | yes | rendition key → CSI rendition (§5) |
| `FACETKEYS` | tree | yes | asset name → attribute list (§4.3) |
| `APPEARANCEKEYS` | tree | write it whenever a rendition has a non-zero appearance (not tested without) | appearance name → number (§4.4) |
| `EXTENDED_METADATA` | block | no (recommended) | §3.2 |
| `BITMAPKEYS` | tree | no | per-identifier attribute masks (§4.5) |

Other names exist in other catalogs (`CARGLOBALS`, `KEYFORMATWORKAROUND`,
`EXTERNAL_KEYS`, `LOCALIZATIONKEYS`, `COLORS`, `FONTS`, `FONTSIZES`,
`GLYPHS`, `BEZELS`, `ELEMENT_INFO`, `PART_INFO`); a reader must tolerate
them and a writer does not need them.

### 2.4 Trees

A tree is a named block holding a 29-byte header (big-endian):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | tag `tree` |
| 4 | 4 | version = 1 |
| 8 | 4 | block number of the root node |
| 12 | 4 | node block size (actool: 4096; 1024 for `BITMAPKEYS`) |
| 16 | 4 | number of entries ("path count") |
| 20 | 1 | 1 = keys are stored inline in the entry (not in blocks), else 0 |
| 21 | 4 | key length: the common length of all keys, or `0xFFFFFFFF` if they differ (0 when inline) |
| 25 | 4 | reserved, 0 |

A node block (big-endian):

    u16 isLeaf (1 = leaf, 0 = branch)
    u16 count
    u32 forward    -- next leaf's block number, 0 at the end
    u32 backward   -- previous leaf's block number, 0 at the start
    count × { u32 value; u32 key }

- In a leaf, `value` is the block number of the value, and `key` is the
  block number of the key (or, with the inline flag, the key itself as a
  32-bit number). **Value comes first.**
- In a branch, `value` is the child node's block number and `key` refers to
  the first key of that child.
- **Fixed-length keys must be copied into the leaf.** When the header's key
  length is a fixed number (not `0xFFFFFFFF`, not inline), the reader
  compares keys from a copy stored in the leaf right after the entry list:
  4 zero bytes, then the `count` keys back to back, each of the key length.
  `actool` sizes such a leaf block as `blockSize + count × keyLength`. If the
  copies are missing, lookups read zeros and every lookup returns a wrong
  entry (`assetutil` shows NUL names). A writer that sets the key length to
  `0xFFFFFFFF` does not need the copies.
- Entries are sorted ascending by key: names by bytes; rendition keys by
  their 16-bit attribute values compared in KEYFORMAT order (§4.2).
  **Correction (ICON-CAR, §I.2):** the runtime searches `RENDITIONS` by
  the stored key bytes (memcmp of the little-endian values); a writer must
  sort the keys as bytes or lookups miss assets.
- All trees in our files are a single leaf. A writer should split large
  trees into leaves of at most `(blockSize − 12) / 8` entries (fewer for
  fixed keys, which also need room for the copies), linked by
  forward/backward, under one branch root. Multi-level trees were not
  exercised (§11).

## 3. Fixed CoreUI blocks

### 3.1 CARHEADER (436 bytes, little-endian)

| Offset | Size | Field | `actool` 27.1 value |
|---|---|---|---|
| 0 | 4 | tag `RATC` | |
| 4 | 4 | CoreUI version | 1010 |
| 8 | 4 | storage version | 17 |
| 12 | 4 | storage timestamp | 0 |
| 16 | 4 | rendition count | number of `RENDITIONS` entries |
| 20 | 128 | main version string, NUL-padded | `@(#)PROGRAM:CoreUI  PROJECT:CoreUI-1010 [LAR]` |
| 148 | 256 | version string, NUL-padded | `Xcode 27.1 (27A9269) via AssetCatalogAgent-AssetRuntime` |
| 404 | 16 | UUID | zero |
| 420 | 4 | associated checksum | 0 |
| 424 | 4 | schema version | 2 |
| 428 | 4 | colour space ID | 1 (sRGB) |
| 432 | 4 | key semantics | 2 for iOS, iPadOS, watchOS, tvOS; 1 for macOS |

Ycode writes its own strings in the two version fields (they are shown by
`assetutil` as `MainVersion` and `AssetStorageVersion`); the runtime
accepted that.

### 3.2 EXTENDED_METADATA (1028 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | tag `META` |
| 4 | 256 | thinning arguments (empty for an unthinned build) |
| 260 | 256 | deployment platform version, e.g. `27.0` |
| 516 | 256 | deployment platform: `ios`, `macosx`, `watch`, `atv`, … (`assetutil` shows it as `Platform`) |
| 772 | 256 | authoring tool string |

All strings NUL-padded.

### 3.3 KEYFORMAT (little-endian)

    tag `tmfk`; u32 version = 0; u32 count; count × u32 attribute number

The list fixes the order of the 16-bit values in every rendition key.
`actool` 27.1 writes nine attributes:

| Platform | Order |
|---|---|
| iOS, iPadOS, watchOS, tvOS (key semantics 2) | appearance, localization, scale, idiom, subtype, dimension2, identifier, element, part (`7 13 12 15 16 9 17 1 2`) |
| macOS (key semantics 1) | appearance, localization, element, part, size, identifier, dimension2, layer, scale (`7 13 1 2 3 17 9 11 12`) |

A writer may use either order on any platform as long as every key follows
the KEYFORMAT it writes.

## 4. Keys and names

### 4.1 Attribute numbers

Matches `assetutil`'s "Key Format" names for our files:

| No. | Attribute | No. | Attribute |
|---|---|---|---|
| 1 | element | 13 | localization |
| 2 | part | 14 | presentation state |
| 3 | size | 15 | idiom |
| 4 | direction | 16 | subtype |
| 6 | value | 17 | identifier |
| 7 | appearance | 18 | previous value |
| 8 | dimension1 | 19 | previous state |
| 9 | dimension2 | 20, 21 | size class horizontal, vertical |
| 10 | state | 22 | memory class |
| 11 | layer | 23 | graphics class |
| 12 | scale | 24 | display gamut |
| | | 25 | deployment target |

(0 is "look", 5 a placeholder; 26 and 27 are glyph weight and size.)

Values used by app catalogs:

- **element** is 85 for every asset written from a catalog or `.icon`
  (9 for the packed atlas).
- **part** says the asset kind (§6 table).
- **identifier** is a 16-bit number per asset name. `actool` derives it from
  the name (the same name gets the same number in every build), but the
  runtime only needs it to be unique within the file and consistent with
  `FACETKEYS`; our own files with arbitrary identifiers (101, 102, …) load.
- **scale**: 1, 2, 3 (1 for vectors, colours and stacks).
- **idiom**: 0 universal, 1 phone, 2 pad, 3 tv, 4 car, 5 watch, 6
  marketing, 7 mac, 8 vision.
- **dimension2**: for Icon Image renditions, the size index of §7.5.
- **appearance**: the number from `APPEARANCEKEYS` (§4.4).

### 4.2 Rendition keys

A `RENDITIONS` key is `count × u16` little-endian, one per KEYFORMAT entry,
in KEYFORMAT order (18 bytes for nine attributes). Unused attributes are 0.

### 4.3 FACETKEYS values

Key: the asset name in UTF-8, no NUL (e.g. `AppIcon`, `AppIcon/Group`,
`AppIcon_Assets/ring`). Value (little-endian):

    u16 hotSpotX = 0; u16 hotSpotY = 0; u16 n; n × { u16 attribute; u16 value }

`actool` writes three pairs: element (1) = 85, part (2) = the kind, and
identifier (17). The part in FACETKEYS is the asset's main kind: for an
`.icon` icon it is 245 (stack); for an `.appiconset` it is 220 (icon image).

### 4.4 APPEARANCEKEYS

Key: the appearance name (UTF-8, no NUL). Value: u16 little-endian number.

| Name | Number | Used on |
|---|---|---|
| `UIAppearanceAny` | 0 | iOS, watchOS, tvOS |
| `UIAppearanceDark` | 1 | iOS |
| `UIAppearanceLight` | 4 | iOS, watchOS |
| `NSAppearanceNameSystem` | 0 | macOS |
| `NSAppearanceNameDarkAqua` | 1 | macOS |
| `NSAppearanceNameAqua` | 8 | macOS |
| `ISAppearanceTintable` | 10 | iOS, macOS (tinted icons) |

Write every appearance that some rendition uses, plus the "any"/"system"
entry 0.

### 4.5 BITMAPKEYS (optional)

An inline-key tree (header flag 1, block size 1024). Key: the identifier as
a 32-bit number. Value (52 bytes, little-endian): `u32 1; u32 0; u32 40;
u32 9;` then nine u32 masks in KEYFORMAT order. A mask has bit *v* set when
some rendition of that identifier uses value *v* for that attribute;
`0xFFFFFFFF` means "any" (written for appearance, identifier, element and
part). Files without `BITMAPKEYS` loaded fine; Ycode may omit it.

## 5. Rendition record (CSI)

A `RENDITIONS` value is a CSI header, then a TLV list, then the payload.

### 5.1 CSI header (184 bytes, little-endian)

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | tag `ISTC` |
| 4 | 4 | version = 1 |
| 8 | 4 | flags (§5.2) |
| 12 | 4 | width in pixels (0 when not a bitmap; canvas size for a stack) |
| 16 | 4 | height |
| 20 | 4 | scale × 100 (100, 200, 300; 0 for colours, vectors, multisize) |
| 24 | 4 | pixel format, as bytes: `BGRA` (ARGB 8-bit), ` GVS` (SVG), `ATAD` (data), or 4 zero bytes (colour, gradient, multisize) |
| 28 | 4 | colour space: low 4 bits = colour-space number (§7.1); 1 for bitmaps, 0 otherwise |
| 32 | 4 | modification time = 0 |
| 36 | 2 | layout (§6) |
| 38 | 2 | reserved = 0 |
| 40 | 128 | rendition name, NUL-padded (e.g. the source file name; `assetutil` shows it as RenditionName) |
| 168 | 4 | TLV length in bytes |
| 172 | 4 | bitmap count = 1 |
| 176 | 4 | reserved = 0 |
| 180 | 4 | payload length in bytes |

The TLV list starts at 184; the payload starts at 184 + TLV length.

### 5.2 Flags

Bit 2 = vector based (set on SVG renditions), bit 4 = template rendering
"automatic" (set by `actool` on imageset images; `assetutil` shows
`Template Mode: automatic`). Other bits (from the write-ups): 0 FPO, 1
excluded from filter, 3 template, 5 opt out of thinning, 6 flippable, 7
tintable, 8 preserved vector representation. Icon renditions use 0.

### 5.3 TLVs

Each entry: `u32 type; u32 length; length bytes` (little-endian).

| Type | Content | Written on |
|---|---|---|
| 1001 | slices: `u32 1; u32 x=0; u32 y=0; u32 width; u32 height` | bitmaps |
| 1003 | metrics: `u32 1; 4 × u32 0; u32 width; u32 height` | bitmaps |
| 1004 | compositing: `u32 blendMode; f32 opacity` | all (opacity 1.0 on bitmaps, vectors, stacks, groups; 0 on colours, gradients, multisize) |
| 1005 | UTI: `u32 length; u32 0; length bytes incl. NUL` — `public.layeredimage` | stacks |
| 1006 | EXIF orientation: `u32 1` | all |
| 1007 | row bytes: `u32 width × 4` | bitmaps |
| 1010 | internal link (`INLK`): a rectangle in another rendition | packed small images (§7.6) |
| 1012 | layer references | stacks, groups (§7.7) |
| 1020 | layer effects | stacks, groups |
| 1021 | glass and shadow | stacks, groups |
| 1022 | refraction | stacks, groups |

## 6. Kinds: part and layout numbers

| Kind (`assetutil` AssetType) | part | layout | pixel format | payload |
|---|---|---|---|---|
| Image (imageset bitmap, `.icon` PNG artwork) | 181 | 12 | `BGRA` | CELM (§7.3) |
| Vector (SVG artwork) | 181 | 9 | ` GVS` | RAWD with SVG text (§7.4) |
| Color | 217 | 1009 | none | COLR (§7.1) |
| MultiSized Image | 218 | 1010 | none | MSIS (§7.5) |
| Icon Image (flattened icon bitmap) | 220 | 12 (1003 when linked into the atlas) | `BGRA` | CELM, or empty with an `INLK` TLV |
| IconImageStack | 245 | 1019 | `ATAD` | empty RAWD |
| IconGroup | 246 | 1020 | `ATAD` | empty RAWD |
| Named Gradient | 247 | 1021 | none | ARGG (§7.2) |
| PackedImage (atlas) | 181, element 9 | 1004 | `BGRA` | CELM |

Layout 12 is "one part, scale". Layout 9 is the vector layout.

## 7. Payloads

### 7.1 COLR (colour)

Little-endian: tag `RLOC`; `u32 version = 1`; `u32 info` (low 8 bits =
colour space, bits 8–10 = 0 for a plain colour); `u32 n`; `n × f64`
components (RGBA, or white and alpha).

Colour-space numbers: 0 generic, 1 sRGB, 2 gray gamma 2.2, 3 Display P3,
4 extended sRGB, 5 extended linear sRGB, 6 extended gray. From `.icon`
colours: `srgb` → 1, `display-p3` → 3, `extended-srgb` with components
outside 0–1 → 4, `extended-gray` → 6 (the default white), `gray` → 2.

### 7.2 ARGG (named gradient)

Little-endian: tag `ARGG`; `u32 stopCount` (2 for linear, 1 for an
automatic gradient — read as a stop count, not proven to be one); `u32 type`
(0 = automatic gradient from one colour, 1 = linear); `u32 0`; `f32 startX; f32 startY;
f32 endX; f32 endY` (unit coordinates, y down; the default is (0.5, 0) to
(0.5, 1)); then per stop: `f32 location; u32 nameLength; nameLength bytes`
(the name of a Color rendition, NUL included in the length).

### 7.3 CELM (bitmap pixels)

Little-endian: tag `MLEC`; `u32 version` (`actool` writes 3 for iOS and
watchOS icon bitmaps, 1 for macOS, 0 for deepmap2 images); `u32
compression`; `u32 n`; data.

| compression | meaning | `n` and data |
|---|---|---|
| 0 | uncompressed | `n` = byte length; then `height × rowBytes` bytes |
| 4 | LZFSE in row chunks ("KCBC") | `n` = number of chunks; then the chunks |
| 11 | deepmap2 (`actool`'s choice for imageset PNGs) | not needed by Ycode |

Other values (from the write-ups): 1 RLE, 2 zip, 3 LZVN, 5 JPEG+LZFSE,
6 blurred, 7 ASTC, 8 palette image, 9 HEVC, 10 deepmap-LZFSE, 12 DXTC.

A KCBC chunk is `KCBC`; `u32 0; u32 0; u32 rows; u32 compressedLength`;
then `compressedLength` bytes of an LZFSE stream that decodes to
`rows × rowBytes` bytes. `actool` cuts the image into chunks of
`floor(height / 3)` rows (341 for 1024 px, 170 for 512, 85 for 256) and a
last chunk with the remaining rows. The runtime does not depend on the
split: our files with one chunk for a whole 256 px image load.

Pixels: 8-bit **B, G, R, A** in memory order, rows top to bottom, `rowBytes =
width × 4` (TLV 1007). Our writer stored premultiplied alpha and the
runtime drew it correctly; whether `actool` premultiplies is an open
question (§11).

LZFSE is Apple's open-source compressor (BSD-3-Clause, github.com/lzfse);
on Linux Ycode can link it. Uncompressed (0) also loads, at a larger size.

### 7.4 RAWD (raw data, SVG)

Little-endian: tag `DWAR`; `u32 flags` (0 = stored, 1 = LZFSE-compressed);
`u32 length`; `length` bytes. SVG artwork is stored as the original SVG
text (compressed when that is smaller; a compressed stream starts with the
LZFSE block magic `bvx`). Stack and group payloads are an empty RAWD
(`flags = 0, length = 0`).

### 7.5 MSIS (multisize image set)

Little-endian: tag `SISM`; `u32 version = 1`; `u32 n`; `n × { u32 width;
u32 height; u32 index }`. Width and height are in points; `index` is the
`dimension2` value of the matching Icon Image renditions.

### 7.6 Packed atlas and links

`actool` packs small bitmaps (macOS 16, 32, 64 pt icons) into one image
named `ZZZZPackedAsset-<version>-gamut<n>` (element 9, part 181, layout
1004). The small Icon Image renditions then have layout 1003, an empty
payload and TLV 1010 (`INLK`: a rectangle and the key of the atlas). This
is an optimisation: our files without an atlas load. **Ycode should not
pack.**

### 7.7 Layer records (stack and group TLVs)

All little-endian, one record per layer, layers **bottom first**. Each of
the four TLVs starts with `u32 layerCount; u32 0`.

**1012 — layer references.** Per layer:

    u32 flags = 0
    i32 x; i32 y; u32 width; u32 height      -- frame in canvas points, top-left origin
    u32 blendMode
    f32 opacity
    u32 keyLength                             -- 16
    keyLength bytes: (u16 attribute, u16 value) pairs, ended by a (0, 0) pair

The reference key names the target rendition by element (1 = 85), part
(2 = 181, 217, 246 or 247) and identifier (17). It has no appearance: the
runtime picks the target's rendition for the appearance being drawn. In a
stack, the background and group entries have a zero frame (meaning "the
whole canvas").

Blend-mode numbers (the Core Graphics numbering): normal 0, multiply 1,
screen 2, overlay 3, darken 4, lighten 5, soft-light 8, hard-light 9,
plus-darker 26, plus-lighter 27.

**1020 — layer effects.** Per layer:

    u32 flags        -- bit 0: lighting effects (glass); bit 1: gathers specular by element
    f32 blurStrength
    u32 nameLength   -- including the NUL; 1 for "no name"
    nameLength bytes -- a Color or Named Gradient name used as the layer's fill, NUL-terminated

In a group, layers have bit 0 = the layer's `glass` and a fill name when the
layer has a fill. In a stack, the background entry is all zero; a group
entry has bit 1 for `lighting: individual` and the group's blur strength.

**1021 — glass and shadow.** Per layer, 20 bytes:

    u32 hasSpecular; f32 translucency; u32 shadowStyle; f32 shadowOpacity; u32 highlightPlacement

Shadow style: 0 none, 2 layer colour, 3 neutral. Placement: 0 automatic,
2 outside. Zero for group members and for the stack's background entry.

**1022 — refraction.** Per layer, 12 bytes: `u32 0; f32 strength; f32
depth` (zero unless the group's refractivity is enabled).

## 8. The `.icon` icon in rendition terms

For an `.icon` named `AppIcon` compiled for iOS, `actool` writes (counts for
a one-group, one-SVG icon with a solid fill):

- 3 IconImageStack renditions (`AppIcon.iconstack`, appearances 4, 1, 10),
  size 1024 × 1024, TLVs 1012/1020/1021/1022/1004/1005/1006.
- 3 IconGroup renditions (`IconGroup`, same appearances).
- 1 Vector rendition for the SVG.
- Colors and Named Gradients for fills (including `system-dark`).
- 2 MultiSized Image renditions (idioms 1 and 2; one size 1024, index 1).
- 6 Icon Image renditions (2 idioms × appearances 0, 1, 10; dimension2 = 1;
  1024 × 1024 at scale 1; CELM v3, LZFSE).

## 9. What Ycode must write

**Tier 1 — flattened (required; enough for an icon to show).**

- `CARHEADER`, `KEYFORMAT`, `RENDITIONS`, `FACETKEYS`; `EXTENDED_METADATA`
  and `APPEARANCEKEYS` as well (cheap, and `assetutil` shows them).
- Per app icon: one MultiSized Image per idiom listing the sizes, and one
  Icon Image (layout 12, `BGRA`, CELM uncompressed or LZFSE) per idiom and
  size, with TLVs 1001, 1003, 1004, 1006, 1007. FACETKEYS part 220.
- Images: part 181, layout 12, same TLVs. Colours: part 217, layout 1009.
- Tree key length `0xFFFFFFFF` (no key copies needed) or fixed with the
  copies of §2.4.

**Tier 2 — layered (for Liquid Glass rendering of an `.icon`).**

- Per appearance: one IconImageStack and one IconGroup per group, with the
  four layer TLVs; the artwork as Vector (SVG) or Image renditions; Colors
  and Named Gradients for fills. FACETKEYS part 245 for the icon name.
- Write tier 1 next to it (as `actool` does), so older systems and the
  loose-file paths still have bitmaps.

**Proven so far** (our own writer, `research/` proof files, §10):

| File | `assetutil --info` | macOS runtime |
|---|---|---|
| Tier 1, macOS key format: colour, LZFSE image, uncompressed image, macOS app icon (7 sizes, unpacked) | all renditions listed correctly | `NSImage`/`NSColor` load from the bundle; Finder/`NSWorkspace` shows the icon for an app bundle with `CFBundleIconName` |
| Same without `EXTENDED_METADATA`, `APPEARANCEKEYS`, `BITMAPKEYS` | correct | same |
| Same with variable-length keys and no key copies | correct | same |
| Tier 1, iOS key format: phone and pad Icon Image + MultiSized Image | identical shape to `actool`'s `.appiconset` output | not tested (iOS) |
| Tier 2 only (no flattened images), macOS: stack + group + SVG vector + colour, appearance 0 only, and again with appearances 8/1/10 | correct | `NSWorkspace` renders the layered glass icon from the stack |

## 10. Verification method

- Our own dumper reads every block, tree and CSI record of an `actool`
  output and prints them; each field in this spec was checked by changing
  one input key (blend mode, opacity, shadow, translucency, lighting,
  specular, blur, refractivity, positions, fills, gradient orientation) and
  diffing the bytes, and against `assetutil --info`.
- Our own writer (a test script in the dirty room, not Ycode code) produced
  the files in §9; `assetutil --info` and AppKit (`Bundle.image(forResource:)`,
  `NSColor(named:bundle:)`, `NSWorkspace.icon(forFile:)`) were the judges.
- A clean implementation should reuse this method as its conformance test:
  write, then compare `assetutil --info` output field by field with
  `actool`'s output for the same inputs (on macOS).

## 11. Open questions

- iOS runtime acceptance (SpringBoard on device or Apple's simulator) of a
  Ycode-written car, both tiers. Dirty-room or owner step.
- Multi-leaf and branch trees (large catalogs): not produced by our tests.
- Whether `actool` stores premultiplied pixels in CELM.
- The meaning of CELM `version` (3 vs 1 vs 0) and whether the runtime
  cares; our writer used 1 (macOS) and 3 (iOS) like `actool`.
- The 1012 per-layer `flags` word and the 1022 first word (always 0 here).
- The identifier hash `actool` uses (not needed; any unique value works).
- Thinning metadata (`EXTENDED_METADATA` thinning arguments) for
  device-thinned builds.

## I. Ycode implementation (CAR-WRITER phase 1, agent ICON-CAR, 2026-10-30)

Clean-room implementation from this spec, public documentation and open
formats (LZFSE, PNG, DEFLATE, ICNS). Module `YcodeAssetCatalog` (portable,
Foundation only; macOS and Linux), command `ycode assets`.

### I.1 What is written

| Part | Ycode type | Notes |
|---|---|---|
| BOM header, block table, variables, trees (§2) | `BOMWriter`, `BOMReader` | Blocks from offset 512 on 16-byte boundaries, then the variables, then the block table (≥ 256 entries, 20 zero bytes). Trees: one leaf of up to `(blockSize − 12) / 8` = 510 entries, more leaves linked forward/backward under one branch root. `RENDITIONS` has fixed 18-byte keys **with the leaf key copies** (4 zero bytes, then the keys; leaf block `blockSize + count × 18`); `FACETKEYS` and `APPEARANCEKEYS` have variable keys (`0xFFFFFFFF`). |
| CARHEADER (§3.1) | `CARWriter.header` | CoreUI version 1010, storage version 17, schema 2, colour space 1, key semantics 2 (1 on macOS); Ycode's own version strings. |
| EXTENDED_METADATA (§3.2) | `CARWriter.metadata` | Deployment target and platform (`ios`, `macosx`, `watch`, `atv`, `xros`), Ycode's authoring-tool string. |
| KEYFORMAT (§3.3) | `CARPlatform.keyFormat` | `actool` 27.1's two orders. |
| APPEARANCEKEYS, FACETKEYS (§4.3, §4.4) | `CARWriter.data` | Every appearance used plus entry 0. Facets: element 85, part, identifier. |
| Renditions (§5–§7) | `CARRendition`, `CSI` | Image (181/12), Icon Image (220/12), Color (217/1009, COLR), MultiSized Image (218/1010, MSIS). TLVs 1001, 1003, 1004, 1006, 1007 (bitmaps) and 1004, 1006 (others), in that order. Image-set images have flag bit 4. |
| Pixels (§7.3) | `CSI.celm`, `Bitmap` | Premultiplied B, G, R, A. CELM version 3 for app-icon bitmaps on the iOS family (opaque, as `actool`), 1 for everything else (I.2 item 6). Compression 4 (LZFSE in KCBC chunks of `height / 3` rows, the last with the rest) by default; 0 with `--compression none`. |
| BITMAPKEYS, packed atlas, tier 2 | — | Not written (phase 2). |

Identifiers are an FNV-1a hash of the asset name folded to 16 bits, moved
on by one on a collision, never 0, assigned in name order: stable across
builds and machines.

LZFSE: `LZFSE.encode` cuts the input into independent blocks of at most
64 KiB (I.2 item 5), each a `bvxn` (LZVN) block or a `bvx-` raw block when
that is smaller, then `bvx$`, with Ycode's own LZVN encoder (greedy
hash matcher; the opcode table of the BSD-3-Clause reference decoder,
github.com/lzfse/lzfse, read as the format definition; no code taken). The
same input gives the same bytes on every platform. `LZFSE.decode` reads
`bvx-` and `bvxn` blocks, and on macOS hands other blocks (`bvx1`, `bvx2`)
to the system library.

### I.2 Findings the spec did not have (to confirm in the dirty room)

Each was found with our own cars and **public AppKit API only**
(`Bundle.image(forResource:)`, `NSColor(named:bundle:)`,
`NSWorkspace.icon(forFile:)`) or the public Compression library; no Apple
tool was run.

1. **RENDITIONS order is by the stored key bytes**, the little-endian u16
   values compared as bytes (memcmp), not by the numeric values (§2.4 says
   "compared in KEYFORMAT order"). With numeric order, lookups missed every
   asset whose identifier sorted differently as bytes (for example 3 of 5
   images in one car, 28 of 30 in another); with byte order all loaded.
   OBS check: the order in `actool`'s own `RENDITIONS` leaves.
2. **Colours and MultiSized Images need scale 1** in their key. With scale
   0, `NSColor(named:bundle:)` returned nil and `NSWorkspace` showed the
   generic icon for an app whose icon was only in the car. Ycode writes
   scale 1 whenever a rendition has none (§4.1 says 1 for colours; the
   MultiSized Image was not listed).
3. LZVN (the reference decoder's format, not the car's): with one literal
   in a distance opcode the longest match is 8, not 10 — the patterns
   0x70–0x7F are not distance opcodes; the system decoder rejected our
   streams that used them. The longest matches per literal count 0–3 are
   10, 8, 6, 4.
4. On macOS an app bundle without its executable shows the generic icon in
   `NSWorkspace` whatever its resources (a test-setup fact).
5. **LZFSE blocks must stay small.** With one LZVN block per KCBC chunk
   (1,396,736 decoded bytes for a 1024-px image), CoreUI decoded only the
   first 782,336 bytes (191 rows) of every chunk and left the rest black —
   on macOS (`Bundle.image(forResource:)`) and on Ycode's iOS simulator (the
   home-screen icon showed black bands). The system's
   `compression_decode_buffer` decoded the same streams completely, so the
   limit is in CoreUI's decoding path. Ycode writes independent blocks of
   at most 64 KiB (`LZFSE.blockSize`); every pixel of 1024-px images then
   comes back exactly. Whether `actool`'s streams use FSE blocks of a
   bounded size is an OBS question (§7.3).
6. **CELM versions 2 and 3 mean opaque.** A translucent image written
   with version 3 drew with its alpha ignored (premultiplied colour on
   black: transparent corners turned black in the iOS sample app on Ycode's
   simulator; on macOS a 50 % red drew as opaque dark red); versions 0 and
   1 keep alpha. `actool`'s choice of 3 for iOS icon bitmaps fits: they are
   opaque. Ycode writes 3 only for iOS-family app-icon bitmaps.

### I.3 Results

- Byte-level tests (`CARStructureTests`): BOM header, block alignment,
  block table, variables; CARHEADER (436 bytes) and EXTENDED_METADATA
  (1028 bytes) fields at their offsets; KEYFORMAT bytes for both orders;
  the RENDITIONS tree header and leaf copies; FACETKEYS and APPEARANCEKEYS
  values; the CSI header fields and TLV bytes; COLR, MSIS, CELM and KCBC
  layouts; a three-leaf tree under a branch root; write-then-read round
  trips for both compressions.
- macOS runtime (`RuntimeLoadTests`, public API only): image sets load with
  their 1x and 2x representations and the dark variant under the dark
  appearance, namespaced names (`Shapes/Star`) and translucent pixels
  included, with LZFSE and uncompressed pixels; colours load with their
  dark variant and Display P3 values; an app bundle shows its icon through
  `NSWorkspace.icon(forFile:)` from an `.appiconset` and from an `.icon`
  (placeholder render), with and without the `.icns` (so from the car
  alone).
- The system's LZFSE decoder reads Ycode's streams (fixed samples and 40
  mixed random inputs); Ycode reads the system's (FSE) streams on macOS.
- iOS (Ycode simulator): see I.5.

### I.4 The compiler (`ycode assets compile`)

Inputs: `.xcassets` folders (image sets with PNG files, colour sets,
app icon sets; other set kinds are skipped with a warning) and `.icon`
packages (`icon-format.md` "Ycode implementation"). Outputs per
`icon-compile.md` §3: `Assets.car`; iOS `<Icon>60x60@2x.png` (120 px) and
`<Icon>76x76@2x~ipad.png` (152 px), ordinary opaque PNGs; macOS
`<Icon>.icns` (`ic13`, `ic11`, `ic04` ARGB, `ic07`; all ten entries with
`--standalone-icon-behavior all`); the partial `Info.plist`
(`CFBundleIcons`, `CFBundleIcons~ipad` with `CFBundleIconName` only for
targeted families, `CFBundleAlternateIcons`; macOS `CFBundleIconFile` and
`CFBundleIconName`; watchOS `CFBundleIconName`; `NSAccentColorName` when
the accent colour set exists — the public Info.plist key, level 1); the
dependency file (`--export-dependency-info`: ld's format, version, input
0x10 and output 0x40 records).

- An `.icon` wins over an `.appiconset` of the same name; an `.icon` inside
  a catalog is ignored with a warning; visionOS ignores `.icon` inputs, tvOS
  warns (§2, §3 of `icon-compile.md`).
- `.icon` flattened tier only (phase 1): iOS MultiSized Image (1024, index
  1) and Icon Images for phone and pad (the targeted families) × any, dark,
  tinted; macOS the seven sizes of `icon-compile.md` §5 (16–512 pt at 2x,
  1024 at 1x) for the system appearance; watchOS idiom 5, any. FACETKEYS
  part 220 (no stack yet).
- The flattened bitmaps come from `--icon-images <dir>` (PNG files named
  `<appearance>[-<platform>][-<pixels>].png`, appearance `default`, `dark`
  or `tinted`; a folder per icon name is also accepted) or, without it,
  Ycode's **placeholder render**: the resolved background fill, then the
  visible groups' PNG layers drawn flat at their frames with opacity and
  simple blend modes; SVG layers and the glass look are not drawn
  (ICON-RENDER). macOS gets an 824-pt rounded rectangle (radius 22.5 %) at
  (100, 100) with a soft shadow; tinted is a grey version.
- `.appiconset`: one MultiSized Image per idiom (the set's sizes, index from
  1 in size order) and one Icon Image per idiom, size, scale and appearance;
  a single-size universal iOS icon becomes phone and pad.
- actool's command line is accepted (`--compile` for `--output`, and the
  flags of `icon-compile.md` §1); flags Ycode does not use are read and
  ignored; an unknown flag is exit 2. Output: the three sections of §1
  (human-readable text) or `--output-format xml1`. The symbol step
  (`--generate-swift-asset-symbols` and friends) writes valid empty files
  and no car (asset symbols are not generated yet). `--version
  --output-format xml1` answers `com.apple.actool.version` with Ycode's own
  numbers (swift-build reads the key `com.apple.<tool file name>.version`).
  `--print-asset-tag-combinations` answers an empty list.

`ycode assets info <car> [--json]` dumps a car (header, metadata, key
format, appearances, facets, every rendition with its key and decoded
payload) and reports structure issues (missing leaf key copies, keys out of
byte order, count mismatches; exit 1).

### I.5 Build integration and the simulator

`YcodeBuild.AssetCompilerHook`: the setting `YCODE_ASSET_COMPILER` =
`actool` | `ycode` (build setting on the command line or environment;
default `actool` on macOS, `ycode` elsewhere). With `ycode`, the IDE's
swift-build engine and ycodebuild add `ASSETCATALOG_EXEC` naming a wrapper
script `actool` (in the derived-data folder or ycodebuild's work folder)
that runs `ycode assets compile "$@"`; an explicit `ASSETCATALOG_EXEC`
wins. ycodebuild puts it in the synthesized overrides, so
`-showBuildSettings` output is unchanged.

The sample `ycode/Samples/IconSamples` (an iOS app with an asset catalog
and an `.icon`, own artwork) built with `ycode build --engine swift-build
YCODE_ASSET_COMPILER=ycode`: swift-build ran `ycode assets compile` for
GenerateAssetSymbols and CompileAssetCatalogVariant, and LinkAssetCatalog
placed `Assets.car` and the two loose PNGs in the app with the partial
plist merged. ycodebuild did the same (`ycodebuild … YCODE_ASSET_COMPILER=ycode
CODE_SIGNING_ALLOWED=NO build`).

On Ycode's simulator (arm64 Linux host, iPhone 18 Pro, iOS 27.0, cold
boots, `--install-app` and `--launch`): **the app's icon appears on the
home screen** from the tier-1 car (the flattened Icon Images; no layered
stack) about 30 s after the home screen, and the app prints `image
40x40@3x, color 0.90 0.30 0.10, icon AppIcon` — `UIImage(named:)` and
`UIColor(named:)` read the car and the generated Info.plist names the icon.
The first runs found I.2 items 5 (black bands across the icon) and 6
(black corners around a transparent image); both are fixed. This answers
the Ycode side of `icon-compile.md` §8's question (iOS accepts a car with
only the flattened tier); Apple's simulator remains a dirty-room check.

### I.6 Open questions (for an OBS agent)

- Confirm I.2 items 1 and 2 against `actool`'s output.
- Which idiom `actool` writes for macOS icon renditions (the macOS key
  format has no idiom attribute, so it did not matter here).
- Whether `actool` premultiplies CELM pixels (§11); Ycode does, and AppKit
  draws translucent pixels correctly from them.
- Template-rendering intents other than the default (Ycode writes bit 4 and
  warns); high-contrast appearances (skipped).

## Evidence

| Claim | Evidence | Level |
|---|---|---|
| BOM header, block table, variables, tree header and nodes, CARHEADER, EXTENDED_METADATA, KEYFORMAT, CSI header, TLV numbers, compression numbers, KCBC, COLR | Public write-ups (Timac 2018; dbg.re 2026, CC BY-SA 4.0) and the MIT-licensed blacktop/ipsw reader, each re-checked byte by byte on cars that `actool` wrote from our own inputs | 1, 2 |
| Attribute numbering, part numbers, appearance numbers, layouts 1019/1020/1021, TLVs 1020/1021/1022 and the 1012 use in icons, ARGG, MSIS, key copies in fixed-key leaves, BITMAPKEYS masks | Format study of our own compiled files, one key changed at a time; `assetutil --info` as the reference decoder | 2, 3 |
| What the runtime accepts | Our own proof files loaded by `assetutil` and AppKit on macOS 27 | 3 |
| Not used | Disassembly or decompilation (level 5); CoreUI headers or private API calls; GPL or unlicensed code | — |
| §I (Ycode implementation): the writer, compiler and tests | This spec; the PNG specification (W3C), RFC 1950/1951 (zlib, DEFLATE), the ICNS layout (public write-ups), the LZFSE reference implementation's format (BSD-3-Clause, read as a format definition); swift-build's `AssetCatalogCompiler` sources (Apache-2.0) for the command line, the version query and the dependency file | 1 |
| §I.2 findings (byte-ordered RENDITIONS, scale 1, LZVN 0x70–0x7F) | Our own cars and streams loaded through public AppKit API (`Bundle.image(forResource:)`, `NSColor(named:bundle:)`, `NSWorkspace.icon(forFile:)`) and the public Compression library on macOS 27, one change at a time | 3 (public API, own files) |
