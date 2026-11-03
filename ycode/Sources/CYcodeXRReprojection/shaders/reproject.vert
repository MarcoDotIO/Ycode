// Depth re-projection, vertex stage (specs/simulator/xr-depth.md §5).
// Ycode's own shader. A grid over the source picture, one vertex per corner
// of each triangle (no vertex buffer: everything follows from
// gl_VertexIndex). Each vertex is the source pixel's point in homogeneous
// view coordinates, (tan x, tan y, -1, d / near) with d the inverse-depth
// sample (q / 65535 = near / z): a point at infinity (d = 0) has w = 0 and
// re-projects by rotation only. One matrix takes it to the destination eye's
// clip space (reverse-Z, infinite far).
//
// Each vertex reads its triangle's three depths, so a triangle across a
// depth edge (farthest / nearest distance above `ratio`) is known to every
// one of its vertices: it spans a depth edge. How far the move has stretched
// it is measured against the same triangle flat at the far corner's depth (at
// the picture's own viewpoint the two coincide, and the factor is 1). Modes 1
// and 2 push it to the background's depth so real surfaces win; mode 1 samples
// the picture at its own place when unstretched, and one colour of the background
// as it stretches over the disoccluded area; mode 2 drops it once stretched
// (what lies under shows), and keeps it, sharp, until then; mode 0 keeps the
// plain rubber sheet.
#version 450

layout(push_constant) uniform Params {
    mat4 m;          // source homogeneous view point -> destination clip
    vec4 tangents;   // source projection: left, right, up, down (left, down negative)
    vec4 inset;      // inset rectangle in source uv (x0, y0, x1, y1); x1 <= x0: none
    float near;      // source near distance (m)
    float ratio;     // depth-edge threshold (distance ratio)
    int gridW;       // grid points per row and column
    int gridH;
    int mode;        // 0 stretch, 1 background, 2 discard; + 16: alpha test, + 32: edge fade, + 64: no windows layer, + 128: only the windows layer
    float fade;      // edge fade width (uv) when mode has 32
    float gain;      // colour gain (the environment's exposure)
} pc;

layout(set = 0, binding = 1) uniform sampler2D depthTex;

layout(location = 0) out vec2 uv;
layout(location = 1) flat out vec2 farUV;
layout(location = 2) flat out int stretched;
// The destination's inverse depth relative to the destination near, screen-linear
// (the cache update writes it; xr-depth.md §5.3).
layout(location = 3) noperspective out float invDepth;
// How far the move stretched a triangle across a depth edge (1: not at all).
layout(location = 4) flat out float stretch;
layout(location = 5) flat out vec2 nearUV;

vec4 sourcePoint(vec2 u, float d) {
    float tx = pc.tangents.x + u.x * (pc.tangents.y - pc.tangents.x);
    float ty = pc.tangents.z - u.y * (pc.tangents.z - pc.tangents.w);
    return vec4(tx, ty, -1.0, d / pc.near);
}

void main() {
    int tri = gl_VertexIndex / 3;
    int corner = gl_VertexIndex - tri * 3;
    int cell = tri >> 1;
    int second = tri & 1;
    int cw = pc.gridW - 1;
    int cx = cell % cw;
    int cy = cell / cw;
    ivec2 c[3];
    if (second == 0) {
        c[0] = ivec2(cx, cy); c[1] = ivec2(cx, cy + 1); c[2] = ivec2(cx + 1, cy);
    } else {
        c[0] = ivec2(cx + 1, cy); c[1] = ivec2(cx, cy + 1); c[2] = ivec2(cx + 1, cy + 1);
    }
    ivec2 size = textureSize(depthTex, 0);
    vec2 scale = vec2(1.0 / float(pc.gridW - 1), 1.0 / float(pc.gridH - 1));
    float d[3];
    vec2 u[3];
    for (int i = 0; i < 3; i++) {
        u[i] = vec2(c[i]) * scale;
        ivec2 t = min(ivec2(u[i] * vec2(size)), size - ivec2(1));
        d[i] = texelFetch(depthTex, t, 0).r;
    }
    float dmax = max(d[0], max(d[1], d[2]));
    float dmin = min(d[0], min(d[1], d[2]));
    int far = d[0] <= d[1] ? (d[0] <= d[2] ? 0 : 2) : (d[1] <= d[2] ? 1 : 2);
    int nearest = d[0] >= d[1] ? (d[0] >= d[2] ? 0 : 2) : (d[1] >= d[2] ? 1 : 2);
    // In inverse depth: distance ratio = dmax / dmin.
    bool edge = dmax > dmin * pc.ratio + 1.0e-6;

    // The low bit of a picture's depth marks the windows layer (xr-depth.md
    // §3.1). Bit 64: its triangles are left out; bit 128: only they are drawn.
    if ((pc.mode & (64 | 128)) != 0) {
        bool window = false;
        for (int i = 0; i < 3; i++) window = window || (int(d[i] * 65535.0 + 0.5) & 1) != 0;
        if (((pc.mode & 64) != 0 && window) || ((pc.mode & 128) != 0 && !window)) {
            gl_Position = vec4(0.0, 0.0, 0.0, 1.0);    // all three corners: nothing is rasterised
            invDepth = 0.0;
            uv = vec2(0.0);
            farUV = vec2(0.0);
            nearUV = vec2(0.0);
            stretched = 0;
            stretch = 1.0;
            return;
        }
    }
    vec4 p = pc.m * sourcePoint(u[corner], d[corner]);
    int m = pc.mode & 15;
    stretch = 1.0;
    if (edge && (m == 1 || m == 2)) {
        vec4 f = pc.m * sourcePoint(u[far], d[far]);
        if (f.w > 0.0) p.z = (f.z / f.w) * 0.999 * p.w;
        // The longest side against the same side with all corners at the far depth.
        vec2 q[3], r[3];
        bool visible = true;
        for (int i = 0; i < 3; i++) {
            vec4 a = pc.m * sourcePoint(u[i], d[i]);
            vec4 b = pc.m * sourcePoint(u[i], d[far]);
            visible = visible && a.w > 1.0e-6 && b.w > 1.0e-6;
            q[i] = a.xy / max(a.w, 1.0e-6);
            r[i] = b.xy / max(b.w, 1.0e-6);
        }
        if (visible) {
            for (int i = 0; i < 3; i++) {
                int k = (i + 1) % 3;
                float flat_ = length(r[k] - r[i]);
                stretch = max(stretch, length(q[k] - q[i]) / max(flat_, 1.0e-6));
            }
        } else {
            stretch = 1.0e6;
        }
    }
    gl_Position = p;
    invDepth = p.w > 0.0 ? p.z / p.w : 0.0;
    uv = u[corner];
    farUV = u[far];
    nearUV = u[nearest];
    stretched = edge ? 1 : 0;
}
