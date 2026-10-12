// Ycode R8 reference vertex shader (ours, GLSL) for vkdraw: the same work
// as draw_vs in shaders/draw.metal, on the R8 PoC graphics ABI.
#version 460
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
layout(buffer_reference, std430, buffer_reference_align = 8) readonly buffer Xform { vec2 scale; vec2 offset; };
layout(push_constant) uniform PC { uint64_t vs[4]; uint64_t fs[4]; } pc;
layout(location = 0) in vec2 pos;
layout(location = 1) in vec4 color;
layout(location = 0) out vec2 uv;
layout(location = 1) out vec4 vcolor;
void main() {
    Xform x = Xform(pc.vs[1]);
    vec2 p = pos * x.scale + x.offset;
    gl_Position = vec4(p, 0.0, 1.0);
    uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    vcolor = color;
}
