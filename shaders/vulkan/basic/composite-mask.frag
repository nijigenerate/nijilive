// Vulkan equivalent of opengl/basic/composite-mask.frag
#version 450

layout(location = 0) in vec2 texUVs;
layout(location = 0) out vec4 outColor;

layout(set = 0, binding = 1) uniform sampler2D tex;

layout(set = 0, binding = 4) uniform MaskParams {
    float threshold;
    float opacity;
} maskParams;

void main() {
    vec4 color = texture(tex, texUVs) * vec4(1, 1, 1, maskParams.opacity);
    if (color.a <= maskParams.threshold) discard;
    outColor = vec4(1, 1, 1, 1);
}
