module nijilive.core.render.backends.opengl.drawable_buffers;

import nijilive.math : vec2, Vec2Array;
import nijilive.core.render.backends : RenderResourceHandle;

version (unittest) {
    alias GLuint = uint;

    void oglInitDrawableBackend() {}
    void oglBindDrawableVao() {}
    void oglCreateDrawableBuffers(ref RenderResourceHandle ibo) {
        ibo = 0;
    }
    void oglUploadDrawableIndices(RenderResourceHandle, ushort[]) {}
    void oglUploadSharedVertexBuffer(Vec2Array) {}
    void oglUploadSharedUvBuffer(Vec2Array) {}
    void oglUploadSharedDeformBuffer(Vec2Array) {}
    GLuint oglGetSharedVertexBuffer() { return 0; }
    GLuint oglGetSharedUvBuffer() { return 0; }
    GLuint oglGetSharedDeformBuffer() { return 0; }
    void oglDrawDrawableElements(GLuint, size_t) {}
} else version (InDoesRender):

import bindbc.opengl;
import nijilive.core.render.backends.opengl.soa_upload : glUploadFloatVecArray;

private __gshared GLuint drawableVAO;
private __gshared bool drawableBuffersInitialized = false;
private __gshared GLuint sharedDeformBuffer;
private __gshared GLuint sharedVertexBuffer;
private __gshared GLuint sharedUvBuffer;
void oglInitDrawableBackend() {
    if (drawableBuffersInitialized) return;
    drawableBuffersInitialized = true;
    glGenVertexArrays(1, &drawableVAO);
}

void oglBindDrawableVao() {
    oglInitDrawableBackend();
    glBindVertexArray(drawableVAO);
}

void oglCreateDrawableBuffers(ref RenderResourceHandle ibo) {
    oglInitDrawableBackend();
    auto handle = cast(GLuint)ibo;
    if (handle == 0) glGenBuffers(1, &handle);
    ibo = cast(RenderResourceHandle)handle;
}

void oglUploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
    auto handle = cast(GLuint)ibo;
    if (handle == 0 || indices.length == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, handle);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_STATIC_DRAW);
}

void oglUploadSharedVertexBuffer(Vec2Array vertices) {
    if (vertices.length == 0) {
        return;
    }
    if (sharedVertexBuffer == 0) {
        glGenBuffers(1, &sharedVertexBuffer);
    }
    glUploadFloatVecArray(sharedVertexBuffer, vertices, GL_DYNAMIC_DRAW, "UploadVertices");
}

void oglUploadSharedUvBuffer(Vec2Array uvs) {
    if (uvs.length == 0) {
        return;
    }
    if (sharedUvBuffer == 0) {
        glGenBuffers(1, &sharedUvBuffer);
    }
    glUploadFloatVecArray(sharedUvBuffer, uvs, GL_DYNAMIC_DRAW, "UploadUV");
}

void oglUploadSharedDeformBuffer(Vec2Array deformation) {
    if (deformation.length == 0) {
        return;
    }
    if (sharedDeformBuffer == 0) {
        glGenBuffers(1, &sharedDeformBuffer);
    }
    glUploadFloatVecArray(sharedDeformBuffer, deformation, GL_DYNAMIC_DRAW, "UploadDeform");
}

GLuint oglGetSharedVertexBuffer() {
    if (sharedVertexBuffer == 0) {
        glGenBuffers(1, &sharedVertexBuffer);
    }
    return sharedVertexBuffer;
}

GLuint oglGetSharedUvBuffer() {
    if (sharedUvBuffer == 0) {
        glGenBuffers(1, &sharedUvBuffer);
    }
    return sharedUvBuffer;
}

GLuint oglGetSharedDeformBuffer() {
    if (sharedDeformBuffer == 0) {
        glGenBuffers(1, &sharedDeformBuffer);
    }
    return sharedDeformBuffer;
}

void oglDrawDrawableElements(RenderResourceHandle ibo, size_t indexCount) {
    auto handle = cast(GLuint)ibo;
    if (handle == 0 || indexCount == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, handle);
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, null);
}
