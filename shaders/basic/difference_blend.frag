/*
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
*/
#version 330

in vec2 texUVs;

layout(location = 0) out vec4 outAlbedo;
layout(location = 1) out vec4 outEmissive;
layout(location = 2) out vec4 outBump;

// Background Textures
uniform sampler2D bg_albedo;
uniform sampler2D bg_emissive;
uniform sampler2D bg_bump;

// Foreground Textures
uniform sampler2D fg_albedo;
uniform sampler2D fg_emissive;
uniform sampler2D fg_bump;

uniform vec2 viewport_size;

void main() {
    // 1. Get Foreground Color + Tints (from basic.frag logic)
    vec4 fg_albedo_color = texture(fg_albedo, texUVs);
    // Note: Tints are applied in the part shader before drawing to fBuffer
    // So fg_albedo already contains the tinted part color.

    // 2. Get Background Color from the current fragment's position
    vec2 bg_uv = gl_FragCoord.xy / viewport_size;
    vec4 bg_albedo_color = texture(bg_albedo, bg_uv);

    // 3. Blend Albedo
    outAlbedo = abs(fg_albedo_color - bg_albedo_color);
    outAlbedo.a = fg_albedo_color.a;

    // 4. Pass through Emissive and Bumpmap from the foreground part
    outEmissive = texture(fg_emissive, texUVs);
    outBump = texture(fg_bump, texUVs);
}
