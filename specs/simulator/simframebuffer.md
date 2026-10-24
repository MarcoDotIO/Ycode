# Spec: the simulator framebuffer client library (`SimFramebuffer.framework`)

Status: **reference** for stage 7 (`stage7-contract.md` §5, agent R4) and
input for stage 8. It describes the interface that the iOS 27.1 runtime
(24A94401) uses from the library named by `SIMULATOR_FRAMEBUFFER_FRAMEWORK`,
the order of calls in a real boot, the values seen, and the smallest
behavior with which `backboardd` starts and serves
`com.apple.backboard.display.services`. §8 surveys `SimulatorHID.framework`
(`SIMULATOR_HID_SYSTEM_MANAGER`) for stage 8.

Every fact comes from public documentation (level 1), from exported names,
load commands, and ObjC metadata of CoreSimulator's frameworks (level 4),
and from black-box runs of our own programs on this Mac's simulator
(level 3). No Apple binary was disassembled or decompiled. Our programs are
in `research/experiments/simulator/simframebuffer/` (Appendix A).

Terms:

- **The library**: CoreSimulator's
  `/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer`
  (version 1174.9.2). It is not part of the runtime.
- **The client**: the runtime's
  `/System/Library/PrivateFrameworks/SimFramebufferClient.framework`
  (in the runtime's shared cache). It loads the library and forwards to it.
- **The server**: the host service `com.apple.CoreSimulator.SimFramebufferServer`
  (`launchd-sim.md` §6.3).
- **Headless prototype**: our `sfbheadless.c` (Appendix A), written from
  this spec. It was used to check §7 on the Mac.
- `ticks`: `mach_absolute_time` units. `CGRect` and `CGSize` are the public
  CoreGraphics structures of `double`s.

## 1. The library as a file

| Property | Value |
|---|---|
| Format | Mach-O 64-bit dylib, arm64, `LC_BUILD_VERSION` platform 7 (iOS simulator), minos 15.0, sdk 27.0 |
| Install name | `…/CoreSimulator.framework/Versions/A/Resources/Platforms/iphoneos/Library/PrivateFrameworks/SimFramebuffer.framework/SimFramebuffer` |
| Bundle id | `com.apple.CoreSimulator.SimFramebuffer`, package type `FMWK` |
| Links | CoreFoundation, IOSurface, Foundation, libobjc, libSystem |
| Exports | 132 functions, 4 data constants, 1 ObjC class, 1 crash-message buffer (§2) |

Imports that matter for a replacement: `bootstrap_look_up`, `mach_msg`,
`mach_msg_send`, dispatch Mach send/receive sources, `IOSurfaceCreateMachPort`,
`IOSurfaceGetID`, `_CFRuntimeRegisterClass`, `_CFRuntimeCreateInstance`.
The library's own objects are CF types.

## 2. How it is loaded

1. **The variable.** `SIMULATOR_FRAMEBUFFER_FRAMEWORK` holds the path of
   the **binary** (`…/SimFramebuffer.framework/SimFramebuffer`), not of the
   bundle directory (compare `SIMULATOR_HID_SYSTEM_MANAGER`, §8).
2. **Who loads it.** The client loads it lazily, on the first call of any
   `SFB…` function of the client. In a real boot only two processes do so:
   `backboardd` (from QuartzCore's window-server start, connection name
   `CAWindowServer`) and CoreSimulator's bridge (`CoreSimulatorBridge`,
   not needed by Ycode). The client is mapped into every process (shared
   cache), but no other process loaded the library.
3. **How.** `dlopen(<value of the variable>, RTLD_LAZY)`, then `dlsym` of
   **61 function names in a fixed order** (§3.1). A missing name aborts the
   process (SIGABRT, crash frames in the client's dispatch-table set-up
   under `SFBConnectionCreate`). An empty variable aborts with "Unable to
   load SimFramebuffer.framework" (`stage7-contract.md` §4). The client
   resolves no data symbols.
4. **Forwarding.** The client's own `SFB…` functions pass the caller's
   arguments to the library unchanged and return its result (the library
   sees the original caller's return address). The interface below is
   therefore also the interface QuartzCore calls.
5. Any arm64 platform-7 dylib at that path works. Our ad-hoc signed
   interposer (install name `@rpath/…`) and the headless prototype loaded
   without complaint.

## 3. Interface

### 3.1 Names the client requires (61, in resolution order)

`simFramebufferGetStructName`, `SFBConnectionGetTypeID`,
`SFBConnectionCreate`, `SFBConnectionConnect`, `SFBConnectionGetID`,
`SFBConnectionSetDisplayConnectedHandler`,
`SFBConnectionSetDisplayUpdatedHandler`,
`SFBConnectionSetDisplayDisconnectedHandler`, `SFBConnectionCopyDisplays`,
`SFBConnectionCopyDisplay`, `SFBConnectionCopyDisplayByUID`,
`SFBConnectionCreateDisplay`, `SFBConnectionUpdateDisplay`,
`SFBConnectionRemoveDisplay`, `SFBDisplayGetTypeID`, `SFBDisplayGetName`,
`SFBDisplayGetDisplayUID`, `SFBDisplayGetDeviceName`,
`SFBDisplayGetConnectionID`, `SFBDisplayGetPowerState`,
`SFBDisplayGetModeCount`, `SFBDisplayGetMode`, `SFBDisplayGetPreferredMode`,
`SFBDisplaySetCurrentMode`, `SFBDisplayGetCurrentMode`,
`SFBDisplayGetExtendedProperties`, `SFBDisplayCopyExtendedPropertyProtocols`,
`SFBDisplayGetDeviceSize`, `SFBDisplayGetCurrentCanvasSize`,
`SFBDisplayGetCanvasSizeCount`, `SFBDisplayGetCanvasSize`,
`SFBDisplaySetCanvasSize`, `SFBDisplaySetCurrentUIOrientation`,
`SFBDisplayGetSupportedSurfaceFlags`, `SFBDisplayGetFlags`,
`SFBDisplayGetSupportedPresentationModes`, `SFBDisplayGetID`,
`SFBDisplayGetType`, `SFBDisplayGetDotPitch`, `SFBDisplayGetMaxLayerCount`,
`SFBDisplayGetMaxSwapchainCount`, `SFBDisplayGetMaskPath`,
`SFBDisplaySetBacklightState`, `SFBDisplaySetBrightnessFactor`,
`SFBDisplayCreateSwapchain`, `SFBSwapchainGetTypeID`, `SFBSwapchainGetID`,
`SFBSwapchainGetDisplayID`, `SFBSwapchainGetConnectionID`,
`SFBSwapchainGetFramebufferSize`, `SFBSwapchainGetPixelFormat`,
`SFBSwapchainGetColorspace`, `SFBSwapchainGetHDRMode`,
`SFBSwapchainGetPresentationMode`, `SFBSwapchainAcquireSurfaceFence`,
`SFBSwapchainSwapBegin`, `SFBSwapchainGetMaxSurfacesPerOperation`,
`SFBSwapchainSwapAddSurface`, `SFBSwapchainSwapSetCallback`,
`SFBSwapchainSwapSubmit`, `SFBSwapchainSwapCancel`.

The other 71 exported functions are not resolved by the client: the
`simFramebufferMessage…` family (the library's wire layer to the server),
`simFramebufferServerPortName`, the `SFBSet…` helpers, and the internal
`_SFB…`/`__…` names. The exported data — `kSFBErrorDomain`
(= `"SimFramebufferClientErrorDomain"`), `kSFBSwapchainOptionUseFences`
(= `"UseFences"`), `kSFBDisplayOptionKeyApplyMask`
(= `"SFBDisplayOptionKeyApplyMask"`), `kSFBDisplayOptionKeyMaskPath`
(= `"SFBDisplayOptionKeyMaskPath"`), all CFStrings, and
`_SimFramebufferCrashBuffer` — is not resolved either.

### 3.2 Objects

Three CF types: **connection**, **display**, **swapchain**. Their
descriptions read `<SFBConnection 0x…>`, `<SFBDisplay 0x…>`,
`<SFBSwapchain 0x…>`. `…GetTypeID` returns the registered CF type id (a
run-time value, 0x48/0x49/0x4a in one process). `Create`/`Copy` results
follow the CF naming rule (+1); `Get` results are not retained (level 1
convention; not separately tested). Arrays are CFArrays of displays.

`error*` below is a `CFErrorRef *` out-parameter; callers pass a pointer to
NULL or NULL itself. On failure it receives a CFError in
`SimFramebufferClientErrorDomain` (§6).

### 3.3 Connection

| Function | Arguments | Result | Observed |
|---|---|---|---|
| `SFBConnectionCreate` | allocator (NULL), name: CFString | connection | names `CAWindowServer` (backboardd), `CoreSimulatorBridge`, `CoreSimulatorBridge.Orientation`. Contacts nothing |
| `SFBConnectionConnect` | connection, error* | Boolean | true. The real library looks up `com.apple.CoreSimulator.SimFramebufferServer` here (first use) |
| `SFBConnectionGetID` | connection | integer | 1 for a process's first connection, before and after connect |
| `SFBConnectionCopyDisplays` | connection, error* | CFArray of displays | 5 displays on iPhone Duo (§4) |
| `SFBConnectionCopyDisplay` | connection, display id, error* | display or NULL | returns the display with that `SFBDisplayGetID` |
| `SFBConnectionCopyDisplayByUID` | connection, CFString | display or NULL | matches the display UID **or** the device name; QuartzCore passes the device name `"resizable"` |
| `SFBConnectionSetDisplayConnectedHandler` | connection, dispatch queue, block | none | signature of the block: open |
| `SFBConnectionSetDisplayUpdatedHandler` | connection, dispatch queue, block | none | block type `v24@?0^{__SFBDisplay=}8Q16`, i.e. (display, 64-bit value). QuartzCore passes the main queue. Never invoked during boot |
| `SFBConnectionSetDisplayDisconnectedHandler` | connection, dispatch queue, block | none | signature of the block: open |
| `SFBConnectionCreateDisplay`, `…UpdateDisplay`, `…RemoveDisplay` | open | open | not called by the runtime |

### 3.4 Display

All take the display as the first argument.

| Function | Further arguments | Result |
|---|---|---|
| `SFBDisplayGetID` | — | integer, 1…n |
| `SFBDisplayGetConnectionID` | — | integer (1) |
| `SFBDisplayGetType` | — | integer: 0 built-in panel, 1 TV-out, 2 wireless, 4 resizable (§4) |
| `SFBDisplayGetName`, `…GetDeviceName`, `…GetDisplayUID` | — | CFString, not retained |
| `SFBDisplayGetPowerState` | — | integer (1 built-in, 0 others) |
| `SFBDisplayGetFlags` | — | integer (1 built-in, 0 others) |
| `SFBDisplayGetModeCount` | — | integer (1) |
| `SFBDisplayGetMode` | index, out: mode record | Boolean; writes §3.5 |
| `SFBDisplayGetPreferredMode`, `…GetCurrentMode` | out: mode record | writes §3.5; result register carries no value (the display argument comes back) |
| `SFBDisplayGetDeviceSize` | — | CGSize in d0/d1: panel pixels (0×0 for non-built-in) |
| `SFBDisplayGetCurrentCanvasSize` | — | CGSize in d0/d1: current canvas pixels |
| `SFBDisplayGetCanvasSizeCount` | — | integer (0 on every display) |
| `SFBDisplayGetCanvasSize` | index | CGSize (not exercised: count 0) |
| `SFBDisplayGetDotPitch` | — | integer, pixels per inch (460, 72, 120) |
| `SFBDisplayGetMaxLayerCount`, `…GetMaxSwapchainCount` | — | integer (1, 1) |
| `SFBDisplayGetSupportedPresentationModes` | — | integer (3) |
| `SFBDisplayGetSupportedSurfaceFlags` | — | integer (0x38) |
| `SFBDisplayGetMaskPath` | — | CFString host path of a PDF mask, or NULL |
| `SFBDisplayGetExtendedProperties` | out: record | Boolean; true only for the wireless display, which gets 21 bytes: u32 720, u32 480, u32 4, u32 1, u32 0, u8 0x80 (meanings open) |
| `SFBDisplayCopyExtendedPropertyProtocols` | — | CFArray (empty on every display) |
| `SFBDisplaySetBacklightState` | state, error* | Boolean; the bridge sends 2 (twice), error* NULL |
| `SFBDisplaySetCurrentUIOrientation` | orientation, error* | Boolean; the bridge sends 1 for each built-in display |
| `SFBDisplaySetCurrentMode`, `…SetCanvasSize`, `…SetBrightnessFactor` | open | not called in a boot |
| `SFBDisplayCreateSwapchain` | presentation mode, options: CFDictionary or NULL, error* | swapchain or NULL (§5) |

### 3.5 Mode record

Written by `GetMode`, `GetPreferredMode`, and `GetCurrentMode`: **35 bytes**
(byte 35 of a marker-filled buffer stays untouched), little-endian.

| Offset | Size | Observed values | Meaning |
|---|---|---|---|
| 0 | u32 | 1…5 (equal to the display id in every case) | mode id |
| 4 | u32 | 1398, 720, 2007, 7680 | width, pixels |
| 8 | u32 | 2034, 480, 2853, 4320 | height, pixels |
| 12 | u32 | 3 (built-in, resizable), 1 (TV-out, wireless) | scale |
| 16 | u32 | 1 always | open |
| 20 | u32 | 0x42475241 (`'BGRA'`) always | pixel format (FourCC). Must be `'BGRA'` (§7) |
| 24 | u32 | 2 (main panel), 1 (others) | open |
| 28 | u32 | 6000 always | probably refresh rate in 1/100 Hz (60 Hz); open |
| 32 | u8 | 1 built-in, 0 others | open |
| 33 | u8 | 1 | open |
| 34 | u8 | 1 | open |

### 3.6 Swapchain

| Function | Arguments | Result / observed |
|---|---|---|
| `SFBSwapchainGetID` | swapchain | integer; assigned by the server, increasing across clients (the probe got 3, 4, 5, 6) |
| `SFBSwapchainGetDisplayID`, `…GetConnectionID` | swapchain | integers |
| `SFBSwapchainGetFramebufferSize` | swapchain | CGSize in d0/d1 = the display's canvas size |
| `SFBSwapchainGetPixelFormat` | swapchain | 0x42475241 `'BGRA'` |
| `SFBSwapchainGetColorspace`, `…GetHDRMode` | swapchain | 1, 1 |
| `SFBSwapchainGetPresentationMode` | swapchain | the value given to `CreateSwapchain` |
| `SFBSwapchainGetMaxSurfacesPerOperation` | swapchain | 32 |
| `SFBSwapchainSwapBegin` | swapchain, target time (ticks), error* | Boolean |
| `SFBSwapchainSwapAddSurface` | swapchain, IOSurfaceRef, source CGRect (d0–d3), destination CGRect (d4–d7), two integers (0, 0; open) | Boolean |
| `SFBSwapchainSwapSetCallback` | swapchain, context pointer, pointer-size value (0; open), block | none |
| `SFBSwapchainSwapSubmit` | swapchain, error* | Boolean; against the real server it can block up to about 0.1 s |
| `SFBSwapchainSwapCancel`, `…AcquireSurfaceFence` | open | not called in a boot |

Completion block type: `v48@?0^{__CFError=}8^{__SFBSwapchain=}16Q24Q32^v40`,
i.e. (error or NULL, swapchain, 64-bit A, 64-bit B, context). Observed:
A = the target time given to `SwapBegin` (sometimes one tick less);
B = the completion time in ticks (0 when the swap failed); context = the
pointer given to `SwapSetCallback`. It runs on a serial queue of the
library (labels `com.apple.SimFramebuffer.<n>`), once per submitted swap.

Fences: the ObjC class `_SFBSwapSurfaceFence` (ivar `_group`, a dispatch
group; `-initReturningPort:` `@24@0:8^I16`; `-waitWithTimeout:`
`B24@0:8Q16`) and the option key `"UseFences"` belong to
`SFBSwapchainAcquireSurfaceFence`. The runtime does not use them (options
NULL).

## 4. Displays of the iPhone Duo device type (iOS 27.1)

Only the iPhone Duo device type could be created with the 27.1 runtime on
this Mac. Its server reports five displays. Display UIDs are per boot (one
later boot showed a different UID for display 1).

| Id | Type | Name | Device name | Mode | Device size | Canvas | Dot pitch | Power, flags | Mask path |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 0 | `LCD` | `primary` | 1398×2034 @3 | 1398×2034 | 1398×2034 | 460 | 1, 1 | yes |
| 2 | 1 | `TVOut` | `external-0` | 720×480 @1 | 0×0 | 720×480 | 72 | 0, 0 | no |
| 3 | 0 | `LCD-1` | `primary-1` | 2007×2853 @3 | 2007×2853 | 2007×2853 | 460 | 1, 1 | yes |
| 4 | 2 | `Wireless` | `wireless0` | 720×480 @1 | 0×0 | 720×480 | 72 | 0, 0 | no |
| 5 | 4 | `Resizable` | `resizable` | 7680×4320 @3 | 0×0 | 7680×4320 | 120 | 0, 0 | no |

Display 1 matches the device's `SIMULATOR_MAINSCREEN_WIDTH/HEIGHT/SCALE/PITCH`
(1398, 2034, 3, 460). Mask paths are host files
`/Library/Developer/DeviceKit/FramebufferMasks/<UUID>.pdf`.

## 5. Call order in a real boot

### 5.1 backboardd (QuartzCore window server)

About 0.45 s after `backboardd` starts, after its HID system is up
("Initializing CAWindowServer…" in its log), on the main thread:

1. `SFBConnectionCreate(NULL, "CAWindowServer")`, `SFBConnectionConnect(conn, &err)`.
2. `SFBConnectionCopyDisplays(conn, &err)`.
3. For each display in order: `GetType`, `GetDeviceName`, `GetType`,
   `GetName`, `GetCurrentMode`, `GetDeviceSize`, `GetCurrentCanvasSize`.
   For each display of **type 0**, before moving on:
   `SFBConnectionCopyDisplays(conn, NULL)`, `GetDisplayUID` (twice), then
   `SFBDisplayCreateSwapchain(display, 2, NULL, &err)`.
   Non-built-in displays get no swapchain.
4. `SFBConnectionCopyDisplayByUID(conn, "resizable")`, then
   `GetCurrentMode`, `GetDeviceSize`, `GetCurrentCanvasSize` on the result.
5. `SFBConnectionSetDisplayUpdatedHandler(conn, main queue, block)`.
6. From then on, on another thread, `GetDisplayUID` + `GetDotPitch` for
   every display, repeatedly (hundreds of times per boot).
7. Per frame, on a render thread, for one swapchain:
   `SwapBegin(sc, target time, &err)` →
   `SwapAddSurface(sc, surface, (0,0,W,H), (0,0,W,H), 0, 0)` →
   `SwapSetCallback(sc, context, 0, block)` → `SwapSubmit(sc, &err)`.
   The surfaces are IOSurfaces of W×H, `BGRA`, named `LCD`, alternating
   between a few ids. The first swap comes about 0.4 s after step 1. Frames
   are submitted only when content changes (88–370 per boot and launch).

### 5.2 CoreSimulator's bridge (not needed by Ycode)

`Create("CoreSimulatorBridge")`, `Connect(conn, NULL)`,
`CopyDisplays(conn, NULL)`, `SetBacklightState(display 1, 2, NULL)` twice,
`Create("CoreSimulatorBridge.Orientation")`, `Connect`, `CopyDisplays`,
`GetType` for each display, `SetCurrentUIOrientation(display, 1, &err)` for
both built-in displays.

## 6. Mach services and errors

- The library contacts exactly one Mach service:
  `com.apple.CoreSimulator.SimFramebufferServer` (also the string returned
  by `simFramebufferServerPortName`), with `bootstrap_look_up` on first use
  (at `Connect`). Display data, swapchain ids, and swap completions come
  from that server. Its message protocol was not studied (the
  `simFramebufferMessage…` exports suggest the layer).
- A replacement that implements §3 itself needs **no** service: the
  headless prototype imports no Mach or XPC function, and `backboardd`
  under it makes no framebuffer-server lookup. In a real boot no other
  `backboardd` code looked the server up (traced: `bootstrap_look_up` and
  XPC Mach-service connections; other lookup paths were not hooked).
- Errors (domain `SimFramebufferClientErrorDomain`):
  code 2 "Framebuffer invalid parameter value: swapchain_exists." (a second
  swapchain on one display); code 13 "The framebuffer server is not
  available or is disabled on this runtime: Mis-matched source and dest
  rects." (delivered through the swap callback, not by `SwapSubmit`, when
  the destination rect size differs from the source).

## 7. Minimal headless behavior (requirements, checked on the Mac)

Checked by booting a throwaway device with the headless prototype as
`SIMULATOR_FRAMEBUFFER_FRAMEWORK`: `backboardd` reported "initial main
screen size:{1398, 2034}", SpringBoard stayed up, and `simctl launch` of
Settings succeeded. Items marked *(tested)* were also varied on purpose.

1. **File.** An arm64 platform-7 dylib at the path in
   `SIMULATOR_FRAMEBUFFER_FRAMEWORK` that exports all 61 names of §3.1.
   Data symbols are not needed. *(tested: a missing name aborts.)*
2. **Objects.** Connections, displays, and swapchains are CF objects (the
   prototype registers three CF runtime classes, declarations from the CF
   open-source `CFRuntime.h`). Non-CF objects were not tried.
3. **Connect** succeeds without contacting anything; `GetID` = 1.
4. **One display** is enough: `CopyDisplays` returns a one-element array;
   `CopyDisplay(id)` and `CopyDisplayByUID` (UID or device name) find it.
   Values used: id 1, connection id 1, type 0, name `LCD`, device name
   `primary`, a fixed UID string, power 1, flags 1, mode count 1, device and
   canvas size = the configured pixel size, canvas count 0, dot pitch =
   `SIMULATOR_MAINSCREEN_PITCH`, max layers 1, max swapchains 1, presentation
   modes 3, surface flags 0x38, no mask path, no extended properties, empty
   protocol array.
5. **Mode record** as in §3.5 with width, height, and scale of the device
   (`SIMULATOR_MAINSCREEN_*`, pixels) and the other fields copied from
   display 1 of §4. *(tested: with pixel format 0x41524742 instead of
   `'BGRA'`, `backboardd` reports main screen size {0,0} and SpringBoard and
   UIKit apps trap in `BKSDisplayServicesStart`.)*
6. **CreateSwapchain** must succeed for the type-0 display.
   *(tested: refusing it with an error gives "failed SFBDisplayCreateSwapchain",
   screen size {0,0}, and the same traps.)* Swapchain getters return the
   values of §3.6 (framebuffer size = canvas size, `'BGRA'`, 1, 1, the mode
   given, 32).
7. **Swaps.** `SwapBegin`, `SwapAddSurface`, and `SwapSubmit` return true;
   `SwapSetCallback` keeps the block. The prototype calls each block once,
   asynchronously on its own serial queue, with (NULL, swapchain, target
   time, now, context). *(tested: never calling the blocks still let
   `backboardd`, SpringBoard, and Settings start; QuartzCore kept submitting.
   Whether surfaces are then never recycled over a long run is open, so
   completing every swap is the recommended behavior.)*
   Ycode's library completes every swap at once, asynchronously; under
   Ycode the render server does not wait for a frame's completion before
   starting the next one (`display-stream.md` §10.2, level 3), and its
   per-swap timing can be logged (`YCODE_DISPLAY_TIMING=1`, §10.1 there).
8. **Handlers** are stored and never called. Setters that only change state
   (backlight, orientation, brightness, mode, canvas size) return true.
   `CreateDisplay`, `UpdateDisplay`, `RemoveDisplay`, `AcquireSurfaceFence`
   may fail (NULL/false); the runtime does not call them.
9. **No Mach service** is contacted.

Requirements outside the library, found with the same boots (all host-side
names of `launchd-sim.md` §6.3, denied by our interposer in every process):

10. **IOSurface must work.** With `com.apple.IOSurface.Remote` unavailable
    (denied together with the framebuffer server and the Indigo port, which
    the headless library and an invalid HID path leave unused anyway),
    `backboardd` again reports screen size {0,0} even with the headless
    library, and SpringBoard traps in `BKSDisplayServicesStart`. Ycode's
    guest therefore needs a working IOSurface path before display services
    can start. This is a stage-7 blocker beyond the framebuffer library.
11. **Metal host services are not required** to start: with every
    `com.apple.metal.simulator*` name and `com.apple.gputools.service.simulator`
    unavailable, `backboardd`, SpringBoard, and Settings started. But
    `backboardd`'s Metal driver retried the lookup of
    `com.apple.metal.simulator.backboardd` about 1300 times in 50 s (CPU
    cost; a fast 1102 answer is cheap but frequent).
12. **SimulatorHID is not required** (§8).

## 8. SimulatorHID.framework (survey for stage 8)

- **Variable.** `SIMULATOR_HID_SYSTEM_MANAGER` holds the path of the
  **bundle directory**
  `…/Platforms/iphoneos/Library/Frameworks/SimulatorHID.framework`.
- **File.** arm64, platform 7, version 1174.9.2, bundle id
  `com.apple.CoreSimulator.SimulatorHID`, `NSPrincipalClass` = `SimHIDSystem`.
  Links Foundation, GraphicsServices, IOKit, the runtime's
  SimFramebufferClient, libMobileGestalt, QuartzCore, libobjc, libSystem,
  CoreFoundation. Its only exported symbols are the `SimHIDSystem` class
  and metaclass.
- **When.** `backboardd` loads it as a bundle (CFBundle) during "start HID
  system start…", after the HID event system is open and before the window
  server starts. The loader logs under the category `SimulatorClient`.
- **Entry point.** Protocol `SimulatorClientHIDSystemManager`, one required
  method `-initUsingHIDService:error:` (`@32@0:8^{__IOHIDEventSystem=}16^@24`),
  i.e. an IOHIDEventSystem and an `NSError **`. It throws
  `NSInternalInconsistencyException` ("Invalid parameter not satisfying:
  hidEventSystem") for NULL. `SimHIDSystem` keeps one ivar
  `_simulatorAppEventSource` (dispatch source).
- **Host service.** In a real boot it looks up `IndigoHIDRegistrationPort`
  (host-side, `launchd-sim.md` §6.3). It imports `mach_msg`, `NSMachPort`,
  and `NSConnection`; the message protocol was not studied.
- **Other classes** (ObjC metadata): `SimHIDVirtualServiceManager`
  (`-initWithEventSystem:`; `-serviceForIndigoHIDData:` and
  `-ensureServiceActiveForIndigoHIDData:`, whose argument type encodes the
  Indigo message layout; `-createMouseForID:`, `-createTrackpadForID:`,
  `-createDigitizerForTargetID:withDisplayUID:isBuiltIn:`,
  `-createCarplayServiceForTargetID:hasDigitizer:` and their `remove…`
  counterparts; DTUHID monitoring through notify), `SimHIDVirtualService`
  (`+serviceWithIdentifier:eventSystem:callbackDelegate:`,
  `+serviceWithIdentifier:eventSystem:properties:`, `-connect`,
  `-disconnect`, `-dispatchEvent:`), `SimHIDVirtualServicePropertyProvider`,
  `SimHIDCarPlayServiceCallbackProvider`,
  `SimHIDVirtualServiceSimulatorUpstreamProvider`, and protocol
  `SimHIDVirtualServiceCallbackDelegate` (all optional: `openService:`,
  `closeService:`, `copyProperty:service:`, `setProperty:value:service:`,
  `setEventCallback:target:refcon:service:`,
  `scheduleWithDispatchQueue:service:`,
  `unscheduleFromDispatchQueue:service:`, `copyEvent:matching:service:`,
  `setOutputEvent:`).
- **Virtual HID services created in a boot** (log identifiers
  `0xacefade0000000N`): `com.apple.SimulatorHID.GamePadService`,
  `.MainScreenButtonsService`, `.ExternalKeyboardService`,
  `.ProximitySensorService`, `.PalomaPoseService`,
  `.SelectionStreamService`, `.ManipulatorService`, and
  `.ScreenTouchService.<display UID>` (one per touch display).
- **Indigo message layout** (type encoding of the argument of
  `-serviceForIndigoHIDData:`, level 4, for stage 8): a structure of a
  32-bit value, a 64-bit value, a 32-bit value, then a union `_event` of
  `_extended`, `_touch_event`, `_pointer_event`, `_velocity_event`,
  `_wheel_event`, `_translation_event`, `_rotation_event`, `_scale_event`,
  `_dock_swipe_event`, `_button_event`, `_pointer_button_event`,
  `_accelerometer_event`, `_force_event`, `_gamecontroller_event`,
  `_generic_vendor_defined_event`, `_watch_gesture_event`,
  `_paloma_pose_event`, `_paloma_collection_event`, followed by a signed
  char, an unsigned char, two unsigned chars, and a 64-bit value. The full
  encoding string is in the R4 scratch dump `objcdump.txt`; a stage-8 spec
  should restate it field by field.
- **Not needed to start.** With the variable pointing at a nonexistent
  path, `backboardd` logs "Failed to initialize HID services: Failed to
  bundle, <path>" and "BKHID: Unable to open Indigo HID system", then
  continues; SpringBoard and Settings start. Ycode can leave the variable
  empty or invalid in stage 7.

## 9. Open questions

1. Meanings of mode-record offsets 16, 24, 32–34, and whether offset 28 is
   the refresh rate; whether QuartzCore needs any of them (the prototype
   copies observed values).
2. The 64-bit argument of the display-updated block, and the block
   signatures of the connected/disconnected handlers. When the server
   invokes them (not in a plain boot).
3. The two trailing integer arguments of `SwapAddSurface` and the third
   argument of `SwapSetCallback`.
4. Arguments of `CreateDisplay`, `UpdateDisplay`, `RemoveDisplay`,
   `SetCurrentMode`, `SetCanvasSize`, `SetBrightnessFactor`,
   `AcquireSurfaceFence`, `SwapCancel`, `GetCanvasSize`,
   `simFramebufferGetStructName`.
5. Whether a non-retained result is expected from `CopyDisplayByUID` (CF
   rule says +1; unverified).
6. Long-run behavior when swaps are never completed (§7 item 7).
7. The server wire protocol (`simFramebufferMessage…`) and the Indigo HID
   registration protocol: needed only when Ycode presents real frames or
   injects touches (stage 8).
8. How IOSurface reaches the host (`com.apple.IOSurface.Remote`) and what
   Ycode's guest must provide for §7 item 10: proposed as a separate
   research task before stage 7 continues.

## Evidence

| Claim | Level | Source |
|---|---|---|
| File properties, links, exported names and data (§1, §3.1 list of non-required names) | 4 | `otool -L/-l`, `nm -gU`, `nm -u`, `plutil -p Info.plist` of the CoreSimulator frameworks |
| Values of the exported CFString constants | 3 | our interposer reading them with `dlsym` at load time |
| Variable values (§2.1, §8) | 3 | `ps -E` of a running `backboardd`; our interposer's constructor |
| Loader, lazy load, `RTLD_LAZY`, 61 names in order, abort on missing name, no data symbols (§2, §3.1) | 3 | `dlsymtrace.c` inserted into our own probe process calling the client; a boot with an interposer that exports only 18 names (crash report frames and abort) |
| Only backboardd and the bridge load the library | 3 | `vmmap` image lists of the device's processes |
| Unchanged forwarding by the client (§2.4) | 3 | interposer return-address image and arguments identical to direct calls |
| ObjC classes, ivars, selectors, type encodings, block signatures (§3.6, §8) | 4 | `objcdump.m` (ObjC runtime API on the loaded frameworks); block signatures from the block descriptors of blocks passed to our interposer |
| Arguments, results, out-record layouts, values, ids, errors (§3.3–§3.6, §4, §6) | 3 | `sfbprobe.c` calls with marker-filled buffers on a throwaway device; `sfbtrace` interposer logs of real boots |
| Call order and timing (§5) | 3 | `sfbtrace` interposer as `SIMULATOR_FRAMEBUFFER_FRAMEWORK` in three boots, plus one Settings launch |
| Mach services contacted (§6, §8) | 3 | `dlsymtrace.c` inserted into every job of a boot, logging only in `backboardd`; and in our probe |
| Requirements and the deny/refuse experiments (§7) | 3 | boots with `sfbheadless.c` (and its `SFBH_NO_CALLBACK`, `SFBH_NO_SWAPCHAIN` switches), `dlsymtrace.c` deny lists, `backboardd` log lines, crash reports, `simctl launch` |
| CF object model, ownership convention | 1 | CF open source `CFRuntime.h`; CF Create/Copy/Get naming rule |
| HID loading and not-needed result (§8) | 3 | `backboardd` log lines; boot with a nonexistent HID path; `hidprobe.m` |
| Under Ycode, swaps are not held back by completions; SwapBegin's target equals the call time (§7 item 7) | 3 | Ycode runs on the Thor with the library's swap timing log (`display-stream.md` §10.2) |

No disassembly or decompilation was used (level 5 not used); no Xcode
binary, `research/dirty/`, or Ghidra project was opened. Crash reports and
log lines were read as black-box output. One deviation, corrected: the first
interposer run printed 32 bytes at each argument pointer, and some pointers
were in executable pages. Those bytes were never analyzed, were replaced by
a placeholder in the raw log, and the tool was changed to refuse to read
executable memory before any further run.

## Appendix A. Programs and method

Sources (ours) in `research/experiments/simulator/simframebuffer/`;
`build.sh <out>` builds everything for `arm64-apple-ios27.0-simulator`
outside the repo.

| File | What it is |
|---|---|
| `gen_tramps.sh` | generates one forwarding stub per exported function name (`nm -gU`), optionally only for an allowlist |
| `tramp_common.s`, `sfbtrace.c` | the tracing interposer: saves x0–x8 and d0–d7, logs the call (caller image, values, CF/ObjC descriptions, C strings, non-executable memory), calls the real function, logs x0/x1/d0–d3 and changed argument memory; wraps block arguments to log their invocations and signatures |
| `backboardd-used.txt` | the 18 names `backboardd` calls (allowlist for the export experiment) |
| `sfbprobe.c`, `rawcall.s` | direct client: calls exported functions by name with chosen registers, marker buffers, forked children for risky calls; swapchain and swap tests |
| `dlsymtrace.c` | `DYLD_INSERT_LIBRARIES` logger of `dlopen`, `dlsym`, `bootstrap_look_up`, XPC Mach connections, with a per-process filter and a deny list |
| `objcdump.m` | ObjC metadata lister |
| `hidprobe.m` | loads the HID bundle and calls its manager initializer |
| `sfbheadless.c` | the headless prototype (§7) |

Method: a throwaway iPhone Duo device on the 27.1 runtime, booted with
`SIMCTL_CHILD_SIMULATOR_FRAMEBUFFER_FRAMEWORK=<our dylib>` (`simctl boot`
passes `SIMCTL_CHILD_` variables into the device's job environment and
they override CoreSimulator's value; the same prefix on `simctl spawn`
does **not** override this variable). Probes were run with `simctl spawn`
from `/tmp`. Raw logs stayed in the session scratch directory; the device
was deleted afterwards.
