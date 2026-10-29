/* Pixel conversion for the host camera layer (camera-host.md §4).
 *
 * Y'CbCr to R'G'B' uses the matrices of ITU-R BT.601 and BT.709 with 16-bit
 * fixed-point coefficients (Kr/Kb of each recommendation; video range
 * scales luma by 255/219 and chroma by 255/224). Range changes map each
 * sample on its own with the same scale factors, rounding to nearest. */
#include "CYcodeCamera.h"

static inline uint8_t clamp8(int v) { return v < 0 ? 0 : v > 255 ? 255 : (uint8_t)v; }

/* Rounded division of a possibly negative numerator by a positive divisor. */
static inline int rdiv(int n, int d) { return n >= 0 ? (n + d / 2) / d : -((-n + d / 2) / d); }

uint8_t ycam_map_luma(int value, int from_full, int to_full) {
    if (from_full == to_full) return clamp8(value);
    if (from_full) return clamp8(16 + rdiv(value * 219, 255));
    return clamp8(rdiv((value - 16) * 255, 219));
}

uint8_t ycam_map_chroma(int value, int from_full, int to_full) {
    if (from_full == to_full) return clamp8(value);
    int d = value - 128;
    if (from_full) return clamp8(128 + rdiv(d * 224, 255));
    return clamp8(128 + rdiv(d * 255, 224));
}

typedef struct { int ys, yo, crR, cbG, crG, cbB; } coefficients;

static coefficients coefficients_for(int full_range, int matrix) {
    coefficients c;
    if (full_range) {
        c.ys = 65536; c.yo = 0;
        if (matrix == 709) { c.crR = 103206; c.cbG = 12276; c.crG = 30679; c.cbB = 121609; }
        else { c.crR = 91881; c.cbG = 22553; c.crG = 46802; c.cbB = 116130; }
    } else {
        c.ys = 76309; c.yo = 16;
        if (matrix == 709) { c.crR = 117489; c.cbG = 13975; c.crG = 34925; c.cbB = 138438; }
        else { c.crR = 104597; c.cbG = 25675; c.crG = 53279; c.cbB = 132201; }
    }
    return c;
}

/* (v + 0.5) >> 16 without shifting a negative value: a bias of 1024 << 16. */
#define BIAS ((1024 << 16) + 32768)
static inline uint8_t fix(int v) { return clamp8(((v + BIAS) >> 16) - 1024); }

static inline void pixel(const coefficients *c, int y, int cb, int cr, uint8_t *bgr) {
    int yy = (y - c->yo) * c->ys, d = cb - 128, e = cr - 128;
    bgr[0] = fix(yy + c->cbB * d);
    bgr[1] = fix(yy - c->cbG * d - c->crG * e);
    bgr[2] = fix(yy + c->crR * e);
}

void ycam_ycbcr_to_bgr(int y, int cb, int cr, int full_range, int matrix, uint8_t bgr[3]) {
    coefficients c = coefficients_for(full_range, matrix);
    pixel(&c, y, cb, cr, bgr);
}

void ycam_to_biplanar420(const ycam_ycbcr_source *s, uint8_t *y, size_t ystride, uint8_t *cbcr, size_t cstride,
                         int out_full_range) {
    int w = s->width, h = s->height;
    if (w <= 0 || h <= 0) return;
    uint8_t lumaMap[256], chromaMap[256];
    for (int i = 0; i < 256; i++) {
        lumaMap[i] = ycam_map_luma(i, s->full_range, out_full_range);
        chromaMap[i] = ycam_map_chroma(i, s->full_range, out_full_range);
    }
    for (int row = 0; row < h; row++) {
        const uint8_t *src = s->y + (size_t)row * s->ystride;
        uint8_t *dst = y + (size_t)row * ystride;
        if (s->ystep == 1) {
            for (int x = 0; x < w; x++) dst[x] = lumaMap[src[x]];
        } else {
            for (int x = 0, at = 0; x < w; x++, at += s->ystep) dst[x] = lumaMap[src[at]];
        }
    }
    int cw = (w + 1) / 2, ch = (h + 1) / 2;
    for (int j = 0; j < ch; j++) {
        int y0 = 2 * j, y1 = 2 * j + 1 < h ? 2 * j + 1 : h - 1;
        size_t r0 = (size_t)(y0 / s->vsub) * s->cstride, r1 = (size_t)(y1 / s->vsub) * s->cstride;
        uint8_t *dst = cbcr + (size_t)j * cstride;
        for (int i = 0; i < cw; i++) {
            int x0 = 2 * i, x1 = 2 * i + 1 < w ? 2 * i + 1 : w - 1;
            size_t a = (size_t)(x0 / s->hsub) * s->cstep, b = (size_t)(x1 / s->hsub) * s->cstep;
            int cb = s->cb[r0 + a] + s->cb[r0 + b] + s->cb[r1 + a] + s->cb[r1 + b];
            int cr = s->cr[r0 + a] + s->cr[r0 + b] + s->cr[r1 + a] + s->cr[r1 + b];
            dst[2 * i] = chromaMap[(cb + 2) >> 2];
            dst[2 * i + 1] = chromaMap[(cr + 2) >> 2];
        }
    }
}

void ycam_to_bgra(const ycam_ycbcr_source *s, uint8_t *bgra, size_t stride) {
    coefficients c = coefficients_for(s->full_range, s->matrix);
    for (int row = 0; row < s->height; row++) {
        const uint8_t *ly = s->y + (size_t)row * s->ystride;
        size_t cr0 = (size_t)(row / s->vsub) * s->cstride;
        uint8_t *dst = bgra + (size_t)row * stride;
        for (int x = 0; x < s->width; x++) {
            size_t ca = cr0 + (size_t)(x / s->hsub) * s->cstep;
            pixel(&c, ly[(size_t)x * s->ystep], s->cb[ca], s->cr[ca], dst + 4 * x);
            dst[4 * x + 3] = 255;
        }
    }
}

void ycam_bgra_downscale(const uint8_t *src, int width, int height, size_t stride, int factor, uint8_t *dst,
                         size_t dst_stride) {
    if (factor < 1) factor = 1;
    int ow = width / factor, oh = height / factor, n = factor * factor;
    for (int oy = 0; oy < oh; oy++) {
        for (int ox = 0; ox < ow; ox++) {
            int sum[4] = {0, 0, 0, 0};
            for (int dy = 0; dy < factor; dy++) {
                const uint8_t *p = src + (size_t)(oy * factor + dy) * stride + (size_t)ox * factor * 4;
                for (int dx = 0; dx < factor; dx++)
                    for (int k = 0; k < 4; k++) sum[k] += p[4 * dx + k];
            }
            uint8_t *q = dst + (size_t)oy * dst_stride + (size_t)ox * 4;
            for (int k = 0; k < 4; k++) q[k] = (uint8_t)((sum[k] + n / 2) / n);
        }
    }
}
