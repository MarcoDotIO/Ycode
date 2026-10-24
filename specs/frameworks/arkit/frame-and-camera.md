# ARKit spec: frames, camera, video formats

Part of `specs/frameworks/arkit/`. Conventions as in `session.md`.

## 1. `ARFrame`

A frame is an immutable snapshot of everything the session knows at the
moment one camera image was captured. It conforms to `NSCopying` and is
`Sendable` in Swift. Apps cannot create frames (`init`/`new` unavailable).

| Member | Type | Since | Meaning |
|---|---|---|---|
| `timestamp` | seconds (double) | 11.0 | Capture time of the image (`coordinates.md` §6 for the clock). |
| `capturedImage` | `CVPixelBuffer` | 11.0 | The camera image (§3). |
| `exifData` | dictionary | 16.0 | EXIF metadata of the captured image. |
| `cameraGrainTexture` | Metal texture, nullable | 13.0 | A tileable 3D noise texture whose depth slices match the camera's noise at different light levels, for making rendered content look like the camera image. |
| `cameraGrainIntensity` | float 0…1 | 13.0 | Which slice of the grain texture matches this frame. |
| `capturedDepthData` | `AVDepthData`, nullable | 11.0 | Front depth-camera data; only with face tracking and only on frames where depth was captured (the depth camera runs slower than the color camera). |
| `capturedDepthDataTimestamp` | seconds | 11.0 | Capture time of `capturedDepthData`. |
| `camera` | `ARCamera` | 11.0 | Camera pose, intrinsics and tracking state (§2). |
| `anchors` | array of `ARAnchor` | 11.0 | All anchors in the session as of this frame. |
| `lightEstimate` | `ARLightEstimate`, nullable | 11.0 | Nil when light estimation is off (§4). |
| `rawFeaturePoints` | `ARPointCloud`, nullable | 11.0 | Feature points found in this frame, in world coordinates; only for configurations that run world tracking. |
| `worldMappingStatus` | `ARWorldMappingStatus` | 12.0 | How well the area in view is mapped (`errors-and-states.md` §4). |
| `segmentationBuffer` | `CVPixelBuffer`, nullable | 13.0 | Per-pixel class labels (`ARSegmentationClass`) when person segmentation is on. |
| `estimatedDepthData` | `CVPixelBuffer`, nullable | 13.0 | Depth (meters) for pixels classified as person when person segmentation with depth is on. |
| `detectedBody` | `ARBody2D`, nullable | 13.0 | The 2D body found in the image when body detection is on. |
| `geoTrackingStatus` | `ARGeoTrackingStatus`, nullable | 14.0 | Geo-tracking status for geo configurations. |
| `sceneDepth` | `ARDepthData`, nullable | 14.0 | Per-frame depth from the depth sensor when the scene-depth semantic is on. |
| `smoothedSceneDepth` | `ARDepthData`, nullable | 14.0 | Same, temporally smoothed, when the smoothed semantic is on. |
| `metadataObjects` | array of `AVMetadataObject` | 27.0 | Face metadata objects (`AVMetadataFaceObject`) from face-tracking sessions with `maximumNumberOfTrackedFaces` = 0 (face detection without face anchors). Empty otherwise. |
| `hitTest:types:` | method → array of `ARHitTestResult` | 11.0, deprecated 14.0 | Legacy hit test from a normalized image point (`scene-understanding.md` §3). |
| `raycastQueryFromPoint:allowingTarget:alignment:` | method → `ARRaycastQuery` | 13.0 | Builds a query whose ray starts at the camera and passes through a normalized image point (0,0 top-left, 1,1 bottom-right of the captured image). |
| `displayTransformForOrientation:viewportSize:` | method → affine transform | 11.0, deprecated 27.0 | Maps normalized captured-image coordinates to normalized view coordinates for an interface orientation and viewport size, with aspect fill (`coordinates.md` §5). |
| `displayTransformForViewRotationAngle:viewportSize:` / `displayTransform(viewRotationAngle:viewportSize:)` | method | 27.0 | Same, keyed by a view-rotation angle in degrees. |

`ARSegmentationClass` / `ARFrame.SegmentationClass` (8-bit):
`ARSegmentationClassNone` = 0, `ARSegmentationClassPerson` = 255.

## 2. `ARCamera`

Immutable, `NSCopying`, `Sendable`. One per frame.

| Member | Type | Since | Meaning |
|---|---|---|---|
| `transform` | 4×4 float | 11.0 | Camera pose in world coordinates (camera-to-world). Camera axes in `coordinates.md` §3. |
| `eulerAngles` | float3 (radians) | 11.0 | Pitch (x), yaw (y), roll (z) of the camera. Applied roll first, then pitch, then yaw. |
| `trackingState` | `ARTrackingState` | 11.0 | Swift: refined into an enum with an associated reason (`errors-and-states.md` §2). |
| `trackingStateReason` | `ARTrackingStateReason` | 11.0 | Objective-C only (folded into the Swift enum). |
| `intrinsics` | 3×3 float | 11.0 | Pinhole intrinsics in pixels of `imageResolution`: focal lengths fx, fy on the diagonal, principal point (px, py) in the third column, last row (0, 0, 1). The pixel origin is the center of the top-left pixel. |
| `imageResolution` | size in pixels | 11.0 | Size of `capturedImage` (landscape, sensor orientation). |
| `exposureDuration` | seconds | 13.0 | Exposure time of the frame. |
| `exposureOffset` | EV | 13.0 | Exposure compensation applied. |
| `projectionMatrix` | 4×4 float | 11.0 | Projection for the native image orientation and size with no far plane (infinite). |
| `projectionMatrixForOrientation:viewportSize:zNear:zFar:` | method | 11.0, deprecated 27.0 | Projection with aspect fill for a viewport; zFar = 0 gives an infinite far plane. |
| `projectionMatrixForViewRotationAngle:viewportSize:zNear:zFar:` / `projectionMatrix(viewRotationAngle:viewportSize:zNear:zFar:)` | method | 27.0 | Same keyed by view-rotation angle. |
| `projectPoint:orientation:viewportSize:` | method → point | 11.0, deprecated 27.0 | World point to viewport point (top-left origin). |
| `projectPoint:viewRotationAngle:viewportSize:` | method | 27.0 | Same keyed by angle. |
| `unprojectPoint:ontoPlaneWithTransform:orientation:viewportSize:` | method → float3 | 12.0, deprecated 27.0 | Intersects the viewing ray through a viewport point with the plane whose local +Y is the normal. Swift returns an optional (nil when the ray misses). |
| `unprojectPoint:ontoPlaneWithTransform:viewRotationAngle:viewportSize:` | method | 27.0 | Same keyed by angle; Swift optional. |
| `viewMatrixForOrientation:` | method → 4×4 | 11.0, deprecated 27.0 | World-to-camera matrix for rendering in the given interface orientation. |
| `viewMatrixForViewRotationAngle:` / `viewMatrix(viewRotationAngle:)` | method | 27.0 | Same keyed by angle. |

Math for all of these is in `coordinates.md` §4–5.

## 3. Video formats and the captured image

### 3.1 `ARVideoFormat` / `ARConfiguration.VideoFormat` (since 11.3)

Immutable, `NSCopying`; apps cannot create them.

| Member | Type | Since | Meaning |
|---|---|---|---|
| `captureDevicePosition` | `AVCaptureDevicePosition` | 13.0 | Front or back. |
| `captureDeviceType` | `AVCaptureDeviceType` | 14.5 | Which camera (wide, ultra-wide, …). |
| `imageResolution` | size | 11.3 | Captured image size in pixels (landscape). |
| `framesPerSecond` | integer | 11.3 | Nominal frame rate. |
| `isRecommendedForHighResolutionFrameCapturing` | BOOL | 16.0 | Still capture gives clearly more resolution than streaming. |
| `videoHDRSupported` (`isVideoHDRSupported`) | BOOL | 16.0 | HDR streaming possible. |
| `defaultColorSpace` | `AVCaptureColorSpace` | 26.0 | Color space ARKit configures for this format. |
| `defaultPhotoSettings` | `AVCapturePhotoSettings` | 26.0 | A fresh, mutable settings object used for high-resolution capture with this format. |

### 3.2 Captured image buffer

- A bi-planar YCbCr 4:2:0 `CVPixelBuffer`: plane 0 luma, plane 1 interleaved
  CbCr at half width and half height (level 1 says "planar YCbCr, full range";
  the 4:2:0 bi-planar layout, i.e. `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`,
  is the format renderers are built for and must be confirmed on hardware).
- **Full range** values with the **BT.601** matrix; the buffer carries the
  `kCVImageBufferYCbCrMatrixKey` attachment naming the matrix. Converting to
  RGB uses the standard full-range JPEG equations (ITU-T T.871).
- Orientation is the sensor's native landscape orientation (`coordinates.md`
  §3); the image is not rotated for the interface orientation. The display
  transform rotates it.
- Ycode's simulated camera must produce buffers that are IOSurface-backed
  (so that Metal textures can be made from them with a texture cache), since
  renderers and the matte generator do that.

## 4. Light estimation

`ARLightEstimate` (11.0, `Sendable`, not creatable):

| Member | Meaning |
|---|---|
| `ambientIntensity` | Ambient light in lumen-like units: about 1000 is a well-lit scene; range roughly 0 (dark) to 2000 (very bright). |
| `ambientColorTemperature` | Ambient color temperature in kelvin; 6500 is neutral white. |

`ARDirectionalLightEstimate` (subclass, 11.0), produced by face tracking
(the face acts as a light probe):

| Member | Meaning |
|---|---|
| `sphericalHarmonicsCoefficients` | Second-degree spherical harmonics for light intensity: 27 32-bit floats, as three consecutive sets of nine (red, then green, then blue). |
| `primaryLightDirection` | Unit vector of the dominant light direction. |
| `primaryLightIntensity` | Intensity along that direction. |

## 5. Frame semantics and depth

`ARFrameSemantics` / `ARConfiguration.FrameSemantics` (13.0, option set):

| Value | Bits | Since | Output |
|---|---|---|---|
| `ARFrameSemanticNone` | 0 | 13.0 | — |
| `ARFrameSemanticPersonSegmentation` | 1 << 0 | 13.0 | `segmentationBuffer` |
| `ARFrameSemanticPersonSegmentationWithDepth` | (1 << 1) \| (1 << 0) | 13.0 | `segmentationBuffer` and `estimatedDepthData` |
| `ARFrameSemanticBodyDetection` | 1 << 2 | 13.0 | `detectedBody` |
| `ARFrameSemanticSceneDepth` | 1 << 3 | 14.0 | `sceneDepth` |
| `ARFrameSemanticSmoothedSceneDepth` | 1 << 4 | 14.0 | `smoothedSceneDepth` |

`ARDepthData` (14.0, `Sendable`):

| Member | Meaning |
|---|---|
| `depthMap` | Per-pixel distance in meters from the camera plane, aligned with `capturedImage` (each depth pixel covers a block of image pixels). Pixel format is decided at run time; 32-bit float depth (`kCVPixelFormatType_DepthFloat32`) is the documented example. The commonly reported size on LiDAR devices is 256 × 192 (community-reported, not in Apple documentation; there is no option to change it). |
| `confidenceMap` | Nullable; same size as the depth map; one `ARConfidenceLevel` raw value per pixel (8-bit). |

`ARConfidenceLevel` (14.0): `ARConfidenceLevelLow` 0, `ARConfidenceLevelMedium`
1, `ARConfidenceLevelHigh` 2. Swift makes it `Comparable`.

## 6. Feature points: `ARPointCloud`

`NSSecureCoding`, `Sendable`, not creatable.

| Member | Meaning |
|---|---|
| `count` | Number of points (Objective-C; Swift uses the arrays' counts). |
| `points` | World-space positions. Objective-C: pointer to `count` float3 values; Swift: array of float3. |
| `identifiers` | 64-bit identifiers; the same physical feature keeps its identifier across frames. Swift: array of UInt64. |

## 7. Body detection in 2D

`ARBody2D` (13.0) holds one `skeleton` (`ARSkeleton2D`, `anchors.md` §6) whose
joint landmarks are normalized image coordinates in the captured image.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Member names, types, availability, enum values | 4 | iOS 27.1 SDK headers, ARKit `.swiftinterface` (described) |
| Member meanings, light-estimate scales, SH layout, intrinsics layout | 1 | ARKit documentation and SDK header documentation (summarized) |
| Captured image: planar YCbCr, full range, BT.601, conversion per T.871 | 1 | `capturedImage` documentation page |
| Bi-planar 4:2:0 layout | — | widely used by sample renderers; **confirm on hardware** |
| Depth map units, format query, confidence semantics | 1 | `ARDepthData` and `depthMap` pages |
| 256 × 192 depth size | community | developer-forum reports; Apple engineer stated the size cannot be configured |
| Simulator: `supportedVideoFormats` empty, `videoFormat` nil | 3 | `ARProbe` |
