# Scene composer 6: `realitytool`, the build, and the `.reality` container

Status: draft round 0 (OBS-RCP, 2026-10-29). Reference: Xcode 27.1
(27A9269) and its `realitytool`. Sources: the open-source swift-build
and SwiftPM projects (level 1), our own compiled files studied as a file
format (level 2), black-box runs of `realitytool`, `xcodebuild` and a
macOS RealityKit loader probe on our own samples (level 3). No
disassembly was used for this file.

"The compiler" below means Apple's `realitytool`; "Ycode's compiler" is
the clean implementation this spec enables.

## 1. `realitytool` overview

One executable in the developer directory
(`$(DEVELOPER_DIR)/usr/bin/realitytool`, normally run through `xcrun`)
with three subcommands: `compile`, `create-schema`, `image`. Every run
prints one informational line to standard output of the form
`[macosx] info: realitytool [<argv as a quoted list>]` before anything
else; tools that parse its output must skip it. Argument errors exit
with status 64 and print the subcommand usage; processing errors exit
with status 1 and print `error: …` lines; warnings are
`<file>:<line>: warning: …`.

The compile is executed with the *target platform's* RealityKit: the
`frameworkVersion` written into the output differs per platform (§6.3).
The first run after boot can take about a minute (helper start-up);
later runs take 1–4 s for small inputs.

## 2. `compile`

```
realitytool compile -o|--output-reality <out> --platform <p>
    --deployment-target <v> [--schema-file <usda>] [--derived-data <dir>]
    [--use-metal true|false|auto] [--reduced-texture-file-size
    disabled|standard|small|smallest] <input>
```

### 2.1 Inputs

| Input | Meaning | Output given `-o X` |
|---|---|---|
| a folder `<Name>.rkassets` | a tree of USD scenes and the files they reference | the file `X` (a `.reality` container), `X`'s folder must exist |
| a folder `<Name>.skybox` | a folder containing one environment image (we used a Radiance `.hdr` lat-long image) | `X` is a **folder**; the output is `X/<Name>.realityenv`. If `X` does not exist the run fails with a file-move error |

A path that is not an existing folder (for example a single `.usda`
file) is rejected with "`'<path>' does not exist`" (status 64). A
missing output folder for `.rkassets` is rejected the same way.

### 2.2 Scene discovery inside `.rkassets`

- **Every USD file** in the tree (`.usda`, `.usdc`, `.usdz`, at any depth)
  becomes one scene; a referenced material file such as
  `Materials/X.usda` is therefore also compiled as a scene of its own.
- Other files (images, text) are included **only** when a scene
  references them (texture assets); loose files are dropped.
- Scene name = path relative to the `.rkassets` root, with extension and
  `/` separators (`Scene.usda`, `Sub/Deep/Inner.usda`, `Bin.usdc`,
  `Packed.usdz`).
- Scene order in the output: `.usda` files sorted by relative path, then
  `.usdc`, then `.usdz` (observed with one file of each).
- The schema file passed with `--schema-file` is added to the tree and
  is also compiled as a scene (its name, e.g.
  `CustomComponentUSDInitializers.usda`, appears in the scene list).

### 2.3 Platforms and deployment targets

Platform values: `appletvos`, `appletvsimulator`, `iphoneos`,
`iphonesimulator`, `macosx`, `xros`, `xrsimulator`. Anything else:
`error: Building for '<p>', but realitytool only supports [<list>]`.
A non-numeric target: `error: Invalid --deployment-target '<v>'`.

Minimum targets (below them: `error: Building for '<p>', but '<v>' must
be >= '<min>'`, status 1):

| Platform family | Minimum accepted | Observed |
|---|---|---|
| `xros`, `xrsimulator` | 1.0 | 1.0, 2.0, 26.0, 27.0, 99.0 accepted |
| `iphoneos`, `iphonesimulator` | 18.0 | 13.0, 15.0, 17.0 rejected |
| `macosx` | 15.0 | 10.15 rejected |
| `appletvos`, `appletvsimulator` | 26.0 | 18.0 rejected |

The target selects the container's `minVersion` (a file-format level,
§6.3) and the payload encoding:

| Target | `minVersion` |
|---|---|
| visionOS 1.x | 10 |
| visionOS 2.x, iOS 18, macOS 15 | 12 |
| visionOS/iOS/tvOS 26 | 15 |
| visionOS 27 and above | 18 (99.0 also gave 18) |

Compiled payload bytes were identical for visionOS 1, 2 and 26 and for
iOS 18 and macOS 15 (only `header.json` and `assetMap.json` differed);
at 27 the scene, collision-shape and material payloads changed. From
`minVersion` 15 the container uses compression method 32867 (§6.5) for
most assets.

### 2.4 Options

- `--use-metal true|auto`: no observable change in our texture sample
  (payloads identical to the default `false`).
- `--reduced-texture-file-size standard|small|smallest`: requires a
  target ≥ 26.0 (`error: Building for 'xros', but '2.0' must be >=
  '26.0' for texture compression`). Each texture asset then ships three
  entries: `<Kind>_<n>.sourceimage` (an **AVIF** file, sizes 17 001 /
  4 965 / 3 576 bytes for our 512×512 PNG at standard / small /
  smallest), a small `.compiledtexture` (170 bytes) and
  `<Kind>_<n>_importOptions.json` (keys `pixelFormat` — `"Invalid"`
  observed — and `colorSpace` — a CoreGraphics colour-space name, here
  `kCGColorSpaceDisplayP3`). Without the option the texture is stored
  decoded (our 512×512 RGBA8 PNG became a 349 938-byte payload: full mip
  chain plus a header).
- `--schema-file <usda>`: the output of `create-schema` (§4). Before
  compiling, the compiler copies the `.rkassets` tree, adds the schema
  file at its root, and rewrites every prim **of type
  `RealityKitCustomComponent`** to
  `prepend references = @<schema file name>@</Components/<prim name>>`.
  The reference is by **prim name**, so the prim must be named
  `<Module>_<Type>` for schema defaults to apply; with another name the
  reference dangles silently and unauthored fields fall back to the Swift
  decoder's defaults. Prims of type `RealityKitComponent` are never
  rewritten. Authored values win over schema defaults (normal USD
  strength order); schema defaults are baked into the compiled scene
  (proved by compiling with an altered schema: the loaded component took
  the altered defaults).
- `--derived-data <dir>`: the folder must exist. The modified copy is
  left at `<dir>/realitytool-modified/<Name>.rkassets/` (rewritten scenes
  plus the schema file). Without it the copy goes to a temporary folder.
  The help says it requires `--schema-file`; without one it is accepted
  and the copy is still written.

### 2.5 Errors and warnings (black box)

| Input problem | Result |
|---|---|
| USD syntax error in a scene | **silently dropped**: exit 0, no message, the scene is missing from the output |
| Reference to a missing file | exit 0, scene compiled without the referenced content, no message |
| Unknown `info:id` on a `RealityKitComponent` prim | exit 0, component ignored, rest of the entity intact |
| Unknown attribute inside a known component | ignored |
| Attribute of the wrong type (`token mask` where `uint` is expected) | field set to zero (not to the default) |
| Custom component id on a `RealityKitComponent` prim (instead of `RealityKitCustomComponent`) | component not created at load |
| Empty `.rkassets` | exit 0, container with no scenes |

Ycode's compiler must report every one of these cases as a diagnostic
(it is free to be stricter than the reference); a "compatibility" switch
can downgrade them to warnings to accept the same inputs.

### 2.6 Determinism

Compiling the same input twice gives byte-identical asset payloads and
`header.json`; only `assetMap.json` differs, because every asset GUID
is a fresh random UUID per run (§6.4). `assetMap.json` also embeds the
**absolute source path** of each texture (`cdm:resolvedpath`,
`Engine/RE-debugName`), so outputs depend on the checkout location.
Ycode's compiler should derive GUIDs from a hash of (scene name, prim
path, asset kind) and write source paths relative to the `.rkassets`
root; the loader does not need either value to be random (§6.8).

## 3. Xcode build integration

Sources: swift-build `RealityAssets.xcspec`, `CompileSkybox.xcspec`,
`AppleFileTypes.xcspec`, `RealityAssetsCompilerSpec.swift`,
`RealityAssetsTaskProducer.swift` and their tests (Apache-2.0, level 1),
confirmed by one `xcodebuild` build of our own macOS executable package
that depends on our own content package with one `.rkassets` folder and
two custom components (level 3).

### 3.1 File types and rules

- `folder.rkassets`: extension `rkassets`, a wrapper folder, UTI
  `com.apple.rkassets`, applies to build rules. Tool spec
  `com.apple.build-tasks.compile-rk-assets.xcplugin` (Compiler, synthesised
  build rule, architecture-neutral, deeply stats input folders).
- Options: `PLATFORM_NAME` → `--platform`;
  `REALITYASSET_DEPLOYMENT_TARGET` (default
  `$($(DEPLOYMENT_TARGET_SETTING_NAME))`, i.e. the target's deployment
  target) → `--deployment-target`.
- `file.skybox` → `com.apple.build-tasks.compile-skybox.xcplugin`
  (output `$(ProductResourcesDir)/$(InputFileBase).realityenv`). The file
  type `file.skybox` is **not defined** in Xcode 27.1's specifications, so
  this rule never matches; `.skybox` folders are compiled only by hand.
- SwiftPM (tools version ≥ 5.7) treats `.rkassets` as a processed
  resource (`processResource`, no localisation) — the same rule family as
  asset catalogs.

### 3.2 Tasks

For every target whose Resources phase contains `.rkassets` folders:

1. **Schema generation (packages only).** When the target is a SwiftPM
   *resource* target (`PACKAGE_RESOURCE_TARGET_KIND = resource`), the
   producer finds the package's *regular* target that depends on it, and
   collects the Swift files of that target's Sources phase and,
   recursively through package products, of every dependency that has
   Swift sources. If there is at least one Swift file it writes
   `$(DERIVED_FILE_DIR)/RealityAssetsGenerated/ModuleWithDependencies.json`
   (§4.1; pretty-printed, sorted keys, unescaped slashes) at
   task-planning time and adds the task
   - rule `RealityAssetsSchemaGen <out.usda>`, description "Generate
     Reality Asset USD schema",
   - `realitytool create-schema --output-schema
     $(DERIVED_FILE_DIR)/RealityAssetsGenerated/CustomComponentUSDInitializers.usda
     <ModuleWithDependencies.json>`,
   - inputs: the JSON and every listed Swift file; output: the `.usda`;
     sandboxed; prepares for indexing; only when `BUILD_COMPONENTS`
     contains `build`.
   App targets in an `.xcodeproj` never get this step (their custom
   components are not schema-processed).
2. **Compile.** One task per `.rkassets` folder (several are allowed;
   more than one `.rkassets` input to a single task is an error
   "multiple .rkassets", more than one `.usda` schema "multiple .usda"):
   - rule `RealityAssetsCompile <out>`, description "Compile Reality
     Asset <Name>.rkassets",
   - `realitytool compile --platform <PLATFORM_NAME>
     --deployment-target <target> -o <out> <Name>.rkassets
     [--schema-file <CustomComponentUSDInitializers.usda>]`
     (Xcode never passes `--derived-data`, `--use-metal` or
     `--reduced-texture-file-size`),
   - output `$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/<Name>.reality`,
   - input is a directory-tree node (any file change in the folder
     reruns it) plus the schema file,
   - environment adds `LLVM_PROFILE_FILE=/dev/null`; task ordering
     "compilation requirement"; run under the build sandbox, or, when
     `ENABLE_GENERIC_TASK_CACHING` is on with CAS options, as a cached
     generic task instead of sandboxed.

### 3.3 Observed build (macOS destination, our package)

- Task order: `RealityAssetsSchemaGen` → `RealityAssetsCompile` (both in
  the resource target `<Package>_<Target>`), then the Swift compiles.
- Command lines (paths shortened):
  `realitytool create-schema --output-schema …/ObsContent_ObsContent-b.build/DerivedSources/RealityAssetsGenerated/CustomComponentUSDInitializers.usda …/RealityAssetsGenerated/ModuleWithDependencies.json`
  and
  `realitytool compile --platform macosx --deployment-target 15.0 -o …/Products/Debug/ObsContent_ObsContent.bundle/Contents/Resources/ObsContent.reality <src>/Sources/ObsContent/ObsContent.rkassets --schema-file …/CustomComponentUSDInitializers.usda`.
  The deployment target came from the package's `platforms:` entry.
- Product: the package resource bundle `<Package>_<Target>.bundle`
  (macOS layout `Contents/Resources/`; expected flat on iOS-family
  platforms, not observed) holds
  exactly one file per `.rkassets`: `<Name>.reality`. `Bundle.module` in
  the package resolves to that bundle.
- A Swift property type the schema generator rejects (§4.3) fails the
  build at the `RealityAssetsSchemaGen` step; a Swift type that is not
  `Codable` fails later in the Swift compile.

### 3.4 Loading by name

`Entity(named: n, in: bundle)` searches the bundle's `.reality` files for
a scene whose `sceneName` matches `n` with or without the extension
(`Scene` and `Scene.usda` both worked) and also by last path component
(`Inner` found one of `Sub/Inner.usda`, `Sub/Deep/Inner.usda` — ambiguous
names should be avoided by Ycode's editor; which one wins is an open
question). Folder-qualified names (`Sub/Inner`, `Sub/Deep/Inner`) work.
An unknown name throws `resourceNotFound("<n>")`. The returned entity is
an unnamed-or-root-named wrapper whose child is the scene's
`defaultPrim` entity (the probe printed `Root` › `Root` › children).
Custom components load only if the app registered the type
(`registerComponent()`) before loading.

## 4. `create-schema`

### 4.1 Input

```
realitytool create-schema -o|--output-schema <out.usda> <module.json>
```

`<module.json>` (`ModuleWithDependencies`):

```json
{
  "dependencies": [ { "moduleName": "Dep", "swiftFiles": ["/abs/Dep.swift"] } ],
  "module": { "moduleName": "Mod", "swiftFiles": ["/abs/A.swift", "/abs/B.swift"] }
}
```

Both keys are required; `swiftFiles` are absolute paths. The module name
becomes the type prefix.

### 4.2 What it extracts

The tool reads the Swift **source text** (it does not type-check) and
emits one entry for every `struct` that conforms to `Component` and
`Codable` (written in its inheritance clause). For each stored instance
property (`var` or `let`, any access level, in declaration order; `static`
and computed properties are skipped) it emits one attribute.

Defaults are taken from the initialiser expression text. The parser is
line-oriented: an initial value is recognised only when the declaration
ends at the end of its line; for single-line structs such as
`struct S: Component, Codable { var x: Float = 1 }` the default is
lost (numeric) or wrong (a string default becomes the rest of the line,
e.g. `'s" }'`). Ycode's compiler must parse Swift properly (swift-syntax)
and should warn where the reference would mis-read.

### 4.3 Accepted property types (observed)

| Swift type | USD attribute | Notes |
|---|---|---|
| `Float` | `float` | |
| `Double` | `double` | |
| `Int`, `Int32`, `Int16` | `int` + `customData { string originalType = "<Swift type>" }` | |
| `UInt8` | `uchar` + `originalType` | |
| `UInt32` | `uint` + `originalType` | |
| `UInt64` | `uint64` + `originalType` | |
| `Bool` | `bool` | default written `1`/`0` |
| `String` | `string` | |
| `SIMD2<Float>`, `SIMD3<Float>`, `SIMD4<Float>` | `float2`, `float3`, `float4` | default from an array literal `[0, 1, 0]` → `(0, 1, 0)` |
| `SIMD3<Double>` | `double3` | |
| `simd_quatf` | `quatf` | accepted by the tool although not `Codable` in Swift |
| `T?` for an accepted `T` | the attribute of `T`, never a default | |
| `enum E: String, Codable` | `token` with `allowedTokens = [cases…]`, default = case name | |
| nested `struct N: Codable` | child prim `def RealityKitStruct "<property>"` with `customData { attributeOrder, sourceTypeName = "Mod.N" }`, `token info:id = "Mod.N"`, and one attribute per field | |
| `[T]` (arrays) | `T[]` attribute | warning "Unable to serialize collections in CustomComponent when used in Reality Composer Pro projects." |
| `SIMD2<Int32>` and other integer SIMD | — | warning "Extended Types are not valid in CustomComponents." |

Rejected with `error: Unable to serialize this unknown type.` (the whole
run fails, no output): `simd_float4x4`, `Entity`/`Entity?`, dictionaries,
`URL`, `Date`, `CGColor`, `Transform`, `UUID`, `Character`, `Float16`.
Other messages seen: "Stored Property must have initial value." (where
the parser could not read a default). Every message has the form
`<file>:<line>: error|warning: <text>`; the run ends with
`error: Finished processSwiftFiles() with code incompatibility issues,
failure` and a "Failure creating schema" line, status 1.

### 4.4 Output layout

```
#usda 1.0

def RealityKitComponents "Components"
{
    def RealityKitCustomComponent "<Module>_<Type>" (
        customData = {
            token[] attributeOrder = ["<p1>", "<p2>", …]   # declaration order
            string sourceTypeName = "<Module>.<Type>"
        }
    )
    {
        <attributes, sorted by name, with defaults when known>
        token info:id = "<Module>.<Type>"
    }
    …
}
```

Components from `dependencies` are included with their own module
prefix. Prims are sorted by name; attributes inside a prim are sorted by
name (`info:id` falls in alphabetical position); `attributeOrder` keeps
declaration order for the editor. Note that `info:id` here is a plain
`token` (no `uniform`), unlike built-in component prims.

### 4.5 Using custom components in scenes

A scene stores a custom component as a prim of type
`RealityKitCustomComponent` named `<Module>_<Type>` with
`uniform token info:id = "<Module>.<Type>"` and only the authored
attributes; the compiler adds the schema reference (§2.4). At run time
the component is decoded with the type's `Codable` implementation from
the attribute names (coding keys) — fields absent from both the scene and
the schema use the type's decoder defaults.

## 5. `image`

```
realitytool image -o|--output-reality-asset <out.ktx|out.realityenv>
    [--platform <p> --deployment-target <v>]   # required for .realityenv
    [--semantic hdrColor|color|scalar|raw|normal] [--color-space <OCIO name>]
    [--cube-face-size n] [--specular-size n] [--diffuse-size n]
    [--lat-long-sampling-quality normal|none|fast]
    [--ibl-sampling-quality fast|normal|high|veryhigh] [--generate-cube-map]
    [--astc-compression-block-size 4x4|5x4|5x5|6x5|6x6|8x5|8x6|8x8|10x5|10x6|10x8|10x10|12x10|12x12]
    [--astc-compression-mode linearLDR|sRGBLDR|linearHDR]
    [--astc-compression-quality fast|normal|high|exhaustive] <input image>
```

- The output kind is chosen by extension; any other extension:
  `error: Invalid output file type <ext>`.
- `--color-space` takes OpenColorIO-style names: `Input - Texture - sRGB
  - sRGB` and `lin_srgb` were accepted; `srgb` was rejected ("not a
  supported OCIO color space", status 64).
- **`.ktx` output is KTX 1.1** (identifier `«KTX 11»`, little-endian),
  with a full mip chain (7 levels for 64×32) and key/value data:

| Input / options | glType / glFormat / glInternalFormat | `KTXmetalPixelFormat` (u32) | Other keys |
|---|---|---|---|
| 8-bit PNG, defaults or `--semantic normal` | UNSIGNED_BYTE / RGBA / RGBA8 (0x8058) | 70 (RGBA8Unorm) | — |
| PNG + `--astc-compression-block-size 8x8` | 0 / 0 / COMPRESSED_RGBA_ASTC_8x8 (0x93B7) | 212 (ASTC 8×8 LDR) | — |
| EXR | HALF_FLOAT / RGBA / RGBA16F (0x881A) | 115 (RGBA16Float) | — |
| HDR + `--generate-cube-map --cube-face-size 32` | HALF_FLOAT / RGBA / RGBA16F, 6 faces, 6 mips | 115 | `com.apple.image.colorGamut` = `DisplayP3`, `com.apple.image.colorTransfer` = `linear` |

- **`.realityenv` output** (image-based light) is a `.reality`-format
  container (§6) with `minVersion` per target, whose assets are one
  `ImageBasedLight` (`ImageBasedLight_0.compiledimagebasedlight`,
  depending on three textures) and three `Texture` assets (skybox,
  specular and diffuse cube maps; `--cube-face-size`, `--specular-size`
  and `--diffuse-size` change their sizes; diffuse defaults to 64).
  Both the IBL and the first texture are listed in `scenes` with an empty
  `sceneName`. Without `--platform`: `error: Missing required --platform`.
  The `.skybox` compile path (§2.1) produces the same structure.

## 6. The `.reality` container (writer level)

Extends `specs/frameworks/realitykit/07-assets.md` §8. Everything below
was established from files we compiled ourselves, plus one sample-content
file shipped in Reality Composer Pro 3's project template, studied at
container level only, and confirmed by writing our own containers with a
Python writer (§6.8). `.realityenv` uses the same container.

### 6.1 ZIP layout

A ZIP archive (no ZIP64 end records; ZIP64 *extra fields* on local
headers), entries in this order:

1. `assets/<Kind>_<n>.<ext>` for every asset, in `assetMap.json`
   `assets` order (scene first, then its dependencies in discovery order,
   then the next scene …);
2. `assetMap.json` (stored);
3. `header.json` (stored);
4. `.align/` — an empty directory entry used as padding;
5. central directory, starting at a multiple of **4096**;
6. end-of-central-directory record with a 42-byte comment (§6.6).

Local file header (all entries): signature, version needed **45**, flags
**0**, method (§6.5), DOS time and date **0**, CRC-32 of the
**uncompressed** data, compressed and uncompressed sizes (32-bit), name,
extra field = ZIP64 extra `0x0001` (16 bytes: uncompressed size u64,
compressed size u64 — present even for small entries) followed by
`0xfffe` (32 bytes: **SHA-256 of the uncompressed data**). Entry data
follows immediately; asset data is **not** aligned.

Central directory header: version made by `0x133e` (host 19 = OS X,
spec version 6.2), version needed **20**, flags 0, same method, time,
date, CRC and sizes, extra field = only `0xfffe` (32 bytes), comment
empty, disk 0, internal attributes 0, external attributes
`0o100644 << 16` for files and `0o40777 << 16` for `.align/`, local
header offset.

`.align/` local header: method 0, sizes 0, CRC 0, extras `0x0001`
(16 zero bytes), `0xfffe` (32 zero bytes) and `0xffff` whose length *L*
makes the central directory start at the next multiple of 4096 after
the end of a minimal `.align/` header (`L` = padding, data all zero; seen
3 576 and 2 677 bytes). Its central-directory entry has no extra field.

### 6.2 Asset entry names and kinds

`assets/<Kind>_<n>.compiled<kind in lower case>`, `n` counting from 0 per
kind. Kinds seen: `Scene`, `Mesh`, `Material`, `ShaderGraph`,
`CollisionShape`, `PhysicsMaterial`, `Texture`, `ImageBasedLight`
(`07-assets.md` also lists animation library, animation scene and
timeline). Extra per-asset files for reduced textures:
`<Kind>_<n>.sourceimage` (AVIF) and `<Kind>_<n>_importOptions.json`.
The asset kinds `MaterialDefinition` (in a Reality Composer Pro 3 file)
appear in `assetMap.json` without a file of their own.

### 6.3 `header.json`

Compact JSON (no whitespace), keys in this order:

| Key | Type | Observed |
|---|---|---|
| `versionInfo` | object | `id` = `"com.apple.RealityKit"`; `frameworkVersion` = the compiling platform's RealityKit version string (453.7.5 visionOS, 453.2.1 iOS, 453.1.1 macOS, 453.3.1 tvOS, 453.40.5 for `image`; 425.0.0.0.3 in the RCP 3 template file); `originPlatform` = `"RealityFilePlatformMacOS"` |
| `minVersion` | integer | file-format level chosen from the deployment target (§2.3) |
| `metadata` | object | `{}` |
| `targetPlatform` | string | `"RealityFilePlatformAll"` for every `--platform` |
| `restrictedSeedVersion` | integer | 0 |

### 6.4 `assetMap.json`

Compact JSON, keys in this order:

| Key | Type | Meaning |
|---|---|---|
| `scenes` | array of objects | `fileName` (entry name without `assets/`), `sceneName` (string; §2.2), `sceneIdentifier` (null), `sceneCompatibilityVariants` (array, empty), and an identifier (below) equal to the scene asset's |
| `assets` | array of objects | `fileNames` (array of entry names without `assets/`), `internalDependencies` (array of indices into `assets`), `label` (scene name for scenes, else null), `metadata` (object; `cdm:primpath` = USD prim path, `cdm:resolvedpath` = absolute source file for textures, `Engine/RE-debugName` = prim path or file), identifier, `externalSource` (null), `typeName` (kind, §6.2) |
| `certifiedFreeOfChangeSceneActions` | bool | `true` in every file seen |
| `configurationSetNames`, `configurationEntryDescriptors`, `defaultConfigurationNames` | arrays | empty (they carry `Entity.ConfigurationCatalog` variants; not produced from our inputs) |

Identifiers come in two spellings:

- `realitytool`: `"GUID": ":<uuid, lower case>:1:00"`;
- Reality Composer Pro 3's exporter: `"guid": { "uuid": [16 byte values],
  "developerID": [10 one-character strings, all NUL], "version": 1,
  "flags": 0 }`.

The string form is read as `<developerID>:<uuid>:<version>:<flags as two
hex digits>` (inference from the two spellings). Both load.

### 6.5 Compression methods

| Method | Meaning |
|---|---|
| 0 | stored (`assetMap.json`, `header.json`, `.align/`, AVIF source images, small JSON) |
| 99 | the whole entry is one **plain LZFSE stream** (blocks `bvx-`, `bvxn`, `bvx1`, `bvx2`, end marker `bvx$`). No encryption: flag bit 0 is clear and there is no AES extra field; tools that see method 99 may wrongly report "AES encrypted". |
| 32867 (`0x8063`) | **chunked**: a `CHNK` frame (below). Used for most assets when `minVersion` ≥ 15; meshes stayed at 99 in every file seen |

`CHNK` frame (little-endian):

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic `CHNK` |
| 4 | 4 | 0 (version) |
| 8 | 4 | *N*, number of chunks |
| 12 | 4 | header size = 16 + 16·*N* |
| 16 | 16·*N* | per chunk: u64 offset of the chunk in the frame; u64 = (codec ≪ 56) \| offset of the chunk's data in the uncompressed output |

Codec 0 = raw bytes; codec `0x63` (`'c'`) = an LZFSE stream. A chunk
extends to the next chunk's frame offset (the last to the end of the
entry). In every file seen, chunk 0 is the payload's leading header kept
raw (95 bytes), followed by one or two LZFSE chunks. Reassembling the
chunks reproduces data whose CRC-32 and SHA-256 match the headers.

The open-source LZFSE encoder (BSD-3-Clause, `lzfse/lzfse`) reproduced
`realitytool`'s method-99 output byte for byte for our sample.

### 6.6 End record and the `RAD` trailer

EOCD: disk numbers 0, entry counts, central-directory size and offset,
comment length 42. Comment:

| Offset | Size | Value |
|---|---|---|
| 0 | 3 | `RAD` |
| 3 | 7 | `01 02 00 00 00 01 00` (constant in all files) |
| 10 | 32 | SHA-256 over the concatenation, in central-directory order, of each entry's name bytes followed by its 32-byte `0xfffe` value (entries without that extra — `.align/` — are skipped) |

### 6.7 Payloads

Each decompressed asset payload starts with the magic `CA01`, a u32
version (3), and a table of u64 section offsets/sizes; the rest is a
RealityKit-native serialisation of the engine object (a decoded texture
with mips, a mesh, a scene graph with components…). Its layout is not
public, it changes with `minVersion`, and reproducing it would mean
re-implementing RealityKit's internal object serialisation for every
asset kind. Levels 2–3 established the container completely; the payload
interior would need level 4–5 work (type-registry and serialiser study)
and was **not** attempted, because Ycode does not need it: see §7.

### 6.8 Loader tolerance (macOS 27 RealityKit, level 3)

Our own writer rebuilt a compiled file from its decoded entries. The
loader (`Entity(contentsOf:)` / `Entity(named:in:)`) accepted all of:
byte-identical rebuild; every entry stored (method 0); no `.align/` entry
and no `RAD` comment; a wrong `RAD` hash; no `0xfffe` extras. So the
integrity fields are not checked on macOS. Whether visionOS and iOS
devices check them is an open question; Ycode's writer emits them all.

### 6.9 Files written by RCP 3.0's exporter (level 2–3, OBS-RCP4)

Five headless exports of one app-made scene (`editor-behavior.md` §7a):
an entity export with `--reality-export-version` 27.0 (twice), 26.0 and
`15.0/18.0/2.0`, and one through a Reality Export Settings asset. Each
file is 78 945 bytes; our reader parsed every entry and verified CRC-32,
the `0xfffe` SHA-256 extras and the `RAD` hash.

| Item | RCP 3.0 exporter | `realitytool` (§6.1–§6.6) |
|---|---|---|
| ZIP layout, extras, version fields, zero times, `.align/` to 4096, `RAD` comment | same | — |
| Methods | 99 (plain LZFSE) for every compressed asset; the audio asset **stored** (0); no 32867 even at version 27.0 | 32867 for most assets from `minVersion` 15 |
| `header.json` | `frameworkVersion` `453.40.5`, `originPlatform` macOS, `targetPlatform` All, **`minVersion` 12 for every requested version** | `minVersion` follows the deployment target |
| Identifiers | string form `":<uuid>:1:00"`, new per export; the mesh asset has `"GUID": "INVALID"` | string form |
| `metadata` | `{}` on every asset: no prim paths, no absolute source paths | `cdm:primpath`, `cdm:resolvedpath`, debug names |
| Scene name | the exported entity's name (`world`) | the USD file's relative path |
| Asset kinds | `Scene`, `Material`, `Texture`, `ShaderGraph`, `Mesh`, `CollisionShape`, `AudioFile` (new kind for this table) | as §6.2 |

- Across the four entity exports only `assetMap.json` (GUIDs) and the
  scene and audio payloads (which embed them) changed; material, texture,
  shader-graph, mesh and collision-shape payloads were byte-identical. The
  requested version therefore had no visible effect on this content; the
  settings asset's stored `version` (we wrote 15) did not either. Whether
  the version only gates which components may be exported (the
  component-availability table, `editor-behavior.md` §7) is open (Q7).
- The one file shipped in RCP 3's template used the struct GUID form and
  `CHNK` frames (§6.4–§6.5); it was evidently made by another build
  (`frameworkVersion` 425.0.0.0.3). Readers accept both forms.
- Loaded with our macOS 27 probe, the file gave the expected scene: the
  entity tree with names, collision in trigger mode, input target, spatial
  audio, audio library, particle emitter, hover effect, grounding shadow,
  point light, and a `ShaderGraphMaterial` with a generated texture
  parameter (`materials.md` §10.1).
- Consequence for Ycode: RCP 3 `.reality` files carry no machine paths,
  unlike `realitytool` output (§2.6); Ycode's container writer should
  follow RCP 3 here and write empty `metadata`.

## 7. Consequences for Ycode

1. **Compiling on macOS**: Ycode's build system runs Apple's `realitytool`
   exactly as §3 describes (same tasks, inputs, outputs) — this is
   required for byte-compatible app bundles.
2. **Compiling elsewhere (Linux)**: Ycode's compiler cannot produce
   RealityKit payloads (§6.7). It validates the `.rkassets` tree with
   §2.2/§2.5 rules, runs the schema step (§4) itself, and packages the
   **USD sources** into the resource bundle (the open RealityKit loads
   USD, `07-assets.md` §8 policy 2). A container writer per §6 is still
   specified so that Ycode can re-pack, inspect and diff `.reality`
   files, and so that a future payload specification slots in.
3. Ycode's `create-schema` equivalent emits §4.4 output exactly
   (sorting, `customData`, `originalType`, `allowedTokens`, nested
   `RealityKitStruct`), but parses Swift with a real parser.
4. Ycode's editor names custom-component prims `<Module>_<Type>` with type
   `RealityKitCustomComponent` (§2.4, §4.5) and avoids duplicate scene
   base names (§3.4).

## Open questions

1. Do device loaders (visionOS, iOS) verify CRC, SHA-256 extras or the
   `RAD` hash?
2. Exact rule for method 99 vs 32867 per asset kind and size (RCP 3.0's
   exporter never used 32867 and stored audio uncompressed, §6.9).
3. Which scene wins for an ambiguous base name in `Entity(named:in:)`.
4. The expected content of a `.skybox` folder made by the editor (we
   used a single `.hdr`); whether several images or a JSON file are read.
5. Effect of `--use-metal` (none seen with one texture).
6. A visionOS-destination `xcodebuild` was not run (one build only); the
   bundle layout there is expected to be flat (`<Package>_<Target>.bundle/<Name>.reality`).
7. What RCP 3's `--reality-export-version` (and the settings asset's
   `version`) changes: four versions gave identical payloads and
   `minVersion` 12 for a simple scene (§6.9).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Option names and help text | 3 | `realitytool help compile|create-schema|image` |
| Inputs, outputs, scene discovery, naming, order | 3 | compiles of `<samples>/compile/*.rkassets`, `.skybox` |
| Minimum targets, `minVersion` table, per-platform framework versions | 3 | 19 compiles over all platforms (`<samples>/compile/plat/`) |
| `--reduced-texture-file-size`, `--use-metal`, `--derived-data`, `--schema-file` rewrite | 3 | our texture and custom-component samples; diff of the `realitytool-modified` copy |
| Silent drop of bad scenes; unknown components and fields | 3 | `E1`–`E3c` samples, loaded with the macOS probe |
| Determinism and GUID randomness, absolute paths in `assetMap.json` | 2, 3 | two identical compiles, per-entry CRC diff |
| Build tasks, rule names, command-line shape, JSON format, output location, package-only schema step | 1 | swift-build `RealityAssetsCompilerSpec.swift`, `RealityAssetsTaskProducer.swift`, `RealityAssets.xcspec`, `CompileSkybox.xcspec`, `AppleFileTypes.xcspec`, tests; SwiftPM `PackagePIFProjectBuilder.swift` |
| Observed build, bundle name, `Entity(named:in:)` behaviour, schema defaults baked in | 3 | one `xcodebuild` of our own packages (macOS), run of the built executable |
| `create-schema` accepted/rejected types, messages, output layout | 3 | runs on our own Swift files |
| KTX 1.1 fields, `.realityenv` structure, colour-space names | 2, 3 | `image` runs on our own PNG/EXR/HDR |
| ZIP layout, extras, alignment, methods 0/99, `RAD` trailer, `header.json`/`assetMap.json` keys | 2 | our compiled files, parsed at container level; hashes verified by recomputation |
| `CHNK` framing, RCP 3 identifier spelling | 2 | container-level study of one file shipped in Reality Composer Pro 3's template (format study, not copied), chunks reassembled and verified by CRC/SHA-256 |
| LZFSE decoding | 1, 2 | open-source `lzfse` (BSD-3-Clause) |
| Loader tolerance | 3 | our own re-packed containers loaded with the macOS probe |
| Payload interior not specified | — | deliberate: would need level 4–5; not needed (§7) |
| RCP 3.0 exporter output (§6.9) | 2, 3 | five headless exports of an owner-made sample, parsed with our container reader (hashes verified) and loaded by our macOS probe (OBS-RCP4) |
