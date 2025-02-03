module nijilive.core.nodes.deformer.path;

import nijilive.fmt.serialize;
import nijilive.math;
import nijilive.core.nodes;
import nijilive.core.nodes.utils;
import nijilive.core.nodes.defstack;
public import nijilive.core.nodes.deformer.drivers.phys;
public import nijilive.core.nodes.deformer.curve;
import nijilive.core;
import inmath.linalg;

import std.stdio;
import std.math;
import std.algorithm;
import std.array;
import std.range;
import std.typecons;
import nijilive.core;

enum CurveType {
    Bezier,
    Spline
}

package(nijilive) {
    void inInitPathDeformer() {
        inRegisterNodeType!PathDeformer;
        inAliasNodeType!(PathDeformer, "BezierDeformer");
    }
}


@TypeId("PathDeformer")
class PathDeformer : Deformable {
protected:
    mat4 inverseMatrix;
    PhysicsDriver _driver;

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

    void deform(vec2[] deformedControlPoints) {
        deformedCurve = createCurve(deformedControlPoints);
    }

    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true) {
        super.serializeSelfImpl(serializer, recursive);
        serializer.putKey("curve_type");
        serializer.serializeValue(curveType);
        serializer.putKey("vertices");
        auto state = serializer.arrayBegin();
        if (originalCurve) {
            foreach(vertex; originalCurve.controlPoints) {
                serializer.elemBegin;
                serializer.serializeValue(vertex.x);
                serializer.elemBegin;
                serializer.serializeValue(vertex.y);
            }
        }
        serializer.arrayEnd(state);
        if (_driver !is null) {
            serializer.putKey("physics");
            serializer.serializeValue(_driver);
        }
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        super.deserializeFromFghj(data);

        if (!data["curve_type"].isEmpty)
            if (auto exc = data["curve_type"].deserializeValue(curveType)) return exc;

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
            if (!data["physics", "type"].isEmpty) data["physics", "type"].deserializeValue(type); else type = "Pendulum";
            switch (type) {
            case "Pendulum":
                auto phys = new ConnectedPendulumDriver(this);
                data["physics"].deserializeValue(phys);
                _driver = phys;
                break;
            case "SpringPendulum":
                break;
            default:
                break;
            }
        }

        return null;
    }

public:
    CurveType curveType;
    Curve originalCurve;
    Curve prevCurve;
    Curve deformedCurve;


    vec2 prevRoot;
    bool prevRootSet;
    bool driverInitialized = false;
    float[][Node] meshCaches;

    Curve createCurve(vec2[] points) {
        if (curveType == CurveType.Bezier) {
            return new BezierCurve(points);
        } else {
            return new SplineCurve(points);
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
    }

    void driver(PhysicsDriver d) {
        _driver = d;
        if (_driver !is null) {
            _driver.retarget(this);
        }
    }
    auto driver() {
        return _driver;
    }

    override
    void update() {
        if (!driverInitialized && driver !is null && puppet !is null && puppet.enableDrivers ) {
            driver.setup();
            driverInitialized = true;
        }
        preProcess();

        if (vertices.length >= 2) {

            prevCurve = createCurve(zip(vertices(), deformation).map!((t) => t[0] + t[1] ).array);
            clearCache();
            if (driver !is null && puppet !is null && puppet.enableDrivers)
                driver.updateDefaultShape();
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

            deform(zip(vertices(), deformation).map!((t) => t[0] + t[1] ).array);
        }
        inverseMatrix = globalTransform.matrix.inverse;

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

    Tuple!(vec2[], mat4*, bool) deformChildren(Node target, vec2[] origVertices, vec2[] origDeformation, mat4* origTransform) {
        if (!originalCurve || vertices.length < 2) {
            return Tuple!(vec2[], mat4*, bool)(null, null, false);
        }
        mat4 centerMatrix = inverseMatrix * (*origTransform);

        vec2[] cVertices;
        vec2[] deformedClosestPointsA;
        deformedClosestPointsA.length = origVertices.length;
        vec2[] deformedVertices;
        deformedVertices.length = origVertices.length;

        foreach (i, vertex; origVertices) {
            vec2 cVertex;
            cVertex = vec2(centerMatrix * vec4(vertex + origDeformation[i], 0, 1));
            cVertices ~= cVertex;

            if (target !in meshCaches)
                cacheClosestPoints(target);
            float t = meshCaches[target][i];
            vec2 closestPointOriginal = prevCurve.point(t);
            vec2 tangentOriginal = prevCurve.derivative(t).normalized;
            vec2 normalOriginal = vec2(-tangentOriginal.y, tangentOriginal.x);
            float originalNormalDistance = dot(cVertex - closestPointOriginal, normalOriginal); 
            float tangentialDistance = dot(cVertex - closestPointOriginal, tangentOriginal);

            // Find the corresponding point on the deformed Bezier curve
            vec2 closestPointDeformedA = deformedCurve.point(t); // 修正: deformedCurve を使用
            vec2 tangentDeformed = deformedCurve.derivative(t).normalized; // 修正: deformedCurve を使用
            vec2 normalDeformed = vec2(-tangentDeformed.y, tangentDeformed.x);

            // Adjust the vertex to maintain the same normal and tangential distances
            vec2 deformedVertex = closestPointDeformedA + normalDeformed * originalNormalDistance + tangentDeformed * tangentialDistance;

            deformedVertices[i] = deformedVertex;
            deformedClosestPointsA[i] = closestPointOriginal;
        }

        foreach (i, cVertex; cVertices) {
            mat4 inv = centerMatrix.inverse;
            inv[0][3] = 0;
            inv[1][3] = 0;
            inv[2][3] = 0;
            origDeformation[i] += (inv * vec4(deformedVertices[i] - cVertex, 0, 1)).xy;
        }
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
        transformChanged();

        foreach (i, child; children) {
            child.localTransform.translation = (transform.matrix.inverse * childTranslations[i]).xyz;
            child.transformChanged();
        }
    }

    override
    void copyFrom(Node src, bool inPlace = false, bool deepCopy = true) {
        super.copyFrom(src, inPlace, deepCopy);

        if (auto pathDeformer = cast(PathDeformer)src) {
            clearCache();
        }
    }

    override
    bool coverOthers() { return true; }

    override
    bool mustPropagate() { return true; }
}
