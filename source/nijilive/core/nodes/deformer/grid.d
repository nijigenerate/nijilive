module nijilive.core.nodes.deformer.grid;

import nijilive.core.nodes;
import nijilive.core.nodes.utils;
import nijilive.core.nodes.defstack;
import nijilive.core.nodes.deformer.base;
import nijilive.core.param;
import nijilive.core;
import nijilive.fmt.serialize;
import nijilive.math;
import std.algorithm : map, sort;
import std.math : approxEqual;
import std.typecons : tuple, Tuple;

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
    GridCellCache[][Node] targetCaches;
    mat4 inverseMatrix;

    enum DefaultAxis = [-0.5f, 0.5f];

public:
    bool dynamic = false;

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
    void update() {
        preProcess();
        deformStack.update();
        inverseMatrix = globalTransform.matrix.inverse;
        Node.update();
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
        targetCaches.clear();
    }

    override
    bool setupChild(Node child) {
        super.setupChild(child);
        void setupRecursive(Node node) {
            setupChildNoRecurse(node);
            if (node.mustPropagate()) {
                foreach (c; node.children) {
                    setupRecursive(c);
                }
            }
        }
        setupRecursive(child);
        return true;
    }

    override
    bool releaseChild(Node child) {
        void releaseRecursive(Node node) {
            releaseChildNoRecurse(node);
            if (!node.mustPropagate()) {
                foreach (c; node.children) {
                    releaseRecursive(c);
                }
            }
        }
        releaseRecursive(child);
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
    Tuple!(vec2[], mat4*, bool) deformChildren(Node target, vec2[] origVertices, vec2[] origDeformation, mat4* origTransform) {
        if (!hasValidGrid()) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }

        auto cachePtr = target in targetCaches;
        if (cachePtr is null || (*cachePtr).length != origVertices.length) {
            cacheTarget(target);
            cachePtr = target in targetCaches;
        }
        if (cachePtr is null) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }
        auto caches = *cachePtr;

        mat4 centerMatrix = inverseMatrix * (*origTransform);
        bool anyChanged = false;

        foreach (i, vertex; origVertices) {
            auto cache = caches[i];
            if (!cache.valid) continue;

            vec2 cVertex = vec2(centerMatrix * vec4(vertex + origDeformation[i], 0, 1));
            vec2 targetPos = sampleDeformed(cache);
            vec2 offsetLocal = targetPos - cVertex;
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
            inverseMatrix = globalTransform.matrix.inverse;
        }

        bool transfer() { return false; }

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
    bool mustPropagate() { return true; }

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
            if (!approxEqual(sorted[write - 1], sorted[i], AxisTolerance, AxisTolerance)) {
                sorted[write] = sorted[i];
                ++write;
            }
        }
        sorted.length = write;
        return sorted;
    }

    int axisIndexOfValue(const(float)[] axis, float value) const {
        foreach (i, v; axis) {
            if (approxEqual(v, value, AxisTolerance, AxisTolerance)) {
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

    GridCellCache computeCache(vec2 localPoint) const {
        GridCellCache cache;
        cache.valid = false;
        if (!hasValidGrid()) {
            return cache;
        }

        auto resultX = locateInterval(axisX, localPoint.x);
        auto resultY = locateInterval(axisY, localPoint.y);

        cache.cellX = cast(ushort)resultX.index;
        cache.cellY = cast(ushort)resultY.index;
        cache.u = resultX.weight;
        cache.v = resultY.weight;
        cache.valid = resultX.valid && resultY.valid;
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

        if (value <= axis[0]) {
            r.index = 0;
            r.weight = 0;
            r.valid = true;
            return r;
        }
        if (value >= axis[$ - 1]) {
            r.index = axis.length - 2;
            r.weight = 1;
            r.valid = true;
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

    void cacheTarget(Node node) {
        vec2[] vertices = getVertices(node);

        mat4 forwardMatrix = node.transform.matrix;
        mat4 inverseLocal = transform.matrix.inverse;
        mat4 tran = inverseLocal * forwardMatrix;

        GridCellCache[] caches;
        caches.length = vertices.length;
        foreach (i, vertex; vertices) {
            vec2 localPos = vec2(tran * vec4(vertex, 0, 1));
            caches[i] = computeCache(localPos);
        }

        targetCaches[node] = caches;
    }

    vec2[] getVertices(Node node) {
        if (auto drawable = cast(Deformable)node) {
            return drawable.vertices;
        }
        return [node.transform.translation.xy];
    }

    void setupChildNoRecurse(bool prepend = false)(Node node) {
        auto drawable = cast(Deformable)node;
        bool isDrawable = drawable !is null;
        if (isDrawable) {
            cacheTarget(node);
            if (dynamic) {
                node.postProcessFilters  = node.postProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
                node.preProcessFilters   = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
            } else {
                node.preProcessFilters   = node.preProcessFilters.upsert!(Node.Filter, prepend)(tuple(1, &deformChildren));
                node.postProcessFilters  = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
            }
        } else {
            targetCaches.remove(node);
            node.preProcessFilters  = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
            node.postProcessFilters = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
        }
    }

    void releaseChildNoRecurse(Node node) {
        node.preProcessFilters  = node.preProcessFilters.removeByValue(tuple(1, &deformChildren));
        node.postProcessFilters = node.postProcessFilters.removeByValue(tuple(1, &deformChildren));
        targetCaches.remove(node);
    }
}
