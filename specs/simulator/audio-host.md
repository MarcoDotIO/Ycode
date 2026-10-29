# Spec: the simulator audio host service (`com.apple.audio.audiohald`)

Status: **reference** (agent VISIONOS-OBS6, 2026-10-27), **implemented in
Ycode** (§13, agent AUDIO-HOST, 2026-10-27), written for
`visionos.md` §9 Q22 and §10.17. It describes the host-side audio endpoint
that the visionOS 27.0 (24M362) and iOS 27.1 (24A94401) runtimes use: who
looks it up, the message protocol, the objects and properties a client asks
for, the shared-memory IO cycle, and the smallest service with which
backboardd's PHASE engine starts and audio IO runs.

Every fact comes from black-box runs on this Mac (level 3): a Mach message
recorder of our own inserted into reference guest processes, a probe of our
own that uses the public CoreAudio property API inside the guest, and
reply-rewriting experiments made by the same recorder inside the guest.
Selector, scope and class four-character codes are public CoreAudio
interop constants (level 1, the macOS SDK's `AudioHardware.h` and
`AudioHardwareBase.h`). No Apple binary was disassembled or decompiled.
Header, disposition and descriptor terms are those of `mach-ipc.md` §2. All
integers are little-endian. A four-character code is written `'abcd'`; in
a message it is a 32-bit integer whose most significant byte is the first
character.

Terms:

- **The service**: the Mach service registered into the guest's
  `user/<uid>` domain under `com.apple.audio.audiohald` (a host-side
  endpoint, `launchd-sim.md` §6.3). In the reference it is the Mac's own
  audio daemon: guest processes talk to the same server, with the same
  protocol, as Mac applications do, and see the Mac's devices.
- **The client**: the runtime's CoreAudio framework (HAL client) inside a
  guest process. Every guest audio stack (AudioToolbox, AVAudioSession's
  simulator implementation, AURemoteIO, PHASE) reaches the host only
  through it.
- **Object ID**: a 32-bit identifier chosen by the service. The system
  object is 1. The client keeps its own, different numbering for the
  public API (the probe saw the default output as 137 where the wire said
  27553), so the service may choose any IDs other than 0 and 1.
- **Object port**: a send right the service hands out for one object
  (message 2). Requests about an object go to its object port; requests
  about the system object go to the service port.

## 1. Endpoints

| Name | Used by guests | Notes |
|---|---|---|
| `com.apple.audio.audiohald` | yes: every audio client, first message within milliseconds of its first CoreAudio call | looked up with `bootstrap_look_up2` from CoreAudio |
| `com.apple.audio.coreaudiod` | no | not looked up and not connected to by any guest process in a visionOS first boot (482 processes, 150 s) or an iOS boot with an app playing a system sound |

Without the audiohald name the client logs "HALC_ProxyObjectMap::_CreateSystemObject:
there is no system object", retries the look-up about once per 1.1 s
(879 failed look-ups in 150 s of a visionOS boot), and every default-device
query fails ("Could not find default device for dOut").

Other audio Mach traffic seen in guest processes is guest-internal and not
the host's business: AudioToolbox's message 89000 (108 bytes, 12 ms
timeout, once per IO cycle in backboardd) goes to a port that did not come
from the service; `com.apple.audioanalyticsd` and
`com.apple.audioanchorservice` are guest names that fail in the reference
too (launchd: "No such process").

## 2. Transport conventions

- Plain Mach messages in the MIG style. Request IDs are 1010000 + n; the
  reply to request 1010000 + n has ID 1010100 + n. This spec names a
  message by n (for example, message 19 is request 1010019).
- Requests that expect a reply carry a send-once reply right (local
  disposition make-send-once) and a voucher (copy-send). Simple requests
  have header bits 0x00131513, complex ones 0x80131513. Messages 35 and 36
  are one-way (bits 0x00130013, no reply port).
- The client sends with send and receive timeouts of 30 000 ms (options
  send | receive | send-timeout | receive-timeout). A slower reply is a
  failure for the client.
- A request body starts, after the descriptors if any, with the 8-byte NDR
  record (bytes 00 00 00 00 01 00 00 00); the arguments follow. A simple
  reply has the NDR record, a 32-bit return code (0 = success), then its
  values. A complex reply (one that carries a port or out-of-line data) has
  its descriptors, the NDR record and its values, and no return code. No
  error reply was observed: the client asks message 13 ("has property")
  before getting a property.
- The client's receive buffer for each reply is the reply's exact size plus
  8 bytes of trailer (column "rcv" in §3). A larger reply does not fit.
- Out-of-line data is sent with the copy option; port descriptors in
  replies are send rights (received as move-send).

## 3. Message table

Sizes are total message sizes in bytes (header included). "Obj" is the
object ID of the request; "addr" is the property address: selector, scope,
element (three 32-bit words).

| n | Our name | Sent to | Request: size, contents after NDR | Reply: size (rcv), contents |
|---|---|---|---|---|
| 71 | register client | service port | 88, complex: port descriptor (make-send of the client's notification receive right), OOL (the process name in UTF-16, may be empty); words 1, 0, 9, 0, name length in UTF-16 units, 2 | 36 (44): return code |
| 2 | get object | service port | 36: obj | 56 (64), complex: port descriptor (the object port); class, base class |
| 13 | has property | object or service port | 48: obj, addr | 40 (48): return code, 1 or 0 |
| 14 | is settable | same | 48: obj, addr | 40 (48): return code, 1 or 0 |
| 16 | get UInt32 | same | 48: obj, addr | 40 (48): return code, value |
| 25 | get Float64 | same | 48: obj, addr | 44 (52): return code, 8-byte value |
| 19 | get UInt32 array | same | 48: obj, addr | 56 (64), complex: OOL array; element count |
| 26 | get Float64 array | same | 48: obj, addr | 56 (64), complex: OOL array; element count (Float64s) |
| 21 | get string | same | 48: obj, addr | 56 (64), complex: OOL UTF-16 text without terminator; length in UTF-16 units |
| 27 | get property list | same | 48: obj, addr | 56 (64), complex: OOL XML property list text; length in bytes |
| 15 | get bytes with qualifier | same | 72, complex: OOL qualifier; obj, addr, qualifier size | 56 (64), complex: OOL data; size in bytes |
| 20 | get UInt32 array with qualifier | same | 72, complex: OOL qualifier; obj, addr, qualifier size | 56 (64), complex: OOL array; element count |
| 30 | set UInt32 | same | 52: obj, addr, value | 36 (44): return code |
| 31 | set Float32 | same | 52: obj, addr, value (IEEE single) | 36 (44): return code |
| 46 | set UInt32 array | same | 72, complex: OOL array; obj, addr, element count | 36 (44): return code |
| 29 | set bytes with qualifier | same | 92, complex: OOL qualifier, OOL data; obj, addr, qualifier size, data size | 36 (44): return code |
| 35 | add listener | same | 48, one-way: obj, addr (the client always used the wildcard address `'****'`, `'****'`, 0xFFFFFFFF) | none |
| 36 | remove listener | same | 48, one-way: obj, addr | none |
| 3 | create IO context | service port | 56, complex: OOL XML property list; its length | 40 (48): return code, new object ID |
| 5 | create aggregate device | service port | 56, complex: OOL XML property list; its length | 40 (48): return code, new object ID |
| 10 | set IO context port | IO context's object port | 52, complex: port descriptor (make-send of a client receive right); obj | 36 (44): return code |
| 63 | start IO | IO context's object port | 52, complex: port descriptor (make-send of the client's wake receive right); obj | 64 (72), complex: port descriptor (the IO port), port descriptor (memory entry of the IO region); region size in bytes |
| 59 | get workgroup port | IO context's object port | 36: obj | 40 (48), complex: port descriptor (a workgroup port); no inline data |
| 12 | stop IO | IO context's object port | 36: obj | 36 (44): return code |
| 500 | property changed (service to client) | the port of message 71 | 60, complex: OOL array of addresses (12 bytes each); obj, address count | — |

No other request IDs were seen (in particular none that destroys an IO
context or an aggregate, within the 150 s boots observed).

## 4. Objects and classes

| Class | Base class | What | Reached through |
|---|---|---|---|
| `'asys'` | — | system object, ID 1 | the service port |
| `'aplg'` | `'aobj'` | plug-in | `'plg#'` of the system object |
| `'abox'`, `'aclk'` | `'aobj'` | box, clock device | `'box#'`, `'clk#'` |
| `'adev'` | `'aobj'` | device | `'dev#'` |
| `'aagg'` | `'adev'` | aggregate device made by message 5 | the reply of message 5 and `'dev#'` |
| `'asub'` | `'adev'` | aggregate's subdevice | `'ownd'` (message 20) of the aggregate |
| `'astr'` | `'aobj'` | stream | `'stm#'` of a device |
| `'vlme'`/`'levl'`, `'mute'`/`'togl'`, `'dsrc'`/`'slct'`, `'dest'`/`'slct'`, `'evis'`/`'togl'`, others | | controls | `'ctrl'` of a device |
| `'ioct'` | `'aobj'` | IO context made by message 3 | the reply of message 3 |
| `'clnt'` | `'aobj'` | process object | `'prs#'` |

For every object it learns, the client sends message 2 (once), message 35
with the wildcard address, and message 13 for `'cust'`; if that answers 1
it gets `'cust'` (message 19: triples of selector, data type, 0, data
types `'cfst'`, `'plst'`, `'raww'`) twice.

## 5. What a client asks: backboardd up to running IO

Order and replies with the reference service, after the reply-rewriting
of §8 reduced the service to one output device (boot b8; the full Mac
service answers the same questions for every plug-in, box, clock, device,
stream, control and process it lists). "Has" is message 13, "get" the
message for the property's type, "set" the setter; values are those of the
reference device (a Bluetooth headset) unless marked. Counts are per
backboardd process.

| Object | Requests (in order of first use) |
|---|---|
| system | 71; set `'powh'` = 0 (30); has/get `'vers'` = 1; 35; get `'plg#'`, `'box#'`, `'clk#'`, `'tps#'` (empty lists accepted); get `'dev#'` (4 times); later get `'prs#'` (empty accepted), get `'mlkf'` = 2, get `'dOut'` (6 times) |
| device | 2 → `'adev'`/`'aobj'`; 35; has `'cust'`, get `'cust'` (empty accepted); get `'uid '` (string), `'lnam'` (3 times); get `'stm#'` output → one stream, input → empty; get `'ctrl'` (empty accepted); get `'ioct'` (property list, §6); get `'tran'`; has/get `'hidn'` = 0; has `'siso'` = 0; has `'lisa'` = 0 (10 times); has/get `'nsrt'`; has `'srnd'` input = 0; has/get `'dch2'` output = [1, 2]; has/get `'srnd'` output (message 15, 52 bytes: layout tag 0, bitmap 0, 2 descriptions, labels 1 and 2, zero flags and coordinates); has `'acom'` = 0; has `'lnam'` = 1; has/get `'rsrc'` (string; the reference gave the driver's bundle path); after IO starts: has/get `'tran'` output; has/is-settable/set `'appv'` output (Float32 0.6, message 31) |
| stream | 2 → `'astr'`/`'aobj'`; 35; has `'cust'` = 0; get `'schn'` = 1; get `'sdir'` = 0 (output); at IO start: has `'lisa'` = 0, has/get `'sfmt'` (message 15, 40 bytes: AudioStreamBasicDescription, linear PCM, flags 9, 8 bytes per frame, 2 channels, 32 bits), has/get `'ltnc'` = 0 |
| IO context (one per device) | 3 → ID; 2 → `'ioct'`/`'aobj'`; 35; has `'cust'` = 0; get `'grid'` output twice and input twice (message 15, §6); 10; get `'fsiz'` = 512 (up to 9 times); at IO start: set `'guse'` input = [0] and output = [1, 1] (message 46); has/get `'fsz#'` (range 14…1024 frames); has `'fsiz'`; 63; 59 |
| aggregate | 5 → ID; 2 → `'aagg'`/`'adev'`; 35; has `'cust'` = 0; get `'uid '` and `'lnam'` (the name given to message 5); get `'stm#'` output → one stream, input → empty; get `'ctrl'` → empty; get `'ownd'` with an empty qualifier (message 20) → one subdevice; get `'ioct'`; get `'tran'` = `'grup'`; has/get `'hidn'` = 0; has `'siso'` = 0; has `'lisa'` = 0 (18 times); has/get `'nsrt'` (5 times); has `'srnd'` input = 0; has/get/is-settable/set `'dch2'` output = [1, 2] (message 46); has/get/is-settable/set `'srnd'` output (message 29, 52 bytes, labels 0xFFFFFFFF); has/get `'acom'` (property list, §7); at IO start: has `'dch2'` input = 0, has/get `'agrp'` = [the subdevice's device ID], has/get `'ltnc'` output |
| subdevice | 2 → `'asub'`/`'adev'`; 35; has `'cust'` = 1, get `'cust'` (empty accepted) |

In this reduced boot backboardd sent 225 requests before and around IO
start (the full reference service: 1 234, because every Mac device,
plug-in, control and process is walked). Every other audio client of the
visionOS boot (RealityEnvironment, SurfBoard, RealityLauncher and seven
more) does the same walk without starting IO; RealityEnvironment also
makes an aggregate. IO contexts are made eagerly, one per listed device,
by every client.

## 6. Property lists and records

**`'ioct'` of a device** (message 27; the client sends it back unchanged
as the argument of message 3). A dictionary:

| Key | Value |
|---|---|
| `device id` | integer: the device's object ID |
| `grid-out` | array with one dictionary per output stream group: `channels` (integer), `stream groups` (array of arrays of dictionaries `index` (integer, stream index) and `uid` (the device UID)) |
| `grid-in` | same for input (absent when the device has no input) |
| `master uid` | the device UID |

The aggregate's `'ioct'` adds `LDCM` (false), `vocal isolation type` (0)
and `voice activity detection enable` (0), and each stream-group entry adds
`drift` (true), `drift algorithm` (0), `drift quality` (127),
`extra latency` (0) and `synch padding` (true); its `uid` and `master uid`
are the subdevice's UID.

**`'grid'` of an IO context** (message 15, empty qualifier): one 56-byte
record per stream of that direction, empty when there is none:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | device ID |
| 4 | 4 | direction (0 output, 1 input) |
| 8 | 4 | 1 in every record seen |
| 12 | 4 | 0 |
| 16 | 40 | stream format (AudioStreamBasicDescription: sample rate as Float64, format `'lpcm'`, flags 9 (float, packed), bytes per packet 8, frames per packet 1, bytes per frame 8, channels 2, bits 32, reserved 0) |

**Property-changed notification** (message 500): the out-of-line array
holds addresses of 12 bytes (selector, scope, element); the inline words
are the object ID and the number of addresses. Seen in backboardd:
`'dev#'` of the system object (after its aggregate appeared), `'dch2'`
and `'srnd'` of the aggregate after it set them, `'appv'` of the device,
`'went'` and `'gone'` of the device, `'pir?'` and `'pdv#'` of process
objects, `'prs#'` of the system object (18 times), `'powh'`. None arrived
on IO-context ports (message 10).

## 7. Aggregate devices

AVAudioSession's simulator implementation in backboardd (and in
RealityEnvironment, and in iOS's systemsoundserver-simd when it plays a
sound) asks for a private aggregate over the default output device
("Creating DefaultDeviceAggregate"). Message 5's property list:

| Key | Value |
|---|---|
| `master` | the output device's UID |
| `name`, `uid` | `iOSSimulatorAudioDevice-<pid>-<n>` (n = 0) |
| `private` | 1 |
| `subdevices` | array of one dictionary: `channels-in` 0, `channels-out` 2, `drift` 1, `name` (the device name), `uid` (the device UID) |

The service answers a new device ID. The client then requires that ID in
the system object's `'dev#'` list (it re-reads `'dev#'`); when the ID is
missing it logs "failed to find the device", asks again with the same UID
(the reference service then answers error `'nope'`), retries ten times,
gives up ("Unable to build a valid aggregate after 10 tries"), and PHASE
does not start (§8). The aggregate's `'acom'` (message 27) is the
composition: the dictionary of message 5 with the subdevice entry
extended by `don't pad` 0, `drift algorithm` 0, `drift quality` 127,
`latency-in` 0, `latency-out` 0.

The IO that PHASE runs is on the aggregate's IO context, not on the
device's.

## 8. What is required (experiments in the reference)

Each row is one visionOS first boot with our recorder rewriting the
service's replies inside every guest process (§9 of the notes,
`research/notes/visionos-renderer-observations.md`, OBS6).

| Boot | Service as the guest saw it | PHASE engine | Room loads, backboardd aborts? |
|---|---|---|---|
| b1, b2 | the reference (the Mac's 12 devices, 15 plug-ins, 3 boxes, 2 clocks, about 60 processes) | starts | loads, no abort |
| b3 | absent (look-ups answered 1102) | fails ("Failed to initialize with mode default, sr 48000 Hz"), retried hundreds of times | aborts with 'API Misuse', "Cannot create a PHASEMaterial with nil or invalid PHASEEngine", 0.4 to 0.8 s after the PSO line; 12 abort cycles in 150 s |
| b5 | reference, but message 5 answered with an error | fails | aborts, 10 cycles |
| b4b | `'plg#'`, `'box#'`, `'clk#'`, `'tps#'`, `'prs#'` empty; `'dev#'` = the default output device and the client's own aggregates | starts | loads, no abort |
| b6 | as b4b, and every `'ctrl'` and `'cust'` list empty | starts | loads, no abort |
| b8 | as b6, and no notification (message 500) delivered | starts | loads, no abort |

In the iOS 27.1 guest, a probe whose message 59 reply was replaced by a
null port, or by an error, fails AudioDeviceStart (return 89 after three
tries of messages 63 and 59): the workgroup port is required.

So the smallest service with which PHASE starts and IO runs is: the system
object with empty plug-in, box, clock, tap and process lists and a device
list holding one output device plus any aggregates the client creates; one
output device with one stream, no controls and no custom properties;
creation of IO contexts and aggregates; the IO protocol of §10 with a real
workgroup port. Notifications are not needed. No guest asked for an input
device's IO (`'dIn '` may name no device; the probe then reported 0).

## 9. Values for a minimal stereo output device

Ycode chooses the values; the reference device's values are given where
they differ. Selector semantics are the public ones (level 1).

| Object | Property | Minimal value | Reference |
|---|---|---|---|
| system | `'vers'` | 1 | 1 |
| system | `'mlkf'` | 2 | 2 |
| system | `'dOut'`, `'sOut'` | the device's ID | same |
| system | `'dIn '` | 0 (no input device) | the Mac's microphone |
| device | `'uid '` | a fixed UID of Ycode's choice | `<Bluetooth address>:output` |
| device | `'lnam'` | a name of Ycode's choice | the headset's name |
| device | `'tran'` | `'bltn'` or `'virt'` (PHASE logged "setting output type = headphones (bluetooth)" from the reference value; the effect of other values was not tested) | `'blue'` |
| device | `'nsrt'` | 48 000.0 | 44 100.0 |
| device | `'hidn'` | 0 | 0 |
| device | `'dch2'` output | [1, 2] | same |
| device | `'srnd'` output | 2 descriptions, labels 1 and 2 | same |
| device | `'rsrc'` | has = 0, or any string | the driver bundle path |
| stream | `'sdir'`, `'schn'`, `'ltnc'` | 0, 1, 0 | same |
| stream | `'sfmt'` | 48 000 Hz, `'lpcm'`, flags 9, 8 bytes per frame, 2 channels, 32 bits | 44 100 Hz otherwise the same |
| IO context | `'fsiz'` | 512 | 512 |
| IO context | `'fsz#'` | one range, 14 to 1024 | same |
| aggregate | `'ltnc'` output | 0 or a small latency | 8961 (Bluetooth) |
| aggregate | `'agrp'` | [device ID] | same |

## 10. The IO protocol

**Start.** On the client's IO thread: message 46 sets `'guse'` (stream
usage) for input [0] and output [1, 1]; message 63 hands the service a
make-send right for the client's *wake port* and receives the *IO port*
(a send right), a memory entry and the region size (65 536 bytes for a
plain device's context, 245 760 for the aggregate's, on visionOS and iOS
alike). The client maps the whole region read-write. Message 59 returns
the workgroup port; the client passes it to os_workgroup_create_with_port
("AudioHALC Workgroup") and its IO thread joins that workgroup. The public
header `os/workgroup_object.h` (level 1) documents that this function takes
a port made by os_workgroup_copy_port, possibly in another process: the
service hands out the port of a workgroup of its own, and the guest's
libdispatch and kernel must accept it (in xnu, workgroups are backed by
work intervals; how the runtime checks the port was not traced).

**The region** (offsets from its start; written by the service unless
marked):

| Offset | Size | Field |
|---|---|---|
| 0x000 | 8 | host ticks per sample frame, Float64 (544.2174 at 44 100 Hz with the 24 MHz host clock) |
| 0x008 | 8 | sample frames per host tick, Float64 (its inverse) |
| 0x010 | 8 | rate scalar, Float64 (0.9999995) |
| 0x018 | 4 | IO buffer size in frames (512) |
| 0x020 | 64 | the device's last zero timestamp (AudioTimeStamp: sample time, host time, flags 3); advances by the zero-timestamp period |
| 0x060 | 64 | "now" of the current cycle (sample time, host time, rate scalar, flags 7) |
| 0x0A0 | 64 | input time of the current cycle (now − buffer size) |
| 0x0E0 | 64 | output time of the current cycle (now + buffer size, as the device's safety offset was 0) |
| 0x124 | 4 | the current cycle number (the ID of the last wake message) |
| 0x4000 | 4 | number of output buffers (1) |
| 0x4004 | 4 | the output buffer's capacity in bytes (8 192 for a plain device: 1024 frames × 8 bytes; 196 608 for the aggregate) |
| 0x8000 | | output data: interleaved Float32, buffer size × channels × 4 bytes per cycle, written by the client |

The AudioTimeStamp layout is the public one (64 bytes: sample time,
host time, rate scalar, word clock time, SMPTE time, flags, reserved).
The IOProc of our probe received exactly the "now" and "output time"
records of the region, and the data it wrote appeared at 0x8000. How the
client finds the data offset (fixed or derived from the 0x4000 table) and
the input-side layout were not determined; a service should reproduce the
observed layout and sizes.

**The cycle.** The IO thread sends a 24-byte header-only message (bits
0x13, copy-send, no reply port, no body) to the IO port whose ID is the
number of the last wake it received (0 for the first), and in the same
call waits on its wake port without a timeout. The service then writes the
next cycle's timestamps into the region and sends a 24-byte header-only
message to the wake port whose ID is the previous ID + 1. The client runs
its IOProc, writes the output at 0x8000, and sends the next message. A
wake with ID 0 restarts the numbering: the reference sent it after a cycle
in which the client was late (16 to 56 ms between messages instead of
11.6), and the client answered with ID 0. Cycles came every 11.6 ms (512
frames at 44 100 Hz) for the whole boot (12 700 cycles in 150 s); PHASE
ran IO continuously while backboardd lived.

**Stop.** The stopping thread sends a cycle message with the next ID to
the IO port and another to the client's own wake port (to release the IO
thread); the IO thread sends a last cycle message (send only) and then
message 12. The service stops waking the client on message 12. The probe
then reset `'guse'` output to [1, 0].

**Timing.** The client never waits on the wall clock: it blocks only on
the wake message, and takes all times from the region. The reference
service paced wakes at the device's real rate. Whether a service that
wakes faster or slower than the timestamps say, or that never plays the
data, disturbs PHASE was not tested; the safe choice is to wake at the
nominal period on the guest's host clock, advance the sample times by the
buffer size per cycle, keep host times consistent with offsets 0x000 and
0x010, and discard (or play) the data.

## 11. iOS 27.1

The same name, message IDs, sizes, objects, aggregate naming, region sizes
and layout, cycle and workgroup protocol. In an iOS boot SpringBoard does
the client walk (message 71 with name `com.apple.springboard`, 12 IO
contexts, no IO); a system sound played by our probe made
systemsoundserver-simd register, create `iOSSimulatorAudioDevice-<pid>-0`
and run IO (1 484 cycles). An iOS guest without the service therefore gets
no audio at all, silently, as visionOS's does.

## 12. The audio settings files

Not part of the service, but read by the same clients
(`launchd-sim.md` §3): the host writes
`DEV/data/var/run/com.apple.coresimulator.audio.plist` before boot (keys
`sim_input_device_uid`, `sim_output_device_uid`,
`useHostDefaultInputDevice`, `useHostDefaultOutputDevice`). The guest's
CoreSimulatorBridge reads it about one second after it starts and writes
`DEV/data/var/run/simulatoraudio/audiosettings.plist` (keys
`sim_input_device_uid`, `sim_output_device_uid`, `sim_ringer_state` 1,
`sim_volume` 60; written to a temporary file and renamed; rewritten 14 s
later). AVAudioSession's simulator code in each audio client opens the
`simulatoraudio` directory and the file (`SIMULATOR_AUDIO_SETTINGS_PATH`);
backboardd's first open comes before the file exists and fails
(ENOENT, "Failed to open audio settings plist!") in the reference too, and
its later opens succeed. The volume (0.6) is what the client then sets as
`'appv'` on the output device.

## 13. Ycode implementation (agent AUDIO-HOST, 2026-10-27)

Clean-room: written from §1–§12, the public CoreAudio headers' codes and
record layouts, and xnu's open source for work intervals; no Apple
simulator, Xcode or reference tool was run. Code:
`ycode/Sources/YcodeHostServices/AudioHostService.swift` (Mach side, IO),
`AudioHostModel.swift` (objects and properties), `AudioCapture.swift`;
the kernel side is `work-intervals.md`.

### 13.1 The endpoint

`com.apple.audio.audiohald` is a host-side name (`launchd-sim.md` §6.3),
registered late (after the GPU, surface and HID names; its clients look it
up again about once a second until it exists). `com.apple.audio.coreaudiod`
stays unregistered. One service thread receives on a port set holding the
service port, one port per object handed out by message 2 (made on first
use; the system object's is the service port), one IO port per running IO
context, and a notification port. `YCODE_DEBUG_NO_AUDIO=1` turns the
service off (the guest then has no audio system, as before);
`YCODE_DEBUG_AUDIO=1` logs every request with its answer.

### 13.2 Messages

Every message of §3 is answered with the reply ID + 100 and the exact
reply size of the table (tests check sizes and IDs on the wire). Simple
replies carry NDR, a return code and values; complex replies carry their
descriptors, NDR and a count, and no return code. Getting a property the
object does not have answers `'who?'` (simple) or an empty region (complex);
setting one that is not settable answers `'who?'`. Listeners (35, 36) are
accepted silently; message 500 is never sent. Message 10's port is
dropped. Unknown IDs answer MIG_BAD_ID (−303). Message 71's notification
port is kept with a dead-name request: when it dies the client's process
ended, and its aggregates, IO contexts and running IO go.

### 13.3 Objects

| ID | Object | Notes |
|---|---|---|
| 1 | system (`'asys'`) | `'vers'` 1, `'mlkf'` 2, `'powh'` settable, empty `'plg#'`, `'box#'`, `'clk#'`, `'tps#'`, `'prs#'`; `'dev#'` = [32] plus the aggregates **the asking process** made (they are private); `'dOut'`, `'sOut'` 32; `'dIn '` 0; `'cust'` empty |
| 32 | output device (`'adev'`) | UID `dev.ycode.simulator.audio.output`, name "Ycode Simulator Output", manufacturer "Ycode", `'tran'` `'bltn'` (§9 Q4 open), 48 000 Hz (`'nsrt'`, `'nsra'`), `'stm#'` output [33] / input [], empty `'ctrl'` and `'cust'`, `'ioct'` (§6), `'dch2'` [1, 2] and a 2-channel `'srnd'` (output scope only), `'appv'` output settable (Float32), `'hidn'` 0, `'ltnc'`/`'saft'` 0, `'fsiz'` 512, `'fsz#'` [14, 1024], `'alv?'` 1, `'dflt'`/`'sflt'` 1 for output |
| 33 | its stream (`'astr'`) | `'sdir'` 0, `'schn'` 1, `'ltnc'` 0, `'sact'` 1, `'term'` `'spkr'`, `'sfmt'`/`'pft '` 48 kHz Float32 stereo interleaved (flags 9); no `'cust'` |
| 0x100… | IO contexts (`'ioct'`) | made by message 3 from the description's `device id`; `'grid'` (one 56-byte record for output, empty for input), `'fsiz'` (settable 14…1024), `'fsz#'`, `'guse'` (settable per scope) |
| 0x100… | aggregates (`'aagg'`/`'adev'`) | made by message 5 (the UID and name given; a UID that exists answers `'nope'`); `'tran'` `'grup'`, one stream, one subdevice (`'asub'`/`'adev'`, `'cust'` empty) through `'ownd'` (an empty qualifier gives the subdevice), `'acom'` (§7), `'agrp'` [32], settable `'dch2'` and `'srnd'`, the aggregate `'ioct'` keys |

"Has property" answers 0 for everything else (`'lisa'`, `'siso'`,
`'rsrc'`, `'muid'`, `'acom'` of the device, input-scope `'dch2'`/`'srnd'`, …).
IDs above 1 other than 32 and 33 come from one counter starting at 0x100.

### 13.4 IO

- **Start (63).** A new zero-filled shared memory object of 65 536 bytes
  (245 760 for an aggregate's context), a memory entry for it (one send
  right moves to the client, one stays for snapshots), an IO port (a
  receive right; the client gets a send right). The region's fixed part:
  ticks per frame = guest timebase ÷ 48 000 (500.0 at 24 MHz), its inverse,
  rate scalar 1.0, buffer size, the buffer table (1 buffer of 8 192 or
  196 608 bytes). A second 63 on a running context restarts it.
- **Workgroup (59).** One work interval per IO context, made by the host
  (`WORK_INTERVAL_TYPE_COREAUDIO | GROUP | JOINABLE`, `work-intervals.md`
  §3); the reply carries a copy of its send right and no inline data.
- **Cycle.** On the client's cycle message *k* the service first takes the
  output of the last cycle from 0x8000 (capture, statistics), then owes
  wake *k* + 1 for the next cycle. The device clock is anchored at the
  first cycle message (host monotonic time and the guest's mach time read
  together); cycle *n*'s "now" is sample time *S* = *n* × 512 frames,
  host time = anchor ticks + *S* × ticks per frame. The wake goes out when
  the host clock reaches that cycle's time (one service thread, receive
  timeouts up to the earliest due wake), after the service wrote the zero
  time (*S*, flags 3), now (*S*, flags 7), input (*S* − 512) and output
  (*S* + 512) time stamps, the buffer size and the wake ID (0x124). A
  client message that arrives more than one period after its cycle's time
  restarts the numbering: wake 0, at the cycle the device's clock is in.
- **Stop (12)** ends the waking; the IO port is destroyed, the wake and
  entry rights dropped. A wake whose port is dead stops the context too.
- **Output** is discarded. `YCODE_AUDIO_CAPTURE=<path.wav>` writes it as a
  16-bit PCM WAV at 48 kHz stereo: each block is mixed in at its play time
  on the host clock (output time), so overlapping clients add up; a gap of
  more than a second with no IO is left out; the header is rewritten every
  second. Each IO stop logs its cycles, restarts, failed wakes, non-zero
  output samples and peak; the capture's totals are logged at the end of
  the run.
- **Real playback** would hook in where the capture does
  (`AudioHostService.deliver`: interleaved Float32 blocks with their host
  play time): on Linux a PipeWire or PulseAudio stream fed from a jitter
  buffer, or the blocks streamed to the IDE next to the display stream
  (`display-stream.md`). Neither exists yet.

### 13.5 What else the guest needed

- **`mlock`.** The HAL client wires the IO region (`HALB_SharedBuffer::Lock`)
  and gives up the start when that fails; Ycode's kernel had no `mlock`
  (ENOSYS). Ycode now answers `mlock`/`munlock` (BSD 203, 204) as a kernel
  whose memory is never paged out: the range, widened to pages, must be
  mapped (ENOMEM), a wrapping range is EINVAL, otherwise 0.
- **Workgroup ports.** Ycode's guest `libsystem_kernel` (SimHostLibs
  `kernel/workinterval.c`) implemented the work-interval calls in the
  library. `work_interval_get_flags_from_port`, `_join_port` and `_leave`
  now ask the kernel first (GET_FLAGS, JOIN), so the host's workgroup port
  reports its CoreAudio flags and is joined; other ports keep the old
  answers (flags 0, success).
- **Normal pthread mutexes.** With IO running, PHASE's engine stop led to
  backboardd aborting with "mutex lock failed: Resource deadlock avoided"
  (`visionos.md` §10.19.1 item 4): CoreAudio's caulk and PHASE unlock a
  normal mutex from a thread other than the holder, and relock one that
  another thread is about to release. Ycode's guest `libsystem_pthread`
  (SimHostLibs `pthread/mutex.c`) answered EPERM and EDEADLK; it now
  behaves as Darwin's: unlocking a held normal mutex from any thread
  releases it, and relocking a normal mutex one holds waits for it (an
  unheld normal mutex still answers EPERM on unlock; error-checking and
  recursive mutexes are unchanged).
- **Settings files.** Before boot Ycode writes
  `DEV/data/var/run/com.apple.coresimulator.audio.plist` with
  `sim_output_device_uid` = the device's UID and an empty input UID, and
  `DEV/data/var/run/simulatoraudio/audiosettings.plist` (`sim_input_device_uid`
  "", `sim_output_device_uid` the device UID, `sim_ringer_state` 1,
  `sim_volume` 60): the reference's CoreSimulatorBridge writes the latter,
  and Ycode does not run that host program. backboardd's first open
  therefore succeeds under Ycode (it fails in the reference, harmlessly).

### 13.6 Snapshots

A snapshot keeps the service's state (`audio` host-service record, read
with the guest quiesced): the model (aggregates, IO contexts, power hint,
volume, the ID counter), the object ports, the clients' ports, the
workgroup ports and every running IO context (its memory entry, IO and
wake ports, sample time). The host task's rights are restored under their
names; the restored service takes the tables back and, once the guest
clock is set, gives every running context a wake 0 at the cycle after the
saved one (a restart; the device clock goes on from the saved sample time).

### 13.7 Results

Visionos.md §10.19 (visionOS and iOS boots on the Thor).

### 13.8 Open questions (reference-only)

1. Q4 of `visionos.md` §10.17.3: whether `'tran'` changes PHASE's output
   mode (Ycode answers `'bltn'`).
2. The pacing a reference client tolerates (§10.17.3 Q2): Ycode wakes at
   the nominal period and restarts with wake 0 when the client is more
   than a period late; whether the reference service does the same, or
   skips ahead without a restart, was not observed.
3. Whether the reference's zero time stamp advances once per cycle (Ycode)
   or per ring-buffer period.
4. The flags of the reference's workgroup (Ycode: CoreAudio type, group,
   joinable), seen through `work_interval_get_flags_from_port` in a guest.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Names looked up, no `coreaudiod` use, retries without the service (§1) | 3 | our recorder's look-up and XPC hooks in every guest process, visionOS boots b2, b3, iOS boot i1 |
| Message IDs, bits, sizes, timeouts, reply sizes and receive sizes (§2, §3) | 3 | our recorder (`mach_msg`, `mach_msg_overwrite`, `mach_msg2_internal` interposed), probe runs p2–p5, boots b2, b7, b8, i1 |
| Meaning of each message (§3) | 3 | which public API call of our probe produced it, the property types of the selectors asked, and the replies |
| Selector, scope, class codes and AudioStreamBasicDescription, AudioTimeStamp, AudioChannelLayout layouts | 1 | macOS SDK `AudioHardware.h`, `AudioHardwareBase.h`, `CoreAudioTypes.h` |
| Objects, request order, replies (§4, §5) | 3 | recorder logs decoded by our scripts, boots b2 (full) and b8 (reduced) |
| Property lists (§6, §7) | 3 | recorder OOL dumps (b7 with 8 KiB dumps) |
| Notifications (§6) | 3 | our relay port in place of the client's (b7: logged and forwarded; b8: dropped) |
| Required and optional parts (§8) | 3 | reply-rewriting boots b3–b8, probe runs ip3 (iOS) |
| Region layout and cycle (§10) | 3 | region dumps at chosen cycles (probe p3, b2, b7, iOS ip1) compared with the timestamps our probe's IOProc received |
| Workgroup port nature | 1 | macOS SDK `os/workgroup_object.h` |
| Settings files (§12) | 3 | the recorder's file hooks in every guest process (b2), file contents |
| Ycode implementation (§13) | 1 | §1–§12; CoreAudio headers; xnu work-interval sources; Ycode code and tests (`AudioHostServiceTests`, `WorkIntervalTests`, `Stage3bTests.mlockChecks`) |
| What the guest needed besides the service: `mlock`, workgroup flags, normal-mutex semantics (§13.5) | 1, 3 | Ycode boots on the Thor (`visionos.md` §10.19): guest log stream ("HALB_SharedBuffer::Lock: mlock failed"), the host log |

Level 4 and level 5 were not used (also not for §13).
