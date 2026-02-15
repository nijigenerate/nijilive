/*
    nijilive Drawable base class
    previously Inochi2D Drawable base class

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.drawable;
import nijilive.integration;
import nijilive.fmt.serialize;
import nijilive.math;
import nijilive.math.veca_ops : transformAssign, transformAdd;
import nijilive.math.triangle;
import std.exception;
import nijilive.core.dbg;
import nijilive.core;
import std.string;
import std.typecons;
import std.algorithm.searching;
import std.algorithm.mutation: remove;
import nijilive.core.nodes.utils;
version(InDoesRender) import nijilive.core.runtime_state : currentRenderBackend;
import nijilive.core.render.shared_deform_buffer;
import nijilive.core.render.backends : RenderResourceHandle;
import nijilive.core.render.scheduler : RenderContext;
private const ptrdiff_t NOINDEX = cast(ptrdiff_t)-1;

package(nijilive) {
    void inInitDrawable() {
        version(InDoesRender) currentRenderBackend().initializeDrawableResources();
    }


    /**
        Binds the internal vertex array for rendering
    */
    void incDrawableBindVAO() {
        version(InDoesRender) currentRenderBackend().bindDrawableVao();
    }

    bool doGenerateBounds = false;
}

/**
    Sets whether nijilive should keep track of the bounds
*/
void inSetUpdateBounds(bool state) {
    doGenerateBounds = true;
}

bool inGetUpdateBounds() {
    return doGenerateBounds;
}

/**
    Nodes that are meant to render something in to the nijilive scene
    Other nodes don't have to render anything and serve mostly other 
    purposes.

    The main types of Drawables are Parts and Masks
*/
@TypeId("Drawable")
abstract class Drawable : Deformable {
protected:

    void updateIndices() {
        version (InDoesRender) {
            currentRenderBackend().uploadDrawableIndices(ibo, data.indices);
        }
    }

    override
    void updateVertices() {
        sharedVertexResize(data.vertices, data.vertices.length);
        sharedVertexMarkDirty();
        sharedDeformResize(deformation, vertices.length);
        this.deformation[] = vec2(0, 0);
        this.updateDeform();
    }

    Tuple!(Vec2Array, mat4*, bool) nodeAttachProcessor(Node node, Vec2Array origVertices, Vec2Array origDeformation, mat4* origTransform) {
        bool changed = false;
        vec2 nodeOrigin = (this.transform.matrix.inverse * vec4(node.transform.translation, 1));
//        writefln("%s-->%s: nodeOrigin=%s", name, node.name, nodeOrigin);
        if (node !in attachedIndex)
            attachedIndex[node] = findSurroundingTriangle(nodeOrigin, this.data);
        auto triangle = attachedIndex[node];
        if (triangle) {
            vec2 transformedOrigin;
            float rotateVert, rotateHorz;
            nlCalculateTransformInTriangle(this.data.vertices, triangle, this.deformation, nodeOrigin, transformedOrigin, rotateVert, rotateHorz);
//            mat4* newMat = new mat4;
//            *newMat = *origTransform;
            transformedOrigin -= nodeOrigin;
            changed = true;
            node.setValue("transform.t.x", transformedOrigin.x);
            node.setValue("transform.t.y", transformedOrigin.y);
            node.setValue("transform.r.z", (rotateHorz + rotateVert)/2.0);
            transformChanged();
//            writefln("%s, %s, %s, %s", name, this.deformation[triangle[0]], this.deformation[triangle[1]], this.deformation[triangle[2]]);
//            writefln("  ->%s: %s, %.2f, %.2f", node.name, transformedOrigin + nodeOrigin, rotateVert, rotateHorz);
//            *newMat = newMat.translate(transformedOrigin.x, transformedOrigin.y, 0.0).rotateZ((rotateVert + rotateHorz) / 2.0);
            return tuple(Vec2Array.init, cast(mat4*)null, changed);
        } else {
            return tuple(Vec2Array.init, cast(mat4*)null, false);
        }
    }

    Tuple!(Vec2Array, mat4*, bool) weldingProcessor(Node target, Vec2Array origVertices, Vec2Array origDeformation, mat4* origTransform) {
        auto linkIndex = welded.countUntil!((a)=>a.target == target)();
        bool changed = false;
        WeldingLink link = welded[linkIndex];
        if (postProcessed < 2)
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, changed);
        if (link.target in weldingApplied && weldingApplied[link.target] || 
            this in link.target.weldingApplied && link.target.weldingApplied[this])
            return Tuple!(Vec2Array, mat4*, bool)(Vec2Array.init, null, changed);
//        import std.stdio;
//        writefln("welding: %s(%b) --> %s(%b)", name, postProcessed, target.name, target.postProcessed);
        weldingApplied[link.target] = true;
        link.target.weldingApplied[this] = true;
        float weldingWeight = min(1, max(0, link.weight));
        auto pairCount = link.indices.length < vertices.length ? link.indices.length : vertices.length;
        if (pairCount == 0) {
            return Tuple!(Vec2Array, mat4*, bool)(origDeformation, null, changed);
        }

        size_t[] selfIndices;
        size_t[] targetIndices;
        selfIndices.reserve(pairCount);
        targetIndices.reserve(pairCount);
        for (size_t i = 0; i < pairCount; ++i) {
            ptrdiff_t mapped = link.indices[i];
            if (mapped == NOINDEX || mapped < 0) {
                continue;
            }
            auto targetIdx = cast(size_t)mapped;
            if (targetIdx >= origVertices.length) {
                continue;
            }
            selfIndices ~= i;
            targetIndices ~= targetIdx;
        }

        auto validCount = selfIndices.length;
        if (validCount == 0) {
            return Tuple!(Vec2Array, mat4*, bool)(origDeformation, null, false);
        }

        Vec2Array selfLocal = gatherVec2(vertices, selfIndices);
        Vec2Array selfDelta = gatherVec2(deformation, selfIndices);
        selfLocal += selfDelta;

        Vec2Array targetLocal = gatherVec2(origVertices, targetIndices);
        Vec2Array targetDelta = gatherVec2(origDeformation, targetIndices);
        targetLocal += targetDelta;

        mat4 selfMatrix = overrideTransformMatrix ? overrideTransformMatrix.matrix : transform.matrix;
        mat4 targetMatrix = *origTransform;

        Vec2Array selfWorld;
        transformAssign(selfWorld, selfLocal, selfMatrix);

        Vec2Array targetWorld;
        transformAssign(targetWorld, targetLocal, targetMatrix);

        Vec2Array blended = targetWorld.dup;
        blended *= (1 - weldingWeight);
        Vec2Array weightedSelf = selfWorld.dup;
        weightedSelf *= weldingWeight;
        blended += weightedSelf;

        Vec2Array deltaSelf = blended.dup;
        deltaSelf -= selfWorld;
        Vec2Array deltaTarget = blended.dup;
        deltaTarget -= targetWorld;

        mat4 selfMatrixInv = selfMatrix.inverse;
        selfMatrixInv[0][3] = 0;
        selfMatrixInv[1][3] = 0;
        selfMatrixInv[2][3] = 0;

        mat4 targetMatrixInv = targetMatrix.inverse;
        targetMatrixInv[0][3] = 0;
        targetMatrixInv[1][3] = 0;
        targetMatrixInv[2][3] = 0;

        Vec2Array localSelf = makeZeroVecArray(validCount);
        transformAdd(localSelf, deltaSelf, selfMatrixInv);
        Vec2Array localTarget = makeZeroVecArray(validCount);
        transformAdd(localTarget, deltaTarget, targetMatrixInv);

        scatterAddVec2(localSelf, selfIndices, deformation, changed);
        scatterAddVec2(localTarget, targetIndices, origDeformation, changed);
        sharedDeformMarkDirty();

        return tuple(origDeformation, cast(mat4*)null, changed);
    }

    override
    void updateDeform() {
        super.updateDeform();
        sharedDeformMarkDirty();
        this.updateBounds();
    }

    /**
        Backend Index Buffer Object handle
    */
    RenderResourceHandle ibo;

    /**
        Offset within the shared deformation buffer
    */
    package(nijilive) size_t deformSliceOffset;

    /**
        Offset within the shared vertex buffer
    */
    package(nijilive) size_t vertexSliceOffset;

    /**
        Offset within the shared UV buffer
    */
    package(nijilive) size_t uvSliceOffset;

    /**
        The mesh data of this part

        NOTE: DO NOT MODIFY!
        The data in here is only to be used for reference.
    */
    MeshData data;

    /**
        Binds Index Buffer for rendering
    */
    final void bindIndex() {
        version (InDoesRender) {
            currentRenderBackend().drawDrawableElements(ibo, data.indices.length);
        }
    }

        /**
            Allows serializing self data (with pretty serializer)
        */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive=true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);
        if (flags & SerializeNodeFlags.Geometry) {
            serializer.putKey("mesh");
            serializer.serializeValue(data);
        }

        // welded links refer to other drawable nodes → Links category
        if ((flags & SerializeNodeFlags.Links) && welded.length > 0) {
            serializer.putKey("weldedLinks");
            auto state = serializer.listBegin();
                foreach(link; welded) {
                    serializer.elemBegin;
                    serializer.serializeValue(link);
                }
            serializer.listEnd(state);
        }

    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
//        import std.stdio : writeln;
        super.deserializeFromFghj(data);
        if (auto exc = data["mesh"].deserializeValue(this.data)) return exc;

        this.vertices = this.data.vertices.dup;

        if (!data["weldedLinks"].isEmpty) {
            data["weldedLinks"].deserializeValue(this.welded);
        }

        // Update indices and vertices
        this.updateIndices();
        this.updateVertices();
        return null;
    }

public:

    struct WeldingLink {
        @Name("targetUUID")
        uint targetUUID; 
        @Ignore
        Drawable target;
        @Name("indices")
        ptrdiff_t[] indices;
        @Name("weight")
        float weight;
    };
    WeldingLink[] welded;
    bool[Drawable] weldingApplied;
    int[][Node] attachedIndex;

    abstract void renderMask(bool dodge = false);

    /**
        Constructs a new drawable surface
    */
    this(Node parent = null) {
        super(parent);
        sharedDeformRegister(deformation, &deformSliceOffset);
        sharedVertexRegister(data.vertices, &vertexSliceOffset);
        sharedUvRegister(data.uvs, &uvSliceOffset);

        version(InDoesRender) {
            currentRenderBackend().createDrawableBuffers(ibo);
        }
    }

    private Vec2Array gatherVec2(const Vec2Array source, const size_t[] indices) {
        Vec2Array result;
        result.length = indices.length;
        auto resX = result.lane(0);
        auto resY = result.lane(1);
        auto srcX = source.lane(0);
        auto srcY = source.lane(1);
        for (size_t i = 0; i < indices.length; ++i) {
            auto idx = indices[i];
            resX[i] = srcX[idx];
            resY[i] = srcY[idx];
        }
        return result;
    }

    private Vec2Array makeZeroVecArray(size_t count) {
        Vec2Array result;
        result.length = count;
        auto rx = result.lane(0);
        auto ry = result.lane(1);
        rx[] = 0;
        ry[] = 0;
        return result;
    }

    private void scatterAddVec2(const Vec2Array delta, const size_t[] indices, ref Vec2Array target, ref bool changed) {
        auto deltaX = delta.lane(0);
        auto deltaY = delta.lane(1);
        auto targetX = target.lane(0);
        auto targetY = target.lane(1);
        for (size_t i = 0; i < indices.length; ++i) {
            auto idx = indices[i];
            auto dx = deltaX[i];
            auto dy = deltaY[i];
            if (dx != 0 || dy != 0) {
                changed = true;
            }
            targetX[idx] += dx;
            targetY[idx] += dy;
        }
    }

    /**
        Constructs a new drawable surface
    */
    this(MeshData data, Node parent = null) {
        this(data, inCreateUUID(), parent);
    }

    /**
        Constructs a new drawable surface
    */
    this(MeshData data, uint uuid, Node parent = null) {
        super(uuid, parent);
        this.data = data;
        sharedDeformRegister(deformation, &deformSliceOffset);
        sharedVertexRegister(this.data.vertices, &vertexSliceOffset);
        sharedUvRegister(this.data.uvs, &uvSliceOffset);

        // Set the deformable points to their initial position
        this.vertices = data.vertices.dup;

        version(InDoesRender) {
            currentRenderBackend().createDrawableBuffers(ibo);
        }

        // Update indices and vertices
        this.updateIndices();
        this.updateVertices();
    }

    ~this() {
        sharedDeformUnregister(deformation);
        sharedVertexUnregister(data.vertices);
        sharedUvUnregister(data.uvs);
    }

    override
    ref Vec2Array vertices() {
        return data.vertices;
    }

    /**
        The bounds of this drawable
    */
    vec4 bounds;

    override
    protected void runBeginTask(ref RenderContext ctx) {
        weldingApplied.clear();
        foreach (link; welded)
            weldingApplied[link.target] = false;
        super.runBeginTask(ctx);
    }

    /**
        Draws the drawable
    */
    override
    void drawOne() {
        super.drawOne();
    }

    /**
        Draws the drawable without any processing
    */
    void drawOneDirect(bool forMasking) { }

    override
    string typeId() { return "Drawable"; }

    /**
        Updates the drawable's bounds
    */
    void updateBounds() {
        if (!doGenerateBounds) return;

        // Calculate bounds
        mat4 matrix = getDynamicMatrix();
        if (vertices.length == 0) {
            Transform wtransform = transform;
            bounds = vec4(wtransform.translation.xyxy);
            return;
        }

        vec2 first = vec2(matrix * vec4(vertices[0] + deformation[0], 0, 1));
        bounds = vec4(first.xyxy);
        for (size_t i = 1; i < vertices.length; ++i) {
            vec2 vertOriented = vec2(matrix * vec4(vertices[i] + deformation[i], 0, 1));
            if (vertOriented.x < bounds.x) bounds.x = vertOriented.x;
            if (vertOriented.y < bounds.y) bounds.y = vertOriented.y;
            if (vertOriented.x > bounds.z) bounds.z = vertOriented.x;
            if (vertOriented.y > bounds.w) bounds.w = vertOriented.y;
        }
    }

    /**
        Draws bounds
    */
    override
    void drawBounds() {
//        if (!doGenerateBounds) return;
        assert(doGenerateBounds);
        if (vertices.length == 0) return;
        
        float width = bounds.z-bounds.x;
        float height = bounds.w-bounds.y;
        Vec3Array boundsPoints = Vec3Array([
            vec3(bounds.x, bounds.y, 0),
            vec3(bounds.x + width, bounds.y, 0),
            
            vec3(bounds.x + width, bounds.y, 0),
            vec3(bounds.x + width, bounds.y+height, 0),
            
            vec3(bounds.x + width, bounds.y+height, 0),
            vec3(bounds.x, bounds.y+height, 0),
            
            vec3(bounds.x, bounds.y+height, 0),
            vec3(bounds.x, bounds.y, 0),
        ]);
        inDbgSetBuffer(boundsPoints);
        inDbgLineWidth(3);
        if (oneTimeTransform !is null)
            inDbgDrawLines(vec4(.5, .5, .5, 1), (*oneTimeTransform));
        else
            inDbgDrawLines(vec4(.5, .5, .5, 1));
        inDbgLineWidth(1);
    }
    
    version (InDoesRender) {
        /**
            Draws line of mesh
        */
        void drawMeshLines(vec4 color = vec4(.5, .5, .5, 1)) {
            if (vertices.length == 0 || data.indices.length == 0) return;

            auto trans = getDynamicMatrix();
            if (oneTimeTransform !is null)
                trans = (*oneTimeTransform) * trans;

            ushort[] indices = data.indices;

            Vec3Array points;
            points.length = indices.length * 2;
            foreach(i; 0..indices.length/3) {
                size_t ix = i*3;
                size_t iy = ix*2;
                auto indice = indices[ix];

                points[iy+0] = vec3(vertices[indice]-data.origin+deformation[indice], 0);
                points[iy+1] = vec3(vertices[indices[ix+1]]-data.origin+deformation[indices[ix+1]], 0);

                points[iy+2] = vec3(vertices[indices[ix+1]]-data.origin+deformation[indices[ix+1]], 0);
                points[iy+3] = vec3(vertices[indices[ix+2]]-data.origin+deformation[indices[ix+2]], 0);

                points[iy+4] = vec3(vertices[indices[ix+2]]-data.origin+deformation[indices[ix+2]], 0);
                points[iy+5] = vec3(vertices[indice]-data.origin+deformation[indice], 0);
            }

            inDbgSetBuffer(points);
            inDbgDrawLines(color, trans);
        }

        /**
            Draws the points of the mesh
        */
        void drawMeshPoints() {
            if (vertices.length == 0) return;

            auto trans = getDynamicMatrix();
            if (oneTimeTransform !is null)
                trans = (*oneTimeTransform) * trans;
            Vec3Array points;
            points.length = vertices.length;
            foreach(i, point; vertices) {
                points[i] = vec3(point-data.origin+deformation[i], 0);
            }

            inDbgSetBuffer(points);
            inDbgPointsSize(8);
            inDbgDrawPoints(vec4(0, 0, 0, 1), trans);
            inDbgPointsSize(4);
            inDbgDrawPoints(vec4(1, 1, 1, 1), trans);
        }
    }

    /**
        Returns the mesh data for this Part.
    */
    final ref MeshData getMesh() {
        return this.data;
    }

    /**
        Changes this mesh's data
    */
    void rebuffer(ref MeshData data) {
        sharedVertexResize(this.data.vertices, data.vertices.length);
        sharedUvResize(this.data.uvs, data.uvs.length);
        this.data = data;
        this.updateIndices();
        this.updateVertices();
    }
    
    /**
        Resets the vertices of this drawable
    */
    final void reset() {
        vertices[] = data.vertices;
    }

    void addWeldedTarget(Drawable target, ptrdiff_t[] weldedVertexIndices, float weldingWeight) {
        // FIXME: must check whether target is already added.
        auto index = welded.countUntil!"a.target == b"(target);
        if (index != -1) {
//            welded[index].weight = weldingWeight;
            welded[index].indices = weldedVertexIndices;
        } else {
            auto link = WeldingLink(target.uuid, target, weldedVertexIndices, weldingWeight);
            welded ~= link;
        }

        ptrdiff_t[] counterWeldedVertexIndices;
        counterWeldedVertexIndices.length = target.vertices.length;
        counterWeldedVertexIndices[0..$] = -1;
        foreach (i, ind; weldedVertexIndices) {
            if (ind != NOINDEX)
                counterWeldedVertexIndices[ind] = i;
        }
        auto counterIndex = target.welded.countUntil!"a.target == b"(this);
        if (counterIndex != -1) {
//            target.welded[counterIndex].weight = 1 - weldingWeight;
            target.welded[counterIndex].indices = counterWeldedVertexIndices;
        } else {
            auto counterLink = WeldingLink(uuid, this, counterWeldedVertexIndices, 1 - weldingWeight);
            target.welded ~= counterLink;
        }

        target.postProcessFilters = target.postProcessFilters.upsert(tuple(2, &weldingProcessor));
        postProcessFilters = postProcessFilters.upsert(tuple(2, &target.weldingProcessor));
    }

    void removeWeldedTarget(Drawable target) {
        auto index = welded.countUntil!((a) => a.target == target)();
        if (index != -1) {
            welded = welded.remove(index);
            postProcessFilters = postProcessFilters.removeByValue(tuple(2, &target.weldingProcessor));
        }
        index = target.welded.countUntil!((a) => a.target == this)();
        if (index != -1) {
            target.welded = target.welded.remove(index);
            target.postProcessFilters = target.postProcessFilters.removeByValue(tuple(2, &weldingProcessor));
        }
    }

    bool isWeldedBy(Drawable target) {
        return welded.countUntil!"a.target == b"(target) != -1;
    }

    override
    void setupSelf() {
        foreach (link; welded) {
            postProcessFilters = postProcessFilters.upsert(tuple(2, &link.target.weldingProcessor));
        }
    }

    override
    void finalize() {
        super.finalize();
        foreach (child; children) {
            if (child.pinToMesh) {
                setupChild(child);
            }
        }
        
        WeldingLink[] validLinks;
        foreach(i; 0..welded.length) {
            if (Drawable nLink = puppet.find!Drawable(welded[i].targetUUID)) {
                welded[i].target = nLink;
                validLinks ~= welded[i];
            }
        }

        // Remove invalid welded links
        welded = validLinks;
        setupSelf();
    }

    override
    void normalizeUV(MeshData* data) {
        import std.algorithm.comparison : min, max;
        if (data.uvs.length != 0) {
            float minX = data.uvs[0].x;
            float maxX = minX;
            float minY = data.uvs[0].y;
            float maxY = minY;
            foreach (i; 1 .. data.uvs.length) {
                auto uv = data.uvs[i];
                minX = min(minX, uv.x);
                maxX = max(maxX, uv.x);
                minY = min(minY, uv.y);
                maxY = max(maxY, uv.y);
            }
            float width = maxX - minX;
            float height = maxY - minY;
            float centerX = (minX + maxX) / 2 / width;
            float centerY = (minY + maxY) / 2 / height;
            foreach(i; 0..data.uvs.length) {
                data.uvs[i].x /= width;
                data.uvs[i].y /= height;
                data.uvs[i] += vec2(0.5 - centerX, 0.5 - centerY);
            }
        }
    }


    override
    void clearCache() {
        attachedIndex.clear();
    }

    override
    void centralize() {
        foreach (child; children) {
            child.centralize();
        }
        updateBounds();
    }

    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        bool autoResizedMesh = false;
        auto dcomposite = cast(DynamicComposite)src;
        if (dcomposite !is null) {
            autoResizedMesh = dcomposite.autoResizedMesh;
            dcomposite.autoResizedMesh = false;
        }
        super.copyFrom(src, clone, deepCopy);
        if (auto drawable = cast(Drawable)src) {
            MeshData newData;
            newData.vertices = drawable.data.vertices.dup;
            newData.uvs = drawable.data.uvs.dup;
            if (newData.uvs.length != newData.vertices.length) {
                newData.uvs = newData.vertices.dup;
            }
            newData.indices = drawable.data.indices.dup;
            if (drawable.data.gridAxes.length > 0) {
                foreach (ax; drawable.data.gridAxes) {
                    newData.gridAxes ~= ax.dup;
                }
            }
            deformation = drawable.deformation.dup;
            rebuffer(newData);
        }
        if (dcomposite !is null)
            dcomposite.autoResizedMesh = autoResizedMesh;
    }

    override
    bool setupChild(Node node) {
        super.setupChild(node);
        if (node.pinToMesh) {
            if (node.preProcessFilters.countUntil(tuple(0, &nodeAttachProcessor)) == -1)
                node.preProcessFilters ~= tuple(0, &nodeAttachProcessor);
        }
        return true;
    }

    override
    bool releaseChild(Node node) {
        node.preProcessFilters = node.preProcessFilters.removeByValue(tuple(0, &nodeAttachProcessor));
        super.releaseChild(node);
        return true;
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
    bool mustPropagate() { return true; }

}
