/* A baseline JPEG decoder of our own (camera-host.md §4.3), written from
 * ITU-T T.81 (ISO/IEC 10918-1): sequential DCT, Huffman coding, 8-bit
 * samples, 1 or 3 components with sampling factors 1 or 2, interleaved or
 * single-component scans, restart intervals. Motion-JPEG frames from UVC
 * cameras may leave out DHT; the tables of T.81 Annex K.3 are then used.
 * Output: one plane per component at its own sampling (no upsampling, no
 * colour conversion; convert.c does that). */
#include "CYcodeCamera.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

enum { ERR_DATA = -1, ERR_UNSUPPORTED = -2, ERR_MEMORY = -3 };

typedef struct {
    int present;
    uint8_t lookup_len[512]; /* 9-bit fast path: code length (0: slow path) */
    uint8_t lookup_val[512];
    int32_t maxcode[18];     /* largest code of each length, -1 when none */
    int32_t valptr[17];
    int32_t mincode[17];
    uint8_t values[256];
} huffman;

typedef struct {
    int id, h, v, tq;
    int dc_table, ac_table;
    int dc_pred;
    uint8_t *plane;
    int stride, rows;
    int bw, bh; /* blocks covering the component (without MCU padding) */
} component;

struct ycam_jpeg {
    uint16_t q[4][64]; /* in zigzag order */
    int q_present[4];
    huffman dc[4], ac[4];
    component comp[3];
    int ncomp, width, height, hmax, vmax, mcux, mcuy;
    int restart;
    uint8_t *buffer;
    size_t capacity;
    /* bit reader */
    const uint8_t *p, *end;
    uint64_t bits;
    int nbits;
    int marker_hit;
    float aan[64];     /* AAN prescale, natural order: s(u) s(v) / 8, s(0) = 1, s(k) = sqrt 2 cos(k pi/16) */
    float qf[4][64];   /* dequantizers with the prescale, natural order */
};

static const uint8_t zigzag[64] = {
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,  12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6,  7,  14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23,
    30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63};

/* T.81 Annex K.3, tables K.3 to K.6. */
static const uint8_t k3_dc_luma_bits[16] = {0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0};
static const uint8_t k4_dc_chroma_bits[16] = {0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0};
static const uint8_t k3_dc_values[12] = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11};
static const uint8_t k5_ac_luma_bits[16] = {0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d};
static const uint8_t k5_ac_luma_values[162] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, 0x22, 0x71,
    0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0, 0x24, 0x33, 0x62, 0x72,
    0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x34, 0x35, 0x36, 0x37,
    0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
    0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83,
    0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3,
    0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa};
static const uint8_t k6_ac_chroma_bits[16] = {0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77};
static const uint8_t k6_ac_chroma_values[162] = {
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, 0x13, 0x22,
    0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0, 0x15, 0x62, 0x72, 0xd1,
    0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x35, 0x36,
    0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58,
    0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,
    0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a,
    0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba,
    0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9, 0xfa};

/* Builds the canonical code (T.81 Annex C) and the 9-bit fast table. */
static int build_huffman(huffman *t, const uint8_t bits[16], const uint8_t *values) {
    int total = 0;
    for (int i = 0; i < 16; i++) total += bits[i];
    if (total > 256) return ERR_DATA;
    memcpy(t->values, values, (size_t)total);
    memset(t->lookup_len, 0, sizeof t->lookup_len);
    int32_t code = 0;
    int k = 0;
    for (int len = 1; len <= 16; len++) {
        int n = bits[len - 1];
        t->valptr[len] = k;
        t->mincode[len] = code;
        if (n == 0) {
            t->maxcode[len] = -1;
        } else {
            for (int i = 0; i < n; i++, k++, code++) {
                if (len <= 9) {
                    int shift = 9 - len, first = code << shift;
                    for (int j = 0; j < (1 << shift); j++) {
                        t->lookup_len[first + j] = (uint8_t)len;
                        t->lookup_val[first + j] = values[k];
                    }
                }
            }
            t->maxcode[len] = code - 1;
            if (code - 1 >= (1 << len)) return ERR_DATA;
        }
        code <<= 1;
    }
    t->maxcode[17] = 0x7fffffff;
    t->present = 1;
    return 0;
}

static ycam_jpeg *ensure_defaults(ycam_jpeg *d) {
    build_huffman(&d->dc[0], k3_dc_luma_bits, k3_dc_values);
    build_huffman(&d->dc[1], k4_dc_chroma_bits, k3_dc_values);
    build_huffman(&d->ac[0], k5_ac_luma_bits, k5_ac_luma_values);
    build_huffman(&d->ac[1], k6_ac_chroma_bits, k6_ac_chroma_values);
    return d;
}

ycam_jpeg *ycam_jpeg_new(void) {
    ycam_jpeg *d = calloc(1, sizeof *d);
    if (!d) return NULL;
    double scale[8] = {1};
    for (int k = 1; k < 8; k++) scale[k] = sqrt(2.0) * cos(k * M_PI / 16.0);
    for (int v = 0; v < 8; v++)
        for (int u = 0; u < 8; u++) d->aan[8 * v + u] = (float)(scale[u] * scale[v] / 8.0);
    return d;
}

void ycam_jpeg_free(ycam_jpeg *d) {
    if (!d) return;
    free(d->buffer);
    free(d);
}

/* MARK: Bit reader (F.2.2.5: 0xFF is followed by a stuffed 0x00) */

static inline void fill(ycam_jpeg *d) {
    while (d->nbits <= 56) {
        uint8_t byte = 0;
        if (!d->marker_hit && d->p < d->end) {
            byte = *d->p;
            if (byte == 0xFF) {
                uint8_t next = d->p + 1 < d->end ? d->p[1] : 0xD9;
                if (next == 0x00) {
                    d->p += 2;
                } else {
                    d->marker_hit = 1; /* leave the marker in place; read zeros */
                    byte = 0;
                }
            } else {
                d->p++;
            }
        }
        d->bits |= (uint64_t)byte << (56 - d->nbits);
        d->nbits += 8;
    }
}

static inline int get_bits(ycam_jpeg *d, int n) {
    if (n == 0) return 0;
    if (d->nbits < n) fill(d);
    int v = (int)(d->bits >> (64 - n));
    d->bits <<= n;
    d->nbits -= n;
    return v;
}

static inline int decode_symbol(ycam_jpeg *d, const huffman *t) {
    if (d->nbits < 16) fill(d);
    int peek = (int)(d->bits >> 55);
    int len = t->lookup_len[peek];
    if (len) {
        d->bits <<= len;
        d->nbits -= len;
        return t->lookup_val[peek];
    }
    int32_t code = (int32_t)(d->bits >> 54); /* 10 bits */
    for (len = 10; len <= 16; len++) {
        if (code <= t->maxcode[len]) {
            d->bits <<= len;
            d->nbits -= len;
            int at = t->valptr[len] + code - t->mincode[len];
            return at >= 0 && at < 256 ? t->values[at] : -1;
        }
        code = (int32_t)(d->bits >> (63 - len));
    }
    return -1;
}

static inline int extend(int v, int s) { return v < (1 << (s - 1)) ? v - (1 << s) + 1 : v; }

/* MARK: Blocks */

/* One 8-point pass of the scaled IDCT of Arai, Agui and Nakajima (inputs
 * prescaled by `aan`), reading every `is`-th input and writing every
 * `os`-th output. */
static inline void idct_pass(const float *i, int is, float *o, int os) {
    float t0 = i[0], t1 = i[2 * is], t2 = i[4 * is], t3 = i[6 * is];
    float t10 = t0 + t2, t11 = t0 - t2, t13 = t1 + t3, t12 = (t1 - t3) * 1.414213562f - t13;
    t0 = t10 + t13;
    t3 = t10 - t13;
    t1 = t11 + t12;
    t2 = t11 - t12;
    float t4 = i[is], t5 = i[3 * is], t6 = i[5 * is], t7 = i[7 * is];
    float z13 = t6 + t5, z10 = t6 - t5, z11 = t4 + t7, z12 = t4 - t7;
    t7 = z11 + z13;
    float o11 = (z11 - z13) * 1.414213562f;
    float z5 = (z10 + z12) * 1.847759065f;
    float o10 = 1.082392200f * z12 - z5;
    float o12 = -2.613125930f * z10 + z5;
    t6 = o12 - t7;
    t5 = o11 - t6;
    t4 = o10 + t5;
    o[0] = t0 + t7;
    o[7 * os] = t0 - t7;
    o[os] = t1 + t6;
    o[6 * os] = t1 - t6;
    o[2 * os] = t2 + t5;
    o[5 * os] = t2 - t5;
    o[4 * os] = t3 + t4;
    o[3 * os] = t3 - t4;
}

/* The inverse DCT of a prescaled block (natural order), level-shifted by
 * 128 and clamped (T.81 A.3.3). */
static void idct_store(const float in[64], uint8_t *out, int stride) {
    float tmp[64], row[8];
    for (int u = 0; u < 8; u++) {
        const float *col = in + u;
        if (col[8] == 0 && col[16] == 0 && col[24] == 0 && col[32] == 0 && col[40] == 0 && col[48] == 0 && col[56] == 0) {
            for (int y = 0; y < 8; y++) tmp[8 * y + u] = col[0];
        } else {
            idct_pass(col, 8, tmp + u, 8);
        }
    }
    for (int y = 0; y < 8; y++) {
        idct_pass(tmp + 8 * y, 1, row, 1);
        uint8_t *o = out + (size_t)y * stride;
        for (int x = 0; x < 8; x++) {
            float v = row[x] + 128.5f;
            o[x] = v <= 0 ? 0 : v >= 255 ? 255 : (uint8_t)v;
        }
    }
}

static int decode_block(ycam_jpeg *d, component *c, uint8_t *out) {
    float coef[64];
    memset(coef, 0, sizeof coef);
    const float *q = d->qf[c->tq];
    int s = decode_symbol(d, &d->dc[c->dc_table]);
    if (s < 0 || s > 11) return ERR_DATA;
    int diff = s ? extend(get_bits(d, s), s) : 0;
    c->dc_pred += diff;
    coef[0] = (float)c->dc_pred * q[0];
    for (int k = 1; k < 64;) {
        int rs = decode_symbol(d, &d->ac[c->ac_table]);
        if (rs < 0) return ERR_DATA;
        int r = rs >> 4, size = rs & 15;
        if (size == 0) {
            if (r != 15) break; /* EOB */
            k += 16;
            continue;
        }
        k += r;
        if (k > 63) return ERR_DATA;
        coef[zigzag[k]] = (float)extend(get_bits(d, size), size) * q[zigzag[k]];
        k++;
    }
    idct_store(coef, out, c->stride);
    return 0;
}

/* MARK: Segments */

static inline int u16(const uint8_t *p) { return p[0] << 8 | p[1]; }

static int read_dqt(ycam_jpeg *d, const uint8_t *p, int len) {
    while (len > 0) {
        int pq = p[0] >> 4, tq = p[0] & 15;
        int n = pq ? 129 : 65;
        if (tq > 3 || len < n) return ERR_DATA;
        for (int i = 0; i < 64; i++) {
            d->q[tq][i] = pq ? (uint16_t)u16(p + 1 + 2 * i) : p[1 + i];
            d->qf[tq][zigzag[i]] = (float)d->q[tq][i] * d->aan[zigzag[i]];
        }
        d->q_present[tq] = 1;
        p += n;
        len -= n;
    }
    return 0;
}

static int read_dht(ycam_jpeg *d, const uint8_t *p, int len) {
    while (len > 0) {
        if (len < 17) return ERR_DATA;
        int tc = p[0] >> 4, th = p[0] & 15, total = 0;
        if (tc > 1 || th > 3) return ERR_DATA;
        for (int i = 0; i < 16; i++) total += p[1 + i];
        if (len < 17 + total || total > 256) return ERR_DATA;
        int r = build_huffman(tc ? &d->ac[th] : &d->dc[th], p + 1, p + 17);
        if (r) return r;
        p += 17 + total;
        len -= 17 + total;
    }
    return 0;
}

static int read_sof(ycam_jpeg *d, const uint8_t *p, int len) {
    if (len < 6) return ERR_DATA;
    if (p[0] != 8) return ERR_UNSUPPORTED;
    d->height = u16(p + 1);
    d->width = u16(p + 3);
    d->ncomp = p[5];
    if (d->width == 0 || d->height == 0) return ERR_UNSUPPORTED; /* DNL not supported */
    if (d->ncomp != 1 && d->ncomp != 3) return ERR_UNSUPPORTED;
    if (len < 6 + 3 * d->ncomp) return ERR_DATA;
    d->hmax = d->vmax = 1;
    for (int i = 0; i < d->ncomp; i++) {
        component *c = &d->comp[i];
        c->id = p[6 + 3 * i];
        c->h = p[7 + 3 * i] >> 4;
        c->v = p[7 + 3 * i] & 15;
        c->tq = p[8 + 3 * i];
        if (c->h < 1 || c->h > 2 || c->v < 1 || c->v > 2 || c->tq > 3) return ERR_UNSUPPORTED;
        if (c->h > d->hmax) d->hmax = c->h;
        if (c->v > d->vmax) d->vmax = c->v;
    }
    d->mcux = (d->width + 8 * d->hmax - 1) / (8 * d->hmax);
    d->mcuy = (d->height + 8 * d->vmax - 1) / (8 * d->vmax);
    size_t total = 0;
    for (int i = 0; i < d->ncomp; i++) {
        component *c = &d->comp[i];
        c->stride = d->mcux * c->h * 8;
        c->rows = d->mcuy * c->v * 8;
        int cw = (d->width * c->h + d->hmax - 1) / d->hmax, ch = (d->height * c->v + d->vmax - 1) / d->vmax;
        c->bw = (cw + 7) / 8;
        c->bh = (ch + 7) / 8;
        total += (size_t)c->stride * c->rows;
    }
    if (total > d->capacity) {
        uint8_t *b = realloc(d->buffer, total);
        if (!b) return ERR_MEMORY;
        d->buffer = b;
        d->capacity = total;
    }
    uint8_t *at = d->buffer;
    for (int i = 0; i < d->ncomp; i++) {
        d->comp[i].plane = at;
        at += (size_t)d->comp[i].stride * d->comp[i].rows;
    }
    return 0;
}

/* Restart (F.2.2.5): drop the bit buffer, expect RSTn, reset DC predictions. */
static int restart(ycam_jpeg *d) {
    d->bits = 0;
    d->nbits = 0;
    d->marker_hit = 0;
    while (d->p + 1 < d->end && !(d->p[0] == 0xFF && d->p[1] >= 0xD0 && d->p[1] <= 0xD7)) d->p++;
    if (d->p + 1 >= d->end) return ERR_DATA;
    d->p += 2;
    for (int i = 0; i < d->ncomp; i++) d->comp[i].dc_pred = 0;
    return 0;
}

/* One scan; *consumed is how far the entropy-coded data went. */
static int read_scan(ycam_jpeg *d, const uint8_t *p, int len, const uint8_t *data_end, const uint8_t **after) {
    if (d->ncomp == 0 || len < 1) return ERR_DATA;
    int ns = p[0];
    if (ns < 1 || ns > d->ncomp || len < 1 + 2 * ns + 3) return ERR_DATA;
    component *scan[3];
    for (int i = 0; i < ns; i++) {
        int id = p[1 + 2 * i], tables = p[2 + 2 * i];
        component *c = NULL;
        for (int j = 0; j < d->ncomp; j++) if (d->comp[j].id == id) c = &d->comp[j];
        if (!c) return ERR_DATA;
        c->dc_table = tables >> 4;
        c->ac_table = tables & 15;
        if (c->dc_table > 3 || c->ac_table > 3) return ERR_DATA;
        if (!d->dc[c->dc_table].present || !d->ac[c->ac_table].present || !d->q_present[c->tq]) return ERR_DATA;
        c->dc_pred = 0;
        scan[i] = c;
    }
    d->p = p + len;
    d->end = data_end;
    d->bits = 0;
    d->nbits = 0;
    d->marker_hit = 0;
    int r, count = 0;
    if (ns == 1) {
        component *c = scan[0];
        for (int by = 0; by < c->bh; by++)
            for (int bx = 0; bx < c->bw; bx++) {
                if (d->restart && count > 0 && count % d->restart == 0 && (r = restart(d))) return r;
                if ((r = decode_block(d, c, c->plane + (size_t)by * 8 * c->stride + bx * 8))) return r;
                count++;
            }
    } else {
        for (int my = 0; my < d->mcuy; my++)
            for (int mx = 0; mx < d->mcux; mx++) {
                if (d->restart && count > 0 && count % d->restart == 0 && (r = restart(d))) return r;
                for (int i = 0; i < ns; i++) {
                    component *c = scan[i];
                    for (int v = 0; v < c->v; v++)
                        for (int h = 0; h < c->h; h++) {
                            uint8_t *out = c->plane + (size_t)((my * c->v + v) * 8) * c->stride + (mx * c->h + h) * 8;
                            if ((r = decode_block(d, c, out))) return r;
                        }
                }
                count++;
            }
    }
    /* Skip to the next marker that is not a stuffed byte or a restart. */
    const uint8_t *q = d->p;
    while (q + 1 < data_end && !(q[0] == 0xFF && q[1] != 0x00 && !(q[1] >= 0xD0 && q[1] <= 0xD7))) q++;
    *after = q;
    return 0;
}

int ycam_jpeg_decode(ycam_jpeg *d, const uint8_t *data, size_t size) {
    if (!d || !data || size < 4 || data[0] != 0xFF || data[1] != 0xD8) return ERR_DATA;
    ensure_defaults(d); /* a stream's DHT replaces them */
    memset(d->q_present, 0, sizeof d->q_present);
    d->ncomp = 0;
    d->restart = 0;
    int frame = 0, scans = 0;
    const uint8_t *p = data + 2, *end = data + size;
    while (p + 1 < end) {
        if (p[0] != 0xFF) { p++; continue; }
        int marker = p[1];
        p += 2;
        if (marker == 0xFF || marker == 0x00 || (marker >= 0xD0 && marker <= 0xD7)) { if (marker == 0xFF) p--; continue; }
        if (marker == 0xD9) break; /* EOI */
        if (p + 2 > end) return ERR_DATA;
        int len = u16(p) - 2;
        if (len < 0 || p + 2 + len > end) return ERR_DATA;
        const uint8_t *body = p + 2;
        int r = 0;
        switch (marker) {
        case 0xC0: case 0xC1:
            r = read_sof(d, body, len);
            frame = 1;
            break;
        case 0xC2: case 0xC3: case 0xC5: case 0xC6: case 0xC7: case 0xC9: case 0xCA: case 0xCB: case 0xCD:
        case 0xCE: case 0xCF:
            return ERR_UNSUPPORTED;
        case 0xC4: r = read_dht(d, body, len); break;
        case 0xDB: r = read_dqt(d, body, len); break;
        case 0xDD: if (len < 2) return ERR_DATA; d->restart = u16(body); break;
        case 0xDA: {
            if (!frame) return ERR_DATA;
            const uint8_t *after = end;
            r = read_scan(d, body, len, end, &after);
            if (r) return r;
            scans++;
            p = after;
            continue;
        }
        default: break; /* APPn, COM, DNL, ... */
        }
        if (r) return r;
        p = body + len;
    }
    return frame && scans ? 0 : ERR_DATA;
}

void ycam_jpeg_image_info(const ycam_jpeg *d, ycam_jpeg_image *out) {
    memset(out, 0, sizeof *out);
    out->width = d->width;
    out->height = d->height;
    out->components = d->ncomp;
    out->hmax = d->hmax;
    out->vmax = d->vmax;
    for (int i = 0; i < d->ncomp && i < 3; i++) {
        out->h[i] = d->comp[i].h;
        out->v[i] = d->comp[i].v;
        out->plane[i] = d->comp[i].plane;
        out->stride[i] = d->comp[i].stride;
    }
}
