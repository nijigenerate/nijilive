module nijilive.core.render.backends.opengl.drawable_buffers;

import nijilive.math : vec2, Vec2Array;

version (unittest) {
    alias GLuint = uint;

    void oglInitDrawableBackend() {}
    void oglBindDrawableVao() {}
    void oglCreateDrawableBuffers(ref GLuint vbo, ref GLuint ibo, ref GLuint dbo) {
        vbo = 0;
        ibo = 0;
        dbo = 0;
    }
    void oglUploadDrawableIndices(GLuint, ushort[]) {}
    void oglUploadDrawableVertices(GLuint, Vec2Array) {}
    void oglUploadDrawableDeform(GLuint, Vec2Array) {}
    void oglDrawDrawableElements(GLuint, size_t) {}
} else version (InDoesRender):

import bindbc.opengl;
import nijilive.core.meshdata : MeshData;
import nijilive.core.render.backends.opengl.soa_upload : glUploadFloatVecArray;

private __gshared GLuint drawableVAO;
private __gshared bool drawableBuffersInitialized = false;
void oglInitDrawableBackend() {
    if (drawableBuffersInitialized) return;
    drawableBuffersInitialized = true;
    glGenVertexArrays(1, &drawableVAO);
}

void oglBindDrawableVao() {
    oglInitDrawableBackend();
    glBindVertexArray(drawableVAO);
}

void oglCreateDrawableBuffers(ref GLuint vbo, ref GLuint ibo, ref GLuint dbo) {
    oglInitDrawableBackend();
    if (vbo == 0) glGenBuffers(1, &vbo);
    if (ibo == 0) glGenBuffers(1, &ibo);
    if (dbo == 0) glGenBuffers(1, &dbo);
}

void oglUploadDrawableIndices(GLuint ibo, ushort[] indices) {
    if (ibo == 0 || indices.length == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_STATIC_DRAW);
}

void oglUploadDrawableVertices(GLuint vbo, Vec2Array vertices) {
    glUploadFloatVecArray(vbo, vertices, GL_DYNAMIC_DRAW, "UploadVertices");
}

void oglUploadDrawableDeform(GLuint dbo, Vec2Array deformation) {
    glUploadFloatVecArray(dbo, deformation, GL_DYNAMIC_DRAW, "UploadDeform");
}

void oglDrawDrawableElements(GLuint ibo, size_t indexCount) {
    if (ibo == 0 || indexCount == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, null);
}
