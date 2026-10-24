# ARKit spec: errors and status values

Part of `specs/frameworks/arkit/`. Conventions as in `session.md`.

## 1. Errors

Domain constant `ARErrorDomain`, string value `com.apple.arkit.error`
(11.0). Codes are the `ARErrorCode` error enum (Swift: `ARError` with
`ARError.Code` cases named in lower camel case, e.g. `.unsupportedConfiguration`).

| Code | Name (`ARErrorCode…`) | Since | Raised when |
|---|---|---|---|
| 100 | `UnsupportedConfiguration` | 11.0 | This device cannot run the configuration (or an option it requests). Also what the simulator returns for every run and for reference-image validation. |
| 101 | `SensorUnavailable` | 11.0 | A required sensor is not available. |
| 102 | `SensorFailed` | 11.0 | A sensor stopped providing usable input. |
| 103 | `CameraUnauthorized` | 11.0 | No camera permission. |
| 104 | `MicrophoneUnauthorized` | 11.0 | No microphone permission (audio requested). |
| 105 | `LocationUnauthorized` | 14.0 | No location permission (geo tracking). |
| 106 | `HighResolutionFrameCaptureInProgress` | 16.0 | A high-resolution capture was requested while one is running. |
| 107 | `HighResolutionFrameCaptureFailed` | 16.0 | High-resolution capture failed. |
| 200 | `WorldTrackingFailed` | 11.0 | World tracking hit an unrecoverable error. |
| 201 | `GeoTrackingNotAvailableAtLocation` | 14.0 | Geo tracking is not offered here. |
| 202 | `GeoTrackingFailed` | 14.0 | Geo tracking runtime error. |
| 300 | `InvalidReferenceImage` | 11.3 | A reference image cannot be used. |
| 301 | `InvalidReferenceObject` | 12.0 | A reference object cannot be loaded, its format does not allow the operation, or legacy and new formats are mixed in one session; the reason is in `userInfo`. |
| 302 | `InvalidWorldMap` | 12.0 | The initial world map cannot be used. |
| 303 | `InvalidConfiguration` | 12.0 | The configuration's settings are invalid together. |
| 304 | `InvalidCollaborationData` | 13.2 | Received collaboration data is corrupt or incompatible. |
| 400 | `InsufficientFeatures` | 12.0 | Not enough features (world map, reference object). |
| 401 | `ObjectMergeFailed` | 12.0 | Two reference objects could not be merged. |
| 500 | `FileIOFailed` | 12.0 | Reading or writing a file failed. |
| 501 | `RequestFailed` | 14.0 | A request failed for another reason. |

Error objects carry `NSLocalizedDescriptionKey` (short title, e.g. "unsupported
configuration") and `NSLocalizedFailureReasonKey` (one sentence explaining the
condition); in the simulator, code 100 carries exactly those two keys and no
recovery suggestion. The text is localized in 57 languages on Apple's side;
Ycode writes its own English text (and later its own translations) — do not
copy Apple's strings.

Which errors are fatal: failures reported through `session:didFailWithError:`
pause the session. Errors returned to completion handlers (world map,
reference object, geo location, high-resolution capture, validation) do not
affect the running session.

## 2. Camera tracking state

`ARTrackingState` (11.0): `NotAvailable` 0, `Limited` 1, `Normal` 2.
`ARTrackingStateReason` (11.0): `None` 0, `Initializing` 1,
`ExcessiveMotion` 2, `InsufficientFeatures` 3, `Relocalizing` 4 (11.3).

Both are refined for Swift into `ARCamera.TrackingState`, a frozen enum:
`.notAvailable`, `.limited(Reason)`, `.normal`, with `ARCamera.TrackingState.Reason`
= `.initializing`, `.excessiveMotion`, `.insufficientFeatures`,
`.relocalizing` (11.3). `TrackingState` is `Equatable` (16.0); `Reason` is
`Hashable`. Mapping: state Limited with reason R → `.limited(R)`; the reason is
None for the other two states.

Meanings:

| State / reason | When |
|---|---|
| not available | before the first frame of a run, or when the configuration does not track (and in the simulator, always, because no frame is produced) |
| limited / initializing | shortly after a run, until enough motion and features have been seen |
| limited / excessive motion | the device moves too fast (blur, too much change between frames) |
| limited / insufficient features | the view lacks texture or light (blank wall, darkness) |
| limited / relocalizing | after an interruption when relocalization was accepted, or while localizing to an `initialWorldMap` |
| normal | tracking is good |

Orientation tracking and image tracking report their own (simpler) notion of
normal; face tracking reports per face via `isTracked`.

## 3. Anchor tracking

`ARTrackable.isTracked` (`anchors.md` §1.1). For `ARObjectAnchor` from legacy
objects it is always YES.

## 4. World mapping status

`ARWorldMappingStatus` / `ARFrame.WorldMappingStatus` (12.0):

| Value | Name | Meaning |
|---|---|---|
| 0 | `NotAvailable` | no map (not world tracking, or nothing yet) |
| 1 | `Limited` | the area in view is barely mapped; a map saved now would not relocalize here |
| 2 | `Extending` | areas already visited are mapped; the current area is still being added |
| 3 | `Mapped` | the area in view is well mapped; saving now is recommended |

## 5. Geo tracking status

`ARGeoTrackingStatus` (14.0; `NSCopying`, `NSSecureCoding`): `state`,
`accuracy`, `stateReason`.

`ARGeoTrackingState` / `ARGeoTrackingStatus.State`: `NotAvailable` 0,
`Initializing` 1, `Localizing` 2, `Localized` 3.

`ARGeoTrackingAccuracy` / `.Accuracy`: `Undetermined` 0, `Low` 1, `Medium` 2,
`High` 3.

`ARGeoTrackingStateReason` / `.StateReason`: `None` 0,
`NotAvailableAtLocation` 1, `NeedLocationPermissions` 2,
`WorldTrackingUnstable` 3, `WaitingForLocation` 4,
`WaitingForAvailabilityCheck` 5, `GeoDataNotLoaded` 6,
`DevicePointedTooLow` 7, `VisualLocalizationFailed` 8.

Changes are reported through `session:didChangeGeoTrackingStatus:` and appear
on each frame's `geoTrackingStatus`.

## 6. Exceptions (programming errors)

ARKit raises Objective-C exceptions (which terminate Swift apps) rather than
returning errors for misuse. Documented case: assigning frame semantics the
configuration class does not support. Unverified on hardware, so the
exception name and the moment it is raised (assignment or run) are open
questions. The simulator raises none of these: every property accepts any
value.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Codes, names, availability, Swift refinements | 4 | SDK headers (`ARError.h`, `ARTrackingStatusTypes.h`, `ARGeoTrackingTypes.h`, `ARFrame.h`), `.swiftinterface` |
| Meanings | 1 | header documentation and ARKit documentation (summarized) |
| Domain string, userInfo keys, simulator code 100 | 3 | `ARProbe` |
| Localized string tables | 4 | simulator runtime bundle file list (`ARKitCore.framework/*.lproj/Localizable.strings`), not opened |
| Exception for unsupported semantics | 1 | `frameSemantics` documentation; hardware behavior **unverified** |
