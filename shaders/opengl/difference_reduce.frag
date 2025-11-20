#version 150 core

out vec4 fragColor;

uniform sampler2D uSource;
uniform ivec2 uSourceSize;

vec4 fetchPixel(ivec2 coord) {
    if (coord.x < 0 || coord.y < 0 || coord.x >= uSourceSize.x || coord.y >= uSourceSize.y) {
        return vec4(0.0);
    }
    return texelFetch(uSource, coord, 0);
}

void main() {
    ivec2 dst = ivec2(gl_FragCoord.xy);
    ivec2 base = dst * 2;

    vec4 sum = vec4(0.0);
    sum += fetchPixel(base);
    sum += fetchPixel(base + ivec2(1, 0));
    sum += fetchPixel(base + ivec2(0, 1));
    sum += fetchPixel(base + ivec2(1, 1));

    fragColor = sum;
}
