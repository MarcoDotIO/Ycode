# RealityKit 2: catalogue of built-in components

Status: draft round 0. Names and availability from SDK module metadata
(level 4); purposes in our own words from public documentation (level 1);
defaults observed with the probe (level 3, **[rv-ecs]**, **[rv-mat]**,
**[rv-physics]**). The member names of every component are in
`api-inventory.md`; this file says what each one is for and which round
implements it (`10-plan.md`).

"iOS n" is the first iOS release with the type. "visionOS only" means not
available on iOS (out of scope for the first rounds).

## 1. Core and hierarchy

| Component | iOS | Purpose | Round |
|---|---|---|---|
| `Transform` | 13 | Local scale, rotation, translation (`01-architecture.md` §5). Every entity has one. Codable (18), implicitly animatable (26). | 1 |
| `SynchronizationComponent` | 13 | Network identity and ownership of the entity; every entity has one by default (§9). | 1 (stub), 7 |
| `AttachedTransformComponent` | 26 | Keeps an entity's transform attached to another entity (source → target). | 4 |
| `ReferenceComponent` | 18 | A reference to an entity stored in another file, loaded immediately or on demand (`loadingPolicy`, `state`, static `loadReference`/`releaseReference`). | 6 |
| `GeometricPinsComponent` | 18 | Named attachment points (position, orientation, optional skeletal joint) used by joints and attachments. | 4 |
| `AccessibilityComponent` | 17 | Accessibility label, value, traits, custom content, actions, rotors. | 7 |
| `WorldComponent` | 18 (visionOS 1) | Marks a separate world (portal target content). | 5 |

## 2. Rendering

| Component | iOS | Purpose | Round |
|---|---|---|---|
| `ModelComponent` | 13 | A `MeshResource` plus an array of materials (one per material index of the mesh) and `boundsMargin`. The renderable. | 2 |
| `MeshInstancesComponent` | 26 | GPU instancing: one mesh part drawn with many per-instance transforms (`LowLevelInstanceData`). | 3 |
| `OpacityComponent` | 18 | Multiplies the opacity of the entity and its descendants (0…1). Animatable through `BindTarget.opacity`. | 2 |
| `ModelSortGroupComponent` | 18 | Explicit draw order within a `ModelSortGroup` (depth pre-pass / post-pass). | 3 |
| `ModelDebugOptionsComponent` | 14 | Debug visualisation of one material input (normals, UVs, base colour, roughness, lighting terms…). | 3 |
| `BillboardComponent` | 18 (visionOS 2) | Rotates the entity to face the camera (`blendFactor`). | 3 |
| `TextComponent` | 18 (visionOS 1) | 2D text panel (text, size, background colour, corner radius, insets). | 6 |
| `ClippingComponent` | 27 | Clips self and/or children to a box with feathered edges. | 6 |
| `RenderLayerComponent` | 27 | Puts the entity in named render layers; lights and shadows can be restricted to layers. | 6 |
| `LevelOfDetailComponent` | 27 | Chooses one of several child entity sets by camera distance, screen area or a resolution metric. | 6 |
| `OcclusionCullingComponent` | 27 | Enables occlusion culling for the entity. | 6 |
| `AdaptiveResolutionComponent` | 18 | Reports the pixels per metre at which the entity is drawn. | 6 |
| `PhysicallyBasedDecalComponent` | 27 | Projects PBR decals (base colour, normal, roughness…) onto receiver entities inside bounds. | 6 |
| `MeshDeformerComponent` | 27 | A stack of mesh deformers (skinning, blend shapes, subdivision, renormalisation, bounding box, custom CPU/GPU deformers) applied before rendering. Present on skinned meshes loaded from USD **[rv-usd]**. | 4 |
| `PortalComponent` / `PortalCrossingComponent` | 18 | Renders a target world through a surface; clipping and crossing by plane (18) or volume (27). | 5 |
| `ParticleEmitterComponent` | 18 | CPU/GPU particle emitter with a main and a spawned emitter; presets in `RealityKit` (`fireworks`, `impact`, `magic`, `rain`, `snow`, `sparks`). | 5 |
| `HoverEffectComponent` | 18 | Highlight/spotlight/shader effect when an input device hovers (visionOS gaze; iOS pointer). | 6 |
| `VideoPlayerComponent` | 18 | Plays an `AVPlayer` on a generated screen mesh; immersive modes are visionOS only. | 6 |
| `ImagePresentationComponent` | visionOS only | Spatial photo presentation. | — |
| `EnvironmentBlendingComponent`, `DockingRegionComponent` | visionOS only | Passthrough blending, video docking. | — |

## 3. Lights, shadows, image-based lighting, post effects

| Component | iOS | Purpose and observed defaults | Round |
|---|---|---|---|
| `DirectionalLightComponent` | 13 | Sun-like light along the entity's −Z. `intensity` in lux; default **2145.7078** **[rv-ecs]**; `color`; `layers` (27). | 2 |
| `DirectionalLightComponent.Shadow` | 13 | Shadow map for a directional light: `depthBias`, `maximumDistance` (deprecated), `shadowProjection` (fixed or automatic, 18), `cullModeOverride`, cascades (27). | 3 |
| `PointLightComponent` | 13 | Omni light: `intensity` in lumens, default **26963.76**; `attenuationRadius` default **10** m; `attenuationFalloffExponent` default **2** (18). | 2 |
| `SpotLightComponent` | 13 | Cone light along −Z: `intensity` default **6740.94** lm; `innerAngleInDegrees` **45**; `outerAngleInDegrees` **60**; `attenuationRadius` **10**. `Shadow` (zNear/zFar, depth bias, cull override; 27: light size, quality); `ProjectiveTexture` (27). | 2 (light), 3 (shadow) |
| `ImageBasedLightComponent` | 18 | Makes the entity a source of image-based light from an `EnvironmentResource` (`.single` or `.blend` of two), with `intensityExponent` and `inheritsRotation`. | 3 |
| `ImageBasedLightReceiverComponent` | 18 | Says which IBL source entity lights this entity. | 3 |
| `EnvironmentLightingConfigurationComponent` | 18 | Weight of the environment (system) lighting on the entity. | 3 |
| `VirtualEnvironmentProbeComponent` | 18 | Reflection/environment probes, global or local with parallax bounds (27). | 6 |
| `DiffuseLightProbeGroupComponent` / `…ReceiverComponent` | 27 | Baked diffuse probe volumes (`DiffuseProbeResource`) and their receivers. | 6 |
| `LightmapComponent` | 27 | Baked lightmaps (`LightmapResource`): AO, indirect diffuse or final shaded colour. | 6 |
| `GroundingShadowComponent` | 18 | Contact/grounding shadow cast onto (and received from) real or virtual surfaces. | 3 |
| `DynamicLightShadowComponent` | 18 | Opts an entity out of casting dynamic-light shadows. | 3 |
| `ToneMappingComponent` | 27 | Filmic tone-curve parameters (exposure, toe, shoulder). | 3 |
| `BloomComponent`, `BloomOptionsComponent` | 27 | Bloom post effect (scope, strength, threshold, radius). | 6 |
| `PointLightComponent.SurroundingsLight`, `SpotLightComponent.SurroundingsLight` | visionOS only | Lights that also light the passthrough surroundings. | — |

## 4. Cameras

| Component | iOS | Purpose and observed defaults | Round |
|---|---|---|---|
| `PerspectiveCameraComponent` | 13 | Pinhole camera looking down −Z. Defaults **near 0.01, far ∞, fieldOfViewInDegrees 60, fieldOfViewOrientation .vertical** **[rv-ecs]**. A `PerspectiveCamera` entity in the scene becomes the view's camera in `RealityView` and non-AR `ARView` (**[rv-basic]**: the content's centre ray started at our camera's position). | 2 |
| `OrthographicCameraComponent` | 18 | Orthographic camera: defaults **near 0.01, far 1000, scale 1** (`scaleDirection` picks the axis). | 2 |
| `ProjectiveTransformCameraComponent` | 18 | Camera with an arbitrary projection matrix. | 2 |

## 5. Physics

| Component | iOS | Purpose and observed defaults | Round |
|---|---|---|---|
| `CollisionComponent` | 13 | Collision shapes (`ShapeResource` list), `mode` (`.default`/`.colliding`, `.trigger`), `filter` (group, mask), `collisionOptions` (static, full contact information, 18), `isStatic` (18). Needed for hit tests and ray casts as well as physics. | 4 |
| `PhysicsBodyComponent` | 13 | Rigid body: `mode` (static, kinematic, dynamic), `massProperties`, `material`, translation/rotation locks per axis, CCD, `isAffectedByGravity`, damping (18). Defaults: **dynamic, mass 1 kg, gravity on, linearDamping 0.02, angularDamping 0.05, CCD off** **[rv-ecs]**. | 4 |
| `PhysicsMotionComponent` | 13 | Linear and angular velocity of a body. Not present by default; reading `physicsMotion` on a body without it gave zero although the body moved **[rv-physics]**. | 4 |
| `PhysicsSimulationComponent` | 18 | Makes the entity the root of a separate simulation: `gravity` default **(0, −9.81, 0)**, `solverIterations` default **6 position / 1 velocity**, `collisionOptions` (report kinematic-vs-static/kinematic contacts), `clock`. | 4 |
| `PhysicsJointsComponent` | 18 | The joints of a simulation (`04-physics.md` §4). | 4 |
| `ForceEffectComponent` | 18 | Force fields (constant, radial, vortex, drag, turbulence, custom) with spatial/timed falloff. | 5 |
| `CharacterControllerComponent` | 15 | Capsule character mover: defaults **radius 0.25, height 2.0, skinWidth 0.01, slopeLimit π/4 (0.785398), stepLimit 0.2, upVector +Y** **[rv-ecs]**. | 5 |
| `CharacterControllerStateComponent` | 15 | Output of the character controller (velocity, on-ground). | 5 |
| `NavigationMeshComponent`, `NavigationComponent` | 27 | Navigation meshes and agents (path finding with `NavigationController`). | 6 |

## 6. Animation

| Component | iOS | Purpose | Round |
|---|---|---|---|
| `AnimationLibraryComponent` | 18 | Named `AnimationResource`s of an entity; default animation; auto-play (27). Present on every non-mesh entity loaded from USD **[rv-usd]**. | 4 |
| `SkeletalPosesComponent` | 18 | Named skeletal poses (joint names and transforms); present on skinned meshes from USD. | 4 |
| `BlendShapeWeightsComponent` | 18 | Blend-shape weight sets for a mesh (`BlendShapeWeightsMapping`). | 4 |
| `IKComponent` | 18 | Inverse-kinematics solvers from an `IKResource` (rig of joints and constraints). | 6 |
| `AnimationGraphComponent` | 27 | Runs an animation graph (`AnimationGraphResource`): state machines, clips, tags. | 6 |
| `BehaviorTreeComponent` | 27 | Runs a behaviour tree (`BehaviorTreeResource`) built from entity actions. | 6 |

## 7. Audio

| Component | iOS | Purpose | Round |
|---|---|---|---|
| `SpatialAudioComponent` | 18 | Positional audio source: `gain` (dB), `directLevel`, `reverbLevel`, `directivity` (beam), `distanceAttenuation` (rolloff). | 5 |
| `AmbientAudioComponent` | 18 | Head-locked but orientation-aware ambient source (`gain`). | 5 |
| `ChannelAudioComponent` | 18 | Plays channels directly to the output (no spatialisation). | 5 |
| `AudioLibraryComponent` | 18 | Named `AudioResource`s of an entity. | 5 |
| `AudioMixGroupsComponent` | 18 | Mix groups (gain, speed, mute, fades) that playback controllers belong to. | 5 |
| `ReverbComponent` | 18 | Reverb preset or (27) simulated reverb from a `ReverbMeshResource` with acoustic materials. | 6 |

## 8. Anchoring, input, interaction

| Component | iOS | Purpose | Round |
|---|---|---|---|
| `AnchoringComponent` | 13 | What the entity is anchored to: world transform, plane (alignment, classification, minimum bounds), image, object, face, body, camera; tracking mode `.once`/`.continuous` (18), separate physics simulation per anchor (18). `06-views-anchoring-input.md` §4. | 2 (world, camera), 8 (AR targets) |
| `ARKitAnchorComponent` | 26 | Read-only access to the `ARAnchor` behind an anchor entity (transient). | 8 |
| `SceneUnderstandingComponent` | 13.4 | Marks entities created from the reconstructed real-world mesh. | 8 |
| `BodyTrackingComponent` | 13 (not visionOS) | Drives a `BodyTrackedEntity` from ARKit body tracking. | 8 |
| `InputTargetComponent` | 18 | Makes the entity receive SwiftUI gestures (direct, indirect). Needs a `CollisionComponent`. | 5 |
| `GestureComponent` | 26 (init on iOS 26) | Attaches a SwiftUI gesture to an entity. | 5 |
| `ManipulationComponent` | visionOS only | System drag/rotate/scale manipulation. | — |

## 9. Compute and USD bridges (iOS 27)

| Component | Purpose | Round |
|---|---|---|
| `ComputeGraphComponent` and its runtime/output/viewpoint companions | Runs a GPU compute graph (Reality Composer Pro) that can output meshes and materials | 6+ |
| `USDStageComponent` | Renders a USDKit stage directly (time code, hit testing) | 6 |

## 10. Rules common to all built-in components

1. Value semantics, at most one per type per entity (`01-architecture.md` §2.2).
2. Components that reference resources (`ModelComponent`,
   `CollisionComponent`, audio and animation libraries) hold the resource
   by reference; resources are immutable after creation except through
   their explicit `replace` APIs (`MeshResource.replace(with:)`,
   `TextureResource.replace(withImage:…)`, `LowLevelMesh` buffers).
3. Lights and cameras orient along the entity's −Z.
4. Many components are `Codable` (light shadows, particle emitters, audio
   components, `Transform` from 18). The encoding is not specified publicly;
   Ycode defines its own if needed.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Component names, nesting, availability | 4 | SDK `.swiftinterface` (names only) |
| Purposes | 1 | developer.apple.com symbol pages and topic overviews (paraphrased) |
| Light, camera, physics, character defaults | 3 | **[rv-ecs]** |
| Components present after USD load | 3 | **[rv-usd]** |
| `PhysicsMotionComponent` absent by default | 3 | **[rv-physics]** |
