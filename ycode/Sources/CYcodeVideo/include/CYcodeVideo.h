/* CYcodeVideo: low-latency H.264 for the display stream
 * (specs/simulator/display-stream.md §14). The encoder is NVIDIA's NVENC
 * (the simulator host, a Jetson Thor), the decoder NVDEC (a viewer with an
 * NVIDIA GPU), both through the driver's libraries opened at run time with
 * dlopen; the interfaces come from the vendored MIT-licensed headers in
 * nvheaders/ffnvcodec. H.264, HEVC (4:2:0, and 4:4:4 where both ends have it)
 * and AV1, chosen by runtime capability checks; where a library or GPU is
 * missing, *_available() returns 0 and the stream falls back to JPEG tiles. */
#ifndef CYCODE_VIDEO_H
#define CYCODE_VIDEO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct yvid_enc yvid_enc;
typedef struct yvid_dec yvid_dec;

/* Codecs and decoded picture formats (display-stream.md §14). */
enum { YVID_H264 = 0, YVID_HEVC = 1, YVID_AV1 = 2 };
enum { YVID_NV12 = 0, YVID_YUV444 = 1 };

/* What NVENC offers for a codec: nvEncGetEncodeGUIDs, then the codec's caps. */
typedef struct { int supported, yuv444, tenBit, maxWidth, maxHeight; } yvid_enc_caps;

/* Opens and closes a session. 0 with *caps filled (`supported` 0: the GPU has
 * no such encoder), or -1 with the reason in `error`. */
int yvid_enc_query(int codec, yvid_enc_caps *caps, char *error, size_t errorSize);

/* An encoder's settings. fps is the nominal rate (it sizes the VBV). qp > 0:
 * constant QP, bitrateKbps unused. Otherwise constantBitrate 1: CBR with a VBV
 * of one frame; 0: VBR, peak twice the average, VBV of one frame of the peak.
 * yuv444 only with HEVC (Rext; NVDEC decodes no 4:4:4 H.264 or AV1). */
typedef struct { int codec, yuv444, fps, bitrateKbps, qp, constantBitrate; } yvid_enc_params;

/* 1 when NVENC can be opened here (checked once; opens and closes a session). */
int yvid_enc_available(void);

/* An encoder for width x height BGRA frames: H.264, no B-frames, an
 * infinite GOP (IDR only when asked), ultra-low-latency tuning, one frame of
 * VBV at `bitrateKbps` (peak twice that), `fps` the nominal rate. NULL on
 * failure (the reason in `error`, at most errorSize bytes). */
yvid_enc *yvid_enc_open(int width, int height, int fps, int bitrateKbps, char *error, size_t errorSize);

/* Copies the given rectangles (x, y, w, h quadruples; count < 0: the whole
 * frame) from `bgra` (rows `stride` bytes apart) into the encoder's input
 * picture, which keeps everything else from the previous frame, and encodes
 * it. On success returns 0 with the Annex B access unit in *out (valid until
 * the next call), its size, and whether it is an IDR. */
int yvid_enc_encode(yvid_enc *e, const uint8_t *bgra, size_t stride, const int32_t *rects, int count, int forceIDR,
                    const uint8_t **out, size_t *outSize, int *isIDR);

/* The same with a codec and rate control of choice (yvid_enc_open: H.264, VBR).
 * BGRA input either way: the encoder converts it to the coded chroma format. */
yvid_enc *yvid_enc_open2(int width, int height, const yvid_enc_params *params, char *error, size_t errorSize);

void yvid_enc_close(yvid_enc *e);

/* 1 when NVDEC can decode H.264 here. */
int yvid_dec_available(void);

yvid_dec *yvid_dec_open(char *error, size_t errorSize);

/* Decodes one access unit (no reordering: shown at once). Returns 1 with
 * the picture's NV12 planes (valid until the next call; Y is width x height
 * bytes `pitch` apart, UV width x height / 2), 0 when no picture came out,
 * -1 on an error (the next IDR recovers). */
int yvid_dec_decode(yvid_dec *d, const uint8_t *au, size_t size, const uint8_t **y, const uint8_t **uv,
                    int *width, int *height, int *pitch);

void yvid_dec_close(yvid_dec *d);

/* What NVDEC offers (cuvidGetDecoderCaps): 0 with *caps filled, or -1 (no driver). */
typedef struct { int supported, maxWidth, maxHeight; } yvid_dec_caps;
int yvid_dec_query(int codec, int yuv444, int bitDepth, yvid_dec_caps *caps);

/* A decoded picture. NV12: y and u (interleaved UV, height / 2 rows), v NULL.
 * YUV444: y, u, v full-size planes. All rows `pitch` bytes apart. */
typedef struct { int format; const uint8_t *y, *u, *v; int pitch, width, height; } yvid_picture;

/* A decoder for a codec; yvid_dec_open is H.264. The chroma format follows the stream. */
yvid_dec *yvid_dec_open2(int codec, char *error, size_t errorSize);

/* As yvid_dec_decode, for every format (valid until the next call). */
int yvid_dec_decode2(yvid_dec *d, const uint8_t *au, size_t size, yvid_picture *out);

/* NV12 → BGRX on the CPU (screenshots, image checks; not the display path). */
void yvid_nv12_to_bgrx(const uint8_t *y, const uint8_t *uv, int pitch, int width, int height, uint8_t *dst, size_t dstStride);

/* Planar 4:4:4 → BGRX on the CPU, the same matrix (the reference for the GPU's conversion). */
void yvid_yuv444_to_bgrx(const uint8_t *y, const uint8_t *u, const uint8_t *v, int pitch, int width, int height, uint8_t *dst, size_t dstStride);

#ifdef __cplusplus
}
#endif
#endif
