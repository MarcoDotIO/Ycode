# Asset catalog editor

Ycode modules: `YcodeUI` (`AssetCatalog`, `AssetCatalogEditorController`).

Opening an `.xcassets` folder shows the asset catalog editor in the editor
area: a list of sets on the left (with a + menu: Image Set, Color Set,
macOS App Icon; and −), the selected set on the right.

Correction (2026-10-19): the outline, the "+" menu, the set header and
slots follow `reference-ui-3.md` §3. Folders are rows of their own, and the
set inspector is a fourth inspector tab, not part of the editor
(`reference-ui-5.md` §7.6, §11.2). The Editor menu while this editor is
focused is in `reference-ui-5.md` §2.8 (Add New Asset ▸, Delete Selected
Items, Device Image Reps ▸, …).

## Format (Contents.json)

Each folder of the catalog has a `Contents.json`. Folders whose extension
is `imageset`, `colorset` or `appiconset` are sets; other folders are
groups (shown as `Group/Name`).

- **Image set**: `images` — entries with `idiom` (`universal`), `scale`
  (`1x`, `2x`, `3x`), optional `filename` (a file in the set folder) and
  optional `appearances` (`[{"appearance": "luminosity", "value": "dark"}]`).
  A new set has universal 1x, 2x and 3x entries. "Add Dark Appearance"
  adds a dark entry for each scale.
- **Color set**: `colors` — entries with `idiom`, optional `appearances`,
  and `color` = {`color-space` (`srgb` | `display-p3`), `components`
  {`red`, `green`, `blue`, `alpha`}}. Components are read as floats
  (`"0.200"`) or 8-bit values (`"51"`, `"0x33"`) and written as floats
  with three decimals.
- **macOS app icon**: `images` with `idiom` `mac`, `size` 16x16, 32x32,
  128x128, 256x256, 512x512, each at `1x` and `2x`.
- `info` = {`author`, `version` 1}; Ycode writes `"author" : "ycode"` in
  files it creates and keeps the value of existing files.

Files are written as JSON with two-space indentation, `"key" : value`,
keys sorted, and a final newline (the layout in which existing files read
and write back unchanged).

## Editing

- Image slots are drop targets for image files; a click opens a file
  picker. The file is copied into the set folder and named in the slot;
  a replaced file no other slot uses is deleted. Clearing a slot removes
  its `filename` and file (Ycode: the Delete key on a selected slot, or
  its context menu's Remove).
- Color rows: a swatch, the color space (sRGB / Display P3) and Red,
  Green, Blue, Alpha fields (0–1); each edit writes the set.
- App icon slots behave like image slots, titled "16x16pt 1x" etc.

## Evidence

- Correction 2026-10-19 (folders as rows, inspector tab, Editor menu): `reference-ui-3.md` §3 and `reference-ui-5.md` §2.8, §7.6 (level 3).
- Contents.json keys and values: Apple's public "Asset Catalog Format
  Reference" (level 1); the JSON layout matched a file in that layout
  byte for byte (level 3).
- Set header, slot captions, the App Icon and Color Set inspectors and the
  "+" menu: `specs/ide/reference-ui-3.md` §3 (level 3).
- OPEN QUESTION: how it
  names copied files, the attributes inspector for sets (render as,
  compression), and the iOS app icon single-size format.
