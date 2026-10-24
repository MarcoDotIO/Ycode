/* CYcodeCodec (see include/CYcodeCodec.h). Uses only the public libjpeg
 * and zlib interfaces, resolved with dlopen/dlsym. */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE
#endif
#include "CYcodeCodec.h"

#include <dlfcn.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

void ycodec_free(void *p) { free(p); }

void ycodec_name_thread(const char *name) {
    char buf[16];
    strncpy(buf, name, sizeof buf - 1);
    buf[sizeof buf - 1] = 0;
#if defined(__APPLE__)
    pthread_setname_np(buf);
#else
    pthread_setname_np(pthread_self(), buf);
#endif
}

/* ---- zlib ---- */

typedef int (*compress2_fn)(unsigned char *, unsigned long *, const unsigned char *, unsigned long, int);
typedef unsigned long (*compressBound_fn)(unsigned long);
static compress2_fn z_compress2;
static compressBound_fn z_compressBound;
static pthread_once_t zOnce = PTHREAD_ONCE_INIT;

static void *open_first(const char *const *names) {
    for (; *names; names++) {
        void *h = dlopen(*names, RTLD_NOW | RTLD_LOCAL);
        if (h) return h;
    }
    return NULL;
}

static void z_load(void) {
    static const char *const names[] = {"libz.so.1", "libz.so", "libz.1.dylib", "/usr/lib/libz.1.dylib", NULL};
    void *h = open_first(names);
    if (!h) return;
    compress2_fn c = (compress2_fn)dlsym(h, "compress2");
    compressBound_fn b = (compressBound_fn)dlsym(h, "compressBound");
    if (c && b) {
        z_compressBound = b;
        z_compress2 = c;
    }
}

int ycodec_zlib_available(void) {
    pthread_once(&zOnce, z_load);
    return z_compress2 != NULL;
}

size_t ycodec_zlib_bound(size_t n) {
    if (!ycodec_zlib_available()) return 0;
    return (size_t)z_compressBound((unsigned long)n);
}

int ycodec_zlib_compress(const uint8_t *src, size_t n, int level, uint8_t *dst, size_t *dstSize) {
    if (!ycodec_zlib_available()) return -1;
    unsigned long out = (unsigned long)*dstSize;
    if (z_compress2(dst, &out, src, (unsigned long)n, level) != 0) return -1;
    *dstSize = (size_t)out;
    return 0;
}

/* ---- downscale ---- */

void ycodec_downscale_bgra(const uint8_t *src, size_t srcBytesPerRow, int srcWidth, int srcHeight, int factor,
                           uint8_t *dst, size_t dstBytesPerRow) {
    if (factor < 1) factor = 1;
    int dw = (srcWidth + factor - 1) / factor, dh = (srcHeight + factor - 1) / factor;
    if (factor == 1) {
        for (int y = 0; y < srcHeight; y++) memcpy(dst + (size_t)y * dstBytesPerRow, src + (size_t)y * srcBytesPerRow, (size_t)srcWidth * 4);
        return;
    }
    for (int dy = 0; dy < dh; dy++) {
        int y0 = dy * factor, y1 = y0 + factor > srcHeight ? srcHeight : y0 + factor;
        uint8_t *out = dst + (size_t)dy * dstBytesPerRow;
        for (int dx = 0; dx < dw; dx++) {
            int x0 = dx * factor, x1 = x0 + factor > srcWidth ? srcWidth : x0 + factor;
            unsigned s0 = 0, s1 = 0, s2 = 0, s3 = 0, n = 0;
            for (int y = y0; y < y1; y++) {
                const uint8_t *p = src + (size_t)y * srcBytesPerRow + (size_t)x0 * 4;
                for (int x = x0; x < x1; x++, p += 4) {
                    s0 += p[0];
                    s1 += p[1];
                    s2 += p[2];
                    s3 += p[3];
                    n++;
                }
            }
            out[0] = (uint8_t)(s0 / n);
            out[1] = (uint8_t)(s1 / n);
            out[2] = (uint8_t)(s2 / n);
            out[3] = (uint8_t)(s3 / n);
            out += 4;
        }
    }
}

/* ---- JPEG ---- */

#if defined(__has_include)
#if __has_include(<jpeglib.h>)
#define YCODEC_HAVE_JPEG_HEADER 1
#endif
#endif

#ifdef YCODEC_HAVE_JPEG_HEADER
#include <jpeglib.h>

static struct {
    struct jpeg_error_mgr *(*std_error)(struct jpeg_error_mgr *);
    void (*create)(j_compress_ptr, int, size_t);
    void (*set_defaults)(j_compress_ptr);
    void (*set_quality)(j_compress_ptr, int, boolean);
    void (*mem_dest)(j_compress_ptr, unsigned char **, unsigned long *);
    void (*start)(j_compress_ptr, boolean);
    JDIMENSION (*write_scanlines)(j_compress_ptr, JSAMPARRAY, JDIMENSION);
    void (*finish)(j_compress_ptr);
    void (*destroy)(j_compress_ptr);
    int ok;
} J;
static pthread_once_t jOnce = PTHREAD_ONCE_INIT;

static void j_load(void) {
#if JPEG_LIB_VERSION >= 80
    static const char *const names[] = {"libjpeg.so.8", "libjpeg.so", NULL};
#elif JPEG_LIB_VERSION >= 70
    static const char *const names[] = {"libjpeg.so.7", "libjpeg.so", NULL};
#else
    static const char *const names[] = {"libjpeg.so.62", "libjpeg.so", NULL};
#endif
    void *h = open_first(names);
    if (!h) return;
#define SYM(field, name) *(void **)&J.field = dlsym(h, name); if (!J.field) return;
    SYM(std_error, "jpeg_std_error")
    SYM(create, "jpeg_CreateCompress")
    SYM(set_defaults, "jpeg_set_defaults")
    SYM(set_quality, "jpeg_set_quality")
    SYM(mem_dest, "jpeg_mem_dest")
    SYM(start, "jpeg_start_compress")
    SYM(write_scanlines, "jpeg_write_scanlines")
    SYM(finish, "jpeg_finish_compress")
    SYM(destroy, "jpeg_destroy_compress")
#undef SYM
    J.ok = 1;
}

struct ycodec_jpeg_job {
    struct jpeg_error_mgr err;
    jmp_buf jump;
    unsigned char *buffer;
    unsigned long size;
    uint8_t *row;
};

static void on_error(j_common_ptr c) {
    struct ycodec_jpeg_job *job = (struct ycodec_jpeg_job *)c->err;
    longjmp(job->jump, 1);
}

static void on_message(j_common_ptr c) { (void)c; }

int ycodec_jpeg_available(void) {
    pthread_once(&jOnce, j_load);
    return J.ok;
}

int ycodec_jpeg_encode_bgra(const uint8_t *pixels, int width, int height, size_t bytesPerRow, int quality,
                            uint8_t **out, size_t *outSize) {
    if (!ycodec_jpeg_available() || width <= 0 || height <= 0) return -1;
    struct jpeg_compress_struct cinfo;
    struct ycodec_jpeg_job job;
    memset(&cinfo, 0, sizeof cinfo);
    memset(&job, 0, sizeof job);
    cinfo.err = J.std_error(&job.err);
    job.err.error_exit = on_error;
    job.err.output_message = on_message;
#ifndef JCS_EXTENSIONS
    job.row = malloc((size_t)width * 3);
    if (!job.row) return -1;
#endif
    if (setjmp(job.jump)) {
        J.destroy(&cinfo);
        free(job.buffer);
        free(job.row);
        return -1;
    }
    J.create(&cinfo, JPEG_LIB_VERSION, sizeof cinfo);
    J.mem_dest(&cinfo, &job.buffer, &job.size);
    cinfo.image_width = (JDIMENSION)width;
    cinfo.image_height = (JDIMENSION)height;
#ifdef JCS_EXTENSIONS
    cinfo.input_components = 4;
    cinfo.in_color_space = JCS_EXT_BGRX;
#else
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
#endif
    J.set_defaults(&cinfo);
    J.set_quality(&cinfo, quality < 1 ? 1 : quality > 100 ? 100 : quality, TRUE);
    cinfo.dct_method = JDCT_IFAST;
    J.start(&cinfo, TRUE);
    while (cinfo.next_scanline < cinfo.image_height) {
        const uint8_t *src = pixels + (size_t)cinfo.next_scanline * bytesPerRow;
#ifdef JCS_EXTENSIONS
        JSAMPROW row = (JSAMPROW)src;
#else
        for (int x = 0; x < width; x++) {
            job.row[x * 3 + 0] = src[x * 4 + 2];
            job.row[x * 3 + 1] = src[x * 4 + 1];
            job.row[x * 3 + 2] = src[x * 4 + 0];
        }
        JSAMPROW row = job.row;
#endif
        J.write_scanlines(&cinfo, &row, 1);
    }
    J.finish(&cinfo);
    J.destroy(&cinfo);
    free(job.row);
    *out = job.buffer;
    *outSize = (size_t)job.size;
    return 0;
}

#else /* no jpeglib.h at build time */

int ycodec_jpeg_available(void) { return 0; }

int ycodec_jpeg_encode_bgra(const uint8_t *pixels, int width, int height, size_t bytesPerRow, int quality,
                            uint8_t **out, size_t *outSize) {
    (void)pixels; (void)width; (void)height; (void)bytesPerRow; (void)quality; (void)out; (void)outSize;
    return -1;
}

#endif
