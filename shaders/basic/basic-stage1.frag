/*
    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen

    ADVANCED BLENDING - STAGE 1
*/
#version 330

// Advanced blendig mode enable
#ifdef GL_KHR_blend_equation_advanced 
#extension GL_KHR_blend_equation_advanced : enable
#endif

#ifdef GL_ARB_sample_shading
#extension GL_ARB_sample_shading : enable
#endif

in vec2 texUVs;

// Handle layout qualifiers for advanced blending specially
#ifdef GL_KHR_blend_equation_advanced 
    layout(blend_support_all_equations) out;
    layout(location = 0) out vec4 outAlbedo;
#else
    layout(location = 0) out vec4 outAlbedo;
#endif

uniform sampler2D albedo;

uniform float opacity;
uniform vec3 multColor;
uniform vec3 screenColor;

// Debug tint for GPU path deformation
uniform int pathDebugEnabled;
uniform vec3 pathDebugColor;
uniform float pathDebugStrength;
// Debug tint for GPU MeshGroup deformation
uniform int groupDebugEnabled;
uniform vec3 groupDebugColor;
uniform float groupDebugStrength;

void main() {
    // Sample texture
    vec4 texColor = texture(albedo, texUVs);

    // Screen color math
    vec3 screenOut = vec3(1.0) - ((vec3(1.0)-(texColor.xyz)) * (vec3(1.0)-(screenColor*texColor.a)));
    
    // Multiply color math + opacity application.
    outAlbedo = vec4(screenOut.xyz, texColor.a) * vec4(multColor.xyz, 1) * opacity;
    if (pathDebugEnabled == 1) {
        outAlbedo.rgb = mix(outAlbedo.rgb, pathDebugColor, clamp(pathDebugStrength, 0.0, 1.0));
    }
    if (groupDebugEnabled == 1) {
        outAlbedo.rgb = mix(outAlbedo.rgb, groupDebugColor, clamp(groupDebugStrength, 0.0, 1.0));
    }
}
