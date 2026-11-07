# Spec: LZBITMAP streams and decmpfs-compressed files

Dirty-room specification (agent B3-LZOBS, 2026-11-07) for
`boot-profile.md` §18.3: every boot, the mobile-asset extractor
(`STExtractionService`, through AppleArchive) writes files compressed by the
file system with decmpfs type 13 or 14 (LZBITMAP), and Ycode's volume can
neither store them nor read them back. This spec gives the clean side what
it needs to write a decompressor (and, if wanted, a compressor) and the file
system side. It contains no Apple code; byte examples are of our own test
inputs.

Summary for the implementer:

- LZBITMAP is a chunked format: the magic `ZBM` + 0x09, chunks of at most
  32 768 output bytes, and an empty end chunk (§2). A compressed chunk
  splits the output into groups of 8 bytes; each group has an 8-bit bitmap
  (bit set: next literal byte; bit clear: copy the byte `period` bytes
  back). Bitmaps are chosen by 4-bit selectors, with a 12-entry bitmap table
  at the chunk's end and run-length repeats. There is no checksum.
- An MIT-licensed open-source decoder *and* encoder exist (libzbitmap,
  Corellium; §6). The format below agrees with it and with over 3 900
  black-box round trips through macOS's own `libcompression` (§2.12).
- decmpfs: a 16-byte header in the `com.apple.decmpfs` attribute (`fpmc`,
  type, uncompressed size). Type 13 keeps the payload in the attribute
  (≤ 3 802 bytes, ≤ 64 KiB of data); type 14 keeps an offset table and
  64 KiB blocks in the `com.apple.ResourceFork` attribute (§3).
- The file system must accept the writer's calls (§4.2), return the
  decompressed bytes on read, and hide the two attributes while
  UF_COMPRESSED is set. On macOS the extractor **does** have a fallback:
  it writes plain files when the volume's capabilities lack
  `VOL_CAP_FMT_DECMPFS_COMPRESSION` (§4.1). Whether the iOS simulator's
  extractor asks the same question of Ycode, and why it compressed although
  Ycode does not report that bit, is open (§5).

## 1. Names used here

| Term | Meaning |
|---|---|
| stream | One LZBITMAP buffer as produced by `compression_encode_buffer(…, COMPRESSION_LZBITMAP)` |
| chunk | A unit of the stream with its own 6-byte header (§2.2) |
| group | 8 consecutive output bytes of a compressed chunk (the last group of a chunk may be shorter) |
| period | The copy distance, in bytes, for bitmap bits that are 0 |
| selector | A 4-bit value naming the bitmap of the next group(s) |
| u24 | A 3-byte unsigned integer, little-endian |
| block | One 64 KiB unit of a decmpfs file (§3) |

Bits of a byte are numbered from the least significant (bit *i* has value
2^*i*). Nibbles of a byte are taken low nibble first, then high nibble.

## 2. The LZBITMAP stream

### 2.1 Public API facts

- `COMPRESSION_LZBITMAP` = 0x702 (`compression.h`; "buffer API only,
  available starting macOS 12.0, iOS 15.0"). AppleArchive uses the same
  number (`AA_COMPRESSION_ALGORITHM_LZBITMAP`).
- `compression_stream_init` refuses LZBITMAP for both encode and decode
  (status −1). Only `compression_encode_buffer` /
  `compression_decode_buffer` work.
- `compression_decode_buffer` with a destination smaller than the output
  fills the destination and returns its size (a prefix); with a larger one it
  returns the output length. It returns 0 for a stream it rejects.

### 2.2 Stream layout

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic: `5A 42 4D 09` (`ZBM` + 0x09) |
| 4 | … | chunks, back to back |
| … | 6 | end chunk: total length 6, output length 0 (`06 00 00 00 00 00`) |

Every chunk starts with:

| Offset in chunk | Size | Field |
|---|---|---|
| 0 | u24 | `chunk_len`: the chunk's total size in bytes, this header included |
| 3 | u24 | `out_len`: the bytes the chunk produces (0 ≤ `out_len` ≤ 32 768) |

Chunk kinds:

- **End chunk**: `out_len` = 0, `chunk_len` = 6. It ends the stream; bytes
  after it are ignored. A stream without it is rejected.
- **Stored chunk**: `chunk_len` = `out_len` + 6. The `out_len` bytes after
  the header are the output, as they are.
- **Compressed chunk**: any other `chunk_len` (at least 32). Layout in §2.3.

The kind is decided only by these equalities; there is no flag. An encoder
must therefore never write a compressed chunk whose size is exactly
`out_len` + 6 (store the bytes instead; Apple's encoder stores a chunk
whenever compression does not make it smaller).

Apple's encoder splits the input into chunks of exactly 32 768 output bytes
(the last one shorter), and stores whole inputs of 144 bytes or fewer
without trying to compress them (for zeros, `ab` repeated and repeated text,
every input of 145 to 399 bytes was compressed, every shorter one stored).

### 2.3 Compressed chunk layout

| Offset in chunk | Size | Field / area |
|---|---|---|
| 0 | 6 | header (§2.2) |
| 6 | u24 | `period_off`: start of the period area |
| 9 | u24 | `bitmap_off`: start of the bitmap area |
| 12 | u24 | `selector_off`: start of the selector area |
| 15 | `period_off` − 15 | **literal area**: the bytes that bitmap bits set to 1 take, in output order |
| `period_off` | `bitmap_off` − `period_off` | **period area**: new periods, 1 or 2 bytes each, little-endian |
| `bitmap_off` | `selector_off` − `bitmap_off` | **bitmap area**: one byte per group that uses selector 0, 1 or 2 |
| `selector_off` | up to `chunk_len` − 17 | **selector area**: nibbles (§2.5) |
| `chunk_len` − 17 | 17 | **bitmap table**: 12 entries of 10 bits (§2.4) |

All offsets are relative to the chunk's first byte. In every chunk Apple's
encoder wrote, the areas are in this order, adjacent, and consumed exactly
by the decoding procedure (the literal area ends at `period_off`, the period
area at `bitmap_off`, the bitmap area at `selector_off`), except the selector
area: 0 to 4 nibbles after the last one used are padding with arbitrary
values (we saw 0, 3 and 15 there). A decoder stops by output count, never by
reaching the end of the selector area.

### 2.4 The bitmap table

Read the last 17 bytes of the chunk as one 136-bit little-endian number.
Entry *k* (0 ≤ *k* < 12) is bits 10*k* to 10*k* + 9:

| Bits of the entry | Meaning |
|---|---|
| 0–7 | the bitmap |
| 8–9 | `period_bytes`: 0, 1 or 2 (3 is invalid) |

Bits 120–135 (the last 16 bits) were 0 in all 943 compressed chunks we
checked for it. Apple's encoder puts the bitmaps it uses most often here.

### 2.5 Selectors and repeats

Each group is described by one selector (a nibble of the selector area):

| Selector | Bitmap of the group | `period_bytes` |
|---|---|---|
| 0, 1, 2 | the next byte of the bitmap area | equal to the selector |
| 3 … 14 | bitmap table entry (selector − 3) | from that entry |
| 15 | never a selector: it starts a repeat count (below) | — |

**Repeats.** After reading a selector, if more than 8 bytes of the chunk's
output are still to be produced, look at the next nibble. If it is not 15,
it is the next selector (do not consume it here) and the repeat count is 1.
If it is 15, consume it; the count starts at 4; then read nibbles, adding
each to the count, until one that is not 15 has been read and added. So
count − 4 = 15·*k* + *r* is written as *k* nibbles of 15 followed by *r*
(0 ≤ *r* ≤ 14), all after the introducing 15. Examples: `F 0` = 4,
`F 2` = 6, `F F 3` = 22. When 8 or fewer output bytes remain, no repeat
count is looked for. (A decoder that always looks also decoded all 400
streams we tried with it; the rule above is the one in libzbitmap.)

Counts 2 and 3 cannot be written; an encoder writes the selector two or three
times. The largest count we saw was 4 096 (a chunk of 32 768 zero bytes).

The group is applied *count* times. Each application is complete: a
selector 0–2 takes a new bitmap byte from the bitmap area every time, and a
bitmap with `period_bytes` > 0 reads a new period every time.

**Overshoot.** A repeat count may describe more groups than the chunk needs
(we saw up to 7 extra groups in Apple's output, e.g. 200 bytes of one
value encoded as 32 groups). The chunk ends as soon as `out_len` bytes are
produced; the rest of the count is ignored.

### 2.6 Applying a group

1. If the group's `period_bytes` is 1 or 2, read that many bytes from the
   period area as a little-endian number; it becomes the current period. A
   period of 0 is an error. The current period starts at **8** at the start
   of every compressed chunk and otherwise carries over from group to group.
2. For *i* = 0 … 7, while the chunk has produced fewer than `out_len` bytes:
   if bit *i* of the bitmap is 1, output the next byte of the literal area;
   if it is 0, output a copy of the byte that is `period` bytes before the
   current output position.

Copies are byte by byte, so a period smaller than 8 (or smaller than the
bytes already produced in the group) repeats freshly written bytes. The
copy source may lie in an **earlier chunk of the same stream**: Apple's
encoder uses periods up to 65 535 (the largest a 2-byte field holds; we saw
65 535) and the second chunk of 64 KiB of zeros has no literals at all.
A copy from before the start of the stream's output is an error.

### 2.7 Decoding procedure

1. Check the magic (§2.8 for its fourth byte).
2. Repeat: read a chunk header; reject it if `chunk_len` < 6, if the chunk
   runs past the input, or if `out_len` > 32 768. If `out_len` = 0, it
   must be the end chunk (`chunk_len` = 6): stop. If `chunk_len` =
   `out_len` + 6, copy the stored bytes. Otherwise decode a compressed
   chunk:
   1. Reject the chunk if it is shorter than 32 bytes or any of the three
      area offsets is not inside it.
   2. Read the 12 table entries; reject an entry with `period_bytes` = 3.
   3. Set period = 8 and read selectors (§2.5) and apply groups (§2.6)
      until the chunk has produced `out_len` bytes. Every read from an area
      is bounds-checked against the chunk's end.
3. The output is the concatenation of all chunks' output. Earlier output
   must stay addressable for copies (up to 65 535 bytes back).

For decmpfs, the expected output size is known (§3), so a decoder can also
stop with an error when the output would exceed it.

### 2.8 The fourth magic byte

Apple's encoder always writes 0x09. Apple's decoder also accepts other
values; we probed it with hand-made streams:

| Fourth byte | Stored chunks accepted up to | Apple-encoded compressed chunks |
|---|---|---|
| 0x08 | 16 384 bytes | decode as with 0x09 (60 of 60 single-chunk streams ≤ 16 384 bytes) |
| 0x09 | 32 768 bytes | decode (the format above) |
| 0x0C | 16 384 bytes | do not decode (0 of 60): compressed chunks are coded differently |
| 0x0D | 32 768 bytes | do not decode (0 of 60) |
| any other, or lower-case `zbm` | rejected | rejected |

The macOS file system also read back a type-13 file whose payload began
with `ZBM` + 0x08. The coding of compressed chunks under 0x0C and 0x0D is
unknown (§5). A Ycode decoder that accepts 0x08 and 0x09 and refuses the
others (the read fails, §4.3) covers everything Apple's public encoder
produces.

### 2.9 What Apple's decoder accepts (hand-made streams)

| Stream | Result |
|---|---|
| stored 100 bytes + stored 51 bytes + end | the 151 bytes (chunks need not be 32 768 long) |
| magic + end only | empty output, accepted |
| stored 100 bytes, no end chunk | rejected |
| Apple-encoded stream without its end chunk | rejected |
| … + end + 5 junk bytes; … + end + another stored chunk | accepted; bytes after the end chunk ignored |
| stored chunk of 32 768 / 32 769 bytes | accepted / rejected |
| end chunk with `chunk_len` 7 | rejected |
| `chunk_len` smaller than its stored data | rejected |
| libzbitmap's encoder output (300 mixed inputs, 0–200 000 bytes) | 300 of 300 decoded correctly |

So **a valid encoder may write stored chunks only** (magic, chunks of at
most 32 768 bytes with header `out_len` + 6, end chunk); Apple's decoder
and the macOS file system read that back.

### 2.10 Worked example

Input (222 bytes, ours): `Ycode LZBITMAP! ` ×4, `Ycode lzbitmap? ` ×4,
64 zero bytes, `0123456789` ×3. Apple's encoder output (134 bytes):

```
0000  5a 42 4d 09 7c 00 00 de 00 00 5e 00 00 5f 00 00
0010  5f 00 00 59 63 6f 64 65 20 4c 5a 42 49 54 4d 41
0020  50 21 20 59 63 6f 64 65 20 4c 5a 6c 7a 62 69 74
0030  6d 61 70 3f 00 00 00 00 00 00 00 00 00 00 00 00
0040  00 00 00 00 30 31 32 33 34 35 36 37 38 39 30 31
0050  32 33 34 35 36 37 38 39 30 31 32 33 34 35 36 37
0060  38 39 10 77 87 f3 60 35 2f 77 f3 72 77 34 0f 00
0070  fc f0 07 30 ff 00 04 00 00 00 00 00 00 00 00 00
0080  06 00 00 00 00 00
```

- 0x00: magic. 0x04: chunk header, `chunk_len` 0x7C = 124, `out_len`
  0xDE = 222. Offsets: period area at 0x5E = 94, bitmap area at 0x5F = 95,
  selector area at 0x5F = 95 (the bitmap area is empty). Chunk offsets are
  stream offset − 4.
- Literal area (chunk 15–93, stream 0x13–0x61): `Ycode LZBITMAP! Ycode LZ`,
  `lzbitmap?`, 16 zero bytes, `012345678901234567890123456789`.
- Period area (stream 0x62): one byte, 0x10 = 16.
- Selector area (stream 0x63–0x6E): `77 87 f3 60 35 2f 77 f3 72 77 34 0f`.
- Bitmap table (stream 0x6F–0x7F, 17 bytes). Its entries (bitmap /
  `period_bytes`), selectors 3 to 8: 0x00/0, 0x3F/0, 0x7F/0, 0xC0/0,
  0xFF/0, 0x00/1; the other six entries are 0x00/0.
- 0x80: end chunk.

Decoding the selector nibbles (low nibble first):

| Nibbles | Groups | Output |
|---|---|---|
| 7 | 0xFF, all literal | `Ycode LZ` |
| 7 | all literal | `BITMAP! ` |
| 7 | all literal | `Ycode LZ` |
| 8 | 0x00 with a 1-byte period: period = 16, all copied | `BITMAP! ` |
| 3, F 0 | 0x00 × 4 (period 16) | `Ycode LZBITMAP! ` ×2 |
| 6 | 0xC0: bytes 0–5 copied, 6–7 literal | `Ycode ` copied + `lz` |
| 5 | 0x7F: bytes 0–6 literal, 7 copied | `bitmap? ` |
| 3, F 2 | 0x00 × 6 | `Ycode lzbitmap? ` ×3 |
| 7, 7 | all literal | 16 zero bytes |
| 3, F 2 | 0x00 × 6 | 48 zero bytes |
| 7, 7, 7 | all literal | `012345678901234567890123` |
| 4 | 0x3F, 6 bytes left: no repeat count looked for | `456789` |
| 3, F, 0 | padding | — |

### 2.11 Encoder notes (for a compressor, if one is wanted)

- Apple's decoder accepts stored-only streams (§2.9) and libzbitmap's
  compressed output (§2.9); either is a valid writer.
- Only the decoder's rules are binding: area order, the table contents and
  the choice of selectors are the encoder's freedom, as long as every area
  read by §2.7 is inside the chunk and copies stay within 65 535 bytes of
  already produced output of the same stream.
- Do not emit a compressed chunk of exactly `out_len` + 6 bytes (§2.2).

### 2.12 Verification

All with a throwaway decoder written from this description (dirty side,
`research/dirty/lzbitmap/`, git-ignored, not committed):

| Test | Inputs | Result |
|---|---|---|
| Apple-encoded → our decoder → compare; and Apple's decoder on the same stream | 2 239: seven generators (random, word text, zeros, mixed random/runs/back-references up to 70 000 back, low-entropy, byte ramp, repeated patterns of period 1 to 65 535) × sizes 0–299, 511–513, 1 023–1 025, 4 095–4 097, 32 767–32 769, 32 776, 65 535–65 537, 98 304, 131 072, 200 000, 1 MiB | 2 239 of 2 239 exact; 1 594 stored and 943 compressed chunks |
| Periodic inputs (16 periods, 200 000 bytes) + 200 mixed inputs up to 150 000 bytes, with area-consumption checks | 216 | all exact; areas consumed exactly; selector padding 0–4 nibbles |
| Selector padding and overshoot survey | 400 | all exact; overshoot 0–7 groups |
| Decoder that always looks for a repeat count | 400 | 400 exact |
| libzbitmap encoder → Apple decoder; libzbitmap encoder → our decoder; Apple encoder → libzbitmap decoder | 300 each | 300, 300, 300 exact |
| Magic byte variants | 60 | §2.8 |
| decmpfs files written by `aa extract -afsc lzbitmap -afsc-all`, decoded from their attributes and forks | 16 compressed files (50 LZBITMAP blocks, 4 stored blocks) | 16 of 16 equal to the source files |

## 3. The decmpfs container

### 3.1 The `com.apple.decmpfs` attribute

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic: bytes `66 70 6D 63` (`fpmc`; the little-endian u32 0x636D7066, "cmpf") |
| 4 | 4 | compression type, u32 little-endian (§3.2) |
| 8 | 8 | uncompressed size, u64 little-endian (the file's logical size) |
| 16 | … | payload (inline types only) |

The attribute is at most **3 802 bytes** (`MAX_DECMPFS_XATTR_SIZE`): on
macOS 27, an attribute of 3 802 bytes is accepted and one of 3 803 is
stored but UF_COMPRESSED then does not take effect (§4.2).

### 3.2 Type numbers

Observed by extracting the same archive with `aa extract -afsc <algorithm>
-afsc-all` and reading the attributes back:

| Algorithm | Payload in the attribute | Payload in the resource fork | First payload byte: stored / compressed |
|---|---|---|---|
| zlib | 3 | 4 | 0xFF / 0x78 |
| LZVN | 7 | 8 | 0x06 / any other |
| LZFSE | 11 | 12 | 0xFF / 0x62 (`b`) |
| **LZBITMAP** | **13** | **14** | **0xFF / 0x5A (`Z`)** |

Other values from public sources, not observed here: type 1 (uncompressed
data in the attribute), 9 and 10 ("plain", stored data), and the
dataless types 0x80000001 and 0x80000002, which are not compressed data.
The extractor of §18.3 writes 13 and 14 only. On macOS 27 the public
AppleArchive extraction API (no algorithm given) wrote LZVN (7/8);
§18's simulator extractor chose LZBITMAP.

A reader tells the cases apart by the type number alone: odd 13 = inline,
even 14 = resource fork; then by the first byte of each payload or block:
0xFF = stored (the bytes after it are the data), 0x5A = an LZBITMAP stream
(§2). On macOS 27 a type-13 payload starting with any other byte (0x00,
0x06, 0x0F, 0x3F, 0xF0 tried) reads as 0 bytes.

### 3.3 Type 13: payload in the attribute

- The payload follows the header: 0xFF + the data, or one LZBITMAP stream.
- The uncompressed size is at most 65 536: a stream of 65 536 zero bytes
  read back; 70 000 and 200 000 (streams of 426 and 1 086 bytes, well
  within the attribute limit) read as 0 bytes.
- The macOS 27 writer puts the payload in the attribute when the whole
  attribute is at most 3 584 bytes (seen with stored data: 3 567 data bytes
  inline, 3 568 left uncompressed; with text, 3 559 inline, 3 597 moved to
  the fork). Otherwise it uses type 14, and if even that does not save
  space the file stays uncompressed. A reader must accept any attribute up
  to 3 802 bytes; the simulator's writer may choose differently.

Examples (ours): a 1-byte file `A`:
`66 70 6d 63 0d 00 00 00 01 00 00 00 00 00 00 00 ff 41`. A 1 005-byte text
file: header with size `ed 03 00 00 00 00 00 00`, then a 509-byte stream
beginning `5a 42 4d 09 f3 01 00 ed 03 00`.

### 3.4 Type 14: payload in the resource fork

The attribute is the 16-byte header only. The `com.apple.ResourceFork`
attribute holds:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 × (*n* + 1) | offset table: *n* + 1 u32 little-endian offsets, *n* = ⌈size / 65 536⌉ |
| offset[0] = 4 × (*n* + 1) | … | block 0 … block *n* − 1, back to back |

Block *i* is the bytes from offset[*i*] to offset[*i* + 1]; offset[*n*] is
the fork's length. Each block is 0xFF + stored data or one LZBITMAP stream
(Apple's streams for a full block hold two 32 768-byte chunks and the end
chunk). Block *i* produces exactly 65 536 bytes, except the last, which
produces size − 65 536 × (*n* − 1). Blocks are independent: copies never
cross a block boundary, so any block can be read alone.

Example (ours): a 65 537-byte text file. Attribute
`66 70 6d 63 0e 00 00 00 01 00 01 00 00 00 00 00`; fork begins
`0c 00 00 00 95 4c 00 00 97 4c 00 00` (offsets 12, 19 605, 19 607), block 0
starts `5a 42 4d 09 52 26 00 00 80 00` (a compressed chunk of 9 810 bytes
producing 32 768), and block 1 is `ff 20` (the last byte, a space, stored).

What the macOS 27 reader does with a damaged type-14 file:

| Fault | Result |
|---|---|
| no resource fork | `open` fails, ENOATTR |
| table with one entry too many (offset[0] wrong for the size) | `open` fails, EINVAL |
| one block producing 131 072 bytes for a 131 072-byte file | `open` fails, EINVAL |
| a middle block producing fewer than 65 536 bytes | reads return 0 bytes |
| both blocks stored (0xFF) | read back correctly |

The zlib fork type (4) uses a different fork layout (a classic resource-fork
header with a block list); it is not needed here.

## 4. What the file system must do

### 4.1 The writer's capability check (macOS 27, black box)

We extracted an archive whose entries carry UF_COMPRESSED with the public
AppleArchive API (`AAExtractArchiveOutputStreamOpen`) in our own program,
logging and changing the answers of the C library calls with an
interposer. Before the first file the extractor asks `statfs` of the target
directory, then `getattrlist` of the mount point that `statfs` named
(`f_mntonname`) with `ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES`:

| Answer to that `getattrlist` | Extractor |
|---|---|
| unchanged (format capabilities 0x019B6EDF, bit 0x10000 set) | writes decmpfs files |
| `VOL_CAP_FMT_DECMPFS_COMPRESSION` (0x10000) cleared in the capabilities (valid bit left set) | writes **plain** files, no decmpfs calls; all 18 files correct |
| that bit cleared in both capabilities and valid | plain files |
| the call fails (ENOTSUP or EINVAL) | writes decmpfs files (treats failure as "supported") |
| `f_fstypename` changed to `ext4` | writes decmpfs files (the name is not used) |

`aa extract -afsc lzbitmap -afsc-all` to a FAT volume also wrote plain,
correct files. So on macOS **the fallback is the capability bit**; failing
the later calls is not a fallback:

| Failure injected | Extractor |
|---|---|
| `fsetxattr(com.apple.decmpfs)` → ENOTSUP | every compressed file left **empty** (size 0); extraction still reports success |
| `fchflags(UF_COMPRESSED)` → ENOTSUP | same: empty files, success |
| `fsetxattr(com.apple.ResourceFork)` → EINVAL | fork-type files left empty, inline-type files fine; extraction reports an error at close |

This matches §18.3 (Ycode answering ENOTSUP, the simulator's extractor
aborting). Ycode reports format capabilities 0x001A4F47
(`file-system-features.md` §2), which lack 0x10000 with its valid bit set;
by the macOS rule the extractor should then write plain files, yet in the
simulator it compressed. See §5, question 1.

### 4.2 The writer's calls and what they must do

The call order per file (macOS public API; §18.3's trap trace of the
simulator shows the same calls):

1. Type 14 only: `fsetxattr(fd, "com.apple.ResourceFork", blocks,
   position = 4 × (n + 1), options 0)` (all blocks in one call), then
   `fsetxattr(fd, "com.apple.ResourceFork", table, position 0, options 0)`.
   §18.3's 4 674 bytes at position 12 is a two-block file.
2. `fsetxattr(fd, "com.apple.decmpfs", header [+ payload], position 0,
   options 0)`.
3. `ftruncate(fd, 0)`.
4. `fchflags(fd, UF_COMPRESSED)` (0x20).

Required behaviour (observed on macOS 27 APFS):

| Call or state | Behaviour |
|---|---|
| `setxattr` / `fsetxattr` of `com.apple.ResourceFork` | Position-addressed: writes at any position, the fork grows (zero-filled gaps), a write at position 0 does **not** truncate the fork (150 bytes stay 150 after writing 10 at 0). Any size (the forks above reach 312 133 bytes). |
| `setxattr` with a non-zero position on any other name | EINVAL |
| `fsetxattr` of `com.apple.decmpfs` on a file without UF_COMPRESSED | An ordinary attribute (any size; visible to listxattr/getxattr) |
| `fchflags(UF_COMPRESSED)` | Returns 0. The flag takes effect only if `com.apple.decmpfs` exists, is at least 16 bytes, at most 3 802 bytes, and starts with `fpmc`; otherwise the flag silently stays clear. The data fork's own bytes are ignored once it is set (a file with 3 bytes of data read back as the 4 000 decompressed bytes). |
| `stat` family on a compressed file | `st_size` = the header's uncompressed size; `st_flags` has UF_COMPRESSED; `st_blocks` counts the stored (compressed) bytes (0 for a small inline file) |
| `read`, `pread` | The decompressed bytes, at any offset |
| `listxattr` while UF_COMPRESSED is set | Omits `com.apple.decmpfs` and `com.apple.ResourceFork`, unless the option `XATTR_SHOWCOMPRESSION` (0x20) is given |
| `getxattr` of either name while UF_COMPRESSED is set | ENOATTR without `XATTR_SHOWCOMPRESSION`; the stored bytes with it |
| Opening a compressed file for writing and writing | The file is decompressed first: UF_COMPRESSED cleared, both attributes removed, contents kept, then the write applies (4 000 bytes + 1 appended = 4 001) |
| `fchflags(0)` on a compressed file | The flag clears; the file shows its (empty) data fork, size 0; `com.apple.decmpfs` stays and becomes visible |

### 4.3 Reading undecodable files (macOS 27)

| Fault | Result |
|---|---|
| unknown type (99) | `read` fails, EIO |
| type 13 payload that does not decode (truncated stream, wrong magic, empty payload, stored data shorter than the size, a stream shorter than the size) | `st_size` from the header; reads return 0 bytes, no error |
| stream longer than the header's size | the first *size* bytes |
| type-14 faults | §3.4 |

## 5. Open questions

1. **Which capability question the simulator's extractor asks, and what
   Ycode answers.** macOS's extractor writes plain files when
   `getattrlist(f_mntonname, ATTR_VOL_CAPABILITIES)` lacks 0x10000, and
   compresses when that call fails. Ycode reports the words without 0x10000,
   but the simulator's extractor compressed. Either the iOS 27 simulator's
   AppleArchive uses another test, or its `getattrlist` of the path in
   Ycode's `statfs` `f_mntonname` fails (which macOS treats as
   "supported"). A Ycode trap trace of `STExtractionService` around its
   first `fsetxattr` answers this; if the call fails, answering it with
   the capability words would make the extractor write plain files (a
   behaviour difference from the reference, whose APFS reports the bit).
2. **Magic bytes 0x0C and 0x0D.** Accepted by Apple's decoder with a
   different, unknown coding of compressed chunks (§2.8). No public encoder
   path produced them.
3. **The simulator writer's inline threshold** may differ from macOS's
   3 584 bytes; readers must accept up to 3 802 either way.
4. **Volumes other than APFS.** HFS+ behaviour was not observed.
5. **`mmap`** of compressed files and `F_NOCACHE`-style paths were not
   probed; `read`/`pread` were.

## 6. Open-source and documentation sources

| Source | Licence | Used for |
|---|---|---|
| libzbitmap (Ernesto A. Fernández, Corellium LLC, 2022), github.com/eafer/libzbitmap: an LZBITMAP decoder and encoder in C | **MIT** | The format of §2 (level 1); its encoder's output tested against Apple's decoder. Being MIT, the clean side may read it or use it with its copyright notice. |
| zbitmap (Rust crate 0.1.0, docs.rs/zbitmap): a port of libzbitmap's decoder with a decmpfs 13/14 reader | MIT | Confirms the type numbers and the 64 KiB block reader (not used further) |
| linux-apfs-rw (Corellium LLC), `compress.c`, `apfs_raw.h` | GPL-2.0-only (its bundled `libzbitmap.h` is GPL-2.0+ OR MIT) | Facts only, no code: type numbers 3/4, 7/8, 9/10, 11/12, 13/14; the 64 KiB block; the u32 offset table of fork types 8, 12, 14; stored markers |
| apfs-fuse issue #168 (github.com/sgan81/apfs-fuse) | GPL (project) | Facts only: 13 = LZBITMAP in the attribute, 14 = 64 KiB blocks in the fork |
| xnu `bsd/sys/decmpfs.h` (apple-oss-distributions/xnu) | APSL 2.0 | Header layout, `DECMPFS_MAGIC`, `MAX_DECMPFS_XATTR_SIZE` 3 802, `CMP_Type1`, dataless types |
| macOS 27 SDK headers: `compression.h`, `sys/xattr.h`, `sys/stat.h`, `sys/attr.h`, `AppleArchive/AADefs.h` | public SDK headers | `COMPRESSION_LZBITMAP` 0x702 (buffer API only), `XATTR_SHOWCOMPRESSION` 0x20, `UF_COMPRESSED` 0x20, `VOL_CAP_FMT_DECMPFS_COMPRESSION` 0x10000 |
| `aa` command help (`-afsc` options) | — | How to make decmpfs test files |

## Evidence

| Claim | Level |
|---|---|
| Stream layout, chunk header, stored/compressed/end chunks, compressed chunk areas, bitmap table, selectors, repeats, period rules (§2.2–§2.7) | 1 (libzbitmap, MIT), confirmed by 3 (round trips of §2.12) |
| Chunk size limit 32 768, stored-chunk rule, end chunk required, trailing bytes ignored (§2.2, §2.9) | 1 (libzbitmap) and 3 (Apple's decoder on hand-made streams) |
| Encoder behaviour: 32 768-byte chunks, small inputs stored, areas consumed exactly, selector padding 0–4 nibbles, overshoot up to 7 groups, periods up to 65 535 across chunks, table's last 16 bits zero, magic byte 0x09 (§2.2–§2.6) | 3 (statistics over Apple's output) |
| Period resets to 8 per compressed chunk (§2.6) | 1 (libzbitmap) and 3 (all round trips decode with it) |
| Fourth magic byte variants 0x08/0x09/0x0C/0x0D (§2.8) | 3 (Apple's decoder on modified streams) |
| `COMPRESSION_LZBITMAP` = 0x702, buffer API only; stream API refuses it (§2.1) | 1 (SDK `compression.h`) and 3 (`compression_stream_init` returns −1) |
| decmpfs header layout, magic, 3 802-byte limit (§3.1) | 1 (xnu `decmpfs.h`) and 3 (activation refused at 3 803) |
| Type numbers 3/4, 7/8, 11/12, 13/14 and stored markers (§3.2) | 2 (files written by `aa extract -afsc`, read with `XATTR_SHOWCOMPRESSION`) and 1 (linux-apfs-rw, apfs-fuse); 1, 9/10 and dataless types 1 only (xnu, linux-apfs-rw) |
| Inline usize ≤ 65 536; writer's 3 584-byte inline choice (§3.3) | 3 (macOS reader and `aa` writer) |
| Fork offset table, 64 KiB independent blocks, block sizes (§3.4) | 2 (16 files decoded) and 1 (linux-apfs-rw) |
| Reader errors for damaged files (§3.4, §4.3) | 3 (our files read on macOS 27 APFS) |
| Extractor's capability check, its answers to injected failures (§4.1) | 3 (public AppleArchive API in our program with a call-logging interposer; `aa` to a FAT disk image) |
| The writer's call order (§4.2) | 3 (same interposer on macOS) and §18.3's Ycode trap trace of the simulator |
| File-system behaviour table (§4.2) | 3 (our probes with `fsetxattr`, `fchflags`, `getxattr`, `listxattr`, `stat`, `read` on macOS 27 APFS) |
| `XATTR_SHOWCOMPRESSION`, `UF_COMPRESSED` values | 1 (SDK headers) |

No disassembly, decompilation or reading of Apple binaries was used. The
black-box tools (Python and C, our decoder, the interposer) and all test
files are in the git-ignored `research/dirty/lzbitmap/`.
