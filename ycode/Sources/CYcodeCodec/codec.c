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
typedef int (*uncompress_fn)(unsigned char *, unsigned long *, const unsigned char *, unsigned long);
static compress2_fn z_compress2;
static compressBound_fn z_compressBound;
static uncompress_fn z_uncompress;
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
    uncompress_fn u = (uncompress_fn)dlsym(h, "uncompress");
    if (c && b && u) {
        z_compressBound = b;
        z_uncompress = u;
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

int ycodec_zlib_uncompress(const uint8_t *src, size_t n, uint8_t *dst, size_t *dstSize) {
    if (!ycodec_zlib_available()) return -1;
    unsigned long out = (unsigned long)*dstSize;
    if (z_uncompress(dst, &out, src, (unsigned long)n) != 0) return -1;
    *dstSize = (size_t)out;
    return 0;
}

static uint32_t crcTable[256];
static pthread_once_t crcOnce = PTHREAD_ONCE_INIT;

static void crc_build(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crcTable[i] = c;
    }
}

uint32_t ycodec_crc32(uint32_t crc, const uint8_t *src, size_t n) {
    pthread_once(&crcOnce, crc_build);
    crc = ~crc;
    for (size_t i = 0; i < n; i++) crc = crcTable[(crc ^ src[i]) & 0xFF] ^ (crc >> 8);
    return ~crc;
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

/* The library's entry points. A library is used only after a test picture
 * went through it both ways (j_probe): libjpeg checks the caller's ABI
 * version and structure size in jpeg_CreateCompress and refuses another
 * one, so a library of another ABI than this build's header (libjpeg.so.8
 * under a header of version 62, through the unversioned libjpeg.so) used
 * to be "available" while every picture failed, and the display stream
 * sent frames without tiles. */
struct jfns {
    struct jpeg_error_mgr *(*std_error)(struct jpeg_error_mgr *);
    void (*create)(j_compress_ptr, int, size_t);
    void (*set_defaults)(j_compress_ptr);
    void (*set_quality)(j_compress_ptr, int, boolean);
    void (*mem_dest)(j_compress_ptr, unsigned char **, unsigned long *);
    void (*start)(j_compress_ptr, boolean);
    JDIMENSION (*write_scanlines)(j_compress_ptr, JSAMPARRAY, JDIMENSION);
    void (*finish)(j_compress_ptr);
    void (*destroy)(j_compress_ptr);
    /* Decompression (the viewer's side). */
    void (*d_create)(j_decompress_ptr, int, size_t);
    void (*d_mem_src)(j_decompress_ptr, const unsigned char *, unsigned long);
    int (*d_read_header)(j_decompress_ptr, boolean);
    boolean (*d_start)(j_decompress_ptr);
    JDIMENSION (*d_read_scanlines)(j_decompress_ptr, JSAMPARRAY, JDIMENSION);
    boolean (*d_finish)(j_decompress_ptr);
    void (*d_destroy)(j_decompress_ptr);
};
static struct jfns J;
static int jOK, jDecodeOK;
static char jProblem[512];
static pthread_once_t jOnce = PTHREAD_ONCE_INIT;

#if JPEG_LIB_VERSION >= 80
#define YCODEC_JPEG_SONAME "libjpeg.so.8"
#elif JPEG_LIB_VERSION >= 70
#define YCODEC_JPEG_SONAME "libjpeg.so.7"
#else
#define YCODEC_JPEG_SONAME "libjpeg.so.62"
#endif

struct ycodec_jpeg_job {
    struct jpeg_error_mgr err;
    jmp_buf jump;
    unsigned char *buffer;
    unsigned long size;
    uint8_t *row;
    char *message; /* where the library's last error text goes, or NULL */
    size_t messageSize;
};

static void on_error(j_common_ptr c) {
    struct ycodec_jpeg_job *job = (struct ycodec_jpeg_job *)c->err;
    if (job->message && job->messageSize > 0) {
        char text[JMSG_LENGTH_MAX];
        (*c->err->format_message)(c, text);
        snprintf(job->message, job->messageSize, "%s", text);
    }
    longjmp(job->jump, 1);
}

static void on_message(j_common_ptr c) { (void)c; }

/* Resolves every entry point of `h`; 0 when all are there. */
static int j_resolve(void *h, struct jfns *f, char *why, size_t whySize) {
#define SYM(field, name) \
    *(void **)&f->field = dlsym(h, name); \
    if (!f->field) { snprintf(why, whySize, "it has no %s", name); return -1; }
    SYM(std_error, "jpeg_std_error")
    SYM(create, "jpeg_CreateCompress")
    SYM(set_defaults, "jpeg_set_defaults")
    SYM(set_quality, "jpeg_set_quality")
    SYM(mem_dest, "jpeg_mem_dest")
    SYM(start, "jpeg_start_compress")
    SYM(write_scanlines, "jpeg_write_scanlines")
    SYM(finish, "jpeg_finish_compress")
    SYM(destroy, "jpeg_destroy_compress")
    SYM(d_create, "jpeg_CreateDecompress")
    SYM(d_mem_src, "jpeg_mem_src")
    SYM(d_read_header, "jpeg_read_header")
    SYM(d_start, "jpeg_start_decompress")
    SYM(d_read_scanlines, "jpeg_read_scanlines")
    SYM(d_finish, "jpeg_finish_decompress")
    SYM(d_destroy, "jpeg_destroy_decompress")
#undef SYM
    return 0;
}

static int encode_with(const struct jfns *f, int callerVersion, const uint8_t *pixels, int width, int height, size_t bytesPerRow,
                       int quality, uint8_t **out, size_t *outSize, char *why, size_t whySize);
static int decode_with(const struct jfns *f, int callerVersion, const uint8_t *data, size_t size, int width, int height, uint8_t *dst,
                       size_t dstBytesPerRow, char *why, size_t whySize);

/* A 16 x 16 test picture through the library both ways, as a caller of ABI
 * `callerVersion` (this build's JPEG_LIB_VERSION; tests pass another one).
 * 0 when the picture comes back with about its colours. */
static int j_probe(const struct jfns *f, int callerVersion, char *why, size_t whySize) {
    enum { N = 16 };
    uint8_t picture[N * N * 4], back[N * N * 4];
    for (int i = 0; i < N * N; i++) {
        picture[i * 4 + 0] = 40;  /* B */
        picture[i * 4 + 1] = 120; /* G */
        picture[i * 4 + 2] = 200; /* R */
        picture[i * 4 + 3] = 255;
    }
    uint8_t *coded = NULL;
    size_t codedSize = 0;
    if (encode_with(f, callerVersion, picture, N, N, N * 4, 90, &coded, &codedSize, why, whySize) != 0) return -1;
    if (!coded || codedSize < 100) {
        free(coded);
        snprintf(why, whySize, "a test picture came out as %zu bytes", codedSize);
        return -1;
    }
    int r = decode_with(f, callerVersion, coded, codedSize, N, N, back, N * 4, why, whySize);
    free(coded);
    if (r != 0) return -1;
    for (int c = 0; c < 3; c++) {
        int d = (int)back[(N * N / 2) * 4 + c] - (int)picture[(N * N / 2) * 4 + c];
        if (d < -24 || d > 24) {
            snprintf(why, whySize, "a test picture came back with other colours");
            return -1;
        }
    }
    return 0;
}

int ycodec_jpeg_probe_library(const char *name, int callerVersion, char *why, size_t whySize) {
    char local[256];
    if (!why || whySize == 0) { why = local; whySize = sizeof local; }
    why[0] = 0;
    void *h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        snprintf(why, whySize, "%.200s cannot be loaded", name);
        return -1;
    }
    struct jfns f;
    memset(&f, 0, sizeof f);
    char inner[200] = "";
    if (j_resolve(h, &f, inner, sizeof inner) != 0 || j_probe(&f, callerVersion, inner, sizeof inner) != 0) {
        snprintf(why, whySize, "%.200s: %.200s", name, inner);
        dlclose(h);
        return -1;
    }
    dlclose(h);
    return 0;
}

static void j_load(void) {
    /* This build's ABI first; the unversioned name (a -dev package's link)
     * only if it is the same ABI, which the probe checks. */
    const char *names[] = {getenv("YCODE_JPEG_LIBRARY"), YCODEC_JPEG_SONAME, "libjpeg.so"};
    char tried[400] = "";
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        const char *name = names[i];
        if (!name || !*name) continue;
        void *h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
        char why[200] = "", entry[320];
        if (!h) {
            snprintf(entry, sizeof entry, "%.100s is not installed", name);
        } else if (j_resolve(h, &J, why, sizeof why) == 0 && j_probe(&J, JPEG_LIB_VERSION, why, sizeof why) == 0) {
            jOK = jDecodeOK = 1;
            jProblem[0] = 0;
            return;
        } else {
            snprintf(entry, sizeof entry, "%.100s: %.200s", name, why);
            memset(&J, 0, sizeof J);
            dlclose(h);
        }
        size_t used = strlen(tried);
        snprintf(tried + used, sizeof tried - used, "%s%.320s", used ? "; " : "", entry);
    }
    snprintf(jProblem, sizeof jProblem, "no usable libjpeg for this build's ABI (version %d): %.400s", JPEG_LIB_VERSION, tried);
}

int ycodec_jpeg_available(void) {
    pthread_once(&jOnce, j_load);
    return jOK;
}

const char *ycodec_jpeg_problem(void) {
    pthread_once(&jOnce, j_load);
    return jOK ? NULL : jProblem;
}

int ycodec_jpeg_abi_version(void) { return JPEG_LIB_VERSION; }

int ycodec_jpeg_encode_bgra(const uint8_t *pixels, int width, int height, size_t bytesPerRow, int quality,
                            uint8_t **out, size_t *outSize) {
    if (!ycodec_jpeg_available() || width <= 0 || height <= 0) return -1;
    return encode_with(&J, JPEG_LIB_VERSION, pixels, width, height, bytesPerRow, quality, out, outSize, NULL, 0);
}

static int encode_with(const struct jfns *f, int callerVersion, const uint8_t *pixels, int width, int height, size_t bytesPerRow,
                       int quality, uint8_t **out, size_t *outSize, char *why, size_t whySize) {
    if (width <= 0 || height <= 0) return -1;
    struct jpeg_compress_struct cinfo;
    struct ycodec_jpeg_job job;
    memset(&cinfo, 0, sizeof cinfo);
    memset(&job, 0, sizeof job);
    job.message = why;
    job.messageSize = whySize;
    cinfo.err = f->std_error(&job.err);
    job.err.error_exit = on_error;
    job.err.output_message = on_message;
#ifndef JCS_EXTENSIONS
    job.row = malloc((size_t)width * 3);
    if (!job.row) return -1;
#endif
    if (setjmp(job.jump)) {
        f->destroy(&cinfo);
        free(job.buffer);
        free(job.row);
        return -1;
    }
    f->create(&cinfo, callerVersion, sizeof cinfo);
    f->mem_dest(&cinfo, &job.buffer, &job.size);
    cinfo.image_width = (JDIMENSION)width;
    cinfo.image_height = (JDIMENSION)height;
#ifdef JCS_EXTENSIONS
    cinfo.input_components = 4;
    cinfo.in_color_space = JCS_EXT_BGRX;
#else
    cinfo.input_components = 3;
    cinfo.in_color_space = JCS_RGB;
#endif
    f->set_defaults(&cinfo);
    f->set_quality(&cinfo, quality < 1 ? 1 : quality > 100 ? 100 : quality, TRUE);
    cinfo.dct_method = JDCT_IFAST;
    f->start(&cinfo, TRUE);
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
        f->write_scanlines(&cinfo, &row, 1);
    }
    f->finish(&cinfo);
    f->destroy(&cinfo);
    free(job.row);
    *out = job.buffer;
    *outSize = (size_t)job.size;
    return 0;
}

int ycodec_jpeg_decode_available(void) {
    pthread_once(&jOnce, j_load);
    return jDecodeOK;
}

int ycodec_jpeg_decode_bgra(const uint8_t *data, size_t size, int width, int height, uint8_t *dst, size_t dstBytesPerRow) {
    if (!ycodec_jpeg_decode_available()) return -1;
    return decode_with(&J, JPEG_LIB_VERSION, data, size, width, height, dst, dstBytesPerRow, NULL, 0);
}

static int decode_with(const struct jfns *f, int callerVersion, const uint8_t *data, size_t size, int width, int height, uint8_t *dst,
                       size_t dstBytesPerRow, char *why, size_t whySize) {
    if (!data || size < 4 || width <= 0 || height <= 0) return -1;
    struct jpeg_decompress_struct dinfo;
    struct ycodec_jpeg_job job;
    memset(&dinfo, 0, sizeof dinfo);
    memset(&job, 0, sizeof job);
    job.message = why;
    job.messageSize = whySize;
    dinfo.err = f->std_error(&job.err);
    job.err.error_exit = on_error;
    job.err.output_message = on_message;
    if (setjmp(job.jump)) {
        f->d_destroy(&dinfo);
        free(job.row);
        return -1;
    }
    f->d_create(&dinfo, callerVersion, sizeof dinfo);
    f->d_mem_src(&dinfo, data, (unsigned long)size);
    if (f->d_read_header(&dinfo, TRUE) != JPEG_HEADER_OK || (int)dinfo.image_width != width || (int)dinfo.image_height != height) {
        f->d_destroy(&dinfo);
        if (why && whySize) snprintf(why, whySize, "a test picture came back with another size");
        return -1;
    }
#ifdef JCS_EXTENSIONS
    dinfo.out_color_space = JCS_EXT_BGRX;
#else
    dinfo.out_color_space = JCS_RGB;
    job.row = malloc((size_t)width * 3);
    if (!job.row) { f->d_destroy(&dinfo); return -1; }
#endif
    dinfo.dct_method = JDCT_IFAST;
    dinfo.do_fancy_upsampling = FALSE;
    f->d_start(&dinfo);
    while (dinfo.output_scanline < dinfo.output_height) {
        uint8_t *out = dst + (size_t)dinfo.output_scanline * dstBytesPerRow;
#ifdef JCS_EXTENSIONS
        JSAMPROW row = (JSAMPROW)out;
        f->d_read_scanlines(&dinfo, &row, 1);
#else
        JSAMPROW row = job.row;
        f->d_read_scanlines(&dinfo, &row, 1);
        for (int x = 0; x < width; x++) {
            out[x * 4 + 0] = job.row[x * 3 + 2];
            out[x * 4 + 1] = job.row[x * 3 + 1];
            out[x * 4 + 2] = job.row[x * 3 + 0];
            out[x * 4 + 3] = 0xFF;
        }
#endif
    }
    f->d_finish(&dinfo);
    f->d_destroy(&dinfo);
    free(job.row);
    return 0;
}

#else /* no jpeglib.h at build time */

int ycodec_jpeg_available(void) { return 0; }

const char *ycodec_jpeg_problem(void) { return "this build has no JPEG support (no jpeglib.h when it was built)"; }

int ycodec_jpeg_abi_version(void) { return 0; }

int ycodec_jpeg_probe_library(const char *name, int callerVersion, char *why, size_t whySize) {
    (void)callerVersion;
    if (why && whySize) snprintf(why, whySize, "%s: this build has no JPEG support", name);
    return -1;
}

int ycodec_jpeg_encode_bgra(const uint8_t *pixels, int width, int height, size_t bytesPerRow, int quality,
                            uint8_t **out, size_t *outSize) {
    (void)pixels; (void)width; (void)height; (void)bytesPerRow; (void)quality; (void)out; (void)outSize;
    return -1;
}

int ycodec_jpeg_decode_available(void) { return 0; }

int ycodec_jpeg_decode_bgra(const uint8_t *data, size_t size, int width, int height, uint8_t *dst, size_t dstBytesPerRow) {
    (void)data; (void)size; (void)width; (void)height; (void)dst; (void)dstBytesPerRow;
    return -1;
}

#endif
