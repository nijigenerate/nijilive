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

package(nijilive) int[] inViewportWidth;
package(nijilive) int[] inViewportHeight;
package(nijilive) vec4 inClearColor = vec4(0, 0, 0, 0);
package(nijilive) Camera[] inCamera;
vec3 inSceneAmbientLight = vec3(1, 1, 1);

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
            resizeViewportBackend(width, height);
            return;
        }
        inViewportWidth[$-1] = width;
        inViewportHeight[$-1] = height;
    }
    resizeViewportBackend(width, height);
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

    dumpViewportBackend(dumpTo, width, height);

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

alias InitRendererFunc = void function();
alias ResizeViewportFunc = void function(int width, int height);
alias DumpViewportFunc = void function(ref ubyte[] data, int width, int height);

private InitRendererFunc initRendererBackend = () {};
private ResizeViewportFunc resizeViewportBackend = (int, int) {};
private DumpViewportFunc dumpViewportBackend = (ref ubyte[] data, int, int) {};

package(nijilive)
void registerRendererBackend(InitRendererFunc initFn,
                             ResizeViewportFunc resizeFn,
                             DumpViewportFunc dumpFn) {
    initRendererBackend = initFn is null ? (() {}) : initFn;
    resizeViewportBackend = resizeFn is null ? ((int, int) {}) : resizeFn;
    dumpViewportBackend = dumpFn is null ? ((ref ubyte[] data, int, int) {}) : dumpFn;
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
    initRendererBackend();
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
