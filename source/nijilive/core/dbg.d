module nijilive.core.dbg;

import nijilive.math : vec3, vec4, mat4, Vec3Array;
import nijilive.core.render.backends : RenderingBackend, BackendEnum;
import nijilive.core.runtime_state : inGetCamera, tryRenderBackend;

alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);

private bool debugInitialized;
private bool hasDebugBuffer;

private RenderBackend backendOrNull() {
    return tryRenderBackend();
}

private RenderBackend backendForDebug() {
    auto backend = backendOrNull();
    if (backend is null) return null;
    if (!debugInitialized) {
        backend.initDebugRenderer();
        debugInitialized = true;
    }
    return backend;
}

package(nijilive) void inInitDebug() {
    backendForDebug();
}

bool inDbgDrawMeshOutlines = false;
bool inDbgDrawMeshVertexPoints = false;
bool inDbgDrawMeshOrientation = false;

void inDbgPointsSize(float size) {
    auto backend = backendForDebug();
    if (backend !is null) {
        backend.setDebugPointSize(size);
    }
}

void inDbgLineWidth(float size) {
    auto backend = backendForDebug();
    if (backend !is null) {
        backend.setDebugLineWidth(size);
    }
}

void inDbgSetBuffer(Vec3Array points) {
    size_t vertexCount = points.length;
    size_t indexCount = vertexCount == 0 ? 0 : vertexCount + 1;
    ushort[] indices = new ushort[indexCount];
    foreach (i; 0 .. vertexCount) {
        indices[i] = cast(ushort)i;
    }
    if (indices.length) {
        indices[$ - 1] = 0;
    }
    inDbgSetBuffer(points, indices);
}

void inDbgSetBuffer(uint vbo, uint ibo, int count) {
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.setDebugExternalBuffer(vbo, ibo, count);
    hasDebugBuffer = count > 0;
}

void inDbgSetBuffer(Vec3Array points, ushort[] indices) {
    if (points.length == 0 || indices.length == 0) {
        hasDebugBuffer = false;
        return;
    }
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.uploadDebugBuffer(points, indices);
    hasDebugBuffer = true;
}

void inDbgDrawPoints(vec4 color, mat4 transform = mat4.identity) {
    if (!hasDebugBuffer) return;
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.drawDebugPoints(color, inGetCamera().matrix * transform);
}

void inDbgDrawLines(vec4 color, mat4 transform = mat4.identity) {
    if (!hasDebugBuffer) return;
    auto backend = backendForDebug();
    if (backend is null) return;
    backend.drawDebugLines(color, inGetCamera().matrix * transform);
}
