module nijilive.core.render.backends.directx12.part_constants;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import nijilive.math : mat4, vec4;

/// VS 用定数バッファ
struct PartVertexConstants {
    mat4 modelMatrix;
    mat4 puppetMatrix;
    vec4 origin; // xy に origin を格納
}

/// PS 用定数バッファ
struct PartPixelConstants {
    vec4 tint;
    vec4 screen;
    vec4 extra; // mask threshold や emission strength 等
}

}

}
