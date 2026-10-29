# Spec: the simulator IOSurface host service (`com.apple.IOSurface.Remote`)

Status: **reference** for stage 7 (`stage7-contract.md` §6, agent R5). It
describes the host-side service that the iOS 27.1 runtime (24A94401) uses
for every IOSurface: who connects to it and when, the message protocol on
the connection, how surface memory is shared, and the smallest service with
which a surface made in one guest process can be looked up and mapped in
another, and with which `backboardd` and SpringBoard start.

Every fact comes from public headers and Apple open source (level 1), from
exported symbol names and ObjC metadata of the runtime's IOSurface
framework read at run time by our own program (level 4), and from
black-box runs of our own programs on this Mac (level 3): a recording relay
between guest clients and the real host service, and a test server of our
own written from these captures. No Apple binary was disassembled or
decompiled. Header, disposition, and descriptor terms are those of
`mach-ipc.md` §2. The XPC object encoding is that of `bootstrap-wire.md` §3.
All integers are little-endian.

Terms:

- **The service**: the Mach service registered into the guest's
  `user/<uid>` domain under the name `com.apple.IOSurface.Remote` (a
  host-side endpoint, `launchd-sim.md` §6.3, `launch-sim-control.md` §3.2).
  On macOS it is served by CoreSimulator's `SimRenderServer` XPC service
  (`SimRenderingServices.simdeviceio`), one process per booted device.
- **The client**: the runtime's `IOSurface.framework` (in the runtime's
  shared cache). Every IOSurface call of a guest process that needs the
  service goes through it.
- **Connection port**: the receive right that the client hands to the
  service in its hand-shake (§2.2); all later requests arrive on it.
- **Request**, **reply**: a client message and the service's answer (§2.3,
  §2.4). The protocol has no other message kinds.
- **Method**: the value of the request key `Method` (§3).
- **SurfaceState**, **PlaneState**, **Limits**: fixed binary records carried
  as XPC data (§4).
- **OSSerialize blob**: a property list in the OSSerialize binary format of
  xnu's libkern (§5), carried as XPC data.
- **Relay**, **test server**: our programs (Appendix A).

## 1. Who uses the service, and when

### 1.1 Processes

A process uses the service only when it creates or looks up an IOSurface.
The client opens **one connection per process**, lazily, on the first such
call, with `xpc_connection_create_mach_service` (flags 0) on the service
name, and then marks it with `xpc_connection_enable_sim2host_4sim` (both are
exported libxpc names; the second one selects the serialization of §2.1).

Observed in a boot of the iPhone Duo device type, followed by launches of
Settings and Safari (one capture; counts are requests; times are
approximate, from the first interposed call of each process):

| Process | First connect | What it does |
|---|---|---|
| `backboardd` | first of all processes, at QuartzCore's window-server start, before it logs "initial main screen size" | creates 3 surfaces per built-in display (the display buffers, §1.2); then mostly **looks up surfaces made by other processes**: 849 by global ID and 781 by Mach port in one boot; locks and unlocks for reading; reads and writes attachments |
| SpringBoard | after `backboardd` (about 4 s later) | creates display-sized and smaller surfaces (names `QuartzCore`, `BaseBoard`, `CoreUI`), makes Mach ports for them (Method 14), sets values and attachments |
| `iconservicesagent` | about 9 s after `backboardd` | creates many small `RGhA` surfaces (name `RenderBox`) and a few `CoreImage` ones |
| `WidgetRenderer_Default`, `PosterBoard`'s poster extensions (`MercuryPosterExtension`, `EmojiPosterExtension`, `GradientPosterExtension`, `KaleidoscopePoster`, `PridePosterExtension`, `UnityPoster`, `Unity2025Poster`, `AegirPoster`, `ExtragalacticPoster`, `RhizomePoster`, `WeatherPoster`, `PhotosPosterProvider`) | from about 7 s after `backboardd`; extensions restart often | create surfaces whose IDs `backboardd` then looks up (most of `backboardd`'s ID look-ups are of surfaces made by `MercuryPosterExtension`) |
| MobileSafari, `com.apple.WebKit.GPU` | at their launch | create (`CoreUI`, `WebKit LayerBacking`), make Mach ports, look up by port |
| **Settings** (a plain UIKit app) | **never** | its launch made no connection: the process loaded IOSurface.framework but created no IOSurface (its Core Animation backing stores are ordinary shared memory) |

### 1.2 The display buffers

`backboardd` creates, for each built-in display, three surfaces with these
creation properties (iPhone Duo display 1; display 2 is 2007×2853 with
bytes per row 8192 and allocation size 23 379 968):

| Key | Value |
|---|---|
| `IOSurfaceWidth`, `IOSurfaceHeight` | 1398, 2034 |
| `IOSurfaceBytesPerElement` | 4 |
| `IOSurfacePixelFormat` | `0x42475241` (`'BGRA'`) |
| `IOSurfaceBytesPerRow` | 5632 |
| `IOSurfaceAllocSize` | 11 468 800 |
| `IOSurfaceCacheMode` | 1024 (`0x400`) |
| `IOSurfaceMapCacheAttribute` | 0 |
| `IOSurfacePixelSizeCastingAllowed` | false |
| `IOSurfaceName` | `QuartzCore`, later set to `LCD` (`LCD-1` for display 2) with Method 9 |

Its first requests are: connect (Method 0), then for each buffer create (2),
set value (9, the name), set attachments (20: colour primaries 1, transfer
function 13), get attachments (21) twice, remove value (11, key
`IOSurfaceColorPrimaries`), set attachments (20); then Mach ports (14) for
the buffers, and from then on look-ups. These are the surfaces that R4
saw passed to `SFBSwapchainSwapAddSurface` (`simframebuffer.md` §5.1).

**If the create request fails, `backboardd` reports "initial main screen
size:{0, 0}" and SpringBoard traps in `BKSDisplayServicesStart`** — the
symptom of `simframebuffer.md` §7 item 10, reproduced with our test server
refusing Method 2 (§7.2).

### 1.3 Formats and sizes seen

| Pixel format | Bytes per element | Where |
|---|---|---|
| `'BGRA'` (`0x42475241`) | 4 | display buffers, SpringBoard, Safari, WebKit, CoreUI, most surfaces |
| `'RGhA'` (`0x52476841`, half-float RGBA) | 8 | `iconservicesagent`, poster extensions (344 of 861 creates) |
| `'RGBA'` (`0x52474241`) | 4 | CoreImage, rare |
| `'LA08'` (`0x4C413038`) | 2 | CoreUI, once |

No planar format was created in the boot. Our probe also created `'420v'`
(two planes), `'L008'`, `'L016'`, `'l10r'` (§4.3).

## 2. Wire protocol

### 2.1 Serialization

Requests and replies carry one XPC dictionary, encoded as in
`bootstrap-wire.md` §3 with one difference: the magic is **`!CPX`** (bytes
`21 43 50 58`, u32 `0x58504321`), followed by version 5. This is the
encoding libxpc uses on a connection marked with
`xpc_connection_enable_sim2host_4sim`; on the same kind of connection
without that call it writes `?cpx` (§7.3, our own test program).

The client **rejects replies that carry `?cpx`**: with our test server
answering in `?cpx`, the probe's create returned NULL and a restarted
`backboardd` reported screen size {0, 0}. A service must reply with `!CPX`.

Value types seen: uint64 (`0x4000`), bool (`0x2000`), string (`0x9000`),
data (`0x8000`), shared memory (`0xC000`), Mach send right (`0xD000`). No
request was larger than 3.6 KB; no out-of-line payload and no data object
larger than 16 KiB (carried by a port, `bootstrap-wire.md` §3.2) was seen.
A service should still accept both (not tested).

### 2.2 Hand-shake

The first message on a new connection, sent to the service port:

| Field | Value (as received) |
|---|---|
| `msgh_id` | `0x77303074` |
| `msgh_bits` | remote 0 (no reply port), local 17 (service port, `COPY_SEND`), voucher 17 (present), `COMPLEX` |
| `msgh_size` | 52 |
| descriptor 0 | port, received as **16 (receive right)**: the connection port. The client keeps send rights to it and sends every request there |
| descriptor 1 | port, received as **17 (send right)**: a port of the client. The real service never sent anything to it (no server-initiated message in 22 138 captured requests) |
| body | none |

A service adds the connection port to its receive set and serves requests
on it. The hand-shake has no reply.

### 2.3 Request

| Field | Value (as received) |
|---|---|
| `msgh_id` | **`0x10000000`** |
| `msgh_bits` | remote 18 (reply port, `MAKE_SEND_ONCE` by the client), local 17, voucher 17, `COMPLEX` only when a descriptor follows. Bit `0x20000000` (`MACH_MSGH_BITS_RAISEIMP`, public `message.h`) was set on 601 of 22 138 requests; it can be ignored |
| descriptors | 0 or 1: one port descriptor (received as 17) when the dictionary holds `MachPort` (§3) |
| body | `!CPX` payload, inline |

Every request carried a reply port. Requests are synchronous: the client
waits for the reply.

### 2.4 Reply

| Field | Value |
|---|---|
| `msgh_id` | **`0x20000000`** |
| `msgh_bits` | remote `MOVE_SEND_ONCE` to the request's reply port, local 0, voucher 0, `COMPLEX` when the dictionary holds `MemoryObject` or `MachPort` |
| descriptors | one port descriptor per port-bearing value, in payload order (`bootstrap-wire.md` §3.4): received by the client as send rights |
| body | `!CPX` payload, inline; always has `ErrorCode` (uint64) |

`ErrorCode` is an IOReturn value **sign-extended to 64 bits**
(`kIOReturnBadArgument` `0xe00002c2` travels as `0xffffffffe00002c2`). The
client returns its low 32 bits from `IOSurfaceLock` and similar calls.
Values seen: 0; `0xe00002c2` (`kIOReturnBadArgument`: invalid create
properties, unlock of a surface that is not locked, Method 2 with none of
its three keys); `0xe00002f0` (`kIOReturnNotFound`: look-up
of an unknown ID). Our test server used `0xe00002c7` (`kIOReturnUnsupported`)
for refused methods; clients tolerated it (§7.2). Constant names and values
are in the public `IOKit/IOReturn.h`.

### 2.5 Connection end

The connection ends when the client process exits (the client holds the
only send rights to the connection port). The real service then **drops
the surfaces that the process held**: a surface created by a process that
exited without releasing it could no longer be looked up by ID from another
process (`kIOReturnNotFound`). A Ycode service can detect the end with a
no-senders notification on the connection port (`mach-ipc.md` §3); that is
how our test server does it.

## 3. Methods

Request keys are in addition to `Method` (uint64). "State" in a reply means
the key `SurfaceState` (§4.1) for the surface after the call; "+ID" means
the key `SurfaceID` (uint64). Methods 1, 7, 8, 18, 19 and numbers above 21
were never sent (§9).

| Method | Public call(s) that send it | Request keys | Reply keys (success) |
|---|---|---|---|
| **0** connect | first use in a process | — | `Limits` (data, §4.4), `ErrorCode`, `ProtocolVersion` (uint64 1) |
| **2** create / look up | `IOSurfaceCreate`; `IOSurfaceLookup`; `IOSurfaceLookupFromMachPort`, `IOSurfaceLookupFromXPCObject` | exactly one of: `PropertiesDictionary` (data: OSSerialize blob of the creation properties, §5.2); `LookupID` (uint64 surface ID); `MachPort` (send right from Method 14) | `MemoryObject` (shared memory, §6), `ErrorCode`, State |
| **3** release | the last `CFRelease` of the client's object | `SurfaceID` | `ErrorCode` only |
| **4** lock | `IOSurfaceLock` | `SurfaceID`, `Options` (uint64: the lock options, `kIOSurfaceLockReadOnly` 1, `kIOSurfaceLockAvoidSync` 2) | `ErrorCode`, State, +ID |
| **5** unlock | `IOSurfaceUnlock` | `SurfaceID`, `Options` | `ErrorCode`, State, +ID; `0xe00002c2` if not locked |
| **6** plane state | first per-plane getter on a multi-planar surface | `SurfaceID`, `PlaneIndex` (uint64) | `ErrorCode`, State, +ID, `PlaneState` (data, §4.3) |
| **9** set value(s) | `IOSurfaceSetValue`; `IOSurfaceSetValues` | `SurfaceID`, `PropertiesDictionary` (blob: `{key: string, value: any}`, or `{value: dictionary, isSetValues: true}`) | `ErrorCode`, State, +ID |
| **10** copy values | `IOSurfaceCopyValue`, `IOSurfaceCopyAllValues` (the reply holds all values; the client picks the key) | `SurfaceID` | `ErrorCode`, State, +ID, `PropertiesDictionary` (blob: all values, §5.3) |
| **11** remove value | `IOSurfaceRemoveValue` | `SurfaceID`, `PropertyKey` (string) | `ErrorCode`, State, +ID |
| **12** remove all values | `IOSurfaceRemoveAllValues` | `SurfaceID` | `ErrorCode`, State, +ID |
| **13** purgeable | `IOSurfaceSetPurgeable` | `SurfaceID`, `NewState` (uint64: 0 non-volatile, 1 volatile, 2 empty, 3 keep current; `0x101` also seen, meaning of bit 8 open) | `ErrorCode`, State, +ID, `OldState` (uint64) |
| **14** make Mach port | `IOSurfaceCreateMachPort`, `IOSurfaceCreateXPCObject` | `SurfaceID` | `ErrorCode`, State, +ID, `MachPort` (send right) |
| **15** / **16** use count +1 / −1 | `IOSurfaceIncrementUseCount` / `…Decrement…` | `SurfaceID` | `ErrorCode`, State, +ID |
| **17** in use? | `IOSurfaceIsInUse` | `SurfaceID` | `ErrorCode`, State, +ID, `IsInUse` (bool) |
| **20** set attachments | no public call; sent by QuartzCore, CoreImage and others when they set colour and video attachments | `SurfaceID` and any subset of the attachment keys of §3.2 | `ErrorCode`, State, +ID |
| **21** get attachments | no public call; sent by the same frameworks | `SurfaceID` | `ErrorCode`, State, +ID and **all** attachment keys of §3.2 |

### 3.1 Behavior per method (observed)

- **Create** fails with `0xe00002c2` for a zero width. Sizes above the
  `Limits` maxima were not tried. The service picks the surface ID. IDs are
  small integers; an ID is reused after its surface is freed.
- **Look-up by ID works for every surface of the device, whether or not it
  was created with `kIOSurfaceIsGlobal`.** `backboardd` depends on this.
  `kIOSurfaceIsGlobal` is passed through in the creation blob and changes
  nothing visible.
- **Look-up by port** takes a send right made by Method 14 in any process.
- Each successful create or look-up gives the requesting process one
  reference; Method 3 drops one. Several look-ups in one process give
  separate client objects, separate mappings of the same memory, and one
  Method 3 each.
- **Lock** with `Options` without the read-only bit increments the seed
  (State offset 52) at lock time; a read-only lock does not. Unlock does not
  change it. Locks are counted; an unlock beyond the count fails.
- **Values**: Method 10's blob holds the values set with Method 9 plus three
  the service adds: `IOSurfaceName` (the creation name), `CreationProperties`
  (a dictionary: the creation properties, with
  `IOSurfacePixelSizeCastingAllowed` filled in), and
  `HorizontalDisparityAdjustment` (a 32-bit number, 0). Method 12 keeps
  those three.
- **Mach ports**: the real service returns a different port for every
  Method 14 call. `IsInUse` is true while the use count is above zero **or**
  while any send right to one of the surface's Mach ports exists (it became
  false again after the only right was deallocated). A second reference by
  look-up does not make it true.
- **Purgeable**: `OldState` is the state before the call; 3 changes nothing.

### 3.2 Attachment keys (Methods 20, 21)

| Key | Type | Default in Method 21 replies |
|---|---|---|
| `ChromaLocationTopField`, `ChromaLocationBottomField`, `FieldCount`, `FieldDetail` | uint64 | 0 |
| `ChromaSubsampling` | uint64 | 128 (`0x80`); 144 (`0x90`) when set |
| `PremultipliedAlpha` | uint64 | 0 |
| `TransferFunctionIndex`, `ColorPrimariesIndex`, `YCbCrMatrixIndex` | uint64 | 0 (values set in the boot: 13, 1, 6) |
| `GammaLevel`, `EDRFactor`, `ContentLightLevelInfo` | data, 8 bytes | zeros |
| `PixelAspectRatio` | data, 24 bytes | zeros |
| `MasteringDisplayColorVolume` | data, 32 bytes | zeros |
| `CleanAperture` | data, 40 bytes | zeros (a set value seen: u32 `0, 0, 0x3ea, 1, 0x426, 1, 0xffffffea, 2`) |

Method 21 returns what Method 20 stored, and the defaults for the rest.

## 4. Fixed records

### 4.1 SurfaceState (72 bytes, 18 × u32)

Sent with every reply that names a surface. The client keeps it as its
cached copy of the surface's layout and seed: with our test server leaving
it out of the replies of Methods 3–21 (but not of Method 2), creates, locks,
and cross-process mapping still worked, but `IOSurfaceGetSeed` stayed 0.

| Offset | Meaning | Observed |
|---|---|---|
| 0 | open | always 0 |
| 4 | surface ID | |
| 8 | allocation size in bytes | the computed size, or `IOSurfaceAllocSize` exactly as given (not page-rounded) |
| 12 | width | |
| 16 | height | |
| 20 | bytes per row | |
| 24 | open | always 0 |
| 28 | pixel format | FourCC as given |
| 32 | cache mode | `IOSurfaceCacheMode` as given (0, `0x400`, `0x700`) |
| 36 | plane count | 0 for non-planar surfaces, 2 for `'420v'` |
| 40 | bytes per element | 1 when not given or 0 |
| 44 | element width | 1 unless given |
| 48 | element height | 1 unless given |
| 52 | seed | starts at 0 |
| 56 | open | always 0 |
| 60 | bits 0–7: pixel-size casting allowed (1 by default, 0 when created with `IOSurfacePixelSizeCastingAllowed` false; `IOSurfaceAllowsPixelSizeCasting` reports it); bits 8–31: open — a value that grew by one with each surface the service created | |
| 64 | open | always 1 |
| 68 | open | always 1 |

### 4.2 Layout the service computes

When the creation properties do not give them (all observed with element
width and height 1):

- **Bytes per row** = width × bytes per element, rounded up to a multiple
  of **128** (alignment `Limits` word 2 + 1). Examples: 64×4 → 256;
  1×4 → 128; 1000×4 → 4096; 1398×4 → 5632; 146×8 → 1280.
- **Allocation size** = bytes per row × height, rounded up to a multiple of
  **16 384** (the page size; `Limits` word 1 + 1). Examples: 64×32 BGRA →
  16 384; 100×100 → 65 536; 1398×2034 → 11 468 800.
- Given values are used as given, even when not aligned (bytes per row 16
  for width 1; 4448 for width 1110; allocation size 8 017 920).
- The shared memory (§6) is the allocation size rounded up to 16 384.

### 4.3 PlaneState (72 bytes, 18 × u32)

Only for multi-planar surfaces (`'420v'` with `IOSurfacePlaneInfo`):

| Offset | Meaning |
|---|---|
| 0 | plane index × 65 536 (0, `0x10000`; meaning of the split open) |
| 4, 8 | plane width, height |
| 12 | plane offset |
| 16 | plane bytes per row |
| 20 | plane size |
| 40 | byte 0: bytes per element; byte 1: 0; byte 2: element width; byte 3: element height |
| others | 0 |

### 4.4 Limits (40 bytes, 10 × u32)

| Word | Value | Matches public call |
|---|---|---|
| 0 | 1 | open |
| 1 | `0x3fff` | `IOSurfaceGetPropertyAlignment(kIOSurfaceOffset)` = `0x4000` |
| 2 | `0x7f` | `IOSurfaceGetPropertyAlignment(kIOSurfaceBytesPerRow)` = `0x80` |
| 3 | `0x8000` | `IOSurfaceGetPropertyMaximum(kIOSurfaceBytesPerRow)` |
| 4, 5 | `0x4000` | maximum width, height |
| 6, 7, 8, 9 | 1, 0, 1, 0 | open |

Clients started normally when Method 0 failed or `Limits` was missing
(§7.2); the values above are what the macOS service sends.

## 5. Property blobs

### 5.1 Format

`PropertiesDictionary` values are XPC data holding the **OSSerialize binary
format** of xnu's libkern (public open source,
`libkern/libkern/OSSerializeBinary.h`): a u32 signature `0x000000D3`, then
records of a u32 key (bit 31 = last element of the enclosing collection;
bits 24–30 = type; bits 0–23 = length or count) and a payload padded to 4
bytes.

| Type | Code | Payload |
|---|---|---|
| dictionary | `0x01` | count = number of key/value pairs; the pairs follow |
| array | `0x02` | count = number of elements |
| number | `0x04` | length = bit width (64 or 32 seen); always 8 bytes |
| symbol | `0x08` | length includes the terminating NUL; used for dictionary keys |
| string | `0x09` | length without NUL; used for string values |
| data | `0x0A` | length in bytes |
| boolean | `0x0B` | value in the length field; no payload |
| object reference | `0x0C` | length = index of an earlier object; no payload |

**Clients use object references**: a value equal to an earlier one (for
example a height equal to the width) is sent as a reference. References
index every decoded object in order — collections, keys, and values —
counting from 0 at the root, and references themselves are not counted. A
service must resolve them. It may write blobs without references.

### 5.2 Creation keys seen

`IOSurfaceWidth`, `IOSurfaceHeight`, `IOSurfaceBytesPerElement`,
`IOSurfaceBytesPerRow`, `IOSurfaceAllocSize`, `IOSurfacePixelFormat`,
`IOSurfaceCacheMode`, `IOSurfaceMapCacheAttribute`,
`IOSurfacePixelSizeCastingAllowed`, `IOSurfaceElementHeight`,
`IOSurfaceName`, `IOSurfaceColorSpace`, `IOSurfaceICCProfile` (data,
3144 bytes), `IOSurfaceProtectionOptions`, `IOSurfaceTransferFunction`,
`IOSurfaceIsGlobal`, `IOSurfacePlaneInfo` (array of dictionaries with
`IOSurfacePlaneWidth`, `…Height`, `…Offset`, `…BytesPerElement`,
`…BytesPerRow`, `…Size`), `HorizontalDisparityAdjustment`, and three
SpringBoard-private keys (`kPaperboardIOSurfaceDeviceOrientationPropertiesKey`,
`…DeviceScale…`, `…InterfaceOrientation…`). The public keys are those of
`IOSurfaceRef.h` (level 1).

**The client adds `IOSurfaceName`** when the caller gives none: the
process name (`isprobe` for our probe; frameworks pass their own:
`QuartzCore`, `CoreUI`, `RenderBox`, `CoreImage`, `BaseBoard`,
`WebKit LayerBacking`).

### 5.3 Values blob (Method 10 reply)

A dictionary of the stored values (§3.1). It may contain any of the types of
§5.1, including nested dictionaries and arrays.

## 6. Shared memory

- The create and look-up reply carries `MemoryObject` as an XPC
  shared-memory object (`0xC000`): a u32 size, a u32 0, and a port
  descriptor holding a **send right to a memory entry** (a named entry made
  with `mach_make_memory_entry_64`). Size = the allocation size rounded up
  to 16 384.
- The client maps it at once, read-write and shared, before any lock: the
  base address is valid right after create or look-up. Each create or
  look-up maps it again (a second look-up in the same process got a
  different address of the same memory object).
- In the client the mapping has protection read-write, share mode
  `SM_TRUESHARED` (5), and the same VM object ID in every process that maps
  the surface. Writes are seen by every process at once: a child that looked
  the surface up by port saw the parent's pattern and the parent saw the
  child's write.
- The macOS service's memory carries VM tag 88 (`VM_MEMORY_IOSURFACE`,
  public `vm_statistics.h`); with our test server's untagged memory the
  clients behaved the same. A Ycode service should tag it 88 anyway.
- The surface Mach port from Method 14 is **not** a memory entry (mapping it
  failed). It is only a handle that the service recognises in Method 2.
- No locking protocol guards the memory: lock and unlock are messages to
  the service (Methods 4, 5) and do not change the mapping.

## 7. Results of the substitution experiments

### 7.1 Method

A throwaway iPhone Duo device on the 27.1 runtime was booted with our
interposer inserted into every job (Appendix A). It replaced each process's
connection to the service with one to a relay in the same process, which
recorded every message and forwarded it to the real service (or to our
test server). Our probe was also run under our bootstrap relay, which
substituted the service's port in the look-up reply. Both paths gave the
same traffic.

### 7.2 The test server (written from §2–§6)

Our test server answers all methods of §3 except 6 with the layouts above,
from its own memory entries. It was run (a) inside the relay for the probe
and (b) as a `user/<uid>` launchd job, with `backboardd` and SpringBoard
restarted against it. The device used R4's headless SimFramebuffer and had
the `com.apple.metal.simulator*` names denied (§8).

| Variation | Result |
|---|---|
| all methods | probe: every test gave the same results as against the real service (layout, seeds, values, use counts, purgeable, cross-process share by port and by ID), except the details noted in §3.1 (`IsInUse` with ports, new port per Method 14, three service-added values) and the VM tag. Boot: `backboardd` "initial main screen size:{1398, 2034}", SpringBoard stayed up, Settings launched |
| only Methods 0 and 2 answered; 3–21 refused | same boot result (lock, unlock, release, ports all failing); Settings also launched |
| Method 0 refused, all others answered | same boot result |
| Method 2 refused | screen size {0, 0}, SpringBoard traps in `BKSDisplayServicesStart` (R4's symptom) |
| replies with `?cpx` | create fails in the probe; boot as for Method 2 refused |
| no `Limits` | probe unaffected |
| no `SurfaceState` except in Method 2 replies | probe works; seeds are not updated |

### 7.3 Other checks

- `xpc_connection_enable_sim2host_4sim` changes the magic of an XPC
  connection's messages from `?cpx` to `!CPX` (our test program, which
  connects to a port of its own both ways).
- With the real Metal host service present, a `backboardd` using our test
  server's surfaces aborted in the Metal simulator driver
  (`-[MTLSimDevice newTextureWithDescriptor:iosurface:plane:]`, crash report
  frames): the host Metal service cannot use surfaces it does not know.

## 8. What a Ycode host service must implement

Requirements, in priority order. Items 1–7 are the minimum with which
`backboardd` and SpringBoard start and Settings launches (§7.2: every other
method was refused in that run; create and look-up are both Method 2 and
were not tested apart). Items 8–11 make surfaces behave as on macOS (seeds,
values, lifetime, in-use state) and are needed for long runs and for
stage 8, which reads pixels.

1. **Name.** Register a send right for `com.apple.IOSurface.Remote` into
   the guest's `user/<uid>` domain before any guest job runs (control
   operation 701, queued before the 808 reply, `launch-sim-control.md`
   §3.2, §5.1).
2. **Hand-shake.** Accept message `0x77303074` on the service port; keep
   the receive right of its descriptor 0 as the connection port and serve
   requests there; keep (and ignore) the send right of descriptor 1.
3. **Envelope.** Requests `0x10000000` with a send-once reply port;
   replies `0x20000000` with `MOVE_SEND_ONCE`, no voucher; ignore the
   request's voucher and `RAISEIMP` bit.
4. **Encoding.** Parse `!CPX` (and accept `?cpx`, `@cpx`) version-5
   dictionaries by key; **write `!CPX`**; set `COMPLEX` and one port
   descriptor per shared-memory or send-right value, in order.
5. **OSSerialize.** Decode creation and value blobs, including object
   references; encode value blobs (references optional).
6. **Create (Method 2 with `PropertiesDictionary`).** Validate width and
   height, compute bytes per row and allocation
   size by §4.2, allocate zeroed memory of the page-rounded size, make a
   read-write memory entry, assign a new surface ID, and reply
   `MemoryObject` + `ErrorCode` 0 + `SurfaceState` (§4.1). Refuse invalid
   properties with `0xe00002c2` (a zero size is invalid; refusing sizes
   above the `Limits` maxima is a design choice, not an observation).
7. **Look-up (Method 2 with `LookupID` or `MachPort`).** Find the surface
   by ID — for **any** surface of the guest, global or not — or by a port
   from Method 14, and reply as for create with the same memory entry;
   `0xe00002f0` when unknown; `0xe00002c2` when neither key nor properties
   are present.
8. **References and lifetime.** Count references per connection (create
   and look-up +1, Method 3 −1); free a surface when no connection holds it
   and no Method-14 port is alive; drop a connection's references when its
   connection port loses its senders (§2.5).
9. **Surface ports (Method 14).** Return a send right to a port the service
   owns and maps to the surface; watch it with a no-senders notification;
   `IsInUse` (Method 17) is true while the use count (Methods 15, 16) is
   positive or such a port has senders.
10. **State-only methods.** Lock/unlock with the seed rule and lock count
    (4, 5); values (9–12) with the three service-added values; purgeable
    (13); attachments (20, 21) with the defaults of §3.2; plane state (6)
    for planar surfaces. Reply `SurfaceState` and `SurfaceID` with all of
    them. Answer unknown methods with `ErrorCode` `0xe00002c7`.
11. **Connect (Method 0).** Reply `Limits` (§4.4), `ErrorCode` 0,
    `ProtocolVersion` 1.

Design notes (not observations):

- The service's memory is guest memory shared between guest processes;
  in Ycode the VMM can implement the memory entry as one host allocation
  mapped into each guest task. Stage 8's display path reads the display
  buffers (§1.2) from the same allocation.
- Ycode must not offer `com.apple.metal.simulator*` host names unless its
  Metal service understands its own surfaces (§7.3); with them absent,
  `backboardd` renders without Metal (`simframebuffer.md` §7 item 11).

### Surfaces made by a Ycode host (2026-10-27)

Ycode's Metal host answers `metal-sim-protocol.md` §5.10 (`messageType`
19, shared textures) with a surface it makes itself in the IOSurface
service (`IOSurfaceHostService.makeSharedTextureSurface`), shaped as the
reference's (visionos.md §10.10.2, §10.11.3): width, height, bytes per
row, pixel format and plane count 0, bytes per element 1, the allocation
size the Metal host gives (op 22's size + 16; the memory is rounded up to
16 KiB), name "Metal", and the Metal host's creation properties (numbers,
64-bit when the value needs it; `kMetalRegistryID` and the `kMetal…`
texture description) with `IOSurfaceName` added. Method 10 returns them
under `CreationProperties`, with `IOSurfaceName` and
`HorizontalDisparityAdjustment` 0, to every process. It gets a Method-14
port (a host-task receive right in the service's port set, with a
no-senders request) whose send right the Metal reply carries; the guest
looks the surface up by it (Method 2 with `MachPort`) as any other. The
surface lives while a port has senders or a connection references it.
For `messageType` 20 the Metal host asks the service for the surface ID
and numeric creation properties behind a Method-14 port
(`creationNumbers(forPort:)`).

## 9. Open questions

1. Methods 1, 7, 8, 18, 19 and above 21: never sent in a boot, a Safari
   launch, or by the probe. The exported key names of §Evidence (level 4)
   suggest calls for shared events (`EventPort`, `EventOperation`,
   `EventValue`), client-provided memory (`ClientProvidedShmem`,
   `IOSurfaceWrapClientMemory`), data properties (`Buffer`, `BufferSize`),
   per-category use counts (`Category`), extra data, accelerator binding,
   and debug lists. Their numbers and layouts are open.
2. SurfaceState offsets 0, 24, 56, 64, 68 and bits 8–31 of offset 60;
   Limits words 0 and 6–9; PlaneState offset 0's split.
3. `NewState` bit 8 (`0x101`).
4. Layout for element width or height above 1, and for planar formats
   without `IOSurfacePlaneInfo` (the probe always gave plane info).
5. Whether the service ever sends a message on the client's port of the
   hand-shake (never seen), and what the client does with the
   `ProtocolVersion` value.
6. Large property blobs (data above 16 KiB, OOL payloads): not seen.
7. Whether apps that use Metal, video, or the camera add calls not seen
   here.


## Evidence

| Claim | Level | Source |
|---|---|---|
| Public API, property key names, lock and purgeable constants (§3, §5.2) | 1 | `IOSurface.framework` headers `IOSurfaceRef.h`, `IOSurfaceTypes.h` (iPhoneSimulator 27.1 SDK) |
| IOReturn codes (§2.4), `VM_MEMORY_IOSURFACE` = 88, `SM_TRUESHARED` = 5, `MACH_MSGH_BITS_RAISEIMP` (§2.3, §6) | 1 | public `IOKit/IOReturn.h`, `mach/vm_statistics.h`, `mach/vm_region.h`, `mach/message.h` |
| OSSerialize binary constants and record rules (§5.1) | 1 | xnu open source `libkern/libkern/OSSerializeBinary.h` and `libkern/c++/OSSerializeBinary.cpp` (Apple OSS GitHub), read as documentation |
| XPC object encoding apart from the magic | 3 | `bootstrap-wire.md` §3 (earlier captures), confirmed by every capture here |
| Exported names of the runtime's IOSurface framework (556, incl. 48 `IOSurfaceRemoteKey*` data names and `kIOSurfaceRemoteServiceName`), `_Emulated` variants, linked libraries; ObjC classes and ivars (`IOSurface`, `IOSurfaceSharedEvent`, `IOSurfaceMemoryPool`, `_IOSurfaceDebugDescription`, …) | 4 | `isnames.c` (export trie of the loaded image, names only) and R4's `objcdump.m`, run in the simulator |
| Wire keys equal the suffixes of the `IOSurfaceRemoteKey*` names (§9 item 1 uses this for unseen keys) | 3 + 4 | every observed key has such a name; unseen ones are an inference, marked open |
| Who connects, when, how often, per process (§1) | 3 | `isinterpose.c` in every job of two boots plus Settings and Safari launches; `vmmap` of Settings (no IOSurface region) |
| `xpc_connection_enable_sim2host_4sim` on the connection (§1.1) | 3 | interposer log of the call on the client's connection |
| `!CPX` magic and its link to sim2host (§2.1, §7.3) | 3 | relay captures; `xpcmagic.c` with and without the call |
| Hand-shake, request, reply envelopes, no server-initiated messages (§2.2–§2.4) | 3 | relay captures (22 138 request/reply pairs in one boot) |
| Methods, keys, values, errors, behaviors (§3), records (§4), layouts (§4.2) | 3 | probe `isprobe.c` tests under `ismitm.c`, and the boot captures |
| Memory entry, mapping attributes, sharing (§6) | 3 | relay's read-only map test of received rights (size, protection, share mode only; no bytes read); probe's region queries and pattern checks of its own memory |
| Surface freed at client exit (§2.5) | 3 | probe `leak` then `lookupid` in a new process |
| Display buffers and their order (§1.2) | 3 | boot capture of `backboardd` |
| Requirements and refusal results (§7.2, §8) | 3 | `isserver.h` (in `ismitm.c` and as `isserve.c` job), `run-fake-restart.sh`, `backboardd` log lines, crash reports |
| `SimRenderServer` serves the name on macOS | 3 | sender pid of the replies in the receive trailer, `ps` |
| Metal abort with foreign surfaces (§7.3) | 3 | crash reports (frame names, black-box output) |
| Design notes (§8) | — | Ycode design |

No disassembly or decompilation was used (level 5 not used). No
`.claude/Xcode.app`, `research/dirty/`, or Ghidra project was opened. No
memory was read at addresses taken from messages, except out-of-line
regions copied into our own process by the kernel (none occurred in these
captures); received memory entries were mapped read-only only to record
their size and protection. Crash reports and log lines were read as
black-box output.

## Appendix A. Programs and method

Sources (ours) in `research/experiments/simulator/iosurface-remote/`; each
is built with `xcrun --sdk iphonesimulator clang -target
arm64-apple-ios27.0-simulator` into a directory outside the repo
(`build.sh <out>`).

| File | What it is |
|---|---|
| `isproxy.h` | the recording relay: a port set of proxy ports; records header, descriptors, and our decoding of `!CPX`/`?cpx` dictionaries and OSSerialize blobs; replaces reply ports and hand-shake ports with proxies so both directions pass through it |
| `ismitm.c` | runs a program with a bootstrap port of ours (as `bsmitm`, `bootstrap-wire.md` §A), relays bootstrap traffic, and substitutes the proxy for the service's port in the look-up reply; copies the program's output into the log; `YC_IS_FAKE=1` points the proxy at the test server instead |
| `isinterpose.c` | `DYLD_INSERT_LIBRARIES` dylib for every job of a boot: replaces the client's connection with one to an in-process relay (`xpc_endpoint_create_mach_port_4sim`, `xpc_connection_create_from_endpoint`); optional redirect to the test server and a deny list |
| `isprobe.c` | IOSurface client written against the public API only: create, lock, values, use counts, purgeable, ports, XPC objects, formats, cross-process share by port and by ID, global, casting flag, leak, in-use |
| `isserver.h`, `isserve.c` | the test server of §7.2 (written from this spec) and a launcher that serves it as a launchd job (`bootstrap_check_in`) |
| `run-fake-restart.sh` | loads the test server job with a refusal list and restarts `backboardd` and SpringBoard against it |
| `xpcmagic.c` | checks the magic with and without sim2host |
| `isnames.c` | export-trie name lister |
| `summarize.py` | per-process method, key, and error summary of relay logs |

Method notes: the throwaway device was created and deleted by this agent.
Job program paths in a guest launchd plist are resolved under the runtime
root, so the job plist names the test server with `../` components.
Raw captures stayed in the agent's scratch directory.
