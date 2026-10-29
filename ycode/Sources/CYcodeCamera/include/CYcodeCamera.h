/* CYcodeCamera: the host camera layer's C helpers
 * (specs/simulator/camera-host.md).
 *
 * - V4L2 access (Linux; the public V4L2 API of <linux/videodev2.h>): device
 *   capabilities, format/size/interval enumeration, format negotiation,
 *   memory-mapped streaming. Elsewhere every call returns -ENOSYS.
 * - A baseline JPEG decoder of our own (ITU-T T.81 sequential Huffman,
 *   8-bit, 1 or 3 components), for cameras that send Motion-JPEG.
 * - Pixel conversion from any 8-bit Y'CbCr layout (packed 4:2:2, planar,
 *   bi-planar) into bi-planar 4:2:0 (video or full range) and 32-bit BGRA.
 *
 * Every function is reentrant; nothing here keeps global state. */
#ifndef CYCODE_CAMERA_H
#define CYCODE_CAMERA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* MARK: V4L2 */

typedef struct {
    char driver[16];
    char card[32];
    char bus_info[32];
    uint32_t version;
    uint32_t capabilities;
    uint32_t device_caps;
} ycam_caps;

/* The format of a capture queue (single-planar). */
typedef struct {
    uint32_t width, height, pixelformat, bytesperline, sizeimage;
    uint32_t field, colorspace, ycbcr_enc, quantization, xfer_func;
} ycam_format;

typedef struct {
    uint32_t index;      /* buffer index */
    uint32_t bytesused;
    uint32_t flags;      /* V4L2_BUF_FLAG_* */
    uint32_t sequence;   /* the driver's frame counter */
    int64_t timestamp_ns; /* the buffer's timestamp, nanoseconds */
} ycam_dequeued;

/* Opens a device node read-write, non-blocking, close-on-exec. Returns the
 * descriptor or -errno. */
int ycam_open(const char *path);
void ycam_close(int fd);

/* VIDIOC_QUERYCAP. 0 or -errno. */
int ycam_query_caps(int fd, ycam_caps *out);

/* VIDIOC_ENUM_FMT on the video-capture queue. 0, or -EINVAL past the end. */
int ycam_enum_format(int fd, uint32_t index, uint32_t *pixelformat, uint32_t *flags, char description[32]);

/* VIDIOC_ENUM_FRAMESIZES. *type: 1 discrete (v[0..1] = width, height),
 * 2 continuous or 3 stepwise (v[0..5] = min w, max w, step w, min h, max h,
 * step h). 0, or -EINVAL past the end. */
int ycam_enum_framesize(int fd, uint32_t pixelformat, uint32_t index, uint32_t *type, uint32_t v[6]);

/* VIDIOC_ENUM_FRAMEINTERVALS. *type: 1 discrete (v[0..1] = numerator,
 * denominator, seconds per frame), 2 continuous or 3 stepwise (v[0..5] =
 * min num, min den, max num, max den, step num, step den). */
int ycam_enum_frameinterval(int fd, uint32_t pixelformat, uint32_t width, uint32_t height, uint32_t index,
                            uint32_t *type, uint32_t v[6]);

/* VIDIOC_S_FMT (or VIDIOC_TRY_FMT when try_only) with *f; the driver's
 * choice comes back in *f. 0 or -errno. */
int ycam_set_format(int fd, ycam_format *f, int try_only);
/* VIDIOC_G_FMT. */
int ycam_get_format(int fd, ycam_format *f);

/* VIDIOC_S_PARM time-per-frame: *num / *den seconds in, the driver's value
 * out. -ENOTTY (or another -errno) when the driver has no frame rate
 * control. */
int ycam_set_interval(int fd, uint32_t *num, uint32_t *den);

/* VIDIOC_REQBUFS with V4L2_MEMORY_MMAP. Returns the number granted (0 frees
 * them) or -errno. */
int ycam_request_buffers(int fd, uint32_t count);
/* VIDIOC_QUERYBUF + mmap. 0 or -errno. */
int ycam_map_buffer(int fd, uint32_t index, void **address, uint32_t *length);
void ycam_unmap_buffer(void *address, uint32_t length);
/* VIDIOC_QBUF. */
int ycam_queue(int fd, uint32_t index);
/* VIDIOC_DQBUF: 0, -EAGAIN when no buffer is ready, -ENODEV when the device
 * went away, or another -errno. */
int ycam_dequeue(int fd, ycam_dequeued *out);
/* VIDIOC_STREAMON / VIDIOC_STREAMOFF. */
int ycam_stream(int fd, int on);
/* poll(2) for a filled buffer: 1 ready, 0 timeout, -ENODEV when the device
 * reports an error or hang-up, or another -errno. */
int ycam_wait(int fd, int timeout_ms);

/* CLOCK_MONOTONIC in nanoseconds (the clock of V4L2 monotonic timestamps). */
int64_t ycam_monotonic_ns(void);

/* MARK: JPEG */

typedef struct ycam_jpeg ycam_jpeg;

/* A decoder; it keeps its buffers between frames. NULL when out of memory. */
ycam_jpeg *ycam_jpeg_new(void);
void ycam_jpeg_free(ycam_jpeg *decoder);

/* Decodes one baseline JPEG (the Motion-JPEG frame of a UVC camera: the
 * standard Huffman tables of T.81 Annex K.3 are used when the stream has
 * no DHT). 0 on success, a negative code otherwise:
 * -1 truncated or malformed, -2 unsupported (progressive, arithmetic,
 * 12-bit, more than 3 components, sampling factor above 2), -3 no memory. */
int ycam_jpeg_decode(ycam_jpeg *decoder, const uint8_t *data, size_t size);

/* The last decoded image. Components: 1 (grey) or 3 (Y, Cb, Cr). The plane
 * of component c has sampling factors h[c], v[c] (relative to hmax, vmax)
 * and is `stride[c]` bytes per row; it covers the image (rounded up to whole
 * MCUs). */
typedef struct {
    int width, height, components;
    int h[3], v[3], hmax, vmax;
    const uint8_t *plane[3];
    int stride[3];
} ycam_jpeg_image;
void ycam_jpeg_image_info(const ycam_jpeg *decoder, ycam_jpeg_image *out);

/* MARK: Conversion */

/* An 8-bit Y'CbCr source: each component is a pointer, the distance in
 * bytes between horizontally adjacent samples, and the row stride. The
 * chroma planes are subsampled by `hsub` x `vsub` (1 or 2 each).
 *   YUYV:      y = p, ystep 2; cb = p+1, cr = p+3, cstep 4; hsub 2, vsub 1
 *   NV12:      y = p, ystep 1; cb = uv, cr = uv+1, cstep 2; hsub 2, vsub 2
 *   I420/YV12: three planes, steps 1; hsub 2, vsub 2
 * `full_range`: 1 for full range (JPEG/JFIF), 0 for video range.
 * `matrix`: 601 or 709. */
typedef struct {
    const uint8_t *y, *cb, *cr;
    int ystep, cstep;
    size_t ystride, cstride;
    int hsub, vsub;
    int width, height;
    int full_range;
    int matrix;
} ycam_ycbcr_source;

/* Writes bi-planar 4:2:0 (Y plane, then interleaved Cb Cr at half width and
 * half height). `out_full_range`: 1 for '420f', 0 for '420v'. Each output
 * chroma sample is the rounded mean of the source chroma covering its 2x2
 * luma block. Odd sizes: the last column/row is repeated. */
void ycam_to_biplanar420(const ycam_ycbcr_source *s, uint8_t *y, size_t ystride, uint8_t *cbcr, size_t cstride,
                         int out_full_range);

/* Writes 32-bit BGRA (alpha 255), each pixel from its own luma and the
 * chroma sample that covers it. */
void ycam_to_bgra(const ycam_ycbcr_source *s, uint8_t *bgra, size_t stride);

/* One Y'CbCr triple to B, G, R (the arithmetic of ycam_to_bgra). */
void ycam_ycbcr_to_bgr(int y, int cb, int cr, int full_range, int matrix, uint8_t bgr[3]);

/* The range mapping of luma and chroma samples (the arithmetic of
 * ycam_to_biplanar420). */
uint8_t ycam_map_luma(int value, int from_full, int to_full);
uint8_t ycam_map_chroma(int value, int from_full, int to_full);

/* Downscales BGRA by an integer factor (box filter). */
void ycam_bgra_downscale(const uint8_t *src, int width, int height, size_t stride, int factor, uint8_t *dst,
                         size_t dst_stride);

#ifdef __cplusplus
}
#endif

#endif
