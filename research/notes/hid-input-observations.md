# HID input: observations (dirty-room notes, prose only)

Date: 2026-10-19. Agent: HID-SPEC. Reference: Xcode 27.1, CoreSimulator
1174.9.2, iOS 27.1 runtime (24A94401), device type iPhone Duo (the only one
the 27.1 runtime offers on this Mac). Throwaway device `ycode-test-hidspec`,
created, used, shut down and deleted in this session. No disassembly or
decompilation was used. Our probe sources are in
`research/experiments/simulator/hid/`; raw logs stayed in the session
scratch directory.

## 1. Where the pieces live (levels 2 and 4)

- `SIMULATOR_HID_SYSTEM_MANAGER` in a reference boot names the bundle
  directory `…/CoreSimulator.framework/Resources/Platforms/iphoneos/Library/Frameworks/SimulatorHID.framework`
  (`simctl getenv`). It is CoreSimulator's file, not the runtime's. Its
  Info.plist: package type FMWK, executable `SimulatorHID`, bundle id
  `com.apple.CoreSimulator.SimulatorHID`, `NSPrincipalClass` `SimHIDSystem`,
  platform iPhoneSimulator, version 1174.9.2.
- The runtime has no HID bundle and no `dtuhidd`. The runtime does have
  `SimulatorClient.framework` (the code in backboardd that loads the bundle;
  its log category is `SimulatorClient`); it has no ObjC classes.
- CoreSimulator also ships, per platform, `usr/libexec/dtuhidd` and
  `Library/LaunchDaemons/com.apple.coredevice.dtuhidd.plist` (read as a file
  format): label `com.apple.coredevice.dtuhidd`, Interactive spawn type,
  transactions and pressured exit, Mach services
  `com.apple.coredevice.feature.remote.hid.{button,digitizer,keyboard,vendordefined}`,
  `com.apple.coredevice.feature.remote.universalhid`,
  `com.apple.coredevice.feature.remote.universalhidservice`. A sibling job
  `com.apple.coredevice.dthidd` serves
  `com.apple.coredevice.feature.remote.devicecontrol.orientation`. Both are
  demand-launched; in a plain boot neither was running.
- Host side: `IndigoLegacyHIDServices.simdeviceio` (macOS bundle in
  CoreSimulator's Resources) and SimulatorKit (in Xcode's SharedFrameworks),
  which exports the message builders `IndigoHIDMessageForMouseNSEvent`,
  `…ForKeyboardArbitrary`, `…ForKeyboardNSEvent`, `…ForButton`,
  `…ForHIDArbitrary`, `…ForScrollEvent`, `…ForTrackpadMoveEvent`,
  `…ForDigitalCrownEvent`, `…ForGameControllerEvent`, and others, plus the
  class `SimDeviceLegacyHIDClient` with a send-message method.

## 2. What the bundle uses (level 4: import table, strings, ObjC metadata)

- Imports from IOKit's HID event system (all exported by the runtime's IOKit):
  `_IOHIDServiceCreateVirtual`, `_IOHIDEventSystemAddService`,
  `_IOHIDEventSystemRemoveService`, `_IOHIDServiceDispatchEvent`,
  `_IOHIDServiceGetSenderID`, the `IOHIDEventCreate…` family (digitizer
  finger, keyboard, button, scroll, pointer, rotation, scale, translation,
  velocity, dock swipe, force, game controller, vendor defined, quaternion
  orientation), `IOHIDEventAppendEvent`, `IOHIDEventSetIntegerValue`,
  `IOHIDEventSetFloatValue`, `IOHIDEventSetPhase`, and
  `IOHIDEventSystemClientCreate` / `…DispatchEvent`.
- From GraphicsServices: `GSEventSetHardwareKeyboardAttachedWithCountryCodeAndType`.
- Mach: `bootstrap_look_up`, `mach_msg`, `mach_msg_send`, a dispatch Mach
  receive source; NSConnection and NSMachPort (for a Simulator.app
  "upstream" service named `com.apple.iphonesimulator.upstream`, used for
  property queries).
- notify: registers for `com.apple.coredevice.dtuhidd.active` (a state
  notification); log strings say it disconnects "dtuhidd-suppressed" services
  while dtuhidd is active and reconnects one when an Indigo event arrives for
  it.
- Strings name a state file `/var/run/SimHIDDynamicServices.plist`, the
  service identifiers listed in §3, the property keys of §3, and the
  messages "Invalid target_id, expected the ScreenID mask bit", "Missing
  display_uid".
- dtuhidd (level 4 import names only) uses the HID framework's client-side
  virtual service class (`HIDVirtualEventService`) and
  `HIDEventSystemClient`, and creates digitizer, keyboard, relative pointer,
  scroll, and fluid-touch-gesture events. It is a second injection path that
  Ycode cannot ship either (CoreSimulator file).

## 3. Services in a reference boot (level 3: backboardd log)

backboardd logs every virtual service with its property dictionary when it
connects. The bundle is loaded during "start HID system start…", right after
"HID system open ready", about 0.3 s after backboardd starts. Service IDs
count up from `0xACEFADE000000000`; backboardd uses the service ID as the
event **sender ID**.

| ID suffix | Identifier | PrimaryUsagePage / Usage | Other properties |
|---|---|---|---|
| 0 | `com.apple.SimulatorHID.GamePadService` | 1 / 5 | Product `Gamepad`, GameControllerType 1, PhysicalDeviceUniqueID `SimulatedGamepad` |
| 1 | `…MainScreenButtonsService` | 0x0B / 1 | Built-In 1, Authenticated 1, PressCountTrackingEnabled 1, PressCountUsagePairs [0x000C0040] |
| 2 | `…ExternalKeyboardService` | 1 / 6 | (none beyond the usage keys) |
| 3 | `…ProximitySensorService` | 0xFF00 / 8 | Built-In 1, Placement 1 |
| 4 | `…PalomaPoseService` | 0xFF00 / 0x72 | Built-In 1 |
| 5 | `…SelectionStreamService` | 0xFF00 / 0x71 | Built-In 1 |
| 6 | `…ManipulatorService` | 0xFF00 / 0x6F | Built-In 1 |
| 7, 8, 9 | `…ScreenTouchService.<display UUID>` | 0x0D / 4 | DisplayIntegrated 1, `displayUUID` = that display's UUID, Built-In 1 (0 for the external TVOut display) |

Every service also carries `DeviceUsagePairs` = one pair equal to its
primary usage. `DeviceOpenedByEventSystem` 1 and `LogLevel` 6 appear in the
dictionaries because the event system sets them through the service's
set-property callback; the bundle stores what it is given. Later the
keyboard service received `CapsLockDelayOverride` -1 the same way.

The touch services were added about 10 ms after the others, from another
thread, after an event-system client named by its caller
`IndigoHIDSystemSpawnLoopback` connected. backboardd then logged:

- for 1/6: "Services discovered … eventSource: externalKeyboard", then
  "Keyboard attached … countryCode: 0; keyboardType: -1" and "Hardware
  keyboard attached (countryCode:0 type:-1 layout:US)";
- for 0x0D/4: three services, the built-in ones marked "authenticated;
  builtIn", eventSource `builtin`, the TVOut one `externalAccessory`.

`GSEventIsHardwareKeyboardAttached` returned 1 in a fresh process both
before and after we sent any key: in this boot the hardware keyboard is
attached from the start, because the keyboard service exists.

The display UUIDs are the QuartzCore display unique ids (backboardd logs
`<CADisplay:LCD primary> <UUID>`); they change per boot. The main display's
digitizer was the one whose `displayUUID` named the `LCD`/`primary` display.

## 4. Driving the reference (level 3)

`hidsend` (ours) builds messages with SimulatorKit's exported builders and
hands them to `SimDeviceLegacyHIDClient`, the route idb documents. backboardd
debug logging (`log stream --level debug`, categories TouchEvents,
TouchDeliveryPolicy, Button, KeyPresses) shows how each arrives.

- **Tap** at ratio (0.121, 0.125): backboardd logs a new contact "pathIndex: 1
  touchID: 1" on digitizer `ACEFADE00000009`, display `5681AA64…` (the main
  display), and two deliveries: SpringBoard's system-gesture touch stream
  gets `{169, 254}` (pixels: 0.121 × 1398, 0.125 × 2034) and the hit-tested
  context gets `{56.33, 84.67}` (points: × 466, × 678). Settings launched.
  So events carry **normalized** positions and backboardd scales them by the
  display size.
- **Drag** from (0.5, 0.995) to (0.5, 0.55) with no edge flag: delivered as
  down/move…/up; Settings scrolled; no system gesture.
- **Same drag with the builder's edge argument = bottom**: the contact is
  marked "swipe-locked", "cancel clients due to system gesture stealing the
  touches", and the app went to the home screen.
- Each new contact got a new touchID (1, 2, … 5 across the session); the
  path index stayed 1.
- **Key** usage 4 down/up: "KeyPress page:0x7 usage:0x4 downEvent:1 down ->
  keyboardFocus …", sender `ACEFADE00000002`. Typing usages 0x16, 0x08, 0x17
  into Spotlight produced "set" with no on-screen keyboard.
- **Home** (builder source 0): "Home page:0xC usage:0x40", sender
  `…01`, destination SpringBoard (system). The app went home.
- **Lock** (source 1): "Lock page:0xC usage:0x30", sender `…01`, destination
  system.
- **Side** (source 3000): "Side page:0xC usage:0x95", sender `…01`,
  destinations none on this device type.
- **Volume** (arbitrary-usage builder, page 0x0C, usages 0xE9/0xEA, target
  0x32): "VolumeIncrement/VolumeDecrement", sender `…09` (the touch
  service), destinations none.
- **Orientation**: the 108-byte GraphicsServices event that idb documents,
  sent to the guest's `PurpleWorkspacePort` (looked up through SimDevice),
  was accepted (send returned 0). SpringBoard logged a scene snapshot with
  interface orientation landscapeLeft once, but no screenshot showed rotated
  content (Settings is portrait-only; Safari did not visibly rotate). Not
  conclusive.

### Bytes produced by the builders (black-box output, level 3)

Described as values, from hex dumps of the buffers the builders return:

- Every message starts with a 24-byte Mach header left zero (the client fills
  it), then a 32-bit inner size 0xA0 and an 8-bit message type (2 for the
  single-point mouse builder, 1 for key/button/arbitrary).
- Each payload record is 0xA0 bytes: 32-bit kind (0x0B touch, 2
  button/key), 64-bit host `mach_absolute_time`, a 32-bit zero, then the
  event union; the record ends with two bytes (0xFF 0x01 for touch, 0x00
  0x01 for buttons) and padding.
- Touch messages hold two records (0x180 bytes in all). Record 1 (index
  0x00400002, identity 1) and record 2 (index 1, identity 2) both carry the
  mask, x and y ratios, range and touch flags, and a target 0x32; record 2
  also carries 90.0 in the twist position and 1.5, 1.5, 4.6, 3.8 further on.
  Down: mask 0x3, range 1, touch 1. Dragged: mask 0x4, range 1, touch 1.
  Up: mask 0x3, range 0, touch 0. The edge argument ORs 0x01040000 (bottom),
  0x02040000 (top), 0x08040000 (left), 0x04040000 (right) into the mask of
  both records, on down, move, and up alike.
- Key: source 10000, direction 1/2, target 0x64, the HID usage (4 for "a"),
  and 0xCC in the next field. Button: source, direction, target 0x33. HID
  arbitrary: source 10001, direction, target 0x32, usage, then the page.

## 5. The prototype replacement (level 3)

`hidproto.m` (ours, written from the draft spec) was booted in place of the
reference bundle with `SIMCTL_CHILD_SIMULATOR_HID_SYSTEM_MANAGER`.

- backboardd loaded it, called the initializer, and accepted three virtual
  services (buttons 0x0B/1, keyboard 1/6, touch screen 0x0D/4). It logged
  "Hardware keyboard attached", "digitizer attached (sender …)", "acquired
  main display digitizer", and a direct-touch state "touchScreen; builtin;
  builtIn: YES; displayIntegrated: YES".
- **Without `displayUUID`** on the touch service: a tap reached backboardd
  and was hit-tested, but it was delivered at `{0, 0}` and there was no
  system-gesture stream. Settings did not open.
- **With `displayUUID`** = the main display's unique id (read from
  QuartzCore's main display on the bundle's own queue; it was available at
  the first try): the tap was delivered at `{169, 254}` / `{56.33, 84.67}`
  exactly like the reference, and Settings launched.
- Home (page 0x0C usage 0x40) and Lock (0x30) from the buttons service were
  routed to SpringBoard; key usage 4 from the keyboard service went to the
  keyboard focus; a bottom-edge drag with mask bits 0x01040000 was
  "swipe-locked" and taken by the system gesture.
- Event shape used: a parent digitizer event (transducer type hand, index 0,
  identity 0, mask as above, x/y of the finger, range and touch flags,
  display-integrated field set to 1) with one appended finger event (index
  1, identity a per-contact counter, same mask, x/y, pressure 0.5 while
  down, twist 90). Events were dispatched with `_IOHIDServiceDispatchEvent`
  from the bundle's serial dispatch queue, timestamped with the guest's
  `mach_absolute_time` at creation.
- Side note: on this foldable device type the cover display's backlight went
  to 0 some seconds after boot in both the reference and the prototype boots;
  a lock-button press woke it to the lock screen.

## 6. Things we could not observe

- The HID event system client API sees no services without HID client
  entitlements, and the simulator refuses to spawn an ad-hoc signed probe
  that claims them ("Security policy issue"). So the exact events that the
  reference bundle dispatches were not captured; §4 relies on backboardd's
  own logs.
- Whether the loader checks the principal class's protocol conformance.
- How Simulator.app's "Connect Hardware Keyboard" off state reaches the
  guest.
