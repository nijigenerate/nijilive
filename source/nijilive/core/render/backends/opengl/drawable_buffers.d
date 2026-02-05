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
private __gshared GLuint sharedIndexBuffer;
private __gshared size_t sharedIndexCapacity;
private __gshared size_t sharedIndexOffset;
private __gshared RenderResourceHandle nextIndexHandle = 1;

private struct IndexRange {
    size_t offset;
    size_t count;
    size_t capacity;
    ushort[] data;
}
private __gshared IndexRange[RenderResourceHandle] sharedIndexRanges;

private void ensureSharedIndexBuffer(size_t bytes) {
    if (sharedIndexBuffer == 0) {
        glGenBuffers(1, &sharedIndexBuffer);
        sharedIndexCapacity = 0;
        sharedIndexOffset = 0;
    }
    if (bytes > sharedIndexCapacity) {
        // Grow to next power-of-two-ish to reduce realloc churn.
        size_t newCap = sharedIndexCapacity == 0 ? 1024 : sharedIndexCapacity;
        while (newCap < bytes) newCap *= 2;
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, newCap, null, GL_DYNAMIC_DRAW);
        sharedIndexCapacity = newCap;
        sharedIndexOffset = 0;
        // Re-upload all cached index data.
        foreach (key, ref entry; sharedIndexRanges) {
            if (entry.data.length == 0) continue;
            auto entryBytes = cast(size_t)entry.data.length * ushort.sizeof;
            entry.offset = sharedIndexOffset;
            entry.count = entry.data.length;
            entry.capacity = entryBytes;
            glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, cast(GLintptr)entry.offset, entryBytes, entry.data.ptr);
            sharedIndexOffset += entryBytes;
        }
    }
}
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
    if (ibo == 0) {
        ibo = nextIndexHandle++;
    }
}

void oglUploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
    if (ibo == 0 || indices.length == 0) return;
    auto bytes = cast(size_t)indices.length * ushort.sizeof;
    ensureSharedIndexBuffer(bytes + sharedIndexOffset);

    IndexRange range;
    auto existing = ibo in sharedIndexRanges;
    if (existing !is null) {
        range = *existing;
    }
    if (existing is null || bytes > range.capacity) {
        // Allocate new slice in the shared IBO.
        range.offset = sharedIndexOffset;
        range.count = indices.length;
        range.capacity = bytes;
        sharedIndexOffset += bytes;
    } else {
        range.count = indices.length;
    }
    range.data = indices.dup;
    sharedIndexRanges[ibo] = range;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
    glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, cast(GLintptr)range.offset, bytes, indices.ptr);
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
    if (ibo == 0 || indexCount == 0) return;
    auto rangePtr = ibo in sharedIndexRanges;
    if (rangePtr is null || sharedIndexBuffer == 0) return;
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sharedIndexBuffer);
    auto offset = rangePtr.offset;
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, cast(void*)offset);
}
