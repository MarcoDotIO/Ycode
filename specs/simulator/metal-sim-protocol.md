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
| `iosurface` | Mach send right | IOSurface texture (§5.4) |
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
| 100 | host → client | — | command buffer scheduled | §8.5 |
| 101 | host → client | — | command buffer completed | §8.5 |

Message types 2–5 and 11 were never sent. Replies to requests that expect
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
| 16 | argument-buffer layout from a function's reflection (`newArgumentEncoderWithBufferIndex:`) | a serialized structure description (keyed, with magic bytes `MTLPSBIN`) | 16 bytes: u32 ref, u32 0, u32 `0xffff0001`, u32 `0xffffffff` (meaning open) |
| 17 | argument encoder from a layout | u32 0, u32 layout ref | u32 ref, u32 0, u16 encoded length (24), u16 alignment (8), u32 0 |
| 19 | argument-encoder set call | u32 encoder ref; u8 kind (0 `setArgumentBuffer:offset:`, 1 buffer, 2 texture, 3 sampler); u8 index; u16 0; four words (0, 0x100, 0, 0 in every capture; open); u32 object ref (0 = nil); u64 offset (the argument-buffer offset for kind 0) | empty. After the calls the argument buffer's shared memory held the data buffer's `gpuAddress` and two small IDs; whether the host or the driver wrote them is open |
| 20 | `newHeapWithDescriptor:` | u32 0, u64 size, u16 resource options, u16 0 | u32 ref, u32 0 |
| 21 | heap `newTextureWithDescriptor:` | u32 0, u32 heap ref, texture descriptor (§5.2), 12 bytes 0 | u32 texture ref, u32 0 |
| 22 | `heapTextureSizeAndAlignWithDescriptor:` | texture descriptor (§5.2) | u64 size, u64 alignment (352 768, 128 for 256×256 BGRA8 with mipmaps) |
| 23 | `heapBufferSizeAndAlignWithLength:options:` | u64 length, u16 options, u16 0 | u64 size, u64 alignment (1000 → 1000, 256) |
| 24 | heap `newBufferWithLength:options:` | u32 0, u32 heap ref, u64 length, u64 0, u64 options | u32 buffer ref, u32 0 |
| 25 | (heap resources; one u32 ref) | u32 ref | 1 byte (meaning open) |
| 27 | texture view with swizzle (from a descriptor with `swizzle`) | as op 8, then u32 swizzle (one byte per channel r, g, b, a, `MTLTextureSwizzle` values) | u32 ref, u32 0 |
| 28 | `newEvent`, `newSharedEvent` | u32 0 | u32 ref, u32 0 |
| 30 | shared event `setSignaledValue:` (connection 0) | u32 ref, u64 value | empty |
| 31 | heap size query | u32 heap ref | u64 size, u64 size, u64 used size (or 8 bytes; open) |
| 32 | `maxAvailableSizeWithAlignment:` | u32 heap ref, u64 alignment | u64 |
| 33 | `minimumLinearTextureAlignmentForPixelFormat:` | u32 pixel format | u64 (16 for BGRA8) |
| 34 | `minimumTextureBufferAlignmentForPixelFormat:` | u32 pixel format | u64 (16) |
| 35 | (argument encoder; `u32 1, u32 0x99, u64`) | | 8 bytes (open) |
| 37 | limits (connection 0, once per process) | u32 0 | u64 max threads per threadgroup x, y, z, u64 max threadgroup memory (macOS: 1024, 1024, 1024, 32 768) |
| 38 | buffer `gpuAddress` | u32 buffer ref | u64 address (host-chosen, e.g. `0x100000f8000`) |
| 39 | sampler `gpuResourceID` (when `supportArgumentBuffers`) | u32 sampler ref, u32 8 | u64 resource ID |
| 41 | shared event `signaledValue` (connection 0) | u32 ref | u64 value |

**Op 37 is the only capability query.** The driver takes, for each of the
four limits, the smaller of the reply and its own cap (512, 512, 512,
16 384): our test server's reply (256, 128, 64, 8192) appeared exactly in
`maxThreadsPerThreadgroup` and `maxThreadgroupMemoryLength`; larger
values and a missing reply both left the caps. No pixel-format, family or
feature query reaches the host.

Ops 26, 29, 36, 40 and above 41 were not seen. The names of the
deserializer's device-level methods (Evidence, level 4) suggest the
remaining ones: a buffer `didModifyRange`, a shared-event wait, a
resource-alias test, unique identifiers and shared events with an event
port. Their numbers are open.

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

### 5.9 Synchronization summary

| Data | Where it lives | How the other side sees it |
|---|---|---|
| shared buffer | guest pages shared with the host | directly; the host must read them when it executes and write them before it reports completion |
| private buffer, texture | host | through commands only (blits, `getBytes`/`replaceRegion`) |
| IOSurface texture | the surface's memory (guest pages shared through the IOSurface service) | directly, with the same rule as shared buffers |
| inline bytes | the driver's per-command-buffer shared buffer | as shared buffers |

There is no flush, invalidate or `didModifyRange` traffic in any
capture: completion (event 101) is the only synchronization point.

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
| 29 | `…instanceCount:baseVertex:baseInstance:` (short) | u16 type, u16 index type, u32 index buffer ref, u16 index buffer offset, u16 index count, u16 instance count, i16 base vertex (−2 is `0xFFFE`), u32 base instance |
| 16 | `drawPrimitives:indirectBuffer:` | u64 indirect offset, u32 indirect buffer ref, u32 primitive type |
| 17 | `drawIndexedPrimitives:…indirectBuffer:` | u16 type, u16 index type, u32 index buffer ref, u32 indirect buffer ref, u64 index buffer offset, u64 indirect offset |
| 23 | `memoryBarrierWithScope:afterStages:beforeStages:` | u16 scope, u8 after stages, u8 before stages |
| 101 | `setBlendColorRed:…` | 4 × f32 |
| 102 | `setColorStoreAction:atIndex:` | two u32 (action, index; both 0 in our run, order open) |
| 104 | `setDepthStencilState:` | u32 ref |
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
| 119 | `setStencilReferenceValue:` / `…Front…back…` | u32 front, u32 back (the one-value call sends it twice) |
| 124 | `setTriangleFillMode:` | u64 |
| 125 | `setVertexBuffer:offset:atIndex:` | u32 index, u32 count (1), u32 buffer ref, u64 offset |
| 126 | `setVertexBufferOffset:atIndex:` | u32 index, u64 offset |
| 127 | `setVertexSamplerState:atIndex:` | u32 index, u32 count, u32 ref |
| 129 | `setVertexTexture:atIndex:` | u32 index, u32 count, u32 ref |
| 130 | `setViewport:` | 6 × f64 (x, y, width, height, znear, zfar) |

Primitive type and index type are the `MTLPrimitiveType` and
`MTLIndexType` values. The short forms were used whenever every value fit
in 16 bits (6000 consecutive draws with starts up to 5999 all used op 1).
The long forms of the instanced draws are ops 2, 4 and 8 (agent H,
2026-10-13: our `mtlvary render` with instance counts, starts and base
instances of 0x12345 and 0x23456, recorded with `mslog` on this Mac's
simulator; level 3). The same capture confirms op 29's field order: u16
index buffer offset before u16 index count, then u16 instance count, u16
base vertex, u32 base instance. An instance count of 0x12345 with a
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
| 209 | `setStageInRegion:` | u64 × 3 origin, u64 × 3 size |
| 211 | `setThreadgroupMemoryLength:atIndex:` | u64 length, u32 index |
| 214 | `memoryBarrierWithResources:count:` | u32 count, u32 ref × count |
| 215 | `memoryBarrierWithScope:` | u32 scope |

`computeCommandEncoderWithDispatchType:` concurrent produced no extra
record.

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
3. Device ops 25, 31 (two reply sizes), 35, 39's second word; ops 26, 29,
   36, 40 (not seen); which of 1010/1011 is layout and encoder; op 1008
   (inferred queue).
4. Long forms of instanced draws, `setVertexBuffers:offsets:withRange:`
   (the `count` word suggests multi-slot records), tessellation, tile
   shaders, parallel render encoders, `setColorStoreAction` field order,
   visibility result mode, `textureBarrier`, `setLineWidth`.
5. How a host reports a shader translation failure or a GPU fault to the
   client (a status 5 completion is honored; nothing else observed).
6. Argument-buffer encoding (op 16 payload, op 19 values, what the host
   writes into argument buffers): only one probe and, in the heavy boot,
   WeatherPoster used
   them.
7. Whether `defaultRasterSampleCount`-only passes ever occur in the boot
   (they crashed the macOS host).

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
