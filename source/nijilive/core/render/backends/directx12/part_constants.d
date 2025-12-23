module nijilive.core.render.backends.directx12.part_constants;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import nijilive.math : mat4, vec4;

/// Constant buffer for VS
struct PartVertexConstants {
    mat4 modelMatrix;
    mat4 puppetMatrix;
    vec4 origin; // store origin in xy
}

/// Constant buffer for PS
struct PartPixelConstants {
    vec4 tint;
    vec4 screen;
    vec4 extra; // mask threshold, emission strength, etc.
}

}

}
