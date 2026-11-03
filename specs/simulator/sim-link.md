# Spec: the simulator link (Ycode's own connection to a simulator host)

Status: **implemented** (agent REMOTE-X86, 2026-10-31). Ycode-original
design: nothing here describes Apple software. It defines how a client (the
Linux or macOS IDE, the viewer, `ycode sim remote`) reaches a simulator host
(an arm64 Linux machine running `ycode-simd`) without ssh: device list,
boot, install, launch, shutdown, the display stream (`display-stream.md`)
with input, and the device's sound, over one authenticated and encrypted
TCP connection per purpose plus an encrypted UDP media channel.

Code: `ycode/Sources/YcodeSimLink` (portable: Noise, identities, pairing,
channels, the media channel, the host service and the client),
`ycode/Sources/ycode-simhost` (the host's service), `ycode sim remote …`
(`SimRemoteCLI.swift`, dispatched by `ycode/Sources/ycode/main.swift`),
`ycode-sim-viewer --link` (`YcodeRemoteViewerSDL/ViewerMain.swift`), the
Linux IDE's run destinations (`YcodeIDEShell/ShellRemoteRun.swift`).
Tests: `Tests/YcodeSimLinkTests`, `Tests/YcodeIDEShellTests/ShellRemoteRunTests.swift`.

## 1. Pieces and where they run

| Piece | Runs on | Does |
|---|---|---|
| `ycode-simhost serve` | the simulator host, as the user, no root | listens on TCP (control and display connections) and UDP (media); runs the host-side launcher (`scripts/ycode-sim.sh`, the IDE's `ycode-sim`) per device with a display socket; relays display streams |
| `ycode-simhost pair` / `identity` / `trust` / `peers` / `untrust` | the host | pairing window, the host's pairing file, trusted clients |
| `ycode sim remote …` | a client | pair, devices, create, boot, shutdown, log, install (upload), run, view |
| `ycode-sim-viewer --link <device> [--host N]` | a client | the device window over the link |
| Linux IDE (`ycode-ide`) | a client | each paired host's devices are run destinations; Run builds here and runs there (§10) |

## 2. Identities and trust

- Each machine has one **Ed25519 identity** (`identity.key`, 32 bytes, mode
  0600, made on first use) in its link directory: `$YCODE_SIM_LINK_HOME`,
  else `~/.config/ycode/sim-link` (mode 0700). A key file readable by others
  is refused.
- **Trusted peers** (`trusted-peers.json`, 0600): name, Base64 public key,
  role (`host` or `client`), for hosts the address `<host>:<control port>`
  and the media port. A host name names one key: re-pairing replaces it.
- A fingerprint for people to compare: the first 10 bytes of SHA-256 of the
  public key as five groups of four hex digits (`d43e-5a2a-6964-235a-c867`).
- Nothing about a peer is trusted except its key: addresses can change,
  names are labels.

## 3. Connections (TCP)

Every connection, from the first byte:

1. **Preamble** (5 bytes): `YSL1`, then `X` (normal) or `P` (pairing).
2. **Handshake**: Noise Protocol Framework revision 34,
   `Noise_XX_25519_ChaChaPoly_SHA256` (pairing: `Noise_XXpsk3_25519_ChaChaPoly_SHA256`),
   prologue `ycode-sim-link/1`, fresh X25519 static keys per connection.
   Each handshake message is length-prefixed (u16 big-endian), at most 2 048
   bytes.
   - message 1 (client): `e`; empty payload.
   - message 2 (host): `e, ee, s, es`; payload = the host's Ed25519 public key
     (32) ‖ its signature (64) over `"YSL1 responder"` ‖ the handshake hash
     before the payload.
   - message 3 (client): `s, se` (psk3: then `psk`); payload = the client's
     Ed25519 key ‖ signature over `"YSL1 initiator"` ‖ hash ‖ the hello
     (JSON: `purpose` `control`, `display` or `pair`; `device`; `client`, its
     name; `media`, whether it wants the media channel).
   The signatures bind each side's long-term identity to this handshake (and
   so to its ephemeral and static keys); pinning is on the Ed25519 keys.
3. **The client checks the host before identifying itself**: a host key
   that is not the pinned one ends the connection after message 2, so an
   impostor never learns who is connecting.
4. **The host checks the client before reading anything else**: message 3
   must decrypt (pairing: only with the code's key), the signature must
   verify, and the key must be a trusted client (or the purpose `pair` in
   an open pairing window). Otherwise the connection is closed without a
   reply. Before that point the host has parsed only the 5-byte preamble
   and three bounded handshake messages; there is no other code path.
5. **Transport records**: u16 big-endian length ‖ ChaCha20-Poly1305
   ciphertext of up to 65 519 bytes of the byte stream (Noise transport
   messages, 64-bit counter nonces, empty associated data); each direction
   rekeys (`Rekey()`, Noise §4.2) every 2^20 records. A record that fails
   authentication closes the connection.
6. The first record from the host is the **welcome** (JSON line): `ok`,
   `error`, `host`, `version`, and for a display connection with media the
   media session id and UDP port. A client that pairs treats the welcome as
   the proof that the host knew the code.

Handshakes are limited to 10 a minute per source address and 5 s each.
`TCP_NODELAY` is set on every connection.

## 4. Pairing

### 4.1 One-time code

`ycode-simhost pair` opens a pairing window for 5 minutes and prints a code
of 12 characters from a 32-letter alphabet without look-alikes (60 bits),
shown as `XXXX-XXXX-XXXX`; the client runs `ycode sim remote pair
<host>[:port] <code> [--name N] [--media-port P]`. The connection runs
XXpsk3 with psk = SHA-256(`"ycode-sim-link pairing code "` ‖ the code,
upper case, dashes and spaces removed, O→0, I and L→1). **Any attempt, right
or wrong, closes the window** (the window's key is taken when a `P`
preamble arrives). A wrong code fails at message 3 (the host cannot decrypt
it); a host without the code cannot produce a welcome the client can
decrypt. On success the host trusts the client's key (role `client`, named
by the client), and the client trusts the host's (role `host`, with the
address it used).

### 4.2 Pairing file

Without a code: `ycode-simhost identity [--name N] [--address host:port]`
prints the host's pairing file (JSON: name, Base64 key, role, address,
media port); the owner copies it to the client and runs `ycode sim remote
trust <file>`. The other way, `ycode sim remote identity` prints the
client's, and `ycode-simhost trust <file>` trusts it. Pairing files hold
only public keys; copying them needs no secrecy, only integrity (compare
the fingerprints both sides print).

## 5. The media channel (UDP)

(Frames, their timings, sound and, since XR-QUALITY, the headset mode's frame views
go by UDP when the client asks for media: a frame view has to travel with its frame,
`display-stream.md` §18. The headset viewer asks for TCP by default, `xr-viewer.md` §7.)

A display connection that asked for media gets a session id (random u32)
and the host's UDP port. Keys: HKDF-SHA256 over the handshake's two split
keys, salt = the handshake hash, info `ycode-sim-link media i2r` / `r2i`
(they never travel). Packets:

| Bytes | Field |
|---|---|
| 1, 1, 1, 1 | `Y`, version 1, direction (1 host → client, 2 client → host), epoch |
| 4 | session (little-endian) |
| 8 | counter (little-endian, per direction from 0) |
| rest | ChaCha20-Poly1305 of the payload, 16-byte tag; nonce = epoch (u8, 3 zero bytes) ‖ counter; the 16 header bytes are the associated data |

Payloads: kind 1 = fragment (u32 message id, u16 index, u16 count, at most
1 200 bytes of one display-stream message), kind 2 = client hello (sent at
start and every second). The host sends media only to the source address of
the newest authenticated client hello of that session, so it never sends to
an address that has not shown it holds the key. Receivers drop packets that
fail authentication, come from another session or direction, or repeat a
counter (4 096-packet sliding window); epochs advance every 2^24 packets,
each epoch's key = HKDF-SHA256(previous, info `ycode-sim-link media rekey`),
and one epoch either side of the newest is accepted.

The host sends **frame (0x03), frame timing (0x08) and audio (0x09)**
messages this way; everything else stays on the TCP connection. The client
reassembles messages; a message is delivered when complete unless a newer
one was; the ones it overtakes, and partial ones older than 200 ms, are
reported lost, and the client sends a keyframe request over TCP at once
(tiles and P-frames are changes against the previous picture). Audio packets
carry their own play times (`display-stream.md` §15) and are concealed or
recovered by the decoder.

`ycode-sim-viewer --media tcp` keeps everything on TCP.

## 6. Control protocol

On a `control` connection: one JSON request per line, one JSON response per
line (`ok`, `error`, `message`, and per request `devices`, `deviceTypes`,
`runtimes`, `log`, `host`, `bundleID`).

| op | Fields | Does |
|---|---|---|
| `info` | | host name, device types (`ycode-simd --list-device-types`), runtimes |
| `devices` | | each device: name, type, runtime, state (`shutdown`, `booting`, `running`, `stopping`), app |
| `create` | `device`, `deviceType` | copies the host's pristine device of that type |
| `boot` | `device`, `cold` | starts the launcher with the device's display socket (warm boot: a saved device restores) |
| `run` | `device`, `app`, `bundleID` (else read from the app's `Info.plist`) | a running device is stopped (saved) first; the launcher installs and launches the uploaded app |
| `shutdown` | `device` | SIGTERM to the launcher (it saves the device), up to 150 s, then the process group is killed |
| `log` | `device`, `lines` | the launcher's log tail |
| `upload` | `app` (`X.app`), `size` | followed by `size` bytes of a directory archive (§6.2); replaces `<home>/apps/X.app` |

Names (devices, apps) are one path component of letters, digits, `-`, `_`,
`.`, not starting with a dot, at most 64 characters.

### 6.2 Directory archive

Entries, depth first: u8 kind (1 directory, 2 file, 3 symbolic link, 0 end),
u16 path length, path (UTF-8, relative), u32 mode, u64 size, size bytes (a
file's contents, a link's target); little-endian. The reader refuses
absolute paths, `..`, `.` and empty components, absolute link targets and
targets that leave the tree, and archives larger than the announced size; it
extracts into a fresh hidden directory and renames it into place.

### 6.3 The host's devices

`<home>/devices/<name>/` with a sidecar `<name>.json` (type, runtime);
display socket `<home>/run/<name>.sock` (mode 0600, the display server's);
the launcher's log `<home>/run/<name>.log`. The launcher is started in its
own session (`POSIX_SPAWN_SETSID`) with no blocked or ignored signals, and
with the environment `scripts/ycode-sim-serve` gives it (tree, data
directory, slots, locks, GPU cache, warm boot).

## 7. Ports, addresses and firewall

| Port | Protocol | Default | Setting (`simhost.env`) | Direction |
|---|---|---|---|---|
| control and display | TCP | 47800 | `YCODE_SIMHOST_LISTEN` (`<address>:<port>`, default `0.0.0.0:47800`) | client → host |
| media | UDP | 47801 | `YCODE_SIMHOST_MEDIA_PORT` | client → host (hellos); host → client (replies to the client's source port, so the client needs no open port behind a stateful firewall) |

The client's UDP socket uses an ephemeral port. The owner's ufw rules on the
host: allow 47800/tcp and 47801/udp from the client's address only
(`ufw allow from <client> to any port 47800 proto tcp`, the same for
47801/udp). The client stores the host's ports with the pairing
(`pair … --media-port P`; default control + 1).

Checked 2026-10-31 with the real service on the Thor and the x86 PC on one
subnet (ping 0.16 ms): pairing, control and display over 47800/tcp, and
media over 47801/udp (frames, timings and sound received by UDP) all pass
the host's firewall from the x86 address.

## 8. Threat model

- **The simulator host is shared** (other users and agents have shells).
  The service runs as the user; everything it writes is in the user's own
  directories (link directory 0700, keys 0600, display sockets 0600). Other
  local users can connect to the TCP port like any LAN peer and are treated
  the same way: no access without a trusted key.
- **LAN peers** can see, drop, delay, replay and inject packets and connect
  to the ports. They learn the two machines' addresses, ports, timing and
  sizes (the stream's frame sizes are not padded); they cannot read or
  forge control, display or media traffic (AEAD under keys from an
  authenticated X25519 exchange), cannot replay it (counters, sliding
  window), cannot run a command, upload, or see the screen without a
  trusted key, and cannot impersonate the host to a paired client (pinned
  key) or a client to the host.
- **Pairing**: an attacker who races the code during the 5-minute window
  gets one attempt with a 60-bit code; a man in the middle at pairing time
  without the code cannot complete either side (§4.1). A lost or copied
  identity key is the trust anchor: remove the peer with `untrust` /
  `unpair` and pair again.
- **Denial of service** (flooding the ports, exhausting handshake slots) is
  limited (handshake rate and time limits) but not prevented.
- **Out of scope**: the host's root and the guest itself.

## 9. Host configuration

`ycode-simhost serve --config <file>` (else `$YCODE_SIMHOST_CONFIG`, else
`~/.config/ycode/simhost.env`): `KEY=value` lines, the keys of
`scripts/ycode-sim-serve`'s `sim-serve.env` (`YCODE_SIM_HOME`,
`YCODE_SIM_TREE`, `YCODE_SIM_RUNTIME`, `YCODE_SIM_RUNTIME_<TYPE>`,
`YCODE_SIM_PRISTINE_<TYPE>`, `YCODE_SIM_LOCKS`, `YCODE_SIM_SLOTS`,
`YCODE_SIM_GPU_CACHE`, `YCODE_SIM_GUEST_TOOLS`, `YCODE_SIM_HOURS`) plus
`YCODE_SIM_LAUNCHER` (default `<home>/bin/ycode-sim`), `YCODE_SIMHOST_LISTEN`,
`YCODE_SIMHOST_MEDIA_PORT`, `YCODE_SIMHOST_NAME`. SIGTERM or SIGINT stops
every device (saved) and exits. Machine paths and addresses stay in these
files, never in the repository.

## 10. Remote run from Linux (`ycode sim remote run`, the IDE)

`ycode sim remote run <device> <App.app>` uploads the app (§6.2), asks the
host to `run` it, then opens the viewer. In the Linux IDE (`ycode-ide`), each
device of each paired host that answers within the connection's timeout is
a destination "<device> (<host>)" (`YCODE_IDE_REMOTE_DESTINATIONS=0` leaves
them out); Product ▸ Run on one builds the scheme for the iOS Simulator on
this machine with `scripts/ycode-ios-build-linux` (the user's own SDK copy,
`YCODE_USER_SDK`; `YCODE_IOS_BUILD` names another script), uploads,
installs, launches, and opens the device window (`ycode-sim-viewer --link`,
an SDL window next to the IDE's; §11); Stop closes it.

### 10.1 iOS builds on Linux

`scripts/ycode-ios-build-linux <project> <scheme> <derived data>` is
RES-STRINGS' recipe (`specs/ide/string-catalog.md` §C.7) as a script: the
user's iPhoneSimulator platform and toolchain resources in a developer folder
(`YCODE_USER_SDK`; never committed or redistributed), Ycode's `ycode build
--engine swift-build` with `ycode-swb` (`YCODE_SWB`), an upstream `ld64.lld`
(`YCODE_LD64`), the toolchain's real `bin` first on `PATH`, and the settings
`SDKROOT=iphonesimulator ARCHS=arm64`, `OTHER_SWIFT_FLAGS=-resource-dir …`,
`OTHER_LDFLAGS=-fuse-ld=lld --ld-path=… libclang_rt.iossim.a`,
`DONT_RUN_SWIFT_STDLIB_TOOL=YES`, `LM_SKIP_METADATA_EXTRACTION=YES`,
`CODE_SIGNING_ALLOWED=NO`. Two things the SDK requires of apps built this way
(2026-10-31, Samples/StreamSamples AVSync): SwiftUI's `@State` and other
macros need the SDK's macro plug-ins, which a Linux toolchain does not have,
so samples use UIKit; and the iOS 27 UIKit requires the scene life cycle
(an app without a scene delegate stops in UIKit at launch).

## 11. The device window the IDE embeds

The portable pieces are `YcodeRemoteViewer.RemoteDeviceSession` (the stream,
touches, keys, buttons, layout, measurements, sound; no toolkit) and
`YcodeRemoteViewerSDL.RemoteDeviceWindow` (an SDL 3 window drawing it).
Today the IDE runs the window as its own process (`ycode-sim-viewer --link`);
an OpenViews view that draws `RemoteDeviceSession`'s canvas (an NV12 or BGRX
texture) inside the workspace window is the follow-up (OpenViews has no
external-texture view yet).

## 12. The ssh fallback

Without the link, `scripts/ycode-sim-try` (unchanged; it now runs on Linux,
building or using the Linux viewer) boots a device through
`scripts/ycode-sim-serve` over ssh and forwards its display socket with
`ssh -L`; the viewer connects to the forward. The x86 → host ssh login is a
key the owner authorized for development; nothing in the link needs it, and
nothing needs the host to log in to the client.

## 13. Open items

- An OpenViews view for the device canvas (§11).
- Microphone input from the viewer to the guest (`audio-host.md` input
  streams): not done.
- Pacing the media channel's sends on slow links (today the kernel drops
  what the link cannot carry and the viewer asks for a keyframe).

## Evidence

| Claim | Level | Source |
|---|---|---|
| Noise handshake, HKDF, Split, Rekey, psk modifier | 1 | The Noise Protocol Framework, revision 34 (public domain), noiseprotocol.org |
| X25519, Ed25519, ChaCha20-Poly1305, SHA-256, HMAC, HKDF | 1 | swift-crypto 4.5.2 with swift-asn1 1.7.3 (both Apache-2.0; CryptoKit's API, BoringSSL on Linux), RFC 7748, RFC 8032, RFC 8439, RFC 5869 |
| Replay window | 1 | RFC 4303 §3.4.3 (the sliding-window scheme) |
| posix_spawn session and signal attributes | 1 | POSIX, glibc documentation (`POSIX_SPAWN_SETSID`, glibc 2.26) |
| Ports pass the host's firewall; pairing, control, display, media work end to end | 3 | REMOTE-X86 runs, x86 PC ↔ Thor, 2026-10-31 |
| Everything else (preamble, payload layouts, control ops, archive, media packets, CLI) | — | Ycode design decisions |

No Apple binary, Apple source or `research/` material was used.
