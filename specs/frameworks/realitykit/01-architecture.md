# RealityKit 1: architecture — modules, entities, components, systems, scenes, events

Status: draft round 0. Sources: SDK module metadata (level 4), public
documentation (level 1), probe runs on the iOS 27.1 simulator (level 3,
modes **[rv-ecs]**, **[rv-basic]**).

## 1. Modules

The SDK splits the framework into several Swift modules. An app imports
`RealityKit`; the others are re-exported or loaded as cross-import overlays.

| Module | Role | Notes for an implementation |
|---|---|---|
| `RealityFoundation` | Platform-neutral core: `Entity`, `Scene`, every component, resources (`MeshResource`, `TextureResource`, `MaterialParameters`, `AnimationResource`, audio resources, `ShapeResource`, …), materials, physics, animation, audio, events, systems, `RealityRenderer`, `LowLevelMesh`/`LowLevelTexture`/`LowLevelBuffer` | Most types carry `@_originallyDefinedIn(module: "RealityKit", …)` metadata: they were moved out of `RealityKit` in the iOS 15 era. Our implementation exposes them under the module name `RealityKit` (and may also offer `RealityFoundation`). |
| `RealityKit` | Umbrella. Re-exports `RealityFoundation` and adds the UIKit-bound pieces: `ARView` and its option types, entity gesture recognizers, `UIColor`/`UIFont` conveniences (`SimpleMaterial(color:roughness:isMetallic:)`, light colours, `MeshResource.generateText`), `MultipeerConnectivityService`, `ParticleEmitterComponent.Presets`, accessibility events | On Linux these need a UIKit-like layer; see `09-open-design.md` §6. |
| `_RealityKit_SwiftUI` | Cross-import overlay of RealityKit + SwiftUI: `RealityView`, `RealityViewCameraContent`, `RealityViewContentProtocol`, `EntityTargetValue` and gesture targeting, `Model3D` (visionOS), Object Capture views, `Entity.animate` | Loaded only when both modules are imported. |
| `_RealityKit_ComputeGraph` (iOS 27) | `ComputeGraphComponent` and resources for GPU compute graphs authored in Reality Composer Pro | Out of scope until round 6. |
| `USDKit` (iOS 27) | A Swift API over USD layers, stages, prims, attributes, paths, values | New in 27; a separate spec (`07-assets.md` §3) |
| `_USDKit_RealityKit` (iOS 27) | `USDStageComponent`, `USDPlayer` (frame-update stream of meshes/materials/textures/deformations), `USDRenderError` | Bridges USDKit to rendering. |
| Metal headers in `RealityKit.framework/Headers` | The shading-language API for custom materials: namespace `realitykit`, `surface_parameters`, `geometry_parameters` | `03-rendering.md` §2.6 |
| `ShaderGraph` (documentation framework) | Node catalogue for Reality Composer Pro materials, MaterialX 1.38 based | `03-rendering.md` §2.5 |

Size of the public surface (iOS 27.1 SDK, our inventory, level 4): about
860 public types and extensions across the RealityKit modules. The full
name list is `api-inventory.md`.

## 2. The entity–component–system model

### 2.1 Entity

An `Entity` is a reference-type node with identity. Properties and
behaviour:

- `id`: a 64-bit unsigned integer, unique per entity. The values are not
  sequential (two consecutive `Entity()` calls gave unrelated 64-bit values
  **[rv-ecs]**). An implementation may use any unique scheme; tests must not
  depend on values.
- `name`: string, empty by default; `findEntity(named:)` searches the
  descendants (depth-first) for the first match. `Scene.findEntity(named:)`
  and `Scene.findEntity(id:)` search a whole scene.
- Hierarchy (`HasHierarchy`): `parent`, `children` (an ordered collection
  with append/insert/remove/replaceAll, each with a "preserve world
  transform" option), `setParent(_:preservingWorldTransform:)`,
  `addChild`, `removeChild`, `removeFromParent`. An entity has at most one
  parent; adding it elsewhere moves it.
- State flags: `isEnabled` (own flag), `isEnabledInHierarchy` (own and all
  ancestors), `isActive` (enabled in hierarchy *and* part of a scene),
  `isAnchored` (its anchoring ancestor is currently tracked).
- `scene`: the scene the entity is in, or nil. `anchor`: nearest anchoring
  ancestor.
- `components`: the component set (§2.2).
- `clone(recursive:)`: copies the entity (and optionally its subtree) with
  new identities and copies of all components **[rv-ecs]**; the subclass
  hook `didClone(from:)` runs on the copy.
- Loading: `Entity(named:in:)`, `Entity(contentsOf:withName:)`,
  `Entity(from:configurations:)` and the older synchronous `load…`
  functions; see `07-assets.md`. `write(to:)` (iOS 18) exports.
- Observation (iOS 26): `Entity.observable` exposes name, enabled state,
  children, transform parts and components to Swift Observation.

Built-in entity subclasses only pre-install components. Observed default
component sets **[rv-ecs]**:

| Class | Components after `init()` |
|---|---|
| `Entity` | `Transform`, `SynchronizationComponent` |
| `ModelEntity` | `Transform`, `SynchronizationComponent` (plus `ModelComponent` when created with a mesh; plus `CollisionComponent`/`PhysicsBodyComponent` via the collision-shape initialisers) |
| `AnchorEntity` (any target) | `Transform`, `SynchronizationComponent`, `AnchoringComponent` |
| `PerspectiveCamera` | + `PerspectiveCameraComponent` |
| `DirectionalLight` | + `DirectionalLightComponent` (shadow is a separate component, `DirectionalLightComponent.Shadow`, absent by default) |
| `PointLight` | + `PointLightComponent` |
| `SpotLight` | + `SpotLightComponent` |
| `TriggerVolume` | + `CollisionComponent` (trigger mode) |

The `Has…` protocols (`HasModel`, `HasPhysicsBody`, `HasCollision`,
`HasAnchoring`, `HasDirectionalLight`, …) are typed views: each property
reads or writes one component in the entity's set (for example
`ModelEntity.model` is `components[ModelComponent.self]`). They add no
state.

### 2.2 Components

- A component is a value type conforming to `Component`. An entity holds
  **at most one component per concrete type**. `components.set(c)` inserts
  or replaces; `components[T.self]` returns a copy; `remove(T.self)`,
  `removeAll()`, `has(T.self)`, `count`, iteration (iOS 18:
  `ComponentSet` is a collection).
- Mutation is copy–modify–set. Changing a returned copy does nothing until
  it is set back; a set of an existing type posts `ComponentEvents.DidChange`
  (§4.2).
- Custom components: any struct conforming to `Component`.
  `registerComponent()` registers the type (needed before the type is
  decoded from files or used by Reality Composer Pro); our probe called it
  at app start.
- `TransientComponent` (iOS 15): marker for components that are not copied
  by `clone` and not serialized (documentation, level 1; not yet probed).
- Components that are "implicitly animatable built-ins" (iOS 26) can be
  animated by `Entity.animate` (`05-animation-audio.md` §6).
- iOS 27 adds `Entity.ComponentSet.set(qualifiedComponentName:representation:)`
  (setting a component from a serialized form by name).

### 2.3 Systems

- A system is a type conforming to `System` with `init(scene:)` and
  `update(context:)`, optional static `dependencies`.
- `registerSystem()` is called once per type, before the scene is shown
  (documentation). After registration the framework creates **one
  instance per scene**.
- Observed creation order **[rv-ecs]**: all registered systems were
  instantiated when the scene first appeared, before the first update, in
  dependency order (see next point).
- Observed update order: with A, B `.after(A)`, C `.before(A)`, every frame
  ran C, A, B. Dependencies are constraints; the order among unconstrained
  systems is unspecified (documentation does not define it). An
  implementation must produce a topological order and should be stable
  (registration order as tie-break).
- `SceneUpdateContext`: `scene`, `deltaTime` (seconds since the previous
  update), `entities(matching:updatingSystemWhen:)` returning the entities
  matching an `EntityQuery`. The only public `SystemUpdateCondition` is
  `.rendering`.
- Observed per-frame sequence **[rv-ecs]**: `SceneEvents.Update` handlers
  run first, then the systems in dependency order. Built-in work
  (physics, animation) happens around this; `PhysicsSimulationEvents`
  bracket each physics step (`04-physics.md` §6).
- Systems run on the main actor (the probe's systems ran synchronously with
  main-thread event handlers; the SDK marks the APIs `@MainActor`).

### 2.4 Queries

`EntityQuery(where: QueryPredicate)`; predicates are `.has(T.self)`
combined with `&&` and `||`. `Scene.performQuery(_:)` and
`SceneUpdateContext.entities(matching:…)` return the matching entities of
the scene (active entities; our probe's query for `ModelComponent`
returned exactly the model entities in the scene **[rv-ecs]**).

## 3. Scene

- A `Scene` owns a forest of root entities. In `ARView` the roots are
  anchors (`scene.anchors`, `addAnchor`, `removeAnchor`). In `RealityView`
  the content's `entities` collection holds the roots and adding an entity
  places it in the view's scene (**[rv-basic]**: an entity added to the
  content immediately had a non-nil `scene` and `isAnchored == true`).
- Services: event subscription (§4), `raycast`/`convexCast` (physics
  queries, `04-physics.md` §7), `pixelCast` (iOS 18, render-based picking),
  `performQuery`, `synchronizationService` (§6.6 of
  `06-views-anchoring-input.md`), `timebase` (iOS 18), `commandQueue`
  (iOS 27, Metal command queue used by the scene).

## 4. Events

### 4.1 Subscription

`Scene.subscribe(to:on:_:)` (optionally filtered by a source entity and
by component type) returns a cancellable token; `publisher(for:on:)` gives
a Combine publisher. `RealityViewContent.subscribe` and
`RealityRenderer.subscribe` are the same for their scenes. Handlers run on
the main actor. Dropping the token cancels.

Event families (all `Event` structs):

| Family | Events |
|---|---|
| `SceneEvents` | `Update` (scene, deltaTime), `AnchoredStateChanged`, `DidAddEntity`, `DidActivateEntity`, `WillDeactivateEntity`, `WillRemoveEntity`, `DidReparentEntity` (child, previousParent) |
| `ComponentEvents` | `DidAdd`, `DidActivate`, `DidChange`, `WillDeactivate`, `WillRemove` (entity, componentType) |
| `CollisionEvents` | `Began`, `Updated`, `Ended` (`04-physics.md` §6) |
| `PhysicsSimulationEvents` | `WillSimulate`, `DidSimulate` |
| `AnimationEvents` | `PlaybackStarted`, `PlaybackCompleted`, `PlaybackLooped`, `PlaybackTerminated`, `SkeletalPoseUpdateComplete`, `RootMotionDidUpdate` (27) |
| `AudioEvents` | `PlaybackCompleted`, `PlaybackGroupCompleted` (27) |
| `AnchorStateEvents` (26) | `DidAnchor`, `WillUnanchor`, `DidFailToAnchor` with reasons |
| `SynchronizationEvents` | `OwnershipRequest`, `OwnershipChanged` |
| `AccessibilityEvents` | `Activate`, `Increment`, `Decrement`, `CustomAction`, `RotorNavigation` |
| `VideoPlayerEvents` | content type, viewing mode, size, rendering status changes |
| visionOS only | `ManipulationEvents`, `ImagePresentationEvents`, tracking-state update |

### 4.2 Lifecycle event order (observed **[rv-ecs]**)

Events are delivered **synchronously, inside the mutating call** (the
trace shows them between our "operation" markers in the same frame).
Mutations of an entity that is not in a scene post nothing.

1. `scene.addChild(e)` where `e` has Transform, Synchronization and a
   custom component P:
   `DidAddEntity(e)`, `DidActivateEntity(e)`, then `ComponentEvents.DidAdd`
   for each component in insertion order (Transform,
   SynchronizationComponent, P), then `DidActivate` for each in the same
   order.
2. `components.set(P)` when P exists: `DidChange(P)` only.
3. `components.set(Q)` when Q is new on an active entity:
   `DidAdd(Q)`, `DidActivate(Q)`, `DidChange(Q)`.
4. A system that sets P every frame causes one `DidChange(P)` per frame.
5. `isEnabled = false`: `WillDeactivateEntity(e)` first, then
   `WillDeactivate` for each component in order.
   `isEnabled = true`: `DidActivate` for each component, then
   `DidActivateEntity(e)` (mirror order).
6. `components.remove(Q)`: `WillDeactivate(Q)`, `WillRemove(Q)`.
7. Moving `e` under another entity already in the scene: only
   `DidReparentEntity(e)`; no remove/add pair.
8. Removing a subtree root `r` with child `e`: children first, then the
   parent (post-order). For each entity: `WillDeactivate` for each
   component, `WillRemove` for each component, then
   `WillDeactivateEntity`, then `WillRemoveEntity`.

The first `SceneEvents.Update` came after all of the above for the frame
in which the scene was created; its `deltaTime` was about 0.03 s.

## 5. Transforms and coordinate conventions

- **Units and axes**: metres; right-handed; +Y up; a camera and the
  default "forward" of `look(at:)` face −Z (documentation states Y-up and
  metres, level 1; the −Z forward and right-handedness are observed
  below).
- `Transform`: `scale` (SIMD3), `rotation` (unit quaternion,
  `simd_quatf`), `translation`; `matrix` composes T·R·S (a point is scaled,
  then rotated, then translated). `Transform(pitch:yaw:roll:)` uses
  radians: pitch about X, yaw about Y, roll about Z (pitch π/2 gave the
  quaternion (0.7071, 0, 0, 0.7071) in (x, y, z, w) order, a positive
  right-handed rotation about +X) **[rv-ecs]**.
- World transform = parent world × local. Observed: parent at (1,0,0),
  yaw +90°, uniform scale 2; child local (0,0,−1) → world (−1,0,0).
- `HasTransform` API: `position/orientation/scale/transform` (local),
  `position(relativeTo:)`, `setPosition(_:relativeTo:)` and the same for
  orientation, scale and the full matrix, where `relativeTo: nil` means
  world space. `convert(position:/direction:/normal:/transform:, from:/to:)`.
  Observed: `convert(direction:to: nil)` applies rotation **and scale** (no
  translation): (0,0,−1) under the parent above → (−2,0,0).
- `look(at:from:upVector:relativeTo:)` sets position and orientation so
  that the entity's −Z points at the target (target straight ahead on −Z
  gives the identity rotation; target on +X gives yaw −90°). The iOS 18
  overload with `forward: .positiveZ` points +Z at the target instead.
- `move(to:relativeTo:duration:timingFunction:)` animates the transform
  (`05-animation-audio.md`).
- `visualBounds(recursive:relativeTo:excludeInactive:)`: axis-aligned
  bounds of the rendered meshes in the given space, including scale
  (box of 0.2 m, scale (2,1,1), at y=1 → x ±0.2, y 0.9…1.1, z ±0.1).
- `BoundingBox`: min/max, center, extents, union, contains, intersects,
  transformed(by:).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Module split, symbol names, availability, `@_originallyDefinedIn` | 4 | `.swiftinterface` files of the iPhoneSimulator 27.1 SDK, read by our inventory script (names only) |
| Systems: registration before display, one instance per scene, dependencies | 1 | developer.apple.com "Implementing systems for entities in a scene" |
| Default component sets of entity classes (§2.1) | 3 | **[rv-ecs]** |
| System creation and update order, update/event interleaving (§2.3) | 3 | **[rv-ecs]** |
| Event order (§4.2) | 3 | **[rv-ecs]** trace, `results/rv-ecs.log` |
| Y-up, metres | 1 | developer.apple.com USD article "Creating USD files for Apple devices" |
| Transform composition, `look(at:)`, convert, visualBounds numbers | 3 | **[rv-ecs]** |
| `TransientComponent` semantics | 1 | symbol documentation; not yet probed |
