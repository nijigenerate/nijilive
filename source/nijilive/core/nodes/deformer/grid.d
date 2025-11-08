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
    vec2[] vertexBuffer;
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
    ref vec2[] vertices() {
        return vertexBuffer;
    }

    override
    void rebuffer(vec2[] gridPoints) {
        if (gridPoints.length == 0 || !adoptFromVertices(gridPoints, false)) {
            adoptGridFromAxes(DefaultAxis, DefaultAxis);
        }
        clearCache();
    }

    override
    string typeId() { return "GridDeformer"; }

    override
    protected void runPreProcessTask() {
        super.runPreProcessTask();
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
    protected void runRenderTask(RenderContext ctx) {
        // GridDeformer does not emit GPU commands.
    }

    override
    Tuple!(vec2[], mat4*, bool) deformChildren(Node target, vec2[] origVertices, vec2[] origDeformation, mat4* origTransform) {
        if (!hasValidGrid()) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }

        if (auto pathTarget = cast(PathDeformer)target) {
            if (!pathTarget.physicsEnabled) {
                return Tuple!(vec2[], mat4*, bool)(null, null, false);
            }
        }

        auto targetName = target is null ? "(null)" : target.name;
        if (!matrixIsFinite(inverseMatrix)) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }
        if (origTransform is null) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }
        if (!matrixIsFinite(*origTransform)) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }

        mat4 centerMatrix = inverseMatrix * (*origTransform);
        bool anyChanged = false;

        GridCellCache[] caches;
        caches.length = origVertices.length;
        vec2[] samplePoints;
        samplePoints.length = origVertices.length;

        if (!matrixIsFinite(centerMatrix)) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }

        bool invalidSamples = false;
        foreach (i, vertex; origVertices) {
            vec2 samplePoint;
            if (dynamic && i < origDeformation.length) {
                samplePoint = vec2(centerMatrix * vec4(vertex + origDeformation[i], 0, 1));
            } else {
                samplePoint = vec2(centerMatrix * vec4(vertex, 0, 1));
            }
            if (!isFinite(samplePoint.x) || !isFinite(samplePoint.y)) {
                invalidSamples = true;
                break;
            }
            samplePoints[i] = samplePoint;
            caches[i] = computeCache(samplePoint);
        }
        if (invalidSamples) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }

        foreach (i, vertex; origVertices) {
            auto cache = caches[i];
            if (!cache.valid) continue;

            vec2 targetPos = sampleDeformed(cache);
            vec2 originalPos = sampleOriginal(cache);
            vec2 offsetLocal = targetPos - originalPos;
            if (!isFinite(offsetLocal.x) || !isFinite(offsetLocal.y)) {
                continue;
            }
            if (offsetLocal == vec2(0, 0)) continue;

            mat4 inv = centerMatrix.inverse;
            inv[0][3] = 0;
            inv[1][3] = 0;
            inv[2][3] = 0;
            origDeformation[i] += (inv * vec4(offsetLocal, 0, 1)).xy;
            anyChanged = true;
        }

        return Tuple!(vec2[], mat4*, bool)(origDeformation, null, anyChanged);
    }

    override
    void applyDeformToChildren(Parameter[] params, bool recursive = true) {
        void update(vec2[] deformationValues) {
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

    vec2 gridPointOriginal(size_t x, size_t y) const {
        return vertexBuffer[gridIndex(x, y)];
    }

    vec2 gridPointDeformed(size_t x, size_t y) const {
        auto idx = gridIndex(x, y);
        return vertexBuffer[idx] + deformation[idx];
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
        foreach (ref d; deformation) {
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

    bool deriveAxes(const(vec2)[] points, out float[] xs, out float[] ys) const {
        if (points.length < 4) return false;

        float[] xCandidates;
        xCandidates.length = points.length;
        float[] yCandidates;
        yCandidates.length = points.length;
        foreach (i, point; points) {
            xCandidates[i] = point.x;
            yCandidates[i] = point.y;
        }

        xs = normalizeAxis(xCandidates);
        ys = normalizeAxis(yCandidates);

        if (xs.length < 2 || ys.length < 2) return false;
        if (xs.length * ys.length != points.length) return false;

        bool[] seen;
        seen.length = xs.length * ys.length;
        foreach (point; points) {
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

    bool adoptFromVertices(const(vec2)[] points, bool preserveShape) {
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

    bool fillDeformationFromPositions(const(vec2)[] positions) {
        if (positions.length != deformation.length) {
            deformation[] = vec2(0, 0);
            return false;
        }

        bool[] seen;
        seen.length = deformation.length;
        deformation[] = vec2(0, 0);

        foreach (pos; positions) {
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

    GridCellCache computeCache(vec2 localPoint) {
        GridCellCache cache;
        cache.valid = false;
        if (!hasValidGrid()) {
            return cache;
        }

        if (!isFinite(localPoint.x) || !isFinite(localPoint.y)) {
            return cache;
        }

        float clampedX = localPoint.x;
        if (clampedX < axisX[0]) {
            clampedX = axisX[0];
        } else if (clampedX > axisX[$ - 1]) {
            clampedX = axisX[$ - 1];
        }

        float clampedY = localPoint.y;
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

    vec2 sampleOriginal(GridCellCache cache) const {
        auto x = cache.cellX;
        auto y = cache.cellY;
        return bilinear(
            gridPointOriginal(x, y),
            gridPointOriginal(x + 1, y),
            gridPointOriginal(x, y + 1),
            gridPointOriginal(x + 1, y + 1),
            cache.u,
            cache.v
        );
    }

    vec2 sampleDeformed(GridCellCache cache) const {
        auto x = cache.cellX;
        auto y = cache.cellY;
        return bilinear(
            gridPointDeformed(x, y),
            gridPointDeformed(x + 1, y),
            gridPointDeformed(x, y + 1),
            gridPointDeformed(x + 1, y + 1),
            cache.u,
            cache.v
        );
    }

    vec2 bilinear(vec2 p00, vec2 p10, vec2 p01, vec2 p11, float u, float v) const {
        auto a = p00 * (1 - u) + p10 * u;
        auto b = p01 * (1 - u) + p11 * u;
        return a * (1 - v) + b * v;
    }

    void setupChildNoRecurse(bool prepend = false)(Node node) {
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
