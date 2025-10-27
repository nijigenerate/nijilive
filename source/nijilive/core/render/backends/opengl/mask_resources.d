module nijilive.core.render.backends.opengl.mask_resources;

version (unittest) {

import nijilive.core.shader;
alias GLint = int;

__gshared Shader maskShader;
__gshared GLint maskOffsetUniform;
__gshared GLint maskMvpUniform;
__gshared bool maskBackendInitialized = true;

void initMaskBackendResources() {}

} else version (InDoesRender) {

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

} else {

import nijilive.core.shader;
alias GLint = int;

__gshared Shader maskShader;
__gshared GLint maskOffsetUniform;
__gshared GLint maskMvpUniform;
__gshared bool maskBackendInitialized = false;

void initMaskBackendResources() {
    maskBackendInitialized = true;
}

}
