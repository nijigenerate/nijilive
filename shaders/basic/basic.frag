/*
    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
#version 330
in vec2 texUVs;

layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outEmissive;
layout(location = 2) out vec4 outBump;

uniform sampler2D albedo;
uniform sampler2D emissive;
uniform sampler2D bumpmap;

uniform float opacity;
uniform vec3 multColor;
uniform vec3 screenColor;
uniform float emissionStrength = 1;

// Debug tint for GPU path deformation
uniform int pathDebugEnabled;
uniform vec3 pathDebugColor;
uniform float pathDebugStrength;
// Debug tint for GPU MeshGroup deformation
uniform int groupDebugEnabled;
uniform vec3 groupDebugColor;
uniform float groupDebugStrength;

vec4 screen(vec3 tcol, float a) {
    return vec4(vec3(1.0) - ((vec3(1.0)-tcol) * (vec3(1.0)-(screenColor*a))), a);
}

void main() {
    // Sample texture
    vec4 texColor = texture(albedo, texUVs);
    vec4 emiColor = texture(emissive, texUVs);
    vec4 bmpColor = texture(bumpmap, texUVs);

    vec4 mult = vec4(multColor.xyz, 1);

    // Out color math
    vec4 albedoOut = screen(texColor.xyz, texColor.a) * mult;
    vec4 emissionOut = screen(emiColor.xyz, texColor.a) * mult * emissionStrength;
    
    // Albedo
    outAlbedo = albedoOut * opacity;
    if (pathDebugEnabled == 1) {
        outAlbedo.rgb = mix(outAlbedo.rgb, pathDebugColor, clamp(pathDebugStrength, 0.0, 1.0));
    }
    if (groupDebugEnabled == 1) {
        outAlbedo.rgb = mix(outAlbedo.rgb, groupDebugColor, clamp(groupDebugStrength, 0.0, 1.0));
    }

    // Emissive
    outEmissive = emissionOut * outAlbedo.a;

    // Bumpmap
    outBump = bmpColor * outAlbedo.a;
}
