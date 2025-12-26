/*
    nijilive Composite Node

    Copyright © 2020, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite.dcomposite;
import nijilive.core.nodes.common;
import nijilive.core.nodes;
import nijilive.fmt;
import nijilive.core;
import nijilive.math;
import nijilive;
import nijilive.core.nodes.utils;
import std.exception;
import std.algorithm;
import std.algorithm.sorting;
//import std.stdio;
import std.array;
import std.format;
import std.range;
import std.algorithm.comparison : min, max;
import std.math : isFinite, ceil, abs;
import nijilive.core.render.commands : DynamicCompositePass, DynamicCompositeSurface, PartDrawPacket;
import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.scheduler : RenderContext, TaskScheduler, TaskOrder, TaskKind;
import nijilive.core.runtime_state : inGetCamera;

package(nijilive) {
    void inInitDComposite() {
        inRegisterNodeType!DynamicComposite;
    }

    __gshared size_t dynamicCompositeFrameCounter;
    void advanceDynamicCompositeFrame() {
        dynamicCompositeFrameCounter++;
    }
    size_t currentDynamicCompositeFrame() {
        return dynamicCompositeFrameCounter;
    }
}

/**
    Composite Node
*/
@TypeId("DynamicComposite")
class DynamicComposite : Part {
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

    void scanPartsRecurse(ref Node node) {

        // Don't need to scan null nodes
        if (node is null) return;

        // Do the main check
        DynamicComposite dcomposite = cast(DynamicComposite)node;
        Part part = cast(Part)node;
        if (part !is null && node != this && node.enabled) {
            subParts ~= part;
            if (dcomposite is null) {
                foreach(child; part.children) {
                    scanPartsRecurse(child);
                }
            } else {
                dcomposite.scanParts();
            }
        } else if ((dcomposite is null || node == this) && node.enabled) {

            // Non-part nodes just need to be recursed through,
            // they don't draw anything.
            foreach(child; node.children) {
                scanPartsRecurse(child);
            }
        } else if (dcomposite !is null && node != this) {
            dcomposite.scanParts();
        }
    }

    // setup Children to project image to DynamicComposite
    //  - Part: ignore transform by puppet.
    //  - Compose: use internal DynamicComposite instead of Composite implementation.
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

    void drawSelf(bool isMask = false)() {
        if (children.length == 0) return;
        super.drawSelf!isMask();
    }

protected:
    package(nijilive) Texture stencil;
    DynamicCompositeSurface offscreenSurface;
    bool textureInvalidated = false;
    bool shouldUpdateVertices = false;

    uint texWidth = 0, texHeight = 0;
    vec2 autoResizedSize;
    int deferred = 0;

    vec3 prevTranslation;
    vec3 prevRotation;
    vec2 prevScale;
    bool deferredChanged = false;
    vec4 maxChildrenBounds;
    bool useMaxChildrenBounds = false;
    size_t maxBoundsStartFrame = 0;
    enum size_t MaxBoundsResetInterval = 120;
    Part[] queuedOffscreenParts;
    bool hasDynamicCompositeAncestor() {
        for (Node node = parent; node !is null; node = node.parent) {
            if (cast(DynamicComposite)node !is null) {
                return true;
            }
        }
        return false;
    }

    DynamicCompositePass prepareDynamicCompositePass() {
        if (textures.length == 0 || textures[0] is null) return null;
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
        if (count == 0) return null;
        offscreenSurface.textureCount = count;
        offscreenSurface.stencil = stencil;

        auto pass = new DynamicCompositePass();
        pass.surface = offscreenSurface;
        auto scale = appliedAutoScale();
        pass.scale = vec2(transform.scale.x * scale.x, transform.scale.y * scale.y);
        pass.rotationZ = transform.rotation.z;
        pass.autoScaled = effectiveAutoScaled();
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
        textureOffset = (worldBounds.xy + worldBounds.zw) / 2 - transform.translation.xy;
        setIgnorePuppet(true);

        textures = [new Texture(texWidth, texHeight), null, null];
        stencil = new Texture(texWidth, texHeight, 1, true);
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
        if (!initialized) {
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
    
    override
    string typeId() { return "DynamicComposite"; }

    /**
        Allows serializing self data (with pretty serializer)
    */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        Texture[3] tmpTextures = textures;
        textures = [null, null, null];
        super.serializeSelfImpl(serializer, recursive, flags);
        // DynamicComposite-specific state
        if (flags & SerializeNodeFlags.State) {
            serializer.putKey("auto_resized");
            serializer.serializeValue(autoResizedMesh);
            serializer.putKey("auto_scaled");
            serializer.serializeValue(autoScaled);
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
        if (!data["auto_scaled"].isEmpty) {
            data["auto_scaled"].deserializeValue(autoScaled);
        }
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

    private DynamicComposite ancestorAutoScaleController() {
        for (Node node = parent; node !is null; node = node.parent) {
            if (auto dyn = cast(DynamicComposite)node) {
                return dyn;
            }
        }
        return null;
    }

    private bool effectiveAutoScaled() {
        if (auto ancestor = ancestorAutoScaleController()) {
            return ancestor.autoScaled;
        }
        return autoScaled;
    }

    private vec2 puppetScale() {
        auto pup = puppet;
        if (pup is null) return vec2(1, 1);
        return vec2(pup.transform.scale.x, pup.transform.scale.y);
    }

    private vec2 cameraScale() {
        auto cam = inGetCamera();
        return vec2(cam.scale.x, cam.scale.y);
    }

    private vec2 appliedAutoScale() {
        if (!effectiveAutoScaled()) return vec2(1, 1);
        vec2 scale = puppetScale();
        auto camScale = cameraScale();
        scale.x *= camScale.x;
        scale.y *= camScale.y;
        return scale;
    }

    private vec2 safeInverse(vec2 scale) {
        enum float epsilon = 1e-6f;
        vec2 result;
        result.x = abs(scale.x) < epsilon ? 1 : 1 / scale.x;
        result.y = abs(scale.y) < epsilon ? 1 : 1 / scale.y;
        return result;
    }

    private mat4 applyAutoScale(mat4 matrix) {
        auto scale = appliedAutoScale();
        if (scale.x == 1 && scale.y == 1) {
            return matrix;
        }
        auto scaleMatrix = mat4.identity.scaling(scale.x, scale.y, 1);
        return scaleMatrix * matrix;
    }

    private mat4 childCorrectionMatrix() {
        return fullTransformMatrix() * transform.matrix.inverse;
    }

    private mat4 applyAutoScaleToChild(Part child, mat4 matrix) {
        if (!effectiveAutoScaled()) return matrix;
        if (cast(DynamicComposite)child !is null) return matrix;
        return applyAutoScale(matrix);
    }

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
            if (auto parentDyn = cast(DynamicComposite)parent) {
                return localTransform.calcOffset(offsetTransform) * parentDyn.fullTransform();
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

    vec4 getChildrenBounds(bool forceUpdate = true) {
        auto frameId = currentDynamicCompositeFrame();
        if (useMaxChildrenBounds) {
            if (frameId - maxBoundsStartFrame >= MaxBoundsResetInterval) {
                useMaxChildrenBounds = false;
            } else {
                return maxChildrenBounds;
            }
        }
        if (forceUpdate) {
            foreach (p; subParts) p.updateBounds();
        }
        vec4 bounds;
        bool useMatrixBounds = autoResizedMesh || effectiveAutoScaled();
        if (useMatrixBounds) {
            auto correction = childCorrectionMatrix();
            bool hasBounds = false;
            foreach (part; subParts) {
                auto childMatrix = applyAutoScaleToChild(part, correction * part.transform.matrix);
                auto childBounds = boundsFromMatrix(part, childMatrix);
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
        } else {
            bounds = mergeBounds(subParts.map!(p=>p.bounds), transform.translation.xyxy);
        }
        if (!useMaxChildrenBounds) {
            maxChildrenBounds = bounds;
        }
        return bounds;
    }

    void enableMaxChildrenBounds(Node target = null) {
        Drawable targetDrawable = cast(Drawable)target;
        if (targetDrawable !is null && (!autoResizedMesh || effectiveAutoScaled())) {
            targetDrawable.updateBounds();
        }
        auto frameId = currentDynamicCompositeFrame();
        if (!useMaxChildrenBounds) {
            useMaxChildrenBounds = true;
            maxBoundsStartFrame = frameId;
            maxChildrenBounds = getChildrenBounds(true);
        }
        if (targetDrawable !is null) {
            vec4 b;
            if (autoResizedMesh || effectiveAutoScaled()) {
                if (auto targetPart = cast(Part)targetDrawable) {
                    auto correction = childCorrectionMatrix();
                    b = boundsFromMatrix(targetPart, applyAutoScaleToChild(targetPart, correction * targetPart.transform.matrix));
                } else {
                    b = targetDrawable.bounds;
                }
            } else {
                b = targetDrawable.bounds;
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
        auto bounds = getChildrenBounds();
        vec2 size = bounds.zw - bounds.xy;
        if (size.x <= 0 || size.y <= 0) {
            return false;
        }

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


        auto originOffset = transform.translation.xy;
        Vec2Array vertexArray = Vec2Array([
            vec2(bounds.x, bounds.y) - originOffset,
            vec2(bounds.x, bounds.w) - originOffset,
            vec2(bounds.z, bounds.y) - originOffset,
            vec2(bounds.z, bounds.w) - originOffset
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
            textureOffset = (bounds.xy + bounds.zw) / 2 - originOffset;
        } else {
            auto newTextureOffset = (bounds.xy + bounds.zw) / 2 - originOffset;
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
    bool autoScaled = false;

    /**
        Constructs a new mask
    */
    this(Node parent = null) {
        super(parent);
    }

    /**
        Constructs a new composite
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
        if (!updateDynamicRenderStateFlags()) return;

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
        auto correction = childCorrectionMatrix();
        foreach (Part child; subParts) {
            auto childMatrix = applyAutoScaleToChild(child, correction * child.transform.matrix);
            child.setOffscreenModelMatrix(childMatrix);
            child.drawOne();
            child.clearOffscreenModelMatrix();
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

        bool autoScale = effectiveAutoScaled();
        if (!autoScale) return;

        auto invCamScale = safeInverse(cameraScale());
        auto cancelCamera = mat4.identity.scaling(invCamScale.x, invCamScale.y, 1);

        if (!ignorePuppet && puppet !is null) {
            auto puppetTransformNoScale = puppet.transform;
            puppetTransformNoScale.scale = vec2(1, 1);
            puppetTransformNoScale.update();
            packet.puppetMatrix = cancelCamera * puppetTransformNoScale.matrix;
        } else {
            packet.puppetMatrix = cancelCamera * packet.puppetMatrix;
        }
        // modelMatrix left as provided by base; puppetMatrix handles camera scale cancellation.
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

        bool allowRenderTasks = !hasDynamicCompositeAncestor();
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

    private void dynamicRenderBegin(ref RenderContext ctx) {
        dynamicScopeActive = false;
        dynamicScopeToken = size_t.max;
        reuseCachedTextureThisFrame = false;
        if (!hasValidOffscreenContent) {
            textureInvalidated = true;
        }
        if (autoResizedMesh) {
            if (createSimpleMesh()) {
                textureInvalidated = true;
            }
        }
        queuedOffscreenParts.length = 0;
        if (!renderEnabled() || ctx.renderGraph is null) return;
        if (!updateDynamicRenderStateFlags()) {
            return;
        }
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
        auto basis = transform.matrix.inverse;
        auto translate = mat4.translation(-textureOffset.x, -textureOffset.y, 0);
        auto childBasis = translate * basis;
        auto correction = childCorrectionMatrix();

        foreach (Part child; subParts) {
            auto childMatrix = applyAutoScaleToChild(child, correction * child.transform.matrix);
            auto finalMatrix = childBasis * childMatrix;
            child.setOffscreenModelMatrix(finalMatrix);
            if (auto dynChild = cast(DynamicComposite)child) {
                dynChild.renderNestedOffscreen(ctx);
            } else {
                child.enqueueRenderCommands(ctx);
            }
            queuedOffscreenParts ~= child;
        }


    }

    private void dynamicRenderEnd(ref RenderContext ctx) {
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
                        import std.stdio : writefln;
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
                    if (part !is null) {
                        part.clearOffscreenModelMatrix();
                    }
                }
            });
        } else {
            auto cleanupParts = queuedOffscreenParts.dup;
            enqueueRenderCommands(ctx, (RenderCommandEmitter emitter) {
                foreach (part; cleanupParts) {
                    if (part !is null) {
                        part.clearOffscreenModelMatrix();
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
        foreach (child; children) {
            scanPartsRecurse(child);
        }
        invalidateChildrenBounds();
    }

    void scanSubParts(Node[] childNodes) { 
        subParts.length = 0;
        foreach (child; childNodes) {
            scanPartsRecurse(child);
        }
        invalidateChildrenBounds();
    }

    override
    bool setupChild(Node node) {
        setIgnorePuppetRecurse(node, true);
        if (puppet !is null) 
            puppet.rescanNodes();

        forceResize = true;
        invalidateChildrenBounds();

        return false;
    }

    override
    bool releaseChild(Node node) {
        setIgnorePuppetRecurse(node, false);
        scanSubParts(children);
        forceResize = true;
        invalidateChildrenBounds();

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
        for (Node c = this; c !is null; c = c.parent) {
            c.addNotifyListener(&onAncestorChanged);
        }
    }

    override
    void releaseSelf() {
        for (Node c = this; c !is null; c = c.parent) {
            c.removeNotifyListener(&onAncestorChanged);
        }
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

    // In autoResizedMesh mode, texture must be updated when any of the parents is translated, rotated, or scaled.
    // To detect parent's change, this object calls addNotifyListener to parents' event slot, and checks whether
    // they are changed or not.
    void onAncestorChanged(Node target, NotifyReason reason) {
        if (autoResizedMesh) {
            if (reason == NotifyReason.Transformed) {
                auto full = fullTransform();
                if (prevTranslation != full.translation || prevRotation != full.rotation || prevScale != full.scale) {
                    deferredChanged = true;
                    prevTranslation = full.translation;
                    prevRotation    = full.rotation;
                    prevScale       = full.scale;
                    invalidateChildrenBounds();
                }
            }
        }
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
        if (target != this) {
            if (reason == NotifyReason.AttributeChanged) {
                scanSubParts(children);
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
            }
        } else if (reason == NotifyReason.AttributeChanged) {
            textureInvalidated = true;
            hasValidOffscreenContent = false;
            loggedFirstRenderAttempt = false;
            invalidateChildrenBounds();
        }
        if (autoResizedMesh) {
            bool ran = false;
            if (updateAutoResizedMeshOnce(ran) && ran) {
                initialized = false;
            }
        }
        super.notifyChange(target, reason);
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
        }
    }

    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);
        normalizeUV(&data);
        rebuffer(data);

        textures = [null, null, null];
        initialized = false;
        if (auto dcomposite = cast(DynamicComposite)src) {
            autoResizedMesh = dcomposite.autoResizedMesh;
            autoScaled = dcomposite.autoScaled;
            if (autoResizedMesh) {
                createSimpleMesh();
                updateBounds();
            }
        } else {
            autoScaled = false;
            autoResizedMesh = false;
            if (data.vertices.length == 0) {
                autoResizedMesh = true;
                createSimpleMesh();
                updateBounds();
            }
        }
        if (auto composite = cast(Composite)src) {
            blendingMode = composite.blendingMode;
            opacity = composite.opacity;
            autoResizedMesh = true;
            createSimpleMesh();
            autoScaled = composite.autoScaled;
        }
    }

    void invalidate() { textureInvalidated = true; }

    override
    void build(bool force = false) {
        super.build(force);
        if (autoResizedMesh) {
            if (createSimpleMesh()) initialized = false;
        }
        if (force || !initialized) {
            initTarget();
        }
    }

    override
    bool mustPropagate() { return false; }
}
