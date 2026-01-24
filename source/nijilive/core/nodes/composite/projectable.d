/*
    nijilive Projectable base for Composite/DynamicComposite

    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite.projectable;

import nijilive.core.nodes.common;
import nijilive.core.nodes.mask : Mask;
import nijilive.core.nodes;
import nijilive.fmt;
import nijilive.core;
import nijilive.math;
import nijilive;
import nijilive.core.nodes.utils;
import std.algorithm;
import std.algorithm.sorting;
import std.array;
import std.range;
import std.algorithm.comparison : min, max;
import std.math : isFinite, ceil, abs;
version (NijiliveRenderProfiler) import nijilive.core.render.profiler : profileScope;
import nijilive.core.render.commands : DynamicCompositePass, DynamicCompositeSurface, PartDrawPacket;
import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.scheduler : RenderContext, TaskScheduler, TaskOrder, TaskKind;
import nijilive.core.runtime_state : inGetCamera;
import std.stdio : writefln;

package(nijilive) {
    __gshared size_t projectableFrameCounter;

    void advanceProjectableFrame() {
        projectableFrameCounter++;
    }

    size_t currentProjectableFrame() {
        return projectableFrameCounter;
    }
}

/**
    Base class for offscreen projectable nodes.
*/
class Projectable : Part {
protected:
    bool initialized = false;
    bool forceResize = false;
    package(nijilive) bool dynamicScopeActive = false;
    package(nijilive) size_t dynamicScopeToken = size_t.max;
    package(nijilive) bool reuseCachedTextureThisFrame = false;
    bool hasValidOffscreenContent = false;
    bool loggedFirstRenderAttempt = false;

    package(nijilive) size_t dynamicScopeTokenValue() const {
        return dynamicScopeToken;
    }
public:
    this(bool delegatedMode) { }

    void selfSort() {
        sort!((a, b) => a.zSort > b.zSort)(subParts);
    }

    // Ensure puppet transform can be ignored when rendering children offscreen.
    void setIgnorePuppetRecurse(Node node, bool ignorePuppet) {
        if (Part part = cast(Part)node) {
            part.ignorePuppet = ignorePuppet;
            foreach (child; node.children) {
                setIgnorePuppetRecurse(child, ignorePuppet);
            }
        } else {
            foreach (child; node.children) {
                setIgnorePuppetRecurse(child, ignorePuppet);
            }
        }
    }

    void setIgnorePuppet(bool ignorePuppet) {
        foreach (child; children) {
            setIgnorePuppetRecurse(child, ignorePuppet);
        }
        if (puppet !is null)
            puppet.rescanNodes();
    }

    // Offscreen orientation context (propagated from parent Composite).
    void setOffscreenScaleSign(vec2 sign) {
        offscreenScaleSign = sign;
        hasOffscreenScaleSign = true;
    }

    void clearOffscreenScaleSign() {
        offscreenScaleSign = vec2(1, 1);
        hasOffscreenScaleSign = false;
    }

    vec2 currentOffscreenScaleSign() const {
        return hasOffscreenScaleSign ? offscreenScaleSign : vec2(1, 1);
    }

    void scanPartsRecurse(ref Node node) {

        // Don't need to scan null nodes
        if (node is null) return;

        // Do the main check
        Projectable proj = cast(Projectable)node;
        Part part = cast(Part)node;
        Mask mask = cast(Mask)node;
        if (part !is null && node != this) {
            subParts ~= part;
            if (mask !is null) {
                maskParts ~= mask;
            }
            if (proj is null) {
                foreach(child; part.children) {
                    scanPartsRecurse(child);
                }
            } else {
                proj.scanParts();
            }
        } else if (mask !is null && node != this) {
            maskParts ~= mask;
            foreach (child; mask.children) {
                scanPartsRecurse(child);
            }
        } else if ((proj is null || node == this) && node.enabled) {

            // Non-part nodes just need to be recursed through,
            // they don't draw anything.
            foreach(child; node.children) {
                scanPartsRecurse(child);
            }
        } else if (proj !is null && node != this) {
            proj.scanParts();
        }
    }

    // setup Children to project image to Projectable
    //  - Part: ignore transform by puppet.
    //  - Compose: use internal Projectable instead of Composite implementation.
    void drawSelf(bool isMask = false)() {
        if (children.length == 0) return;
        super.drawSelf!isMask();
    }

protected:
    package(nijilive) Texture stencil;
    DynamicCompositeSurface offscreenSurface;
    bool textureInvalidated = false;
    bool shouldUpdateVertices = false;
    bool boundsDirty = true;
    vec2 offscreenScaleSign = vec2(1, 1);
    bool hasOffscreenScaleSign = false;

    uint texWidth = 0, texHeight = 0;
    vec2 autoResizedSize;
    int deferred = 0;

    vec3 prevTranslation;
    vec3 prevRotation;
    vec2 prevScale;
    bool hasCachedAncestorTransform = false;
    size_t lastAncestorTransformCheckFrame = size_t.max;
    bool deferredChanged = false;
    vec4 maxChildrenBounds;
    bool useMaxChildrenBounds = false;
    size_t maxBoundsStartFrame = 0;
    size_t lastInitAttemptFrame = size_t.max;
    enum size_t MaxBoundsResetInterval = 120;
    bool hasProjectableAncestor() {
        for (Node node = parent; node !is null; node = node.parent) {
            if (cast(Projectable)node !is null) {
                return true;
            }
        }
        return false;
    }

    DynamicCompositePass prepareDynamicCompositePass() {
        if (textures.length == 0 || textures[0] is null) {
            return null;
        }
        if (offscreenSurface is null) {
            offscreenSurface = new DynamicCompositeSurface();
        }
        size_t count = 0;
        foreach (i; 0 .. offscreenSurface.textures.length) {
            Texture tex = i < textures.length ? textures[i] : null;
            offscreenSurface.textures[i] = tex;
            if (tex !is null) {
                count = i + 1;
            }
        }
        if (count == 0) {
            return null;
        }
        offscreenSurface.textureCount = count;
        offscreenSurface.stencil = stencil;

        auto pass = new DynamicCompositePass();
        pass.surface = offscreenSurface;
        pass.scale = vec2(transform.scale.x, transform.scale.y);
        pass.rotationZ = transform.rotation.z;
        pass.autoScaled = false;
        return pass;
    }

    void renderNestedOffscreen(ref RenderContext ctx) {
        dynamicRenderBegin(ctx);
        dynamicRenderEnd(ctx);
    }

    bool initTarget() {
        auto prevTexture = textures[0];
        auto prevStencil = stencil;

        updateBounds();
        vec4 worldBounds = bounds;
        if (!boundsFinite(worldBounds)) {
            return false;
        }

        vec2 minPos;
        vec2 maxPos;
        bool first = true;
        size_t count = vertices.length;
        for (size_t i = 0; i < count; ++i) {
            vec2 pos = vertices[i];
            if (i < deformation.length) {
                pos += deformation[i];
            }
            if (first) {
                minPos = pos;
                maxPos = pos;
                first = false;
            } else {
                minPos.x = min(minPos.x, pos.x);
                minPos.y = min(minPos.y, pos.y);
                maxPos.x = max(maxPos.x, pos.x);
                maxPos.y = max(maxPos.y, pos.y);
            }
        }

        vec2 size = maxPos - minPos;
        if (!sizeFinite(size) || size.x <= 0 || size.y <= 0) {
            return false;
        }

        texWidth = cast(uint)(ceil(size.x)) + 1;
        texHeight = cast(uint)(ceil(size.y)) + 1;
        vec2 deformOffset = deformationTranslationOffset();
        textureOffset = (worldBounds.xy + worldBounds.zw) / 2 + deformOffset - transform.translation.xy;

        textures = [new Texture(texWidth, texHeight, 4, false, false), null, null];
        stencil = new Texture(texWidth, texHeight, 1, true, false);
        if (prevTexture !is null) {
            prevTexture.dispose();
        }
        if (prevStencil !is null) {
            prevStencil.dispose();
        }
        version (InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend !is null && offscreenSurface !is null) {
                backend.destroyDynamicComposite(offscreenSurface);
                offscreenSurface.framebuffer = 0;
            }
        }

        initialized = true;
        textureInvalidated = true;
        hasValidOffscreenContent = false;
        loggedFirstRenderAttempt = false;
        return true;
    }

    bool updateDynamicRenderStateFlags() {
        bool resized = false;
        auto frameId = currentProjectableFrame();
        if (autoResizedMesh && detectAncestorTransformChange(frameId)) {
            deferredChanged = true;
            useMaxChildrenBounds = false;
        }
        if (deferredChanged) {
            if (autoResizedMesh) {
                bool ran = false;
                resized = updateAutoResizedMeshOnce(ran);
                if (ran && resized) {
                    initialized = false;
                }
                if (ran) {
                    deferredChanged = false;
                    textureInvalidated = true;
                    hasValidOffscreenContent = false;
                    loggedFirstRenderAttempt = false;
                }
            } else {
                deferredChanged = false;
                textureInvalidated = true;
                hasValidOffscreenContent = false;
                loggedFirstRenderAttempt = false;
            }
        }
        if (autoResizedMesh && boundsDirty) {
            bool resizedNow = createSimpleMesh();
            boundsDirty = false;
            if (resizedNow) {
                textureInvalidated = true;
                initialized = false;
            }
        }
        if (!initialized) {
            if (lastInitAttemptFrame == frameId) {
                return false;
            }
            lastInitAttemptFrame = frameId;
            if (!initTarget()) {
                return false;
            }
        }
        if (shouldUpdateVertices) {
            shouldUpdateVertices = false;
        }
        return true;
    }
    Part[] subParts;
    Mask[] maskParts;
    Drawable[] queuedOffscreenParts;

    /**
        Allows serializing self data (with pretty serializer)
    */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        Texture[3] tmpTextures = textures;
        textures = [null, null, null];
        super.serializeSelfImpl(serializer, recursive, flags);
        // Projectable-specific state
        if (flags & SerializeNodeFlags.State) {
            serializer.putKey("auto_resized");
            serializer.serializeValue(autoResizedMesh);
        }
        textures = tmpTextures;
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        auto result = super.deserializeFromFghj(data);
        textures = [null, null, null];
        if (!data["auto_resized"].isEmpty) 
            data["auto_resized"].deserializeValue(autoResizedMesh);
        else if (this.data.indices.length != 0) {
            autoResizedMesh = false;
        } else autoResizedMesh = true;
        return result;
    }

    vec4 mergeBounds(T)(T bounds, vec4 origin = vec4.init) {
        if (bounds.length > 0) {
            float minX = (bounds.map!(p=> p.x).array).minElement();
            float minY = (bounds.map!(p=> p.y).array).minElement();
            float maxX = (bounds.map!(p=> p.z).array).maxElement();
            float maxY = (bounds.map!(p=> p.w).array).maxElement();
            return vec4(minX, minY, maxX, maxY);
        } else {
            return origin;
        }
    }

protected:
    private Transform fullTransform() {
        localTransform.update();
        offsetTransform.update();
        if (lockToRoot()) {
            Transform trans = (puppet !is null && puppet.root !is null)
                ? puppet.root.localTransform
                : Transform(vec3(0, 0, 0));
            return localTransform.calcOffset(offsetTransform) * trans;
        }
        if (parent !is null) {
            if (auto parentProj = cast(Projectable)parent) {
                return localTransform.calcOffset(offsetTransform) * parentProj.fullTransform();
            }
            return localTransform.calcOffset(offsetTransform) * parent.transform();
        }
        return localTransform.calcOffset(offsetTransform);
    }

    private mat4 fullTransformMatrix() {
        return fullTransform().matrix;
    }

    private vec4 boundsFromMatrix(Part child, const mat4 matrix) {
        float tx = matrix[0][3];
        float ty = matrix[1][3];
        vec4 bounds = vec4(tx, ty, tx, ty);
        if (child.vertices.length == 0) {
            return bounds;
        }
        auto deform = child.deformation;
        foreach (i, vertex; child.vertices) {
            vec2 localVertex = vertex;
            if (i < deform.length) {
                localVertex += deform[i];
            }
            vec2 vertOriented = vec2(matrix * vec4(localVertex, 0, 1));
            bounds.x = min(bounds.x, vertOriented.x);
            bounds.y = min(bounds.y, vertOriented.y);
            bounds.z = max(bounds.z, vertOriented.x);
            bounds.w = max(bounds.w, vertOriented.y);
        }
        return bounds;
    }

    bool detectAncestorTransformChange(size_t frameId) {
        if (lastAncestorTransformCheckFrame == frameId) {
            return false;
        }
        lastAncestorTransformCheckFrame = frameId;
        auto full = fullTransform();
        if (!hasCachedAncestorTransform) {
            prevTranslation = full.translation;
            prevRotation = full.rotation;
            prevScale = full.scale;
            hasCachedAncestorTransform = true;
            return false;
        }
        enum float TransformEpsilon = 0.0001f;
        bool changed =
            abs(full.translation.x - prevTranslation.x) > TransformEpsilon ||
            abs(full.translation.y - prevTranslation.y) > TransformEpsilon ||
            abs(full.translation.z - prevTranslation.z) > TransformEpsilon ||
            abs(full.rotation.x - prevRotation.x) > TransformEpsilon ||
            abs(full.rotation.y - prevRotation.y) > TransformEpsilon ||
            abs(full.rotation.z - prevRotation.z) > TransformEpsilon ||
            abs(full.scale.x - prevScale.x) > TransformEpsilon ||
            abs(full.scale.y - prevScale.y) > TransformEpsilon;
        if (changed) {
            prevTranslation = full.translation;
            prevRotation = full.rotation;
            prevScale = full.scale;
        }
        return changed;
    }

    vec4 getChildrenBounds(bool forceUpdate = true) {
        version (NijiliveRenderProfiler) auto __prof = profileScope("Composite:getChildrenBounds");
        auto frameId = currentProjectableFrame();
        if (useMaxChildrenBounds) {
            if (frameId - maxBoundsStartFrame < MaxBoundsResetInterval) {
                return maxChildrenBounds;
            }
            useMaxChildrenBounds = false;
        }
        if (forceUpdate) {
            foreach (p; subParts) {
                if (p !is null) p.updateBounds();
            }
        }
        vec4 bounds;
        bool hasBounds = false;
        mat4 correction;
        bool haveCorrection = false;
        foreach (part; subParts) {
            if (part is null) continue;
            vec4 childBounds = part.bounds;
            if (!boundsFinite(childBounds)) {
                if (!haveCorrection) {
                    correction = fullTransformMatrix() * transform.matrix.inverse;
                    haveCorrection = true;
                }
                auto childMatrix = correction * part.transform.matrix;
                childBounds = boundsFromMatrix(part, childMatrix);
            }
            if (!hasBounds) {
                bounds = childBounds;
                hasBounds = true;
            } else {
                bounds.x = min(bounds.x, childBounds.x);
                bounds.y = min(bounds.y, childBounds.y);
                bounds.z = max(bounds.z, childBounds.z);
                bounds.w = max(bounds.w, childBounds.w);
            }
        }
        if (!hasBounds) {
            bounds = transform.translation.xyxy;
        }
        maxChildrenBounds = bounds;
        useMaxChildrenBounds = true;
        maxBoundsStartFrame = frameId;
        return bounds;
    }

    // Detects uniform deformation translation so we can shift offscreen rendering accordingly.
    private vec2 deformationTranslationOffset() const {
        if (deformation.length == 0) return vec2(0);
        vec2 base = deformation[0];
        enum float eps = 0.0001f;
        foreach (off; deformation) {
            if (abs(off.x - base.x) > eps || abs(off.y - base.y) > eps) {
                return vec2(0);
            }
        }
        return base;
    }

    void enableMaxChildrenBounds(Node target = null) {
        Drawable targetDrawable = cast(Drawable)target;
        if (targetDrawable !is null) {
            targetDrawable.updateBounds();
        }
        auto frameId = currentProjectableFrame();
        maxChildrenBounds = getChildrenBounds(false);
        useMaxChildrenBounds = true;
        maxBoundsStartFrame = frameId;
        if (targetDrawable !is null) {
            vec4 b = targetDrawable.bounds;
            if (!boundsFinite(b)) {
                if (auto targetPart = cast(Part)targetDrawable) {
                    auto correction = fullTransformMatrix() * transform.matrix.inverse;
                    b = boundsFromMatrix(targetPart, correction * targetPart.transform.matrix);
                } else {
                    return;
                }
            }
            maxChildrenBounds.x = min(maxChildrenBounds.x, b.x);
            maxChildrenBounds.y = min(maxChildrenBounds.y, b.y);
            maxChildrenBounds.z = max(maxChildrenBounds.z, b.z);
            maxChildrenBounds.w = max(maxChildrenBounds.w, b.w);
        }
    }

    void invalidateChildrenBounds() {
        useMaxChildrenBounds = false;
    }

    bool createSimpleMesh() {
        version (NijiliveRenderProfiler) auto __prof = profileScope("Composite:createSimpleMesh");
        auto bounds = getChildrenBounds();
        vec2 size = bounds.zw - bounds.xy;
        if (size.x <= 0 || size.y <= 0) {
            return false;
        }

        auto deformOffset = deformationTranslationOffset();
        vec2 origSize = shouldUpdateVertices
            ? autoResizedSize
            : (textures.length > 0 && textures[0] !is null)
                ? vec2(textures[0].width, textures[0].height)
                : vec2(0, 0);
        bool resizing = false;
        if (forceResize) {
            resizing = true;
            forceResize = false;
        } else {
            if (cast(int)origSize.x > cast(int)size.x) {
                float diff = (origSize.x - size.x) / 2;
                bounds.z += diff;
                bounds.x -= diff;
            } else if (cast(int)size.x > cast(int)origSize.x) {
                resizing = true;
            }
            if (cast(int)origSize.y > cast(int)size.y) {
                float diff = (origSize.y - size.y) / 2;
                bounds.w += diff;
                bounds.y -= diff;
            } else if (cast(int)size.y > cast(int)origSize.y) {
                resizing = true;
            }
        }


        auto originOffset = transform.translation.xy + deformOffset;
        Vec2Array vertexArray = Vec2Array([
            vec2(bounds.x, bounds.y) + deformOffset - originOffset,
            vec2(bounds.x, bounds.w) + deformOffset - originOffset,
            vec2(bounds.z, bounds.y) + deformOffset - originOffset,
            vec2(bounds.z, bounds.w) + deformOffset - originOffset
        ]);

        if (resizing) {
            MeshData newData;
            newData.vertices = vertexArray;
            newData.uvs = Vec2Array([
                vec2(0, 0),
                vec2(0, 1),
                vec2(1, 0),
                vec2(1, 1)
            ]);
            newData.indices = [
                0, 1, 2,
                2, 1, 3
            ];
            newData.origin = vec2(0, 0);
            newData.gridAxes = [];
            super.rebuffer(newData);
            shouldUpdateVertices = true;
            autoResizedSize = bounds.zw - bounds.xy;
            textureOffset = (bounds.xy + bounds.zw) / 2 + deformOffset - originOffset;
        } else {
            auto newTextureOffset = (bounds.xy + bounds.zw) / 2 + deformOffset - originOffset;
            enum float TextureOffsetEpsilon = 0.001f;
            bool offsetChanged = abs(newTextureOffset.x - textureOffset.x) > TextureOffsetEpsilon ||
                abs(newTextureOffset.y - textureOffset.y) > TextureOffsetEpsilon;
            if (offsetChanged) {
                textureInvalidated = true;
                data.vertices = vertexArray;
                data.indices = [
                    0, 1, 2,
                    2, 1, 3
                ];
                shouldUpdateVertices = true;
                autoResizedSize = bounds.zw - bounds.xy;
                updateVertices();
                textureOffset = newTextureOffset;
            }
        }
        return resizing;
    }

    private bool updateAutoResizedMeshOnce(out bool ran) {
        ran = false;
        if (!autoResizedMesh) {
            return false;
        }
        ran = true;
        return createSimpleMesh();
    }

public:
    vec2 textureOffset;
    bool autoResizedMesh = true;

    /**
        Constructs a new mask
    */
    this(Node parent = null) {
        super(parent);
    }

    /**
        Constructs a new projectable
    */
    this(MeshData data, uint uuid, Node parent = null) {
        if (data.indices.length != 0) autoResizedMesh = false;
        super(data, uuid, parent);
    }

    @Ignore
    override
    Transform transform() {
        auto trans = super.transform();
        if (autoResizedMesh) {
            trans.rotation = vec3(0, 0, 0);
            trans.scale = vec2(1, 1);
            trans.update();
        }
        return trans;
    }

    override
    protected void runDynamicTask(ref RenderContext ctx) {
        if (autoResizedMesh) {
            if (shouldUpdateVertices) {
                shouldUpdateVertices = false;
            }
            bool ran = false;
            if (updateAutoResizedMeshOnce(ran) && ran) {
                initialized = false;
            }
        } else {
            super.runDynamicTask(ctx);
        }
    }

    override
    void preProcess() {
        if (!autoResizedMesh) {
            super.preProcess();
        } else {
            Node.preProcess();
        }
    }

    override
    void postProcess(int id = 0) {
        if (!autoResizedMesh) {
            super.postProcess(id);
        } else {
            Node.postProcess(id);
        }
    }

    void drawContents() {
        updateDynamicRenderStateFlags();

        bool needsRedraw = textureInvalidated || deferred > 0;
        if (!needsRedraw) {
            reuseCachedTextureThisFrame = true;
            return;
        }

        selfSort();

        DynamicCompositePass immediatePass;
        version (InDoesRender) {
            auto backendBegin = puppet ? puppet.renderBackend : null;
            immediatePass = prepareDynamicCompositePass();
            if (backendBegin !is null && immediatePass !is null) {
                backendBegin.beginDynamicComposite(immediatePass);
            }
        }

        auto original = oneTimeTransform;
        mat4 tmp = transform.matrix.inverse;
        tmp[0][3] -= textureOffset.x;
        tmp[1][3] -= textureOffset.y;
        setOneTimeTransform(&tmp);
        auto correction = fullTransformMatrix() * transform.matrix.inverse;
        foreach (Part child; subParts) {
            if (cast(Mask)child !is null) {
                continue;
            }
            auto childMatrix = correction * child.transform.matrix;
            child.setOffscreenModelMatrix(childMatrix);
            child.drawOne();
            child.clearOffscreenModelMatrix();
        }
        foreach (mask; maskParts) {
            auto maskMatrix = correction * mask.transform.matrix;
            mask.setOffscreenModelMatrix(maskMatrix);
            mask.renderMask(false);
            mask.clearOffscreenModelMatrix();
        }
        setOneTimeTransform(original);

        version (InDoesRender) {
            auto backendEnd = puppet ? puppet.renderBackend : null;
            if (backendEnd !is null && immediatePass !is null) {
                backendEnd.endDynamicComposite(immediatePass);
            }
        }

        textureInvalidated = false;
        if (deferred > 0) deferred--;
        hasValidOffscreenContent = true;
        reuseCachedTextureThisFrame = false;
        loggedFirstRenderAttempt = true;
    }

    override
    void drawOne() {
//        writefln("%s: drawOne", name);
        if (!enabled || puppet is null) return;
        this.drawContents();

        // No masks, draw normally
        drawSelf();
//        writefln("  %s: end", name);
    }

    override
    void draw() {
        if (!enabled || puppet is null) return;
        this.drawOne();
    }

    override void fillDrawPacket(ref PartDrawPacket packet, bool isMask = false) {
        super.fillDrawPacket(packet, isMask);
        // No autoscale handling in base; Composite handles scaling.
    }

    override
    void registerRenderTasks(TaskScheduler scheduler) {
        if (scheduler is null) return;

        scheduler.addTask(TaskOrder.Init, TaskKind.Init, &runBeginTask);
        scheduler.addTask(TaskOrder.PreProcess, TaskKind.PreProcess, &runPreProcessTask);
        scheduler.addTask(TaskOrder.Dynamic, TaskKind.Dynamic, &runDynamicTask);
        scheduler.addTask(TaskOrder.Post0, TaskKind.PostProcess, &runPostTask0);
        scheduler.addTask(TaskOrder.Post1, TaskKind.PostProcess, &runPostTask1);
        scheduler.addTask(TaskOrder.Post2, TaskKind.PostProcess, &runPostTask2);

        bool allowRenderTasks = !hasProjectableAncestor();
        if (allowRenderTasks) {
            scheduler.addTask(TaskOrder.RenderBegin, TaskKind.Render, &runRenderBeginTask);
            scheduler.addTask(TaskOrder.Render, TaskKind.Render, &runRenderTask);
        }

        scheduler.addTask(TaskOrder.Final, TaskKind.Finalize, &runFinalTask);

        auto orderedChildren = children.dup;
        if (orderedChildren.length > 1) {
            import std.algorithm.sorting : sort;
            orderedChildren.sort!((a, b) => a.zSort > b.zSort);
        }

        foreach(child; orderedChildren) {
            child.registerRenderTasks(scheduler);
        }

        if (allowRenderTasks) {
            scheduler.addTask(TaskOrder.RenderEnd, TaskKind.Render, &runRenderEndTask);
        }
    }

    protected void dynamicRenderBegin(ref RenderContext ctx) {
        dynamicScopeActive = false;
        dynamicScopeToken = size_t.max;
        reuseCachedTextureThisFrame = false;
        if (!hasValidOffscreenContent) {
            textureInvalidated = true;
        }
        queuedOffscreenParts.length = 0;
        if (!renderEnabled()) {
            return;
        }
        if (ctx.renderGraph is null) {
            return;
        }
        updateDynamicRenderStateFlags();
        bool needsRedraw = textureInvalidated || deferred > 0;
        if (!needsRedraw) {
            reuseCachedTextureThisFrame = true;
            loggedFirstRenderAttempt = true;
            return;
        }

        selfSort();
        auto passData = prepareDynamicCompositePass();
        if (passData is null) {
            reuseCachedTextureThisFrame = true;
            loggedFirstRenderAttempt = true;
            return;
        }
        dynamicScopeToken = ctx.renderGraph.pushDynamicComposite(this, passData, zSort());
        dynamicScopeActive = true;

        queuedOffscreenParts.length = 0;
        auto translate = mat4.translation(-textureOffset.x, -textureOffset.y, 0);
        auto correction = fullTransformMatrix() * transform.matrix.inverse;
        auto childBasis = translate * transform.matrix.inverse;

        foreach (Part child; subParts) {
            if (cast(Mask)child !is null) {
                continue;
            }
            auto childMatrix = correction * child.transform.matrix;
            auto finalMatrix = childBasis * childMatrix;
            child.setOffscreenModelMatrix(finalMatrix);
            if (auto dynChild = cast(Projectable)child) {
                dynChild.renderNestedOffscreen(ctx);
            } else {
                child.enqueueRenderCommands(ctx);
            }
            queuedOffscreenParts ~= child;
        }
        foreach (mask; maskParts) {
            auto maskMatrix = correction * mask.transform.matrix;
            auto finalMatrix = translate * maskMatrix;
            mask.setOffscreenModelMatrix(finalMatrix);
            mask.enqueueRenderCommands(ctx);
            queuedOffscreenParts ~= mask;
        }


    }

    protected void dynamicRenderEnd(ref RenderContext ctx) {
        if (ctx.renderGraph is null) return;
        bool redrew = dynamicScopeActive;
        if (dynamicScopeActive) {
            auto queuedForCleanup = queuedOffscreenParts.dup;
            MaskBinding[] dedupMaskBindings() {
                MaskBinding[] result;
                bool[ulong] seen;
                foreach (m; masks) {
                    if (m.maskSrc is null) continue;
                    auto key = (cast(ulong)m.maskSrc.uuid << 32) | cast(uint)m.mode;
                    if (key in seen) continue;
                    seen[key] = true;
                    result ~= m;
                }
                return result;
            }
            auto maskBindings = dedupMaskBindings();
            bool hasMasks = maskBindings.length > 0;
            bool useStencil = false;
            foreach (m; maskBindings) {
                if (m.mode == MaskingMode.Mask) {
                    useStencil = true;
                    break;
                }
            }
            auto partNode = this;
            ctx.renderGraph.popDynamicComposite(dynamicScopeToken, (RenderCommandEmitter emitter) {
                if (hasMasks) {
                    emitter.beginMask(useStencil);
                    foreach (binding; maskBindings) {
                        if (binding.maskSrc is null) continue;
                        bool isDodge = binding.mode == MaskingMode.DodgeMask;
                        debug (UnityDLLLog) writefln("[nijilive] applyMask dynComposite=%s(%s) maskSrc=%s(%s) mode=%s dodge=%s",
                            this.name, this.uuid, binding.maskSrc.name, binding.maskSrc.uuid, binding.mode, isDodge);
                        emitter.applyMask(binding.maskSrc, isDodge);
                    }
                    emitter.beginMaskContent();
                }

                emitter.drawPart(partNode, false);

                if (hasMasks) {
                    emitter.endMask();
                }

                foreach (part; queuedForCleanup) {
                    if (auto p = cast(Part)part) {
                        p.clearOffscreenModelMatrix();
                        p.clearOffscreenRenderMatrix();
                    } else if (auto m = cast(Mask)part) {
                        m.clearOffscreenModelMatrix();
                        m.clearOffscreenRenderMatrix();
                    }
                }
            });
        } else {
            auto cleanupParts = queuedOffscreenParts.dup;
            enqueueRenderCommands(ctx, (RenderCommandEmitter emitter) {
                foreach (part; cleanupParts) {
                    if (auto p = cast(Part)part) {
                        p.clearOffscreenModelMatrix();
                        p.clearOffscreenRenderMatrix();
                    } else if (auto m = cast(Mask)part) {
                        m.clearOffscreenModelMatrix();
                        m.clearOffscreenRenderMatrix();
                    }
                }
            });
        }
        reuseCachedTextureThisFrame = false;
        queuedOffscreenParts.length = 0;
        if (redrew) {
            textureInvalidated = false;
            if (deferred > 0) deferred--;
            hasValidOffscreenContent = true;
        }
        loggedFirstRenderAttempt = true;
        dynamicScopeActive = false;
        dynamicScopeToken = size_t.max;
    }

    package(nijilive)
    void delegatedRunRenderBeginTask(ref RenderContext ctx) {
        dynamicRenderBegin(ctx);
    }

    package(nijilive)
    void delegatedRunRenderTask(ref RenderContext ctx) {
    }

    package(nijilive)
    void delegatedRunRenderEndTask(ref RenderContext ctx) {
        dynamicRenderEnd(ctx);
    }

    package(nijilive)
    void registerDelegatedTasks(TaskScheduler scheduler) {
        if (scheduler is null) return;

        scheduler.addTask(TaskOrder.Init, TaskKind.Init, &runBeginTask);
        scheduler.addTask(TaskOrder.PreProcess, TaskKind.PreProcess, &runPreProcessTask);
        scheduler.addTask(TaskOrder.Dynamic, TaskKind.Dynamic, &runDynamicTask);
        scheduler.addTask(TaskOrder.Post0, TaskKind.PostProcess, &runPostTask0);
        scheduler.addTask(TaskOrder.Post1, TaskKind.PostProcess, &runPostTask1);
        scheduler.addTask(TaskOrder.Post2, TaskKind.PostProcess, &runPostTask2);
        scheduler.addTask(TaskOrder.Final, TaskKind.Finalize, &runFinalTask);
    }

    override
    protected void runRenderBeginTask(ref RenderContext ctx) {
        dynamicRenderBegin(ctx);
    }

    override
    protected void runRenderTask(ref RenderContext ctx) {
    }

    override
    protected void runRenderEndTask(ref RenderContext ctx) {
        dynamicRenderEnd(ctx);
    }


    /**
        Scans for parts to render
    */
    void scanParts() {
        subParts.length = 0;
        maskParts.length = 0;
        foreach (child; children) {
            scanPartsRecurse(child);
        }
        invalidateChildrenBounds();
        boundsDirty = true;
    }

    void scanSubParts(Node[] childNodes) { 
        subParts.length = 0;
        maskParts.length = 0;
        foreach (child; childNodes) {
            scanPartsRecurse(child);
        }
        invalidateChildrenBounds();
        boundsDirty = true;
    }

    override
    bool setupChild(Node node) {
        setIgnorePuppetRecurse(node, true);
        if (puppet !is null) 
            puppet.rescanNodes();

        forceResize = true;
        invalidateChildrenBounds();
        boundsDirty = true;

        return false;
    }

    override
    bool releaseChild(Node node) {
        setIgnorePuppetRecurse(node, false);
        scanSubParts(children);
        forceResize = true;
        invalidateChildrenBounds();
        boundsDirty = true;

        return false;
    }

    override
    void setupSelf() { 
        transformChanged();
        scanSubParts(children);
        if (autoResizedMesh) {
            if (createSimpleMesh()) initialized = false;
        }
        textureInvalidated = true;
        boundsDirty = false;
        hasCachedAncestorTransform = false;
        lastAncestorTransformCheckFrame = size_t.max;
    }

    override
    void releaseSelf() {
        hasCachedAncestorTransform = false;
        lastAncestorTransformCheckFrame = size_t.max;
    }

    bool boundsFinite(vec4 b) const {
        return isFinite(b.x) && isFinite(b.y) && isFinite(b.z) && isFinite(b.w);
    }

    bool sizeFinite(vec2 v) const {
        return isFinite(v.x) && isFinite(v.y);
    }

    vec4 getMeshBounds() const {
        if (data.vertices.length == 0) {
            return vec4(0, 0, 0, 0);
        }
        float minX = data.vertices[0].x;
        float minY = data.vertices[0].y;
        float maxX = data.vertices[0].x;
        float maxY = data.vertices[0].y;
        foreach (v; data.vertices) {
            minX = min(minX, v.x);
            minY = min(minY, v.y);
            maxX = max(maxX, v.x);
            maxY = max(maxY, v.y);
        }
        return vec4(minX, minY, maxX, maxY);
    }

    override
    void normalizeUV(MeshData* data) {
        data.uvs.length = data.vertices.length;
        if (data.uvs.length != 0) {
            import std.algorithm.comparison : min, max;
            float minX = data.vertices[0].x;
            float maxX = minX;
            float minY = data.vertices[0].y;
            float maxY = minY;
            foreach (i; 1 .. data.vertices.length) {
                auto vert = data.vertices[i];
                minX = min(minX, vert.x);
                maxX = max(maxX, vert.x);
                minY = min(minY, vert.y);
                maxY = max(maxY, vert.y);
            }
            float width = maxX - minX;
            float height = maxY - minY;
            if (autoResizedMesh) {
                if (width < bounds.z - bounds.x) {
                    width = bounds.z - bounds.x;
                }
                if (height < bounds.w - bounds.y) {
                    height = bounds.w - bounds.y;
                }
            }
            float centerX = (minX + maxX) / 2 / width;
            float centerY = (minY + maxY) / 2 / height;
            foreach(i; 0..data.uvs.length) {
                auto vert = data.vertices[i];
                data.uvs[i].x = vert.x / width;
                data.uvs[i].y = vert.y / height;
                data.uvs[i] += vec2(0.5 - centerX, 0.5 - centerY);
            }
        }
    }

    override
    void notifyChange(Node target, NotifyReason reason = NotifyReason.Transformed) {
        bool markBoundsDirty = false;
        if (target != this) {
            if (reason == NotifyReason.AttributeChanged) {
                scanSubParts(children);
                markBoundsDirty = true;
            }
            if (reason != NotifyReason.Initialized) {
                textureInvalidated = true;
                hasValidOffscreenContent = false;
                loggedFirstRenderAttempt = false;
            }
            if (reason == NotifyReason.Transformed) {
                enableMaxChildrenBounds(target);
            } else {
                invalidateChildrenBounds();
                markBoundsDirty = true;
            }
        } else if (reason == NotifyReason.AttributeChanged) {
            textureInvalidated = true;
            hasValidOffscreenContent = false;
            loggedFirstRenderAttempt = false;
            invalidateChildrenBounds();
            markBoundsDirty = true;
        } else if (reason == NotifyReason.Transformed) {
            // Composite自身の原点移動などの変化に追従するため、キャッシュを無効化して再計算させる
            textureInvalidated = true;
            hasValidOffscreenContent = false;
            loggedFirstRenderAttempt = false;
            invalidateChildrenBounds();
            markBoundsDirty = true;
        }
        if (markBoundsDirty) {
            boundsDirty = true;
        }
        if (autoResizedMesh && reason == NotifyReason.AttributeChanged) {
            bool ran = false;
            if (updateAutoResizedMeshOnce(ran) && ran) {
                initialized = false;
            }
        }
        super.notifyChange(target, reason);
    }

    override
    void onDeformPushed(ref Deformation deform) {
        super.onDeformPushed(deform);
        textureInvalidated = true;
        hasValidOffscreenContent = false;
        loggedFirstRenderAttempt = false;
    }

    override
    void rebuffer(ref MeshData data) {
        if (data.vertices.length == 0) {
            autoResizedMesh = true;
        } else {
            autoResizedMesh = false;
        }

        super.rebuffer(data);
        initialized = false;
        setIgnorePuppet(false);
        notifyChange(this);
    }

    override
    void centralize() {
        super.centralize();
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
        vec2 center = (bounds.xy + bounds.zw) / 2;
        if (parent !is null) {
            center = (parent.transform.matrix.inverse * vec4(center, 0, 1)).xy;
        }
        auto diff = center - localTransform.translation.xy;
        localTransform.translation.x = center.x;
        localTransform.translation.y = center.y;
        if (!autoResizedMesh) {
            foreach (v; vertices) {
                v -= diff;
            }
            updateBounds();
            initialized = false;
        }
        clearCache();
        initialized = false;
        transformChanged();
        foreach (i, child; children) {
            child.localTransform.translation = (transform.matrix.inverse * childTranslations[i]).xyz;
            child.transformChanged();
        }
        if (autoResizedMesh) {
            createSimpleMesh();
            updateBounds();
            initialized = false;
            boundsDirty = false;
        }
    }

    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);
        normalizeUV(&data);
        rebuffer(data);

        textures = [null, null, null];
        initialized = false;
        if (auto proj = cast(Projectable)src) {
            autoResizedMesh = proj.autoResizedMesh;
            if (autoResizedMesh) {
                createSimpleMesh();
                updateBounds();
                boundsDirty = false;
            }
        } else {
            autoResizedMesh = false;
            if (data.vertices.length == 0) {
                autoResizedMesh = true;
                createSimpleMesh();
                updateBounds();
                boundsDirty = false;
            }
        }
    }

    void invalidate() { textureInvalidated = true; }

    override
    void build(bool force = false) {
        super.build(force);
        if (autoResizedMesh) {
            if (createSimpleMesh()) initialized = false;
            boundsDirty = false;
        }
        if (force || !initialized) {
            initTarget();
        }
    }

    override
    bool mustPropagate() { return false; }
}
