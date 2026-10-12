// gpu-data.h: test inputs shared by the Mac oracle (mtl-oracle.m) and the
// Thor runner (airc-gpu.c), so both sides compute on identical data.
#pragma once

#include <stdint.h>
#include <string.h>

#define GD_VERTEX_STRIDE 16

static inline void gd_add_inputs(float *a, float *b, uint32_t n) {
    for (uint32_t i = 0; i < n; i++) {
        a[i] = (float)i;
        b[i] = 2.0f * (float)i + 0.5f;
    }
}

// 64 records of struct Pair { float4 a; uint2 b; float c; } (32 bytes).
static inline void gd_pairs(uint32_t *w) {
    for (uint32_t r = 0; r < 64; r++)
        for (uint32_t k = 0; k < 8; k++) {
            uint32_t v = r * 8 + k;
            float f = (float)v * 0.25f;
            if (k < 4) memcpy(&w[r * 8 + k], &f, 4);
            else if (k < 6) w[r * 8 + k] = v * 3u + 1u;
            else if (k == 6) { f = (float)v * 0.5f; memcpy(&w[r * 8 + k], &f, 4); }
            else w[r * 8 + k] = 0;
        }
}

// Texture 0: 16 x 16 RGBA32F, texel (x, y) = (x, y, x + y, 1) / 16 (alpha 1).
static inline void gd_tex0(float *t) {
    for (int y = 0; y < 16; y++)
        for (int x = 0; x < 16; x++) {
            float *p = t + (y * 16 + x) * 4;
            p[0] = (float)x / 16.0f;
            p[1] = (float)y / 16.0f;
            p[2] = (float)(x + y) / 16.0f;
            p[3] = 1.0f;
        }
}

// Texture 2: 16 x 16 R32Uint, texel (x, y) = x * 16 + y.
static inline void gd_tex2(uint32_t *t) {
    for (int y = 0; y < 16; y++)
        for (int x = 0; x < 16; x++) t[y * 16 + x] = (uint32_t)(x * 16 + y);
}

// Texture 3: 4 x 4 x 4 RGBA8Unorm, texel (x, y, z) = (60x, 60y, 60z, 255).
static inline void gd_tex3(uint8_t *t) {
    for (int z = 0; z < 4; z++)
        for (int y = 0; y < 4; y++)
            for (int x = 0; x < 4; x++) {
                uint8_t *p = t + ((z * 4 + y) * 4 + x) * 4;
                p[0] = (uint8_t)(60 * x);
                p[1] = (uint8_t)(60 * y);
                p[2] = (uint8_t)(60 * z);
                p[3] = 255;
            }
}

static inline uint16_t gd_half(float f) {
    // Exact for the values used here (multiples of 1/4 in [0, 1]).
    uint32_t b;
    memcpy(&b, &f, 4);
    if (f == 0.0f) return 0;
    uint32_t e = ((b >> 23) & 0xff) - 127 + 15, m = (b >> 13) & 0x3ff;
    return (uint16_t)((e << 10) | m);
}

// Render test: a quad as a triangle strip; per vertex float2 position at
// offset 0 and half4 colour at offset 8 (stride 16).
static inline void gd_vertices(uint8_t *v) {
    static const float pos[4][2] = {{-0.75f, -0.75f}, {0.75f, -0.75f}, {-0.75f, 0.75f}, {0.75f, 0.75f}};
    static const float col[4][4] = {{1.0f, 0.5f, 0.25f, 1.0f}, {0.5f, 1.0f, 0.5f, 1.0f}, {0.25f, 0.5f, 1.0f, 1.0f}, {1.0f, 1.0f, 1.0f, 1.0f}};
    for (int i = 0; i < 4; i++) {
        memcpy(v + i * GD_VERTEX_STRIDE, pos[i], 8);
        for (int c = 0; c < 4; c++) {
            uint16_t h = gd_half(col[i][c]);
            memcpy(v + i * GD_VERTEX_STRIDE + 8 + c * 2, &h, 2);
        }
    }
}

// Render test texture: 8 x 8 RGBA8Unorm, texel (x, y) = (32x, 32y, 128, 255).
static inline void gd_draw_texture(uint8_t *t) {
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++) {
            uint8_t *p = t + (y * 8 + x) * 4;
            p[0] = (uint8_t)(32 * x);
            p[1] = (uint8_t)(32 * y);
            p[2] = 128;
            p[3] = 255;
        }
}

// Argument-buffer test data: 256 floats.
static inline void gd_argbuf_data(float *d) {
    for (int i = 0; i < 256; i++) d[i] = (float)i * 0.5f;
}
