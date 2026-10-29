// Pixel work of the guest capture layer: rotating and mirroring a plane
// (video data output connections with a rotation angle or mirroring), and
// bi-planar 4:2:0 to BGRA for the preview layer and stills. BT.601
// coefficients as in camera-host.md §4.2 (ITU-R BT.601).

#include <stddef.h>
#include <stdint.h>
#include <string.h>

void yc_transform_plane(const uint8_t *src, size_t srcStride, size_t width, size_t height, size_t bpe,
                        uint8_t *dst, size_t dstStride, int angle, int mirror) {
    // Output size: width x height for 0/180, height x width for 90/270.
    size_t ow = (angle == 90 || angle == 270) ? height : width;
    size_t oh = (angle == 90 || angle == 270) ? width : height;
    for (size_t oy = 0; oy < oh; oy++) {
        uint8_t *row = dst + oy * dstStride;
        for (size_t ox0 = 0; ox0 < ow; ox0++) {
            size_t ox = mirror ? ow - 1 - ox0 : ox0;
            size_t sx, sy;
            switch (angle) {
            case 90:  sx = oy; sy = height - 1 - ox; break;            // clockwise
            case 180: sx = width - 1 - ox; sy = height - 1 - oy; break;
            case 270: sx = width - 1 - oy; sy = ox; break;
            default:  sx = ox; sy = oy; break;
            }
            const uint8_t *p = src + sy * srcStride + sx * bpe;
            uint8_t *q = row + ox0 * bpe;
            for (size_t k = 0; k < bpe; k++) q[k] = p[k];
        }
    }
}

static inline uint8_t clamp8(int v) { return (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v); }

void yc_420_to_bgra(const uint8_t *y, size_t yStride, const uint8_t *cbcr, size_t cStride, size_t width, size_t height,
                    int fullRange, uint8_t *dst, size_t dstStride) {
    // 16-bit fixed point (x 65536), round to nearest.
    const int ky = fullRange ? 65536 : 76309, y0 = fullRange ? 0 : 16;
    const int rv = fullRange ? 91881 : 104597, gu = fullRange ? -22553 : -25675;
    const int gv = fullRange ? -46802 : -53279, bu = fullRange ? 116130 : 132201;
    for (size_t j = 0; j < height; j++) {
        const uint8_t *yr = y + j * yStride;
        const uint8_t *cr = cbcr + (j / 2) * cStride;
        uint8_t *o = dst + j * dstStride;
        for (size_t i = 0; i < width; i++) {
            int l = (yr[i] - y0) * ky + 32768;
            int d = cr[(i & ~(size_t)1)] - 128, e = cr[(i & ~(size_t)1) + 1] - 128;
            o[4 * i + 0] = clamp8((l + bu * d) >> 16);
            o[4 * i + 1] = clamp8((l + gu * d + gv * e) >> 16);
            o[4 * i + 2] = clamp8((l + rv * e) >> 16);
            o[4 * i + 3] = 255;
        }
    }
}
