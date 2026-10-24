# RealityKit 4: physics — collisions, bodies, simulation, joints, forces, queries

Status: draft round 0. Sources: SDK module metadata (level 4),
documentation (level 1), probe runs (level 3, **[rv-physics]**,
**[rv-ecs]**, **[arview-nonar]**).

## 1. Collision shapes (`ShapeResource`)

- Generators (iOS 13): `generateBox(size:)` / `(width:height:depth:)`,
  `generateSphere(radius:)`, `generateCapsule(height:radius:)` (height
  along Y), `generateConvex(from:)` (point cloud or mesh → convex hull);
  iOS 18: `generateStaticMesh(positions:faceIndices:)` and
  `generateStaticMesh(from: MeshResource)` (triangle meshes, static bodies
  only; async; `ShapeResourceError.staticMeshGenerationFailed`,
  `.convexPolyhedronGenerationFailed`).
- `offsetBy(rotation:translation:)` returns a shifted copy; `bounds`.
- `Entity.generateCollisionShapes(recursive:static:)` builds shapes from the
  entity's model bounds/geometry and installs a `CollisionComponent`
  (**[arview-nonar]**: after calling it on our scene a hit test at the
  view centre returned the sphere and then the floor).

## 2. Collision component and filtering

- `CollisionComponent(shapes:mode:filter:)`; iOS 18 adds
  `collisionOptions` (`static`, `fullContactInformation`) and `isStatic`.
- `mode`: `.default` / `.colliding` (participates in contacts),
  `.trigger` (reports overlap, no response).
- `CollisionFilter(group:mask:)`: two entities collide when each one's
  group intersects the other's mask. `CollisionFilter.default` is group 1
  (`CollisionGroup.default`), mask all bits; `.sensor` is group all, mask
  all **[rv-ecs]**. `CollisionGroup.sceneUnderstanding` is the group of the
  reconstructed real-world mesh (13.4).
- A `CollisionComponent` is required for hit tests, ray casts, gestures
  (`InputTargetComponent`) and physics.

## 3. Rigid bodies

- `PhysicsBodyComponent`: `mode` (`PhysicsBodyMode` `.static`,
  `.kinematic`, `.dynamic`), `massProperties` (`mass`, `inertia` as the
  diagonal of the inertia tensor, `centerOfMass` position and orientation),
  `material` (`PhysicsMaterialResource` with static/dynamic friction and
  restitution; `.default`), per-axis translation and rotation locks,
  continuous collision detection, `isAffectedByGravity`, `linearDamping`,
  `angularDamping` (18). Defaults in `02-components.md` §5.
- Mass from shapes: `init(shapes:density:…)` computes mass and inertia
  from the shape volume. Observed **[rv-physics]**: 0.1 m box at density
  1000 → mass **1.0 kg**, inertia **(0.001667, 0.001667, 0.001667)**
  (= m·(a²+b²)/12, the solid-box formula). `init(shapes:mass:…)` sets the
  mass and derives inertia. A default `PhysicsBodyComponent()` has mass 1.
- `PhysicsMotionComponent` holds linear and angular velocity; the
  simulation updates it **only if the entity has one** (§8).
- `HasPhysicsBody` API: `addForce(_:relativeTo:)`, `addForce(_:at:…)`,
  `addTorque`, `clearForcesAndTorques()`, `applyLinearImpulse`,
  `applyAngularImpulse`, `applyImpulse(_:at:…)`, `resetPhysicsTransform`.
  Observed: impulse (1,0,0) N·s on a 2 kg body → velocity 0.498 m/s after
  0.2 s (0.5 reduced by linear damping 0.02), displacement 0.0998 m.
- Kinematic bodies follow their transform and push dynamic bodies;
  static bodies never move. Moving a dynamic body's transform teleports it.

## 4. Joints and pins (iOS 18)

`GeometricPin`s (named points on an entity, optionally on a skeletal
joint) are the joint endpoints. Joint types, all with `pin0`, `pin1`,
`checksForInternalCollisions`, `isActive`, `addToSimulation()`:

| Joint | Parameters |
|---|---|
| `PhysicsFixedJoint` | — |
| `PhysicsSphericalJoint` | `angularLimitInYZ` (cone) |
| `PhysicsRevoluteJoint` | `angularLimit` (about X) |
| `PhysicsPrismaticJoint` | `linearLimit` (along X) |
| `PhysicsDistanceJoint` | `distanceLimit`, `tolerance` |
| `PhysicsCustomJoint` | per-axis `MotionLimit` (`fixed`, `unlimited`, `range`) for linear X/Y/Z and angular X/Y/Z |

`PhysicsJointsComponent` (on the simulation root) holds the active joints
as a `PhysicsJoints` collection. The axis conventions (joint frame = pin
frame, X as the hinge/slide axis) follow the parameter names; they are to
be confirmed by a probe in round 4.

## 5. Simulation roots and stepping

- `PhysicsSimulationComponent` on an entity creates a separate simulation
  for its subtree; `nearestSimulationEntity(for:)` finds the root that
  simulates an entity. With no explicit root a scene still simulates: in
  `RealityView` the nearest simulation entity of our bodies was an
  **unnamed entity above our content root** **[rv-physics]**, i.e. the view
  inserts its own root with a simulation. `ARView.physicsOrigin` (and
  `AnchorEntity(…, physicsSimulation:)`, 18) choose the frame in which
  physics is computed; scaling that origin by 1/k simulates the content as
  if k times larger (documentation; used for objects under 1 cm³).
- Parameters: `gravity` (default (0, −9.81, 0)), `solverIterations`
  (default 6 position, 1 velocity), `collisionOptions`
  (`reportKinematicVsStatic`, `reportKinematicVsKinematic`), `clock`.
- **Fixed time step 1/60 s** (`WillSimulate.deltaTime` =
  0.016666668 every step; 192 steps in 3.2 s of simulated time)
  **[rv-physics]**.
- Integrator: positions match semi-implicit (symplectic) Euler — velocity
  updated first, then position — with gravity 9.81: after 15 steps a body
  released at y = 1.0 was at 0.6736 (semi-implicit Euler predicts 0.6730
  before damping; the continuous solution is 0.6934). After one step:
  0.9973 (= 1 − 9.81/3600). Conformance tests must use this integrator
  to match trajectories to 3 decimals.
- Contact restitution: a ball (restitution 0.8) dropped from 0.95 m onto a
  floor (restitution 0) rebounded to 0.172 m above its rest height, an
  effective restitution of ≈ 0.43 — consistent with the **average** of the
  two materials (0.4), not the maximum or the product **[rv-physics]**.
  Friction combination is presumably the same (open).
- Bodies resting on a floor settle to the exact contact height (cube
  half-extent 0.05 above the floor top, orientation unchanged).

## 6. Events

- `CollisionEvents.Began` (entityA, entityB, position, impulse; iOS 18:
  penetration distance, impulse direction, `contacts` — `Contact` with
  point, normal, impulse, impulse direction, penetration), `Updated`,
  `Ended` (entityA, entityB).
- **Delivery**: a scene-wide subscription receives every `Began` **twice**,
  once with each participant as `entityA` (pairs (kick, floor) and
  (floor, kick) at the same time). A subscription filtered on one entity
  (`on: ball`) received one event per contact begin **[rv-physics]**.
  So events are posted per participating entity (event source).
- Bodies that start in contact produce `Began` in the first step with
  impulse 0.
- `contacts` was empty without `CollisionComponent.CollisionOptions
  .fullContactInformation`.
- `PhysicsSimulationEvents.WillSimulate` / `DidSimulate` (deltaTime,
  simulation root entity) bracket each fixed step.
- Triggers report `Began`/`Ended` for overlaps without response.

## 7. Queries

- `Scene.raycast(origin:direction:length:query:mask:relativeTo:)` and
  `raycast(from:to:…)`; `query` `.nearest`, `.all`, `.any`
  (`CollisionCastQueryType`); `mask` is a `CollisionGroup`. Results:
  `CollisionCastHit` (entity, position, normal, distance; iOS 18 triangle
  hit with face index and barycentric UV, shape index).
  Observed: ray from (−0.3, 2, 0) down → `.all` returned the cube top at
  distance 1.9 then the floor at 2.0, **sorted by distance**; `.nearest`
  returned only the cube **[rv-physics]**.
- `convexCast(convexShape:fromPosition:fromOrientation:toPosition:
  toOrientation:query:mask:relativeTo:)` sweeps a shape.
- `ARView.hitTest(_:query:mask:)`, `entity(at:)`, `entities(at:)` and
  `RealityViewCameraContent.hitTest/entity(at:)` cast from a screen
  point through collision shapes (nearest first).
- `Scene.pixelCast` (iOS 18) picks by rendered pixels (`PixelCastHit` with
  mesh part, instance, primitive, barycentrics) — no collision shape needed.

## 8. Character controller (iOS 15)

`CharacterControllerComponent` (capsule: radius, height, skin width,
slope limit, step limit, up vector, collision filter; defaults in
`02-components.md`), moved with `Entity.moveCharacter(by:deltaTime:
relativeTo:collisionHandler:)` (sweeps and slides, reports
`CharacterControllerComponent.Collision` with hit entity, position,
normal, move direction and distance) and `teleportCharacter(to:)`.
`CharacterControllerStateComponent` reports velocity and on-ground.
`CollisionFlags`: side, top, bottom.

## 9. Force effects (iOS 18)

`ForceEffectComponent` holds `ForceEffect`s, each wrapping a
`ForceEffectProtocol` value with strength scale, position, orientation,
collision mask, spatial falloff (`SpatialForceFalloff`: bounds sphere,
rate, distance offset) and timed falloff (duration, rate). Built-in
effects: `ConstantForceEffect` (strength, direction),
`ConstantRadialForceEffect`, `RadialForceEffect` (rest distance),
`VortexForceEffect` (axis), `DragForceEffect`, `TurbulenceForceEffect`
(smoothness, speed). Custom effects implement `update(parameters:)`
over `ForceEffectParameters` (per-body positions, orientations,
velocities, angular velocities, distances, masses, inertia; output
`setForce`/`setTorque`) and declare `parameterTypes` and a `ForceMode`
(`force`, `acceleration`, `impulse`, `velocity`).

## 10. Navigation (iOS 27)

`NavigationMeshResource` builds a navigation mesh from triangles, a
`MeshDescriptor` or a mesh, with a `Configuration` whose fields are the
classic voxel-based navmesh parameters — cell size and height, walkable
slope angle, character height, radius and climb, maximum edge length and
simplification error, minimum region size, region merge size, detail
sample distance and error, maximum vertices per polygon, and a partition
method `watershed`/`monotone`/`layer` — plus off-mesh connections, area
and flag marking (cylinders, boxes, polygons), layers and height data.
`NavigationMeshComponent` and `NavigationComponent` (layer, filter with
area costs and include/exclude flags) attach meshes and agents;
`NavigationController` computes or requests paths (`PathfindStatus`). This
parameter set is that of the open-source Recast/Detour library
(`09-open-design.md` §3.2), which makes it a natural implementation.

## 11. Not on iOS in the 27.1 SDK

Cloth simulation (`ClothSimulationComponent`, `ClothBodyComponent`, cloth
colliders, shapes, events, `ClothMeshResource`) is documented on
developer.apple.com and presented at WWDC26 ("Explore advances in
RealityKit", session 279) but is not in the installed iOS 27.1 or
visionOS 27.0 SDKs. It is listed for a later round.

## Evidence

| Claim | Level | Source |
|---|---|---|
| API names | 4 | SDK `.swiftinterface` |
| Physics-origin scaling for small objects | 1 | developer.apple.com "Handling different-sized objects in physics simulations" |
| Mass, inertia, impulse response, fixed step, integrator, restitution combination, resting height | 3 | **[rv-physics]** |
| Event duplication per participant, filtered subscription | 3 | **[rv-physics]** round 2 |
| Ray-cast ordering, nearest | 3 | **[rv-physics]** |
| Implicit simulation root in `RealityView` | 3 | **[rv-physics]** |
| Collision-filter defaults | 3 | **[rv-ecs]** |
| Cloth simulation documented but absent | 1, 4 | developer.apple.com "Cloth simulation"; WWDC26 session 279 page; grep of both SDKs |
| Navigation-mesh parameter set equals Recast's | 4, 1 | SDK names; Recast public repository (zlib) |
