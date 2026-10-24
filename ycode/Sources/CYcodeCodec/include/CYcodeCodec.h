/* CYcodeCodec: image helpers for the display stream
 * (specs/simulator/display-stream.md §4). JPEG comes from the system's
 * libjpeg (libjpeg-turbo), zlib from the system's libz, both loaded at run
 * time with dlopen: the package builds where neither is installed, and the
 * functions then report "unavailable". */
#ifndef CYCODE_CODEC_H
#define CYCODE_CODEC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 1 when JPEG encoding works here (header at build time, library at run time). */
int ycodec_jpeg_available(void);

/* Encodes `width` x `height` BGRA pixels (rows `bytesPerRow` apart) as a
 * baseline JPEG of `quality` (1...100). On success returns 0 and sets *out
 * (free with ycodec_free) and *outSize; otherwise returns -1. */
int ycodec_jpeg_encode_bgra(const uint8_t *pixels, int width, int height, size_t bytesPerRow, int quality,
                            uint8_t **out, size_t *outSize);

/* 1 when zlib can be loaded. */
int ycodec_zlib_available(void);

/* Worst-case size of compressing n bytes (0 without zlib). */
size_t ycodec_zlib_bound(size_t n);

/* zlib-format (RFC 1950) compression of src into dst (capacity *dstSize,
 * at least ycodec_zlib_bound(n)). Returns 0 and the compressed size in
 * *dstSize, or -1. */
int ycodec_zlib_compress(const uint8_t *src, size_t n, int level, uint8_t *dst, size_t *dstSize);

/* Box-filter downscale of BGRA by an integer factor (1...8). The result is
 * ceil(srcWidth / factor) x ceil(srcHeight / factor); edge cells average
 * the pixels they cover. */
void ycodec_downscale_bgra(const uint8_t *src, size_t srcBytesPerRow, int srcWidth, int srcHeight, int factor,
                           uint8_t *dst, size_t dstBytesPerRow);

void ycodec_free(void *p);

/* Names the calling thread (at most 15 bytes are kept). */
void ycodec_name_thread(const char *name);

#ifdef __cplusplus
}
#endif
#endif
