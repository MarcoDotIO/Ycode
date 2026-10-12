// Ycode R8 reference fragment shader (ours, GLSL) for vkdraw.
#version 460
layout(set = 0, binding = 0) uniform texture2D textures[16];
layout(set = 0, binding = 1) uniform sampler samplers[16];
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 vcolor;
layout(location = 0) out vec4 o;
void main() { o = texture(sampler2D(textures[0], samplers[0]), uv) * vcolor; }
