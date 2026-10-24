# ARKit spec: anchors and their geometry

Part of `specs/frameworks/arkit/`. Conventions as in `session.md`.

## 1. `ARAnchor`

A position and orientation in the world that the session keeps track of.
Conforms to `ARAnchorCopying` (hence `NSCopying`) and `NSSecureCoding`;
`Sendable` in Swift.

| Member | Type | Since | Meaning |
|---|---|---|---|
| `identifier` | UUID | 11.0 | Unique and stable for the anchor's life, kept by copies and by archiving. The session matches anchors across frames by identifier. |
| `name` | string, nullable | 12.0 | Optional app-chosen name. |
| `sessionIdentifier` | UUID, nullable | 13.0 | Identifier of the session that owns the anchor. Nil until the anchor is added to a session (also nil after `addAnchor:` on a session that is not running, in the simulator). |
| `transform` | 4×4 float | 11.0 | Rotation, translation and scale of the anchor in world coordinates (anchor-to-world). |
| `initWithTransform:` | initializer | 11.0 | App anchor at a pose. |
| `initWithName:transform:` | initializer | 12.0 | Same with a name. |
| `initWithAnchor:` | initializer (`ARAnchorCopying`) | 12.0 | Copy initializer. Called whenever an anchor is copied (the session copies anchors into each frame), so **app subclasses that add properties must implement it** and copy their own state. |

`init` and `new` are unavailable. Subclasses that the session creates make
`initWithTransform:` and `initWithName:transform:` unavailable (apps cannot
create planes, faces and so on), except `AREnvironmentProbeAnchor` and
`ARGeoAnchor`, which apps create with their own initializers.

Equality: a copy compares equal to its original (same identifier); it is a
distinct object.

### 1.1 Protocol `ARTrackable` (11.0)

One read-only BOOL, `isTracked`: whether the anchor's transform is currently
valid because the tracked thing is in view and recognized. Adopted by image,
face, body, object, app-clip-code and geo anchors. When an image or face
leaves the view the anchor stays in the session with `isTracked == NO`.

### 1.2 Archive format (observed)

`NSKeyedArchiver` with secure coding encodes an `ARAnchor` as a keyed object
of class name `ARAnchor` (class chain `ARAnchor`, `NSObject`) with these keys:

| Key | Value |
|---|---|
| `identifier` | an `NSUUID` object (its own key `NS.uuidbytes`, 16 bytes) |
| `name` | string object; the key is absent for an unnamed anchor |
| `transform` | data, 64 bytes: the 4×4 float matrix as 16 little-endian floats, column-major (bytes 48–59 hold the translation) |
| `referenceTransform` | data, 64 bytes: a second 4×4 matrix (equal to the transform for a fresh app anchor) |
| `lastUpdateTimestamp` | number, 0 for an anchor never updated |
| `isHiddenFromPublicDelegate` | BOOL, 0 for app anchors |

Unarchiving restores identifier and name. Subclasses add their own keys; their
layouts are not yet observed (they need anchors produced by a running
session, i.e. hardware). A Ycode implementation should write at least these
keys so that archives round-trip with Apple's implementation, and should treat
unknown keys as optional when reading.

## 2. Plane anchors

`ARPlaneAnchor` (11.0): a flat surface. The plane lies in the anchor's local
X–Z plane; local +Y is the surface normal.

| Member | Type | Since | Meaning |
|---|---|---|---|
| `classificationSupported` (class, `isClassificationSupported`) | BOOL | 12.0 | Device can classify planes. |
| `alignment` | `ARPlaneAnchorAlignment` | 11.0 | Horizontal or vertical with respect to gravity. |
| `center` | float3 | 11.0 | Center of the estimated extent in anchor space. |
| `extent` | float3 | 11.0, deprecated 16.0 | Width (x) and length (z) of the estimated rectangle; y is 0. |
| `planeExtent` | `ARPlaneExtent` | 16.0 | Replacement for `extent` (below). |
| `geometry` | `ARPlaneGeometry` | 11.3 | Detailed outline as a triangle mesh (below). |
| `classificationStatus` | `ARPlaneClassificationStatus` | 12.0 | Objective-C only (folded into Swift `classification`). |
| `classification` | `ARPlaneClassification` | 12.0 | What the plane is. |

`ARPlaneAnchorAlignment` / `ARPlaneAnchor.Alignment`: `…Horizontal` 0,
`…Vertical` 1 (11.3).

`ARPlaneClassificationStatus`: `NotAvailable` 0, `Undetermined` 1, `Unknown` 2,
`Known` 3. `ARPlaneClassification`: `None` 0, `Wall` 1, `Floor` 2, `Ceiling` 3,
`Table` 4, `Seat` 5, `Window` 6, `Door` 7. In Swift both are combined into
`ARPlaneAnchor.Classification`, an enum with cases `none(Status)`, `wall`,
`floor`, `ceiling`, `table`, `seat`, `window`, `door`, where
`ARPlaneAnchor.Classification.Status` has `notAvailable`, `undetermined`,
`unknown`; the Objective-C pair maps as: status Known → the named case for the
classification; any other status → `none(status)`. Classification is
`Equatable` (16.0) and its status `Hashable`.

`ARPlaneExtent` (16.0, `NSSecureCoding`): `width` (along local x before
rotation), `height` (along local z before rotation), `rotationOnYAxis`
(radians, rotation of that rectangle about the anchor's y axis).

`ARPlaneGeometry` (11.3, `NSSecureCoding`): a growing triangle mesh in anchor
space whose vertex and triangle counts change between frames.

| Member | Objective-C | Swift |
|---|---|---|
| vertices | `vertexCount` + pointer to float3 | `vertices: [simd_float3]` |
| texture coordinates | `textureCoordinateCount` + pointer to float2 | `textureCoordinates` array |
| triangles | `triangleCount` + pointer to 16-bit indices (3 per triangle) | `triangleIndices: [Int16]`; `triangleCount` stays |
| boundary | `boundaryVertexCount` + pointer to float3 | `boundaryVertices` array (outermost polygon, ordered) |

Merging: when two planes are found to be one, the newer anchor is removed and
the older one grows.

## 3. Image anchors

`ARImageAnchor` (11.3, `ARTrackable`): a detected `ARReferenceImage`.
`referenceImage`; `estimatedScaleFactor` (13.0; ratio between the estimated
physical size and the declared one, 1.0 unless automatic image scale
estimation is on, in which case the transform's translation is corrected by
it). The image lies in the anchor's X–Z plane with +Y out of the image
(same convention as planes). Reference images are in
`scene-understanding.md` §7.

## 4. Object anchors

`ARObjectAnchor` (12.0, `ARTrackable`): a detected `ARReferenceObject`.
`referenceObject`; `isTracked` (27.0). For `.referenceobject` objects the
anchor stays when tracking is lost and `isTracked` reports it; for legacy
`.arobject` objects `isTracked` is always YES. Content is placed using the
anchor transform plus the reference object's `center` and `extent`; since iOS
27 the reference object may carry a USDZ model (`usdzFile`).

## 5. Face anchors

`ARFaceAnchor` (11.0, `ARTrackable`). The anchor origin is near the center of
the head; in face space +Y is up, +Z points out of the face toward the viewer,
+X points to the face's left (the viewer's right). Units are meters.

| Member | Type | Since | Meaning |
|---|---|---|---|
| `geometry` | `ARFaceGeometry` | 11.0 | Face mesh deformed by the current blend shapes. |
| `leftEyeTransform`, `rightEyeTransform` | 4×4 | 12.0 | Eye poses relative to the anchor. |
| `lookAtPoint` | float3 | 12.0 | Gaze target relative to the anchor. |
| `blendShapes` | dictionary blend-shape-location → number 0…1 | 11.0 | Expression coefficients. Values describe the face **as seen in the captured image**: the person's right eye closing shows up as the left-side coefficient. |

`ARBlendShapeLocation` / `ARFaceAnchor.BlendShapeLocation` is a string enum
with 52 constants (all 11.0 except `TongueOut`, 12.0):
BrowDownLeft, BrowDownRight, BrowInnerUp, BrowOuterUpLeft, BrowOuterUpRight,
CheekPuff, CheekSquintLeft, CheekSquintRight, EyeBlinkLeft, EyeBlinkRight,
EyeLookDownLeft, EyeLookDownRight, EyeLookInLeft, EyeLookInRight,
EyeLookOutLeft, EyeLookOutRight, EyeLookUpLeft, EyeLookUpRight,
EyeSquintLeft, EyeSquintRight, EyeWideLeft, EyeWideRight, JawForward, JawLeft,
JawOpen, JawRight, MouthClose, MouthDimpleLeft, MouthDimpleRight,
MouthFrownLeft, MouthFrownRight, MouthFunnel, MouthLeft, MouthLowerDownLeft,
MouthLowerDownRight, MouthPressLeft, MouthPressRight, MouthPucker, MouthRight,
MouthRollLower, MouthRollUpper, MouthShrugLower, MouthShrugUpper,
MouthSmileLeft, MouthSmileRight, MouthStretchLeft, MouthStretchRight,
MouthUpperUpLeft, MouthUpperUpRight, NoseSneerLeft, NoseSneerRight,
TongueOut (each prefixed `ARBlendShapeLocation`; Swift: lower-camel-case
static members). The string values of the constants are in §8.

`ARFaceGeometry` (11.0, `NSSecureCoding`, `NSCopying`): a mesh with a **fixed
topology** — vertex count, triangle count, texture coordinates and indices
never change; only vertex positions move.

| Member | Notes |
|---|---|
| `vertexCount`, `vertices` | float3 positions in face-anchor space; Swift array |
| `textureCoordinateCount`, `textureCoordinates` | float2; Swift array |
| `triangleCount`, `triangleIndices` | 16-bit indices; Swift array |
| `initWithBlendShapes:` | Builds a geometry for given coefficients (empty dictionary = neutral face). Nullable. |

The topology (vertex positions of the neutral face, UVs, indices) is data
that a Ycode implementation must author itself (for example from a
permissively licensed face model); Apple's mesh must not be copied. Apps
depend on the counts being constant, not on particular values. The
commonly cited count on devices (1220 vertices) is not verified here.

## 6. Bodies and skeletons

`ARBodyAnchor` (13.0, `ARTrackable`): `skeleton` (`ARSkeleton3D`) and
`estimatedScaleFactor` (ratio to the default body size; 1.0 unless automatic
skeleton scale estimation is on). The default skeleton height, lowest to
highest joint standing, is 1.71 m. The anchor transform is the body's root
(hip) joint in world space.

`ARSkeleton` (13.0): `definition` (`ARSkeletonDefinition`), `jointCount`,
`isJointTracked:`.

`ARSkeleton3D` (13.0): `jointModelTransforms` (each joint relative to the
skeleton root, i.e. the anchor), `jointLocalTransforms` (each joint relative to
its parent), `modelTransformForJointName:`, `localTransformForJointName:`.
Objective-C: pointers to `jointCount` matrices; an unknown joint name gives a
matrix full of NaN. Swift: arrays, and the by-name lookups return optionals
(nil for unknown names).

`ARSkeleton2D` (13.0): `jointLandmarks` (normalized image coordinates, float2
per joint), `landmarkForJointNamed:` (NaN for unknown names; Swift optional).

`ARSkeletonDefinition` (13.0):

| Member | Meaning |
|---|---|
| `defaultBody3DSkeletonDefinition` (class) | The 3D body skeleton. |
| `defaultBody2DSkeletonDefinition` (class) | The 2D body skeleton. |
| `jointCount`, `jointNames` | Joint list; names are `ARSkeletonJointName` strings. |
| `parentIndices` | Parent of each joint; the root has −1. Swift: `[Int]`. |
| `neutralBodySkeleton3D` | The 3D skeleton in a T-pose at the standard size; nil for the 2D definition. |
| `indexForJointName:` | Index, or `NSNotFound` (Swift: `index(for:)` returns `Int`, with `NSNotFound` for unknown names). |

`ARSkeletonJointName` / `ARSkeleton.JointName` (13.0) has eight named
constants: `Root`, `Head`, `LeftHand`, `RightHand`, `LeftFoot`, `RightFoot`,
`LeftShoulder`, `RightShoulder`. `ARSkeletonJointNameForRecognizedPointKey`
(14.0; Swift `ARSkeletonJointName.init(_:)`) maps a Vision body-pose point
key to a joint name, or nil.

**2D definition (observed in the simulator, where it is fully populated):**
19 joints, index : name : parent index —
0 `head_joint` 1; 1 `neck_1_joint` 16; 2 `right_shoulder_1_joint` 1;
3 `right_forearm_joint` 2; 4 `right_hand_joint` 3; 5 `left_shoulder_1_joint` 1;
6 `left_forearm_joint` 5; 7 `left_hand_joint` 6; 8 `right_upLeg_joint` 16;
9 `right_leg_joint` 8; 10 `right_foot_joint` 9; 11 `left_upLeg_joint` 16;
12 `left_leg_joint` 11; 13 `left_foot_joint` 12; 14 `right_eye_joint` 0;
15 `left_eye_joint` 0; 16 `root` −1; 17 `right_ear_joint` 14;
18 `left_ear_joint` 15. `indexForJointName:` gives 16 for Root and 0 for Head.

**3D definition:** empty in the simulator (0 joints, no names). The device
definition (documented in WWDC 2019 material as 91 joints, of which a subset
is actively tracked) must be obtained by a hardware probe before Ycode can
match it; joint names are interop identifiers, so recording them from a
device run of our own probe is allowed.

## 7. Other anchors

| Class | Since | Created by | Content |
|---|---|---|---|
| `ARMeshAnchor` | 13.4 | session (scene reconstruction) | `geometry` (`ARMeshGeometry`, `scene-understanding.md` §5) in anchor space. The reconstructed world is split into many mesh anchors, each a chunk of space. |
| `AREnvironmentProbeAnchor` | 12.0 | app (`initWithTransform:extent:`, `initWithName:transform:extent:`) or session (automatic texturing) | `environmentTexture` (Metal cube texture, nullable until generated) and `extent` (box used for parallax correction; infinite by default, i.e. `initWithTransform:` gives an extent of +∞ in all axes). |
| `ARParticipantAnchor` | 13.0 | session (collaboration) | Pose of another participant's device; `sessionIdentifier` tells whose. Updated every frame. |
| `ARAppClipCodeAnchor` | 14.3 | session | `url` (nil until decoded), `urlDecodingState` (`Decoding` 0, `Failed` 1, `Decoded` 2; Swift `ARAppClipCodeAnchor.URLDecodingState`), `radius` (meters). |
| `ARGeoAnchor` | 14.0 | app | `coordinate` (latitude/longitude), `altitude` (meters above mean sea level, valid only when `altitudeSource` is not unknown; Swift: optional), `altitudeSource` (`ARAltitudeSource`, Swift `ARGeoAnchor.AltitudeSource`: `Unknown` 0, `Coarse` 1, `Precise` 2, `UserDefined` 3). Initializers with coordinate, optionally altitude and name (Swift: one initializer with an optional altitude). Without an altitude the session looks up ground level and fills it in. The transform is maintained by the session while geo tracking runs. |

## 8. Constant string values

The constants are strings that apps may compare or store, so their values are
part of the interface (like plist keys). Observed values:

- Blend-shape locations, in the order of §5: `browDown_L`, `browDown_R`,
  `browInnerUp`, `browOuterUp_L`, `browOuterUp_R`, `cheekPuff`,
  `cheekSquint_L`, `cheekSquint_R`, `eyeBlink_L`, `eyeBlink_R`,
  `eyeLookDown_L`, `eyeLookDown_R`, `eyeLookIn_L`, `eyeLookIn_R`,
  `eyeLookOut_L`, `eyeLookOut_R`, `eyeLookUp_L`, `eyeLookUp_R`,
  `eyeSquint_L`, `eyeSquint_R`, `eyeWide_L`, `eyeWide_R`, `jawForward`,
  `jawLeft`, `jawOpen`, `jawRight`, `mouthClose`, `mouthDimple_L`,
  `mouthDimple_R`, `mouthFrown_L`, `mouthFrown_R`, `mouthFunnel`, `mouthLeft`,
  `mouthLowerDown_L`, `mouthLowerDown_R`, `mouthPress_L`, `mouthPress_R`,
  `mouthPucker`, `mouthRight`, `mouthRollLower`, `mouthRollUpper`,
  `mouthShrugLower`, `mouthShrugUpper`, `mouthSmile_L`, `mouthSmile_R`,
  `mouthStretch_L`, `mouthStretch_R`, `mouthUpperUp_L`, `mouthUpperUp_R`,
  `noseSneer_L`, `noseSneer_R`, `tongueOut` (52 values; "Left" constants end
  in `_L`, "Right" in `_R`).
- Joint names: Root `root`, Head `head_joint`, LeftHand `left_hand_joint`,
  RightHand `right_hand_joint`, LeftFoot `left_foot_joint`, RightFoot
  `right_foot_joint`, LeftShoulder `left_shoulder_1_joint`, RightShoulder
  `right_shoulder_1_joint`.
- `ARErrorDomain` = `com.apple.arkit.error`;
  `ARReferenceObjectArchiveExtension` = `arobject`.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Names, types, availability, enum values, Swift refinements | 4 | SDK headers and `.swiftinterface` (described) |
| Meanings (plane frame, merging, face space, blend-shape mirroring, skeleton height, probe extent) | 1 | ARKit documentation and header documentation (summarized) |
| Anchor archive keys and byte layout (column-major checked with a rotated, translated matrix) | 2/3 | `NSKeyedArchiver` output of an anchor created by `ARProbe` in the simulator |
| Copy equality, `sessionIdentifier` nil when not running, infinite probe extent | 3 | `ARProbe` |
| 2D skeleton joint list, 3D definition empty in the simulator, constant string values | 3 | `ARProbe` (`-probe all`, `-probe consts`) |
| 91-joint 3D skeleton, 1220-vertex face mesh | community/WWDC | **unverified**; to be measured on hardware |
