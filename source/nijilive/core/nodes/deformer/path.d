module nijilive.core.nodes.deformer.path;

import nijilive.fmt.serialize;
import nijilive.math;
import nijilive.core.nodes;
import nijilive.core.nodes.utils;
import nijilive.core.nodes.defstack;
public import nijilive.core.nodes.deformer.drivers.phys;
public import nijilive.core.nodes.deformer.curve;
import nijilive.core.nodes.deformer.base;
import nijilive.core.nodes.deformer.grid;
import inmath.linalg;

//import std.stdio;
import std.math : sqrt, isNaN, isFinite;
import std.algorithm;
import std.array;
import std.range;
import std.typecons;
import std.format : formattedWrite;
import std.stdio : writeln;
import nijilive.core;
import nijilive.core.render.scheduler : RenderContext;
import nijilive.core.dbg;
import core.exception;

enum CurveType {
    Bezier,
    Spline
}

enum PhysicsType {
    Pendulum,
    SpringPendulum
}

package(nijilive) {
    void inInitPathDeformer() {
        inRegisterNodeType!PathDeformer;
        inAliasNodeType!(PathDeformer, "BezierDeformer");
    }
}


@TypeId("PathDeformer")
class PathDeformer : Deformable, NodeFilter, Deformer {
    mixin NodeFilterMixin;
protected:
    mat4 inverseMatrix;
    PhysicsDriver _driver;
    enum float curveReferenceEpsilon = 1e-6f;
    enum float curveCollapseRatio = 1e-3f;
    enum float tangentEpsilon = 1e-8f;
    enum float segmentDegeneracyEpsilon = 1e-6f;
    enum size_t invalidDisableThreshold = 10;

    bool hasDegenerateBaseline = false;
    size_t[] degenerateSegmentIndices;
    size_t frameCounter = 0;
    size_t invalidFrameCount = 0;
    size_t consecutiveInvalidFrames = 0;
    size_t totalMatrixInvalidCount = 0;
    bool invalidThisFrame = false;
    bool matrixInvalidThisFrame = false;
    bool diagnosticsFrameActive = false;
    size_t[] invalidTotalPerIndex;
    size_t[] invalidConsecutivePerIndex;
    bool[] invalidIndexThisFrame;

    vec2[] getVertices(Node node) {
        vec2[] vertices;
        if (auto drawable = cast(Deformable)node) {
            vertices = drawable.vertices;
        } else {
            vertices = [node.transform.translation.xy];
        }
        return vertices;
    }

    void cacheClosestPoints(Node node, int nSamples = 100) {
        auto vertices = getVertices(node);
        meshCaches[node] = new float[vertices.length];

        if (prevCurve) {
            mat4 forwardMatrix = node.transform.matrix;
            mat4 inverseMatrix = transform.matrix.inverse;
            mat4 tran = inverseMatrix * forwardMatrix;
            foreach (i, vertex; getVertices(node)) {
                vec2 cVertex = (tran * vec4(vertex, 0, 1)).xy;
                meshCaches[node][i] = prevCurve.closestPoint(cVertex, nSamples);
            }
        }
    }

    void deform(vec2[] deformedControlPoints) {
        deformedCurve = createCurve(deformedControlPoints);
    }

    private
    float computeCurveScale(const(vec2)[] points) {
        float scale = 0;
        foreach (pt; points) {
            if (isNaN(pt.x) || isNaN(pt.y)) continue;
            float magnitude = sqrt(pt.x * pt.x + pt.y * pt.y);
            if (magnitude > scale) {
                scale = magnitude;
            }
        }
        return scale;
    }

    private
    string summarizePoints(const(vec2)[] points, size_t maxCount = 4) {
        auto buffer = appender!string();
        formattedWrite(buffer, "len=%s [", points.length);
        size_t limit = points.length < maxCount ? points.length : maxCount;
        foreach (i; 0 .. limit) {
            auto pt = points[i];
            formattedWrite(buffer, "(%.4f, %.4f)", pt.x, pt.y);
            if (i + 1 < limit) buffer.put(", ");
        }
        if (points.length > maxCount) {
            buffer.put(", ...");
        }
        buffer.put("]");
        return buffer.data;
    }

    private
    string formatVec2(const(vec2) value) {
        auto buffer = appender!string();
        formattedWrite(buffer, "(%.4f, %.4f)", value.x, value.y);
        return buffer.data;
    }

    private
    bool guardFinite(vec2 value) {
        return value.x.isFinite && value.y.isFinite;
    }

    private
    bool hasInvalidOffsets(string context, const(vec2)[] values, out size_t invalidIndex, out vec2 invalidValue) {
        ensureDiagnosticCapacity(deformation.length);
        foreach (idx, value; values) {
            if (!value.isFinite) {
                invalidIndex = idx;
                invalidValue = value;
                markInvalidOffset(context, idx, value);
                return true;
            }
        }
        invalidIndex = size_t.max;
        invalidValue = vec2(0, 0);
        return false;
    }

    private
    void handleInvalidDeformation(string context, const vec2[] fallback) {
        writeln("[PathDeformer][InvalidDeformation] node=", name,
                " context=", context,
                " driverActive=", _driver !is null,
                " frame=", frameCounter,
                " consecutiveInvalidFrames=", consecutiveInvalidFrames + 1);
        invalidThisFrame = true;
        if (fallback !is null && fallback.length == deformation.length) {
            deformation = fallback.dup;
        }
    }

    private
    bool matrixIsFinite(const mat4 matrix) {
        foreach (i; 0 .. 4) {
            foreach (j; 0 .. 4) {
                if (!isFinite(matrix[i][j])) {
                    return false;
                }
            }
        }
        return true;
    }

    private
    string matrixSummary(const mat4 matrix) {
        auto buffer = appender!string();
        buffer.put("[");
        foreach (i; 0 .. 4) {
            buffer.put("[");
            foreach (j; 0 .. 4) {
                formattedWrite(buffer, "%.3f", matrix[i][j]);
                if (j < 3) buffer.put(", ");
            }
            buffer.put("]");
            if (i < 3) buffer.put(", ");
        }
        buffer.put("]");
        return buffer.data;
    }

    private
    mat4 safeInverse(mat4 matrix, string context) {
        auto inv = matrix.inverse;
        if (!matrixIsFinite(inv)) {
            writeln("[PathDeformer][MatrixDiag] node=", name,
                    " context=", context,
                    " matrixInvalid=", !matrixIsFinite(matrix),
                    " matrix=", matrixSummary(matrix));
            if (!matrixInvalidThisFrame) {
                totalMatrixInvalidCount++;
            }
            matrixInvalidThisFrame = true;
            invalidThisFrame = true;
            return mat4.identity;
        }
        return inv;
    }

    private
    mat4 requireFiniteMatrix(mat4 matrix, string context) {
        if (!matrixIsFinite(matrix)) {
            writeln("[PathDeformer][MatrixDiag] node=", name,
                    " context=", context,
                    " matrix=", matrixSummary(matrix));
            if (!matrixInvalidThisFrame) {
                totalMatrixInvalidCount++;
            }
            matrixInvalidThisFrame = true;
            invalidThisFrame = true;
            return mat4.identity;
        }
        return matrix;
    }

    private
    void refreshInverseMatrix(string context) {
        auto globalMatrix = requireFiniteMatrix(globalTransform.matrix, context ~ ":global");
        inverseMatrix = safeInverse(globalMatrix, context ~ ":inverse");
    }

    private
    bool logCurveHealth(string context, Curve reference, Curve target, const(vec2)[] deformationSnapshot) {
        if (target is null) return false;

        const(vec2)[] targetPoints = target.controlPoints;
        bool hasNaN = false;
        foreach (pt; targetPoints) {
            if (isNaN(pt.x) || isNaN(pt.y)) {
                hasNaN = true;
                break;
            }
        }

        float targetScale = computeCurveScale(targetPoints);
        float referenceScale = 0;
        const(vec2)[] referencePoints;
        if (reference !is null) {
            referencePoints = reference.controlPoints;
            referenceScale = computeCurveScale(referencePoints);
        }

        bool collapsed = false;
        if (reference !is null && referenceScale > curveReferenceEpsilon) {
            collapsed = targetScale < referenceScale * curveCollapseRatio;
        }

        if (hasNaN || collapsed) {
            writeln("[PathDeformer][CurveDiag] node=", name,
                    " context=", context,
                    " collapsed=", collapsed,
                    " hasNaN=", hasNaN,
                    " refScale=", referenceScale,
                    " targetScale=", targetScale,
                    " refPoints=", summarizePoints(referencePoints),
                    " targetPoints=", summarizePoints(targetPoints),
                    " deformation=", summarizePoints(deformationSnapshot));
            return true;
        }
        return false;
    }

    private
    void logCurveState(string context) {
        const(vec2)[] deformationSnapshot = deformation;
        bool logged = false;
        if (originalCurve !is null && prevCurve !is null) {
            logged = logCurveHealth(context ~ ":prev", originalCurve, prevCurve, deformationSnapshot) || logged;
        } else if (prevCurve !is null) {
            logged = logCurveHealth(context ~ ":prev", null, prevCurve, deformationSnapshot) || logged;
        }
        if (originalCurve !is null && deformedCurve !is null) {
            logged = logCurveHealth(context ~ ":deformed", originalCurve, deformedCurve, deformationSnapshot) || logged;
        } else if (deformedCurve !is null) {
            logged = logCurveHealth(context ~ ":deformed", null, deformedCurve, deformationSnapshot) || logged;
        }
        if (!logged && prevCurve !is null && deformedCurve !is null) {
            logCurveHealth(context ~ ":diff", prevCurve, deformedCurve, deformationSnapshot);
        }
    }

    private
    void ensureDiagnosticCapacity(size_t length) {
        if (invalidIndexThisFrame.length != length) {
            invalidIndexThisFrame.length = length;
            invalidConsecutivePerIndex.length = length;
            invalidTotalPerIndex.length = length;
            foreach (ref flag; invalidIndexThisFrame) flag = false;
            foreach (ref val; invalidConsecutivePerIndex) val = 0;
            foreach (ref val; invalidTotalPerIndex) val = 0;
        }
    }

    private
    bool beginDiagnosticFrame() {
        if (diagnosticsFrameActive) {
            return false;
        }
        diagnosticsFrameActive = true;
        frameCounter++;
        ensureDiagnosticCapacity(deformation.length);
        foreach (ref flag; invalidIndexThisFrame) flag = false;
        invalidThisFrame = false;
        matrixInvalidThisFrame = false;
        return true;
    }

    private
    void markInvalidOffset(string context, size_t index, vec2 value) {
        if (!diagnosticsFrameActive) {
            beginDiagnosticFrame();
        }
        ensureDiagnosticCapacity(deformation.length);
        invalidThisFrame = true;
            if (index < invalidIndexThisFrame.length) {
                invalidIndexThisFrame[index] = true;
                invalidTotalPerIndex[index]++;
                invalidConsecutivePerIndex[index]++;
                writeln("[PathDeformer][InvalidDeformation] node=", name,
                    " context=", context,
                    " index=", index,
                    " value=", formatVec2(value),
                    " frame=", frameCounter,
                    " indexConsecutive=", invalidConsecutivePerIndex[index],
                    " indexTotal=", invalidTotalPerIndex[index],
                    " driverActive=", _driver !is null);
                if (_driver !is null && invalidConsecutivePerIndex[index] >= invalidDisableThreshold) {
                    disablePhysicsDriver(context ~ ":threshold");
                }
            } else {
                writeln("[PathDeformer][InvalidDeformation] node=", name,
                        " context=", context,
                        " index=", index,
                        " value=", formatVec2(value),
                        " frame=", frameCounter,
                    " driverActive=", _driver !is null);
        }
    }

    private
    void endDiagnosticFrame() {
        if (!diagnosticsFrameActive) {
            return;
        }
        if (invalidThisFrame || matrixInvalidThisFrame) {
            invalidFrameCount++;
            consecutiveInvalidFrames++;
        } else if (consecutiveInvalidFrames > 0) {
            writeln("[PathDeformer][InvalidDeformationRecovered] node=", name,
                    " frame=", frameCounter,
                    " lastedFrames=", consecutiveInvalidFrames);
            consecutiveInvalidFrames = 0;
        }

        if (matrixInvalidThisFrame) {
            writeln("[PathDeformer][MatrixInvalidFrame] node=", name,
                    " frame=", frameCounter,
                    " totalMatrixInvalidFrames=", totalMatrixInvalidCount);
        }

        foreach (i; 0 .. invalidConsecutivePerIndex.length) {
            if (!invalidIndexThisFrame[i] && invalidConsecutivePerIndex[i] > 0) {
                writeln("[PathDeformer][InvalidDeformationRecovered] node=", name,
                        " index=", i,
                        " frame=", frameCounter,
                        " lastedFrames=", invalidConsecutivePerIndex[i],
                        " totalInvalid=", invalidTotalPerIndex[i]);
                invalidConsecutivePerIndex[i] = 0;
            }
        }
        invalidThisFrame = false;
        matrixInvalidThisFrame = false;
        diagnosticsFrameActive = false;
    }

    private
    void checkBaselineDegeneracy(const(vec2)[] points) {
        hasDegenerateBaseline = false;
        degenerateSegmentIndices.length = 0;
        if (points.length < 2) return;

        auto buffer = appender!string();
        foreach (i; 1 .. points.length) {
            auto delta = points[i] - points[i - 1];
            float segLen = sqrt(delta.x * delta.x + delta.y * delta.y);
            if (!isFinite(segLen) || segLen <= segmentDegeneracyEpsilon) {
                if (!hasDegenerateBaseline) buffer.put("[");
                else buffer.put(", ");
                formattedWrite(buffer, "%s->%s", i - 1, i);
                degenerateSegmentIndices ~= i - 1;
                hasDegenerateBaseline = true;
            }
        }
        if (hasDegenerateBaseline) {
            buffer.put("]");
            writeln("[PathDeformer][DegenerateBaseline] node=", name,
                    " segments=", buffer.data,
                    " epsilon=", segmentDegeneracyEpsilon,
                    " points=", summarizePoints(points));
            disablePhysicsDriver("degenerateBaseline");
        }
    }

    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);
        if (physicsOnly) {
            serializer.putKey("physics_only");
            serializer.serializeValue(physicsOnly);
        }
        serializer.putKey("curve_type");
        serializer.serializeValue(curveType);
        if (flags & SerializeNodeFlags.Geometry) {
            serializer.putKey("vertices");
            auto state = serializer.listBegin();
            if (originalCurve) {
                foreach(vertex; originalCurve.controlPoints) {
                    serializer.elemBegin;
                    serializer.serializeValue(vertex.x);
                    serializer.elemBegin;
                    serializer.serializeValue(vertex.y);
                }
            }
            serializer.listEnd(state);
        }
        // physics driver is a link to another resource → Links category
        if ((flags & SerializeNodeFlags.Links) && _driver !is null) {
            serializer.putKey("physics");
            serializer.serializeValue(_driver);
        }
        serializer.putKey("dynamic_deformation");
        serializer.serializeValue(dynamic);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        super.deserializeFromFghj(data);

        if (!data["physics_only"].isEmpty)
            if (auto exc = data["physics_only"].deserializeValue(physicsOnly)) return exc;

        if (!data["curve_type"].isEmpty)
            if (auto exc = data["curve_type"].deserializeValue(curveType)) return exc;

        dynamic = false; // Should be set to false by default for compatibility.
        if (!data["dynamic_deformation"].isEmpty)
            if (auto exc = data["dynamic_deformation"].deserializeValue(dynamic)) return exc;

        auto elements = data["vertices"].byElement;
        vec2[] controlPoints;
        while(!elements.empty) {
            float x;
            float y;
            elements.front.deserializeValue(x);
            elements.popFront;
            elements.front.deserializeValue(y);
            elements.popFront;
            controlPoints ~= vec2(x, y);
        }
        rebuffer(controlPoints);

        if (!data["physics"].isEmpty) {
            string type;
            data["physics", "type"].deserializeValue(type);
            switch (type) {
            case "Pendulum":
                auto phys = new ConnectedPendulumDriver(this);
                data["physics"].deserializeValue(phys);
                driver = phys;
                break;
            case "SpringPendulum":
                auto spring = new ConnectedSpringPendulumDriver(this);
                data["physics"].deserializeValue(spring);
                driver = spring;
                break;
            default:
                break;
            }
        }

        return null;
    }

public:
    CurveType curveType;
    PhysicsType physicsType;
    Curve originalCurve;
    Curve prevCurve;
    Curve deformedCurve;
    bool dynamic = false;

    vec2 prevRoot;
    bool prevRootSet;
    bool driverInitialized = false;
    float[][Node] meshCaches;
    bool physicsOnly = false;

    Curve createCurve(vec2[] points) {
        if (curveType == CurveType.Bezier) {
            return new BezierCurve(points);
        } else {
            return new SplineCurve(points);
        }
    }

    PhysicsDriver createPhysics() {
        if (hasDegenerateBaseline) {
            writeln("[PathDeformer][PhysicsDisabled] node=", name,
                    " reason=degenerateBaseline");
            return null;
        }
        switch (physicsType) {
        case PhysicsType.SpringPendulum:
            return new ConnectedSpringPendulumDriver(this);
        default:
            return new ConnectedPendulumDriver(this);
        }
    }

    override
    ref vec2[] vertices() {
        return originalCurve.controlPoints;
    }

    this(Node parent = null, CurveType curveType = CurveType.Spline) {
        super(parent);
        this.curveType = curveType;
        originalCurve = createCurve([]);
        deformedCurve = createCurve([]);
        driver = null;
        prevRootSet = false;
    }

    override
    string typeId() { return "PathDeformer"; }

    override
    void rebuffer(vec2[] originalControlPoints) {

        this.originalCurve = createCurve(originalControlPoints);
        this.deformedCurve = createCurve(originalControlPoints);
        this.deformation.length = originalControlPoints.length;
        clearCache();
        driverInitialized = false;
        prevCurve = originalCurve;
        ensureDiagnosticCapacity(this.deformation.length);
        checkBaselineDegeneracy(originalCurve.controlPoints);
        logCurveState("rebuffer");
    }

    void driver(PhysicsDriver d) {
        if (_driver is d) {
            if (_driver !is null) {
                if (hasDegenerateBaseline) {
                    disablePhysicsDriver("degenerateBaseline");
                } else {
                    _driver.retarget(this);
                }
            }
            return;
        }
        _driver = d;
        driverInitialized = false;
        prevRootSet = false;
        if (_driver !is null) {
            if (hasDegenerateBaseline) {
                disablePhysicsDriver("degenerateBaseline");
            } else {
                _driver.retarget(this);
            }
        }
        clearCache();
    }
    auto driver() {
        return _driver;
    }

    private
    void disablePhysicsDriver(string reason) {
        if (_driver is null) return;
        writeln("[PathDeformer][PhysicsDisabled] node=", name,
                " reason=", reason,
                " driverType=", _driver.classinfo.name);
        _driver = null;
        driverInitialized = false;
        prevRootSet = false;
        physicsOnly = false;
        foreach (ref offset; deformation) {
            offset = vec2(0, 0);
        }
    }
    package(nijilive)
    void reportPhysicsDegeneracy(string reason) {
        disablePhysicsDriver(reason);
    }
    package(nijilive)
    void reportDriverInvalid(string context, size_t index, vec2 value) {
        markInvalidOffset(context, index, value);
    }

    override
    protected void runPreProcessTask() {
        // Child filters consume inverseMatrix during super.runPreProcessTask();
        // ensure it reflects this frame's transform before they run.
        if (diagnosticsFrameActive) {
            endDiagnosticFrame();
        }
        beginDiagnosticFrame();
        this.transform();
        refreshInverseMatrix("runPreProcessTask:initial");
        auto origDeform = deformation.dup;
        super.runPreProcessTask();
        applyPathDeform(origDeform);
    }

    override
    protected void runDynamicTask() {
        super.runDynamicTask();
    }

    private void applyPathDeform(const vec2[] origDeform) {
        // Ensure global transform is fresh before using cached matrix values.
        this.transform();
        refreshInverseMatrix("applyPathDeform:pre");
        size_t invalidIndex;
        vec2 invalidValue;
        if (hasInvalidOffsets("applyPathDeform:deformationInput", deformation, invalidIndex, invalidValue)) {
            handleInvalidDeformation("applyPathDeform:deformationInput", origDeform);
            return;
        }

        if (driver) {
            vec2[] baseline = (origDeform.length == deformation.length) ? origDeform.dup : deformation.dup;
            if (hasInvalidOffsets("applyPathDeform:baseline", baseline, invalidIndex, invalidValue)) {
                handleInvalidDeformation("applyPathDeform:baseline", origDeform);
                return;
            }
            if (!driverInitialized && driver !is null && puppet !is null && puppet.enableDrivers ) {
                driver.setup();
                if (driver is null) {
                    handleInvalidDeformation("applyPathDeform:setupDisabled", origDeform);
                    return;
                }
                driverInitialized = true;
            }
            vec2[] diffDeform = zip(baseline, deformation).map!((t) => t[1] - t[0]).array;
            if (hasInvalidOffsets("applyPathDeform:diffDeform", diffDeform, invalidIndex, invalidValue)) {
                handleInvalidDeformation("applyPathDeform:diffDeform", origDeform);
                return;
            }

            if (vertices.length >= 2) {
                prevCurve = createCurve(zip(vertices(), diffDeform).map!((t) => t[0] + t[1] ).array);
                clearCache();
                logCurveHealth("applyPathDeform:driverPrev", originalCurve, prevCurve, deformation);
                if (driver !is null && puppet !is null && puppet.enableDrivers)
                    driver.updateDefaultShape();
                if (driver is null) {
                    handleInvalidDeformation("applyPathDeform:updateDefaultShapeDisabled", origDeform);
                    return;
                }
                if (driver !is null && puppet !is null && puppet.enableDrivers) {
                    vec2 root;
                    mat4 transformMatrix = requireFiniteMatrix(transform.matrix, "applyPathDeform:transform");
                    if (deformation.length > 0)
                        root = (transformMatrix * vec4(vertices[0] + deformation[0], 0, 1)).xy;
                    else
                        root = vec2(0, 0);
                    if (!guardFinite(root)) {
                        handleInvalidDeformation("applyPathDeform:root", origDeform);
                        disablePhysicsDriver("applyPathDeform:root");
                        return;
                    }
                    if (prevRootSet) {
                        vec2 deform = root - prevRoot;
                        if (!guardFinite(deform)) {
                            handleInvalidDeformation("applyPathDeform:deformVector", origDeform);
                            disablePhysicsDriver("applyPathDeform:deformVector");
                            return;
                        }
                        driver.reset();
                        driver.enforce(deform);
                        driver.rotate(transform.rotation.z);
                        if (physicsOnly) { // Tentative solution.
                            vec2[] prevDeform = deformation.dup;
                            driver.update();
                            if (driver is null) {
                                handleInvalidDeformation("applyPathDeform:updateDisabled", origDeform);
                                return;
                            }
                            prevCurve = createCurve(vertices());
                            logCurveHealth("applyPathDeform:physicsPrev", originalCurve, prevCurve, deformation);
                            deformation = zip(deformation, prevDeform).map!(t=>t[0] - t[1]).array;
                            if (hasInvalidOffsets("applyPathDeform:physicsRestore", deformation, invalidIndex, invalidValue)) {
                                handleInvalidDeformation("applyPathDeform:physicsRestore", prevDeform);
                                return;
                            }
                        } else
                            driver.update();
                        if (driver is null) {
                            handleInvalidDeformation("applyPathDeform:updateDisabled", origDeform);
                            return;
                        }
                    }
                    prevRoot = root;
                    prevRootSet = true;
                }

                auto candidate = zip(vertices(), deformation).map!((t) => t[0] + t[1]).array;
                if (hasInvalidOffsets("applyPathDeform:driverCandidate", candidate, invalidIndex, invalidValue)) {
                    handleInvalidDeformation("applyPathDeform:driverCandidate", baseline);
                    return;
                }
                deform(candidate);
                logCurveState("applyPathDeform");
            }
            refreshInverseMatrix("applyPathDeform:postDriver");
        } else {

            if (vertices.length >= 2) {
                // driver なしの場合は純粋に現在の変形を適用する。
                auto candidate = zip(vertices(), deformation).map!((t) => t[0] + t[1]).array;
                if (hasInvalidOffsets("applyPathDeform:directCandidate", candidate, invalidIndex, invalidValue)) {
                    handleInvalidDeformation("applyPathDeform:directCandidate", origDeform);
                    return;
                }
                deform(candidate);
                logCurveState("applyPathDeform");
            }
            refreshInverseMatrix("applyPathDeform:postNoDriver");

        }

        updateDeform();
    }

    override
    void build(bool force = false) { 
        foreach (child; children) {
            setupChild(child);
        }
        setupSelf();
        super.build(force);
    }

    bool setupChildNoRecurse(bool prepend = false)(Node node) {
        auto drawable = cast(Drawable)node;
        auto grid = cast(GridDeformer)node;
        bool supportsDeform = (drawable !is null) || (grid !is null);

        if (supportsDeform) {
            cacheClosestPoints(node);
            if (dynamic) {
                node.postProcessFilters  = node.postProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
                node.preProcessFilters  = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
            } else {
                node.preProcessFilters  = node.preProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
                node.postProcessFilters  = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
            }
        } else {
            meshCaches.remove(node);
            node.preProcessFilters  = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
            node.postProcessFilters  = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
        }
        return true;
    }

    override
    bool setupChild(Node child) {
        super.setupChild(child);
        void setGroup(Node node) {
            setupChildNoRecurse(node);
            bool mustPropagate = node.mustPropagate();
            if (mustPropagate) {
                foreach (child; node.children) {
                    setGroup(child);
                }
            }
        }

        setGroup(child);

        return true;
    }

    bool releaseChildNoRecurse(Node node) {
        meshCaches.remove(node);
        node.preProcessFilters = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
        node.postProcessFilters = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
        return true;
    }

    override
    bool releaseChild(Node child) {
        void unsetGroup(Node node) {
            releaseChildNoRecurse(node);
            bool mustPropagate = !node.mustPropagate();
            if (mustPropagate) {
                foreach (child; node.children) {
                    unsetGroup(child);
                }
            }
        }
        unsetGroup(child);
        super.releaseChild(child);

        return true;
    }

    override
    void captureTarget(Node target) {
        children_ref ~= target;
        setupChildNoRecurse!true(target);
    }

    override
    void releaseTarget(Node target) {
        releaseChildNoRecurse(target);
        children_ref = children_ref.removeByValue(target);
    }

    override
    protected void runRenderTask(RenderContext ctx) {
        // PathDeformer does not enqueue GPU work.
    }

    debug(path_deform) {
        vec2[][Node] closestPointsDeformed; // debug code
        vec2[][Node] closestPointsOriginal; // debug code
    }
    override
    Tuple!(vec2[], mat4*, bool) deformChildren(Node target, vec2[] origVertices, vec2[] origDeformation, mat4* origTransform) {
        if (!originalCurve || vertices.length < 2) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }
        bool diagnosticsStarted = beginDiagnosticFrame();
        scope(exit) {
            if (diagnosticsStarted) {
                endDiagnosticFrame();
            }
        }
        mat4 centerMatrix = inverseMatrix * (*origTransform);
        centerMatrix = requireFiniteMatrix(centerMatrix, "deformChildren:centerMatrix:" ~ target.name);
        size_t invalidIndex;
        vec2 invalidValue;
        if (hasInvalidOffsets("deformChildren:inputDeformation", origDeformation, invalidIndex, invalidValue)) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }

        vec2[] cVertices;
        vec2[] deformedClosestPointsA;
        deformedClosestPointsA.length = origVertices.length;
        vec2[] deformedVertices;
        deformedVertices.length = origVertices.length;

        if (target !in meshCaches)
            cacheClosestPoints(target);
        foreach (i, vertex; origVertices) {
            vec2 cVertex;
            vec2 deformationValue = origDeformation[i];
            cVertex = vec2(centerMatrix * vec4(vertex + deformationValue, 0, 1));
            if (!cVertex.isFinite) {
                markInvalidOffset("deformChildren:cVertexNaN", i, deformationValue);
                writeln("[PathDeformer][CurveDiag] node=", name,
                        " context=deformChildren:cVertexNaN",
                        " index=", i,
                        " vertex=", formatVec2(vertex),
                        " deformation=", formatVec2(deformationValue),
                        " target=", target.name);
                return Tuple!(vec2[], mat4*, bool)(null, null, false);
            }
            cVertices ~= cVertex;

            float t;
            if (target !in meshCaches || i>= meshCaches[target].length ) {
                meshCaches.remove(target);
                cacheClosestPoints(target);
            }
            t = meshCaches[target][i];
            vec2 closestPointOriginal = (prevCurve? prevCurve: originalCurve).point(t);
            debug(path_deform) closestPointsOriginal[target] ~= closestPointOriginal; // debug code
            vec2 tangentOriginalRaw = (prevCurve? prevCurve: originalCurve).derivative(t);
            float tangentOriginalLenSq = dot(tangentOriginalRaw, tangentOriginalRaw);
            vec2 tangentOriginal;
            if (tangentOriginalLenSq > tangentEpsilon) {
                tangentOriginal = tangentOriginalRaw / sqrt(tangentOriginalLenSq);
            } else {
                tangentOriginal = vec2(1, 0);
                writeln("[PathDeformer][CurveDiag] node=", name,
                        " context=tangentOriginalDegenerate",
                        " t=", t,
                        " controlPoints=", summarizePoints((prevCurve? prevCurve: originalCurve).controlPoints));
            }
            vec2 normalOriginal = vec2(-tangentOriginal.y, tangentOriginal.x);
            float originalNormalDistance = dot(cVertex - closestPointOriginal, normalOriginal); 
            float tangentialDistance = dot(cVertex - closestPointOriginal, tangentOriginal);

            // Find the corresponding point on the deformed Bezier curve

            vec2 closestPointDeformedA = deformedCurve.point(t); // 修正: deformedCurve を使用
            debug(path_deform) closestPointsDeformed[target] ~= closestPointDeformedA; // debug code
            if (!closestPointDeformedA.isFinite) {
                markInvalidOffset("deformChildren:closestPointDeformedNaN", i, deformationValue);
                writeln("[PathDeformer][CurveDiag] node=", name,
                        " context=closestPointDeformedNaN",
                        " t=", t,
                        " centerVertex=", cVertex,
                        " origPoint=", closestPointOriginal,
                        " deformedPoint=", closestPointDeformedA,
                        " deformation=", deformationSnapshot());
                return Tuple!(vec2[], mat4*, bool)(null, null, false);
            }
            vec2 tangentDeformedRaw = deformedCurve.derivative(t);
            float tangentDeformedLenSq = dot(tangentDeformedRaw, tangentDeformedRaw);
            vec2 tangentDeformed;
            if (tangentDeformedLenSq > tangentEpsilon) {
                tangentDeformed = tangentDeformedRaw / sqrt(tangentDeformedLenSq);
            } else {
                tangentDeformed = tangentOriginal;
                writeln("[PathDeformer][CurveDiag] node=", name,
                        " context=tangentDeformedDegenerate",
                        " t=", t,
                        " controlPoints=", summarizePoints(deformedCurve.controlPoints));
            }
            vec2 normalDeformed = vec2(-tangentDeformed.y, tangentDeformed.x);

            // Adjust the vertex to maintain the same normal and tangential distances
            vec2 deformedVertex = closestPointDeformedA + normalDeformed * originalNormalDistance + tangentDeformed * tangentialDistance;

            deformedVertices[i] = deformedVertex;
            deformedClosestPointsA[i] = closestPointOriginal;
        }

        mat4 invCenter = safeInverse(centerMatrix, "deformChildren:centerInverse:" ~ target.name);
        foreach (i, cVertex; cVertices) {
            mat4 inv = invCenter;
            inv[0][3] = 0;
            inv[1][3] = 0;
            inv[2][3] = 0;
            origDeformation[i] += (inv * vec4(deformedVertices[i] - cVertex, 0, 1)).xy;
        }

        if (driver) {
            target.notifyChange(target);
        }
        return Tuple!(vec2[], mat4*, bool)(origDeformation, null, true);
    }

    override
    void clearCache() {
        meshCaches.clear();
    }

    void applyDeformToChildren(Parameter[] params, bool recursive = true) {
        if (driver !is null) {
            physicsOnly = true;
            return;
        }
        if (dynamic) {
            return;
        }

        bool diagnosticsStarted = beginDiagnosticFrame();
        scope(exit) {
            if (diagnosticsStarted) {
                endDiagnosticFrame();
            }
        }

        void update(vec2[] deformation) {
            size_t invalidIndex;
            vec2 invalidValue;
            if (hasInvalidOffsets("applyDeformToChildren:updateInput", deformation, invalidIndex, invalidValue)) {
                return;
            }
            if (vertices.length >= 2) {
                auto candidate = zip(vertices(), deformation).map!((t) => t[0] + t[1] ).array;
                if (hasInvalidOffsets("applyDeformToChildren:candidate", candidate, invalidIndex, invalidValue)) {
                    return;
                }
                deform(candidate);
                logCurveState("applyDeformToChildren");
            }
            refreshInverseMatrix("applyDeformToChildren:update");
        }

        bool transfer() { return false; }

        _applyDeformToChildren(tuple(1, &deformChildren), &update, &transfer, params, recursive);
        physicsOnly = true;
        rebuffer([]);
    }

    override
    void centralize() {
        foreach (child; children) {
            child.centralize();
        }

        vec4 bounds;
        vec4[] childTranslations;
        if (children.length > 0) {
            bounds = children[0].getCombinedBounds();
            foreach (child; children) {
                auto cbounds = child.getCombinedBounds();
                bounds.x = min(bounds.x, cbounds.x);
                bounds.y = min(bounds.y, cbounds.y);
                bounds.z = max(bounds.z, cbounds.z);
                bounds.w = max(bounds.w, cbounds.w);
                childTranslations ~= child.transform.matrix() * vec4(0, 0, 0, 1);
            }
        } else {
            bounds = transform.translation.xyxy;
        }
        transformChanged();

        foreach (i, child; children) {
            child.localTransform.translation = (transform.matrix.inverse * childTranslations[i]).xyz;
            child.transformChanged();
        }
    }
    
    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);

        if (auto pathDeformer = cast(PathDeformer)src) {
            clearCache();
            curveType = pathDeformer.curveType;
            physicsType = pathDeformer.physicsType;
            physicsOnly = pathDeformer.physicsOnly;
            if (pathDeformer.driver) {
                driver = createPhysics();

            }
            driverInitialized = false;
        }
        if (auto deformable = cast(Deformable)src) {
            originalCurve = createCurve(deformable.vertices);
        }
        deformation.length = originalCurve.controlPoints.length;
    }

    override
    bool coverOthers() { return true; }

    override
    bool mustPropagate() { return true; }

    bool physicsEnabled() { return _driver !is null; }
    void physicsEnabled(bool value) {
        if (value) {
            if (driver is null) {
                driver = createPhysics();
            }
        } else {
            driver = null;
        }
    }

    override
    void notifyChange(Node target, NotifyReason reason = NotifyReason.Transformed) {
        if (target != this && reason == NotifyReason.StructureChanged) {
            if (target in meshCaches) {
                meshCaches.remove(target);
            }
        }
        super.notifyChange(target, reason);
    }

    void switchDynamic(bool dynamic) {
        if (dynamic != this.dynamic) {
            this.dynamic = dynamic;
            build();
        }
    }

    private string deformationSnapshot() {
        return summarizePoints(deformation);
    }
}
