#version 450
// Premultiplied colour times the layer opacity.
layout(set = 0, binding = 0) uniform sampler2D layerTexture;
layout(location = 0) in vec2 uv;
layout(location = 1) in float opacity;
layout(location = 0) out vec4 color;
void main() {
    color = texture(layerTexture, uv) * opacity;
}
