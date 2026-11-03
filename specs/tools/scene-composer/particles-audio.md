# Scene composer 5: particle emitters and audio

Status: draft, OBS-RCP round (2026-10-29); RCP 3 storage added by OBS-RCP4. Method: our own USDA under
`<samples>/particles-audio/` (generated WAV and PNG files only), loaded
with RealityKit on macOS 27 and compiled with `realitytool compile
--platform xros --deployment-target 27.0`; the compiled `.reality` loaded
to the same component values as the USDA (dumps diffed). Component
encoding in general: `scene-usd.md` (`RealityKitComponent`,
`info:id = "RealityKit.<Name>"`, nested `RealityKitStruct`,
`RealityKitDict`).

## 1. Particle emitter component

```
def RealityKitComponent "VFXEmitter"
{
    uniform token info:id = "RealityKit.VFXEmitter"
    def RealityKitStruct "currentState"          # emitter-level settings (§1.1)
    {
        ...
        def RealityKitStruct "mainEmitter" { ... }      # per-particle settings (§1.2)
        def RealityKitStruct "spawnedEmitter" { ... }   # optional secondary emitter, same fields
    }
}
```

Runtime result: `ParticleEmitterComponent`. An empty component (no
`currentState`) is valid and yields all defaults below. Omitting
`spawnedEmitter` leaves the runtime `spawnedEmitter` nil; authoring it
(even with one field) creates one whose unset fields take the
main-emitter defaults. USD attribute names differ from the Swift property
names in several places; both are listed.

### 1.1 `currentState` fields (verified)

| USD attribute (type) | Swift property | Default | Values / notes |
|---|---|---|---|
| `emissionDuration` (double) | `emissionDuration` | 1.0 | |
| `emissionDurationVariation` (double) | same | 0 | |
| `idleDuration` (double) | same | 0 | |
| `warmupDuration` (double) | same | 0 | |
| `loops` (bool) | `shouldLoop` | true | |
| `emitterShape` (token) | `emitterShape` | plane | `Point`, `Plane`, `Box`, `Sphere`, `Cone`, `Cylinder`, `Torus` |
| `shapeSize` (float3) | `emitterShapeSize` | (0.1, 0.1, 0.1) | metres |
| `birthLocation` (token) | `birthLocation` | surface | `Surface`, `Volume`, `Vertices` |
| `birthDirection` (token) | `birthDirection` | normal | `Normal`, `Local` verified; `World` and `world` left the default (open question 1) |
| `emissionDirection` (float3) | same | (0, 1, 0) | |
| `particleSpeed` (float) | `speed` | 0.5 | m/s |
| `particleSpeedVariation` (float) | `speedVariation` | 0 | |
| `radialAmount` (float) | same | 2π (6.2831855) | radians |
| `torusInnerRadius` (float) | same | 0.25 | |
| `spawnOccasion` (token) | same | onDeath | `OnBirth`, `OnDeath`, `OnUpdate`, `OnCollide` (C++-style capitalised names) |
| `isSpawningEnabled` (bool) | same | false | stays false unless authored, even when `spawnedEmitter` exists |
| `spawnVelocityFactor`, `spawnSpreadFactor`, `spawnSpreadFactorVariation`, `spawnInheritParentColor` | `spawnVelocityFactor`… `spawnInheritsParentColor` | 1, 0, 0, false | names from level 4; defaults observed |
| `isLocal` (bool) | `simulationSpace` = local and `particlesInheritTransform` = true | false (global, false) | one USD flag drives two Swift properties |
| `isLocalFields` (bool) | `fieldSimulationSpace` = local | false (global) | |
| `isEmitting` (bool) | same | true | |
| `burstCount` (int64) | same | 100 | |
| `burstCountVariation` (int64) | same | 0 | level-4 name |
| — | `simulationState` | play | not authored by RCP |
| — | `simulationRate`, `restartCount`, `burstRestartCount` | 1, 0, 0 | runtime state |

### 1.2 `mainEmitter` / `spawnedEmitter` fields (verified)

| USD attribute (type) | Swift property | Default |
|---|---|---|
| `birthRate` (float) | `birthRate` | 100 |
| `birthRateVariation` (float) | same | 0 |
| `particleSize` (float) | `size` | 0.02 |
| `particleSizeVariation` (float) | `sizeVariation` | 0 |
| `particleLifeSpan` (double) | `lifeSpan` | 1.0 |
| `particleLifeSpanVariation` (double) | `lifeSpanVariation` | 0.2 |
| `particleMass` / `particleMassVariation` (float) | `mass` / `massVariation` | 1 / 0 |
| `particleAngle` / `…Variation` (float) | `angle` / `angleVariation` | 0 / 0 |
| `particleAngularVelocity` / `…Variation` (float) | `angularSpeed` / `angularSpeedVariation` | 0 / 0 |
| `particleBounce` (float) | `bounce` | 0.3 |
| `particleFriction` (float) | `friction` | 0 |
| `acceleration` (float3) | same | (0, 0, 0) |
| `dampingFactor` (float) | same | 0 |
| `spreadingAngle` (float) | same | 0 (radians) |
| `collisions` (bool) | `areCollisionsEnabled` | false |
| `startColorA`, `startColorB`, `endColorA`, `endColorB` (float4 RGBA) | same (colours) | A start (1, 0.2936, 0, 1); B start (≈1, 1, 1, 1); A end (0.0013, 0.0322, 1, 1); B end (0.2957, 0.0150, 0.2885, 1) |
| `useStartColorRange`, `useEndColorRange` (bool) | same | false, false |
| `useEndColor` (bool) | same | true |
| `colorEvolutionPower` (float) | same | 1 |
| `opacityOverLife` (token) | `opacityCurve` | quickFadeInOut; tokens `LinearFadeIn` (verified), `EaseFadeOut` (verified), `LinearFadeOut`, `GradualFadeInOut`, `QuickFadeInOut`, `EaseFadeIn` (level-4 names); Swift's `constant` case has no observed token |
| `sizeMultiplierAtEndOfLifespan` (float) | same | 0.1 |
| `sizeMultiplierAtEndOfLifespanPower` (float) | same | 1 |
| `noiseStrength`, `noiseScale`, `noiseAnimationSpeed` (float) | same | 0, 1, 0 |
| `radialGravityStrength` (float) | `attractionStrength` | 0 |
| `radialGravityCenter` (float3) | `attractionCenter` | (1, 1, 0) |
| `vortexStrength` (float), `vortexDirection` (float3) | same | 0, (0, 1, 0) |
| `isLightingEnabled` (bool) | same | false |
| `stretchFactor` (float) | same | 0 |
| `billboardMode` (token) | same | billboard; tokens `Billboard`, `BillboardYAligned`, `Free` (free gets axis (0,1,0), variation 0; level-4 fields `billboardAxis`, `axisVariation`) |
| `sortOrder` (token) | same | increasingDepth; tokens `IncreasingDepth`, `DecreasingDepth`, `IncreasingID`, `DecreasingID`, `IncreasingAge`, `DecreasingAge`, `Unsorted` (a `sorting` attribute was ignored) |
| `blendMode` (token) | same | alpha; tokens `Alpha`, `Opaque`, `Additive` |
| `particleImage` (asset) | `image` | none (the runtime then uses its built-in round sprite) |
| `isAnimated` (bool) + `rowCount`, `columnCount`, `initialFrame`, `initialFrameVariation` (int64), `frameRate`, `frameRateVariation` (float), `animationRepeatMode` (token `PlayOnce`, `Looping`, `AutoReverse`) | `imageSequence` | nil; set only when `isAnimated` is true (a sheet with rows but `isAnimated` unset stayed nil) |

Colours are read as **linear sRGB** components (our (1,0,0,1) loaded as a
linear-sRGB colour (1,0,0,1)).

Token spelling rule: enum tokens use the runtime's capitalised C++ names
(`Sphere`, `OnCollide`, `EaseFadeOut`), not Swift's lower-camel names.

### 1.3 Presets

RealityKit's public presets (names only): `fireworks`, `impact`, `magic`,
`rain`, `snow`, `sparks` (`ParticleEmitterComponent.Presets`). An editor
preset is just a set of the fields above plus, optionally, a particle
image. Ycode ships its own preset values and images; Apple's preset
contents are not copied.

### 1.4 How RCP 3 stores an emitter (OBS-RCP4)

RCP 3.0 keeps the emitter as `tm_re_particle_emitter_component` in its
own project format (`project-format.md` §4.7.4), **not** in the USD
shape above, and its USD export drops it (`scene-usd.md` §5.1). The
stored form, for the RCP 3 importer:

- No `currentState` level: the emitter-level fields sit on the component
  itself; the per-particle sets are `mainEmitter` and
  **`secondaryEmitter`** (USD: `spawnedEmitter`), both of type
  `tm_re_particle_emitter`, both always present.
- Field names are the **Swift** property names, not the USD names:
  `speed`, `speedVariation`, `emitterShapeSize`, `shouldLoop`,
  `particlesInheritTransform`, `fieldsSimulationSpace`, `spawningEnabled`,
  `simulationState`, `burstCount`/`burstCountVariation` (int32),
  `idleDurationVariation`; per particle `lifeSpan`, `size`, `mass`,
  `angle`, `angularSpeed`, `opacityCurve`, `attractionStrength`,
  `attractionCenter`, `particleImage` (a reference to a texture asset),
  `billboardAxis`, `billboardAxisVariation`, and an `imageSequence`
  subobject (`animationMode`, `rowCount`, `columnCount`, `initialFrame`,
  `initialFrameVariation`, `frameRate`, `frameRateVariation`).
- Enumerations are integers. Type-index defaults: `emitterShape` 1,
  `birthDirection` 2, `fieldsSimulationSpace` 1, `spawnOccasion` 2,
  `simulationState` 2, `billboardMode` 1, `opacityCurve` 3; a new emitter
  exported to `.reality` loads as plane, normal, global, on death, play,
  **billboardYAligned** and quick fade in/out. The full integer ↔ case
  tables are not established (one value each).
- Colours are `tm_color_aces2065_rgba`: **ACES2065-1** components, alpha
  omitted when 1. The stored defaults convert to the linear-sRGB
  defaults of §1.2 (e.g. start colour A (0.5521, 0.3286, 0.0503) →
  (1, 0.2936, 0)).
- Defaults that differ from a plain USD/API emitter (§1.1–§1.2): the
  image sequence defaults to 3 × 3 frames at 9 fps (inactive while
  `isAnimated` is false); billboard mode Y-aligned. The end colour B
  loaded from RCP's `.reality` as linear (0.114, 0.0065, 0.106) although
  the stored value converts to the §1.2 default (0.296, 0.015, 0.289);
  not explained.



An audio file is a **prim**, not a component; components reference it.

```
def RealityKitAudioFile "tone_wav"            # RCP names it after the file, '.' → '_'
{
    uniform asset file = @tone.wav@            # relative to this layer
    uniform bool shouldLoop = 0                # default false
    uniform bool shouldRandomizeStartTime = 0  # default false
    uniform token loadingStrategy = "preload"  # "preload" (default) | "stream"
    uniform token normalization = "dynamic"    # optional; absent = none
    uniform token calibrationMode = "absolute" # optional: "absolute" | "relative"
    uniform double absoluteCalibration = 80    # dB SPL, used with "absolute" (80 when omitted)
    uniform double relativeCalibration = 0     # dB, used with "relative"
    rel mixGroup = </Root/Music>               # optional RealityKitAudioMixGroup
}
```

Runtime result: an `AudioFileResource` whose configuration carries
`loadingStrategy`, `shouldLoop`, `shouldRandomizeStartTime`,
`normalization` (kind dynamic), `calibration` (absolute dB SPL / relative
dB) and `mixGroupName` = **the mix-group prim's name**. A file prim is
only loaded when something references it (an `AudioLibrary` entry or a
timeline `audio` action through the library). The compiled container
stores each as an `AudioFile_<n>.compiledaudiofile` asset.

Groups (random-pick sets):

```
def RealityKitAudioFileGroup "Footsteps"
{
    def RealityKitAudioFile "step1" { uniform asset file = @step1.wav@ }
    def RealityKitAudioFile "step2" { uniform asset file = @step2.wav@ }
}
```

The member files are **child prims**; the group loads as an
`AudioFileGroupResource` with one resource per child (relationship
attributes `files`, `audioFiles`, `sources`, `resources`, `values` were
all ignored).

Mix groups: `def RealityKitAudioMixGroup "<Name>"` with `float gain`,
`bool mute`, `float speed` (level-4 names; the prim name reached
`mixGroupName`, the three values were not observable at load).

## 3. Audio components (verified)

| Prim | `info:id` | Attributes (type) → runtime | Defaults |
|---|---|---|---|
| `SpatialAudio` | `RealityKit.SpatialAudio` | `gain`, `directLevel`, `reverbLevel` (float, dB); `directivityFocus` (float 0–1) → `directivity = .beam(focus:)`; `rolloffFactor` (float) → `distanceAttenuation = .rolloff(factor:)` | 0, 0, 0, focus 0, rolloff 1 |
| `AmbientAudio` | `RealityKit.AmbientAudio` | `gain` (float, dB) | 0 |
| `ChannelAudio` | `RealityKit.ChannelAudio` | `gain` (float, dB) | 0 |
| `AudioLibrary` | `RealityKit.AudioLibrary` | `def RealityKitDict "resources"` with `string[] keys` and `rel values` (same order) → `AudioLibraryComponent.resources[key]` | empty |
| `Reverb` | `RealityKit.Reverb` | `token reverbPreset` → `.preset(…)`; tokens `Outside`, `ConcertHall`, `VeryLargeRoom`, `LargeRoom`, `LargeRoomTreated`, `MediumRoomDry`, `MediumRoomTreated`, `SmallRoom`, `SmallRoomBright`, `VerySmallRoomBright`; unknown or absent → `anechoic` | anechoic |
| `AudioMixGroups` | `RealityKit.AudioMixGroups` | `rel mixGroups` was not taken (runtime list stayed empty; open question 3) | empty |

Library keys are free strings; RCP uses the file name (`tone.wav`). The
timeline `audio` action names a library key (`timelines-behaviors.md`
§3), so an entity that plays audio needs both the `AudioLibrary` entry
and, for positional sound, a `SpatialAudio` component on the same or the
target entity.

Level-4 field names on the runtime audio and reverb components not
covered by the table (for later rounds): reverb `priority`,
`allowSpaceBlendingWithReverbPreset`, `reverbType`, `audioMaterials`,
`meshAsset` (simulated reverb, iOS 27).

### 3.1 How RCP 3 stores audio (OBS-RCP4)

From an app-made project (`project-format.md` §4.7.4–§4.7.5):

| RCP 3 object | Content | Runtime result of its `.reality` export |
|---|---|---|
| `tm_audio_file_asset` (file `<name>.tm_audio_file`) | the original file as a buffer, decoded 32-bit float samples as a second buffer, `sample_rate`, `num_channels`; flags `should_loop`, `should_randomize_start`, `should_stream`; `calibration_mode`, `calibration_level_absolute` (default 80) / `_relative`, `normalization_mode`, `mix_group` | an `AudioFileResource` (preload, no loop, no normalisation, no calibration, no mix group) |
| `tm_re_audio_library_component` | `"Audio Resources"`: `{ Name, "Audio Asset" }` entries | `AudioLibraryComponent` with key = `Name` = the asset name **without extension** (RCP 2 used the file name with extension) |
| `tm_re_spatial_audio_component` | `gain`, `direct_level`, `reverb_level`, `focus` (0), `rolloff_factor` (1) | `SpatialAudioComponent` with those defaults |

The spatial-audio component has no file reference of its own: what it
plays comes from the library through a behavior or app code, as in §3.
In the container the audio asset is `AudioFile_0.compiledaudiofile`,
**stored** (method 0), and shorter than the source WAV (66 250 vs
88 244 bytes for 1 s of 16-bit mono): the exporter re-encodes it.

## 4. File formats accepted

The USD reader allows core audio files embedded or referenced as
`.m4a`, `.mp3`, `.wav` (USDZ packaging rule in the bundled USD library's
validator text, level 4). Our PCM WAV (16-bit, 48 kHz, mono) loaded and
compiled; its duration (0.5 s) was reported on the resource.

## 5. UsdMedia `SpatialAudio` prims

The public UsdMedia schema (`def SpatialAudio` with `filePath`,
`auralMode` = `spatial`/`nonSpatial`, `playbackMode` = `onceFromStart`,
`onceFromStartToEnd`, `loopFromStart`, `loopFromStartToEnd`,
`loopFromStage`, `startTime`, `endTime`, `mediaOffset`, `gain`) is read as
a track of the stage's scene animation, not as components: our prim gave
its entity an `AnimationLibraryComponent` and no audio components, and on
macOS the track came out as an invalid animation definition. Ycode's
editor should therefore write the RealityKit form of §2–§3 and treat
UsdMedia audio as import-only.

## 6. Requirements for Ycode

1. Write emitters with the USD names of §1 (not Swift names) and
   capitalised enum tokens; write colours as linear sRGB float4.
2. Write audio as `RealityKitAudioFile` prims referenced from an
   `AudioLibrary` dictionary; groups as parent prims; mix groups by `rel`.
3. Readers apply the defaults of §1.1–§1.2 and §3 for absent attributes.

## 7. Open questions

1. How `birthDirection = world` is spelled (neither `World` nor `world`
   took effect).
2. Whether `currentState` holds further fields RCP writes (e.g. collision
   planes, `fieldSimulationSpace` as its own attribute, burst restart).
3. The `AudioMixGroups` component's USD form and the effect of mix-group
   `gain`/`mute`/`speed`.
4. **Answered as far as RCP 3 can answer it** (§1.4, §3.1): RCP 3 stores
   emitters and audio in its own format and writes neither to USD, so "the
   attribute set RCP writes to USD by default" does not exist for RCP 3. A
   mix group was not in the sample.
5. The integer ↔ case tables of RCP 3's emitter enumerations (needs an
   emitter with non-default shape, direction, billboard, opacity curve).
6. Why RCP 3's exported end colour B differs from its stored value.
7. The audio codec inside RCP 3's exported `compiledaudiofile`.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Emitter field names (USD side) | 4 → 3 | CoreRE type-registry name strings; each verified on `<samples>/particles-audio/p0.usda`, `p1.usda` with RealityKit on macOS 27 |
| Emitter defaults | 3 | empty `VFXEmitter` component loaded |
| Enum token spellings | 3 | `p1.usda` (one entity per token) |
| Same values after `realitytool compile` | 3 | `PA.reality` dump identical to direct load |
| Preset names | 4 | SDK interface (`api-inventory.md`) |
| Audio file prim, group, calibration, mix group name | 4 → 3 | RealityIO name strings; `a1–a3.usda` |
| Audio components, reverb presets | 3, 4 | `a1.usda`, `a2.usda`, `r1.usda`; preset list from SDK interface |
| Accepted audio extensions | 4 | validator text in the bundled USD library |
| UsdMedia SpatialAudio handling | 1, 3 | OpenUSD UsdMedia schema; `a4.usda` |
| RCP 3 emitter and audio storage, defaults (§1.4, §3.1) | 2 | owner-made RCP 3 sample and its type index, read with our parser (OBS-RCP4) |
| Runtime values of RCP 3's emitter, audio library, spatial audio | 3 | headless `.reality` export of that sample loaded by our macOS probe (OBS-RCP4) |
| ACES2065-1 storage of colours | 2, 3 | stored values recomputed through the public ACES AP0 → linear sRGB matrix, compared with the loaded colours |
