module nijilive.core.render.backends.opengl.drawable_buffers;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.meshdata : MeshData;
import nijilive.math : vec2;

private __gshared GLuint drawableVAO;
private __gshared bool drawableBuffersInitialized = false;

void initDrawableBackend() {
    if (drawableBuffersInitialized) return;
    drawableBuffersInitialized = true;
    glGenVertexArrays(1, &drawableVAO);
}

void bindDrawableVAO() {
    initDrawableBackend();
    glBindVertexArray(drawableVAO);
}

void createDrawableBuffers(ref GLuint vbo, ref GLuint ibo, ref GLuint dbo) {
    initDrawableBackend();
    if (vbo == 0) glGenBuffers(1, &vbo);
    if (ibo == 0) glGenBuffers(1, &ibo);
    if (dbo == 0) glGenBuffers(1, &dbo);
}

void uploadDrawableIndices(GLuint ibo, ushort[] indices) {
    if (ibo == 0 || indices.length == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_STATIC_DRAW);
}

void uploadDrawableVertices(GLuint vbo, vec2[] vertices) {
    if (vbo == 0 || vertices.length == 0) return;
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, vertices.length * vec2.sizeof, vertices.ptr, GL_DYNAMIC_DRAW);
}

void uploadDrawableDeform(GLuint dbo, vec2[] deformation) {
    if (dbo == 0 || deformation.length == 0) return;
    glBindBuffer(GL_ARRAY_BUFFER, dbo);
    glBufferData(GL_ARRAY_BUFFER, deformation.length * vec2.sizeof, deformation.ptr, GL_DYNAMIC_DRAW);
}

void drawDrawableElements(GLuint ibo, size_t indexCount) {
    if (ibo == 0 || indexCount == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, null);
}
