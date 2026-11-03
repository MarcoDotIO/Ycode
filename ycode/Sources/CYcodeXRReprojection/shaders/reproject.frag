// Depth re-projection, fragment stage (specs/simulator/xr-depth.md §5).
// Ycode's own shader. Samples the source picture (an sRGB or half-float
// texture: filtering in linear light) or, inside the inset rectangle, the
// sharper inset (blended by its soft-edge alpha). A triangle across a depth
// edge samples at its own place while unstretched, so a picture at its own
// viewpoint shows exactly as sent; as the move stretches it over a
// disocclusion, mode 1 fills it with one colour of the background, read half a
// cell past the farthest corner, away from the nearest (inside the background:
// at the corner itself the filter still sees the near surface; the stretched
// edge, or anything read further away, shows as stripes beside every window),
// and mode 2 drops it. Mode bit 16:
// texels with alpha below 0.5 are empty (the world cache; a partly empty
// filtered texel has its colour restored from the premultiplied average); bit 32: alpha ramps to 0 over `fade` at the picture's edges (the
// fresh picture blended over the cache). With CACHE defined (the cache
// update) a second output takes the destination's inverse depth.
#version 450

layout(push_constant) uniform Params {
    mat4 m;
    vec4 tangents;
    vec4 inset;
    float near;
    float ratio;
    int gridW;
    int gridH;
    int mode;
    float fade;
    float gain;
} pc;

layout(set = 0, binding = 0) uniform sampler2D colourTex;
layout(set = 0, binding = 2) uniform sampler2D insetTex;

layout(location = 0) in vec2 uv;
layout(location = 1) flat in vec2 farUV;
layout(location = 2) flat in int stretched;
layout(location = 3) noperspective in float invDepth;
layout(location = 4) flat in float stretch;
layout(location = 5) flat in vec2 nearUV;

layout(location = 0) out vec4 outColour;
#ifdef CACHE
layout(location = 1) out float outDepth;
#endif

void main() {
    int m = pc.mode & 15;
    if (stretched != 0 && m == 2 && stretch > 1.5) discard;
    vec2 s = uv;
    if (stretched != 0 && m == 1) {
        vec2 past = clamp(farUV + (farUV - nearUV) * 0.5, vec2(0.0), vec2(1.0));
        s = mix(uv, past, clamp((stretch - 1.0) * 2.0, 0.0, 1.0));
    }
    vec4 c = texture(colourTex, s);
    if (pc.inset.z > pc.inset.x && s.x >= pc.inset.x && s.y >= pc.inset.y && s.x < pc.inset.z && s.y < pc.inset.w) {
        // The inset's alpha is its soft edge (straight alpha): the base shows through there.
        vec4 i = texture(insetTex, (s - pc.inset.xy) / (pc.inset.zw - pc.inset.xy));
        c.rgb = mix(c.rgb, i.rgb, i.a);
    }
    if ((pc.mode & 16) != 0) {
        if (c.a < 0.5) discard;
        c.rgb /= c.a;
    }
    float a = 1.0;
    if ((pc.mode & 32) != 0 && pc.fade > 0.0) {
        vec2 e = min(uv, vec2(1.0) - uv);
        a = clamp(min(e.x, e.y) / pc.fade, 0.0, 1.0);
    }
    outColour = vec4(min(c.rgb * pc.gain, vec3(1.0)), a);
#ifdef CACHE
    outDepth = invDepth;
#endif
}
