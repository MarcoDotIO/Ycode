# Spec: the simulator Metal host protocol (`com.apple.metal.simulator`)

Status: **reference** for stage 8a (`stage8-contract.md` §2, agent R7). It
describes the host service that the iOS 27.1 runtime (24A94401) uses for
all Metal work of guest processes: how a process connects, the messages on
the connections, how resources and their memory are shared, the form in
which shaders reach the host, the encoding of pipeline descriptors and
command buffers, completion and synchronization, the part Metal plays in
presentation, and what the processes of a boot to the home screen use.

Every fact comes from public Metal documentation and headers (level 1),
from exported names and ObjC class, selector, ivar and type-encoding names
of the runtime's frameworks read by our own programs (level 4), and from
black-box runs of our own programs on this Mac (level 3): a recorder
inserted into every job of a throwaway device and into our own Metal test
programs, a Mach-level relay (R5's), and an in-process test server written
from the captures. No Apple binary was disassembled or decompiled. The
XPC object encoding is that of `bootstrap-wire.md` §3, the Mach envelope
that of `iosurface-remote.md` §2. All integers are little-endian.

Terms:

- **The driver**: the runtime's `MTLSimDriver.framework` (bundle version
  382.5.3). `MTLCreateSystemDefaultDevice` in a guest process returns its
  device object (class `MTLSimDevice`, name "Apple iOS simulator GPU").
  Its encoder classes derive from `MetalSerializer.framework`'s
  `MTLSerializer…CommandEncoder` classes, so the command stream (§8) is
  that framework's serialized form.
- **The host**: the process that answers. On macOS it is CoreSimulator's
  `SimMetalHost` XPC service (`SimRenderingServices.simdeviceio`), several
  processes per booted device (§1.2). Its crash frames name the macOS
  `MTLSimImplementation` framework (`MTLSimApplicationContext`,
  `MTLSimulatorHandleEvent`).
- **Message**: one XPC dictionary. Its key `messageType` (uint64) selects
  the message kind (§2.4). Most messages carry a **command record** in the
  data value `command`.
- **Record**: u32 opcode, u32 total length in bytes (header included), then
  the body. Records appear alone (in `command`) and in sequences (in
  command-buffer segments, §8).
- **Ref**: a u32 handle for a host object (§3).
- **Segment**: a 64 KiB data value of a command-buffer submission (§8.1).
- **Recorder**, **relay**, **test server**: our programs (Appendix A).

## 1. Names, processes and connections

### 1.1 Which name a process uses

For each connection it opens, the driver first calls `bootstrap_look_up`
for `com.apple.metal.simulator.<process name>` (the name `getprogname`
returns). If that succeeds it connects to that name, otherwise to
`com.apple.metal.simulator`. Either way the connection is made with
`xpc_connection_create_mach_service` (flags 0), then marked with
`xpc_connection_enable_sim2host_4sim`, so the wire encoding is `!CPX`
(`iosurface-remote.md` §2.1).

In a boot of the iPhone Duo device type, the per-process look-up
succeeded only for `backboardd` and `SpringBoard` (the host registers
`.SpringBoard`, `.SBRendererService`, `.backboardd`, `.PineBoard`,
`.HeadBoard`, `.Carousel`, `launchd-sim.md` §6.3). Every other process
(`iconservicesagent`, poster extensions, `WidgetRenderer_Default`,
`chronod`, `assetsd`, our probes, …) got 1102 and used the plain name.

### 1.2 Which host process answers

The sender of the replies (`xpc_connection_get_pid` of the client's
connection) showed three different host processes for one device:

| Client | Name used | Host process |
|---|---|---|
| our probe (any app-like process) | `com.apple.metal.simulator` | `SimMetalHost` A |
| `SpringBoard` | `com.apple.metal.simulator.SpringBoard` | `SimMetalHost` B |
| `backboardd` | `com.apple.metal.simulator.backboardd` | `SimMetalHost` C |

So the per-client names give the system shell and the compositor host
processes of their own, apart from the one that serves apps. A crash of
host A (our probe's zero-attachment render pass, §8.6) ended only our
probe's connections; host C, serving `backboardd`, kept its process
id. Why the names exist beyond this separation is not documented; a Ycode host may serve all names with one service (§12).

### 1.3 Three connections per process

At its first Metal call (`MTLCreateSystemDefaultDevice`) the driver opens
**three** connections to the same name, one after another, each with a
hand-shake (§2.3). They differ in `connectionType` and in what travels on
them (all captures of a boot plus all probe runs):

| `connectionType` | What the client sends on it |
|---|---|
| 0 | command-buffer submissions (`messageType` 6), texture read-backs (10), shared-event value get and set (12, ops 30, 41), the limits query (12, op 37). Completion events (§8.5) arrive on this connection |
| 1 | everything that creates, changes or releases objects: buffers (1), queues (7), textures, samplers, depth-stencil states (8), texture uploads (9), device queries (12), IOSurface textures (13), releases (14), functions (15) |
| 2 | pipeline creation only (12, ops 11 and 14) |

A process that uses Metal keeps the three connections for its life. No
process opened more than three.

## 2. Wire format

### 2.1 Mach envelope

The same as `iosurface-remote.md` §2.2–§2.4 (checked with R5's relay on
our probe): connection hand-shake `msgh_id` `0x77303074` with a receive
right (descriptor 0, the connection port) and a send right (descriptor 1,
the client's event port); requests `0x10000000`; replies `0x20000000`
with `MOVE_SEND_ONCE`; payload version 5. The relay decodes all three
magics without recording which one it saw; the payload is `!CPX`
because the driver marks every connection with
`xpc_connection_enable_sim2host_4sim` (`iosurface-remote.md` §7.3).

Differences from the IOSurface service:

- **One-way messages.** `messageType` 6 (submission) and 14 (release)
  are sent without a reply port (`msgh_bits` remote none).
- **Server-initiated messages.** The host sends completion events (§8.5)
  as `0x10000000` messages, no reply port, to the send right the client
  gave in descriptor 1 of the hand-shake of connection type 0.
- **Large data.** Segments (64 KiB) exceed the inline limit of XPC data
  and travel as port descriptors (data by memory entry,
  `bootstrap-wire.md` §3.2): a submission with two segments carried two
  port descriptors. Large texture uploads (§5.3) are bigger still and
  presumably travel the same way (not checked at the Mach level).

### 2.2 Keys

All messages are XPC dictionaries. Keys seen:

| Key | Type | Where |
|---|---|---|
| `messageType` | uint64 | every client message and every event |
| `version`, `processRef`, `connectionType` | uint64 | hand-shake request (§2.3) |
| `version`, `processRef`, `registryID`, `hostFeatureProfile` | uint64 | hand-shake reply |
| `command` | data | a record (§2.4) |
| `replyData` | data | most replies; a fixed record per operation |
| `sharedMem` | shared memory | buffer creation (§5.1), texture read-back (§5.3) |
| `options`, `bufferIndex`, `length` | uint64 | buffer creation |
| `bufferRef`, `commandQueueRef` | uint64 | replies to buffer and queue creation |
| `maxCommandBufferCount` | uint64 | queue creation |
| `iosurface` | Mach send right | IOSurface texture (§5.4), opening a shared-texture handle (§5.11) |
| `iosurfaceXPCObject` | Mach send right | reply to a shared texture (§5.10) |
| `label` | string | opening a shared-texture handle that has a label (§5.11) |
| `functionIR` | data | function creation (§6) |
| `segments` | array of data | submission (§8.1) |
| `commandQueue`, `commandBufferRef` | uint64 | submission, events |
| `status`, `error` | uint64 | events |
| `startTime`, `endTime` | double | events |

### 2.3 Hand-shake (`messageType` 0)

| Request key | Value |
|---|---|
| `messageType` | 0 |
| `version` | 1 |
| `connectionType` | 0, 1 or 2 (§1.3) |
| `processRef` | 0 on the first connection; on the second and third, the value the host returned on the first |

| Reply key | Value from the macOS host |
|---|---|
| `version` | 10 |
| `processRef` | a small number per client process (1, 8, 27, … — increasing per host process) |
| `registryID` | `0x100000473`; the driver reports it as `MTLDevice.registryID` |
| `hostFeatureProfile` | 10 |

With our test server, the device was created and worked with any
`version` (1, 9, 10, 11) and any `hostFeatureProfile` (0, 1, 5, 9, 11, 12,
20), and even with an empty reply dictionary. No device property we read
(§4) changed with these values. Their meaning is open.

### 2.4 Message types

| `messageType` | Connection | Reply | Meaning | Section |
|---|---|---|---|---|
| 0 | each | yes | hand-shake | §2.3 |
| 1 | 1 | `bufferRef` | new buffer | §5.1 |
| 6 | 0 | none (events later) | submit a command buffer | §8 |
| 7 | 1 | `commandQueueRef` | new command queue | §8.1 |
| 8 | 1 | `replyData` (u32 ref) | new texture (op 1), sampler (op 3), depth-stencil state (op 4) | §5 |
| 9 | 1 | empty | replace texture region (op 2) | §5.3 |
| 10 | 0 | empty | read texture region into shared memory (op 5) | §5.3 |
| 12 | 0, 1, 2 | `replyData` (per op) or empty | device operation; op table §4.2 | §4–§7 |
| 13 | 1 | `replyData` (u32 ref, u32 0) | texture over an IOSurface (op 47) | §5.4 |
| 14 | 1 | none | release an object (op 1000–1013) | §3 |
| 15 | 1 | `replyData` (u32 ref, u32 0) | new function (op 15) | §6 |
| 17 | 1 | `eventPort` (send right), `labelTraceID` (uint64 0) | `newSharedEventHandle`: request `eventRef` (uint64) | §5.8 |
| 18 | 1 | `replyData` (u32 ref, u32 0) | `newSharedEventWithHandle:`: request `eventPort` (send right) and `command` (op 40, u32 0) | §5.8 |
| 19 | 1 | `iosurfaceXPCObject` (send right), `replyData` (u32 ref, u32 0); the driver also reads `fatalError` and `error`, which the reference never sent | `newSharedTextureWithDescriptor:`: request `command` (op 42, the texture descriptor) | §5.10 |
| 20 | 1 | `replyData` (u32 ref, descriptor words 1–8) | `newSharedTextureWithHandle:`: request `command` (op 43, u32 0), `iosurface` (send right), `label` (optional) | §5.11 |
| 100 | host → client | — | command buffer scheduled | §8.5 |
| 101 | host → client | — | command buffer completed | §8.5 |

Message types 2–5 and 11 were never sent. Types 17 and 18 were added
from visionos.md §10.6.5 (2026-10-27; RealityKit uses them in backboardd
and datamigrator). Type 19 was added from visionos.md §10.9 (2026-10-27,
Ycode's guest; wakeboardd's compositor uses it on visionOS); its reference
reply and type 20 from visionos.md §10.10 (2026-10-27). Replies to requests that expect
no data are empty dictionaries.

## 3. References

- The host chooses every ref except command-buffer refs and returns it in
  the creation reply. Refs are small integers counted per kind; a released
  ref is reused (a texture created, released and created again got ref 1
  both times).
- **Buffers and textures share one counter** (a texture created after two
  buffers got ref 3); functions, render pipelines, compute pipelines,
  samplers, depth-stencil states, heaps, fences, events, queues and
  argument-buffer objects each have their own. Command-encoder records
  name buffers and textures by these refs; 0 means none (`nil`).
- **Release** (`messageType` 14, one-way): a 12-byte record, opcode by
  kind, body u32 ref.

| Op | Kind released | Evidence |
|---|---|---|
| 1000 | buffer | isolated (probe) |
| 1001 | texture (also IOSurface textures and views) | isolated |
| 1002 | depth-stencil state | isolated |
| 1003 | sampler state | isolated |
| 1005 | function | isolated |
| 1006 | compute pipeline | isolated |
| 1007 | render pipeline | isolated |
| 1008 | command queue | inferred: SpringBoard created queue ref 1 and released 1008 ref 1; counts across the boot match |
| 1009 | fence | isolated |
| 1010, 1011 | argument-buffer layout and argument encoder (which is which: open) | probe |
| 1012 | heap | counts in a boot (8 heaps, 8 releases) |
| 1013 | event or shared event | isolated |

## 4. Device and capability queries

### 4.1 What the driver answers itself

Almost every `MTLDevice` property is answered in the guest without a
message. Values seen on our probe (with the macOS host and with our test
server alike): `supportsFamily` true only for Apple1, Apple2 and Common1;
`maxThreadsPerThreadgroup` at most 512×512×512;
`maxThreadgroupMemoryLength` at most 16 384; `maxBufferLength` 256 MiB;
`hasUnifiedMemory` false; `argumentBuffersSupport` tier 1;
`readWriteTextureSupport` none; texture sample counts 1 and 4; largest 2D
texture 8192 (a height of 8193 fails validation in the guest);
`sparseTileSizeInBytes` 16 384; no ray tracing, function pointers,
dynamic libraries, barycentrics, BC formats, lossy compression, or
indirect command buffers (`newIndirectCommandBufferWithDescriptor:` aborts
"not supported in the simulator").

### 4.2 Device operations (`messageType` 12)

`command` holds one record. Ops seen, with request body and reply
(`replyData`):

| Op | Call | Request body | Reply |
|---|---|---|---|
| 7 | `newTextureViewWithPixelFormat:` | u32 0, u32 parent texture ref, u32 pixel format | u32 new texture ref, u32 0 |
| 8 | `newTextureViewWithPixelFormat:textureType:levels:slices:` | u32 0, u32 parent, u16 pixel format, u16 texture type, u64 level location, u64 level length, u64 slice location, u64 slice length | u32 ref, u32 0 |
| 11 | new compute pipeline (connection 2) | keyed descriptor (§7) | 24 bytes: u32 ref, u32 0, u16 1024, u16 32 (the macOS values; the probe then reported `maxTotalThreadsPerThreadgroup` 512 and `threadExecutionWidth` 32), 12 bytes 0 |
| 13 | `newFence` | u32 0 | u32 ref, u32 0 |
| 14 | new render pipeline (connection 2) | keyed descriptor (§7) | u32 ref, u32 0 |
| 16 | argument-buffer layout (`newArgumentEncoderWithBufferIndex:` on a function, and `newArgumentEncoderWithArguments:`) | u32 0, u32 payload length, u32 0, a layout description (magic `MTLPSBIN`, §4.3.1) | 16 bytes: u32 layout ref, u32 0, u32 `0xffff0001`, u32 `0xffffffff` (the same for every layout; meaning open) |
| 17 | argument encoder from a layout | u32 0, u32 layout ref | u32 encoder ref, u32 0, **u16 alignment, u16 encoded length** (corrected by OBS-ARGBUF, §4.3.3: the reply word `0x00180008` is alignment 8, length 24), u32 0 |
| 19 | argument-encoder set call | §4.3.4 (corrected by OBS-ARGBUF: the index is 24 bits, a count follows, range forms) | empty. **The host writes the members** into the argument buffer's shared memory at the offsets of op 16's description (§4.3.2, §4.3.5); the driver writes nothing |
| 20 | `newHeapWithDescriptor:` | u32 0, u64 size, u16 resource options, u16 0 | u32 ref, u32 0 |
| 21 | heap `newTextureWithDescriptor:` | u32 0, u32 heap ref, texture descriptor **words 1–8** (§5.2, without word 0), 12 bytes 0: 52 bytes (corrected 2026-10-27, see below) | u32 texture ref, u32 0 |
| 22 | `heapTextureSizeAndAlignWithDescriptor:` | texture descriptor **words 1–8** (§5.2, without word 0): 32 bytes | u64 size, u64 alignment (352 768, 128 for 256×256 BGRA8 with mipmaps; the reference's answers follow the rule of visionos.md §10.8.3, which a Ycode host uses) |
| 23 | `heapBufferSizeAndAlignWithLength:options:` | u64 length, u16 options, u16 0 | u64 size, u64 alignment (1000 → 1000, 256) |
| 24 | heap `newBufferWithLength:options:` | u32 0, u32 heap ref, u64 length, u64 0, u64 options | u32 buffer ref, u32 0 |
| 25 | (heap resources; one u32 ref) | u32 ref | 1 byte (meaning open) |
| 27 | texture view with swizzle (from a descriptor with `swizzle`) | as op 8, then u32 swizzle (one byte per channel r, g, b, a, `MTLTextureSwizzle` values) | u32 ref, u32 0 |
| 28 | `newEvent`, `newSharedEvent` | u32 0 | u32 ref, u32 0 |
| 30 | shared event `setSignaledValue:` (connection 0) | u32 ref, u64 value | empty |
| 31 | heap size query | u32 heap ref | u64 size, u64 size, u64 used size (or 8 bytes; open). The reference's heap `size` and `currentAllocatedSize` are the requested size rounded up to a multiple of 16 384 (visionos.md §10.8.3); a Ycode host grants heaps (op 20) in those units |
| 32 | `maxAvailableSizeWithAlignment:` | u32 heap ref, u64 alignment | u64 |
| 33 | `minimumLinearTextureAlignmentForPixelFormat:` | u32 pixel format | u64 (16 for BGRA8) |
| 34 | `minimumTextureBufferAlignmentForPixelFormat:` | u32 pixel format | u64 (16) |
| 35 | `constantDataAtIndex:` | u32 encoder ref, u32 argument-buffer ref (the last kind-0 set call's), u32 argument index, u32 0 | u64: the member's byte offset from the start of the argument buffer (argument-buffer offset plus member offset; §4.3.6) |
| 37 | limits (connection 0, once per process) | u32 0 | u64 max threads per threadgroup x, y, z, u64 max threadgroup memory (macOS: 1024, 1024, 1024, 32 768; a Ycode host answers its GPU's limits with z raised to at least 512, so the guest keeps its own cap of 512 as with the reference, visionos.md §10.6.1) |
| 38 | buffer `gpuAddress` | u32 buffer ref | u64 address (host-chosen, e.g. `0x100000f8000`) |
| 39 | sampler `gpuResourceID` (when `supportArgumentBuffers`) | u32 sampler ref, u32 8 | u64 resource ID |
| 41 | shared event `signaledValue` (connection 0) | u32 ref | u64 value |

**Heap texture descriptors (correction, 2026-10-27, level 3).** Ops 21
and 22 carry the descriptor without its leading zero word. Captured from
Ycode's own host during a visionOS 27.0 boot (backboardd's RealityKit
renderer creates heap textures at start; `YCODE_METAL_DUMP_OPS`): op 22
bodies were 32 bytes, for example word 1 `0x00460042` (2D, GPU-optimized,
usage 0, RGBA8Unorm 70), then width, height, depth 1, levels and samples
1, array length 1 with options `0x20`, and a zero u64; op 21 bodies were
52 bytes (u32 0, u32 heap ref, the same 32 bytes, 12 zero bytes). Read
with word 0, op 22 ran out of bytes (refused as malformed) and op 21 read
pixel format 0. iOS boots under Ycode showed the same op-22 refusal. A
Ycode host accepts both forms (32/36 and 52/56 bytes).

**Op 37 is the only capability query.** The driver takes, for each of the
four limits, the smaller of the reply and its own cap (512, 512, 512,
16 384): our test server's reply (256, 128, 64, 8192) appeared exactly in
`maxThreadsPerThreadgroup` and `maxThreadgroupMemoryLength`; larger
values and a missing reply both left the caps. No pixel-format, family or
feature query reaches the host.

Ops 26, 29, 36 and above 41 were not seen as device operations (op 40 appears only as the `command` of `messageType` 18, §5.8). The names of the
deserializer's device-level methods (Evidence, level 4) suggest the
remaining ones: a buffer `didModifyRange`, a shared-event wait, a
resource-alias test, unique identifiers and shared events with an event
port. Their numbers are open.

### 4.3 Argument buffers (ops 16, 17, 19, 35; agent OBS-ARGBUF, 2026-10-30)

Observed on this Mac with the iOS 27.0 runtime (24A434), throwaway device
`ycode-test-argbuf-ios27` (iPhone 18 Pro), our probe `argprobe.m` run
with `simctl spawn` under the recorder, and the recorder's test server for
the "who writes" question. Level 3. The probe made 32 layouts: 25 from our
own shader structs (`newArgumentEncoderWithBufferIndex:`) and 7 from
argument descriptors (`newArgumentEncoderWithArguments:`). For each it
filled a shared buffer with a known byte, set every member to a distinct
value, and compared the bytes with the function's reflection and with
`constantDataAtIndex:`. The device reports `argumentBuffersSupport` tier 1.

The sequence for one encoder: op 16 (the layout description) returns a
layout ref; op 17 (encoder from that layout) returns the encoder ref, its
alignment and encoded length; then op 19 set calls, the first of kind 0
naming the argument buffer and offset; op 35 for each `constantDataAtIndex:`.
Ops 16, 17, 19 and 35 are synchronous device operations (`messageType` 12,
connection 2). Releases 1010 and 1011 come in pairs when an encoder goes
away (which ref kind each names is still open, §13).

#### 4.3.1 The layout description (op 16)

Record body: u32 0, u32 payload length *P*, u32 0, then *P* payload bytes,
zero-padded so the record length is a multiple of 4. All integers are
little-endian and **unaligned** (names of any length sit between them).

**Payload:**

| Bytes | Field |
|---|---|
| 8 | magic `MTLPSBIN` |
| 4 | u32 2 (every capture; a format version) |
| … | the top-level **struct** |

**Struct:** u32 serial number, u32 member count, then the members. The top
level is serial 1; every further struct in the description (a member of
struct type, the element of a struct array, the pointee of a buffer) takes
the next number in the order it appears, depth first, even when the type
repeats (two members of the same type got serials 2 and 3).

**Member:**

| Field | Meaning |
|---|---|
| name | NUL-terminated; the field name in the shader (empty for descriptor-built layouts) |
| u32 offset | **byte offset of the member within its enclosing struct** |
| u32 argument index | the member's `[[id(n)]]` (relative to the enclosing struct), or `MTLArgumentDescriptor.index` |
| u32 type code | 57 single argument, 1 struct, 2 array |
| u64 | 0 |
| type body | by type code, below |

**Type bodies:**

| Code | Body |
|---|---|
| 57 | u32 argument count (always 1), then the argument record |
| 1 | a struct (serial, count, members), then u64 `0xFFFFFFFFFFFFFFFF` |
| 2 | u32 element count, u32 element type code (57 or 1), u32 stride in bytes, u32 argument-index stride, u64 0, then the element's type body (for code 57 the argument record names the first element) |

**Argument record:**

| Field | Meaning |
|---|---|
| name | NUL-terminated (repeats the member's name) |
| u8 kind and access | bits 0–4 the kind: **1** buffer in the constant address space, **2** buffer in the device address space, **4** texture, **5** sampler, **8** inline data (a value stored in the argument buffer itself). Bits 5–6 the access (`MTLBindingAccess`: 0 read-only, 1 read-write, 2 write-only). Seen: 0x01 `constant T *`, 0x02 `const device T *` and descriptor buffers with read-only access, 0x22 `device T *`, 0x04 / 0x24 / 0x44 textures with `access::sample`/`read`, `read_write`, `write`, 0x05, 0x08 |
| u8 | 2 (every capture) |
| u16 | 0 |
| u32 argument index | as the member's |
| u32 array length | *n* for a resource array of the `array<texture2d<float>, n>` / `array<sampler, n>` form, else 1 |
| kind fields | below |
| u64 | `0xFFFFFFFFFFFFFFFF` |

Kind fields:

- **Buffer (1, 2) and inline data (8):** u32 data type (`MTLDataType` of
  the pointee or of the value: 3 float, 6 float4, 15 float4x4, 29 int, 1
  struct; 0 for descriptor-built buffers), u32 0, u32 0, u32 alignment,
  u32 size (of the pointee or the value; descriptor-built buffers say 1
  and 0; `constant` pointees report alignment 256), then u32 pointee
  struct serial, 0 when there is none. When it is not 0 the pointee
  struct's member count and members follow (no terminator of their own).
- **Texture (4):** u32 0, u32 `MTLTextureType`, u32 0. A `depth2d` member
  is described as type 2 with nothing that marks depth.
- **Sampler (5):** u32 0.

Every description the probe produced (32 layouts, 90 to 1140 bytes)
parses exactly to its end with this grammar.

#### 4.3.2 Where each member is: the offset rule

**The description carries each member's offset, and the host writes there.**
Argument ids are names, not positions. Gaps between ids leave no gap in the
buffer.

| Layout (our shader structs; `id` in brackets) | Offsets written | Encoded length, alignment |
|---|---|---|
| buffer (0), texture (1), sampler (2) | 0, 8, 16 | 24, 8 |
| buffer (0), texture (5), sampler (9) | 0, 8, 16 | 24, 8 |
| buffer (200), buffer (201), texture (230), sampler (231) | 0, 8, 16, 24 | 32, 8 |
| buffer (1) | 0 | 8, 8 |
| buffer (1000) | 0 | 8, 8 |
| float (3), buffer (10), float4 (11), sampler (40) | 0, 8, 16, 32 | 48, 16 |
| buffer (0), float (1), buffer (2), half (3), texture (4) | 0, 8, 16, 24, 32 | 40, 8 |
| float, float4, int, float3, half, char, float4x4, buffer, packed_float3, float2, uint (0–10) | 0, 16, 32, 48, 64, 66, 80, 144, 152, 168, 176 | 192, 16 |
| 15 buffers (0–14), visionOS RealityKit's shape | 0, 8, …, 112 | 120, 8 |
| one float (0) | 0 | 4, 4 |
| half (3), char (4) | 0, 2 | 4, 2 |

Rules, all consistent with every capture:

1. **Order.** A shader struct's members are laid out in declaration order.
   The shader compiler requires ids to increase in declaration order (an
   id below the previous member's id plus its slot count is a compile
   error, "minimum is *n*"), so declaration order is id order. A
   descriptor-built layout keeps the **order of the descriptor array**,
   not index order (texture 5, buffer 0, samplers 2–4 were placed at 0, 8,
   16, 24, 32).
2. **Sizes and alignments.** Buffers (any address space, also pointers to
   structs), textures and samplers take 8 bytes at 8-byte alignment.
   Inline data takes the Metal shading language size and alignment of its
   type: char, uchar, bool 1/1; short, half, uchar2 2/2; float, int, uint
   4/4; float2, half4, ulong 8/8; float3, float4 16/16; packed_float3
   12/4; float2x3 32/16; float4x4 64/16.
3. **Arrays.** A resource array of the `array<…, n>` form (argument record
   array length *n*) has element *k* at the member offset plus 8*k*,
   argument index plus *k*. An array member (type code 2) has element *e*
   at the member offset plus *e* × stride, argument index plus *e* × the
   index stride. Descriptor-built arrays (`arrayLength` 4) arrive as type 2
   with stride 8 and **index stride 0**, and their elements still take
   consecutive indices 10, 11, 12, 13, so a host treats index stride 0 as 1.
   A C array of inline data (`float fa [[id(20)]] [3]`) has stride 4 and
   indices 20–22.
4. **Nesting.** A member inside a struct member (or inside an element of a
   struct array) is at the outer member's offset plus its own, with
   argument index the outer index plus its own: struct `In { buffer;
   texture; float; }` at ids 0 and 10 placed members 0–2 at 0, 8, 16 and
   10–12 at 24, 32, 40. `array<In2, 2>` (In2 = buffer, sampler) has stride
   16 and index stride 2.
5. **Length and alignment** (op 17's reply). The alignment is the largest
   alignment of any member (8 as soon as there is a buffer, texture or
   sampler); the encoded length is the end of the last member (offset plus
   size) rounded up to that alignment. The reflection's `bufferDataSize`
   (from the guest's compiler) is the same number.

The id-to-position rule that a Ycode host has used (member *n* at 8 × *n*)
matches only dense layouts without inline data: for ids 200, 201, 230 and
231 it gives 1600–1848 where the reference writes 0–24.

#### 4.3.3 Encoder reply (op 17)

u32 encoder ref, u32 0, **u16 alignment, u16 encoded length**, u32 0. The
driver returns these as the encoder's `alignment` and `encodedLength`
without checking them: a test-server reply with the two fields set to 40
and 8 gave an encoder whose alignment was 40 and length 8. The earlier
reading of this row (length first) had the two halves swapped.

#### 4.3.4 Set calls (op 19)

| Body bytes | Field |
|---|---|
| 0–3 | u32 encoder ref |
| 4 | u8 kind: 0 `setArgumentBuffer:offset:`, 1 buffers, 2 textures, 3 samplers |
| 5–7 | u24 first argument index (index 1000 arrived as `0x3e801` in the u32 at bytes 4–7) |
| 8–11 | u32 0 |
| 12 | u8 0 |
| 13–15 | u24 count (1 for the single calls; *n* for `setBuffers:offsets:withRange:`, `setTextures:withRange:`, `setSamplerStates:withRange:`) |
| 16–23 | u64 0 |
| 24… | kind 0 and 1: *count* pairs of u32 ref, u64 offset (for kind 0 the argument buffer and its offset). Kinds 2 and 3: *count* u32 refs, then *count* u64 zeros |

A ref of 0 (`nil`) is a request to clear the member. The reply is empty.
`setArgumentBuffer:offset:` sends kind 0 on every call.

#### 4.3.5 What the host writes

The host writes each set member as 8 bytes into the argument buffer's
shared memory, at the kind-0 offset plus the member's offset (§4.3.2),
plus 8 × *k* for the *k*-th element of a range call:

| Kind | Value written |
|---|---|
| 1 buffer | the buffer's `gpuAddress` (op 38's answer) plus the call's offset |
| 2 texture | a texture handle of the host's own choosing (the macOS host wrote small integers such as 2, 7, 0x10–0x2f that are not the guest's texture refs; the guest's `gpuResourceID` of the same textures reads 0) |
| 3 sampler | the sampler's resource ID (op 39's answer, e.g. 0xd) |
| any, ref 0 | 0 |

Nothing else in the buffer changes (bytes before the offset and between
members keep their contents). **The driver writes nothing:** with the
recorder's test server answering ops 16, 17 and 19 without writing, no byte
of the argument buffer changed after any set call.

#### 4.3.6 Inline data (op 35)

`constantDataAtIndex:` sends op 35 (body: u32 encoder ref, u32 the
argument-buffer ref of the last kind-0 call, u32 argument index, u32 0)
and returns the buffer's `contents` plus the u64 reply. The reply is the
member's offset **from the start of the buffer**: 0x108 for a member at 8
of an argument buffer set at offset 256. The guest then stores the value
itself; the host is not told what was stored. The test server's answer
(the next ref number) became the pointer offset unchecked.

#### 4.3.7 Other observations

- `newArgumentEncoderForBufferAtIndex:` (a pointer to a nested argument
  buffer) returns nil on this tier-1 device without a message; the member
  itself is an ordinary 8-byte address.
- Asking a function for an encoder at a buffer index that is not an
  argument buffer aborts in the guest ("does not identify an argument
  buffer") without a message.
- The reference's cold boot of iOS 27.0 did not create any argument
  encoder in `WeatherPoster` (both of its instances drew only RenderBox
  pipelines; recorder in `WeatherPoster` and `PosterBoard`, boot `w1`), so
  the layout behind Ycode's ids 200, 201, 230 and 231 (`app-launch.md`
  §3.9) was not captured from the process itself. The rule above places
  them by the description that op 16 carries, whatever the struct holds.
  The function Ycode's hang report names (`fragment_skybox_texture1d`, in
  the runtime's VFX library, opened by our probe with `newLibraryWithURL:`
  and given a render pipeline with reflection) binds a texture and a
  16-byte buffer and no argument buffer, so the encoder belongs to
  another function of that command buffer.

#### 4.3.8 What a Ycode host must do

1. Parse op 16's description (§4.3.1) into a table from argument index to
   (offset, kind, size): walk nested structs and arrays with the rules of
   §4.3.2, adding offsets and indices; treat an array index stride of 0
   as 1. Keep the table under the layout ref; op 17 copies it to the
   encoder.
2. Answer op 17 with u16 alignment then u16 encoded length (§4.3.2 rule 5).
3. On op 19, write each member at the argument-buffer offset plus the
   table's offset (plus 8 × *k* for range elements), with the values of
   §4.3.5, and 8 zero bytes for ref 0. An index that is not in the table:
   log it and write nothing.
4. Answer op 35 with the argument-buffer offset plus the member's offset.
5. Read the u24 index and the count of op 19 (§4.3.4), not a u8 index.

#### 4.3.9 Ycode implementation (agent ARGBUF-IMPL, 2026-10-30)

Clean-room work from §4.3.1–§4.3.8 only (`YcodeMetalHost`,
`MetalArgumentLayout.swift` and `MetalHostCore.swift`).

- **Op 16.** The record body is parsed with the grammar of §4.3.1 into a
  table from argument index to (byte offset, kind, size, alignment). Type
  57 places its argument record (a resource array of length *n* as *n*
  members 8 bytes apart, indices +*k*; inline data at its own size and
  alignment; buffers, textures and samplers 8 and 8). Type 1 adds the
  member's offset and index to its struct's members. Type 2 places element
  *e* at + *e* × stride and its indices at + *e* × the index stride, with
  an index stride of 0 taken as 1. A buffer's pointee struct is read and
  discarded. The alignment is the largest member alignment and the encoded
  length the furthest member end (or array end) rounded up to it (§4.3.2
  rule 5). The layout object keeps the table; its recipe keeps the record
  body. The reply is unchanged (`0xffff0001`, `0xffffffff`). A description
  that does not parse is refused (statistics key `12:16`) and logged with
  where it stopped; its encoders use the fallback below.
- **Unreadable pointee structs (Ycode design).** Under Ycode, iOS 27.0's
  WeatherPoster (below) sends descriptions (about 11 KB) in which the pointee
  struct of a top-level buffer member (index 10 at offset 8) holds a member
  with type code 11, which §4.3.1 does not describe (§13 item 9). The
  pointee does not change the argument buffer's layout, so the parser keeps
  that buffer member and looks for the next top-level member after an
  argument record's terminator (u64 all ones): it takes the first such
  position from which every remaining top-level member parses and the
  payload ends exactly. If there is none, the description fails as above.
  The layout's log line counts the pointee structs skipped this way.
- **Op 17.** The encoder takes its layout's table and the record body. The
  reply is u32 ref, u32 0, **u16 alignment, u16 encoded length**, u32 0.
  (The reply before this change was u16 24 then u16 8. Read in the
  corrected order, every encoder had alignment 24 and an encoded length of
  8.) An encoder whose layout ref is unknown or has no table is answered
  with alignment 8 and length 24.
- **Op 19.** The body is read as §4.3.4 gives it: u24 first index, u24
  count, then *count* (ref, u64 offset) pairs for kinds 0 and 1, or *count*
  refs and *count* zero u64s for kinds 2 and 3. Kind 0 sets the encoder's
  argument buffer and offset. Element *k* of kinds 1–3 is index first +
  *k*, written as 8 bytes at the argument-buffer offset plus that index's
  table offset: a buffer's GPU address plus the call's offset, a texture's
  `gpuResourceID` (Ycode's heap slot; §4.3.5 leaves the handle to the
  host), a sampler's op-39 answer, and 0 for ref 0. An index that is not in
  the table is logged and not written. `YCODE_METAL_ARGUMENT_ENCODER=0`
  still refuses the set calls.
- **Op 35.** The answer is the encoder's argument-buffer offset plus the
  member's table offset. For an index that is not in the table, the host
  logs it and answers with the argument-buffer offset.
- **Fallback.** An encoder without a table (no description, or one that
  did not parse) keeps the earlier rule: member *n* at 8 × *n*, and op 35
  answers + 8 × *n*. It is logged once per encoder ("has no layout
  description").
- **Snapshots** (`snapshot.md` §8). Layouts and encoders keep the op-16
  record body in their recipe, and a restore parses it again. An encoder's
  argument buffer and offset are saved too (object tags 56 and 57), so a
  set call after a restore lands at the table's offset without a new
  kind-0 call. Recorded members carry their absolute byte offset, so a
  restore writes them again where they were written. A snapshot made
  before this change has no description in its recipes, and its encoders
  use the fallback.
- **Logs.** For each layout the host logs "argument layout R of process P:
  N members (index@offset …), length L, alignment A", plus "not 8 × index"
  for layouts that the old rule would have placed wrongly. The first 24
  layouts are logged, and after them only the layouts the old rule gets
  wrong (up to 96). The first 24 set-call writes are logged, and every
  write that fails.
- **Tests.** `ArgumentLayoutTests` (Mac, x86 Linux, the Thor). Descriptions
  are built from the §4.3.1 grammar. The tests cover the spec's example
  (ids 200, 201, 230, 231 at 0, 8, 16, 24, length 32, alignment 8), inline
  data (lengths 48/16, 4/4 and 4/2), the 15-buffer layout (120, 8), nested
  structs, every array form (index stride 0, resource arrays, inline C
  arrays, struct arrays), pointee structs, a skipped unreadable pointee,
  malformed descriptions, set calls at sparse ids, the 24-bit index and
  range forms, op 35, the fallback, and a restore.
  `CoreTests.argumentEncoderSetCallsWriteTheirMembers` and
  `SnapshotReplayTests.restoreKeepsSlotsAndRewritesArgumentMembers` cover
  the fallback.

**Layouts seen under Ycode** (Thor, level 3 under Ycode, the guest's own
descriptions as parsed). visionOS 27.0 backboardd and its RealityKit
clients: one layout of 15 buffers, indices 0–14 at 0, 8, …, 112, length
120, alignment 8. This is the reference's layout in §4.3.2. iOS 27.0: in
about half of the cold boots, one client process makes all the layouts
below (one Metal client per boot, ended before the boot's thread report).
By its members 200, 201, 230 and 231 it is the WeatherPoster encoder of
`app-launch.md` §3.9, which names WeatherPoster from its GPU-hang reports:

- 17 members: index 0 at 0, 1 at 64, then 2–12 between 68 and 137,
  **200, 201, 230, 231 at 144, 152, 160, 168**; length 176, alignment 16.
- 3 members: 30, 31, 32 at 0, 8, 16; length 24.
- 12 members: 0 at 0, 1 at 4, 10 at 8, 11 at 16, 12 at 24, 20–24 at
  32–64, 33 at 72, 34 at 80; length 88. In some boots the description of
  this layout has three of the unreadable pointee structs described above,
  the first behind member 10. Before the search was added, these
  descriptions were refused: 13 in `d1a`, and at least 24 (the log's limit)
  in each of `c1b`, `d2a` and `d4a`. With the search (`e4a`, `e5a`, `e6a`), they
  parse to the same 12 members and length as the other variant, and none
  is refused.

So the four members behind `app-launch.md` §3.9 lie at 144–175 of a
176-byte encoding, not at 0–31 or 1600–1855.

## 5. Resources and memory

### 5.1 Buffers (`messageType` 1)

| Key | Value |
|---|---|
| `length` | the buffer's length |
| `options` | `MTLResourceOptions` (0 for shared, `0x20` for private) |
| `bufferIndex` | always 0 (meaning open) |
| `sharedMem` | **shared storage only**: an XPC shared-memory object (a memory entry) of the guest's own pages |

Reply `bufferRef`.

- **Shared buffers live in guest memory.** The driver allocates the
  storage itself, rounded up to 16 KiB (a 100-byte buffer: 16 384; 256 KiB:
  256 KiB), page-aligned, and shares it with `xpc_shmem_create`. The host
  maps the same pages. `contents` returns the guest's address; no message
  is sent when the CPU writes or reads them.
- **Private buffers have no guest memory**: no `sharedMem`; the host
  allocates them.
- `newBufferWithBytes:` copies into fresh shared storage before the
  message (the shared memory already holds the bytes).
- `newBufferWithBytesNoCopy:` stops the process (signal 5) in the
  simulator. `newTextureWithDescriptor:offset:bytesPerRow:` on a shared
  buffer aborts ("Linear texture can only be created on buffers with
  MTLStorageModePrivate in the simulator").
- **Inline bytes.** `setVertexBytes`, `setFragmentBytes` and `setBytes`
  do not put the bytes in the command stream. The driver keeps a 256 KiB
  shared buffer per command buffer in flight (created with
  `messageType` 1 like any buffer, reused), copies the bytes into it
  **twice**, at a 256-aligned offset and again at the next 256-aligned
  offset after the first copy, and encodes two buffer bindings, one for
  each copy; the second binding is the effective one. A host only needs
  to process the bindings in order.
- **gpuAddress** is asked from the host (op 38) and is a host value.

### 5.2 Textures (`messageType` 8, op 1)

Body (36 bytes, word offsets):

| Word | Content |
|---|---|
| 0 | 0 |
| 1 | bits 0–3 texture type (`MTLTextureType`); bit 4 and bit 5 flags (seen only on some IOSurface textures, §5.4; meaning open); bit 6 `allowGPUOptimizedContents`; bit 7 0; bits 8–15 usage (`MTLTextureUsage`, low 8 bits); bits 16–31 pixel format (`MTLPixelFormat`) |
| 2, 3, 4 | width, height, depth |
| 5 | u16 mipmap level count, u16 sample count |
| 6 | u16 array length, u16 resource options (`MTLResourceOptions`: CPU cache mode bits 0–3, storage mode bits 4–7, hazard tracking bits 8–9) |
| 7, 8 | 0 (a u64; meaning open: swizzle goes to a view, §4.2 op 27) |

Reply: u32 texture ref.

Observed mappings: memoryless storage was sent as private (`0x20`);
`compressionType` lossy aborts in the guest. The bit layout matches the
deserializer's descriptor type encoding (Evidence): a 4-bit field, four
1-bit fields, an 8-bit field, a 16-bit field, three u32, four u16, one
u64.

**Texture memory belongs to the host for every storage mode**, shared
included: no texture creation carries memory, and CPU access goes through
messages (§5.3).

### 5.3 CPU access to textures

- **`replaceRegion:` → `messageType` 9, op 2** (connection 1, reply
  empty). Body: u32 texture ref; u64 origin x, y, z; u64 size w, h, d;
  u64 mipmap level; u64 slice; u64 bytes per row; u64 bytes per image;
  then the pixel bytes, exactly (rows − 1) × bytes per row + width × bytes
  per pixel of them (108 bytes for 3×4 RGBA8 with bytes per row 32). Large
  uploads (QuartzCore sends 185 892 bytes for a 194×237 image) travel by
  memory entry.
- **`getBytes:` → `messageType` 10, op 5** (connection 0, so it is
  ordered after earlier submissions; reply empty). The message carries
  `sharedMem`, a fresh shared region of the guest (16 KiB or more); the
  body is as for op 2 followed by u64 data size (no pixel bytes). The host
  writes the pixels into the shared region before it replies; the driver
  then copies them out.

### 5.4 Textures over IOSurfaces (`messageType` 13, op 47)

Used by `newTextureWithDescriptor:iosurface:plane:`, by `CAMetalLayer`
drawables and by QuartzCore for the display buffers and for client
surfaces.

- Body (40 bytes): texture descriptor words 0–8 as §5.2, then u32 plane
  index. Resource options were 0 (shared) in every case; the IOSurface's
  size and format are repeated in the descriptor.
- `iosurface`: a Mach send right — the surface's **IOSurface.Remote
  surface port** (`iosurface-remote.md` Method 14; the driver imports
  `IOSurfaceCreateXPCObject`, which returns a Mach send right object in
  the simulator). The host resolves the surface through its IOSurface
  service; a host that does not know the surface cannot serve the call
  (`iosurface-remote.md` §7.3).
- Reply: u32 texture ref, u32 0.
- **Rendering lands in the surface's memory.** After a clear and a
  compute write into such a texture, and the completion event, our probe
  read the expected pixels through `IOSurfaceGetBaseAddress` (guest memory
  of the surface). A Ycode host must make GPU writes visible in the
  surface's shared memory before it reports completion (§9).
- Low half of word 1 seen: `0x0552` for QuartzCore's display buffers
  (usage render target + shader read, bit 4 set), `0x0142` for surfaces
  it only samples, `0x0062` for `CAMetalLayer` drawables (usage 0, bits 5
  and 6), `0x0542`/`0x0242` for our probe's surfaces (bits 4 and 5 clear).

### 5.5 Samplers (`messageType` 8, op 3)

Body (28 bytes): u32 0; u32 packed fields; u32 flags; f32 `lodMinClamp`;
f32 `lodMaxClamp`; u64 0.

| Bits of the packed word | Field |
|---|---|
| 0–1 | `minFilter` |
| 2–3 | `magFilter` |
| 4 | open (0) |
| 5–7 | `compareFunction` (Less = 1 seen) |
| 8–11, 12–15, 16–19 | `sAddressMode`, `tAddressMode`, `rAddressMode` |
| 20–23 | `borderColor` |
| 24–25 | `mipFilter` |
| 26–30 | `maxAnisotropy` |
| 31 | `normalizedCoordinates` |

Flags word bit 0: `supportArgumentBuffers`. Default sampler:
`0x84000000`, flags 0, lod 0 and `FLT_MAX`. Reply u32 ref.

### 5.6 Depth-stencil states (`messageType` 8, op 4)

Body (32 bytes): u32 0; u32 bits 0–2 depth compare function, bit 3 depth
write, bit 4 front stencil present, bit 5 back stencil present; front
stencil: u32 (bits 0–2 compare, 3–5 stencil-fail op, 6–8 depth-fail op,
9–11 pass op), u32 read mask, u32 write mask; back stencil the same.
Default: `7` (Always, no write), zeros. Reply u32 ref.

### 5.7 Heaps

`newHeapWithDescriptor:` aborts in the guest unless the storage mode is
private. Ops 20–24, 31, 32 (§4.2). Heap resources get ordinary buffer
and texture refs.

### 5.8 Events and fences

`newEvent` and `newSharedEvent` both use op 28; `newFence` op 13. The
CPU side of a shared event is two round trips on connection 0 (op 30
set, op 41 get); there is no host-initiated notification of signaled
values in our captures. GPU-side signal, wait and fence records are in
§8.4.

**Shared-event handles** (`messageType` 17 and 18, visionos.md §10.6.5).
17 names an event ref (`eventRef`) and gets back `eventPort`, a send right
that stands for the event, and `labelTraceID` 0. 18 sends such a right
back (`eventPort`, with a `command` record op 40 holding a zero u32) and
gets a new event ref (`replyData` u32 ref, u32 0) in the sending process;
both refs name one event: a value set through one (op 30, or a GPU signal)
is read through the other (op 41) and waited for by either. A handle with
port 0 breaks the client later (command-buffer decoding failed in the
reference), so a host must answer 17 with a real right.

A Ycode host (`MetalHostCore`) makes one port per exported event (a
receive right of the host task that nothing receives on; replies carry
MAKE_SEND rights), keeps a table port → event, and answers 18 by
creating a backend alias of that event (`createEventAlias`; on Vulkan the
same timeline semaphore under a second handle). The port is destroyed
with the last ref of the event in any process. An 18 whose port names no
exported event gets a fresh event (counted as refused). **In the
reference an 18 whose `eventPort` is MACH_PORT_NULL gets an empty
dictionary** (no `replyData`, no `error`) and `newSharedEventWithHandle:`
returns nil; that is what the driver sends for a nil handle, and visionOS
backboardd and wakeboardd send one right after each real 18 of a layer
(visionos.md §10.12.2, level 3). A host must answer it that way, not with
a fresh event. Ycode does so since VISIONOS-R4b (visionos.md §10.14):
an 18 without a port, or with port 0, gets an empty dictionary, makes no
event and is not counted as refused (it is counted on its own). While exported
events exist the Metal service reports itself busy to snapshots (the
ports cannot be restored).

### 5.9 Synchronization summary

| Data | Where it lives | How the other side sees it |
|---|---|---|
| shared buffer | guest pages shared with the host | directly; the host must read them when it executes and write them before it reports completion |
| private buffer, texture | host | through commands only (blits, `getBytes`/`replaceRegion`) |
| IOSurface texture | the surface's memory (guest pages shared through the IOSurface service) | directly, with the same rule as shared buffers |
| inline bytes | the driver's per-command-buffer shared buffer | as shared buffers |

There is no flush, invalidate or `didModifyRange` traffic in any
capture: completion (event 101) is the only synchronization point.

### 5.10 Shared textures (`messageType` 19, op 42)

Used by `newSharedTextureWithDescriptor:`. On visionOS, wakeboardd's
compositor makes its presentation layers with it, 16 in one boot. Level
3: the reference and Ycode's guest (visionos.md §10.9, §10.10).

**Request** (connection type 1):

| Key | Value |
|---|---|
| `messageType` | 19 |
| `command` | an op-42 record of 44 bytes: u32 42, u32 44, then the 36-byte texture descriptor (words 0–8, §5.2). wakeboardd's colour layers: word 1 `0x00510543` (2D array, GPU-optimized, usage ShaderRead + RenderTarget, `BGRA8Unorm_sRGB` 81). Its depth layers: word 1 `0x00fc0543` (`Depth32Float` 252). Both are 3840 × 2160, depth 1, one level, one sample, array length 1, options `0x0020` (private) |

**Reply** from the macOS host (16 of 16 in a boot, and in our probes):

| Key | Type | Value |
|---|---|---|
| `iosurfaceXPCObject` | Mach send right | the new surface. The guest hands it to `IOSurfaceLookupFromXPCObject`, which makes the surface with the IOSurface service (`iosurface-remote.md`) |
| `replyData` | data, 8 bytes | u32 texture ref (from the counter that buffers and textures share, §3), u32 0 |

There are no other keys. The driver also asks for `fatalError` and
`error`, but the reference never sent them. With an empty reply the
look-up returns NULL, and wakeboardd crashes in `CFRelease`.

**The surface** as the guest sees it: width, height, bytes per row,
pixel format and plane count are 0, and bytes per element is 1. The
allocation size is the heap size answer for the same descriptor (op 22,
`heapTextureSizeAndAlignWithDescriptor:`) plus 16 bytes: 33 947 664 for
the 3840 × 2160 layers. The values are `CreationProperties`,
`HorizontalDisparityAdjustment` (0) and `IOSurfaceName` ("Metal").
Creation properties (all numbers unless noted):

| Key | Value |
|---|---|
| `IOSurfaceAllocSize` | the allocation size above |
| `IOSurfaceName` | "Metal" (string) |
| `IOSurfacePixelSizeCastingAllowed` | 1 |
| `IOSurfaceProtectionOptions` | 0 |
| `kAGXCompressionMode` | 0 |
| `kMetalRegistryID` | the device's `registryID`, the value in the hand-shake reply (§2.3) |
| `kMetalTextureType`, `kMetalTexturePixelFormat`, `kMetalTextureWidth`, `kMetalTextureHeight`, `kMetalTextureDepth`, `kMetalTextureArrayLength`, `kMetalTextureMipmapLevelCount`, `kMetalTextureSampleCount` | from the descriptor (wakeboardd: 3, 81 or 252, 3840, 2160, 1, 1, 1, 1) |
| `kMetalTextureUsage` | `MTLTextureUsage` (5) |
| `kMetalTextureResourceOptions` | `MTLResourceOptions` (32, private) |
| `kMetalTextureGPUOptimization` | 1 when `allowGPUOptimizedContents` |
| `kMetalTextureSwizzleKey` | the four swizzle channels, one byte each, red first (identity: `0x05040302`) |
| `kMetalTextureRotation`, `kMetalTextureCSCMatrix`, `kMetalTextureFootprint`, `kMetalTextureSparseValue`, `kMetalTextureResourceIndex`, `kMetalTextureWriteAccessPattern` | 0 |

The key `MetalSharedTexture` (`kIOSurfaceMetalSharedTexture`) is not
present, neither in the creation properties nor in the values.

**Handles.** `newSharedTextureHandle` makes a handle from the texture's
surface. It reads the surface's `CreationProperties` and selects the
Metal device whose `registryID` equals `kMetalRegistryID`, read as an
unsigned 64-bit number. If that key is missing or does not match, no
handle is made: our probe crashed, and under Ycode the handle was nil.
Making a handle sends no host message. A handle goes to another process
only inside an NSXPC message, which carries its surface as an XPC object
(a Mach send right). Keyed archiving of a handle fails ("may only be
encoded by an NSXPCCoder").

**Ycode** (visionos.md §10.11.3): the host makes the surface in its
IOSurface service with exactly the values and creation properties above
(`kMetalRegistryID` = its hand-shake `registryID`; `IOSurfaceName` is
added by the service), so every process that looks it up by port or ID
sees the same properties (Method 10), and replies with the two keys. The
texture is GPU memory of the host's own: the surface's memory is not
linked to it (nothing the guest does reads that memory). The host keeps,
per surface ID, the live refs naming that GPU image, for §5.11. A replay
after a snapshot makes the texture again without its contents.

### 5.11 Opening a shared-texture handle (`messageType` 20, op 43)

Used by `newSharedTextureWithHandle:`, in the creating process and in any
other process. On visionOS, backboardd opens wakeboardd's layers (twelve
in one boot), and wakeboardd opens four of its own. Level 3, visionos.md
§10.10.2.

**Request** (connection type 1):

| Key | Value |
|---|---|
| `messageType` | 20 |
| `command` | an op-43 record of 12 bytes: u32 43, u32 12, u32 0 |
| `iosurface` | a Mach send right for the handle's surface (the driver gets it with `IOSurfaceCreateXPCObject`) |
| `label` | the handle's label (string), sent only when the handle has one. wakeboardd's labels look like "wakeboardd-layer 2 [frame 1/3 protection:0 size:3840x2160 recorder:False]: Color (Layered)" |

**Reply**:

| Key | Value |
|---|---|
| `replyData` | 36 bytes: u32 texture ref (from this process's counter), then descriptor words 1–8 of the texture (§5.2). The resource-options half of word 6 includes the hazard-tracking mode: `0x0220` (private, tracked) where the message-19 request had `0x0020` |

The host makes the texture from the surface. For a surface that a guest
made itself with the full set of `kMetal…` creation properties, the
reference replied with the descriptor taken from those properties (a
64 × 64 `BGRA8Unorm` 2D texture: word 1 `0x00500542`). With only
`kMetalRegistryID`, the reply was an empty dictionary and
`newSharedTextureWithHandle:` returned nil. The guest builds its texture
object from the reply, so the descriptor words must be correct.

**Ycode** (visionos.md §10.11.3): the host resolves `iosurface` through its
IOSurface service (a Method-14 port), reads the surface's numeric
creation properties and builds the descriptor from the `kMetalTexture…`
keys (type, pixel format, width and height required; depth, array
length, mipmap and sample counts default to 1). Without them the reply is
empty. The new ref names the same GPU image as a live ref of that surface
in any process (a §5.11 opening or the §5.10 texture: a backend view of
it); when there is none, it is a texture over the surface's memory (a
surface a guest made) or a new private texture. Word 6's hazard-tracking
bits are set to "tracked" (2) when the properties give none. The `label`
is logged. The right is kept for the ref's life. While refs opened this
way exist, the service is busy for snapshots (they may name another
process's image).

## 6. Functions and the form of shaders

- **Libraries never reach the host.** `newLibraryWithSource:` compiles in
  the guest (the runtime's `MTLCompilerService`); compile errors and
  warnings are produced there. `newLibraryWithURL:` and
  `newLibraryWithData:` send nothing. `newFunctionWithName:` sends
  nothing, and neither does a missing function name.
- **A function reaches the host when a pipeline uses it**, once per
  function object, as `messageType` 15 with:
  - `functionIR`: a **metallib container holding that one function**:
    magic `MTLB`, the function's name, and an LLVM bitcode wrapper
    (`0x0B17C0DE`) around AIR bitcode with target
    `air64-apple-ios13.0.0-simulator`. 2.9–6.3 KB for typical functions.
    The same form comes from source, from a metallib file and from
    function specialization. The container and AIR as file formats are
    R8's subject (`metal-shaders.md`).
  - `command`: op 15, body three u32 0 (meaning open).
  - Reply: `replyData` u32 function ref, u32 0.
- **Function constants are resolved in the guest.**
  `newFunctionWithName:constantValues:error:` produced a specialized
  function whose `functionIR` was sent like any other (op 15 body
  unchanged); no constant values travel separately.
- The deserializer's method for this message takes an "override target
  triple" argument (name only, Evidence), which suggests that the macOS
  host retargets the AIR before compiling it (not observed directly).
- **Reflection** for pipeline creation (`MTLPipelineOption`
  `ArgumentInfo`, `BufferTypeInfo`) was produced without any extra
  message; the replies (§7) carry no reflection. The guest computes it.

## 7. Pipeline states

### 7.1 Keyed descriptor format

Ops 11 and 14 (connection 2): body u32 0, u32 payload length, payload.
A payload **object** is a u8 field count followed by fields of u8 key,
u8 type, value; type 4 is a u32 (the only type seen). Defaults are left
out. A field may hold the **offset** of a nested element, counted from
the start of the payload (top level) or of the enclosing object; nested
elements start at 4-byte-aligned offsets. An **array** is u32 count, u32
element offsets (relative to the array), then the elements, each an
object. A string is NUL-terminated and follows the top-level fields (an
unlabelled descriptor has a single NUL there).

### 7.2 Render pipeline (op 14)

| Top-level key | Meaning |
|---|---|
| 0 | offset of the label string (present when labelled) |
| 1 | vertex function ref (corrected 2026-10-12, see the note below) |
| 2 | fragment function ref (corrected 2026-10-12) |
| 3 | offset of the vertex descriptor object |
| 4 | `rasterSampleCount` |
| 5 | `alphaToCoverageEnabled` |
| 8 | offset of the color-attachment array |
| 9 | `depthAttachmentPixelFormat` |
| 10 | `stencilAttachmentPixelFormat` |
| 11 | `inputPrimitiveTopology` |

| Color-attachment key | Meaning |
|---|---|
| 0 | attachment index |
| 1 | `pixelFormat` |
| 2 | `blendingEnabled` |
| 3, 4, 5 | `sourceRGBBlendFactor`, `destinationRGBBlendFactor`, `rgbBlendOperation` |
| 6, 7, 8 | `sourceAlphaBlendFactor`, `destinationAlphaBlendFactor`, `alphaBlendOperation` |
| 9 | `writeMask` |

**Correction (2026-10-12).** Keys 1 and 2 were first recorded the other
way round. Stage 8a-i runs on the Thor (level 3: the Ycode host service
with its Vulkan back end, serving our probe's hello-triangle pipeline and
a system process's pipelines) showed that key 1 carries the vertex
function's ref and key 2 the fragment function's ref; with the original
assignment the translated stages were swapped. The table above has been
corrected.

Only attachments with a pixel format are listed. **Vertex descriptor**
object: key 0 offset of the attribute array, key 1 offset of the layout
array (both relative to the vertex descriptor). Attribute: key 0 index,
1 `format` (`MTLVertexFormat`), 2 `offset`, 3 `bufferIndex`. Layout:
key 0 buffer index, 1 `stepFunction`, 2 `stepRate`, 3 `stride`; the
array had one layout element per attribute (duplicates for a shared
buffer).

**Ycode implementation (ARGBUF-IMPL, 2026-10-30).** A pipeline without
key 2 (no fragment function) is rasterized for depth and stencil only,
with colour writes off, when it has a depth or stencil format. Metal's
`fragmentFunction` may be nil for depth-only rendering, and only
`rasterizationEnabled` NO turns rasterization off (Metal documentation).
No key for `rasterizationEnabled` has been seen (§13 item 10), so a
pipeline with neither a fragment function nor a depth or stencil format is
treated as not rasterized. Before this change every fragment-less pipeline
was discarded. visionOS backboardd's occlusion boxes, stencil masks and
depth-only draws then drew nothing (`visionos.md` §10.22.2).

Reply: u32 pipeline ref, u32 0. QuartzCore's pipelines in `backboardd`
use keys 0, 1, 2, 3, 8 and color keys 0, 1, 2, 4, 7 (premultiplied
"over": source factors default One, destination factors
OneMinusSourceAlpha) and 0–8 for a few.

### 7.3 Compute pipeline (op 11)

Payload: one field, key 0 = function ref. Reply in §4.2.

## 8. Command buffers

### 8.1 Queues and submission

- `newCommandQueue` → `messageType` 7 with `maxCommandBufferCount` (64 for
  `newCommandQueue`) → `commandQueueRef`.
- `commit` → one-way `messageType` 6 on connection 0 with
  `commandQueue` (queue ref), `commandBufferRef` (chosen by the client:
  1, 2, … reused once a command buffer has completed; 20 in flight got
  1–20), and `segments`, an array of 64 KiB data values. Nothing is sent
  before `commit`; encoding is entirely in the guest.
- **Segment**: u32 bytes used (header included); u8 encoder kind; u8 1 if
  this segment continues the previous segment's encoder; u8 1 if the
  encoder continues in the next segment; u8 0. Then whole records; a
  record never straddles segments (a render encoder of 6003 records used
  65 520 bytes of the first segment and continued in the second).
- **Encoder kinds**: 0 render, 1 compute, 2 blit, 3 event (signal/wait
  records between encoders). Each encoder begins a new segment; an empty
  `endEncoding` leaves nothing.
- Debug signposts and debug groups produce no records.

### 8.2 Records common to several kinds

| Op | Call | Body |
|---|---|---|
| 135 | `useResource:usage:` (render, compute) | u32 count, u32 usage, u32 ref × count |
| 137 | `useResource(s):…usage:stages:` | u32 count, u16 usage, u16 stages, u32 ref × count |

### 8.3 Render records (kind 0)

| Op | Call | Body |
|---|---|---|
| 26 | begin render pass | 584-byte render pass descriptor (§8.6) |
| 0 | `drawPrimitives` (values ≥ 65 536) | u32 primitive type, u64 vertex start, u64 vertex count |
| 1 | `drawPrimitives` (short) | u32 primitive type, u16 vertex start, u16 vertex count |
| 2 | `…instanceCount:` (values ≥ 65 536) | u64 vertex start, u64 vertex count, u64 instance count, u32 primitive type |
| 3 | `…instanceCount:` (short) | u16 start, u16 count, u16 instance count, u16 primitive type |
| 4 | `…instanceCount:baseInstance:` (values ≥ 65 536) | u64 vertex start, u64 vertex count, u64 instance count, u64 base instance, u32 primitive type |
| 5 | `…instanceCount:baseInstance:` (short) | u16 start, u16 count, u16 instance count, u16 base instance, u32 primitive type |
| 6 | `drawIndexedPrimitives` (values ≥ 65 536) | u16 primitive type, u16 index type, u32 index buffer ref, u64 index count, u64 index buffer offset |
| 7 | `drawIndexedPrimitives` (short) | u16 primitive type, u16 index type, u32 index buffer ref, u16 index count, u16 index buffer offset |
| 8 | `drawIndexedPrimitives:…instanceCount:` (values ≥ 65 536) | u16 primitive type, u16 index type, u32 index buffer ref, u64 index count, u64 index buffer offset, u64 instance count |
| 9 | `…instanceCount:` (short) | as op 7, then u16 instance count, i16 base vertex (corrected 2026-10-13, agent H: the earlier reading "u32 instance count" held only while the base vertex was 0) |
| 28 | `…instanceCount:baseVertex:baseInstance:` (values ≥ 65 536) | u16 type, u16 index type, u32 index buffer ref, u64 index buffer offset, u64 index count, u64 instance count, i64 base vertex, u64 base instance |
| 29 | `…instanceCount:baseVertex:baseInstance:` (short) | u16 type, u16 index type, u32 index buffer ref, u16 index buffer offset, u16 index count, u16 instance count, i16 base vertex (−2 is `0xFFFE`), u16 base instance, u16 not written (stale bytes; corrected by visionos.md §10.20.2: read as one u32 it gave base instances such as 0x3FF00000). Confirmed on the reference (OBS-ARGBUF, visionos.md §9 Q24): last word `0x66660005` drew with `base_instance` 5; the host uses the low 16 bits only |
| 16 | `drawPrimitives:indirectBuffer:` | u64 indirect offset, u32 indirect buffer ref, u32 primitive type |
| 17 | `drawIndexedPrimitives:…indirectBuffer:` | u16 type, u16 index type, u32 index buffer ref, u32 indirect buffer ref, u64 index buffer offset, u64 indirect offset |
| 22 | `memoryBarrierWithResources:count:afterStages:beforeStages:` | u32 count, u16 after stages, u16 before stages, u32 ref × count |
| 23 | `memoryBarrierWithScope:afterStages:beforeStages:` | u16 scope, u8 after stages, u8 before stages |
| 24 | `updateFence:afterStages:` | u32 fence ref, u32 `MTLRenderStages` (1 vertex, 2 fragment) |
| 25 | `waitForFence:beforeStages:` | u32 fence ref, u32 `MTLRenderStages` |
| 27 | `useHeap:stages:`, `useHeaps:count:stages:` | u32 count, u16 stages, then u32 heap ref × count from byte 6 (unaligned), zero-padded to a multiple of 4 |
| 101 | `setBlendColorRed:…` | 4 × f32 |
| 102 | `setColorStoreAction:atIndex:` | u32 action, u32 index (order confirmed by VISIONOS-OBS4's probe, visionos.md §10.12.1) |
| 103 | `setColorStoreActionOptions:atIndex:` | u64 options, u32 index |
| 104 | `setDepthStencilState:` | u32 ref |
| 105 | `setDepthStoreAction:` | u64 action |
| 106 | `setDepthStoreActionOptions:` | u64 options |
| 107 | `setCullMode:` | u64 |
| 108 | `setDepthBias:slopeScale:clamp:` | 3 × f32 |
| 109 | `setDepthClipMode:` | u64 |
| 110 | `setFragmentBuffer:offset:atIndex:` | u32 index, u32 count (1), u32 buffer ref (0 = nil), u64 offset |
| 111 | `setFragmentBufferOffset:atIndex:` | u32 index, u64 offset |
| 112 | `setFragmentSamplerState:atIndex:` | u32 index, u32 count, u32 ref |
| 113 | `…lodMinClamp:lodMaxClamp:atIndex:` | u32 index, u32 count, u32 ref, f32 min, f32 max |
| 114 | `setFragmentTexture:atIndex:` | u32 index, u32 count, u32 ref |
| 115 | `setFrontFacingWinding:` | u64 |
| 116 | `setRenderPipelineState:` | u32 ref |
| 117 | `setScissorRect:` | u64 x, y, width, height |
| 118 | `setScissorRects:count:` | u32 count, u32 0, then per rect u64 x, y, width, height |
| 119 | `setStencilReferenceValue:` / `…Front…back…` | u32 front, u32 back (the one-value call sends it twice) |
| 120 | `setStencilStoreAction:` | u64 action |
| 121 | `setStencilStoreActionOptions:` | u64 options |
| 124 | `setTriangleFillMode:` | u64 |
| 125 | `setVertexBuffer:offset:atIndex:` | u32 index, u32 count (1), u32 buffer ref, u64 offset |
| 126 | `setVertexBufferOffset:atIndex:` | u32 index, u64 offset |
| 127 | `setVertexSamplerState:atIndex:` | u32 index, u32 count, u32 ref |
| 129 | `setVertexTexture:atIndex:` | u32 index, u32 count, u32 ref |
| 130 | `setViewport:` | 6 × f64 (x, y, width, height, znear, zfar) |
| 132 | `setVisibilityResultMode:offset:` | u64 offset, u64 mode (0 disabled, 1 boolean, 2 counting) |
| 134 | `useHeap:`, `useHeaps:count:` (render and compute) | u32 count, u32 heap ref × count |

**Range forms** (Ycode's guest, visionos.md §10.11.3, level 3): the
binding records 110/125 (buffers), 112/127 (samplers) and 114/129
(textures) also come with a count above 1: u32 first index, u32 count,
then one u32 ref per slot. **For buffers each slot is a pair, u32 ref
then its u64 offset** (unaligned), not all refs followed by all offsets
(VISIONOS-OBS4's probe, visionos.md §10.12.1: buffers a and b with
offsets 16 and 32 bound to slots 5 and 6 with
`setVertexBuffers:offsets:withRange:` gave 5, 2, a, 16, b, 32; both
readings give the same body length, so the length cannot tell them
apart). The count-1 form is the same pair. wakeboardd's
compositor sends 114 with count 2. Record **131** is `setViewports:count:`: u32 count, then
that many viewports of six f64 (backboardd: 1; 0, 0, 3840, 2160, 0, 1).
Records **24**, **25**, **132** and compute records **212**, **213**,
which visionOS backboardd sends in every frame, are the fence updates and
waits and the visibility-result mode (visionos.md §9 Q18, §10.12.1,
level 3: our probes with separator records, and backboardd's recorded
encoder calls matched to its records in the same command buffer).
backboardd's `04 00 00 00 02 00 00 00` is fence 4, fragment stage. Fence
refs come from `newFence` (op 13); visionOS backboardd creates and
releases fences continuously, so the refs are reused.

**Ycode** (visionos.md §10.14): the decoder turns every record of this
table, the range forms and the compute records of §8.4 into commands
(none of them is left unknown). Deferred store actions (102, 105, 120)
are also written into the open pass's descriptor, since a Vulkan render
pass fixes its store operations when it begins; an index the pass has no
attachment for changes nothing. The Vulkan back end runs a command
buffer's encoders strictly in order with a full memory barrier between
encoders, and command buffers of one queue in submission order (a
command buffer held for an event holds the later ones of its queue), so
every fence wait (25, 213, 317) is already satisfied when it is reached
and the fence records need no work of their own; a fence's state is not
kept, so a reused fence ref needs nothing either. Record 132 with mode 0
needs nothing. A non-zero mode (1 boolean, 2 counting) makes the
following draws count passing samples into the 8-byte slot at the offset
of the render pass's visibility result buffer (descriptor offset 556);
Ycode counts them with occlusion queries and writes each slot after the
pass (visionos.md §10.20.8; visionOS backboardd uses boolean mode).

**Inline bytes.** `setVertexBytes:length:atIndex:`,
`setFragmentBytes:length:atIndex:` and the compute `setBytes:length:atIndex:`
each make **two** count-1 binding records (125, 110 or 203) naming the
driver's inline-bytes buffer, the second with an offset 256 bytes past
the first's (0 and 0x100, then 0x200 and 0x300, …), for 16 and 64 bytes
alike (level 3, VISIONOS-OBS4's probe).

**Calls without a record** (same probe): `setVertexAmplificationCount:viewMappings:`
(the simulator device answers `supportsVertexAmplificationCount:` 2 with
NO), the compute `setImageblockWidth:height:`. The simulator's render
encoder does not implement `setTileBytes:length:atIndex:` or
`setThreadgroupMemoryLength:offset:atIndex:` (unrecognized selector). A
command buffer that set a colour store action and colour store-action
options on attachment indices 2 and 3 of a pass without those
attachments killed the macOS host process (the three connections were
interrupted).

Primitive type and index type are the `MTLPrimitiveType` and
`MTLIndexType` values. The short forms were used whenever every value fit
in 16 bits (6000 consecutive draws with starts up to 5999 all used op 1).
The long forms of the instanced draws are ops 2, 4 and 8 (agent H,
2026-10-13: our `mtlvary render` with instance counts, starts and base
instances of 0x12345 and 0x23456, recorded with `mslog` on this Mac's
simulator; level 3). The same capture confirms op 29's field order: u16
index buffer offset before u16 index count, then u16 instance count, u16
base vertex, and the base instance in the low half of the last word (the
high half is not written: visionos.md §10.20.2). An instance count of 0x12345 with a
16-bit index count and offset takes long form 8, so op 9's instance count
is 16 bits; RenderBox (iconservicesagent) sends op 9 records whose last
word is `0x02000019` (25 instances, base vertex 0x200), the same packing as
op 29's fourth word. Base vertex 0x10000 takes long form 28.
Bindings are state: a record changes one slot until the end of the
encoder.

### 8.4 Compute, blit and event records

Compute (kind 1):

| Op | Call | Body |
|---|---|---|
| 200 | `dispatchThreadgroups:threadsPerThreadgroup:` | u64 × 3 groups, u64 × 3 threads per group |
| 201 | `dispatchThreadgroupsWithIndirectBuffer:…` | u64 × 3 threads per group, u64 offset, u32 buffer ref |
| 202 | `dispatchThreads:threadsPerThreadgroup:` | u64 × 3 threads, u64 × 3 threads per group |
| 203 | `setBuffer:offset:atIndex:` | u32 index, u32 count, u32 ref, u64 offset |
| 204 | `setSamplerState:atIndex:` | u32 index, u32 count, u32 ref |
| 205 | `…lodMinClamp:lodMaxClamp:atIndex:` | as 204, f32 min, f32 max |
| 206 | `setTexture:atIndex:` | u32 index, u32 count, u32 ref |
| 207 | `setBufferOffset:atIndex:` | u32 index, u64 offset |
| 208 | `setComputePipelineState:` | u32 ref |
| 209 | `setStageInRegion:` | u64 × 3 **size**, then u64 × 3 origin (corrected by VISIONOS-OBS4: origin x 2035, size 1, 1, 1 gave 1, 1, 1, 2035, 0, 0) |
| 211 | `setThreadgroupMemoryLength:atIndex:` | u64 length, u32 index |
| 212 | `updateFence:` | u32 fence ref |
| 213 | `waitForFence:` | u32 fence ref |
| 214 | `memoryBarrierWithResources:count:` | u32 count, u32 ref × count |
| 215 | `memoryBarrierWithScope:` | u32 scope |

`computeCommandEncoderWithDispatchType:` concurrent produced no extra
record. Record 203 has the range form of §8.3 too ((ref, u64 offset) per
slot, visionos.md §10.12.5 item 2); Ycode reads 204 and 206 with a count
above 1 as one ref per slot, like 112 and 114 (a Ycode choice by analogy,
not observed), and 134 as in §8.3.

Blit (kind 2):

| Op | Call | Body |
|---|---|---|
| 300 | copy buffer → texture | u32 source buffer, u32 destination texture, u64 source offset, u64 bytes per row, u64 bytes per image, u64 × 3 size, u64 × 3 destination origin, u16 slice, u16 level, u32 options |
| 301 | copy buffer → buffer | u32 source, u32 destination, u64 source offset, u64 destination offset, u64 size |
| 302 | copy texture → buffer | u32 source texture, u32 destination buffer, u64 × 3 source origin, u64 × 3 size, u64 destination offset, u64 bytes per row, u64 bytes per image, u16 slice, u16 level, u32 options |
| 303 | copy texture → texture (region) | u32 source, u32 destination, u64 × 3 source origin, u64 × 3 size, u64 × 3 destination origin, u16 source slice, u16 source level, u16 destination slice, u16 destination level |
| 306 | `fillBuffer:range:value:` | u32 ref, u64 location, u64 length, u32 value |
| 307 | `generateMipmapsForTexture:` | u32 ref |
| 309 | `optimizeContentsForGPUAccess:` | u32 ref |
| 316 | `updateFence:` | u32 fence ref |
| 317 | `waitForFence:` | u32 fence ref |
| 318 | copy texture → texture (slices and levels, or whole) | u32 source, u32 destination, u16 source slice, u16 source level, u16 destination slice, u16 destination level, u16 slice count, u16 level count |

Event (kind 3), one record per segment:

| Op | Call | Body |
|---|---|---|
| 400 | `encodeWaitForEvent:value:` | u32 event ref, u64 value |
| 401 | `encodeSignalEvent:value:` | u32 event ref, u64 value |

A wait for a value the CPU signals later (op 30) held the command buffer:
it stayed uncompleted until the CPU signal, then completed.

### 8.5 Completion events

For each submission the host sends two one-way messages on connection 0:

| Key | 100 (scheduled) | 101 (completed) |
|---|---|---|
| `messageType` | 100 | 101 |
| `commandBufferRef` | the submission's ref | same |
| `status` | 3 (`MTLCommandBufferStatusScheduled`) | 4 (`Completed`) |
| `error` | 1 | 1 |
| `startTime`, `endTime` | GPU start and end, seconds of the host clock | same values |

Under Ycode the guest's mach clock is not the host's uptime (they differ by
its offset, about 19 days on the Thor), and the guest compares these times
with its own media time: Ycode's events carry the guest's mach time in seconds
(`visionos.md` §10.28.1; `YCODE_METAL_EVENT_CLOCK=host`: the host's uptime).

With our test server:

- Without events, `waitUntilCompleted` never returned.
- With **only event 101**, completion, `waitUntilCompleted`, the completed
  handler **and** the scheduled handler all ran; `waitUntilScheduled`
  returns at completion.
- The command buffer's `status` is the value of `status` in event 101
  (5 gave `MTLCommandBufferStatusError`). The `error` value (0, 1, 5) made
  no visible difference with status 4; its meaning is open.
- Events for several command buffers interleave; 100 can come after an
  earlier buffer's 101.

### 8.6 Render pass descriptor (op 26 body, 584 bytes)

Offsets in bytes from the start of the body. Each attachment is
**texture ref, resolve texture ref, u16 level + u16 slice, two words
(depth plane and resolve level/slice/plane; open), u16 load action + u16
store action, one word (open), clear value**:

| Offset | Content |
|---|---|
| 0 | depth: texture ref |
| 4 | depth: resolve texture ref |
| 8 | depth: u16 level, u16 slice |
| 12, 16 | open |
| 20 | depth: u16 `loadAction` (default 2 Clear), u16 `storeAction` |
| 24 | open |
| 28 | depth: `clearDepth` f64 (default 1.0), 4-byte aligned |
| 36 | open |
| 40 | stencil: texture ref |
| 44, 48, 52, 56 | stencil: resolve texture, level/slice, open |
| 60 | stencil: u16 load action (default Clear), u16 store action |
| 64 | open |
| 68 | stencil: `clearStencil` u32 |
| 72 | open |
| 76 + 60 × n | color attachment n (n = 0…7): +0 texture, +4 resolve texture, +8 u16 level / u16 slice, +12, +16 open, +20 u16 load / u16 store (default DontCare / Store), +24 open, +28 clear color, four f64 (r, g, b, a; default 0, 0, 0, 1) |
| 556 | visibility result buffer ref |
| 560, 564 | open (0) |
| 568 | `renderTargetWidth` (u64) |
| 576 | `renderTargetHeight` (u64) |

Load actions: 0 DontCare, 1 Load, 2 Clear; store actions: 0 DontCare,
1 Store, 2 MultisampleResolve. A render pass with **no attachments**
(width and height only) killed the macOS host process (crash report: an
abort in the host's GPU driver while it built a program for the pass);
the client's three connections were interrupted and its command buffer
never completed. `defaultRasterSampleCount` was not found in the record.

### 8.7 GPU hangs: the watchdog and device recovery (Ycode; agent GPU-SIRI, 2026-11-01)

What the protocol gives a host for a command buffer that cannot run is
event 101 with `status` 5 (§8.5): the client's command buffer ends with
`MTLCommandBufferStatusError` and its handlers run. A guest render
server treats any error of its own command buffers as fatal: visionOS
`backboardd` aborts ("Command buffer SharedEventSignalBuffer failed to
execute, causing a fatal error in the renderer", `MTLCommandBufferErrorDomain`
code 1) and is started again by launchd, and every client process of the
shell ends with it. A host must therefore (1) end GPU work that does not
end, (2) fail only the command buffer that hung, and (3) be able to serve
every later command buffer, in particular those of the restarted render
server.

**What happened before (XR-VIEWER's run `x7`, visionOS 27.0, Siri invoked
from the home view).** The Siri orb's kernel read unbound buffer slots
(metal-shaders.md §4.11) and never completed. On the Thor a hung context
is stopped by the driver only when another context needs the GPU and the
hung one cannot be switched out (Xid 109, stage8-contract.md §15.1): here
after 80 s. Ycode then saw `VK_ERROR_DEVICE_LOST`, failed every pending
and held command buffer, backboardd aborted, and every later submission
of the new backboardd failed too (the device stays lost): backboardd
restarted every 50–70 s for the rest of the session.

**A second hang of the same shape (XR-VIEWER's run `x8`): render
passes with attachments of different sizes.** Changing visionOS's
immersion (vhmdd `change_immersion_level`) makes backboardd's command
buffer 7 clear and draw into a 172 × 172 (R16Unorm) and a 16 × 16 (R8Uint)
colour attachment in one pass (`vertexShaderClearAll` and
`fragmentShaderClearAll`, two instances, the vertex function writes
`viewport_array_index`), then dispatch `immersivemask::precomputeMaskTransition`.
The checkpoints put the GPU in the clear draw, not in the kernel (whose
one buffer and one texture are bound). Ycode's render area was the first
attachment's size; Vulkan requires it to lie inside every attachment, and
the clear and draw wrote past the 16 × 16 image. On the Thor that write
never completes: `GPURecoveryTests.attachmentsOfDifferentSizesStayInsideTheSmallest`
with the old rule (`YCODE_GPU_MIXED_SIZE=first`) — two cleared attachments
of those sizes, no draw — hung until the device was lost. **Rule (Ycode):**
a pass is rendered at the smallest attachment's size (and the
`renderTargetWidth`/`Height` of the descriptor, when smaller); the stats
line counts `passes of mixed sizes`. That Metal does the same (the render
target is the smallest attachment) is Ycode's reading of the
`renderTargetWidth` documentation, not an observation (§13 item 12). Both
hangs had 32 × 16-thread threadgroups in the stuck command buffer, but
neither was in a kernel's execution: the Siri kernel's loads of address 0
and the clear's writes past an image were.

**What ends a hung submission on the Thor** (our `hangkick` probe:
a one-thread kernel that reads address 0, or loops until the host writes
a word; level 3):

| After 3 s stuck | Result |
|---|---|
| nothing | still running (and at 80 s, without another GPU client) |
| a second device of the same process submits work | it runs; the stuck context is killed (Xid 109) while the second device is created (5.2 s), but the first device's waits and counter reads do not report it |
| `vkDeviceWaitIdle` on the stuck device | returns `VK_ERROR_DEVICE_LOST` after **1.3 s** (Xid 109), for the address-0 read and the endless loop alike |
| destroying the device, then creating a new one in the same process | the destroy returns (0.1 s after the wait above, 4.5 s without it); the new device runs work correctly |

**The watchdog (Ycode).** The completion thread waits for each submission
in slices (stage8-contract.md §14). A submission still running after
`YCODE_GPU_WATCHDOG_S` seconds (default 10; 0 turns it off) is ended:
the thread waits the device idle under the back end's lock (the wait
needs the queue to itself), which returns `VK_ERROR_DEVICE_LOST` once the
driver has stopped the work, and the loss is handled as any other.
Before ending it, the hang report of stage8-contract.md §15.2 has
described the command buffer (at 2 s).

**Device recovery (Ycode; `VulkanDeviceReset.swift`).** After a loss
(seen by a wait, a counter read, a submission, or made by the watchdog),
unless `YCODE_GPU_RECOVER=0`:

1. The device gate closes: no pipeline compile, timeline wait outside the
   lock or pipeline-cache save may use the device until the reset ends
   (they enter the gate; the reset waits for those inside).
2. **The stuck command buffer fails** (status 5): the first pending
   submission at or after the serial that was being waited for that
   carries a Metal command buffer. **Every other command buffer** —
   pending on the GPU queue, held behind an event (§5.8, the held-work
   rule), or refused meanwhile with `VK_ERROR_DEVICE_LOST` — is kept, in
   that order, and recorded again from its decoded commands on the new
   device; its client sees it complete normally, late. Completions with no
   GPU work of their own keep their status; CPU reads waiting on the lost
   work (`getBytes`) see the failure.
3. Deferred destroys of released objects run (legal on a lost device);
   then every Vulkan object of the old device is destroyed and the device
   (with its instance) is made again.
4. Every live object is rebuilt **in place**, under its handle:
   - buffers and IOSurface links: guest-memory imports are imported again
     (their contents are the guest's pages); owned host memory is copied
     into the new allocation; private (device) memory comes back zeroed.
     With `bufferDeviceAddressCaptureReplay` (the Thor has it) every
     allocation is made with the capture-replay flag and its opaque
     capture address is kept, so the rebuilt buffer gets **the same device
     address** (our `car` probe: imports and allocations, rebuilt in
     reverse order on a new device, all at their old addresses; capture-
     replay allocations come from their own address range, 0xe0_0000_0000
     on the Thor, apart from ordinary ones). Addresses the guest holds
     (op 38 answers, argument buffers) therefore stay valid; a buffer that
     does move is counted in the report, and the service writes argument-
     buffer members again whose value changed (`MetalBackend.setDeviceResetHandler`);
   - textures: the image is created again from its create info and moved
     to `GENERAL`; its contents are lost (zero), except that an IOSurface
     texture copies its surface in before its next use. Its sampled,
     storage and per-level storage views are made again and written into
     **the same heap slots** (the guest holds them as resource IDs);
   - samplers into their slots; events as new timeline semaphores at the
     highest value signaled or scheduled for them (a wait for a value that
     failed work would have signaled does not hold the queue for ever);
   - pipelines keep their translated shaders; constant data is copied
     again and constexpr samplers resolved, and Vulkan pipelines are
     compiled again on first use (through the pipeline cache);
   - the dummy resources, the pipeline cache, and the timeline (serials
     start again at 1); feedback-copy images, transient memory, query
     pools and library parts are made again when next needed. A frame
     trace (`YCODE_METAL_TRACE`) stops.
5. The gate opens, the reset handler runs, and the kept command buffers
   are submitted again.

The reset logs one line ("device made again in … ms … recorded again")
and the stats line counts `device resets`. If the device cannot be made
again, every later command buffer fails as before.

**In a boot (GPU-SIRI's `r1`, visionOS 27.0, the Siri fix turned off
with `YCODE_GPU_UNBOUND_DUMMY=0`):** Siri's orb kernel hung; the watchdog
ended it at 10 s, and the device was made again in 2.9 s (gate 0 ms,
idle 15, the old objects 780, destroy 160, create 1,689, rebuild 241):
951 buffers and imports, **none at a new device address**, 499 images,
562 textures, 35 samplers, 30 events, 206 render and 113 compute
pipelines; campo's command buffer failed and 10 others were recorded
again. backboardd did not abort; it and the shell kept rendering (windows,
the Siri panel, the home view's icon discs, the system UI) for the rest of
the run, and Siri could be invoked again. What the reset cannot bring back
is the content of textures that only the GPU held: the room
(environment maps and the ASTC-decoded textures RealityKit made at boot)
and the icons' images stayed black until their owners draw them again.
A client restart (the render server's, which restarts the shell) would
bring them back; Ycode does not force one.

**Open:** which `error` value (§8.5) the reference's event carries for a
command buffer that timed out (Metal's `MTLCommandBufferErrorTimeout` is
2; Ycode sends 1 as for every event, §13 item 1). Ycode does not run a
kept command buffer's parts that had already run before the loss only
once: a command buffer split at an event wait whose first part completed
runs that part again.

### 8.8 One client's stuck submission and the others (Ycode; agent B3-GPU, 2026-11-05)

Every Metal client process of a device shares one Vulkan device and one
queue, and the completion thread completes submissions in their order
(stage8-contract.md §14). A submission that never ends therefore held up
every client: nothing behind it ran, no completion handler behind it was
called, and the render server stopped presenting (`app-launch.md` §3.7,
§3.9: a poster extension's hang froze SpringBoard and backboardd). With
§8.7 the watchdog ended such work after 10 s, then rebuilt the device.

**Why not a queue per client** (our `scripts/gpu-probes/queuekick.c` on
the Thor, level 3). Queue 0 runs a kernel that never ends; one second later
a one-thread kernel is submitted:

| Where the second kernel goes | Result |
|---|---|
| a second queue of the same device (family 0 has 16) | does not run: 0 of 5 within 2 s each |
| queue 0, behind the hang | does not run |
| a second device (another GPU context) of the same process | runs after 3.9–4.3 s (n = 4): the driver ends the context that does not yield (a context-switch timeout); later work there runs in 0.1 ms. The stuck device's own waits and counter reads still say "running" |
| none; `vkDeviceWaitIdle` on the stuck device | returns `VK_ERROR_DEVICE_LOST` after 6.7, 12.5 and 19.0 s (probe); 4–59 s in the back end's tests (the 1.3 s of §8.7 was one early measurement) |
| the second device's kernel, then `vkDeviceWaitIdle` on the stuck device | the wait returns `VK_ERROR_DEVICE_LOST` in 10–20 ms (n = 3) |

So work on one device cannot be split between clients on this GPU, and
only losing the device ends a submission. A device per client would let
the driver end only the stuck client's context, but after the same 4 s,
and at the cost of every object, pipeline and IOSurface link per client;
not done.

**What Ycode does (VulkanClientIsolation.swift):**

1. **The blocking watchdog.** A submission still running after
   `YCODE_GPU_BLOCKING_WATCHDOG_S` seconds (default 2; 0 off) while command
   buffers of *other* client processes wait behind it (queued, or refused
   while the device is lost) is ended. The plain watchdog (10 s, §8.7)
   stays for work that holds up only its own client. The limit is about
   100 times legitimate work: in a traced 700 s full boot
   (`YCODE_METAL_TRACE`, run `f700`, 352 command buffers) the longest GPU
   time of a command buffer was 21.7 ms (mean 1.7 ms; submission to
   completion at most 53 ms); none of stage8-contract.md §14–§15's
   measurements had a frame's command buffer over 100 ms outside hangs.
2. **The kick.** The watchdog runs an empty kernel on a second device of
   ours (made at the first hang without touching the function table other
   threads use, then kept; `YCODE_GPU_KICK=0` turns it off), then waits the
   stuck device idle, which then fails at once. Measured stop: 4.3–4.5 s
   (12 hangs in the tests below), against 4–59 s for the wait alone.
3. **Blame.** The hang line names the stuck client, its command buffer and
   the clients it held up, e.g. `GPU hang: serial 102 of process 10
   (MercuryPosterExtension, guest pid 345) still running after 2.0 s …;
   4 command buffers of 1 other client waited behind it (process 7
   (iconservicesagent, guest pid 282)); ending it`. The hang report of
   stage8-contract.md §15.2 is written before the device is stopped, even
   when the blocking limit is below `YCODE_GPU_HANG_REPORT_S`. Names come
   from ycode-simd (`Options.describeProcess`: executable name and guest
   pid).
4. **Only its client fails.** The device reset (§8.7) fails the stuck
   command buffer **and every other command buffer of the same client
   process** still queued, held or refused meanwhile (status 5); the other
   clients' command buffers are recorded again and complete normally.
5. **Access revoked.** A client process whose work had to be ended
   `YCODE_GPU_REVOKE_AFTER` times (default 2; 0 never) loses GPU access:
   its later command buffers complete with status 5 without running, in
   order behind its earlier ones, as Metal's
   `MTLCommandBufferErrorAccessRevoked` describes ("the process was denied
   access to the GPU device", level 1). A client that hangs the GPU on
   every frame therefore stalls the others at most twice.

`YCODE_GPU_INJECT_HANG=<name>@<s>[x<n>]` (debugging) puts a kernel that
never ends in front of the first command buffer of a client whose name
contains `<name>`, `<s>` seconds after the back end started, `<n>` times.

**Tests** (`GPUClientIsolationTests`, the Thor, run alone: a shared back
end in the same process makes the driver's stop slower). Client 1's
kernel never ends; clients 2 and 3 submit a frame every 50 ms (clear to a
colour that changes per frame, draw a triangle), plain watchdog 30 s,
blocking limit 1 s. In 3 of 3 runs: client 1's command buffer failed;
all 80 frames of clients 2 and 3 completed, none failed; their longest
gap was 5.67–5.68 s (1 s limit + 4.3–4.4 s stop + 0.2 s reset); the last
frame's pixels were right; the hang line named client 1 and the two
clients. A second hang of client 1 revoked its access; its next command
buffer failed at once and client 2 kept drawing with no further reset. A
3 s submission with only its own client's work behind it was not ended
by the blocking limit.

**In a boot** (iOS 27.1, iPhone 18 Pro copy of the golden device, the
Thor shared with other agents' boots, load 40–60):
`YCODE_GPU_INJECT_HANG=Poster@90x2` hung `MercuryPosterExtension` twice
(run `inj1`, before the kick): each hang was ended at 2.0 s with 4 and
then 1 command buffers of `iconservicesagent` and `backboardd` waiting;
the resets took 1.6 and 3.2 s (device creation 1.2 and 2.8 s); the
extension's access was revoked after the second; the boot reached the
home screen (101 s, the load).
With the kick (runs `inj3`–`inj5`, load 10–20, the same injection 15 s
into the boot, three times): each hang was ended at 2.0 s with 8–28
command buffers of `backboardd` and `iconservicesagent` waiting, stopped
in 4.3–4.5 s, and the device made again in 0.3 s; the third command
buffer was refused without running. `inj3` reached the home screen at
42.5 s (a boot without injection: 42.7 s). In `inj4` and `inj5` the
extension lost access before it had drawn the wallpaper: the screen then
showed no wallpaper and placeholder icons without labels (screenshots at
60 and 90 s), so the home watch never saw a lit screen; `backboardd`,
SpringBoard and the other clients did not fail. Losing a poster extension
costs its wallpaper, by design; the alternative is a 6.5 s stall of every
client at each of its frames.

**Open.** Texture contents that only the GPU held are still lost for
every client at a reset (§8.7); keeping a copy of `replaceRegion`
uploads to put back would cover icons and glyphs. A spare device made in
advance to skip the creation at reset made the driver's stop slower in
tests (another idle context in the process: 9–50 s), so it is not used.

## 9. Presentation

The Metal host has **no presentation call**. Frames reach the screen as
pixels in IOSurfaces:

- `backboardd` (QuartzCore's render server) wraps each display buffer —
  the `LCD` surfaces it created through IOSurface.Remote and adds to the
  SimFramebuffer swapchain (`iosurface-remote.md` §1.2,
  `simframebuffer.md` §5.1) — in a texture (op 47) and renders the frame
  into it with one render pass per command buffer. It wraps the
  display buffer in a new texture for every frame and releases it after
  the frame (694 op-47 calls and 2390 texture releases in 107 s of boot).
- `CAMetalLayer` drawables in apps are IOSurface textures too (op 47);
  `presentDrawable:` sends nothing to the Metal host. The surface reaches
  `backboardd` through Core Animation, and `backboardd` samples it
  (op 47 with usage shader-read).
- **Order per frame in `backboardd`** (recorder with the swap calls
  wrapped at `dlsym`, 100+ frames of a restarted `backboardd`; with that
  wrapper the screenshot stayed black, §10, so only the call order is
  taken from this run): `SFBSwapchainSwapBegin` → `SwapAddSurface` (the
  display buffer) → `commit` (`messageType` 6) → event 100 →
  `SwapSubmit` → event 101 (101 sometimes came before `SwapSubmit`
  returned). So **`backboardd` presents after the command buffer is
  *scheduled*, not after it is completed**: on the Mac the host GPU orders
  the display read after the render. A Ycode host that cannot give that
  guarantee must not send event 100 before the frame's pixels are in the
  surface memory; sending 100 together with 101 after completion (or only
  101, §8.5) delays `SwapSubmit` until then.

## 10. What a boot to the home screen uses

A boot of a throwaway iPhone Duo device with the recorder in every job (in
its light mode, Appendix A), captured for about 107 s. A screenshot at
90 s showed the normal home screen: wallpaper, Settings and Safari icons,
status bar, the same as a boot of a second device without the recorder.
(An earlier boot that wrote every data object to disk, 5 GB, and a boot
with the `dlsym` wrapper of §9 both ended with a black or partly black
screen; their counts are not used here.)

| Process | Submits | Encoders used |
|---|---|---|
| `backboardd` | 428 | **render only**; all compositing, for **both** built-in displays (155 and 153 display-buffer textures of 1398×2034 and 2007×2853) |
| `iconservicesagent` | 46 | render only; icon images |
| poster extensions: `MercuryPosterExtension` (7 processes), `KaleidoscopePoster` (3), `EmojiPosterExtension` (3), `GradientPosterExtension` (3), `PridePosterExtension` (4), `AegirPoster` (3), `Unity2025Poster` (2), `RhizomePoster` (2), `ExtragalacticPoster` (2), `PhotosPosterProvider` (2), `WeatherPoster` (3) | 1–203 per process | render; blit in Mercury (303, 307); compute in Pride (200, 203, 204, 206, 208) |
| `WidgetRenderer_Default` | 2 | render |
| `SpringBoard` | 1 | one render pass, blit 307 and 318 |
| `PosterBoard`, `chronod` | 0 | device creation only (hand-shakes, op 37) |

Union of what they used — **the minimum a Ycode host must translate for
this boot**:

- Messages: 0, 1, 6, 7, 8 (ops 1, 3, 4), 9 (op 2), 10 (op 5, 10 times),
  12 (ops 7, 8, 11, 14, 20, 21, 22, 25, 31, 32, 33, 37), 13 (op 47),
  14 (1000–1003, 1005–1008, 1012), 15; events 100, 101.
- `backboardd` alone: messages 0, 1, 6, 7, 8 (ops 1, 3, 4), 9 (op 2),
  12 (ops 14, 37), 13 (op 47), 14 (1000, 1001), 15.
- Render records: 26, 1, 3, 6, 7, 9, 104, 107, 110, 111, 112, 114, 116,
  117, 119, 125, 126, 130. `backboardd`: 26, 3, 6, 7, 110, 111, 112, 114,
  116, 117, 125, 126, 130.
- Compute records: 200, 203, 204, 206, 208. Blit records: 303, 307, 318.
  No event-kind segments, fences, argument buffers or indirect draws.
- Pipelines: 1025 render pipelines (keys 0–4, 8–10 at top level; colour
  keys 0–9; 96 with vertex descriptors, most of them in `backboardd`),
  57 compute pipelines; 1474 functions.
- Texture types 2D (almost all), 2D multisample, 3D, 1D. Pixel formats
  created, by count: RGBA16Float (115), BGRA8Unorm (80), RG16Float (65),
  Stencil8 (253), R16Float (25), R8Unorm (10), A8Unorm (1), RGBA8Unorm
  (70), BGRA8Unorm_sRGB (81), RGBA8Unorm_sRGB (71), RGBA16Unorm (110),
  Depth16Unorm (250), Depth32Float (252), RG11B10Float (92),
  RGB10A2Unorm (90).

A host that refuses Metal entirely is tolerated (`simframebuffer.md` §7
item 11), so this set is what stands between "no Metal" and a composited
home screen.

## 11. Results of the test-server runs

Our in-process test server (Appendix A), answering from §2–§8 without a
GPU, with our probe:

| Variation | Result |
|---|---|
| hand-shake values as macOS, op 37 as macOS, refs counting from 0x101, events 100 and 101 per submission | device created; texture, buffer, pipeline, render pass, compute dispatch, events all completed (`status` 4); pixels stayed 0 (nothing executed) |
| other `version`, other `hostFeatureProfile`, empty hand-shake reply | no difference |
| op 37 reply 256, 128, 64, 8192 | device limits became exactly these |
| op 37 not answered (empty reply) | device limits stayed at the driver's caps |
| no events | `waitUntilCompleted` hangs |
| only event 101 | everything completes; both handlers run |
| event 101 with `status` 5 | command buffer status Error |

The test server ran inside the client (anonymous XPC listener); it checks
semantics, not the Mach wire, and `xpc_connection_enable_sim2host_4sim`
was not applied to its connections.

## 12. Requirements for a Ycode host (derived)

1. **Names.** Register `com.apple.metal.simulator` and the per-client
   names of `launchd-sim.md` §6.3 into the guest's `user/<uid>` domain
   (control operation 701), all to one Ycode service or to several; serve
   the hand-shake on each connection, reply `!CPX`.
2. **Hand-shake.** Reply `version` 10, `processRef` per client process,
   `registryID` any constant, `hostFeatureProfile` 10. Bind connections
   2 and 3 to the process named by `processRef`. Free all of a process's
   objects when its connections lose their senders.
3. **Event port.** Keep the send right of descriptor 1 of connection
   type 0's Mach hand-shake; send events 100 and 101 there as
   `0x10000000` `!CPX` messages without a reply port.
4. **Objects.** Ref counters per kind (buffers and textures shared),
   reuse after release; the creation messages and replies of §4–§7.
5. **Memory.** Map each buffer's `sharedMem` memory entry (guest pages,
   16 KiB granules) and execute against it in place (on the Thor:
   `VK_EXT_external_memory_host`), never copy-and-forget: the guest reads
   results from the same pages after event 101. Map XPC data that arrives
   by memory entry (segments, uploads). Write `getBytes` results into the
   message's shared region before replying.
6. **IOSurface textures.** Resolve the `iosurface` port with Ycode's own
   IOSurface service (`iosurface-remote.md` §8 item 9) and back the
   texture by the surface's memory (linear), or copy back to it before
   event 101.
7. **Shaders.** Translate each `functionIR` (single-function metallib,
   AIR) when it arrives or when a pipeline first needs it (R8's path);
   pipelines are created on connection 2 and may take long. Compile errors
   never need to be reported to the guest (the guest compiled already);
   a translation failure has no observed error path (open).
8. **Command buffers.** Decode segments in order, by encoder kind; keep
   binding state per encoder; replay to Vulkan; send 100 (only after the
   pixels are in IOSurface memory, §9) and 101 with `status` 4.
9. **Order.** Process connection 0 in order: a `getBytes` (10) and op 30
   must see the effects of earlier submissions; events 400/401 and CPU
   signals (op 30) must interact (a GPU wait releases on a later CPU
   signal).
10. **Unknown ops.** Messages and records outside §10's minimum may be
    refused; a refused synchronous request should still get a reply
    (an empty dictionary worked for every request in our test server
    runs) so that the client does not block.

## 13. Open questions

1. Meaning of `hostFeatureProfile`, `version` 10, `bufferIndex`, the
   `error` key of events, `startTime`/`endTime` units beyond "host clock
   seconds", and op 15's three body words.
2. Texture descriptor bits 4–5 of word 1 and words 7–8; IOSurface
   texture flag combinations; render pass words marked open;
   `defaultRasterSampleCount` and tile/imageblock fields.
3. Device ops 25, 31 (two reply sizes), 39's second word; ops 26, 29,
   36, 40 (not seen); which of 1010/1011 is layout and encoder; op 1008
   (inferred queue); op 16's reply words `0xffff0001`, `0xffffffff` and the
   constant byte 2 of its argument records (§4.3.1). Op 35 is
   `constantDataAtIndex:` (§4.3.6).
4. Long forms of instanced draws, `setVertexBuffers:offsets:withRange:`
   (the `count` word suggests multi-slot records), tessellation, tile
   shaders, parallel render encoders, `setColorStoreAction` field order,
   visibility result mode, `textureBarrier`, `setLineWidth`.
5. How a host reports a shader translation failure or a GPU fault to the
   client (a status 5 completion is honored; nothing else observed).
6. *(Answered, §4.3, OBS-ARGBUF.)* Argument-buffer encoding: op 16's
   layout description, op 17's reply, op 19's set calls and what the host
   writes. Still open: how the macOS host chooses the 8-byte texture
   handles it writes, and the layout of WeatherPoster's encoder (not made
   in the reference's cold boot; as Ycode receives it, §4.3.9).
7. Whether `defaultRasterSampleCount`-only passes ever occur in the boot
   (they crashed the macOS host).
8. *(Answered, §5.10, §5.11, level 3.)* The reference's reply to `messageType` 19
   (all keys and the `replyData` layout) and the creation properties of
   the IOSurface it makes, in particular the value under
   `MetalSharedTexture`; whether opening a handle in another process
   (`newSharedTextureWithHandle:`) sends a message, and which.
9. *(New, ARGBUF-IMPL, 2026-10-30.)* Op 16's member type codes other
   than 57, 1 and 2. Under Ycode, iOS 27.0 WeatherPoster's descriptions
   (11 220 bytes) hold a member with type code 11 inside the pointee
   struct of a top-level buffer member. Type code 11 is `MTLDataTypeFloat3x3`
   as a data-type value, so this may be a plain-data member of a pointee
   struct. On the reference, with a probe whose argument buffer has a
   `constant S *` member and `S` holds a `float3x3` (and other matrix and
   vector types, and a nested struct): which type codes appear for the
   members of a pointee struct, and what follows each code. Ycode skips
   such pointee structs (§4.3.9) and needs nothing more for the layout. A
   full grammar would let the parser stop depending on that search.
   *(VISIONOS-R10b, 2026-10-31: no visionOS boot of round R10 logged a
   layout it did not parse; still open for the reference.)*
10. *(New, ARGBUF-IMPL, 2026-10-30.)* Which op-14 key, if any, carries
   `rasterizationEnabled` NO, and whether a pipeline with it can have a
   depth or stencil format. Ycode infers "not rasterized" from no fragment
   function and no depth or stencil format (§7.2). *(VISIONOS-R10b,
   2026-10-31: the visionOS boots of round R10 logged no render-pipeline
   key Ycode does not model, only compute-pipeline keys 1 and 2, as
   before; still open for the reference.)*
11. *(New, GPU-SIRI, 2026-11-01.)* What the reference sends for a command
   buffer the host GPU stopped (a GPU timeout or fault): `status` 5 with
   which `error` value, and whether the driver turns it into
   `MTLCommandBufferErrorTimeout` (2) or `PageFault`; and what a client's
   other in-flight command buffers get then. Ycode fails the stuck one and
   the same client's other in-flight command buffers, with `error` 1, and
   after two hangs refuses the client's command buffers (§8.8). Also:
   after how many GPU errors the reference revokes a process's access
   (`MTLCommandBufferErrorAccessRevoked`), and whether the render server
   is exempt.
12. *(New, GPU-SIRI.)* Which area the reference renders when a pass's
   attachments differ in size (the smallest, Ycode's rule in §8.7, or each
   attachment clipped to its own size); probe: a pass with a 64 × 64 and a
   16 × 16 attachment, both cleared, and a full-screen draw writing both.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Public Metal API, enum values (`MTLPixelFormat`, `MTLTextureType`, `MTLTextureUsage`, `MTLResourceOptions` shifts, load/store actions, compare functions, stencil ops, blend factors, vertex formats, primitive and index types, swizzles, command-buffer status) | 1 | iPhoneSimulator 27.1 SDK Metal headers; Metal documentation |
| Driver and host component names, bundle versions, linked libraries, the driver's imported libxpc calls (`xpc_shmem_create`, `xpc_connection_enable_sim2host_4sim`, …), `MTLCreateSimulatorDevice` export | 4 | `otool -L`, load commands and symbol tables of the runtime's `MTLSimDriver`, `MTLSimImplementation`, `MetalSerializer` and of `SimMetalHost` (names only) |
| ObjC classes `MTLSimDevice`, `MTLSimBuffer` (`_bufferRef`, `_iosurface`, `_gpuAddress`), `MTLSimRenderCommandEncoder : MTLSerializerRenderCommandEncoder`, `MTLSimCommandStoragePool`; MetalSerializer's `_MTLDeserializer` method names and the type encodings of its descriptor records (texture, sampler, depth-stencil bit fields), segment header type `{?=ICCC}`, `submitCommandSegments:…submissionCompleted:commandBufferCompleted:…`, `newFunctionWithSerializedMetallib:…overrideTargetTriple:…`, the per-kind ref allocators | 4 | `objcdump.m` (R4's, public ObjC runtime API) run in the simulator on both frameworks |
| Names used, look-up order, three connections and their use, hand-shake keys and values (§1, §2) | 3 | `mslog.c` in every job of a boot, and in our probes; `xpc_connection_get_pid` of replies; `ps` |
| Mach envelope, one-way messages, server-initiated events on the hand-shake send right, segments by memory entry (§2.1) | 3 | R5's `ismitm.c`/`isproxy.h` relay on our probe |
| Message types, ops, record bodies, replies (§3–§8) | 3 | our probes `mtltest.m` and `mtlvary.m` (each call isolated with separator records and distinctive values) under the recorder; `msparse.py`, `mspso.py` |
| Inline-bytes double copy (§5.1) | 3 | `mtlvary bytes` with the recorder's dump of the driver's own shared regions at submission |
| Shared buffers in guest memory, no sync traffic, IOSurface texture results in surface memory (§5) | 3 | probe results read back after event 101; absence of messages in all captures |
| Shader form (§6) | 3 + 2 | captured `functionIR` data read as a file (magic, name, bitcode wrapper, target string); no content copied |
| Completion semantics, op 37 clamping, hand-shake tolerance (§8.5, §11) | 3 | the test server in `mslog.c` (`YC_MS_FAKE`) with our probe |
| Frame order in `backboardd` (§9) | 3 | `mslog.c` with `YC_MS_SFB`: swap functions wrapped at `dlsym` |
| Host crash on a zero-attachment pass; host frame names | 3 | crash report of our own run (black-box output, frame names only) |
| Boot usage (§10) | 3 | recorder logs (light mode) of every job of one boot, 107 s, home screen checked by screenshot against a boot without the recorder |
| Heap ops 21/22 carry descriptor words 1–8 only (§4.2 correction) | 3 | request bodies logged by Ycode's own host (`YCODE_METAL_DUMP_OPS`) during Ycode boots of the visionOS 27.0 runtime on the Thor, 2026-10-27 |
| `messageType` 17 and 18 (§2.4, §5.8) | 3 | visionos.md §10.6.5 (reference observation with our probe and Metal message recorder) |
| Ycode's handling of 17/18 and the op-37 z parity (§4.2, §5.8) | — | Ycode design; unit tests `CoreTests.sharedEventHandlesNameOneEventAcrossProcesses`, `MachServiceTests.sharedEventHandleTravelsAsARight` |
| `messageType` 19: request body, the reply keys the driver reads, the `MetalSharedTexture` creation property the handle needs (§2.4, §5.10) | 3, 4 | Ycode's host log of the refused request; Ycode's `mtlrec.dylib` (XPC dictionary reads, IOSurface calls) in wakeboardd; our probe `shtex`; the key's value read from the exported constant `kIOSurfaceMetalSharedTexture` (level 4: a name) |
| Ycode's op 22 rule, op 20/31 16 KiB heaps, its `messageType` 19 (§4.2, §5.10) | — | Ycode design from visionos.md §10.8.3; unit tests `CoreTests.heapSizesFollowTheReferenceRule`, `sharedTextureGetsAHostSurface` |
| `messageType` 19 reply keys and `replyData`, the surface's values and creation properties, no `MetalSharedTexture`, what a handle needs, `messageType` 20 request and reply (§2.2, §2.4, §5.10, §5.11) | 3 | visionos.md §10.10.2: `mslog` in our probes (`shtex2`, `shtex3`, `shtex4`) and in backboardd and wakeboardd during a reference boot of the visionOS 27.0 runtime, 2026-10-27 |
| Records 22, 24, 25, 27, 103, 105, 106, 118, 120, 121, 132, 134, 212, 213; corrections to 102, 209 and the buffer range form; inline-bytes records; calls without a record (§8.3, §8.4) | 3 | visionos.md §10.12.1: our probes `encprobe`, `encprobe2` with separator records under `mslog`, visionOS 27.0 runtime, 2026-10-27; backboardd's encoder calls (a copy of Ycode's recorder) matched to its records |
| Null-port 18 answered with an empty dictionary; nil event (§5.8) | 3 | visionos.md §10.12.2: `mslog` with port names in backboardd and wakeboardd; recorder copy in backboardd |
| Ycode's decoding of those records, deferred store actions in the descriptor, fences satisfied by in-order execution, the null-port 18 reply (§5.8, §8.3, §8.4) | — | Ycode design (visionos.md §10.14.1); unit tests `CommandDecoderTests.fenceVisibilityAndDeferredStoreRecords`, `computeFencesAndRangeBindings`, `rangeBindingsAndViewportArrays`, `computeRecords`, `CoreTests.sharedEventHandlesNameOneEventAcrossProcesses`; no unknown record in visionOS boots r1–r3 |
| Argument buffers: op 16's layout description, the offset rule, op 17's reply order, op 19's index, count and range forms, what the host writes, op 35 (§4.3) | 3 | OBS-ARGBUF, 2026-10-30: our probe `argprobe.m` (32 layouts) under the recorder on the iOS 27.0 reference (24A434), the recorder's test server for the driver-writes check, `msargbuf.py` parsing every description exactly; visionOS 27.0 backboardd's one encoder in a reference boot (recorder in backboardd) |
| Ycode's argument buffers: the op-16 parser, op 17's order, op 19's forms and writes, op 35, the 8 × *n* fallback, snapshots (§4.3.9) | — | Ycode design from §4.3.1–§4.3.8; unit tests `ArgumentLayoutTests` (11), `CoreTests.argumentEncoderSetCallsWriteTheirMembers`, `SnapshotReplayTests.restoreKeepsSlotsAndRewritesArgumentMembers` |
| The search past an unreadable pointee struct (§4.3.9) | — | Ycode design; `ArgumentLayoutTests.anUnreadablePointeeIsSkipped` |
| Fragment-less pipelines rasterize depth and stencil (§7.2) | 1, 3 | Metal documentation (`fragmentFunction`, `rasterizationEnabled`); `visionos.md` §10.22.2 (boots `v6`, `v7`); `VulkanBackendTests.depthOnlyPipelinesRasterize` |
| Layouts seen under Ycode: visionOS backboardd's 15 buffers; WeatherPoster's 17-, 3- and 12-member layouts; type code 11 in a pointee struct (§4.3.9, §13 item 9) | 3 (under Ycode) | ARGBUF-IMPL boots on the Thor (iOS 27.0 `c1a`–`c8a`, `c1b`, `d1a`–`d6a`, `e1a`–`e6a`; visionOS 27.0 `v1`–`v7`): the host's own "argument layout" and "did not parse" log lines |
| Op 29's stale high half ignored by the host (§8.3) | 3 | OBS-ARGBUF: `argprobe draw2` (a vertex function reports `base_instance`) on the iOS 27.0 reference; backboardd's op-29 records in a visionOS 27.0 reference boot |
| What ends a hung submission on the Thor: a second device, `vkDeviceWaitIdle` (1.3 s, `VK_ERROR_DEVICE_LOST`), destroy and re-create; capture-replay addresses survive a new device (§8.7) | 3 | GPU-SIRI's probes `scripts/gpu-probes/hangkick.c`, `loop.comp`, `car.c` (our C and GLSL) on the Thor; the host kernel log (Xid 109); Vulkan specification (`bufferDeviceAddressCaptureReplay`, `vkDeviceWaitIdle`, device loss) level 1 |
| The render server's abort on a failed command buffer; the loss loop of run `x7` (§8.7) | 3 | XR-VIEWER's run `ide-remote/xr-viewer/runs/x7` (host log, guest crash annotations), Ycode's own boots |
| Ycode's watchdog and device recovery (§8.7) | — | Ycode design; `GPURecoveryTests` on the Thor's GPU; GPU-SIRI's boots |
| A second queue of the device does not run while one submission is stuck; a second device does after 3.9–4.3 s; the device wait alone ends it in 4–59 s, after the second device's kernel in 10–20 ms (§8.8) | 3 | B3-GPU's probe `scripts/gpu-probes/queuekick.c` (our C and GLSL) on the Thor; Vulkan specification (queue submission order, device loss) level 1 |
| Blocking watchdog, kick, blame, revocation (§8.8) | — | Ycode design; `GPUClientIsolationTests` on the Thor's GPU; B3-GPU's boots `inj1`, `inj2`; `MTLCommandBufferErrorAccessRevoked` (Metal documentation, level 1) |
| Requirements (§12) | — | derived from the above; Ycode design |

No disassembly or decompilation was used (level 5 not used). No
`.claude/Xcode.app`, `research/dirty/`, or Ghidra project was opened. No
executable memory was read: the recorder prints XPC objects through the
public XPC API, maps received shared-memory objects read-only, and reads
only the driver's own shared data regions. Shader payloads stayed in the
scratch directory and are not reproduced here.

## Appendix A. Programs and method

Sources (ours) in `research/experiments/simulator/metal-sim/`, built with
`build.sh <out>` (outside the repo) for `arm64-apple-ios27.0-simulator`:

| File | What it is |
|---|---|
| `mslog.c` | the recorder, a `DYLD_INSERT_LIBRARIES` dylib: interposes `xpc_connection_create_mach_service`, `bootstrap_look_up`, `xpc_connection_enable_sim2host_4sim`, the three send calls, `xpc_connection_set_event_handler` (to see events) and `xpc_shmem_create`; prints every message of the Metal connections and writes data objects to files (`YC_MS_LIGHT`: segments trimmed, large uploads skipped); `YC_MS_FAKE=1` replaces the host by the in-process test server; built with `-DMS_SFB` (`mslog-sfb.dylib`) it also wraps the SimFramebuffer swap calls at `dlsym` (not for whole-boot use: §10) |
| `mtltest.m` | probe: device info, buffers, textures, clear, triangle, compute, function constants, blit, metallib, IOSurface textures, heaps, depth, samplers, events and fences, errors, `CAMetalLayer`, indirect command buffers, argument buffers |
| `mtlvary.m` | field separation: render, compute and blit call matrices with separator records; render pass, pipeline, texture, sampler, depth-stencil variants; a 6000-draw encoder; 20 command buffers in flight; inline-bytes sizes |
| `shaders.metal` | our test shaders for the metallib case |
| `msparse.py` | prints a capture as messages and records |
| `mspso.py` | decodes keyed pipeline descriptors |
| `argprobe.m` | argument-buffer probe (OBS-ARGBUF): 25 shader-struct and 7 descriptor-built layouts, range set calls, `constantDataAtIndex:`, a public-API look at a library file's functions, and the op-29 checks `draw`, `draw2` |
| `msargbuf.py` | decodes op-16 layout descriptions into index → offset tables |

Method: a throwaway iPhone Duo device (`R7-metal`) on the 27.1 runtime was
booted with `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES` pointing at the recorder
(three boots: full dumps, `dlsym` wrapper, light mode), so every job and
every `simctl spawn` probe carried it; a second throwaway device
(`R7-plain`) was booted without it for the screenshot comparison; probes were run
with `simctl spawn`; `backboardd` was restarted with `launchctl kickstart
-k` for the server-pid and swap-order runs (`launchctl setenv YC_MS_SFB
1`). R5's `ismitm.c` was reused unchanged for the Mach-level check. Raw
captures stayed in the agent's scratch directory. Both devices were deleted
afterwards.
