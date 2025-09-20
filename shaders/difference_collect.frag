#version 150 core

in vec2 vUv;
out vec4 fragColor;

uniform sampler2D uSource;
uniform ivec2 uViewportSize;
uniform ivec4 uRect;
uniform bool uUseRect;

void main() {
    ivec2 pixel = clamp(ivec2(gl_FragCoord.xy), ivec2(0), uViewportSize - ivec2(1));

    bool inside = !uUseRect || (
        pixel.x >= uRect.x && pixel.y >= uRect.y &&
        pixel.x < uRect.x + uRect.z &&
        pixel.y < uRect.y + uRect.w
    );

    if (!inside) {
        fragColor = vec4(0.0);
        return;
    }

    vec3 sample = clamp(texelFetch(uSource, pixel, 0).rgb, 0.0, 1.0);
    fragColor = vec4(sample, 1.0);
}
