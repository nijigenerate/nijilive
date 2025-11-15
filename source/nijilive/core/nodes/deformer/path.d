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
import nijilive.math.veca_ops : transformAssign, transformAdd, projectVec2OntoAxes,
    composeVec2FromAxes, rotateVec2TangentsToNormals;

//import std.stdio;
import std.math : sqrt, isNaN, isFinite, fabs;
import std.algorithm;
import std.array;
import std.range;
import std.typecons;
import std.format : formattedWrite;
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
    enum size_t invalidLogInterval = 10;
    enum size_t invalidLogFrameInterval = 30;
    enum size_t curveDiagRepeatInterval = 15;
    enum size_t invalidInitialLogAllowance = 3;

    bool hasDegenerateBaseline = false;
    size_t[] degenerateSegmentIndices;
    size_t frameCounter = 0;
    size_t invalidFrameCount = 0;
    size_t consecutiveInvalidFrames = 0;
    size_t totalMatrixInvalidCount = 0;
    bool invalidThisFrame = false;
    bool matrixInvalidThisFrame = false;
    bool diagnosticsFrameActive = false;
    bool loggedTransformInvalid = false;
    size_t[] invalidTotalPerIndex;
    size_t[] invalidConsecutivePerIndex;
    bool[] invalidIndexThisFrame;
    size_t[] invalidStreakStartFrame;
    size_t[] invalidLastLoggedFrame;
    size_t[] invalidLastLoggedCount;
    bool[] invalidLastLoggedValueWasNaN;
    Vec2Array invalidLastLoggedValue;
    string[] invalidLastLoggedContext;

    struct CurveDiagLogState {
        bool hasNaN;
        bool collapsed;
        float targetScale;
        float referenceScale;
        size_t lastFrame;
        size_t firstInvalidFrame;
    }

    CurveDiagLogState[string] curveDiagLogStates;

    private void pathLog(T...)(T args) { }

    Vec2Array getVertices(Node node) {
        if (auto drawable = cast(Deformable)node) {
            return drawable.vertices;
        } else {
            return Vec2Array([node.transform.translation.xy]);
        }
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

    void deform(Vec2Array deformedControlPoints) {
        deformedCurve = createCurve(deformedControlPoints);
    }

    private
    float computeCurveScale(Points)(auto ref Points points) {
        float scale = 0;
        auto len = points.length;
        foreach (i; 0 .. len) {
            auto pt = points[i];
            if (isNaN(pt.x) || isNaN(pt.y)) continue;
            float magnitude = sqrt(pt.x * pt.x + pt.y * pt.y);
            if (magnitude > scale) {
                scale = magnitude;
            }
        }
        return scale;
    }

    private
    string summarizePoints(Points)(auto ref Points points, size_t maxCount = 4) {
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
    bool approxEqual(float a, float b, float epsilon = 1e-3f) {
        if (isNaN(a) && isNaN(b)) return true;
        return fabs(a - b) <= epsilon;
    }

    private
    bool guardFinite(vec2 value) {
        return value.x.isFinite && value.y.isFinite;
    }

    private
    void sanitizeOffsets(ref Vec2Array values) {
        foreach (value; values) {
            if (!guardFinite(value)) {
                value = vec2(0, 0);
            }
        }
    }

    private
    vec2 sanitizeVec2(vec2 value) {
        return guardFinite(value) ? value : vec2(0, 0);
    }

    private
    void handleInvalidDeformation(string context, const Vec2Array fallback) {
        pathLog("[PathDeformer][InvalidDeformation] node=", name,
                " context=", context,
                " driverActive=", _driver !is null,
                " frame=", frameCounter,
                " consecutiveInvalidFrames=", consecutiveInvalidFrames + 1);
        invalidThisFrame = true;
        if (fallback.length != 0 && fallback.length == deformation.length) {
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
            pathLog("[PathDeformer][MatrixDiag] node=", name,
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
            pathLog("[PathDeformer][MatrixDiag] node=", name,
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
    void logTransformFailure(string context, ref Transform transformInfo) {
        if (loggedTransformInvalid) {
            return;
        }
        loggedTransformInvalid = true;
        string translationXY = formatVec2(transformInfo.translation.xy);
        string scaleXY = formatVec2(transformInfo.scale.xy);
        pathLog("[PathDeformer][TransformDiag] node=", name,
                " context=", context,
                " frame=", frameCounter,
                " translation=", translationXY,
                " scale=", scaleXY,
                " rotationZ=", transformInfo.rotation.z,
                " matrix=", matrixSummary(transformInfo.matrix));
    }

    private
    bool logCurveHealth(Points)(string context, Curve reference, Curve target, auto ref Points deformationSnapshot) {
        if (target is null) return false;

        auto targetPoints = target.controlPoints;
        bool hasNaN = false;
        foreach (i; 0 .. targetPoints.length) {
            auto pt = targetPoints[i];
            if (isNaN(pt.x) || isNaN(pt.y)) {
                hasNaN = true;
                break;
            }
        }

        float targetScale = computeCurveScale(targetPoints);
        float referenceScale = 0;
        auto referencePoints = Vec2Array.init;
        if (reference !is null) {
            referencePoints = reference.controlPoints;
            referenceScale = computeCurveScale(referencePoints);
        }

        bool collapsed = false;
        if (reference !is null && referenceScale > curveReferenceEpsilon) {
            collapsed = targetScale < referenceScale * curveCollapseRatio;
        }

        bool emittedLog = false;
        bool isInvalid = hasNaN || collapsed;
        auto statePtr = context in curveDiagLogStates;
        CurveDiagLogState prevState;
        bool hadPrevState = false;
        if (statePtr !is null) {
            prevState = *statePtr;
            hadPrevState = true;
            bool wasInvalid = prevState.hasNaN || prevState.collapsed;
            if (wasInvalid && !isInvalid) {
                size_t startFrame = prevState.firstInvalidFrame != 0 ? prevState.firstInvalidFrame : prevState.lastFrame;
                size_t framesInvalid = prevState.lastFrame >= startFrame ? (prevState.lastFrame - startFrame + 1) : 1;
                pathLog("[PathDeformer][CurveDiagRecovered] node=", name,
                        " context=", context,
                        " frame=", frameCounter,
                        " framesInvalid=", framesInvalid,
                        " prevHasNaN=", prevState.hasNaN,
                        " prevCollapsed=", prevState.collapsed);
                emittedLog = true;
            }
        }

        if (isInvalid) {
            bool logNow = true;
            if (hadPrevState) {
                bool sameState = prevState.hasNaN == hasNaN &&
                                 prevState.collapsed == collapsed &&
                                 approxEqual(prevState.targetScale, targetScale) &&
                                 approxEqual(prevState.referenceScale, referenceScale);
                if (sameState && frameCounter < prevState.lastFrame + curveDiagRepeatInterval) {
                    logNow = false;
                }
            }
            if (logNow) {
                size_t startFrame = frameCounter;
                if (hadPrevState) {
                    bool prevInvalid = prevState.hasNaN || prevState.collapsed;
                    if (prevInvalid && prevState.firstInvalidFrame != 0) {
                        startFrame = prevState.firstInvalidFrame;
                    } else if (prevInvalid && prevState.firstInvalidFrame == 0) {
                        startFrame = prevState.lastFrame;
                    }
                }
                size_t framesInvalid = frameCounter >= startFrame ? (frameCounter - startFrame + 1) : 1;
                pathLog("[PathDeformer][CurveDiag] node=", name,
                        " context=", context,
                        " collapsed=", collapsed,
                        " hasNaN=", hasNaN,
                        " refScale=", referenceScale,
                        " targetScale=", targetScale,
                        " refPoints=", summarizePoints(referencePoints),
                        " targetPoints=", summarizePoints(targetPoints),
                        " deformation=", summarizePoints(deformationSnapshot),
                        " firstFrame=", startFrame,
                        " framesInvalid=", framesInvalid);
                emittedLog = true;
            }
        }

        size_t nextFirstInvalidFrame = 0;
        if (isInvalid) {
            if (hadPrevState && (prevState.hasNaN || prevState.collapsed)) {
                nextFirstInvalidFrame = prevState.firstInvalidFrame != 0 ? prevState.firstInvalidFrame : prevState.lastFrame;
            } else {
                nextFirstInvalidFrame = frameCounter;
            }
        }

        curveDiagLogStates[context] = CurveDiagLogState(hasNaN, collapsed, targetScale, referenceScale, frameCounter, nextFirstInvalidFrame);
        return emittedLog;
    }

    private
    void logCurveState(string context) {
        auto deformationSnapshot = deformation;
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
            invalidStreakStartFrame.length = length;
            invalidLastLoggedFrame.length = length;
            invalidLastLoggedCount.length = length;
            invalidLastLoggedValueWasNaN.length = length;
            invalidLastLoggedValue.length = length;
            invalidLastLoggedContext.length = length;
            foreach (ref flag; invalidIndexThisFrame) flag = false;
            foreach (ref val; invalidConsecutivePerIndex) val = 0;
            foreach (ref val; invalidTotalPerIndex) val = 0;
            foreach (ref val; invalidStreakStartFrame) val = 0;
            foreach (ref val; invalidLastLoggedFrame) val = 0;
            foreach (ref val; invalidLastLoggedCount) val = 0;
            foreach (ref val; invalidLastLoggedValueWasNaN) val = false;
            invalidLastLoggedValue[] = vec2(0, 0);
            foreach (ref ctx; invalidLastLoggedContext) ctx = "";
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
            if (!invalidIndexThisFrame[index]) {
                invalidIndexThisFrame[index] = true;
                if (invalidStreakStartFrame[index] == 0) {
                    invalidStreakStartFrame[index] = frameCounter;
                }
            }
            invalidTotalPerIndex[index]++;
            invalidConsecutivePerIndex[index]++;
            auto consecutive = invalidConsecutivePerIndex[index];
            if (invalidStreakStartFrame[index] == 0) {
                invalidStreakStartFrame[index] = frameCounter;
            }
            if (shouldEmitInvalidIndexLog(index, context, value, consecutive)) {
                logInvalidIndex(context, index, value, consecutive);
            }
            if (_driver !is null && consecutive >= invalidDisableThreshold) {
                disablePhysicsDriver(context ~ ":threshold");
            }
        } else {
            pathLog("[PathDeformer][InvalidDeformation] node=", name,
                    " context=", context,
                    " index=", index,
                    " value=", formatVec2(value),
                    " frame=", frameCounter,
                    " driverActive=", _driver !is null);
        }
    }

    private
    bool shouldEmitInvalidIndexLog(size_t index, string context, vec2 value, size_t consecutive) {
        bool hasPrevLog = invalidLastLoggedFrame[index] != 0;
        bool valueIsNaN = !guardFinite(value);
        bool valueChanged = !hasPrevLog;
        if (hasPrevLog) {
            if (invalidLastLoggedValueWasNaN[index] != valueIsNaN) {
                valueChanged = true;
            } else if (!valueIsNaN) {
                vec2 prevValue = invalidLastLoggedValue[index];
                valueChanged = (value.x != prevValue.x) || (value.y != prevValue.y);
            }
        }
        bool contextChanged = !hasPrevLog || invalidLastLoggedContext[index] != context;
        bool consecutiveTrigger = ( !hasPrevLog && consecutive >= 1 && invalidTotalPerIndex[index] <= invalidInitialLogAllowance )
            || (consecutive == invalidDisableThreshold && invalidLastLoggedCount[index] != consecutive)
            || (consecutive % invalidLogInterval == 0 && invalidLastLoggedCount[index] != consecutive);
        bool timeTrigger = hasPrevLog && (frameCounter - invalidLastLoggedFrame[index]) >= invalidLogFrameInterval;
        bool totalTrigger = (invalidTotalPerIndex[index] % invalidLogInterval == 0) && invalidLastLoggedFrame[index] != frameCounter;
        return valueChanged || contextChanged || consecutiveTrigger || timeTrigger || totalTrigger;
    }

    private
    void logInvalidIndex(string context, size_t index, vec2 value, size_t consecutive) {
        size_t startFrame = invalidStreakStartFrame[index] != 0 ? invalidStreakStartFrame[index] : frameCounter;
        pathLog("[PathDeformer][InvalidDeformation] node=", name,
                " context=", context,
                " index=", index,
                " value=", formatVec2(value),
                " frame=", frameCounter,
                " indexConsecutive=", consecutive,
                " indexTotal=", invalidTotalPerIndex[index],
                " firstFrame=", startFrame,
                " driverActive=", _driver !is null);
        invalidLastLoggedFrame[index] = frameCounter;
        invalidLastLoggedCount[index] = consecutive;
        invalidLastLoggedContext[index] = context;
        invalidLastLoggedValue[index] = value;
        invalidLastLoggedValueWasNaN[index] = !guardFinite(value);
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
            pathLog("[PathDeformer][InvalidDeformationRecovered] node=", name,
                    " frame=", frameCounter,
                    " lastedFrames=", consecutiveInvalidFrames);
            consecutiveInvalidFrames = 0;
        }

        if (matrixInvalidThisFrame) {
            pathLog("[PathDeformer][MatrixInvalidFrame] node=", name,
                    " frame=", frameCounter,
                    " totalMatrixInvalidFrames=", totalMatrixInvalidCount);
        }

        foreach (i; 0 .. invalidConsecutivePerIndex.length) {
            if (!invalidIndexThisFrame[i] && invalidConsecutivePerIndex[i] > 0) {
                size_t startFrame = invalidStreakStartFrame[i];
                pathLog("[PathDeformer][InvalidDeformationRecovered] node=", name,
                        " index=", i,
                        " frame=", frameCounter,
                        " lastedFrames=", invalidConsecutivePerIndex[i],
                        " totalInvalid=", invalidTotalPerIndex[i],
                        " firstFrame=", startFrame);
                invalidConsecutivePerIndex[i] = 0;
                invalidStreakStartFrame[i] = 0;
                invalidLastLoggedFrame[i] = 0;
                invalidLastLoggedCount[i] = 0;
                invalidLastLoggedContext[i] = "";
                invalidLastLoggedValueWasNaN[i] = false;
                invalidLastLoggedValue[i] = vec2(0, 0);
            }
        }
        invalidThisFrame = false;
        matrixInvalidThisFrame = false;
        diagnosticsFrameActive = false;
        if (!invalidThisFrame && !matrixInvalidThisFrame) {
            loggedTransformInvalid = false;
        }
    }

    private
    void checkBaselineDegeneracy(Points)(auto ref Points points) {
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
            pathLog("[PathDeformer][DegenerateBaseline] node=", name,
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
        Vec2Array controlPoints;
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

    Curve createCurve(Vec2Array points) {
        if (curveType == CurveType.Bezier) {
            return new BezierCurve(points);
        } else {
            return new SplineCurve(points);
        }
    }

    PhysicsDriver createPhysics() {
        if (hasDegenerateBaseline) {
            pathLog("[PathDeformer][PhysicsDisabled] node=", name,
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
    ref Vec2Array vertices() {
        return originalCurve.controlPoints;
    }

    this(Node parent = null, CurveType curveType = CurveType.Spline) {
        super(parent);
        this.curveType = curveType;
        originalCurve = createCurve(Vec2Array());
        deformedCurve = createCurve(Vec2Array());
        driver = null;
        prevRootSet = false;
    }

    override
    string typeId() { return "PathDeformer"; }

    override
    void rebuffer(Vec2Array originalControlPoints) {

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
        driverInitialized = false;
        prevRootSet = false;
        physicsOnly = false;
        deformation[] = vec2(0, 0);
        _driver.reset();
    }
    package(nijilive)
    void reportPhysicsDegeneracy(string reason) {
        disablePhysicsDriver(reason);
    }
    package(nijilive)
    void reportDriverInvalid(string context, size_t index, vec2 value) {
        if (index < deformation.length) {
            deformation[index] = vec2(0, 0);
        }
    }

    override
    protected void runPreProcessTask() {
        // Child filters consume inverseMatrix during super.runPreProcessTask();
        // ensure it reflects this frame's transform before they run.
        if (diagnosticsFrameActive) {
            endDiagnosticFrame();
        }
        bool diagnosticsStarted = beginDiagnosticFrame();
        auto currentTransform = this.transform();
        if (!matrixIsFinite(currentTransform.matrix)) {
            logTransformFailure("runPreProcessTask:transform", currentTransform);
            disablePhysicsDriver("transformInvalid");
            return;
        }
        refreshInverseMatrix("runPreProcessTask:initial");
        auto origDeform = deformation.dup;
        super.runPreProcessTask();
        applyPathDeform(origDeform);
        if (diagnosticsStarted) {
            endDiagnosticFrame();
        }
    }

    override
    protected void runDynamicTask() {
        super.runDynamicTask();
    }

    private void applyPathDeform(const Vec2Array origDeform) {
        // Ensure global transform is fresh before using cached matrix values.
        this.transform();
        refreshInverseMatrix("applyPathDeform:pre");
        sanitizeOffsets(deformation);

        if (driver) {
            Vec2Array baseline = (origDeform.length == deformation.length) ? origDeform.dup : deformation.dup;
            sanitizeOffsets(baseline);
            if (!driverInitialized && driver !is null && puppet !is null && puppet.enableDrivers ) {
                driver.setup();
                if (driver is null) {
                    handleInvalidDeformation("applyPathDeform:setupDisabled", origDeform);
                    return;
                }
                driverInitialized = true;
            }
            Vec2Array diffDeform = deformation.dup;
            diffDeform -= baseline;
            sanitizeOffsets(diffDeform);

            if (vertices.length >= 2) {
                auto prevCandidate = vertices.dup;
                prevCandidate += diffDeform;
                prevCurve = createCurve(prevCandidate);
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
                        root = sanitizeVec2((transformMatrix * vec4(vertices[0] + deformation[0], 0, 1)).xy);
                    else
                        root = vec2(0, 0);
                    if (prevRootSet) {
                        vec2 deform = sanitizeVec2(root - prevRoot);
                        driver.reset();
                        driver.enforce(deform);
                        driver.rotate(transform.rotation.z);
                        if (physicsOnly) { // Tentative solution.
                            Vec2Array prevDeform = deformation.dup;
                            driver.update();
                            if (driver is null) {
                                handleInvalidDeformation("applyPathDeform:updateDisabled", origDeform);
                                return;
                            }
                            prevCurve = createCurve(vertices);
                            logCurveHealth("applyPathDeform:physicsPrev", originalCurve, prevCurve, deformation);
                            deformation -= prevDeform;
                            sanitizeOffsets(deformation);
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

                auto candidate = vertices.dup;
                candidate += deformation;
                sanitizeOffsets(candidate);
                deform(candidate);
                logCurveState("applyPathDeform");
            }
            refreshInverseMatrix("applyPathDeform:postDriver");
        } else {

            if (vertices.length >= 2) {
                // driver なしの場合は純粋に現在の変形を適用する。
                auto candidate = vertices.dup;
                candidate += deformation;
                sanitizeOffsets(candidate);
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
        Vec2Array[Node] closestPointsDeformed; // debug code
        Vec2Array[Node] closestPointsOriginal; // debug code
    }
    override
    Tuple!(Vec2Array, mat4*, bool) deformChildren(Node target, Vec2Array origVertices, Vec2Array origDeformation, mat4* origTransform) {
        if (!originalCurve || vertices.length < 2) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }
        bool diagnosticsStarted = beginDiagnosticFrame();
        scope(exit) {
            if (diagnosticsStarted) {
                endDiagnosticFrame();
            }
        }
        mat4 centerMatrix = inverseMatrix * (*origTransform);
        centerMatrix = requireFiniteMatrix(centerMatrix, "deformChildren:centerMatrix:" ~ target.name);
        sanitizeOffsets(origDeformation);

        size_t vertexCount = origVertices.length;
        Vec2Array cVertices;
        Vec2Array deformedVertices;
        deformedVertices.length = origVertices.length;
        if (origDeformation.length < origVertices.length) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        transformAssign(cVertices, origVertices, centerMatrix);
        transformAdd(cVertices, origDeformation, centerMatrix);

        auto deformLaneX = origDeformation.lane(0);
        auto deformLaneY = origDeformation.lane(1);
        auto origLaneX = origVertices.lane(0);
        auto origLaneY = origVertices.lane(1);
        auto centerLaneX = cVertices.lane(0);
        auto centerLaneY = cVertices.lane(1);
        auto invalidCenterIdx = firstNonFiniteIndex(cVertices);
        if (invalidCenterIdx >= 0) {
            vec2 deformationValue = vec2(deformLaneX[invalidCenterIdx], deformLaneY[invalidCenterIdx]);
            markInvalidOffset("deformChildren:cVertexNaN", invalidCenterIdx, deformationValue);
            pathLog("[PathDeformer][CurveDiag] node=", name,
                    " context=deformChildren:cVertexNaN",
                    " index=", invalidCenterIdx,
                    " vertex=", formatVec2(vec2(origLaneX[invalidCenterIdx], origLaneY[invalidCenterIdx])),
                    " deformation=", formatVec2(deformationValue),
                    " target=", target.name);
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        if (target !in meshCaches || meshCaches[target].length < vertexCount)
            cacheClosestPoints(target);
        if (target !in meshCaches || meshCaches[target].length < vertexCount) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        float[] tSamples;
        tSamples.length = vertexCount;
        tSamples[] = meshCaches[target][0 .. vertexCount];

        Vec2Array closestOriginal;
        auto baseCurve = prevCurve ? prevCurve : originalCurve;
        baseCurve.evaluatePoints(tSamples, closestOriginal);

        Vec2Array closestDeformed;
        deformedCurve.evaluatePoints(tSamples, closestDeformed);

        Vec2Array tangentOriginalRaw;
        baseCurve.evaluateDerivatives(tSamples, tangentOriginalRaw);

        Vec2Array tangentDeformedRaw;
        deformedCurve.evaluateDerivatives(tSamples, tangentDeformedRaw);

        debug(path_deform) {
            closestPointsOriginal[target] = closestOriginal.dup;
            closestPointsDeformed[target] = closestDeformed.dup;
        }

        auto closestOrigX = closestOriginal.lane(0);
        auto closestOrigY = closestOriginal.lane(1);
        auto closestDefX = closestDeformed.lane(0);
        auto closestDefY = closestDeformed.lane(1);

        auto invalidIdx = firstNonFiniteIndex(closestDeformed);
        if (invalidIdx >= 0) {
            vec2 deformationValue = vec2(deformLaneX[invalidIdx], deformLaneY[invalidIdx]);
            markInvalidOffset("deformChildren:closestPointDeformedNaN", invalidIdx, deformationValue);
            pathLog("[PathDeformer][CurveDiag] node=", name,
                    " context=closestPointDeformedNaN",
                    " t=", tSamples[invalidIdx],
                    " centerVertex=", formatVec2(vec2(centerLaneX[invalidIdx], centerLaneY[invalidIdx])),
                    " origPoint=", formatVec2(vec2(closestOrigX[invalidIdx], closestOrigY[invalidIdx])),
                    " deformedPoint=", formatVec2(vec2(closestDefX[invalidIdx], closestDefY[invalidIdx])),
                    " deformation=", deformationSnapshot());
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        Vec2Array tangentOriginal = tangentOriginalRaw.dup;
        normalizeVec2ArrayWithConstantFallback(
            tangentOriginal,
            tangentEpsilon,
            vec2(1, 0),
            (idx) {
                pathLog("[PathDeformer][CurveDiag] node=", name,
                        " context=tangentOriginalDegenerate",
                        " t=", tSamples[idx],
                        " controlPoints=", summarizePoints(baseCurve.controlPoints));
            });

        Vec2Array tangentDeformed = tangentDeformedRaw.dup;
        normalizeVec2ArrayWithArrayFallback(
            tangentDeformed,
            tangentEpsilon,
            tangentOriginal,
            (idx) {
                pathLog("[PathDeformer][CurveDiag] node=", name,
                        " context=tangentDeformedDegenerate",
                        " t=", tSamples[idx],
                        " controlPoints=", summarizePoints(deformedCurve.controlPoints));
            });

        Vec2Array normalOriginal;
        rotateVec2TangentsToNormals(normalOriginal, tangentOriginal);
        Vec2Array normalDeformed;
        rotateVec2TangentsToNormals(normalDeformed, tangentDeformed);

        float[] normalDistances;
        float[] tangentialDistances;
        normalDistances.length = vertexCount;
        tangentialDistances.length = vertexCount;

        projectVec2OntoAxes(
            cVertices,
            closestOriginal,
            normalOriginal,
            tangentOriginal,
            normalDistances,
            tangentialDistances);

        composeVec2FromAxes(
            deformedVertices,
            closestDeformed,
            normalDistances,
            normalDeformed,
            tangentialDistances,
            tangentDeformed);

        mat4 invCenter = safeInverse(centerMatrix, "deformChildren:centerInverse:" ~ target.name);
        invCenter[0][3] = 0;
        invCenter[1][3] = 0;
        invCenter[2][3] = 0;
        Vec2Array offsetLocal = deformedVertices.dup;
        offsetLocal -= cVertices;
        transformAdd(origDeformation, offsetLocal, invCenter, offsetLocal.length);

        if (driver) {
            target.notifyChange(target);
        }
        return Tuple!(Vec2Array, mat4*, bool)(origDeformation, null, true);
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

        void update(Vec2Array deformation) {
            sanitizeOffsets(deformation);
            if (vertices.length >= 2) {
                Vec2Array candidate = vertices.dup;
                candidate += deformation;
                sanitizeOffsets(candidate);
                deform(candidate);
                logCurveState("applyDeformToChildren");
            }
            refreshInverseMatrix("applyDeformToChildren:update");
        }

        bool transfer() { return false; }

        _applyDeformToChildren(tuple(1, &deformChildren), &update, &transfer, params, recursive);
        physicsOnly = true;
        rebuffer(Vec2Array());
    }

    override
    void centralize() {
        foreach (child; children) {
            child.centralize();
        }

        vec4 bounds;
        Vec4Array childTranslations;
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

private:
    int firstNonFiniteIndex(const Vec2Array data) const {
        auto laneX = data.lane(0);
        auto laneY = data.lane(1);
        foreach (i; 0 .. data.length) {
            if (!laneX[i].isFinite || !laneY[i].isFinite) {
                return cast(int)i;
            }
        }
        return -1;
    }

    void normalizeVec2ArrayWithConstantFallback(ref Vec2Array data, float epsilon, vec2 fallback, scope void delegate(size_t) onFallback) {
        auto laneX = data.lane(0);
        auto laneY = data.lane(1);
        foreach (i; 0 .. data.length) {
            float lenSq = laneX[i] * laneX[i] + laneY[i] * laneY[i];
            if (lenSq > epsilon) {
                float invLen = 1.0f / sqrt(lenSq);
                laneX[i] *= invLen;
                laneY[i] *= invLen;
            } else {
                laneX[i] = fallback.x;
                laneY[i] = fallback.y;
                if (onFallback !is null) onFallback(i);
            }
        }
    }

    void normalizeVec2ArrayWithArrayFallback(ref Vec2Array data, float epsilon, const Vec2Array fallback, scope void delegate(size_t) onFallback) {
        auto laneX = data.lane(0);
        auto laneY = data.lane(1);
        auto fallbackX = fallback.lane(0);
        auto fallbackY = fallback.lane(1);
        foreach (i; 0 .. data.length) {
            float lenSq = laneX[i] * laneX[i] + laneY[i] * laneY[i];
            if (lenSq > epsilon) {
                float invLen = 1.0f / sqrt(lenSq);
                laneX[i] *= invLen;
                laneY[i] *= invLen;
            } else {
                laneX[i] = fallbackX[i];
                laneY[i] = fallbackY[i];
                if (onFallback !is null) onFallback(i);
            }
        }
    }

}
