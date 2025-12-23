#version 150 core

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uSource;
uniform ivec2 uViewportSize;
uniform ivec4 uRect;
uniform bool uUseRect;

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (uUseRect) {
        pixel += uRect.xy;
    }
    pixel = clamp(pixel, ivec2(0), uViewportSize - ivec2(1));

    vec3 sample = clamp(texelFetch(uSource, pixel, 0).rgb, 0.0, 1.0);
    fragColor = vec4(sample, 1.0);
}
