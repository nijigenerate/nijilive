module nijilive.core.nodes.deformer.bezier;

import nijilive.fmt.serialize;
import nijilive.math;
import nijilive.core.nodes;
import nijilive.core.nodes.utils;
import nijilive.core.nodes.defstack;
import nijilive.core.nodes.deformer.drivers.phys;
import nijilive.core;
import inmath.linalg;

import std.stdio;
import std.math;
import std.algorithm;
import std.array;
import std.range;
import std.typecons;
import nijilive.core;

private {
    // Binomial coefficient function
    long binomial(long n, long k) {
        if (k > n) return 0;
        if (k == 0 || k == n) return 1;
        long c = 1;
        for (long i = 1; i <= k; ++i) {
            c = c * (n - (k - i)) / i;
        }
        return c;
    }
}

package(nijilive) {
    void inInitBezierDeformer() {
        inRegisterNodeType!BezierDeformer;
    }
}

struct BezierCurve {
    vec2[] controlPoints;
    vec2[] derivatives; // Precomputed Bezier curve derivatives

    this(vec2[] controlPoints) {
        this.controlPoints = controlPoints.dup;
        this.derivatives = new vec2[controlPoints.length > 0? controlPoints.length - 1: 0];
        calculateDerivatives();
    }

    // Compute the point on the Bezier curve
    vec2 point(float t) {
        long n = controlPoints.length - 1;
        vec2 result = vec2(0.0, 0.0);
        float oneMinusT = 1 - t;
        float[] tPowers = new float[n + 1];
        float[] oneMinusTPowers = new float[n + 1];
        tPowers[0] = 1;
        oneMinusTPowers[0] = 1;
        for (int i = 1; i <= n; ++i) {
            tPowers[i] = tPowers[i - 1] * t;
            oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
        }
        for (int i = 0; i <= n; ++i) {
            float binomialCoeff = float(binomial(n, i));
            result += binomialCoeff * oneMinusTPowers[n - i] * tPowers[i] * controlPoints[i];
        }
        return result;
    }

    // Compute the derivatives of the Bezier curve
    void calculateDerivatives() {
        long n = controlPoints.length - 1;
        for (int i = 0; i < n; ++i) {
            derivatives[i] = (controlPoints[i + 1] - controlPoints[i]) * n;
        }
    }

    // Compute the point of the derivative of the Bezier curve
    vec2 derivative(float t) {
        long n = derivatives.length;
        vec2 result = vec2(0.0, 0.0);
        float oneMinusT = 1 - t;
        float[] tPowers = new float[n];
        float[] oneMinusTPowers = new float[n];
        tPowers[0] = 1;
        oneMinusTPowers[0] = 1;
        for (int i = 1; i < n; ++i) {
            tPowers[i] = tPowers[i - 1] * t;
            oneMinusTPowers[i] = oneMinusTPowers[i - 1] * oneMinusT;
        }
        for (int i = 0; i < n; ++i) {
            float binomialCoeff = float(binomial(n - 1, i));
            result += binomialCoeff * oneMinusTPowers[n - 1 - i] * tPowers[i] * derivatives[i];
        }
        return result;
    }

    // Find the closest point on the Bezier curve
    float closestPoint(vec2 point, int nSamples = 100) {
        float minDistanceSquared = float.max;
        float closestT = 0.0;
        for (int i = 0; i < nSamples; ++i) {
            float t = i / float(nSamples - 1);
            vec2 bezierPoint = this.point(t);
            float distanceSquared = (bezierPoint - point).lengthSquared;
            if (distanceSquared < minDistanceSquared) {
                minDistanceSquared = distanceSquared;
                closestT = t;
            }
        }
        return closestT;
    }

    T opCast(T: bool)() { return controlPoints.length > 0; }
}


@TypeId("BezierDeformer")
class BezierDeformer : Deformable {
protected:
    mat4 inverseMatrix;
    PhysicsDriver driver;

    vec2[] getVertices(Node node) {
        vec2[] vertices;
        if (auto drawable = cast(Drawable)node) {
            vertices = drawable.getMesh().vertices;
        } else {
            vertices = [node.transform.translation.xy];
        }
        return vertices;
    }

    // Cache the closest points on the Bezier curve for each vertex in the mesh
    void cacheClosestPoints(Node node, int nSamples = 100) {
        auto vertices = getVertices(node);
        meshCaches[node] = new float[vertices.length];

        if (originalCurve) {
            mat4 forwardMatrix = node.transform.matrix;
            mat4 inverseMatrix = transform.matrix.inverse;
            mat4 tran = inverseMatrix * forwardMatrix;
            foreach (i, vertex; getVertices(node)) {
                vec2 cVertex = (tran * vec4(vertex, 0, 1)).xy;
                meshCaches[node][i] = originalCurve.closestPoint(cVertex, nSamples);
            }
        }
    }

    // Deform all registered meshes using the deformed Bezier curve
    void deform(vec2[] deformedControlPoints) {
        deformedCurve = BezierCurve(deformedControlPoints);
    }


    // Implementation for adjustment

    // Calculate the intersection of two lines
    bool intersect(vec2 p1, vec2 p2, vec2 p3, vec2 p4, out vec2 result) {
        vec2 s1 = p2 - p1;
        vec2 s2 = p4 - p3;

        float s = (-s1.y * (p1.x - p3.x) + s1.x * (p1.y - p3.y)) / (-s2.x * s1.y + s1.x * s2.y);
        float t = (s2.x * (p1.y - p3.y) - s2.y * (p1.x - p3.x)) / (-s2.x * s1.y + s1.x * s2.y);

        if (0 <= s && s <= 1 && 0 <= t && t <= 1) {
            result = (p1 + t * s1);
            return true;
        }
        return false;
    }

    // Create a grid for optimization
    auto createGrid(vec2[] vertices, float cellSize) {
        ulong[][Tuple!(int, int)] grid;

        foreach (i, vertex; vertices) {
            auto gridKey = tuple(cast(int)(vertex.x / cellSize), cast(int)(vertex.y / cellSize));
            if (gridKey in grid) {
                grid[gridKey] ~= i;
            } else {
                grid[gridKey] = [i];
            }
        }
        return grid;
    }

    // Get the cache of adjacent cells
    auto getAdjacentCellsCache() {
        Tuple!(int, int)[][Tuple!(int, int)] cache;

        foreach (x; -1 .. 2) {
            foreach (y; -1 .. 2) {
                cache[tuple(x, y)] = [
                    tuple(x-1, y-1), tuple(x, y-1), tuple(x+1, y-1),
                    tuple(x-1, y), tuple(x, y), tuple(x+1, y),
                    tuple(x-1, y+1), tuple(x, y+1), tuple(x+1, y+1)
                ];
            }
        }
        return cache;
    }

    // Adjust vertices to maintain distances
    void adjust(ref vec2[] vertices, vec2[] closestPointsA, float cellSize = 5.0) {
        auto grid = createGrid(vertices, cellSize);
        auto adjacentCellsCache = getAdjacentCellsCache();
        foreach (_; 0 .. 10) {  // Limit the number of iterations to avoid infinite loops
            vec2[] intersections;
            Tuple!(ulong, ulong)[] pairs;
            foreach (cell, indices; grid) {
                auto adjacentCells = cell in adjacentCellsCache ? adjacentCellsCache[cell]: [];
                foreach (i; indices) {
                    foreach (adjCell; adjacentCells) {
                        if (adjCell in grid) {
                            foreach (j; grid[adjCell]) {
                                if (i >= j) continue;
                                vec2 intersection;
                                if (intersect(closestPointsA[i], vertices[i], closestPointsA[j], vertices[j], intersection)) {
                                    intersections ~= intersection;
                                    pairs ~= tuple(cast(ulong)i, cast(ulong)j);
                                }
                            }
                        }
                    }
                }
            }

            if (intersections.empty) break;

            foreach (k, pair; pairs) {
                vertices[pair[0]] = intersections[k];
                vertices[pair[1]] = intersections[k];
            }

            grid = createGrid(vertices, cellSize);
        }
    }

    /**
        Allows serializing self data (with pretty serializer)
    */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive=true) {
        super.serializeSelfImpl(serializer, recursive);
        serializer.putKey("vertices");
        auto state = serializer.arrayBegin();
        foreach(vertex; originalCurve.controlPoints) {
            serializer.elemBegin;
            serializer.serializeValue(vertex.x);
            serializer.elemBegin;
            serializer.serializeValue(vertex.y);
        }
        serializer.arrayEnd(state);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        super.deserializeFromFghj(data);

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
        return null;
    }

public:
    vec2 prevRoot;
    bool prevRootSet;
    bool driverInitialized = false;
    BezierCurve originalCurve;
    BezierCurve deformedCurve;  // 追加: 変形後のベジェ曲線を保持する
    float[][Node] meshCaches; // Cache for each Mesh

    override
    ref vec2[] vertices() {
        return originalCurve.controlPoints;
    }

    this(Node parent = null) {
        super(parent);
        driver = null;
        prevRootSet = false;
    }

    override
    string typeId() { return "BezierDeformer"; }

    override
    void rebuffer(vec2[] originalControlPoints) {
        this.originalCurve = BezierCurve(originalControlPoints);
        this.deformation.length = originalControlPoints.length;
        clearCache();
        driverInitialized = false;
    }

    void setDriver(PhysicsDriver driver) {
        this.driver = driver;
        if (driver !is null) {
            driver.retarget(this);
        }
    }

    override
    void update() {
        if (!driverInitialized && driver !is null && puppet !is null && puppet.enableDrivers ) {
            driver.setup();
            driver.updateDefaultShape();
            driverInitialized = true;
        }
        preProcess();

        deformStack.update();
        if (driver !is null && puppet !is null && puppet.enableDrivers) {
            if (prevRootSet) {
                vec2 root = (transform.matrix * vec4(0, 0, 0, 1)).xy;
                vec2 deform = root - prevRoot;
                if (deformation.length > 0) {
                    deform += deformation[0];
                }
                driver.reset();
                driver.enforce(deform);
                driver.rotate(transform.rotation.z);
                driver.update();
            }
            prevRoot = (transform.matrix * vec4(0, 0, 0, 1)).xy;
            prevRootSet = true;
        }

        inverseMatrix = globalTransform.matrix.inverse;

        if (vertices.length > 0) {
            vec2[] transformedVertices;
            transformedVertices.length = vertices.length;
            foreach(i, vertex; vertices) {
                transformedVertices[i] = vertex+this.deformation[i];
            }

            deform(transformedVertices);
        }

        Node.update();
        this.updateDeform();
    }

    override
    void build(bool force = false) { 
        foreach (child; children) {
            setupChild(child);
        }
        setupSelf();
        super.build(force);
    }

    // Add a mesh to the deformer and initialize its cache
    override
    void setupChild(Node child) {
        super.setupChild(child);
        void setGroup(Node node) {
            auto drawable = cast(Drawable)node;
            auto composite = cast(Composite)node;
            bool isDrawable = drawable !is null;
            bool mustPropagate = node.mustPropagate();

            if (isDrawable) {
                cacheClosestPoints(node);
                node.preProcessFilters  = node.preProcessFilters.upsert(&deformChildren);
            } else {
                meshCaches.remove(node); 
                node.preProcessFilters  = node.preProcessFilters.removeByValue(&deformChildren);
            }

            // traverse children if node is Drawable and is not MeshGroup instance.
            if (mustPropagate) {
                foreach (child; node.children) {
                    setGroup(child);
                }
            }
        }

        setGroup(child);
    }

    override
    void releaseChild(Node child) {
        void unsetGroup(Node node) {
            node.preProcessFilters = node.preProcessFilters.removeByValue(&deformChildren);
            bool mustPropagate = !node.mustPropagate();
            if (mustPropagate) {
                foreach (child; node.children) {
                    unsetGroup(child);
                }
            }
        }
        unsetGroup(child);
        super.releaseChild(child);
    }

    // Update method to deform a single mesh
    Tuple!(vec2[], mat4*, bool) deformChildren(Node target, vec2[] origVertices, vec2[] origDeformation, mat4* origTransform) {
        if (!originalCurve || originalCurve.controlPoints.length < 2) return Tuple!(vec2[], mat4*, bool)(null, null, false);
        mat4 centerMatrix = inverseMatrix * (*origTransform);

        vec2[] cVertices;
        vec2[] deformedClosestPointsA;
        deformedClosestPointsA.length = origVertices.length;
        vec2[] deformedVertices;
        deformedVertices.length = origVertices.length;

        foreach (i, vertex; origVertices) {
            vec2 cVertex;
                cVertex = vec2(centerMatrix * vec4(vertex + origDeformation[i], 0, 1));            // Find the closest point on the original Bezier curve
            cVertices ~= cVertex;

            if (target !in meshCaches)
                cacheClosestPoints(target);
            float t = meshCaches[target][i];
            vec2 closestPointOriginal = originalCurve.point(t);
            vec2 tangentOriginal = originalCurve.derivative(t).normalized;
            vec2 normalOriginal = vec2(-tangentOriginal.y, tangentOriginal.x);
            float originalNormalDistance = dot(cVertex - closestPointOriginal, normalOriginal);
            float tangentialDistance = dot(cVertex - closestPointOriginal, tangentOriginal);

            // Find the corresponding point on the deformed Bezier curve
            vec2 closestPointDeformedA = deformedCurve.point(t);
            vec2 tangentDeformed = deformedCurve.derivative(t).normalized;
            vec2 normalDeformed = vec2(-tangentDeformed.y, tangentDeformed.x);

            // Adjust the vertex to maintain the same normal and tangential distances
            vec2 deformedVertex = closestPointDeformedA + normalDeformed * originalNormalDistance + tangentDeformed * tangentialDistance;

            deformedVertices[i] = deformedVertex;
            deformedClosestPointsA[i] = closestPointDeformedA;

        }

        adjust(deformedVertices, deformedClosestPointsA);

        foreach (i, cVertex; cVertices) {
            mat4 inv = centerMatrix.inverse;
            inv[0][3] = 0;
            inv[1][3] = 0;
            inv[2][3] = 0;
            origDeformation[i] += (inv * vec4(deformedVertices[i] - cVertex, 0, 1)).xy;
        }
        //mesh.vertices = deformedVertices;
        return Tuple!(vec2[], mat4*, bool)(origDeformation, null, true);
    }

    override
    void clearCache() {
        meshCaches.clear();
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
        /*
        vec2 center = (bounds.xy + bounds.zw) / 2;
        if (parent !is null) {
            center = (parent.transform.matrix.inverse * vec4(center, 0, 1)).xy;
        }
        auto diff = center - localTransform.translation.xy;
        localTransform.translation.x = center.x;
        localTransform.translation.y = center.y;
        */
        transformChanged();

        foreach (i, child; children) {
            child.localTransform.translation = (transform.matrix.inverse * childTranslations[i]).xyz;
            child.transformChanged();
        }
    }

    override
    void copyFrom(Node src, bool inPlace = false, bool deepCopy = true) {
        super.copyFrom(src, inPlace, deepCopy);

        if (auto bezier = cast(BezierDeformer)src) {
            //TBD
            clearCache();
        }
    }

    override
    bool coverOthers() { return true; }

    override
    bool mustPropagate() { return false; }

}
