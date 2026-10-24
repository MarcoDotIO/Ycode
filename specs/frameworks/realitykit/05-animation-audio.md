# RealityKit 5: animation and audio

Status: draft round 0. Sources: SDK module metadata (level 4),
documentation (level 1), probe runs (level 3, **[rv-anim]**, **[rv-usd]**,
**[rv-audio]**).

## 1. Model

- An **animation definition** (`AnimationDefinition` protocol, iOS 15)
  describes *what* changes over time and for how long. Common properties:
  `name`, `bindTarget` (what it drives), `blendLayer`, `fillMode`
  (`AnimationFillMode` none/forwards/backwards/both), `trimStart`,
  `trimEnd`, `trimDuration`, `offset`, `delay`, `speed`, `repeatMode`
  (`AnimationRepeatMode` none, repeat, cumulative, autoReverse),
  `duration`; helpers `trimmed`, `repeated(count:)`, `repeatingForever()`.
- An `AnimationResource` wraps a definition (`generate(with:)`), or groups
  (`group(with:)`) or sequences (`sequence(with:)`) of resources;
  `repeat(count:)`, `repeat(duration:)`; `definition` gives it back;
  iOS 18 `makeActionAnimation(for:…)` turns an entity action into an
  animation.
- Playing: `Entity.playAnimation(_:transitionDuration:blendLayerOffset:
  separateAnimatedValue:startsPaused:clock:handoffType:)` returns an
  `AnimationPlaybackController` (`isPlaying`, `isPaused`, `isComplete`,
  `isStopped`, `isValid`, `speed`, `time`, `blendFactor`, `duration`,
  `clock`, `pause()`, `resume()`, `stop()`, `stop(blendOutDuration:)`).
  `AnimationHandoffType`: `snapshotAndReplace`, `replace` (optionally all
  layers), `compose`, `stop`, `default`.
- `move(to:relativeTo:duration:timingFunction:)` is a transform
  animation helper. `AnimationTimingFunction`: `default`, `linear`,
  `easeIn`, `easeOut`, `easeInOut`, `cubicBezier(controlPoint1:
  controlPoint2:)`.
- Bind targets (`BindTarget` / `BindPath`): `transform`,
  `jointTransforms`, `parameter(name)`, entity paths (`entity(name)`,
  `anchorEntity`, `scene`), `opacity` (18), material paths (base colour
  tint, scales, emissive, opacity threshold, texture coordinate offset,
  custom value; 18), blend-shape weights, billboard blend factor, IK
  targets, skeletal poses (18), root motion (27). Animatable value types
  (`AnimatableData`): `Float`, `Double`, SIMD2/3/4<Float>, `simd_quatf`,
  `Transform`, `JointTransforms`, `BlendShapeWeights`.

## 2. Definition types

| Type | iOS | Content |
|---|---|---|
| `FromToByAnimation<Value>` | 15 | from/to/by values with a timing function and additive flag; joint-transform and blend-weight variants |
| `SampledAnimation<Value>` | 15 | key frames at a fixed `frameInterval` with `tweenMode` (`hold`, `linear`); `start`, `end`; iOS 27 skeletal post-processing (`extractRootMotion`, convert to additive, retargeting) |
| `OrbitAnimation` | 15 | orbit around an axis (rotation count, orient to path, spin direction) |
| `AnimationView` | 15 | a trimmed/retimed view of another definition |
| `AnimationGroup` | 15 | parallel group |
| `BlendTreeAnimation<Value>` | 15 | tree of `BlendTreeSourceNode` / `BlendTreeBlendNode` with weights from values, parameters or bind targets |
| `ActionAnimation<Action>` | 18 | timeline of entity-action events |
| `AnimationGraphResource` + `AnimationGraphComponent` | 27 | state machines and clips authored in Reality Composer Pro |

## 3. Observed timing semantics **[rv-anim]**

Measured against the scene time (sum of `SceneEvents.Update.deltaTime`):

1. `move(to:…duration: 1, timingFunction: .linear)` starts in the frame it
   is called (`PlaybackStarted` at the first update) and its value is
   linear in time; it completed at scene time 1.025 (one frame after 1.0).
2. **Values read in a `SceneEvents.Update` handler are one frame old**:
   at scene time 0.4926 the moved x was 0.4774, equal to the controller's
   `time`, which was the previous frame's time. Animation evaluation
   therefore runs after the update events of the frame (and after
   systems), so a system that reads animated values sees last frame's
   result.
3. `FromToByAnimation` with `repeatMode: .autoReverse` reported
   `duration == ∞` and posted `PlaybackLooped` once per second (each
   direction counts as a loop); easing applied per direction.
4. `SampledAnimation<Float>` with 3 frames and `frameInterval` 0.5 ran for
   **1.5 s** (completed at 1.525): the duration is frame count ×
   interval, the last key held for one interval; values are linearly
   interpolated (`tweenMode` default `.linear`).
5. Completion order: `PlaybackCompleted` then `PlaybackTerminated` in the
   same update; `stop()` posts `PlaybackTerminated` only.
6. `AnimationPlaybackController.time` returns to 0 after completion.

## 4. Skeletal animation, blend shapes, IK

- Skeletons: `MeshResource.Skeleton` (joint names, parent indices,
  inverse bind poses, rest poses), `MeshResource.JointInfluences`,
  `SkeletonResource` (27, joint builder, blend masks),
  `SkeletalPosesComponent` / `SkeletalPoseSet` / `SkeletalPose` (18),
  `jointNames` and `jointTransforms` on `HasModel`.
- From USD: a `SkelRoot` with a skinned `Mesh` loaded as a `ModelEntity`
  at the SkelRoot with `ModelComponent`, `SkeletalPosesComponent`,
  `MeshDeformerComponent` and `AnimationLibraryComponent`; the
  `Skeleton` and `Mesh` prims became plain child entities; the
  `SkelAnimation` became a 1.0 s animation (24 time codes at 24 per
  second) **[rv-usd]**.
- Blend shapes: `BlendShapeWeightsMapping`, `BlendShapeWeightsComponent`,
  `BlendShapeWeights`, mesh blend-shape offset buffers (18).
- Inverse kinematics: `IKRig` (joints with limits and stiffness;
  constraints `point`, `orient`, `parent`, `lookAtAdditive`,
  `lookAtAbsolute` with position/orientation demands), `IKResource`,
  `IKComponent` with solvers (18). `RetargetingConfiguration` (27, biped
  and quadruped auto-matching).
- Deformation pipeline (27): `MeshDeformerComponent` with a
  `MeshDeformationStack` of deformers (`SkinningDeformer`,
  `BlendShapeDeformer`, `SubdivisionSurfaceDeformer`,
  `RenormalizingDeformer`, `BoundingBoxCalculator`, custom `MeshDeformer`
  on CPU or GPU with `MeshDeformParameter` buffers).

## 5. Entity actions (iOS 18) and behaviour trees (27)

`EntityAction` values (`Codable`) are played as animations
(`ActionAnimation`) and raise `ActionEvent`s (started, updated, ended,
skipped, paused, resumed, terminated) to handlers registered with
`subscribe(to:)` or an `ActionHandlerProtocol`. Built-in actions:
`FromToByAction` (transform modes parent/local/scene/relative),
`SpinAction`, `OrbitEntityAction`, `EmphasizeAction` (pop, blink,
bounce, flip, float, jiggle, pulse, spin × basic/playful/wild),
`BillboardAction`, `ImpulseAction`, `PlayAnimationAction`,
`PlayAudioAction`, `SetEntityEnabledAction`. iOS 27 `BehaviorTreeAction`,
`BehaviorTreeActionHandler` (handlers return `ActionResult` running/
failure/success), `BehaviorTreeResource`, `BehaviorTreeComponent`.

## 6. Implicit animation (iOS 26)

`Entity.animate(_:body:completion:)` (SwiftUI overlay) animates changes
made in the body to components marked implicitly animatable: `Transform`,
`ModelComponent`, `OpacityComponent`, lights, `BillboardComponent`,
particle emitters, audio components (27), `ToneMappingComponent`,
`BloomOptionsComponent`, decal, projective texture.

## 7. USD animations

Every Xform entity loaded from USD carries an `AnimationLibraryComponent`;
`availableAnimations` on the loaded root listed two animations, "global
scene animation" and "default subtree animation", each with the stage's
duration (`(endTimeCode − startTimeCode) / timeCodesPerSecond`: 48 / 24 =
2.0 s for our file) **[rv-usd]**. Transform time samples
(`xformOp:rotateY.timeSamples`) became transform animation.

## 8. Audio

### 8.1 Resources

| Resource | Content |
|---|---|
| `AudioFileResource` | a file (named in a bundle or at a URL) with `Configuration`: loading strategy (`stream`, `preload`), loop, random start, normalisation (`dynamic`), calibration (`relative`/`absolute` dB SPL), mix group |
| `AudioFileGroupResource` | a set of files, one chosen per play |
| `AudioBufferResource` | an `AVAudioPCMBuffer` with the same configuration (18) |
| `AudioGeneratorConfiguration` | live generator (render callback, 18; `Entity.playAudio(configuration:_:)` returns an `AudioGeneratorController`) |
| `ReverbMeshResource` (27) | room geometry with `Audio.Material`s (absorption, scattering per frequency; presets concrete, wood, glass, carpet, water…) |

### 8.2 Playback and spatialisation

- `Entity.playAudio(_:)` / `prepareAudio(_:)` return an
  `AudioPlaybackController` (`play`, `pause`, `stop`, `seek(to:)` 18,
  `play(at:)` 27, `gain` in dB, `speed`, `fade(to:duration:)`,
  `isPlaying`, `completionHandler`). `stopAllAudio()`.
- How a source sounds depends on the component on the entity:
  `SpatialAudioComponent` (positional: gain, direct and reverb level,
  `Audio.Directivity.beam(focus:)`, `Audio.DistanceAttenuation.rolloff`),
  `AmbientAudioComponent`, `ChannelAudioComponent`. The listener is the
  camera (`ARView.audioListener`, `RealityRenderer.audioListener` 27).
- Mix groups (`AudioMixGroup`, `AudioMixGroupsComponent`), reverb
  (`ReverbComponent` with `Reverb.preset(...)`, `anechoic`, iOS 27
  `simulated(mesh:materials:)`), `ARView.environment.reverb`.
- Observed **[rv-audio]**: a 0.5 s, 48 kHz mono `AVAudioPCMBuffer` made an
  `AudioBufferResource` with `duration` 0.5 s; playing it on an entity
  with a `SpatialAudioComponent` reported `isPlaying` true and gain 0 dB,
  and `AudioEvents.PlaybackCompleted` arrived 0.87 s (wall time) after
  `play`; afterwards `isPlaying` was false. Audio output works in the
  simulator.

## Evidence

| Claim | Level | Source |
|---|---|---|
| API names, availability | 4 | SDK `.swiftinterface` |
| Timing semantics §3 | 3 | **[rv-anim]** (scene-time sampling) |
| USD skeleton/animation mapping §4, §7 | 3 | **[rv-usd]** with our own `skinned.usda`, `cube.usda` |
| Audio behaviour | 3 | **[rv-audio]** |
| Purposes of actions, deformers, IK | 1 | developer.apple.com symbol pages (paraphrased) |
