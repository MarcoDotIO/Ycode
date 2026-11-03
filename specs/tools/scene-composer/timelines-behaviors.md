# Scene composer 4: timelines, behaviors and animation libraries

Status: draft, OBS-RCP round (2026-10-29). Reference: the USDA that Reality
Composer Pro 1–2 wrote ("RCP2 format", still compiled by Xcode 27.1's
`realitytool` and still read by RealityKit), checked against RealityKit on
macOS 27 and `realitytool compile` with our own hand-written files under
`<samples>/timelines/`. Reality Composer Pro 3 keeps its own project format
(see `project-format.md`); this file is about the USD form that the build
and the runtime read.

**Generation note (owner correction, OBS-RCP4).** The timelines, actions
and `Preliminary_*` behaviors of §1–§5 are the RCP 1/2 ("legacy content
package") model. Reality Composer Pro 3 does not author timelines:
animation and logic are **state-machine node graphs**, stored as
*Animation Graph* and *Behavior Tree* assets (§7, and
`project-format.md` §4.7.7). RCP 3 only meets §1–§5 when it migrates or
imports legacy USD. Ycode keeps §1–§5 because its native format is the
legacy package, which Xcode still compiles.

Notation: "loaded as" means what RealityKit produced when our file was
loaded with `Entity(contentsOf:)` (direct USDA load) **and** after
`realitytool compile --platform xros --deployment-target 27.0` (the
`.reality` path). Unless a row says otherwise, both paths gave identical
results (we diffed the dumps).

## 1. Model

| Concept | USD storage | Runtime result |
|---|---|---|
| Timeline | `def RealityKitTimeline "<name>"` anywhere in the scene (RCP puts them under the root prim) | Two named animations in the `AnimationLibraryComponent` of the **default prim's entity**: `"<prim path>"` (an `AnimationGroup`) and `"<prim path>__auto_generated_looping"` (an `AnimationView` with `repeatMode = .repeat` around the same group). The timeline prim itself does not become an entity. |
| Track | `def RealityKitTrack "<name>"` child of a timeline | No runtime object of its own; its actions join the timeline's group. Tracks only order and group actions for the editor. |
| Action | `def RealityKitAction "<name>"` child of a track | One child of the timeline group: an `AnimationView` with `delay = startTime` and `duration = startTime + active duration`, whose source is an `ActionAnimation<…>` (§3). |
| Behavior | `def Preliminary_Behavior "<name>"` with `Preliminary_Trigger` and `Preliminary_Action` children (public AR schema, §4) | One interaction in the scene's interaction service (the legacy Reality Composer trigger/action runtime), registered when the entity joins a scene. |
| Behaviors list | `def RealityKitComponent "RCP_BehaviorsContainer"` with `uniform token info:id = "RCP.BehaviorsContainer"` and `rel behaviors = [<behavior prims>]` | **No runtime component.** Behaviors loaded identically with and without it; it is editor bookkeeping (which behaviors the inspector shows on this entity). Writers should emit it; readers must not require it. |
| Animation library | `def RealityKitComponent "AnimationLibrary"` (`info:id = "RealityKit.AnimationLibrary"`) with `RealityKitAnimationFile` / `RealityKitClipDefinition` children | Not reproduced by our samples (open question 1). Timelines and USD time samples reach `AnimationLibraryComponent` without it. |

Duration of a timeline = max over its actions of `startTime + duration`.
Instant actions (notification, enable, disable, impulse) get a minimum
active duration of 1/30 s whatever `duration` says.

## 2. Timeline grammar

```
def RealityKitTimeline "<TimelineName>"
{
    def RealityKitTrack "<TrackName>"
    {
        def RealityKitAction "<ActionName>"
        {
            string actionKind = "<kind>"          # §3; required
            uniform token info:id = "<UUID>"      # RCP writes a fresh upper-case UUID per action
            double startTime = <seconds>          # offset in the timeline; default 0
            double duration = <seconds>           # active duration
            rel target = </path/to/entity/prim>   # entity the action drives
            int blendLayer = <n>                  # optional; default 0 (sets the animation's blend layer)
            def RealityKitStruct "timingFunction" # optional; §2.1
            {
                token type = "<easing>"
                float2 controlPoint1 = (x, y)     # cubicBezier only
                float2 controlPoint2 = (x, y)
            }
            # kind-specific attributes (§3)
        }
    }
}
```

`actionKind` is a `string` (not a token) in RCP's files; a `token` was not
tested. An action whose kind is unknown, or whose required reference is
missing (orbit without pivot, audio without a resolvable resource,
timeline without `timeline`), is dropped silently and contributes nothing
(timeline duration 0 if it was the only action).

### 2.1 Timing functions (verified)

| `type` | Resulting easing |
|---|---|
| absent (no struct) | cubic Bézier (0.25, 0.1, 0.25, 1.0) — the CSS "ease" curve |
| `"linear"` | linear |
| `"easeIn"` | cubic Bézier (0.42, 0, 1, 1) |
| `"easeOut"` | cubic Bézier (0, 0, 0.58, 1) |
| `"easeInOut"` | cubic Bézier (0.42, 0, 0.58, 1) |
| `"cubicBezier"` | cubic Bézier (controlPoint1.x, controlPoint1.y, controlPoint2.x, controlPoint2.y) |

## 3. Action kinds (verified unless marked)

All action animations are bound to the target entity: transform-driving
kinds bind to `entity(<name>).transform`; opacity kinds bind to the
internal path `entities[<name>].HierarchicalFade.opacity` (the runtime name
of the opacity component); look-at binds to
`entities[<name>].Billboard.blendFactor`.

| `actionKind` | Kind-specific attributes (USD type) and defaults | Runtime action |
|---|---|---|
| `spin` | `float revolutions` (1); `token spinDirection` = `clockwise` (default) / `counterclockwise`; `float3 localAxis` ((0,1,0)) | `SpinAction(revolutions, localAxis, timingFunction, isAdditive: true)`. **Clockwise negates the axis**: default gives axis (0,−1,0); counterclockwise keeps the authored axis. |
| `orbit` | `rel pivotEntity` (required); `float revolutions`; `token orbitDirection` (`clockwise`/`counterclockwise`); `float3 axis`; `bool orientToPath` | `OrbitEntityAction(pivotEntity, revolutions, orbitalAxis, isOrientedToPath, isAdditive: true)`. Counterclockwise with axis (0,0,1) gave orbital axis (0,0,1); clockwise is expected to negate (not tested). |
| `emphasize` | `token motionType` = `pop` (default), `blink`, `bounce`, `flip`, `float`, `jiggle`, `pulse`, `spin`; `token style` = `basic` (default), `playful`, `wild` | `EmphasizeAction(motionType, style, isAdditive: true)` (`bounce`/`playful` verified; other case tokens are the public enum case names, unverified). |
| `moveTo` | `float3 position`, `quatf rotation` (USD order real, i, j, k), `float3 scale`; `token transformMode` (`parent`/`local`/`scene`/`relative` seen, no observable effect, open question 2); `rel referenceEntity` | `FromToByAction<Transform>(to: Transform(scale, rotation, translation))`; unspecified parts are identity (scale 1, rotation identity, translation 0). Mode reported `.scene`, `isAdditive: true`, `isReversible: true`. `transform` and `fromToBy` are **not** valid kind names. |
| `show` | `token transitionIn` (e.g. `scaleUp`; effect not observed) | `FromToByAction<Float>(to: 1)` on opacity. |
| `hide` | `token transitionOut` (e.g. `scaleDown`, `opacity`; effect not observed) | `FromToByAction<Float>(to: 0)` on opacity. |
| `enable` / `disable` | — | `SetEntityEnabledAction(isEnabled: true/false)`, 1/30 s. |
| `impulse` | `float3 impulse` ((0,1,0)) | `ImpulseAction(linearImpulse)`, 1/30 s. Needs a dynamic physics body at run time. |
| `lookAt` | `transitionIn`/`transitionOut` structs (not decoded) | `BillboardAction` with zero-length transitions. `lookAtCamera` is not a valid kind. |
| `audio` | `string audioResourceName` (key in the target's `AudioLibraryComponent`, normally the file name); `token controlPlayback` (`play` observed); `double gain` (dB) | `PlayAudioAction(audioResourceName, gain, useControlledPlayback: true)`, wrapped in a repeating view trimmed to `duration`. The audio file must be in the scene (a `RealityKitAudioFile` prim, `particles-audio.md` §4). |
| `notification` | `string notificationName` (required) | Internal `NotificationAction`, 1/30 s. At run time it posts `RealityKit.NotifyAction` (§5). |
| `animation` | `string animation` = key of an animation in the target's `AnimationLibraryComponent` (e.g. `default subtree animation` for a referenced USD with time samples); also seen: `transitionDuration`, `separateAnimatedValue`, `applyToAllLayers`, `handoffType`, `loopCount` | `PlayAnimationAction(animationName: "<key>__auto_generated_looping", transitionDuration 0, blendLayer 0, separateAnimatedValue false, handoffType default)` inside a repeating view trimmed to `duration`. A `rel animation` did **not** load. |
| `timeline` | `rel timeline = </path/to/RealityKitTimeline>` | `PlayAnimationAction(animationName: "<timeline path>__auto_generated_looping", separateAnimatedValue: true, handoffType: compose, useParentedControllers: true)` trimmed to `duration` and delayed by `startTime` — sub-timelines play the looping variant clipped to the action. |

Not valid kinds (dropped): `transform`, `fromToBy`, `playAudio`,
`playAnimation`, `playTimeline`, `setEntityEnabled`, `enableEntity`,
`disableEntity`, `lookAtCamera`, `billboard`, `wait`, `visibility`,
`setEntityProperty`. Level-4 names suggest extra kinds exist in the
builder (a "set entity property" action and a `selectedTimeline`
attribute); open question 3.

## 4. Behaviors (verified)

RCP2 stores each behavior as a `Preliminary_Behavior` prim **inside the
entity prim that owns it**, plus the `RCP_BehaviorsContainer` component
listing them. The prim and property names are Apple's public "OpenUSD
schemas for AR" (`Preliminary_Behavior`, `Preliminary_Trigger`,
`Preliminary_Action`).

```
def Preliminary_Behavior "OnTap"
{
    rel triggers = </Root/Box/OnTap/Trigger>
    rel actions  = </Root/Box/OnTap/Action>
    uniform bool exclusive                  # authored without a value by RCP
    def Preliminary_Trigger "Trigger"
    {
        token info:id = "TapGesture"        # §4.1
        rel affectedObjects = </Root/Box>
    }
    def Preliminary_Action "Action"
    {
        token info:id = "PlayTimeline"
        rel affectedObjects = </Root>        # entity whose animation library holds the timeline
        rel animationLibraryKey = </Root/MyTimeline>
        rel animationLibraryKeyOverrideKey = </Root/Box/OnTap/Trigger>
        int loops = 0
        int performCount = 1
        token type = "serial"                # serial | parallel
    }
}
```

### 4.1 Triggers

| `info:id` | Extra properties | Runtime trigger (verified) |
|---|---|---|
| `TapGesture` | — | tap trigger; the entity is listed in the service's tap targets. Needs `InputTarget` + `Collider` on the entity to fire in an app. |
| `SceneTransition` | `token type = "enter"` (the "On added to scene" behavior) | start trigger; the service invokes start triggers automatically when the scene starts. |
| `Collide` | `rel colliders = [<other entity prims>]` | collision trigger with the listed colliding entities. |
| `Notification` | `string identifier = "<name>"` | custom trigger with that identifier, fired by the app (§5). |
| `ProximityToCamera` | (public schema: `distance`) | name seen at level 4; not tested. |

### 4.2 Actions

RCP writes only `PlayTimeline` (properties above); it becomes a
play-timeline action on the `affectedObjects` entity with
`animationLibraryKey` = the timeline prim path (string form) and
`animationLibraryKeyOverrideKey` = the trigger prim path. The action group
defaults to sequenced with multiple-perform behavior `ignore`. Other
public `Preliminary_Action` ids appear in the reader (`Audio`,
`ChangeScene`, `Emphasize`, `Group`, `Impulse`, `LookAtCamera`,
`Notification`, `Orbit`, `Spin`, `StartAnimation`, `Transform`,
`Visibility`, `Wait`) — these are the iOS Reality Composer vocabulary; a
writer for RCP-compatible files need not produce them. Tokens
`multiplePerformOperation` = `allow`/`ignore`/`stop` exist in the reader;
setting them on the action did not change the group's reported behavior
(open question 4).

## 5. Notifications (app interface)

These names are the documented app-side contract (level 1, Apple sample
code and WWDC sessions) and appear verbatim in the runtime (level 4):

- **Trigger a `Notification` behavior** from app code: post
  `NotificationCenter` notification `RealityKit.NotificationTrigger` with
  user-info keys `RealityKit.NotificationTrigger.Scene` (the RealityKit
  scene), `RealityKit.NotificationTrigger.Identifier` (the trigger's
  `identifier`); optional `…SourceEntity`, `…CustomArguments`,
  `…Overrides`.
- **Receive a timeline `notification` action**: observe
  `RealityKit.NotifyAction`; user info `RealityKit.NotifyAction.Identifier`
  (`notificationName`), `RealityKit.NotifyAction.Entity` (target),
  `RealityKit.NotifyAction.Scene`, `RealityKit.NotifyAction.CustomArguments`.

An open implementation running these scenes must post and observe the same
names so app code is source compatible.

## 6. Animation from USD time samples

A referenced or inline USD with time samples (transform ops, `SkelAnimation`)
gives every Xform entity an `AnimationLibraryComponent` with
`"default subtree animation"` and the root with `"global scene animation"`
(see `specs/frameworks/realitykit/07-assets.md` §2). These keys are what an
`animation` action names. A UsdMedia `SpatialAudio` prim also enters that
scene animation as an audio track (`particles-audio.md` §5).

## 7. RCP 3: animation graphs and behavior trees

- RCP 3 authors animation as **Animation Graph** assets (a root node, state
  machines with states, transitions, conduits, typed parameters and tags;
  clip, blend and IK nodes inside states) and logic as **Behavior Tree**
  assets (root, composite, wait, move and parameter nodes with modifiers and
  typed parameters). Their project storage, as far as empty assets show it,
  is in `project-format.md` §4.7.7; entities use them through
  `tm_re_animation_graph_component` and `tm_re_behavior_tree_component`.
- Editor command names also mention sequences with tracks and "the timeline
  of an animation-library entry" (level 4); per the owner these are not an
  authoring model for scenes in RCP 3.0 — the editor offers state-machine
  graphs. (Whether a sequence editor exists for clip previews is open.)
- RealityKit 27 adds **behavior trees** and **animation graphs**. The
  bundled schema files (`BehaviorTreeSchema.json`,
  `AnimationGraphSchema.json`) share one structure: `version` (string),
  `objectTypes[]` with `type_name`, `ui_name`, `base_type_name`, `release`,
  `members[]` (`name`, `ui_name`, `type_name`, `array_element_type`,
  `default_value`, `hidden`), and `enumTypes[]` (`type_name`, `values`).
  Behavior-tree node types include root, sequence, selector, random
  selector, parallel, wait, move-to, move-on-nav-mesh, rotate-to-face,
  parameter setter, set-tree, action, no-op, debug, with loop/return
  modifiers and typed parameters (bool, int, float, option, string,
  vector2/3/4, rotation). Animation-graph types include state machines,
  states, transitions, conduits, clip, 1-D blend, additive, subtract, blend
  mask, bind pose, speed scale, root-motion generation, foot placement,
  full-body IK and motion-warping nodes, with typed parameters and
  conditions. They compile to `.reality` assets. RCP 3 project storage:
  `project-format.md` §4.7.7 (empty assets only). The engine's type names
  (`RootNodeDefinition`, `StateMachineNodeDefinition`, `StateDefinition`,
  `StateTransitionDefinition`, `BT…NodeDefinition`, `…ParameterDefinition`)
  match the runtime schema's type set.

## 8. Requirements for Ycode

1. **Write** timelines, tracks, actions and behaviors exactly as §2–§4
   (prim types, property names and types, `actionKind` strings, UUID
   `info:id` per action). Keep `RCP_BehaviorsContainer` on each entity
   that owns behaviors.
2. **Read** them by the same rules; ignore unknown kinds without failing
   the scene (the reference drops them silently).
3. **Run** them (open runtime): produce one group per timeline plus the
   `__auto_generated_looping` variant under the same keys in the default
   prim's animation library; apply the timing table of §2.1, the axis
   negation for clockwise spins, the 1/30 s minimum for instant actions,
   and the notification names of §5.

## 9. Open questions

1. How RCP2 stored an `AnimationLibrary` component (prims
   `RealityKitAnimationFile`, `RealityKitClipDefinition`; level-4 field
   names `file`, `name`, `looping`, `clipNames`, `startTimes`,
   `sourceAnimationName`). Our four encodings loaded nothing. **Owner by
   hand:** in an RCP 2-era project (or RCP 3 → export), add an animation
   file to an entity's Animation Library, save, and share the USDA.
2. Effect of `transformMode` / `referenceEntity` on `moveTo` (not visible
   at load; probably applied when the action starts).
3. Whether a "set entity property" kind exists and its name; meaning of
   `selectedTimeline`.
4. How `multiplePerformOperation` is authored on a behavior.
5. **Partly answered.** RCP 3 stores behavior trees and animation graphs as
   project assets (`project-format.md` §4.7.7), not in USD; its USD export
   writes neither. Still open: a USD form, if any (the runtime schema JSON
   suggests one in RealityKit 27), the `.reality` asset kinds they compile
   to (empty assets that were not attached to an entity produced none), and
   filled graphs (states with clips, transitions with conditions, trees with
   nodes and parameters).
6. Run-time check that `RealityKit.NotifyAction` is posted with the keys
   above (needs a rendering scene; not run).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Prim types `RealityKitTimeline/Track/Action`, property names (`actionKind`, `startTime`, `duration`, `target`, `blendLayer`, kind-specific names) | 4 → 3 | names from RealityIO string metadata; every listed kind and attribute verified by loading our `<samples>/timelines/tl1–tl6.usda` with RealityKit on macOS 27 |
| Animation-library keys, group/view structure, durations, 1/30 s minimum | 3 | probe dumps of our files |
| Timing-function table | 3 | `tl4.usda` |
| Valid / invalid kind names | 3 | `tl2.usda` (27 candidate kinds) |
| Same result after `realitytool compile` | 3 | `BH.reality`, `T3.reality` dumps diffed against direct loads |
| Behavior prims and properties | 1, 3 | Apple "OpenUSD schemas for AR" / "Actions and triggers"; our `bh1–bh3.usda` loaded into a scene, interaction service inspected |
| Container not needed at run time | 3 | `bh2.usda` (container removed) |
| Notification names and user-info keys | 1, 4 | Apple sample code/WWDC; runtime string metadata |
| RCP 3 sequences/tracks | 4 | editor command names in RCP 3 libraries |
| Behavior-tree / animation-graph schema structure | 2 | key names of the JSON schema files shipped in RealityKit (format study; contents not copied) |
| RCP 3 authors graphs, not timelines | 1, 2 | owner's statement after building the sample in RCP 3.0; the sample's assets |
| RCP 3 animation-graph / behavior-tree storage | 2 | empty assets of the owner-made sample and the project's type index, read with our parser (OBS-RCP4) |
