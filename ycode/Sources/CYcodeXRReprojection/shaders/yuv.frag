// A video picture's YUV → RGB conversion on the GPU (display-stream.md §14).
// Ycode's own shader. BT.709 limited range, what NVENC's BGRA input is
// converted with and its VUI says; the same matrix as yvid_nv12_to_bgrx. The
// target is an sRGB attachment, so the gamma-encoded result is decoded first
// and the attachment encodes it again, to the same 8-bit code. NV12's chroma
// is sampled bilinearly; 4:4:4's samples are read exactly at their texels.
#version 450

layout(push_constant) uniform Params {
    mat4 m;
    vec4 tangents;
    vec4 inset;
    float near;
    float ratio;
    int gridW;
    int gridH;
    int mode;        // 0 NV12 (binding 1 interleaved UV), 1 planar 4:4:4 (binding 1 U, binding 2 V)
    float fade;
    float gain;
} pc;

layout(set = 0, binding = 0) uniform sampler2D yTex;
layout(set = 0, binding = 1) uniform sampler2D uTex;
layout(set = 0, binding = 2) uniform sampler2D vTex;

layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 outColour;

vec3 toLinear(vec3 c) {
    vec3 low = c / 12.92;
    vec3 high = pow((c + 0.055) / 1.055, vec3(2.4));
    return mix(high, low, lessThanEqual(c, vec3(0.04045)));
}

void main() {
    float y = texture(yTex, uv).r;
    float u, v;
    if (pc.mode == 1) {
        u = texture(uTex, uv).r;
        v = texture(vTex, uv).r;
    } else {
        vec2 c = texture(uTex, uv).rg;
        u = c.x;
        v = c.y;
    }
    float c = (y * 255.0 - 16.0) * (298.0 / 256.0);
    float d = u * 255.0 - 128.0;
    float e = v * 255.0 - 128.0;
    vec3 rgb = vec3(c + (459.0 / 256.0) * e, c - (55.0 / 256.0) * d - (136.0 / 256.0) * e, c + (541.0 / 256.0) * d) / 255.0;
    outColour = vec4(toLinear(clamp(rgb, 0.0, 1.0)), 1.0);
}
