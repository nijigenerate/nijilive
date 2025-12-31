// Vulkan equivalent of opengl/basic/composite.frag
#version 450

layout(location = 0) in vec2 texUVs;

layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outEmissive;
layout(location = 2) out vec4 outBump;

layout(set = 0, binding = 1) uniform sampler2D albedo;
layout(set = 0, binding = 2) uniform sampler2D emissive;
layout(set = 0, binding = 3) uniform sampler2D bumpmap;

layout(set = 0, binding = 4) uniform Params {
    float opacity;
    vec3 multColor;
    vec3 screenColor;
    float emissionStrength;
} params;

vec4 screen(vec3 tcol, float a) {
    return vec4(vec3(1.0) - ((vec3(1.0) - tcol) * (vec3(1.0) - (params.screenColor * a))), a);
}

void main() {
    vec4 texColor = texture(albedo, texUVs);
    vec4 emiColor = texture(emissive, texUVs);
    vec4 bmpColor = texture(bumpmap, texUVs);

    vec4 mult = vec4(params.multColor.xyz, 1);

    vec4 albedoOut = screen(texColor.xyz, texColor.a) * mult;
    vec4 emissionOut = screen(emiColor.xyz, texColor.a) * mult;

    outAlbedo = albedoOut * params.opacity;
    outEmissive = emissionOut;
    outBump = bmpColor;
}
