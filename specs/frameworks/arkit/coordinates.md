# ARKit spec: coordinate systems, math, units, timing

Part of `specs/frameworks/arkit/`. Where a formula is marked **derived**, it
follows from the documented conventions by Ycode's own derivation and must be
checked numerically on hardware with our probe (conformance test C-MATH in
`plan.md`).

## 1. Conventions

- All 3D coordinate systems are **right-handed**.
- Lengths are **meters**; angles are radians except the view-rotation angle,
  which is in degrees.
- Matrices are simd `float4x4`/`float3x3`, **column-major**: `columns[3]` of a
  4×4 transform holds the translation (x, y, z, 1). Points are column vectors
  multiplied on the right: `p_world = T * p_local`.
- A transform property named `transform` maps the object's local space to
  world space (object-to-world). Its inverse is the view matrix of a camera.
- Scale in transforms passed to `setWorldOrigin` is ignored; anchor
  transforms may carry scale (rare; image and body anchors use separate scale
  factors instead).

## 2. World coordinate system

Chosen when a run starts tracking afresh (first run, or reset-tracking), per
`worldAlignment`:

| Alignment | Origin | +Y | −Z | +X |
|---|---|---|---|---|
| gravity (default) | device position at start | up (opposite to gravity; gravity is (0, −1, 0)) | the camera's initial viewing direction, projected onto the horizontal plane | to the right of −Z (right-hand rule) |
| gravity and heading | device position at start | up | true north | east (so +Z is south) |
| camera | the camera | the camera's up | the camera's viewing direction | the camera's right |

With camera alignment the world frame moves with the device: the camera pose
stays at the origin with no rotation and everything else is expressed
relative to the camera (**derived** reading of "locked to the camera's
orientation"; verify on hardware).

Geo tracking uses gravity-and-heading axes (x east, y up, z south). Its origin
is not documented; Ycode places it at the device position when geo tracking
starts.

Orientation tracking (3DoF) uses the gravity frame with the translation
always zero.

`setWorldOrigin(relativeTransform: R)`: R is the new origin's pose in old
world coordinates. Afterward every world-space quantity X (camera transform,
anchor transforms, feature points, raycast results) is reported as
`R⁻¹ · X` (with scale removed from R).

## 3. Camera space and the captured image

Camera space is fixed to the device, not to the interface:

- **+X** runs along the device's long axis toward the Home-button end (the
  bottom of the device in portrait); equivalently, it points right when the
  device is held in `UIDeviceOrientation.landscapeLeft` (Home button or bottom
  edge on the right). This device orientation corresponds to
  `UIInterfaceOrientation.landscapeRight`, the view-rotation angle 0.
- **+Y** points up in that same orientation.
- **+Z** points out of the screen, toward the user; the back camera looks
  along **−Z**.

The captured image is stored in this native orientation: image +x
(columns, left to right) corresponds to camera +X, image +y (rows, top to
bottom) to camera −Y. Intrinsics use pixel coordinates (u right, v down) with
the origin at the **center** of the top-left pixel:

    u = fx · (X / −Z) + px
    v = py − fy · (Y / −Z)

for a point (X, Y, Z) in camera space (Z < 0 in front of the camera).

Face-anchor space and other local spaces are listed with their anchors
(`anchors.md`).

## 4. Camera matrices

### 4.1 Native projection (`projectionMatrix`)

Maps camera space to clip space for the full captured image (width W, height
H, intrinsics fx, fy, px, py) with no far plane. The x and y rows are
**derived** from §3 (NDC x right, NDC y up, both −1…1):

    row 0: [ 2·fx/W,  0,       1 − 2·px/W,  0 ]
    row 1: [ 0,       2·fy/H,  2·py/H − 1,  0 ]
    row 3: [ 0,       0,       −1,          0 ]

(With the half-pixel convention of §3, use px + 0.5 and py + 0.5 if pixel
edges are at integer positions in the renderer; this detail must be fixed by
the hardware check.) The depth row (row 2) depends on the clip-space depth
convention ARKit uses (0…1 as in Metal, or reversed); that is an **open
question** for hardware. Until then Ycode uses Metal's 0…1 range with near at
0 and infinite far at 1: row 2 = [0, 0, −1, −zNear].

### 4.2 Viewport projection

`projectionMatrix(viewRotationAngle:viewportSize:zNear:zFar:)` (and the
orientation form) composes, in normalized device coordinates: the native
projection, then the rotation by the view-rotation angle (§5), then the
aspect-fill scale of §5, so that 3D content lines up with the image drawn
using the display transform for the same size and angle. zFar = 0 means
infinite.

### 4.3 View matrix

`viewMatrix(viewRotationAngle: θ) = Rz(−θ) · camera.transform⁻¹` (**derived**),
where Rz is a rotation about camera Z. For θ = 0 it is simply the inverse of
the camera transform. For θ = 90 (portrait) view +X is camera +Y and view +Y is
camera −X.

### 4.4 Projecting and unprojecting

- `projectPoint(_:viewRotationAngle:viewportSize:)`: world point → viewport
  point in points, origin top-left: apply the view matrix, the viewport
  projection, divide by w, then map NDC to the viewport (x right, y down).
- `unprojectPoint(_:ontoPlaneWithTransform:…)`: build the ray from the camera
  through the viewport point and intersect it with the plane through the
  transform's origin whose normal is the transform's +Y. No intersection (ray
  parallel or behind) → NaN vector in Objective-C, nil in Swift.

## 5. Display transform and the view-rotation angle

The view-rotation angle θ ∈ {0, 90, 180, 270} is the clockwise rotation (in
degrees) to apply to the native image so it appears level in the view:

| θ | Interface orientation | Normalized image (x, y) → normalized rotated (x′, y′) |
|---|---|---|
| 0 | landscape right | (x, y) |
| 90 | portrait | (1 − y, x) |
| 180 | landscape left | (1 − x, 1 − y) |
| 270 | portrait upside down | (y, 1 − x) |

(For θ = 90 this is the affine map a = 0, b = 1, c = −1, d = 0, tx = 1,
ty = 0.) The table is **derived** from §3; verify on hardware.

`displayTransform(viewRotationAngle:viewportSize:)` returns the affine
transform from normalized captured-image coordinates (0…1, origin top-left)
to normalized view coordinates (0…1, origin top-left): the rotation above,
followed by **aspect fill** about the center. With rotated image size (W′, H′)
(W′ = W, H′ = H for 0 and 180; swapped for 90 and 270) and viewport size
(Vw, Vh):

    s  = max(Vw / W′, Vh / H′)
    kx = W′ · s / Vw,   ky = H′ · s / Vh        (both ≥ 1, one equals 1)
    x_view = (x′ − 0.5) · kx + 0.5
    y_view = (y′ − 0.5) · ky + 0.5

Renderers draw the background by mapping each view coordinate through the
inverse transform to a texture coordinate in the captured image.

## 6. Timing

- `ARFrame.timestamp`, `capturedDepthDataTimestamp`: seconds on the system
  host-time clock, the same base as `CACurrentMediaTime()` and as
  AVFoundation capture timestamps (ARKit's documentation says only "time of
  capture"; the clock base is a Ycode decision consistent with capture
  pipelines, to be checked on hardware by comparing with
  `CACurrentMediaTime()` in `didUpdateFrame`).
- Frame rate: the video format's `framesPerSecond` (typically 60 or 30).
  Frames are delivered roughly at that rate; slower processing drops frames.
- Anchor and frame data in one `ARFrame` are consistent for that timestamp.
- `exposureDuration` is in seconds; `lastUpdateTimestamp` in the anchor
  archive uses the same clock as frame timestamps (assumed; 0 when never
  updated).

## 7. Other units

| Quantity | Unit |
|---|---|
| `ambientIntensity` | lumens (≈1000 for a well-lit scene) |
| `ambientColorTemperature` | kelvin |
| `exposureOffset` | EV |
| depth maps | meters (float) |
| `physicalSize`, `physicalWidth`, `radius`, `extent` | meters |
| geo `altitude` | meters above mean sea level |
| Euler angles | radians; applied roll (z), then pitch (x), then yaw (y) |

## Evidence

| Claim | Level | Source |
|---|---|---|
| Right-handed, y up, origin and axes per alignment, gravity vector, heading axis | 1 | "Understanding World Tracking"; `ARConfiguration.WorldAlignment` pages; header documentation |
| Meters | 1 | ARKit documentation (world tracking, depth, reference images) |
| Camera axes relative to `UIDeviceOrientation.landscapeLeft` | 1 | `ARCamera.transform` documentation |
| Intrinsics layout and pixel origin | 1/4 | header documentation of `intrinsics` |
| View-rotation angle values and their orientations | 4 | iOS 27 SDK header documentation |
| Projection rows, view matrix, rotation table, aspect-fill formula | **derived** | Ycode derivation; hardware check C-MATH |
| Clock base of timestamps, depth convention | open | to be measured on hardware |
