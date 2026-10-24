# Design note (Ycode-original): a simulated world for ARKit

> **This file is Ycode's own design, not a description of Apple's
> behavior.** Nothing here comes from Apple binaries; it builds on the
> interface in the other files of this directory, public computer-vision
> literature and permissively licensed open source. It defines what Ycode
> adds on top of the baseline in `simulator-baseline.md`.

## 1. Goal

Run unmodified ARKit apps in Ycode's iOS simulator against a **simulated
physical world**: a 3D scene in which a virtual iPhone moves. The simulator
renders what the phone's cameras would see and what its motion sensors would
measure, and Ycode's ARKit produces frames, anchors and the rest from that.
Later the scene comes from the visionOS-like environment (`docs/FUTURE.md`),
where the virtual iPhone is held inside a spatial scene.

The feature is per simulated device and off by default. When it is off, the
baseline applies unchanged.

## 2. Architecture

    host (Linux, Ycode simulator host)                 guest (iOS runtime)
    ┌──────────────────────────────┐                  ┌────────────────────────────┐
    │ World: scene + semantics      │                  │ App                        │
    │ Pose driver: UI / script /    │                  │   │ ARKit API (Ycode)      │
    │   visionOS hand pose          │   sensor channel │   ▼                        │
    │ Sensor renderer: cameras,     │ ───────────────► │ ARKit engine               │
    │   depth, IMU, compass, GPS    │  (IOSurfaces +   │  ├─ oracle backend         │
    │ Oracle service: ground-truth  │   sample stream) │  └─ vision backend (VIO…)  │
    │   queries (planes, meshes, …) │ ◄─────────────── │                            │
    └──────────────────────────────┘   oracle queries  └────────────────────────────┘

- **World**: geometry, materials and lights, plus a semantic side-car (§5).
- **Pose driver**: produces the device's ground-truth 6-DoF trajectory over
  time from user input (keyboard/mouse "walk", like the visionOS simulator's
  camera controls), a recorded or scripted trajectory file (deterministic
  tests), or, in the visionOS-like environment, the pose of the hand holding
  the phone.
- **Sensor renderer**: renders camera images (Ycode's Metal→Vulkan graphics
  layer), depth, and synthesizes inertial data from the trajectory.
- **Sensor channel**: delivers camera frames as IOSurface-backed buffers
  (`specs/simulator/iosurface-remote.md`) and a timestamped sample stream
  (IMU, magnetometer, location) into the guest. The same camera service
  should also back AVFoundation capture in the simulator, so apps that use
  the camera directly see the same world.
- **ARKit engine** (guest, Ycode code): implements the API and selects a
  backend per session.

## 3. Inputs an implementation needs

| Stream | Content | Rate | Used for |
|---|---|---|---|
| Back camera image | YCbCr 4:2:0 full-range BT.601 buffer, landscape native orientation (`frame-and-camera.md` §3); exposure duration, exposure offset, EXIF | 30/60 Hz per video format | `capturedImage`, rendering, vision backend |
| Camera intrinsics | fx, fy, px, py at the stream resolution; optional lens distortion (the image ARKit delivers is undistorted, so render undistorted) | per frame | `ARCamera.intrinsics`, projection |
| Device pose (ground truth) | 6-DoF pose of the camera in world space, plus linear and angular velocity | ≥ camera rate (ideally IMU rate) | oracle backend; evaluation of the vision backend |
| IMU | accelerometer (specific force incl. gravity, m/s²) and gyroscope (rad/s), with configurable bias, noise and timestamp jitter | 100–1000 Hz | vision backend (VIO), CoreMotion consistency |
| Magnetometer / heading | magnetic field or true heading | 50–100 Hz | gravity-and-heading alignment, geo tracking |
| Location | latitude, longitude, altitude, accuracies | 1 Hz | geo tracking, `ARGeoAnchor` |
| Depth (LiDAR-like) | metric depth map 256 × 192 (float32) + confidence, aligned with the back camera | camera rate | `sceneDepth`, smoothed depth, scene reconstruction, better raycasts |
| Front camera + front depth | color image and a depth map from the front camera | 60 Hz color, ~15–30 Hz depth | face tracking, `capturedDepthData` |
| Microphone | audio sample buffers | — | `providesAudioData` |
| Semantics (oracle only) | object IDs per pixel, person mask, plane and surface labels, marker/image placements, object placements, face rig state, body skeleton state | camera rate | anchors and semantic outputs in oracle mode |

## 4. What can be computed from a synthetic scene

Two backends:

- **Oracle backend**: reads ground truth from the world. Exact, cheap and
  deterministic; ideal for app development and conformance tests.
- **Vision backend**: runs real algorithms on the rendered (or real-webcam)
  images and IMU samples. Needed to reproduce realistic behavior
  (initialization time, drift, tracking loss) and to work with real camera
  input that has no ground truth.

| ARKit output | Oracle backend (synthetic scene) | Vision backend needs |
|---|---|---|
| Camera pose (`ARCamera.transform`) | ground-truth pose (optionally plus drift/noise model) | visual-inertial odometry |
| Tracking state and reason | scripted from simple rules: initializing for a set time after run; excessive motion above an angular/linear speed threshold; insufficient features when the visible-texture measure is low; relocalizing after interruption | VIO health signals |
| Orientation tracking (3DoF) | ground-truth rotation | IMU attitude filter (complementary/Kalman) |
| Raw feature points | sample points on visible textured surfaces, with stable identifiers per surface point | feature detection and tracking |
| Plane anchors | from surfaces labeled planar in the side-car, revealed progressively as their area becomes visible, grown/merged over time; classification from labels | plane fitting on depth or triangulated points (RANSAC) |
| Plane geometry (`ARPlaneGeometry`) | visible part of the labeled polygon, triangulated | polygon from fitted points (convex/concave hull) |
| Scene depth + confidence | render depth buffer, downsampled; confidence from surface angle/distance | requires a depth sensor or learned monocular depth (lower quality) |
| Mesh anchors | scene geometry within observed regions, chunked into spatial cells; classification from labels | TSDF fusion of depth + marching cubes |
| Light estimate | integrate scene lighting at the camera; color temperature from light colors | image statistics (mean luminance, white balance) |
| Environment probe textures | render a cube map at the probe position | accumulate camera images onto a proxy geometry |
| Image anchors | known placement of image textures in the world; visibility test | 2D feature matching + homography + PnP |
| Object anchors | known placement of reference objects | 3D object detection/pose estimation (hard) |
| Face anchors (front camera) | an animated face rig in the world provides pose, blend shapes and eye/gaze state directly | face landmark detection + blend-shape fitting |
| Body anchors / 2D body | an animated character provides joint transforms, retargeted to ARKit's joint set | 2D/3D pose estimation |
| Person segmentation / estimated depth | ID buffer and depth buffer of person meshes | person segmentation network |
| Raycasts and hit tests | ray intersection with detected planes / visible geometry | same against estimated planes and feature points |
| World maps | serialize the oracle's revealed state; relocalization is immediate when the pose is known | place recognition + map merge |
| Collaboration | two simulated devices in one world share ground truth; participant anchors from the other device's pose | map merging between VIO instances |
| Geo tracking | world's geodetic reference converts world ↔ latitude/longitude/altitude; states can be scripted (initializing → localizing → localized) | not reproducible (needs Apple's map data) |
| App Clip Codes | placements and URLs declared in the side-car | not reproducible (format is Apple's) |
| Camera grain, motion blur | synthesize noise texture and blur from exposure and motion | — |
| Matte generator | from the person mask | — |

Default: the oracle backend. The vision backend is a later round and is
optional per session.

## 5. World description

- Geometry: **OpenUSD** stages (the format RealityKit and visionOS use), in
  meters with +Y up, which matches ARKit's world. A small built-in set of test
  worlds (empty room, tabletop with posters, office, outdoor plaza with a
  geodetic origin) ships with Ycode, authored by us.
- Semantic side-car (Ycode format, JSON) listing: planar surfaces with
  ARKit classifications; mesh classification per material or object; reference
  images placed in the world (by asset name and physical size); reference
  objects; animated people (body skeleton tracks) and faces (blend-shape
  tracks); App Clip Codes; the geodetic origin and heading of the world's
  origin; lighting summary values.
- Device trajectories: a timestamped list of poses (optionally IMU samples),
  replayable for deterministic tests.

## 6. Realism controls

Per device: initialization delay; pose noise and drift; IMU noise and bias;
frame drops and latency; plane discovery speed; forced tracking-state
episodes; forced interruptions (simulate backgrounding or camera loss); depth
noise; exposure and white balance. Every control has a deterministic seed.

## 7. Open-source building blocks

Licenses checked from each project's license file or GitHub metadata
(2026-10-19). **GPL/LGPL code must not be linked into or copied into Ycode
code.** Projects may be used only as external references or under their
license terms; no code is copied into specs.

| Project | Use | License | Usable |
|---|---|---|---|
| OpenCV | image processing, features (ORB, AKAZE), PnP, homography, calibration | Apache-2.0 | yes |
| Basalt | visual-inertial odometry and mapping | BSD-3-Clause | yes |
| Kimera-VIO | visual-inertial odometry | BSD-2-Clause | yes |
| OKVIS / OKVIS2 | keyframe visual-inertial SLAM | BSD-style (3-clause text) | yes, after reading the notice |
| ROVIO | filter-based VIO | BSD-style | yes, after reading the notice |
| maplab | mapping, map merging, relocalization | Apache-2.0 | yes |
| GTSAM | factor-graph optimization | BSD (core) | yes |
| Ceres Solver | nonlinear least squares | BSD-style | yes |
| Sophus | Lie groups for poses | MIT | yes |
| DBoW2 | place recognition (bag of words) | BSD-style with notices | check notices |
| AprilTag 3 | fiducial detection (test markers) | BSD-2-Clause | yes |
| LightGlue | learned feature matching | Apache-2.0 (code; check weights) | yes for code |
| Open3D | TSDF fusion, meshing, plane segmentation | MIT | yes |
| COLMAP | offline structure-from-motion (test-data tooling) | BSD-style (verify) | tooling only |
| MediaPipe | face landmarks/mesh, pose, segmentation models | Apache-2.0 | yes (check model cards) |
| MiDaS | monocular depth | MIT | yes (check weights) |
| Filament | physically based renderer | Apache-2.0 | yes |
| Habitat-sim | reference for embodied sensor simulation | MIT | yes |
| AirSim | reference for sensor/IMU simulation | MIT (archived) | reference |
| OpenUSD | scene format | modified Apache-2.0 (TOST 1.0; verify) | yes |
| ORB-SLAM2 / ORB-SLAM3 | SLAM | GPL-3.0 | **no** |
| OpenVINS | VIO | GPL-3.0 | **no** |
| VINS-Mono / VINS-Fusion | VIO | GPL-3.0 | **no** |

Datasets (for evaluating the vision backend, not shipped): check each
dataset's license separately; many research datasets are non-commercial.

## 8. Interfaces to settle in implementation rounds

1. Sensor channel protocol (shared with the simulator's camera and
   CoreMotion work): message types, clock domain (host time), buffer
   ownership, back-pressure (drop oldest).
2. Oracle query protocol: "surfaces visible from pose P", "ray hits", "mesh
   chunks in region", "people and faces in view", "lighting at point".
3. Device settings: enable flag, world selection, trajectory source, realism
   controls.
4. How the visionOS-like environment supplies the world and the phone pose.

## Evidence

Ycode-original design. External facts used: license files and GitHub license
metadata of the listed projects (fetched 2026-10-19); ARKit interface facts
from the other files of this spec.
