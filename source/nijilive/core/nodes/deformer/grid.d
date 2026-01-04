module nijilive.core.nodes.deformer.grid;

import nijilive.core.nodes;
import nijilive.core.nodes.utils;
import nijilive.core.nodes.defstack;
import nijilive.core.nodes.deformer.base;
import nijilive.core.nodes.deformer.path;
import nijilive.core.param;
import nijilive.core;
import nijilive.fmt.serialize;
import nijilive.math;
import nijilive.math.veca_ops : transformAssign, transformAdd;
import nijilive.math.simd : SimdRepr, simdWidth, storeVec;
import std.algorithm : sort;
import std.math : isClose, isFinite;
import std.typecons : tuple, Tuple;
import nijilive.core.render.scheduler : RenderContext;

enum GridFormation {
    Bilinear,
}

struct GridCellCache {
    ushort cellX;
    ushort cellY;
    float u;
    float v;
    bool valid;
}

package(nijilive) {
    void inInitGridDeformer() {
        inRegisterNodeType!GridDeformer;
    }
}

@TypeId("GridDeformer")
class GridDeformer : Deformable, NodeFilter, Deformer {
    mixin NodeFilterMixin;

private:
    Vec2Array vertexBuffer;
    float[] axisX;
    float[] axisY;
    GridFormation formation = GridFormation.Bilinear;
    mat4 inverseMatrix;

    enum DefaultAxis = [-0.5f, 0.5f];
    enum float BoundaryTolerance = 1e-4f;

public:
    bool dynamic = false;
    bool translateChildren = true;

    this(Node parent = null) {
        super(parent);
        requirePreProcessTask();
        axisX = DefaultAxis.dup;
        axisY = DefaultAxis.dup;
        setGridAxes(axisX, axisY);
    }

    @property
    GridFormation gridFormation() const { return formation; }
    @property
    void gridFormation(GridFormation value) {
        formation = value;
    }

    void switchDynamic(bool value) {
        dynamic = value;
        foreach (child; children_ref) {
            setupChildNoRecurse(child);
        }
    }

    override
    ref Vec2Array vertices() {
        return vertexBuffer;
    }

    override
    void rebuffer(Vec2Array gridPoints) {
        if (gridPoints.length == 0 || !adoptFromVertices(gridPoints, false)) {
            adoptGridFromAxes(DefaultAxis, DefaultAxis);
        }
        clearCache();
    }

    override
    string typeId() { return "GridDeformer"; }

    override
    protected void runPreProcessTask(ref RenderContext ctx) {
        super.runPreProcessTask(ctx);
        localTransform.update();
        transform();
        inverseMatrix = globalTransform.matrix.inverse;
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

    override
    void clearCache() {
    }

    override
    bool setupChild(Node child) {
        super.setupChild(child);
        void setGroup(Node node) {
            bool mustPropagate = node.mustPropagate();
            setupChildNoRecurse(node);
            if (mustPropagate) {
                foreach (c; node.children) {
                    setGroup(c);
                }
            }
        }
        if (hasValidGrid()) {
            setGroup(child);
        }
        return false;
    }

    override
    bool releaseChild(Node child) {
        void unsetGroup(Node node) {
            releaseChildNoRecurse(node);
            bool mustPropagate = node.mustPropagate();
            if (mustPropagate) {
                foreach (c; node.children) {
                    unsetGroup(c);
                }
            }
        }
        unsetGroup(child);
        super.releaseChild(child);
        return false;
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
    protected void runRenderTask(ref RenderContext ctx) {
        // GridDeformer does not emit GPU commands.
    }

    override
    Tuple!(Vec2Array, mat4*, bool) deformChildren(Node target, Vec2Array origVertices, Vec2Array origDeformation, mat4* origTransform) {
        if (!hasValidGrid()) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        if (auto pathTarget = cast(PathDeformer)target) {
            if (!pathTarget.physicsEnabled) {
                return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
            }
        }

        auto targetName = target is null ? "(null)" : target.name;
        if (!matrixIsFinite(inverseMatrix)) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }
        if (origTransform is null) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }
        if (!matrixIsFinite(*origTransform)) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        mat4 centerMatrix = inverseMatrix * (*origTransform);
        GridCellCache[] caches;
        caches.length = origVertices.length;
        Vec2Array samplePoints;
        bool anyChanged = false;

        if (!matrixIsFinite(centerMatrix)) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        transformAssign(samplePoints, origVertices, centerMatrix);
        if (dynamic && origDeformation.length && samplePoints.length) {
            auto overlap = origDeformation.length < samplePoints.length ? origDeformation.length : samplePoints.length;
            transformAdd(samplePoints, origDeformation, centerMatrix, overlap);
        }

        bool invalidSamples = false;
        auto laneX = samplePoints.lane(0);
        auto laneY = samplePoints.lane(1);
        foreach (i; 0 .. samplePoints.length) {
            auto x = laneX[i];
            auto y = laneY[i];
            if (!isFinite(x) || !isFinite(y)) {
                invalidSamples = true;
                break;
            }
            caches[i] = computeCache(x, y);
        }
        if (invalidSamples) {
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, false);
        }

        Vec2Array originalSample;
        Vec2Array targetSample;
        sampleGridPoints(originalSample, caches, false);
        sampleGridPoints(targetSample, caches, true);
        Vec2Array offsetLocal = targetSample.dup;
        offsetLocal -= originalSample;

        auto offsetLaneX = offsetLocal.lane(0);
        auto offsetLaneY = offsetLocal.lane(1);
        foreach (i; 0 .. offsetLocal.length) {
            if (!caches[i].valid ||
                !isFinite(offsetLaneX[i]) ||
                !isFinite(offsetLaneY[i])) {
                offsetLaneX[i] = 0;
                offsetLaneY[i] = 0;
                continue;
            }
            if (offsetLaneX[i] != 0 || offsetLaneY[i] != 0) {
                anyChanged = true;
            }
        }

        if (!anyChanged) {
            return Tuple!(Vec2Array, mat4*, bool)(origDeformation, null, false);
        }

        mat4 invCenter = centerMatrix.inverse;
        invCenter[0][3] = 0;
        invCenter[1][3] = 0;
        invCenter[2][3] = 0;
        transformAdd(origDeformation, offsetLocal, invCenter, offsetLocal.length);

        return Tuple!(Vec2Array, mat4*, bool)(origDeformation, null, anyChanged);
    }

    override
    void applyDeformToChildren(Parameter[] params, bool recursive = true) {
        void update(Vec2Array deformationValues) {
            if (deformationValues.length != deformation.length) return;
            foreach (i, value; deformationValues) {
                deformation[i] = value;
            }
        }

        bool transfer() { return translateChildren; }

        localTransform.update();
        transform();
        inverseMatrix = globalTransform.matrix.inverse;

        _applyDeformToChildren(tuple(1, &deformChildren), &update, &transfer, params, recursive);
    }

    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);

        bool initialized = false;

        if (auto grid = cast(GridDeformer)src) {
            adoptGridFromAxes(grid.axisX, grid.axisY);
            formation = grid.formation;
            dynamic = grid.dynamic;
            deformation = grid.deformation.dup;
            translateChildren = grid.translateChildren;
            initialized = true;
        } else if (auto drawable = cast(Drawable)src) {
            if (adoptFromVertices(drawable.vertices, true)) {
                initialized = true;
            }
        } else if (auto deformable = cast(Deformable)src) {
            if (adoptFromVertices(deformable.vertices, true)) {
                initialized = true;
            }
        }

        if (!initialized) {
            adoptGridFromAxes(DefaultAxis, DefaultAxis);
        }

        clearCache();
    }

    override
    bool coverOthers() { return true; }

    override
    bool mustPropagate() { return false; }

    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags = SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);
        serializer.putKey("grid_axis_x");
        auto xsState = serializer.listBegin();
        foreach (value; axisX) {
            serializer.elemBegin;
            serializer.serializeValue(value);
        }
        serializer.listEnd(xsState);

        serializer.putKey("grid_axis_y");
        auto ysState = serializer.listBegin();
        foreach (value; axisY) {
            serializer.elemBegin;
            serializer.serializeValue(value);
        }
        serializer.listEnd(ysState);

        serializer.putKey("formation");
        serializer.serializeValue(formation);

        serializer.putKey("dynamic");
        serializer.serializeValue(dynamic);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        if (auto exc = super.deserializeFromFghj(data)) return exc;

        if (!data["grid_axis_x"].isEmpty) {
            axisX.length = 0;
            foreach (elem; data["grid_axis_x"].byElement) {
                float v;
                if (auto exc = elem.deserializeValue(v)) return exc;
                axisX ~= v;
            }
        }

        if (!data["grid_axis_y"].isEmpty) {
            axisY.length = 0;
            foreach (elem; data["grid_axis_y"].byElement) {
                float v;
                if (auto exc = elem.deserializeValue(v)) return exc;
                axisY ~= v;
            }
        }

        if (!data["formation"].isEmpty) {
            if (auto exc = data["formation"].deserializeValue(formation)) return exc;
        }

        if (!data["dynamic"].isEmpty) {
            if (auto exc = data["dynamic"].deserializeValue(dynamic)) return exc;
        }

        setGridAxes(axisX, axisY);
        clearCache();

        return null;
    }

private:
    enum float AxisTolerance = 1e-4f;

    size_t cols() const { return axisX.length; }
    size_t rows() const { return axisY.length; }
    bool hasValidGrid() const { return cols() >= 2 && rows() >= 2; }

    size_t gridIndex(size_t x, size_t y) const {
        return y * cols() + x;
    }

    static float[] normalizeAxis(const(float)[] values) {
        auto sorted = values.dup;
        if (sorted.length == 0) {
            return sorted;
        }
        sort(sorted);
        size_t write = 1;
        foreach (i; 1 .. sorted.length) {
            if (!isClose(sorted[write - 1], sorted[i], AxisTolerance, AxisTolerance)) {
                sorted[write] = sorted[i];
                ++write;
            }
        }
        sorted.length = write;
        return sorted;
    }

    int axisIndexOfValue(const(float)[] axis, float value) const {
        foreach (i, v; axis) {
            if (isClose(v, value, AxisTolerance, AxisTolerance)) {
                return cast(int)i;
            }
        }
        return -1;
    }

    void rebuildVertices() {
        rebuildBuffers();
    }

    void rebuildBuffers() {
        if (axisX.length < 2) axisX = DefaultAxis.dup;
        if (axisY.length < 2) axisY = DefaultAxis.dup;
        vertexBuffer.length = cols() * rows();
        deformation.length = vertexBuffer.length;
        foreach (d; deformation) {
            d = vec2(0, 0);
        }
        foreach (y; 0 .. rows()) {
            foreach (x; 0 .. cols()) {
                auto idx = gridIndex(x, y);
                vertexBuffer[idx] = vec2(axisX[x], axisY[y]);
            }
        }
    }

    void setGridAxes(const(float)[] xs, const(float)[] ys) {
        axisX = normalizeAxis(xs);
        axisY = normalizeAxis(ys);
        rebuildBuffers();
    }

    void adoptGridFromAxes(const(float)[] xs, const(float)[] ys) {
        setGridAxes(xs, ys);
    }

    bool deriveAxes(Points)(auto ref Points points, out float[] xs, out float[] ys) const {
        auto count = points.length;
        if (count < 4) return false;

        float[] xCandidates;
        xCandidates.length = count;
        float[] yCandidates;
        yCandidates.length = count;
        foreach (i; 0 .. count) {
            auto point = points[i];
            xCandidates[i] = point.x;
            yCandidates[i] = point.y;
        }

        xs = normalizeAxis(xCandidates);
        ys = normalizeAxis(yCandidates);

        if (xs.length < 2 || ys.length < 2) return false;
        if (xs.length * ys.length != count) return false;

        bool[] seen;
        seen.length = xs.length * ys.length;
        foreach (i; 0 .. count) {
            auto point = points[i];
            int xi = axisIndexOfValue(xs, point.x);
            int yi = axisIndexOfValue(ys, point.y);
            if (xi < 0 || yi < 0) return false;
            size_t idx = cast(size_t)yi * xs.length + cast(size_t)xi;
            seen[idx] = true;
        }
        foreach (flag; seen) {
            if (!flag) return false;
        }
        return true;
    }

    bool adoptFromVertices(Points)(auto ref Points points, bool preserveShape) {
        float[] xs;
        float[] ys;
        if (!deriveAxes(points, xs, ys)) {
            return false;
        }

        setGridAxes(xs, ys);

        if (preserveShape) {
            if (!fillDeformationFromPositions(points)) {
                return false;
            }
        }

        return true;
    }

    bool fillDeformationFromPositions(Points)(auto ref Points positions) {
        auto count = positions.length;
        if (count != deformation.length) {
            deformation[] = vec2(0, 0);
            return false;
        }

        bool[] seen;
        seen.length = deformation.length;
        deformation[] = vec2(0, 0);

        foreach (i; 0 .. count) {
            auto pos = positions[i];
            int xi = axisIndexOfValue(axisX, pos.x);
            int yi = axisIndexOfValue(axisY, pos.y);
            if (xi < 0 || yi < 0) return false;
            auto idx = gridIndex(cast(size_t)xi, cast(size_t)yi);
            deformation[idx] = pos - vertexBuffer[idx];
            seen[idx] = true;
        }

        foreach (flag; seen) {
            if (!flag) {
                deformation[] = vec2(0, 0);
                return false;
            }
        }
        return true;
    }

    bool matrixIsFinite(const mat4 matrix) const {
        foreach (row; matrix.matrix) {
            foreach (val; row) {
                if (!isFinite(val)) {
                    return false;
                }
            }
        }
        return true;
    }

    GridCellCache computeCache(float localX, float localY) {
        GridCellCache cache;
        cache.valid = false;
        if (!hasValidGrid()) {
            return cache;
        }

        if (!isFinite(localX) || !isFinite(localY)) {
            return cache;
        }

        float clampedX = localX;
        if (clampedX < axisX[0]) {
            clampedX = axisX[0];
        } else if (clampedX > axisX[$ - 1]) {
            clampedX = axisX[$ - 1];
        }

        float clampedY = localY;
        if (clampedY < axisY[0]) {
            clampedY = axisY[0];
        } else if (clampedY > axisY[$ - 1]) {
            clampedY = axisY[$ - 1];
        }

        auto resultX = locateInterval(axisX, clampedX);
        auto resultY = locateInterval(axisY, clampedY);

        if (resultX.valid && resultY.valid) {
            cache.cellX = cast(ushort)resultX.index;
            cache.cellY = cast(ushort)resultY.index;
            float u = resultX.weight;
            float v = resultY.weight;
            if (u <= BoundaryTolerance) u = 0;
            else if (u >= 1 - BoundaryTolerance) u = 1;
            if (v <= BoundaryTolerance) v = 0;
            else if (v >= 1 - BoundaryTolerance) v = 1;
            cache.u = u;
            cache.v = v;
            cache.valid = true;
        } else {
            cache.valid = false;
        }
        return cache;
    }

    struct IntervalResult {
        size_t index;
        float weight;
        bool valid;
    }

    IntervalResult locateInterval(const float[] axis, float value) const {
        IntervalResult r;
        if (axis.length < 2) {
            r.valid = false;
            return r;
        }

        if (value < axis[0] || value > axis[$ - 1]) {
            r.valid = false;
            return r;
        }

        size_t idx = axis.length - 2;
        foreach (i; 0 .. axis.length - 1) {
            if (value <= axis[i + 1]) {
                idx = i;
                break;
            }
        }
        float span = axis[idx + 1] - axis[idx];
        float w = span > 0 ? (value - axis[idx]) / span : 0;
        r.index = idx;
        r.weight = w;
        r.valid = true;
        return r;
    }

    void sampleGridPoints(ref Vec2Array dst, const GridCellCache[] caches, bool includeDeformation) const {
        auto len = caches.length;
        dst.length = len;
        if (len == 0) return;

        auto dstX = dst.lane(0);
        auto dstY = dst.lane(1);
        auto baseX = vertexBuffer.lane(0);
        auto baseY = vertexBuffer.lane(1);
        auto deformX = deformation.lane(0);
        auto deformY = deformation.lane(1);

        size_t i = 0;
        for (; i + simdWidth <= len; i += simdWidth) {
            SimdRepr weights00;
            SimdRepr weights10;
            SimdRepr weights01;
            SimdRepr weights11;
            SimdRepr p00x;
            SimdRepr p10x;
            SimdRepr p01x;
            SimdRepr p11x;
            SimdRepr p00y;
            SimdRepr p10y;
            SimdRepr p01y;
            SimdRepr p11y;
            foreach (laneIdx; 0 .. simdWidth) {
                auto cache = caches[i + laneIdx];
                if (!cache.valid) {
                    continue;
                }
                float u = cache.u;
                float v = cache.v;
                float wu0 = 1 - u;
                float wv0 = 1 - v;
                weights00.scalars[laneIdx] = wu0 * wv0;
                weights10.scalars[laneIdx] = u * wv0;
                weights01.scalars[laneIdx] = wu0 * v;
                weights11.scalars[laneIdx] = u * v;

                auto x = cache.cellX;
                auto y = cache.cellY;
                auto idx00 = gridIndex(x, y);
                auto idx10 = gridIndex(x + 1, y);
                auto idx01 = gridIndex(x, y + 1);
                auto idx11 = gridIndex(x + 1, y + 1);

                float p00xVal = baseX[idx00];
                float p00yVal = baseY[idx00];
                float p10xVal = baseX[idx10];
                float p10yVal = baseY[idx10];
                float p01xVal = baseX[idx01];
                float p01yVal = baseY[idx01];
                float p11xVal = baseX[idx11];
                float p11yVal = baseY[idx11];

                if (includeDeformation) {
                    p00xVal += deformX[idx00];
                    p00yVal += deformY[idx00];
                    p10xVal += deformX[idx10];
                    p10yVal += deformY[idx10];
                    p01xVal += deformX[idx01];
                    p01yVal += deformY[idx01];
                    p11xVal += deformX[idx11];
                    p11yVal += deformY[idx11];
                }

                p00x.scalars[laneIdx] = p00xVal;
                p00y.scalars[laneIdx] = p00yVal;
                p10x.scalars[laneIdx] = p10xVal;
                p10y.scalars[laneIdx] = p10yVal;
                p01x.scalars[laneIdx] = p01xVal;
                p01y.scalars[laneIdx] = p01yVal;
                p11x.scalars[laneIdx] = p11xVal;
                p11y.scalars[laneIdx] = p11yVal;
            }

            auto blendX = weights00.vec * p00x.vec
                + weights10.vec * p10x.vec
                + weights01.vec * p01x.vec
                + weights11.vec * p11x.vec;
            auto blendY = weights00.vec * p00y.vec
                + weights10.vec * p10y.vec
                + weights01.vec * p01y.vec
                + weights11.vec * p11y.vec;

            storeVec(dstX, i, blendX);
            storeVec(dstY, i, blendY);
        }

        for (; i < len; ++i) {
            auto cache = caches[i];
            if (!cache.valid) {
                dstX[i] = 0;
                dstY[i] = 0;
                continue;
            }
            auto x = cache.cellX;
            auto y = cache.cellY;
            auto idx00 = gridIndex(x, y);
            auto idx10 = gridIndex(x + 1, y);
            auto idx01 = gridIndex(x, y + 1);
            auto idx11 = gridIndex(x + 1, y + 1);

            float p00xVal = baseX[idx00];
            float p00yVal = baseY[idx00];
            float p10xVal = baseX[idx10];
            float p10yVal = baseY[idx10];
            float p01xVal = baseX[idx01];
            float p01yVal = baseY[idx01];
            float p11xVal = baseX[idx11];
            float p11yVal = baseY[idx11];

            if (includeDeformation) {
                p00xVal += deformX[idx00];
                p00yVal += deformY[idx00];
                p10xVal += deformX[idx10];
                p10yVal += deformY[idx10];
                p01xVal += deformX[idx01];
                p01yVal += deformY[idx01];
                p11xVal += deformX[idx11];
                p11yVal += deformY[idx11];
            }

            float u = cache.u;
            float v = cache.v;
            float wu0 = 1 - u;
            float wv0 = 1 - v;
            float w00 = wu0 * wv0;
            float w10 = u * wv0;
            float w01 = wu0 * v;
            float w11 = u * v;

            dstX[i] = p00xVal * w00 + p10xVal * w10 + p01xVal * w01 + p11xVal * w11;
            dstY[i] = p00yVal * w00 + p10yVal * w10 + p01yVal * w01 + p11yVal * w11;
        }
    }

    void setupChildNoRecurse(bool prepend = false)(Node node) {
        // If Composite wants to propagate MeshGroup-like transforms itself,
        // avoid applying this deformer to its children to prevent double application.
        if (auto comp = cast(Composite)node) {
            if (comp.propagateMeshGroup) {
                releaseChildNoRecurse(node);
                return;
            }
        }
        auto drawable = cast(Deformable)node;
        bool isDrawable = drawable !is null;
        if (isDrawable) {
            if (dynamic) {
                node.postProcessFilters  = node.postProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
                node.preProcessFilters   = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
            } else {
                node.preProcessFilters   = node.preProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
                node.postProcessFilters  = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
            }
        } else if (translateChildren) {
            node.preProcessFilters   = node.preProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
            node.postProcessFilters  = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
        } else {
            releaseChildNoRecurse(node);
        }
    }

    void releaseChildNoRecurse(Node node) {
        node.preProcessFilters  = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
        node.postProcessFilters = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
    }
}
