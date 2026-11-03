# Spec: the `.icon` package (Icon Composer document)

Status: **specification (round 0)**, 2026-10-30. Reference: Icon Composer
27.1 (build 129, inside Xcode 27.1 27A9269) and the standalone Icon Composer
2.0 (build 109.4). Read and written by Ycode (`YcodeIcon`, "Ycode
implementation" below); rendering is a later round (ICON-RENDER).

An `.icon` is the layered app-icon document made by Icon Composer. Xcode 26
and later accept it as an app icon in place of an `.appiconset`. This spec
covers the files, the JSON document, and how each key affects the rendered
icon. Compilation into the app bundle is in `icon-compile.md`; the compiled
container is in `assets-car.md`.

## 1. Package layout

An `.icon` is a directory (a package) with this content:

    <Name>.icon/
        icon.json            -- the document (required)
        Assets/              -- image files that layers reference (optional)
            <file>.svg | <file>.png

- Uniform type `com.apple.iconcomposer.icon`, conforming to
  `com.apple.package`; extension `icon`. Xcode's file type for it is
  `folder.iconcomposer.icon` (based on `folder.abstractassetcatalog`), and
  Xcode treats it as opaque (not expandable in the navigator).
- The package name without `.icon` is the **icon name** that the build uses
  (`--app-icon <Name>`, `CFBundleIconName`). See `icon-compile.md` §2.
- `Assets/` is flat. A layer refers to a file by its file name
  (`image-name`), including the extension. SVG and PNG are the formats seen;
  other image types are an open question.
- A missing `Assets/` folder is valid when no layer has an image (the Xcode
  file templates contain only `icon.json`). A layer whose image file is
  missing does not stop rendering; the layer is skipped.

## 2. `icon.json` encoding

- UTF-8 JSON. Icon Composer writes two-space indentation, `"key" : value`
  (a space on both sides of the colon), keys sorted, and empty arrays as
  `[\n\n  ]`. Readers must accept any valid JSON layout (hand-edited files
  with `"key": value` are common and load fine).
- Unknown keys are ignored by the reader.
- The document has **no version key**. Format generations are told apart by
  the keys present (§9).
- Writers should emit keys sorted and numbers in their shortest form, and
  colors with five decimals (§4), to round-trip with Icon Composer's output.

## 3. Object model

    Document
      fill / fill-specializations         background of the icon canvas
      groups: [Group]                     front-most first, at most 4 visible
      supported-platforms                 which design shapes the icon targets
      color-space-for-untagged-svg-colors
    Group
      name, hidden, opacity, blend-mode, position
      layers: [Layer]                     front-most first
      shadow, translucency, specular, specular-highlight-placement,
      lighting, blur-material, refractivity   (the Liquid Glass properties)
    Layer
      name, image-name, hidden, opacity, blend-mode, position,
      fill, glass

Order: the first element of `groups` is the **top** group, and the first
element of a group's `layers` is the **top** layer. (Compiled output lists
them bottom-up; `icon-compile.md` §5.)

### 3.1 Document keys

| Key | Type | Default when absent | Notes |
|---|---|---|---|
| `groups` | array of Group | — (**required**; `{}` fails with "data is missing") | May be empty. Icon Composer warns when more than four groups are visible ("too-many-visible-groups"). |
| `fill` | Fill (§4.2) | light and tinted: plain white; dark: the system dark gradient (§4.3) | Background of the whole canvas. |
| `fill-specializations` | array of Specialization<Fill> | — | Per-appearance or per-idiom background (§5). |
| `supported-platforms` | object | — | `{"squares": "shared" \| [platform…], "circles": ["watchOS"]}` (§6). |
| `color-space-for-untagged-svg-colors` | string | sRGB | `"display-p3"` is accepted. `"srgb"` is rejected as invalid; the complete value set is an open question. |

The reader also knows the names `material-strength`, `specular-location`
and `implicit-asset-mirroring` at document level (level 4). Their meaning
was not observed; preserve them on round-trip.

### 3.2 Group keys

| Key | Type | Default | Effect |
|---|---|---|---|
| `layers` | array of Layer | — (required) | |
| `name` | string | `"Group"` in compiled names | Display name. |
| `hidden` | bool | `false` | A hidden group is left out of the rendered icon and the build. |
| `opacity` | number 0–1 | `1` | Opacity of the whole group. |
| `blend-mode` | Blend mode (§4.5) | `normal` | How the group composites onto the groups below. |
| `position` | Position (§4.4) | identity | Transforms every layer of the group about the canvas center. |
| `shadow` | `{"kind": Kind, "opacity": number}` | `{"kind": "neutral", "opacity": 0.5}` | `kind`: `neutral`, `layer-color` (the shadow takes the layers' colour), `none`. |
| `translucency` | `{"enabled": bool, "value": number}` | enabled, `0.3` | How much the background shows through the group's glass. `enabled: false` means no translucency (the value is kept but unused). |
| `specular` | bool | `true` | Specular highlight on the glass edge. |
| `specular-highlight-placement` | string | `automatic` | Values seen in the reader: `automatic`, `inside`, `outside`. `inside` changes the render; `outside` renders like `automatic` on the sample icons. Unrecognized values are ignored, not errors. |
| `lighting` | `"individual"` \| `"combined"` | `individual` | `individual`: each layer of the group is lit as its own glass piece. `combined`: the group's layers are lit as one piece. Any other value is an error. |
| `blur-material` | number 0–1 or `null` | none | Frosted blur behind the group. `null` and `0` are "off". |
| `refractivity` | `{"enabled": bool, "strength": number, "depth": number}` | disabled | All three keys are required when the object is present. With `enabled: false` it has no effect. |

Each key above except `layers` and `name` may also appear as
`<key>-specializations` (§5): `hidden-specializations`,
`opacity-specializations`, `blend-mode-specializations`,
`position-specializations`, `shadow-specializations`,
`translucency-specializations`, `specular-specializations`,
`specular-highlight-placement-specializations`, `lighting-specializations`,
`blur-material-specializations`, `refractivity-specializations`. The reader
also knows `refractivity-strength`, `refractivity-depth` (and their
`-specializations`) and `asset-mirroring` (and `-specializations`) as group
or layer keys; their exact placement is an open question.

### 3.3 Layer keys

| Key | Type | Default | Effect |
|---|---|---|---|
| `image-name` | string | — | File name inside `Assets/`. A layer without an image draws nothing. |
| `name` | string | — | Display name. |
| `hidden` | bool | `false` | Hidden layers are not rendered and not compiled. |
| `opacity` | number 0–1 | `1` | |
| `blend-mode` | Blend mode | `normal` | Blend onto the layers below inside the group. |
| `position` | Position | scale 1, no translation | |
| `fill` | Fill, or `"automatic"`, or `"none"` | `"automatic"` | `automatic`/`none`: the artwork keeps its own colours. A Fill replaces the artwork's colour (the artwork becomes a mask). |
| `glass` | bool | `true` | `false` turns off the Liquid Glass lighting for this layer (it stays flat artwork). |

Specializable: `fill-specializations`, `glass-specializations`,
`hidden-specializations`, `opacity-specializations`,
`blend-mode-specializations`, `position-specializations`,
`image-name-specializations` (a different file per appearance or idiom).

## 4. Value grammars

### 4.1 Colors

A color is a string:

    color      := space ':' component (',' component)*
    space      := 'srgb' | 'extended-srgb' | 'display-p3'     -- 4 components: R,G,B,A
                | 'gray' | 'extended-gray'                    -- 2 components: white, A

- Components are decimal numbers. Icon Composer writes five decimals
  (`"extended-srgb:0.00000,0.53333,1.00000,1.00000"`).
- `extended-*` spaces allow components outside 0–1.
- A missing `:` is an error ("Invalid color encoding, missing ':'
  delimiter"); an unknown space is an error ("Invalid color space"); a wrong
  component count is an error.
- The reader also knows named colors (`system-red`, `system-green`,
  `system-blue`, `system-orange`, `system-yellow`, `system-brown`,
  `system-pink`, `system-purple`, `system-gray`, `system-teal`,
  `system-indigo`, `system-mint`, `system-cyan`), but a bare name in a color
  position is rejected (no `:`). How a named color is written is an open
  question.

### 4.2 Fill

A Fill is one of:

| JSON | Meaning |
|---|---|
| `{"solid": color}` | A flat color. |
| `{"automatic-gradient": color}` | A gradient that the system derives from one color (a slight top-to-bottom shift). |
| `{"linear-gradient": [color, color], "orientation": {"start": {"x": n, "y": n}, "stop": {"x": n, "y": n}}}` | A two-stop linear gradient. Exactly two colors are required (more is an error). `orientation` is in unit coordinates of the canvas, origin top-left, y down; when absent it runs from `(0.5, 0)` to `(0.5, 1)` (top to bottom). |
| `"automatic"` | The system background: a light gradient (white to 92.5 % white) in light and tinted, the dark gradient in dark. |
| `"none"`, `"system-light"`, `"system-dark"` | Accepted strings. On the document fill they rendered the same as `"automatic"` in our samples; for layers `"none"` is the same as `"automatic"` (artwork colours). |

A dictionary must have exactly one of the keys `solid`, `automatic-gradient`,
`linear-gradient` (with the optional `orientation` beside the latter).
Anything else is an error ("A fill should be one of: …").

### 4.3 System backgrounds (compiled values)

These are the colours the build writes for the built-in backgrounds; a
renderer should use the same:

| Name | Stops (top → bottom) |
|---|---|
| default (no `fill`), light and tinted | solid extended gray 1.0 (white) |
| `system-light` (`"automatic"`) | gray 1.0 → gray 0.925 |
| `system-dark` (dark appearance when no dark fill is given) | gray-gamma-2.2 0.192 → 0.078 |

### 4.4 Position

    {"scale": number, "translation-in-points": [x, y]}

- The icon canvas is 1024 × 1024 points for squares (iOS, iPadOS, macOS) and
  1088 × 1088 for circles (watchOS).
- A layer's natural size in points is the SVG's width and height (its
  `width`/`height` attributes, or the `viewBox`), or the PNG's pixel size
  (1 pixel = 1 point).
- Layer frame (top-left origin, y down):
  `size = natural × scale`; `origin = canvas_center + translation − size / 2`.
  Positive y moves the artwork **down**.
- A group `position` applies after the layer's own: scale about the canvas
  center, then translate. Example: group scale 2, translation (50, −30), a
  400 pt layer with no own position → frame (162, 82, 800, 800).
- The reader also knows a `relative-translation` key next to
  `translation-in-points`. Its meaning was not observed; preserve it on
  round-trip.

### 4.5 Blend modes

`normal`, `multiply`, `screen`, `overlay`, `darken`, `lighten`, `soft-light`,
`hard-light`, `plus-darker`, `plus-lighter`. Anything else is an error. The
compiled numeric codes are in `assets-car.md` §7.2.

## 5. Specializations (appearance and idiom variants)

Any specializable key `K` may be replaced by `K-specializations`, an array of
entries:

    {"value": V}                                  -- the base value
    {"appearance": A, "value": V}                 -- A ∈ light | dark | tinted
    {"idiom": I, "value": V}                      -- I ∈ square | macOS | watchOS (iOS also accepted)

- An entry without `appearance` or `idiom` is the base value.
- Appearances apply to the six renditions (§7) as follows:

| Rendition | Uses the entry for |
|---|---|
| Default | `light` (else base) |
| Dark | `dark` (else base) |
| TintedLight, TintedDark, ClearLight, ClearDark | `tinted` (else base) |

  A `dark` entry does **not** apply to TintedDark or ClearDark.
- Idioms: `square` applies to iOS and macOS, `macOS` only to macOS,
  `watchOS` only to watchOS, `iOS` only to iOS.
- Other values (`clear`, `any`, `universal`, `circle`, …) make the whole
  document unreadable ("isn't in the correct format").
- When both an idiom entry and an appearance entry match, which wins is an
  open question (not observed). Icon Composer's own files list the base
  entry first, then the appearance entries.

## 6. Supported platforms

    "supported-platforms": {
      "squares": "shared" | ["iOS", "macOS"],   -- square (rounded-rect) designs
      "circles": ["watchOS"]                     -- the round watch design
    }

- `"shared"` means one square design for iOS, iPadOS and macOS. A list
  names the platforms that use the square design.
- Unknown platform names make the document unreadable.
- The Xcode templates write `{"squares": "shared", "circles": ["watchOS"]}`
  (multiplatform), `{"squares": ["iOS"]}`, `{"squares": ["macOS"]}` or
  `{"circles": ["watchOS"]}`.
- The build does **not** filter by this key: an icon with
  `"squares": ["macOS"]` still compiles for iOS. It is an editor setting
  (which previews to show).

## 7. Renditions and appearances

Icon Composer previews, and its command-line tool renders, six renditions:

| Rendition | Appearance | Notes |
|---|---|---|
| `Default` | light | |
| `Dark` | dark | |
| `TintedLight`, `TintedDark` | tinted | Monochrome tinted look; takes a tint colour and strength. |
| `ClearLight`, `ClearDark` | tinted | The clear-glass look; uses the `tinted` specializations. |

Two design generations exist: 27 (current, default) and 26 (the iOS 26 look).
They render differently from the same document.

## 8. The command-line renderer

Icon Composer ships `Contents/Executables/ictool` (and a helper `icrtool`
that is not meant to be run directly). Ycode does not need them; they are
the reference for black-box comparison of an Icon Composer–compatible
renderer.

    ictool <doc.icon> --export-image --output-file <out.png>
           --platform iOS|macOS|watchOS --rendition <Rendition>
           --width <px> --height <px> --scale <n>
           [--tint-color <0..1>] [--tint-strength <0..1>] [--design-generation 26|27]
    ictool --version            -- prints {"bundle-version": "...", "short-bundle-version": "..."}

- Output: an 8-bit RGBA PNG with an sRGB ICC profile (the TintedDark output
  is tagged sRGB without a profile). iOS and macOS renders are the
  rounded-rectangle ("squircle") shape on a transparent canvas; watchOS
  renders are a circle.
- `--tint-color` is a hue position 0–1 and only changes tinted renditions.
- Errors are printed as one line on standard output and the **exit status is
  0**; success prints an empty JSON object. A wrapper must check for the
  output file, not the status.
- Only `iOS`, `macOS` and `watchOS` are platforms; there is no visionOS or
  tvOS rendition of an `.icon`.

## 9. Compatibility notes

- There is no version key. Every file we saw (third-party files made with
  earlier Icon Composer releases, and the Xcode 27.1 templates) uses only
  the key set above. Icon Composer 2 has a diagnostic for localized assets
  that earlier versions recorded with language codes instead of locale IDs;
  localized assets are an open question (§10).
- Files in the wild are often hand-edited (other key layouts, extra empty
  groups). A reader must be tolerant: ignore unknown keys, accept empty
  groups and layers without images.

## 10. Open questions and owner steps

- **Owner step (needs the GUI):** create an icon in Icon Composer and save
  it, to confirm (a) the exact JSON Icon Composer writes for each inspector
  control (especially `specular-highlight-placement`, `refractivity`,
  `blur-material`, named colours and `color-space-for-untagged-svg-colors`),
  (b) localized image variants (`image-name-specializations` with a locale),
  and (c) whether `relative-translation`, `asset-mirroring`,
  `material-strength` and `specular-location` are still written. Our samples
  were written by hand (no clicks were allowed).
- Precedence when an idiom entry and an appearance entry both match.
- Image formats other than SVG and PNG in `Assets/`.
- The exact meaning of the reader-known keys listed in §3.1 and §3.2 that
  were not observed in any file.

## I. Ycode implementation (ICON-READER, agent ICON-CAR, 2026-10-30)

Module `YcodeIcon` (portable, Foundation only; macOS and Linux). Commands:
`ycode assets icon info | validate | to-json | from-json | render`.

### I.1 Model

| Spec | Ycode type |
|---|---|
| Document (§3.1) | `IconDocument`: `fill` (+ specializations), `groups`, `supportedPlatforms`, `colorSpaceForUntaggedSVGColors`, `extra` |
| Group (§3.2) | `IconGroup`: `name`, `layers`, and every specializable key as `IconSpecialized<…>` (hidden, opacity, blend mode, position, shadow, translucency, specular, highlight placement, lighting, blur material, refractivity) |
| Layer (§3.3) | `IconLayer`: `name`, and `IconSpecialized` image name, hidden, opacity, blend mode, position, fill, glass |
| Colours (§4.1) | `IconColor` (space, components; the text as read is written back while unchanged, new colours with five decimals) |
| Fill (§4.2) | `IconFill`: automatic, none, system-light, system-dark, solid, automatic-gradient, linear-gradient (+ orientation) |
| Position (§4.4), blend modes (§4.5) | `IconPosition`, `IconBlendMode` (with the compiled code of `assets-car.md` §7.7) |
| `K-specializations` (§5) | `IconSpecialized<V>` = the plain value + `[IconSpecialization<V>]` (appearance, idiom, value) |
| Supported platforms (§6), renditions (§7) | `IconSupportedPlatforms`, `IconRendition` (with the appearance each uses) |
| Unknown keys | `extra` on the document, groups, layers, specialization entries, positions, shadows, translucency and refractivity objects, supported platforms: kept and written back |

### I.2 Reading and writing

- Reader: Ycode's own JSON parser (any valid JSON layout; a UTF-8 BOM is
  accepted). Errors (`IconError`, with a path like
  `groups[0].layers[1].blend-mode`) for: not an object, missing `groups` or
  `layers`, bad blend mode, fill, colour encoding (missing `:`, unknown
  space, wrong component count), lighting, appearance, idiom, platform, a
  linear gradient without exactly two colours, refractivity without all
  three keys, `color-space-for-untagged-svg-colors` = `srgb`. Everything else
  is tolerated (empty groups, layers without images, unknown keys and
  values, unrecognized highlight placements and shadow kinds).
- Writer: Icon Composer's layout of §2 — keys sorted by bytes, two-space
  indent, `"key" : value`, empty arrays and objects as `[`, an empty line,
  `]`, numbers in their shortest form, no final newline. A document in that
  layout that uses every key of §3 (our own, in the tests) reads and writes
  back byte for byte.
- Validation (`IconPackage.validate`): warnings for more than four visible
  groups (in any appearance and platform), missing `Assets/` files, image
  types other than SVG and PNG, empty groups, layers without images, the
  unknown values above.

### I.3 Resolution (§5) and defaults (§3)

`IconDocument.resolved(appearance, platform)` gives every group and layer
with the defaults of §3 applied; `value(for: "groups[i].layers[j].key",
appearance:, platform:)` gives one key's effective value. Rules:

- With `K-specializations`, the matching entry applies (appearance absent
  or equal; idiom absent or applying to the platform: `square` → iOS and
  macOS, `macOS`, `watchOS`, `iOS` → their own). **Ycode's precedence for
  the open question of §5/§10:** an appearance match outranks an idiom
  match, and a platform's own idiom outranks `square`; among equals the
  first in the file wins. Without a matching entry the plain key applies,
  then the default.
- Renditions map to appearances as §5's table (TintedDark and ClearDark use
  `tinted`, never `dark`).
- The document background: light and tinted as above, default white
  (extended gray 1); **dark uses only a `dark` entry, else `system-dark`**
  — a plain fill does not carry into dark, as the compiled output in
  `icon-compile.md` §4.2 and `assets-car.md` §8 shows. `automatic` is
  system-light in light and tinted, system-dark in dark. Built-in stops
  per §4.3 (`IconBackground`); an automatic gradient is approximated as the
  colour at the top and 90 % of it at the bottom.

### I.4 Frames (§4.4)

`IconGeometry.layerFrame`: size = natural × layer scale × group scale;
centre = canvas centre + layer translation × group scale + group
translation. The §4.4 example gives (162, 82, 800, 800). Natural sizes:
`IconImageInfo` reads a PNG's IHDR (also after a CgBI chunk) and an SVG's
`width`/`height` (numbers, `px`/`pt`) or `viewBox`. Canvas 1024 (iOS,
macOS) or 1088 (watchOS).

### I.5 Tests

`YcodeIconTests` (macOS and Linux): byte-for-byte round trip of the
every-key document; every key read into the model; the writer's layout;
hand-edited layouts and unknown keys; shortest numbers; colour text kept;
16 invalid documents with their messages; the resolution table; dark
entries not applying to TintedDark; idioms per platform; the precedence
rule; every default; backgrounds per appearance; `value(for:)`; frames
(§4.4 example, own position, watch canvas); SVG and PNG natural sizes; the
package on disk (write with assets, read back, frames from files,
validation warnings).

## Evidence

| Claim | Evidence | Level |
|---|---|---|
| Package layout, UTI, file type, Xcode treating it as opaque | Icon Composer's `Info.plist`; Xcode's `StandardFileTypes.xcspec`; the Xcode file templates (`icon.json` only) | 2 |
| Key names, value names, error texts | Third-party `.icon` files on the owner's drive (open-source projects; format study only, nothing copied); strings in `IconComposerFoundation` (Codable key names, enum values, messages); confirmed by `ictool` reading our own hand-written documents | 2, 4, 3 |
| Defaults, appearance/idiom mapping, ordering, position maths, blend modes | `ictool` renders of our own sample icons, pixel-diffed against a base; compiled values from `actool` (`icon-compile.md`) | 3 |
| System background colours | Colours in `Assets.car` compiled from our samples, read with `assetutil --info` | 3 |
| `ictool` usage and behaviour | `ictool --help`, `--version`, runs on our samples | 3 |
| Not used | Disassembly or decompilation (level 5); GUI clicks; Apple's sample icons or artwork | — |
| §I (Ycode implementation) | This spec only; the dark-background rule from `icon-compile.md` §4.2 and `assets-car.md` §8; the precedence rule is Ycode's choice (an open question here) | 1 (spec), Ycode decision |
