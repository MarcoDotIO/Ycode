# Spec: simulator input (touch, hardware keyboard, hardware buttons)

Status: **normative for SIM-VIEWER** (input part), 2026-10-19. Reference:
Xcode 27.1, CoreSimulator 1174.9.2, iOS 27.1 runtime (24A94401). It answers
how Xcode's Simulator gets mouse, keyboard, and button input into the guest,
and specifies what Ycode builds instead. Raw observations:
`research/notes/hid-input-observations.md`. Our probes and the prototype:
`research/experiments/simulator/hid/` (Appendix A).

Sections marked **Ycode decision** are design choices for Ycode's own two
ends (host and guest), not facts about Xcode. Everything else is observed or
documented; the Evidence section gives the level of each claim.

Terms:

- **Event system**: the HID event system that backboardd creates and owns
  (an `IOHIDEventSystem` object inside backboardd). Services publish
  events into it; backboardd routes them to SpringBoard and apps.
- **Virtual service**: a HID service that exists only in user space, created
  inside the event-system process with a table of callbacks (§4).
- **The bundle**: the code bundle named by `SIMULATOR_HID_SYSTEM_MANAGER`.
- **Normalized point**: x and y in 0…1, origin at the top-left corner of the
  display in its native (portrait) orientation.
- `ticks`: guest `mach_absolute_time` units. Ycode's guest timebase is
  24 MHz.

## 1. How input reaches the guest in Xcode's Simulator

1. **Receiver.** Input enters the guest in **backboardd**. During its "start
   HID system start…" step (about 0.3 s after it starts, after the event
   system is open and before the window server starts), backboardd's
   `SimulatorClient` code loads the bundle named by
   `SIMULATOR_HID_SYSTEM_MANAGER` as a CFBundle and calls one initializer on
   its principal class, passing backboardd's event system.
2. **The bundle is CoreSimulator's, not the runtime's.** The variable names
   the **bundle directory**
   `…/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/Frameworks/SimulatorHID.framework`
   (principal class `SimHIDSystem`). The runtime contains the loader
   (`SimulatorClient.framework`) but no HID bundle. Ycode cannot ship
   Apple's bundle.
3. **What the bundle does.** It creates virtual HID services inside the
   event system (gamepad, main-screen buttons, external keyboard, proximity
   sensor, three vendor-defined sensor services, and one touch screen per
   display), then turns host messages into HID events and dispatches them
   from those services. backboardd treats them like hardware: it reads
   their properties, matches them by usage, scales digitizer positions to
   the display, and routes events (touches by hit test and system gestures,
   keys to the keyboard focus, buttons to SpringBoard).
4. **Transport (reference).** The bundle looks up the host-side Mach name
   **`IndigoHIDRegistrationPort`** (one of the host names CoreSimulator
   registers in the guest bootstrap, `launchd-sim.md` §6.3) and receives
   **Indigo** messages from Simulator.app or SimulatorKit's
   `SimDeviceLegacyHIDClient`. Each message is a Mach message with a
   32-bit inner size (0xA0), a message type, and one or more 0xA0-byte
   payload records (kind, host `mach_absolute_time`, then a union of touch,
   button, wheel, pointer, force, game controller, and other events). The
   layout is documented by Meta's idb; Appendix B summarizes what Ycode
   needs to know of it. Ycode does **not** implement Indigo (§7 explains).
5. **A second, newer path.** CoreSimulator also ships a guest daemon
   `dtuhidd` (job `com.apple.coredevice.dtuhidd`, Mach services
   `com.apple.coredevice.feature.remote.hid.{digitizer,button,keyboard,vendordefined}`
   and two `universalhid` names) that receives XPC dictionaries and injects
   events through client-side virtual services. While it is active it sets
   the notify state `com.apple.coredevice.dtuhidd.active`, and the bundle
   disconnects its own touch/button/keyboard services. This daemon is also
   a CoreSimulator file; Ycode does not run it, so the notify state stays
   unset.
6. **Orientation and lock** have a separate legacy path: a GraphicsServices
   event Mach message to the guest's `PurpleWorkspacePort` (§10).

## 2. What Ycode must provide

| Piece | Where | Replaces |
|---|---|---|
| **Ycode HID bundle** (§3–§6) | guest; loaded by backboardd through `SIMULATOR_HID_SYSTEM_MANAGER` | `SimulatorHID.framework` |
| **HID host service** (§7) | `ycode-simd` (VMM host task), one Mach name in the guest bootstrap | `IndigoHIDRegistrationPort` and SimulatorKit's client |
| **Viewer input mapping** (§8) | the Ycode simulator window | Simulator.app's input view |

The bundle uses only interfaces that the runtime's own IOKit exports (the
virtual-service and event-creation functions of §4–§5). Nothing else in the
runtime has to change; backboardd, SpringBoard, and UIKit do the rest.

`ycode-simd` sets `SIMULATOR_HID_SYSTEM_MANAGER` to the guest path of the
bundle **directory** (the framebuffer variable names the binary; this one
names the directory). An empty or invalid value keeps today's behavior:
backboardd logs "Failed to initialize HID services" and "BKHID: Unable to
open Indigo HID system" and continues without input (`simframebuffer.md` §8).

## 3. The bundle: loading contract

1. **Layout.** A directory (Ycode decision: `SimHID.framework`) holding
   `Info.plist` and the executable. Info.plist keys: `CFBundleExecutable`
   (the executable's file name), `CFBundleIdentifier` (a Ycode identifier,
   e.g. `dev.ycode.SimHID`), `CFBundlePackageType` `FMWK`,
   `CFBundleInfoDictionaryVersion` `6.0`, and **`NSPrincipalClass`** naming
   the class of item 2. The executable is an arm64 Mach-O dylib for the iOS
   simulator platform (platform 7), like Ycode's framebuffer library.
2. **Principal class.** An Objective-C class, subclass of `NSObject`, that
   adopts a protocol named **`SimulatorClientHIDSystemManager`** and
   implements one instance method, **`initUsingHIDService:error:`**: argument
   1 is the event system (a CF object pointer, `IOHIDEventSystemRef`),
   argument 2 is an out-pointer for an `NSError`; it returns the
   initialized object or nil. Type encoding `@32@0:8^{__IOHIDEventSystem=}16^@24`.
   The protocol does not exist in the runtime unless the bundle defines it;
   the bundle must define (or create at load time) a protocol with that name
   and declare conformance, because whether the loader checks conformance is
   not known (§13). The class may be created at image load time with the
   Objective-C runtime functions; it must exist before the loader asks the
   bundle for its principal class.
3. **Call.** The loader allocates an instance and calls the initializer on
   backboardd's main thread. A NULL event system must fail (return nil with
   an error); the reference raises an assertion instead.
4. **Lifetime.** backboardd keeps the returned object for its lifetime. The
   bundle never unloads. When backboardd exits, everything goes with it; the
   next backboardd loads the bundle again (§7 item 5).
5. **Threading.** The initializer must return quickly: create the
   non-display services (§4.3), start the host transport (§7), and do the
   rest on the bundle's **own serial dispatch queue**. All event creation and
   dispatch happens on that queue, one message at a time, in arrival order.
6. **Failure.** If the host service cannot be found, the bundle still
   publishes its services and returns success; input simply never arrives.
   It logs one line (os_log, subsystem of Ycode's choosing).

## 4. Virtual services

### 4.1 Creating one

Three functions, all exported by the runtime's IOKit (names and roles as
in Apple's IOHIDFamily and IOKitUser open source):

| Function | Arguments | Result |
|---|---|---|
| `_IOHIDServiceCreateVirtual` | allocator; 64-bit **service ID**; pointer to the callback table (§4.2); `target` pointer; `refcon` pointer | a new service object (CF, +1) |
| `_IOHIDEventSystemAddService` | event system; service | none; the event system calls the callbacks synchronously during this call |
| `_IOHIDServiceDispatchEvent` | service; event | none; publishes the event from that service |

`_IOHIDEventSystemRemoveService` (event system, service) also exists for
removing one (used only for §9).

The **service ID is the sender ID** of every event the service dispatches
(backboardd logs `senderID` equal to it). Ycode decision: IDs
`0x59434F4400000001` and up (ASCII "YCOD" in the high half), fixed per
service kind so they are stable across boots: 1 buttons, 2 keyboard,
3 built-in touch screen.

### 4.2 The callback table

Nine function pointers in this order; each receives `target` and `refcon`
first. The bundle keeps one mutable property dictionary per service.

| # | Callback | Further arguments | Required behavior |
|---|---|---|---|
| 1 | open | options | return true |
| 2 | close | options | nothing |
| 3 | copyProperty | key (CFString) | the value for key from the dictionary, **retained** (+1), or NULL |
| 4 | setProperty | key, value | store value under key (replace), return true. The event system sets `DeviceOpenedByEventSystem`, `LogLevel`, and on the keyboard `CapsLockDelayOverride`; later reads must return what was stored. |
| 5 | setEventCallback | callback, callback target, callback refcon | store them (not needed when dispatching with `_IOHIDServiceDispatchEvent`) |
| 6 | scheduleWithDispatchQueue | queue | nothing |
| 7 | unscheduleFromDispatchQueue | queue | nothing |
| 8 | copyEvent | event type, matching event, options | return NULL |
| 9 | setOutputEvent | event | return `kIOReturnUnsupported` (0xE00002C7). Keyboard LED output (caps lock) may be ignored. |

Callbacks can run on backboardd threads other than the bundle's queue; the
property dictionary must be locked.

### 4.3 The services Ycode publishes

Property dictionaries (all keys are CF strings; numbers are CFNumbers;
`DeviceUsagePairs` is an array of one dictionary with `DeviceUsagePage` and
`DeviceUsage` equal to the primary pair):

| Service | ID (§4.1) | `PrimaryUsagePage` / `PrimaryUsage` | Other keys | backboardd treats it as |
|---|---|---|---|---|
| Buttons | …01 | 0x0B (11) / 1 | `Built-In` true, `Authenticated` true, `PressCountTrackingEnabled` true, `PressCountUsagePairs` [0x000C0040] | main-screen buttons (home, lock, side, volume) |
| Keyboard | …02 | 1 / 6 | `Product` (any string) | external hardware keyboard |
| Touch screen | …03 | 0x0D (13) / 4 | `Built-In` true, `DisplayIntegrated` true, `Authenticated` true, **`displayUUID`** (§6), `Product` | the main display's digitizer |

Create buttons and keyboard in the initializer, and the touch screen once
the display UUID is known (§6). The reference also publishes a gamepad
(1/5), a proximity sensor (0xFF00/8), and three vendor-defined services
(0xFF00/0x6F, 0x71, 0x72); Ycode does not need them for touch, keys, or
buttons (the prototype ran without them, §12). One touch screen per display
in the reference; Ycode has one display, so one touch screen.

## 5. Events

Event objects are created with the runtime's IOKit event constructors and
dispatched with `_IOHIDServiceDispatchEvent` from the matching service. The
bundle releases each event after dispatch.

### 5.1 Timestamps and ordering

- Every event carries a timestamp in **guest ticks**: the bundle reads the
  guest's `mach_absolute_time` when it creates the event (Ycode: the 24 MHz
  guest timebase that UIKit also reads). Host times are never passed
  through. A parent event and its children share one timestamp.
- Timestamps from one service never decrease. Events are dispatched in the
  order the host sent them (one serial queue, §3 item 5).

### 5.2 Touch (digitizer) events

One host touch message (§7.3) becomes **one parent event with one child per
contact**, dispatched from the touch-screen service.

Constructors (argument order as in WebKit's public SPI declarations):

| Constructor | Arguments in order |
|---|---|
| `IOHIDEventCreateDigitizerEvent` | allocator, timestamp, transducer type, index, identity, event mask, button mask, x, y, z, tip pressure, barrel pressure, range (bool), touch (bool), options |
| `IOHIDEventCreateDigitizerFingerEvent` | allocator, timestamp, index, identity, event mask, x, y, z, tip pressure, twist, range (bool), touch (bool), options |
| `IOHIDEventAppendEvent` | parent, child, options (0) |
| `IOHIDEventSetIntegerValue` | event, field, value |

**Parent:** transducer type **hand (3)**; index 0; identity 0; button mask
0; x, y = the centroid of the children that are touching (or of all
children when none is touching); z, pressures 0; range = OR of the
children's range; touch = OR of the children's touch; event mask = OR of the
children's masks; options 0. Set field **`kIOHIDEventFieldDigitizerIsDisplayIntegrated`
(0xB0019) to 1**.

**Child (one per contact):** a finger event with:

| Field | Value |
|---|---|
| index | the host's contact slot, 1-based (backboardd logs it as "pathIndex") |
| identity | a per-contact number the bundle assigns at the contact's start from a counter that starts at 1 and never repeats within a boot; constant until the contact ends |
| x, y | normalized point (§5.3) |
| z | 0 |
| tip pressure | 0.5 while touching, 0 at the end (Ycode decision; any value in 0…1 worked) |
| twist | 90 (the value the reference builder writes) |
| range, touch | 1, 1 while down or moving; 0, 0 at end or cancel |
| event mask | from the table below |

Event mask bits (IOHIDFamily `IOHIDDigitizerEventMask`):

| Contact phase | Mask | range / touch |
|---|---|---|
| began | Range 0x1 \| Touch 0x2 = **0x3** | 1 / 1 |
| moved (position changed) | Position **0x4** | 1 / 1 |
| unchanged (another contact moved) | 0 | 1 / 1 |
| ended | **0x3** | 0 / 0 |
| cancelled | Cancel 0x80 \| 0x3 | 0 / 0 |

**Edge contacts.** A contact that the host marks as starting at a screen
edge (§8.2) carries, on **every** event of that contact (began, moved,
ended), the swipe-locked bit plus one direction bit, ORed into its mask
(and so into the parent's):

| Edge the contact starts at | Bits | Meaning (IOHIDFamily names) |
|---|---|---|
| bottom | 0x01040000 | SwipeUp (1<<24) \| SwipeLocked (1<<18) |
| top | 0x02040000 | SwipeDown (1<<25) \| SwipeLocked |
| right | 0x04040000 | SwipeLeft (1<<26) \| SwipeLocked |
| left | 0x08040000 | SwipeRight (1<<27) \| SwipeLocked |

SpringBoard's system gestures (home/app switcher from the bottom, Control
Center and Notification Center from the top, back-swipe from the left)
depend on these bits, **not** on the coordinates: the same bottom-to-middle
drag without them scrolls the app; with them it goes home.

**Multi-touch.** Up to 5 contacts (Ycode decision; the viewer uses 2). All
contacts that are down (and those ending in this message) appear as
children of the same parent, each with its own index and identity. A
contact's ended message is the last one that contains it.

### 5.3 Coordinates

- x, y are **normalized** to the display: x = pixel column / display width
  in pixels, y = pixel row / display height in pixels, both in 0…1, origin
  top-left, in the display's native portrait orientation regardless of the
  interface orientation. backboardd multiplies by the display size: on the
  1398 × 2034 @3 display, (0.121, 0.125) arrives at SpringBoard's gesture
  stream as (169, 254) pixels and at the app as (56.33, 84.67) points.
- Values outside 0…1 are clamped by the host before sending.

### 5.4 Keyboard events

From the keyboard service: `IOHIDEventCreateKeyboardEvent` with
(allocator, timestamp, usage page, usage, down (bool), options 0). Usage
page **7** (Keyboard/Keypad), usage from the USB HID Usage Tables (Appendix
C). One event per key down and one per key up. **Modifiers are their own
keys** (usages 0xE0–0xE7), sent down before and up after the key they
modify, exactly as a USB keyboard reports them; backboardd tracks modifier
state itself. Usages are positions, not characters: the guest applies the
keyboard layout (backboardd reports layout US by default).

### 5.5 Hardware buttons

From the buttons service, a keyboard event (§5.4 constructor) with usage
page **0x0C** (Consumer) and:

| Button | Usage | backboardd's name | Result seen |
|---|---|---|---|
| Home | 0x40 | Home | to SpringBoard: goes home; press counting enabled (double press) |
| Lock / sleep-wake (power) | 0x30 | Lock | to SpringBoard: locks, or wakes the display |
| Side button | 0x95 | Side | accepted; no destination on the reference device type |
| Volume up / down | 0xE9 / 0xEA | VolumeIncrement / VolumeDecrement | accepted; no destination in the reference boot |
| Siri (voice command) | 0xCF | — | not tested |
| Play/Pause | 0xCD | — | not tested |

Down, then up. A long press is a longer hold (SpringBoard measures it);
Apple Pay is a double side press. The reference dispatches volume from the
touch-screen service, not the buttons service; Ycode sends all buttons from
the buttons service (§13).

## 6. Display association

- The touch-screen service's **`displayUUID`** must equal the unique id of
  the built-in display as QuartzCore reports it in backboardd (the
  `uniqueId` of the main `CADisplay`, named `LCD`/`primary`). The bundle
  reads it on its own queue (it was available at once in the prototype),
  retrying every 50 ms for up to 10 s, and only then creates the touch
  service. In Ycode this id comes from the framebuffer library's built-in
  display UID (`simframebuffer.md` §3; Ycode's library returns the constant
  `59434F44-4500-4000-8000-000000000001`); if the lookup fails, the bundle
  uses that constant.
- **Without `displayUUID`**, backboardd still accepts the digitizer as the
  main-display digitizer and hit-tests, but delivers every touch at (0, 0)
  and opens no system-gesture stream: taps hit the wrong place and edge
  gestures fail.
- `DisplayIntegrated` true and `Built-In` true make backboardd treat it as
  the built-in direct-touch screen ("touchScreen; builtin; displayIntegrated").

## 7. Host → guest transport (Ycode decision)

Both ends are Ycode's, so Ycode uses its own small Mach protocol instead of
Indigo. Reasons: Indigo payloads contain fields whose meaning is not known
(Appendix B), its builders are Apple host code, and Ycode's VMM already
serves host Mach services (as for `com.apple.IOSurface.Remote`).

1. **Name.** `ycode-simd` serves **`dev.ycode.simulator.hid`** from the VMM's
   host task and registers it in the guest bootstrap like its other host
   services (701 before jobs start). It does not offer
   `IndigoHIDRegistrationPort` (lookups keep answering 1102).
2. **Registration (guest → host).** The bundle allocates a receive right,
   looks up the name, and sends one message: `msgh_id` **0x59480001**,
   complex, one port descriptor carrying a **send right (make-send)** to its
   receive right, then a body of two 32-bit little-endian words: protocol
   version **1**, flags 0. No reply. The bundle receives on its port with a
   dispatch Mach receive source targeting its serial queue.
3. **Events (host → guest).** The host sends to the registered port:
   `msgh_id` **0x59480002**, not complex, body little-endian:

   | Offset in body | Size | Field |
   |---|---|---|
   | 0 | 4 | version = 1 |
   | 4 | 4 | kind: 1 touch, 2 key, 3 button, 4 keyboard attach, 5 orientation |
   | 8 | 8 | sequence number (host counter, for logs) |
   | 16 | … | kind-specific (below) |

   - **Touch (1):** 4 bytes display (0 = built-in), 4 bytes contact count n
     (1…5), then n records of 32 bytes: 4 index (1-based slot), 4 phase
     (1 began, 2 moved, 3 unchanged, 4 ended, 5 cancelled), 4 edge (0 none,
     1 top, 2 left, 3 bottom, 4 right), 4 reserved 0, 8 x (IEEE double),
     8 y (IEEE double). Body size 24 + 32 n.
   - **Key (2)** and **Button (3):** 4 usage page, 4 usage, 4 down (1) or
     up (0), 4 reserved. Body size 32.
   - **Keyboard attach (4):** 4 attached (1/0), 4 reserved (§9).
   - **Orientation (5):** 4 UIDeviceOrientation value 1–4, 4 reserved (§10).

   The guest checks `msgh_size`, version, kind, and count, and drops a
   malformed message with one log line. Unknown kinds are ignored.
4. **Invariants.** One host sender per device. Messages are not batched
   across kinds. For each contact slot the host sends exactly one began,
   then moved/unchanged, then exactly one ended or cancelled; a slot is not
   reused until its contact has ended. Moves are coalesced to at most one
   touch message per display frame (60 Hz); began, ended, cancelled, keys,
   and buttons are never dropped or coalesced. The host sends a key's up
   before sending the same key's next down.
5. **Restart.** A send failing with a dead port (backboardd exited) clears
   the registration; the next backboardd's bundle registers again, and a
   new registration replaces the old one. Contacts and keys that were down
   are forgotten on both sides (the host shows no stuck state).
6. **Snapshots** (`snapshot.md` §2.6, §12.4): the registration is a send
   right in the host task's Mach space, and a snapshot captures that space
   with its names. A snapshot therefore records the registration as a
   host-service record `hid` (the host-task name of the send right; no
   record while no bundle has registered). The restored run's service takes
   that name back before any guest thread runs and delivers input at once;
   the bundle is not asked to register again (it registered once, in the
   run that was saved, and keeps its receive right). A restore whose
   snapshot has no `hid` record logs that the device takes input only after
   its bundle registers. Contacts, keys and buttons are released before a
   stop's save (the viewer is gone or told the device is stopping, §7.5), so
   a restored device has none held.

## 8. The viewer: mapping host input (Simulator.app parity)

### 8.1 Mouse as touch

- Left button down inside the screen image: contact slot 1 **began** at the
  normalized point (window position → display pixel through the image's
  current scale and offset, then divided by the display size). Dragging:
  **moved** (coalesced, §7 item 4). Button up: **ended** at the last
  position. Leaving the screen image while dragging clamps the position to
  the edge; the contact ends only on button up. Window losing focus or the
  device stopping while a contact is down: **cancelled**.
- Tap, swipe, and long press need nothing special: they are a short
  down/up, a fast drag, and a held button. Timing belongs to the guest.

### 8.2 Edges

A contact is an edge contact if its began point lies within **10 points**
(30 pixels at scale 3) of a display edge (Ycode decision; Simulator.app's
exact threshold is not known). Corners: the nearer edge wins, bottom before
top on ties. The edge is fixed for the life of the contact.

### 8.3 Two-finger gestures

As in Simulator.app: holding **Option** shows two touch points mirrored
through a pinch center (initially the screen center); Option-drag sends two
contacts (slots 1 and 2), the second at the mirror image of the pointer
(for center (cx, cy): (2cx − x, 2cy − y)), giving pinch and rotate. Holding
**Shift** as well moves the pair (the pinch center) without changing their
distance; pressed with the button down, both contacts move together, a
two-finger pan.

### 8.4 Keyboard

When the simulator window has keyboard focus and the hardware keyboard is
connected (§9), every host key down and up is sent as a page-7 usage
(Appendix C), modifiers included. Keys bound to viewer commands are not
forwarded. Simulator.app's bindings, which the viewer should mirror:
Home ⇧⌘H, Lock ⌘L, Rotate left ⌘←, Rotate right ⌘→ (on Linux hosts, the
viewer's own equivalents). Key repeat is the guest's: the host sends no
repeats, only the held down.

### 8.5 Buttons

Viewer controls (toolbar or menu) for Home, Lock, Side, Volume up/down
(Siri optional) send §5.5 usages: down, then up 100 ms later; a "long
press" control holds 1 s.

## 9. Hardware keyboard state

- A service with usage page 1 / usage 6 present ⇒ backboardd logs "Keyboard
  attached" and "Hardware keyboard attached (countryCode:0 type:-1
  layout:US)", and `GSEventIsHardwareKeyboardAttached` returns 1 in every
  process. With it attached, text fields show **no on-screen keyboard** and
  take typed keys (Spotlight test, §12). This is the reference's default:
  the keyboard is attached from boot.
- "Connect Hardware Keyboard" off (viewer setting, Ycode default **on**): the
  host sends keyboard attach 0; the bundle removes the keyboard service with
  `_IOHIDEventSystemRemoveService` and the host stops forwarding keys. On
  attach 1 the bundle adds it again (same ID). Whether removal flips the
  guest's state to "no hardware keyboard" and brings back the on-screen
  keyboard is not yet verified (§13).
- Optional property `CountryCode` (number) on the keyboard service selects
  the keyboard's country; absent means 0 (US layout in the reference).

## 10. Rotation (experimental)

The reference's legacy path is a GraphicsServices event message to the
guest's `PurpleWorkspacePort` (a SpringBoard Mach service): 108 bytes,
`msgh_bits` 0x13, `msgh_id` 0x7B (123), event type 50 (device orientation
changed) ORed with the host flag 0x20000 at body offset 0 (message offset
0x18), record size 4 at message offset 0x48, and the UIDeviceOrientation
(1 portrait, 2 upside down, 3 landscape right, 4 landscape left) at 0x4C.
In Ycode the bundle can send it itself when it gets an orientation message
(§7 kind 5), after looking up `PurpleWorkspacePort` in the guest bootstrap.
On the reference the message was accepted, but a visible rotation was not
confirmed (§13). Rotation is not required for the first input milestone.

## 11. Not needed

- Apple's `SimulatorHID.framework`, `dtuhidd`, `dthidd`, SimulatorKit, and
  `IndigoLegacyHIDServices.simdeviceio` (all CoreSimulator/Xcode files).
- The Indigo wire format and `IndigoHIDRegistrationPort`.
- The gamepad, proximity, and vendor-defined services; the
  `com.apple.iphonesimulator.upstream` property service; the state file
  `/var/run/SimHIDDynamicServices.plist`.
- HID client entitlements: virtual services added from inside backboardd
  need none.

## 12. Test plan

Prototype status: `hidproto.m` (Appendix A), written from this spec,
replaced Apple's bundle on the Mac's simulator and passed items 1–4 and 6
(touch, home, lock, key routing, edge swipe; Settings opened from a tap).

On Ycode (Thor), after a full boot to the home screen:

1. **Load.** backboardd's log shows the three services added, "Hardware
   keyboard attached", and "digitizer attached (sender 0x59434F4400000003)"
   with "builtIn: YES; displayIntegrated: YES"; no "Unable to open Indigo
   HID system".
2. **Tap launches an app.** Tap the Settings icon's center (normalized
   position from a screenshot). Within 5 s `launchctl list` in the guest
   shows `UIKitApplication:com.apple.Preferences…` and a screenshot shows
   Settings. backboardd debug log: the touch arrives in points at the app
   and in pixels at SpringBoard's gesture stream, not at (0, 0).
3. **Scroll.** Drag from (0.5, 0.8) to (0.5, 0.3) without edge: the Settings
   list scrolls.
4. **Swipe home.** With Settings open, drag from (0.5, 0.995) to (0.5, 0.55)
   in 12 steps of 16 ms with edge = bottom: the home screen returns.
   Repeat without edge: it only scrolls.
5. **Spotlight typing.** On the home screen tap the search button (or drag
   down from the middle of the screen), then type "set" (usages 0x16, 0x08,
   0x17): results for Settings appear and no on-screen keyboard is drawn.
   Shift + letter gives a capital.
6. **Buttons.** Home from an app returns to the home screen; Lock turns the
   display off (lock screen on the next press); home double press opens the
   app switcher.
7. **Long press.** Hold on an app icon for 1 s: the context menu appears.
8. **Pinch.** In Photos or Maps, Option-drag outward: content zooms.
9. **Latency.** From host send to backboardd's "contact … touching" log line:
   under 20 ms on an idle guest.
10. **Restart.** Kill backboardd in the guest; after it restarts, item 2
    works again without restarting `ycode-simd`.

A booted Ycode device stays awake (§13 item 8): no Home or Lock press is
needed before the first touch.

## 13. Open questions

1. Does the loader require the principal class to conform to
   `SimulatorClientHIDSystemManager`, or only to respond to the initializer?
   (Declaring conformance is harmless either way.)
2. Does removing the keyboard service turn the guest's hardware-keyboard
   state off and bring back the on-screen keyboard? How does Simulator.app's
   "Connect Hardware Keyboard" reach the guest?
3. Rotation: does the `PurpleWorkspacePort` orientation event rotate a
   landscape-capable app on iOS 27, or does iOS 27 take orientation only
   from device-motion input (idb sends it through dtuhidd's vendor-defined
   service on such runtimes)?
4. Do volume and side buttons from the buttons service reach their
   consumers (the reference showed "destinations: none" for both on its
   device type)?
5. Multi-touch through the prototype was not exercised (single contact
   only); the parent/child structure follows IOHIDFamily's own driver and
   the reference's two-finger messages.
6. Simulator.app's edge threshold (§8.2).
7. The meaning of the remaining Indigo fields (Appendix B); not needed.
8. *Answered (2026-10-19, §14.1):* the display does not sleep after a boot.
   As in the reference, SpringBoard disables its idle timer at startup
   ("Disabling idle timer for reason: SBDisableAutoDim user default."), so
   there is no auto-dim and no auto-lock; Lock still locks. The first touch
   on the home screen is taken without a Home press.

## 14. Implementation notes (Ycode, 2026-10-19)

Implemented from this spec by SIM-VIEWER: the bundle
`ycode/SimGuestFrameworks/SimHID` (C, Objective-C runtime functions; built by
`SimGuestFrameworks/build.sh` into `out/SimHID.framework`), the host service
`YcodeHostServices/HIDHostService.swift`, the bridge from the display stream
`ycode-simd/InputBridge.swift`, and the viewer `ycode-sim-viewer`
(`display-stream.md`). `ycode-simd` copies the bundle to
`DEV/ycode-frameworks/SimHID.framework` and sets the variable only with
`--display-server` (or `--hid-bundle <dir>`), so other boots are unchanged.
The bundle appends diagnostics to `$YCODE_SIMHID_LOG`
(`DEV/data/tmp/ycode-simhid.log`).

Observed on the Thor (level 3, Ycode runs):

- Loading: the class created by an image initializer (`__init_offsets`) was
  found as the principal class; backboardd called the initializer about
  10 s into the boot; buttons and keyboard were added at once; the
  registration reached the host; `+[CADisplay mainDisplay].uniqueId` was
  available on the first try (about 4.5 s after the initializer), and the
  touch screen was added then.
- §12 items 2 (tap opens Settings), 3 (scroll), 4 (bottom-edge swipe returns
  home), 5 (typing "Set" in Spotlight, shift for the capital, no on-screen
  keyboard), 6 (Home returns home; Lock shows the lock screen a few seconds
  later) passed. Items 7, 8 (long press, pinch effect), 9 (latency to
  backboardd's log), 10 (backboardd restart) and volume/side were not
  checked.
- (Corrected by §14.1.) The first viewer sessions reported that the
  display slept after a boot and that Home and taps had no visible effect
  until about 4 min after the start, when the app icons appeared. Neither
  was reproduced in the runs of §14.1.
- A button held when a viewer disconnects stays down in the guest (a held
  Lock brought up Siri). The bridge therefore cancels contacts and releases
  keys and buttons when the viewer goes away (§7.5 "no stuck state").

### 14.1 Awake display, input right after the boot, input after a restore (SIM-INPUT2, 2026-10-19)

**The display stays awake (§13 item 8).** Guest logs (`log stream` one-shot,
default level; subsystems `com.apple.SpringBoard` categories `IdleTimer`
and `Backlight`, `com.apple.BackBoard`, `com.apple.BacklightServices`)
of Ycode boots and of a reference boot (iPhone Duo, iOS 27.1, `simctl
boot`, `log show`) show the same sequence: backlight `ActiveOn` once
SpringBoard's main scene connects, then "SBIdleTimerGlobalCoordinator -
Idle timer disable assertion: Disabling idle timer for reason:
SBDisableAutoDim user default." and the idle-timer descriptor `mode:
Disabled`; the auto-lock descriptor (`warn 40 s, total 60 s`,
`MCFeatureAutoLockTime (60)`) is computed and "not applied". The value is
not stored in any preference file of the device (neither on the Mac nor
under Ycode); SpringBoard's default is on. On the reference, writing
`SBDisableAutoDim = NO` to the `com.apple.springboard` domain and
restarting SpringBoard made it apply the 60 s auto-lock ("applying updated
idle timer descriptor … total: 60.0s"); removing the key restored the
disabled timer. So no device setup is needed: Ycode's device behaves like
the reference without one. No backlight change to off was logged in any
Ycode boot (up to 400 s) unless Lock was pressed.

**Input right after the boot.** Two driver boots (a display-stream client
on the simulator host; taps on the Settings icon every 20 s from 90 s, Home
at 310 s and 350 s; a fresh copy of the pristine device, then a second boot
of that copy) and 18 viewer sessions through `ycode-sim-try --script` (8
cold boots, 10 restores; light and dark appearance): in every one the
**first** tap on the home screen, with no Home press before it, launched
Settings. The tap is taken at once (backboardd and
SpringBoard react to the touch within the first changed frame); what the
person waits for is the app: on a cold boot the first launch of Settings
drew its first content 3.6–16.3 s after the tap (a white launch screen
first), after a restore the screen changed 0.13–1.4 s after the tap and
Settings was drawn within 5.5 s. Home from an app returned within
0.6–1.3 s. The
4-minute delay of the first sessions was the app icons: they are grey
placeholders until iconservicesagent has rendered them, and the rendering
waited about 22–34 s for a start hold of `MTLCompilerService`
(`scheduling-policy.md` §4.2 "on demand", `home-screen.md` §2.1); on a
loaded host that came on top of a slower boot. The placeholders take taps
too (Settings opened from one at 90 s in the first driver boot).

**Input after a restore (§7 item 6).** Implemented as the `hid` record.
Measured through the viewer (§12.4 of `snapshot.md`): the restored device
was live 0.9 s after `ycode-simd` started, "hid: the registration of the
saved run is used again" was logged, and the first tap, sent right after
the first frame, changed the screen 654 ms later.

### 14.2 Delivery timing (FPS-LATENCY, 2026-10-19)

With `YCODE_DISPLAY_TIMING=1` (`display-stream.md` §10.1) the bundle logs,
per event message, the host sequence number (body offset 8), the mach time
it took the message from its port, and the mach time after
`_IOHIDServiceDispatchEvent` returned. Measured on the Thor (load ≈ 34):
display server → message sent 0.07 ms; sent → taken by the bundle in
`backboardd` 0.1 ms; taken → dispatched 1–2 ms median, with single
outliers of 280–340 ms per session in which the dispatch call itself did
not return (inside `backboardd`'s event system). The 16 ms move
coalescing of §7 item 4 is kept (`display-stream.md` §10.4).

## Appendix A. Programs (ours)

In `research/experiments/simulator/hid/`; `build.sh <out>` builds them
outside the repo.

| File | What it is |
|---|---|
| `hidsend.m` | Mac-side black-box driver of the reference path: builds messages with SimulatorKit's exported builders, hex-dumps them, sends them through `SimDeviceLegacyHIDClient`; also sends the orientation event to `PurpleWorkspacePort` |
| `hidmon.m` | guest-side HID service lister and event monitor (sees nothing without entitlements, which the simulator refuses for ad-hoc binaries); `kbstate` prints GraphicsServices' hardware-keyboard state |
| `hidproto.m` | the prototype replacement bundle (§12), loaded with `SIMCTL_CHILD_SIMULATOR_HID_SYSTEM_MANAGER=<bundle dir>` at `simctl boot`; commands arrive by a Darwin notification instead of §7's port |

## Appendix B. Indigo, for reference only

From idb's documentation (MIT) and our dumps of SimulatorKit's builders:
a Mach message (24-byte header), a 32-bit inner size 0xA0, an 8-bit message
type (1 button/key, 2 touch), then 0xA0-byte records: 32-bit kind (0x0B
touch, 2 button/key), 64-bit host `mach_absolute_time`, 32-bit zero, a
union. Touch records: index, identity, digitizer mask, x and y as ratios
(doubles), z, pressure, twist, range, touch, a target (0x32), then values
whose meaning is unknown. Touch messages carry two records (a hand record
with index 0x00400002 and the finger record). Button records: source (0
home, 1 lock, 500 Apple Pay, 3000 side, 10000 keyboard, 10001 arbitrary
HID usage, 0x400002 Siri), direction (1 down, 2 up), target (0x33
hardware buttons, 0x64 keyboard, 0x32 digitizer), key code (HID usage), and
for arbitrary usages the usage page. Mapping seen in the guest: source 0 →
0x0C/0x40, 1 → 0x0C/0x30, 3000 → 0x0C/0x95.

## Appendix C. Keyboard usages (USB HID Usage Tables, page 7)

| Keys | Usages |
|---|---|
| a … z | 0x04 … 0x1D |
| 1 … 9, 0 | 0x1E … 0x26, 0x27 |
| Return, Escape, Backspace, Tab, Space | 0x28, 0x29, 0x2A, 0x2B, 0x2C |
| `-` `=` `[` `]` `\` | 0x2D, 0x2E, 0x2F, 0x30, 0x31 |
| `;` `'` `` ` `` `,` `.` `/` | 0x33, 0x34, 0x35, 0x36, 0x37, 0x38 |
| Caps Lock | 0x39 |
| F1 … F12 | 0x3A … 0x45 |
| Home, Page Up, Delete forward, End, Page Down | 0x4A, 0x4B, 0x4C, 0x4D, 0x4E |
| Right, Left, Down, Up arrows | 0x4F, 0x50, 0x51, 0x52 |
| Left Control, Shift, Option (Alt), Command (GUI) | 0xE0, 0xE1, 0xE2, 0xE3 |
| Right Control, Shift, Option, Command | 0xE4, 0xE5, 0xE6, 0xE7 |

## Evidence

| Claim | Level | Source |
|---|---|---|
| backboardd loads the bundle at "start HID system start…", as a CFBundle, calling one initializer with its event system (§1 item 1, §3) | 3, 4 | backboardd log of a reference boot; `simframebuffer.md` §8 (ObjC metadata: protocol, method, type encoding; `hidprobe.m`); prototype loaded the same way |
| Bundle path, owner (CoreSimulator), principal class; runtime has only the loader (§1 item 2) | 2, 3, 4 | `simctl getenv`; Info.plist; file listing of the runtime root and CoreSimulator; ObjC listing of `SimulatorClient` (no classes) |
| Reference services, IDs, properties, order, sender ID = service ID (§1 item 3, §4.3) | 3 | backboardd log lines "Connecting service … properties" and "Services discovered" |
| `IndigoHIDRegistrationPort` lookup and Indigo transport (§1 item 4) | 1, 3, 4 | idb `Indigo.h`, `SimulatorIndigoHID.swift`, `SimulatorIndigoHIDClient.swift` (MIT); guest `launchctl print` (host-side name); bundle strings |
| dtuhidd job, names, notify state, suppression (§1 item 5) | 1, 2, 4 | idb DTUHID transport sources; dtuhidd launchd plist; bundle strings; dtuhidd import names |
| Virtual-service functions, their arguments, the nine-entry callback table and its order (§4.1, §4.2) | 1 | IOHIDFamily `tools/IOHIDEventSystemMonitor.c` (APSL), IOKitUser `hidobjcbase.h` |
| `_IOHIDServiceDispatchEvent` (service, event) dispatches; set-property keys the system writes (§4.1, §4.2) | 3, 4 | bundle imports (level 4); prototype dispatch worked; reference log of `DeviceOpenedByEventSystem`, `LogLevel`, `CapsLockDelayOverride` |
| Event constructors and argument orders, `IsDisplayIntegrated` field id 0xB0019 (§5.2, §5.4) | 1 | WebKit `IOKitSPIIOS.h`, `HIDEventGenerator.mm` (BSD) |
| Mask bits, swipe/edge bit names, transducer types, collection semantics (parent = OR of children, centroid) (§5.2) | 1 | IOHIDFamily `IOHIDEventTypes.h`, `IOHIDEventDriver.cpp` (APSL) |
| Down/move/up masks, range/touch values, edge bits on every event (§5.2) | 3 | hex dumps of SimulatorKit builder output; prototype runs |
| Edge bits drive system gestures; coordinates alone do not (§5.2) | 3 | reference drag with and without edge; prototype drag with edge ("swipe-locked") |
| Normalized coordinates scaled by backboardd to pixels and points (§5.3) | 3 | backboardd TouchEvents debug log, reference and prototype |
| Keyboard page 7 routing to keyboard focus; typing in Spotlight without on-screen keyboard (§5.4, §9) | 3 | backboardd KeyPresses log; screenshot |
| Button usages and backboardd names (§5.5) | 3 | backboardd Button log for builder sources 0, 1, 3000 and usages 0xE9/0xEA; prototype home/lock |
| Siri 0xCF, Play/Pause 0xCD, Apple Pay = double side press (§5.5) | 1 | idb `Indigo.h`, `SimulatorDigitizerHIDTransport.swift` |
| `displayUUID` required; behavior without it (§6) | 3 | prototype boots with and without the key |
| Display UUID = QuartzCore display unique id, per boot (§6) | 3 | backboardd log `<CADisplay:LCD primary> <UUID>`, "main display is now"; prototype read |
| Ycode display UID constant (§6) | — | Ycode source `SimGuestFrameworks/SimFramebuffer/simframebuffer.c` |
| Hardware keyboard attached from service presence; GS state 1 (§9) | 3 | backboardd Keyboard log; `hidmon kbstate`; prototype boot |
| Orientation GSEvent layout (§10) | 1, 3 | idb `GSEvent.h`, `SimulatorPurpleHID.swift`; our send accepted (kr 0); effect not confirmed |
| Simulator.app Option / Shift-Option gestures (§8.3) | 1 | Apple's archived *iOS Simulator User Guide*, "Interacting with iOS and watchOS" (retired document) |
| Simulator.app menu shortcuts (§8.4) | 1 | Simulator's Device menu as publicly documented; not re-checked in this session |
| HID usage values (Appendix C) | 1 | USB HID Usage Tables, keyboard page 7, consumer page 0x0C |
| §2 split, §7 wire, IDs, thresholds, defaults | — | Ycode decisions |
| Implementation observations (§14) | 3 | Ycode runs on the Thor: the bundle's log, ycode-simd's log, viewer script logs and screenshots |
| The idle timer is disabled at startup by SpringBoard's `SBDisableAutoDim` default, not by a stored preference; a stored `NO` brings back the 60 s auto-lock (§13 item 8, §14.1) | 2, 3 | guest `log stream`/`log show` of Ycode and reference boots; the reference device's preference files (`plutil -p`, `grep`) and `simctl spawn defaults read/write/delete` with a SpringBoard restart |
| First tap taken without a Home press; app-launch and Home timings (§14.1) | 3 | driver boots (`ydrive.py` over the display socket) and viewer `--script` sessions on the Thor |
| The registration is a host-task right whose name a snapshot keeps (§7 item 6) | — | Ycode design (`snapshot.md` §2.6); `HIDHostServiceTests.registrationSurvivesRestore`; restores through the viewer |
| Delivery timing (§14.2) | 3 | the bundle's event timing log and the display server's trace in Ycode runs on the Thor |

Level 5 (disassembly, decompilation) was not used. No Apple binary was
opened in a disassembler or Ghidra; `research/dirty/` was not used. Level 4
was limited to file listings, Info.plists, import and export symbol names,
printable strings, and ObjC runtime metadata. Apple code was **run** as a
black box (SimulatorKit builders and client on the Mac) only to observe
its output.
