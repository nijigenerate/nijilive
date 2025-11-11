module nijilive.core.runtime_state;

import fghj : deserializeValue;
import std.exception : enforce;
import core.stdc.string : memcpy;
import nijilive.math : vec3, vec4;
import nijilive.math.camera : Camera;
import nijilive.core.param : Parameter, inParameterSetFactory;
import nijilive.core.nodes : inInitNodes;
import nijilive.core.nodes.common : inInitBlending;
import nijilive.core.nodes.drawable : inInitDrawable;
import nijilive.core.nodes.part : inInitPart;
import nijilive.core.nodes.mask : inInitMask;
import nijilive.core.nodes.composite : inInitComposite;
import nijilive.core.nodes.composite.dcomposite : inInitDComposite;
import nijilive.core.nodes.meshgroup : inInitMeshGroup;
import nijilive.core.nodes.deformer.grid : inInitGridDeformer;
import nijilive.core.nodes.deformer.path : inInitPathDeformer;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult,
    rpSetDifferenceEvaluationEnabled, rpDifferenceEvaluationEnabled,
    rpSetDifferenceEvaluationRegion, rpGetDifferenceEvaluationRegion,
    rpEvaluateDifference, rpFetchDifferenceResult;
import nijilive.core.render.backends : RenderingBackend, BackendEnum;

package(nijilive) int[] inViewportWidth;
package(nijilive) int[] inViewportHeight;
package(nijilive) vec4 inClearColor = vec4(0, 0, 0, 0);
package(nijilive) Camera[] inCamera;
vec3 inSceneAmbientLight = vec3(1, 1, 1);

private __gshared RenderingBackend!(BackendEnum.OpenGL) cachedRenderBackend;

private void ensureRenderBackend() {
    if (cachedRenderBackend is null) {
        cachedRenderBackend = new RenderingBackend!(BackendEnum.OpenGL);
    }
}

/// Push a new default camera onto the stack.
void inPushCamera() {
    inPushCamera(new Camera);
}

/// Push a provided camera instance onto the stack.
void inPushCamera(Camera camera) {
    inCamera ~= camera;
}

/// Pop the most recent camera if we have more than one.
void inPopCamera() {
    if (inCamera.length > 1) {
        inCamera.length = inCamera.length - 1;
    }
}

/// Current camera accessor (ensures at least one camera exists).
Camera inGetCamera() {
    if (inCamera.length == 0) {
        inPushCamera(new Camera);
    }
    return inCamera[$-1];
}

/// Set the current camera, falling back to push if the stack is empty.
void inSetCamera(Camera camera) {
    if (inCamera.length == 0) {
        inPushCamera(camera);
    } else {
        inCamera[$-1] = camera;
    }
}

version(unittest)
void inEnsureCameraStackForTests() {
    if (inCamera.length == 0) {
        inCamera ~= new Camera;
    }
}

/// Push viewport dimensions and sync camera stack.
void inPushViewport(int width, int height) {
    inViewportWidth ~= width;
    inViewportHeight ~= height;
    inPushCamera();
}

/// Pop viewport if we have more than one entry.
void inPopViewport() {
    if (inViewportWidth.length > 1) {
        inViewportWidth.length = inViewportWidth.length - 1;
        inViewportHeight.length = inViewportHeight.length - 1;
        inPopCamera();
    }
}

/**
    Sets the viewport dimensions (logical state + backend notification)
*/
void inSetViewport(int width, int height) {
    if (inViewportWidth.length == 0) {
        inPushViewport(width, height);
    } else {
        if (width == inViewportWidth[$-1] && height == inViewportHeight[$-1]) {
            requireRenderBackend().resizeViewportTargets(width, height);
            return;
        }
        inViewportWidth[$-1] = width;
        inViewportHeight[$-1] = height;
    }
    requireRenderBackend().resizeViewportTargets(width, height);
}

/**
    Gets the current viewport dimensions.
*/
void inGetViewport(out int width, out int height) {
    if (inViewportWidth.length == 0) {
        width = 0;
        height = 0;
        return;
    }
    width = inViewportWidth[$-1];
    height = inViewportHeight[$-1];
}

version(unittest)
void inEnsureViewportForTests(int width = 640, int height = 480) {
    if (inViewportWidth.length == 0) {
        inPushViewport(width, height);
    }
}

/// Compute viewport data size (RGBA per pixel).
size_t inViewportDataLength() {
    return inViewportWidth[$-1] * inViewportHeight[$-1] * 4;
}

/// Dump current viewport pixels (common path, backend-provided grab).
void inDumpViewport(ref ubyte[] dumpTo) {
    auto width = inViewportWidth.length ? inViewportWidth[$-1] : 0;
    auto height = inViewportHeight.length ? inViewportHeight[$-1] : 0;
    auto required = width * height * 4;
    enforce(dumpTo.length >= required, "Invalid data destination length for inDumpViewport");

    requireRenderBackend().dumpViewport(dumpTo, width, height);

    if (width == 0 || height == 0) return;
    ubyte[] tmpLine = new ubyte[width * 4];
    size_t ri = 0;
    foreach_reverse(i; height/2 .. height) {
        size_t lineSize = width * 4;
        size_t oldLineStart = lineSize * ri;
        size_t newLineStart = lineSize * i;

        memcpy(tmpLine.ptr, dumpTo.ptr + oldLineStart, lineSize);
        memcpy(dumpTo.ptr + oldLineStart, dumpTo.ptr + newLineStart, lineSize);
        memcpy(dumpTo.ptr + newLineStart, tmpLine.ptr, lineSize);

        ri++;
    }
}

/// Clear color setter.
void inSetClearColor(float r, float g, float b, float a) {
    inClearColor = vec4(r, g, b, a);
}

/// Clear color getter.
void inGetClearColor(out float r, out float g, out float b, out float a) {
    r = inClearColor.r;
    g = inClearColor.g;
    b = inClearColor.b;
    a = inClearColor.a;
}

package(nijilive) RenderingBackend!(BackendEnum.OpenGL) tryRenderBackend() {
    ensureRenderBackend();
    return cachedRenderBackend;
}

private RenderingBackend!(BackendEnum.OpenGL) requireRenderBackend() {
    auto backend = tryRenderBackend();
    enforce(backend !is null, "RenderBackend is not available.");
    return backend;
}

package(nijilive) RenderingBackend!(BackendEnum.OpenGL) currentRenderBackend() {
    return requireRenderBackend();
}

alias GLuint = uint;

version(InDoesRender) {

    private RenderingBackend!(BackendEnum.OpenGL) renderBackendOrNull() {
        return tryRenderBackend();
    }

    private GLuint handleOrZero(uint value) {
        return cast(GLuint)value;
    }

    GLuint inGetRenderImage() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.renderImageHandle());
    }

    GLuint inGetFramebuffer() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.framebufferHandle());
    }

    GLuint inGetCompositeImage() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.compositeImageHandle());
    }

    GLuint inGetCompositeFramebuffer() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.compositeFramebufferHandle());
    }

    GLuint inGetMainAlbedo() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.mainAlbedoHandle());
    }

    GLuint inGetMainEmissive() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.mainEmissiveHandle());
    }

    GLuint inGetMainBump() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.mainBumpHandle());
    }

    GLuint inGetCompositeEmissive() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.compositeEmissiveHandle());
    }

    GLuint inGetCompositeBump() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.compositeBumpHandle());
    }

    GLuint inGetBlendFramebuffer() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendFramebufferHandle());
    }

    GLuint inGetBlendAlbedo() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendAlbedoHandle());
    }

    GLuint inGetBlendEmissive() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendEmissiveHandle());
    }

    GLuint inGetBlendBump() {
        auto backend = renderBackendOrNull();
        return backend is null ? 0 : handleOrZero(backend.blendBumpHandle());
    }
} else {
    GLuint inGetRenderImage() { return 0; }
    GLuint inGetFramebuffer() { return 0; }
    GLuint inGetCompositeImage() { return 0; }
    GLuint inGetCompositeFramebuffer() { return 0; }
    GLuint inGetMainAlbedo() { return 0; }
    GLuint inGetMainEmissive() { return 0; }
    GLuint inGetMainBump() { return 0; }
    GLuint inGetCompositeEmissive() { return 0; }
    GLuint inGetCompositeBump() { return 0; }
    GLuint inGetBlendFramebuffer() { return 0; }
    GLuint inGetBlendAlbedo() { return 0; }
    GLuint inGetBlendEmissive() { return 0; }
    GLuint inGetBlendBump() { return 0; }
}

void inBeginScene() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.beginScene();
}

void inEndScene() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.endScene();
}

void inPostProcessScene() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.postProcessScene();
}

void inPostProcessingAddBasicLighting() {
    auto backend = tryRenderBackend();
    if (backend !is null) backend.addBasicLightingPostProcess();
}

package(nijilive)
void initRendererCommon() {
    inPushViewport(0, 0);

    inInitBlending();
    inInitNodes();
    inInitDrawable();
    inInitPart();
    inInitMask();
    inInitComposite();
    inInitMeshGroup();
    inInitDComposite();
    inInitGridDeformer();
    inInitPathDeformer();

    inParameterSetFactory((data) {
        Parameter param = new Parameter;
        data.deserializeValue(param);
        return param;
    });

    inSetClearColor(0, 0, 0, 0);
}

package(nijilive)
void initRenderer() {
    initRendererCommon();
    requireRenderBackend().initializeRenderer();
}

void inSetDifferenceAggregationEnabled(bool enabled) {
    rpSetDifferenceEvaluationEnabled(enabled);
}

bool inIsDifferenceAggregationEnabled() {
    return rpDifferenceEvaluationEnabled();
}

void inSetDifferenceAggregationRegion(int x, int y, int width, int height) {
    rpSetDifferenceEvaluationRegion(DifferenceEvaluationRegion(x, y, width, height));
}

DifferenceEvaluationRegion inGetDifferenceAggregationRegion() {
    return rpGetDifferenceEvaluationRegion();
}

bool inEvaluateDifferenceAggregation(uint texture, int viewportWidth, int viewportHeight) {
    return rpEvaluateDifference(texture, viewportWidth, viewportHeight);
}

bool inFetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
    return rpFetchDifferenceResult(result);
}
