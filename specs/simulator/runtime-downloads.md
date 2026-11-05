# Spec: simulator runtime and Metal Toolchain downloads

Status: **accepted** (OBS-RUNTIME, 2026-10-31; owner decisions recorded 2026-11-04). It says where Apple
publishes simulator runtimes and the Metal Toolchain, what the catalogs look
like, how a runtime is chosen for an SDK and CPU, what the downloaded file
is, how Apple's tools install it, and what Ycode's own downloader must do on
a Linux arm64 host. Observations behind it: `research/notes/runtime-downloads.md`.
It uses the RuntimeRoot layout of `ipad.md` and `docs/SIMULATOR-LINUX.md`.
**Ycode decision** marks design choices; **Owner decision** marks open
questions that this spec does not settle.

**Licensing.** Runtimes and the Metal Toolchain are Apple software. Each
user fetches them from Apple, for themselves. Ycode never hosts, mirrors,
caches for others, or redistributes them, and its repository holds no
runtime file, key, hash list or image.

## 1. The two catalogs

| Layer | What it answers | Location | Auth |
|---|---|---|---|
| Downloadable index | Which runtimes exist; which fits an SDK; which Metal Toolchain fits an Xcode | `https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex` (HTTP GET, ETag, `max-age=600`) | none |
| MobileAsset query ("Pallas") | Where the bytes of one asset are, their size, hashes, decryption key | `https://gdmf.apple.com/v2/assets` (HTTPS POST, JSON) | none (no account); request describes the host |
| Payload CDN | The asset archive | `https://updates.cdn-apple.com/MobileAssets<year>/mobileassets/<part>/<UUID>/<relative path>.aar` | none |
| Legacy (pre-cryptex runtimes only) | Old `.dmg` runtimes | `https://download.developer.apple.com/...` (`source` key) | Apple developer sign-in (`authentication = virtual`) |

Ycode supports only the first three. Legacy entries are listed but marked
"needs Apple sign-in; not supported".

## 2. Downloadable index format

An XML property list (`plutil` reads it; any plist parser). Top level:

| Key | Type | Meaning |
|---|---|---|
| `version` | string | format version (`"1"`) |
| `refreshInterval` | integer | seconds between refreshes (86400) |
| `downloadables` | array of dict | runtime entries (§2.1) |
| `sdkToSimulatorMappings` | array of dict | SDK build → runtime builds (§2.2) |
| `sdkToSeedMappings` | array of dict | `buildUpdate`, `platform`, `seedNumber` (beta labels) |
| `otherDownloadables` | array of dict | Metal Toolchain, documentation (§2.3) |
| `xcodeToOtherDownloadablesMappings` | array of dict | Xcode build → component build (§2.3) |

### 2.1 Runtime entry (`downloadables[]`)

| Key | Type | Example / values |
|---|---|---|
| `identifier` | string | `com.apple.dmg.iPhoneSimulatorSDK27_0_b1` or a UUID string |
| `name` | string | `iOS 27.1 Simulator Runtime` |
| `category` | string | `simulator` |
| `platform` | string | `com.apple.platform.iphoneos` / `appletvos` / `watchos` / `xros` (device-platform ids, not simulator ids) |
| `version` | string | `27.1.0.0` (4-part; 4th part = beta number, 0 = release) |
| `simulatorVersion` | dict | `version` (`27.1`), `buildUpdate` (`24A94425`) |
| `architectures` | array, optional | `[arm64]` or `[arm64, x86_64]`; absent on old entries |
| `contentType` | string | `cryptexDiskImage` (current), `diskImage`, `package` (legacy) |
| `downloadMethod` | string, optional | `mobileAsset` (current); absent = use `source` |
| `source` | string, optional | legacy direct URL |
| `authentication` | string, optional | `virtual` (sign-in) / `none` |
| `fileSize` | integer | bytes (download size) |
| `hostRequirements` | dict, optional | `minXcodeVersion`, `maxXcodeVersion`, `minHostVersion`, `maxHostVersion`, `excludedHostArchitectures` |
| `isUserInitiated` | bool, optional | |
| `dictionaryVersion` | integer | `2` |

iPadOS has no entries of its own: iPad device types run on the iOS
runtime (`supportedProductFamilyIDs` 1 and 2, see §5). Several entries can
share a `version` with different builds (e.g. two 27.2 iOS builds); the
build is the key.

### 2.2 SDK → runtime mapping (`sdkToSimulatorMappings[]`)

| Key | Meaning |
|---|---|
| `sdkIdentifier` | e.g. `iphoneos27.1` |
| `sdkBuildUpdate` | SDK build, e.g. `24A94403` |
| `simulatorBuildUpdate` | a runtime build that works with it |
| `affinity` | `preferred` / `available` / `unavailable` / absent (= available) |
| `groupTag` | grouping label, e.g. `iphoneos-simgroup-sdk-24A94403`, or `none` |

### 2.3 Components (`otherDownloadables[]`, `xcodeToOtherDownloadablesMappings[]`)

Component entry: `assetType` (`metalToolchain`, `developerDocumentation`),
`identifier` (`com.apple.Xcode.metalToolchain_27_0`), `name`,
`description`, `assetBuildUpdate` (`27A266a`), `contentType`
(`cryptexDiskImage` / `directory`), `downloadMethod` (`mobileAsset`),
`fileSizeBytes`, `authentication` (optional), `dictionaryVersion` (2 or 3).
Mapping row: `assetType`, `assetBuildUpdate`, `xcodeBuildUpdate` (or
`xcodeVersion` for documentation), `affinity`. Xcode 27.1 (27A9269) maps to
Metal Toolchain 27A266a.

## 3. Selection rule

Input: platform, wanted OS version or build (optional), CPU architecture,
SDK build (Ycode's chosen SDK, optional), host facts.

1. Candidates = `downloadables` with the platform, `category = simulator`,
   `downloadMethod = mobileAsset`.
2. If a build was asked for, take the entry with that
   `simulatorVersion.buildUpdate`. If a version was asked for, take entries
   with that `simulatorVersion.version`.
3. Else, with an SDK build: rows of `sdkToSimulatorMappings` for that
   `sdkBuildUpdate`; prefer `affinity = preferred`, then `available`;
   never `unavailable`. Without an SDK: the highest release version
   (4th `version` part 0) of the platform.
4. Drop entries whose `architectures` lacks the wanted arch (absent means
   the legacy universal/x86 kind; skip for arm64 hosts). Apple's
   `-architectureVariant arm64` prefers arm64-only entries; `universal`
   prefers `[arm64, x86_64]`. **Ycode decision:** always arm64-only.
5. Drop entries whose `hostRequirements` exclude the host. For Ycode,
   `min/maxXcodeVersion` is compared against the Xcode version Ycode
   declares parity with (27.1); `min/maxHostVersion` (macOS versions) is
   ignored on Linux.
6. Ties: highest build.

**Default (owner decision, 2026-11-04):** with no build, no version and no
SDK given, Ycode chooses the **newest release** of the platform: the
highest `simulatorVersion.version` among entries whose 4th `version` part
is 0, after steps 4 and 5, ties by step 6. Betas (4th part ≠ 0) are chosen
only when the user names their build or version. `ycode runtime available`
lists the candidates newest first, so the default is its first release row.

Observed: with SDK `iphoneos27.1` build 24A94403, Apple preferred runtime
24A434 (27.0) and also offered 24A94401 (27.1); `xcrun simctl runtime match
list -j` reports per SDK `sdkBuild`, `defaultBuild`, `chosenRuntimeBuild`.

## 4. MobileAsset query and payload

### 4.1 Query (`POST https://gdmf.apple.com/v2/assets`)

JSON body, keys as Apple's client sends them:

| Key | Value for a runtime query |
|---|---|
| `AssetType` | `com.apple.MobileAsset.iOSSimulatorRuntime`; also `watchOSSimulatorRuntime`, `appleTVOSSimulatorRuntime`, `xrOSSimulatorRuntime`; `com.apple.MobileAsset.MetalToolchain` |
| `AssetAudience` | the public "macOS Mobile Asset Customer" audience UUID `02d8e57e-dd1c-4090-aa50-b4ed2aef0062` |
| `RequestedBuild` | runtime build from §3 |
| `ClientVersion` | `2` |
| `ClientData` | `{ AllowXmlFallback: "false", DeviceAccessClient: <client id> }` |
| host description | `ProductName`, `ProductType`, `ProductVersion`, `BuildVersion`, `HWModelStr`, `HardwarePlatform`, `DeviceClass`, `DeviceName`, memory size, `CertIssuanceDay`, nonce/session UUIDs, and the same under `DeviceOSData` |

Response: a signed document (the client verifies the signature) whose body
has `AssetSetId`, `PostingDate`, `Nonce`, and `Assets` (array; one entry for
a `RequestedBuild` query). Apple caches it as
`/System/Library/AssetsV2/<AssetType with dots as _>/<same>.xml` (a plist
with `Assets`, `AssetType`, `DownloadedFromLive`, `postedDate`,
`lastTimeChecked`), which is a readable example of the asset record.

**Owner decision (O1, 2026-11-04):** Ycode sends an honest description of
the machine it runs on: on a Mac, that Mac's own values; on Linux, its real
OS, architecture and Ycode's client name, with no Mac model fields. It never
presents itself as a Mac it is not. If the server refuses the query, Ycode
says so and offers route A or C (§6.1) instead.

### 4.2 Asset record

| Key | Meaning |
|---|---|
| `Build`, `SimulatorVersion`, `Architectures`, `TrainName` | identity (runtime) |
| `AssetFormat`, `_CompressionAlgorithm` | `AppleArchive` |
| `_DownloadSize` / `_UnarchivedSize` | bytes of `.aar` / of the extracted tree |
| `_Measurement` / `_Measurement-SHA256` | SHA-1 / SHA-256 of the downloaded `.aar` (raw bytes, base64 in JSON) |
| `_MeasurementAlgorithm` | `SHA-1` |
| `ArchiveID` | archive identifier (base64) |
| `ArchiveDecryptionKey` | present: the `.aar` is an *encrypted* Apple Archive; the key is in the reply |
| `__BaseURL` + `__RelativePath` | download URL |
| `__CanUseLocalCacheServer` | Apple's client tries a LAN Content Caching server first |

### 4.3 Download and verify

1. GET `__BaseURL` + `__RelativePath` (resumable with HTTP ranges; ~7.9 GB
   for iOS 27.1; 0.84 GB for the Metal Toolchain).
2. Check length = `_DownloadSize` and SHA-256 = `_Measurement-SHA256`.
3. Decrypt and extract the Apple Archive to a directory with the layout of
   §5.1, with the key that Apple's server returns to this user in the asset
   record. **Owner decision (O2, 2026-11-04):** Ycode does this itself, as
   Apple's own client does. On macOS it uses the system's public Apple Archive
   API. On Linux it uses an open-source Apple Encrypted Archive
   implementation under a license compatible with Ycode's (MIT), linked or run
   as a separate program. This spec does not describe the encryption.

**The downloaded file (outer container).** The file starts with the magic
`AEA1`, then the profile number in 3 little-endian bytes (observed: 1,
symmetric key, no signature), a 1-byte scrypt strength (0) and a 4-byte
auth-data size (observed: 0, no auth data). The layout of the rest is
python-aea's `FORMAT.md` (MIT) and is not repeated here. The file is
padded: the Metal Toolchain 27A266a download was exactly 800 MiB
(838,860,800 bytes, equal to `_DownloadSize`) and held 832,819,155 bytes of
plaintext. Decryption yields the **asset archive** of §5.0, not a plain
Apple Archive of files: a generic Apple Archive extractor that is given
the plaintext extracts nothing (Apple's own `aa extract` reports four
entries and no files), so Ycode must handle §5.0's parts itself.

## 5. What the payload contains

### 5.0 The asset archive (decrypted plaintext)

Observed on the Metal Toolchain 27A266a asset (`AssetFormat =
AppleArchive`, `_CompressionAlgorithm = AppleArchive`). Runtime assets
carry the same two values; that their part layout matches is expected but
**to confirm** on a runtime asset.

**Apple Archive records.** The plaintext is a sequence of Apple Archive
entries. Each entry is a header, then the payloads of the header's blob
fields, in the order the fields appear. A header is: the magic `AA01`, a
little-endian `uint16` giving the whole header's length (magic and length
included), then fields until that length. A field is a 3-letter key, a
1-letter subtype, then the value:

| Subtype | Value | Seen with |
|---|---|---|
| `1`, `2`, `4`, `8` | unsigned integer, little-endian, of that many bytes (writers pick the smallest that fits) | `TYP`, `YOP`, `UID`, `GID`, `MOD`, `SIZ`, `IDX`, `IDZ` |
| `P` | string: `uint16` LE length, then that many bytes (UTF-8, no terminator) | `PAT`, `LBL` |
| `A`, `B`, `C` | blob: its size as `uint16`, `uint32` or `uint64` LE; the bytes follow the header | `DAT`, `YEC` |
| `H` | 32-byte hash (SHA-256) | `SH2` |

A reader that meets any other subtype stops with an error (the format has
more, e.g. times and other hash sizes, none of which occur here).

Keys (meanings from Apple's public `AppleArchive/AADefs.h` and the `aa`
tool's help, except `YOP` and `LBL`, which neither documents):

| Key | Meaning |
|---|---|
| `TYP` | entry type, as an ASCII code: `M` (77) metadata, `F` (70) regular file (the header also defines `D` directory, `L` symbolic link and others) |
| `PAT` | path, relative to the asset folder |
| `DAT` | the file's data (or, in a metadata entry, a part's payload) |
| `SIZ` | data size |
| `UID`, `GID` | owner and group (0 and 0 here) |
| `MOD` | mode. Observed values carry the file-type bits too (`0o100644`, `0o100444`) although the header documents only the low 12 bits; apply `MOD & 0o7777` |
| `SH2` | SHA-256 of the file's data |
| `IDX`, `IDZ` | offset and size of an entry (see the manifest, below) |
| `YEC` | "file data error correcting codes" (`aa` help); its blob starts with `BXECC010` and the data size. Ycode does not need it and skips it |
| `YOP` | **part operation**: `M` manifest, `E` extract, `O` fix-up. Apple's `aa list` prints these as `manifest`, `extract`, `dst-fixup` |
| `LBL` | part label (`main` for every part here) |

**Top level: four metadata entries (parts).**

| # | Entry | Payload |
|---|---|---|
| 1 | `TYP=M`, `YOP=M`, `DAT` (139 bytes) | The **manifest**: itself an Apple Archive stream of one header per later part, each `TYP=M`, `YOP`, `LBL`, `SIZ` (that part's payload size), `IDX` (offset of that part's entry, counted from the **end of the manifest entry**) and `IDZ` (that part's entry size: header plus payload). No blob data. |
| 2 | `TYP=M`, `YOP=E`, `LBL=main`, `DAT` (832,812,196 bytes) | An **extract** part: a pbzx stream (below) that decompresses to Apple Archive file entries, each `TYP=F`, `PAT`, `DAT`, `YEC`. Here one entry, the disk image `AssetData/Restore/<part-no>.dmg` (907,281,108 bytes). |
| 3 | `TYP=M`, `YOP=E`, `LBL=main`, `DAT` (6,136 bytes) | A second **extract** part, the same form: the small files (`BuildManifest.plist`, the three `Firmware/<dmg>.*` files and `Restore.plist` under `AssetData/Restore/`, and top-level `Info.plist` and `version.plist`). |
| 4 | `TYP=M`, `YOP=O`, `LBL=main`, `DAT` (564 bytes) | The **fix-up** part: pbzx, decompressing to one header per file already extracted, `TYP=F`, `PAT`, `UID`, `GID`, `MOD`, `SH2`, with no data. |

The manifest's offsets check out exactly against the parts that follow
(entry 2 at offset 0 after the manifest, entry 3 after entry 2, entry 4
after entry 3), and the four entries end exactly at the end of the
plaintext. Paths never start with `/` and contain no `..`. **Ycode
decision:** reject an archive whose paths do, or whose manifest offsets do
not match its parts.

**pbzx.** An extract or fix-up part's payload is a pbzx stream: the magic
`pbzx`, a big-endian `uint64` chunk size (`0x400000`, 4 MiB), then chunk
records until the payload ends. A record is a big-endian `uint64`
uncompressed size, a big-endian `uint64` stored size, and the stored
bytes. If the stored bytes begin with the XZ magic (`FD 37 7A 58 5A 00`)
they are one complete XZ stream that decompresses to exactly the
uncompressed size; otherwise the stored size equals the uncompressed size
and the bytes are the data as is. Every chunk but the last decompresses to
the chunk size. The decompressed chunks, concatenated, are the Apple
Archive stream; entries and file data run across chunk boundaries freely.
Observed in part 2: 217 chunks, 163 stored as is (the disk image is already
compressed) and 54 XZ.

**Applying the parts (what a correct extraction does).** Read the manifest;
then, in order, for each extract part write every `F` entry's `DAT` to
`<asset folder>/<PAT>` (creating parent folders); then for the fix-up part
set each listed file's mode (`MOD & 0o7777`; owner only where permitted) and
check its SHA-256 against `SH2`, failing on any mismatch or on a fix-up
entry for a file not extracted. In the observed asset every file's SHA-256
matched, and the files form the §5.1 tree.

**Sizes.** `_UnarchivedSize` is the sum of the file sizes each rounded up to
4,096 bytes (907,333,632 for 27A266a, whose files total 907,310,951 bytes);
use it for the free-space check, plus the archive itself while both
exist.

### 5.1 Extracted asset ("exported bundle")

Both the installed asset (`…/<40-hex>.asset/AssetData/`) and the output of
`xcodebuild -downloadPlatform <P> -exportPath <dir>`
(`<dir>/<sdkplatform>_<version>_<build>.exportedBundle/`, e.g.
`iphonesimulator_27.1_24A94425.exportedBundle`) have this tree:

```
ExportedMetadata.plist        (export; asset dir has Info.plist + version.plist)
Restore/
  <part-no>.dmg               the runtime disk image
  Restore.plist               ProductVersion, ProductBuildVersion, SupportedProductTypes [iSim1,1]
  BuildManifest.plist         one build identity, Info.Variant e.g. "Arm64Only Customer Simulator Runtime"
  Firmware/<dmg>.trustcache   IMG4 payload
  Firmware/<dmg>.root_hash    IMG4 payload
  Firmware/<dmg>.cryptex_info plist: CFBundleIdentifier (com.apple.iPhoneOS.SimulatorRuntime), CFBundleVersion (24.1.94425.0)
```

`ExportedMetadata.plist` → `MobileAssetProperties` = {`Architectures`,
`Build`, `SimulatorVersion`}. Metal Toolchain exports are named
`MetalToolchain-<build>.exportedBundle/` with `ExportMetadata.plist`
(`assetId`, `assetType`, `buildUpdateVersion`, `downloadSizeBytes`,
`unarchivedSizeBytes`, `isInternal`) and the same `Restore/` tree.

### 5.2 The disk image

UDIF, read-only, lzfse-compressed blocks ("ULFO"), GPT with one `Apple_APFS`
partition; for iOS 27.1 about 7.9 GB compressed, 18 GB raw. The DMG has an
embedded code signature (Apple-signed, no team). Inside the APFS volume:

```
Library/Developer/CoreSimulator/Profiles/Runtimes/<Name> <ver>.simruntime/
  Contents/Info.plist          CFBundleIdentifier = com.apple.CoreSimulator.SimRuntime.<OS>-<maj>-<min>
  Contents/MacOS/, _CodeSignature/
  Contents/Resources/profile.plist
  Contents/Resources/RuntimeRoot/   Applications Developer Library RestoreVersion.plist System bin etc private sbin usr
  Contents/Resources/{SampleContent, update_dyld_sim_shared_cache, dylib-order.txt, dirty-data-segments-order.txt, en.lproj}
```

`profile.plist` keys Ycode reads: `platformIdentifier`
(`com.apple.platform.iphonesimulator`), `defaultVersionString`,
`supportedArchs`, `supportedProductFamilyIDs` (1 iPhone, 2 iPad, 3 TV, 4
Watch, 7 Vision), `restrictedToDeviceTypes` (optional list of device-type
ids: when present only those device types may use the runtime),
`minHostVersion`, `supportedFeatures`,
`supportedFeaturesConditionalOnDeviceType`, `pairingRequirements`.
`RuntimeRoot/System/Library/CoreServices/SystemVersion.plist` gives
`ProductName`, `ProductVersion`, `ProductBuildVersion`.

### 5.3 How Apple's tools register it (macOS, for reference)

The asset goes to `/System/Library/AssetsV2/com_apple_MobileAsset_<Type>/<hash>.asset/`;
the DMG is attached as a cryptex (mounted under
`/private/var/run/com.apple.security.cryptexd/mnt/…` or
`/Library/Developer/CoreSimulator/Volumes/<OS>_<build>/`). `xcrun simctl
runtime list -j` then shows, per runtime UUID: `build`, `version`,
`runtimeIdentifier`, `platformIdentifier`, `kind` ("Patchable Cryptex Disk
Image"), `state` ("Ready"), `signatureState` ("Verified"/"Unknown"),
`sizeBytes`, `supportedArchitectures`, `path` (asset dir or DMG),
`mountPath`, `runtimeBundlePath`, `deletable`, `lastUsedAt`. Note:
`-downloadPlatform … -exportPath` installs **and** exports; `-importPlatform
<dmg>` / `simctl runtime add` import a DMG. Ycode does not emulate this
registry on Linux; it keeps its own (§6.3).

## 6. What Ycode does

### 6.1 Routes

- **Route A (always available): import an exported bundle.** The user runs
  `xcodebuild -downloadPlatform iOS -exportPath <dir>` on their own Mac and
  copies the `.exportedBundle` (or just its DMG) to the Linux host;
  `ycode runtime import <path>` does §6.2 from step 3.
- **Route B: direct download** (owner decision, 2026-11-04; offered as an
  explicit choice, never automatic). `ycode runtime download
  <platform> [--build B | --version V]` does §6.2 from step 1.

- **Route C (a Mac with Xcode): Apple's own tool.** With the user's
  confirmation, Ycode runs `xcodebuild -downloadPlatform <platform>`
  (optionally `-exportPath` for a copy to a Linux host) and shows its
  progress; Apple's tool does the download. Offered first on a Mac.

### 6.2 Steps

1. Fetch the index (§1), honour ETag and `refreshInterval`; cache under
   `$YCODE_DATA/runtimes/.index/`.
2. Select (§3); query (§4.1); download and verify (§4.3) into
   `$YCODE_DATA/runtimes/.partial/` with resume.
3. Validate the bundle: `ExportedMetadata.plist` (or `Restore.plist`) build
   and version equal the selected ones; `Restore/*.dmg` exists.
4. Read the DMG: UDIF parser (koly trailer, block map, lzfse/zlib/raw
   chunks) → raw GPT image → `Apple_APFS` partition → read-only APFS reader.
   **Ycode decision:** use or write an APFS reader under a license
   compatible with Ycode (MIT); if only a GPL tool exists, run it as a
   separate program, never link it.
5. Copy `…/<Name>.simruntime/Contents/Resources/RuntimeRoot` to
   `$YCODE_DATA/runtimes/<OS>-<version>-<build>/RuntimeRoot` (the layout
   `ipad.md` already uses, e.g. `iOS-27.1-24A94425`), keeping modes,
   symlinks, hard links and extended attributes the simulator needs. Copy
   `profile.plist` and the runtime `Info.plist` beside it, under
   `$YCODE_DATA/runtimes/<OS>-<version>-<build>/` as `profile.plist` and
   `runtime-Info.plist`.
6. Write `$YCODE_DATA/runtimes/<OS>-<version>-<build>/ycode-runtime.json`:
   platform, version, build, arch, runtime identifier, source (index entry
   identifier, URL host, SHA-256 checked, or "imported"), date. This is
   Ycode's registry; `ycode runtime list [--json]` reads these files.
7. Delete the `.aar`, DMG and partial files unless `--keep` is given.

### 6.3 Metal Toolchain

Ycode lists the matching Metal Toolchain (§2.3) for information only. The
toolchain is macOS executables (`Metal.xctoolchain/usr/bin/air-*`, `metal*`)
and does not run on Linux; Ycode's shader path is in `metal-shaders.md`.
If a later round needs files from it (e.g. headers), it is fetched like a
runtime (asset type `com.apple.MobileAsset.MetalToolchain`) and only the
needed files are extracted.

### 6.4 Must not

- Ship, cache for others, or mirror Apple runtimes, keys or index copies.
- Use legacy signed-in downloads, or automate Apple ID sign-in.
- Pretend to be a specific Mac in the gdmf query.

## Evidence

| Claim | Level | Source |
|---|---|---|
| Index URL, no auth, headers, plist keys and values (§1, §2) | 2 | fetched the public index, read as a plist; `xcodebuild` conditional GET (304) seen in its unified log |
| Index URL is the one open-source tools use | 1 (not re-checked) | `xcodes` (MIT) is known to read this URL; its source was not opened in this round |
| Selection inputs, affinities, `match list` output (§3) | 2, 3 | index mappings; `xcrun simctl runtime match list -j` |
| arm64 variant preference, "No needed downloadables" behaviour | 3 | `xcodebuild -downloadPlatform iOS -exportPath -architectureVariant arm64` runs |
| gdmf URL, request keys, audience, response shape, signature check (§4.1) | 3 | `mobileassetd` unified log during one download (passive; no interception) |
| Asset record keys, CDN URL form (§4.2) | 2, 3 | cached `/System/Library/AssetsV2/*/*.xml` read as data; daemon log |
| Download size/time, install + export side effects (§4.3, §5.3) | 3 | one download of iOS 27.1 24A94425; `simctl runtime list -j` before/after |
| Exported bundle layout and plists (§5.1) | 2 | exported bundles read as files |
| DMG format, signature, APFS partition (§5.2) | 2 | `diskutil image info`, `codesign -dv` |
| simruntime / RuntimeRoot / profile.plist layout (§5.2) | 2 | mounted runtime volumes listed and plists read |
| Metal Toolchain mapping, export layout, contents (§2.3, §6.3) | 2, 3 | index; `xcodebuild -downloadComponent MetalToolchain -exportPath`; `-showComponent -json` |
| Xcode preference keys (§7.1) | 2 | `defaults read com.apple.dt.Xcode` (key names only) |
| Xcode loads assets via UAF locks; small_v3 in use (§7.3) | 3 | unified log of Xcode |

| Default selection: newest release when nothing is given (§3) | — | owner decision, 2026-11-04 |
| Outer container header: magic, profile 1, no auth data, padding (§4.3) | 2, 1 | the downloaded Metal Toolchain 27A266a file read as bytes; python-aea `FORMAT.md` (MIT) for the field order; `aea` help for the profile names |
| Plaintext is Apple Archive records; header, field and subtype encoding (§5.0) | 2 | the decrypted 27A266a asset read as bytes (B2-OBS-RUNTIME, 2026-11-04) |
| Key meanings `TYP`, `PAT`, `DAT`, `SIZ`, `UID`, `GID`, `MOD`, `SH2`, `IDX`, `IDZ`, `YEC` (§5.0) | 1 | macOS SDK `AppleArchive/AADefs.h`; `aa` help ("Archive fields") |
| `YOP` values manifest / extract / dst-fixup; `aa extract` extracts no files (§5.0, §4.3) | 3 | `aa list -v` and `aa extract -v` on the decrypted asset |
| Four parts, manifest offsets, pbzx records, chunk counts, fix-up fields, `MOD` with type bits, SHA-256 matches, `_UnarchivedSize` rounding (§5.0) | 2 | the decrypted asset read as bytes; each part decompressed with Python's standard `lzma`; every file's SHA-256 computed and compared with `SH2` |
| pbzx as a known format (§5.0) | 1 | the open-source `pbzx` tool (GPL-3.0: cited as a reference only, never linked or copied); XZ per its public file-format specification |

Method for §4.3's outer header and §5.0 (2026-11-04): the Metal Toolchain
27A266a asset was fetched by the steps of §4 (an honest query describing
this Mac, the download, size and SHA-256 checked), decrypted with macOS's
`aea` tool and the key in the answer, and studied as a file in the
git-ignored dirty folder. Nothing was installed; the download, the
plaintext and the key were deleted afterwards. This replaces the
understanding a clean-room implementer had gained by reading decrypted
asset data directly on 2026-11-04 (a protocol deviation, recorded in
`research/notes/obs-runtime-onboarding-2026-11-04.md` §8).

No disassembly or decompilation was used. §7 of the original observation
(a model asset) is held back from this spec.
