#version 450
// OVRender compositor: one textured quad per layer (OVVulkanCompositor).
// The quad covers the layer's pixels; the affine transform maps layer pixel
// coordinates to target pixel coordinates.
layout(push_constant) uniform Push {
    vec4 m0;      // a, c, tx, opacity      (x' = a*x + c*y + tx)
    vec4 m1;      // b, d, ty, unused       (y' = b*x + d*y + ty)
    vec4 sizes;   // layer width, height, target width, height
} pc;
layout(location = 0) out vec2 uv;
layout(location = 1) out float opacity;
void main() {
    vec2 corner = vec2(float(gl_VertexIndex & 1), float((gl_VertexIndex >> 1) & 1));
    vec2 p = corner * pc.sizes.xy;
    vec2 q = vec2(pc.m0.x * p.x + pc.m0.y * p.y + pc.m0.z, pc.m1.x * p.x + pc.m1.y * p.y + pc.m1.z);
    gl_Position = vec4(q / pc.sizes.zw * 2.0 - 1.0, 0.0, 1.0);
    uv = corner;
    opacity = pc.m0.w;
}
