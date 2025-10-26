module nijilive.core.render.backends.opengl.mask_resources;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.shader;

__gshared Shader maskShader;
__gshared GLint maskOffsetUniform;
__gshared GLint maskMvpUniform;
__gshared bool maskBackendInitialized = false;

void initMaskBackendResources() {
    if (maskBackendInitialized) return;
    maskBackendInitialized = true;

    maskShader = new Shader(import("mask.vert"), import("mask.frag"));
    maskOffsetUniform = maskShader.getUniformLocation("offset");
    maskMvpUniform = maskShader.getUniformLocation("mvp");
}
