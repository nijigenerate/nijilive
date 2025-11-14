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
import std.math : isFinite, ceil;
import nijilive.core.render.commands;
import nijilive.core.render.graph_builder : RenderCommandBuffer;
import nijilive.core.render.scheduler : RenderContext, TaskScheduler, TaskOrder, TaskKind;

package(nijilive) {
    void inInitDComposite() {
        inRegisterNodeType!DynamicComposite;
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
        Composite composite = cast(Composite)node;
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
            
        } else if (((dcomposite is null && composite is null) || node == this) && node.enabled) {

            // Non-part nodes just need to be recursed through,
            // they don't draw anything.
            foreach(child; node.children) {
                scanPartsRecurse(child);
            }
        } else if (dcomposite !is null && node != this) {
            dcomposite.scanParts();
        } else if (composite !is null) {
            if (composite.delegated !is null) {
                subParts ~= composite.delegated;
            }
            composite.scanParts();
        }
    }

    // setup Children to project image to DynamicComposite
    //  - Part: ignore transform by puppet.
    //  - Compose: use internal DynamicComposite instead of Composite implementation.
    void setIgnorePuppetRecurse(Node node, bool ignorePuppet) {
        if (Part part = cast(Part)node) {
            part.ignorePuppet = ignorePuppet;
        } else if (Composite comp = cast(Composite)node) {
            if (ignorePuppet) {
                auto dcomposite = comp.delegated;
                if (comp.delegated is null) {
                    // Insert delegated DynamicComposite object to Composite Node.
                    dcomposite = new DynamicComposite(true);
                    dcomposite.name = "(%s)".format(comp.name);
                    dcomposite.setPuppet(puppet);
                    static if (1) {
                        // Insert Dynamic Composite in shadow mode.
                        // In this mode, parents and children are set to dcomposite in one-way manner.
                        // parent and children doesn't know dcomposite in their parent-children relationship.
                        Node* parent = &dcomposite.parent();
                        *parent = comp.parent;
                    } else {
                        // Debug mode:
                        // Insert Dynamic Composite as opaque mode.
                        // In this mode, parents and children are aware of inserted Dcomposite object in their tree hierarchy.
                        dcomposite.parent = comp.parent;
                    }

                    dcomposite.localTransform.translation = comp.localTransform.translation;
                }
                dcomposite.ignorePuppet = ignorePuppet;
                dcomposite.children_ref.length = 0;
                foreach (child; comp.children) {
                    dcomposite.children_ref ~= child;
                }
                comp.setDelegation(dcomposite);
            } else {
                // Remove delegated DynamicComposite.
                comp.setDelegation(null);
            }
        }
        foreach (child; node.children) {
            setIgnorePuppetRecurse(child, ignorePuppet);
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
        pass.scale = vec2(transform.scale.x, transform.scale.y);
        pass.rotationZ = transform.rotation.z;
        return pass;
    }

    void renderNestedOffscreen(RenderContext ctx) {
        dynamicRenderBegin(ctx);
        dynamicRenderEnd(ctx);
    }

    bool initTarget() {
        auto prevTexture = textures[0];
        auto prevStencil = stencil;

        vec4 targetBounds;
        if (autoResizedMesh) {
            targetBounds = getChildrenBounds(true);
            if (!boundsFinite(targetBounds)) {
                targetBounds = getMeshBounds();
            }
        } else {
            targetBounds = getMeshBounds();
            if (!boundsFinite(targetBounds)) {
                targetBounds = getChildrenBounds(true);
            }
        }

        if (!boundsFinite(targetBounds)) {
            return false;
        }

        vec2 size = targetBounds.zw - targetBounds.xy;
        if (!sizeFinite(size) || size.x <= 0 || size.y <= 0) {
            return false;
        }

        texWidth = cast(uint)(ceil(size.x)) + 1;
        texHeight = cast(uint)(ceil(size.y)) + 1;
        textureOffset = (targetBounds.xy + targetBounds.zw) / 2;
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
        if (deferredChanged) {
            if (autoResizedMesh) {
                if (createSimpleMesh()) initialized = false;
            }
            deferredChanged = false;
            textureInvalidated = true;
            hasValidOffscreenContent = false;
            loggedFirstRenderAttempt = false;
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

    vec4 getChildrenBounds(bool forceUpdate = true) {
        if (forceUpdate) {
            foreach (p; subParts) p.updateBounds();
        }
        if (subParts.length == 0) {
            return vec4(0, 0, 0, 0);
        }

        auto inv = transform.matrix.inverse;
        bool first = true;
        vec4 bounds;

        foreach (child; subParts) {
            auto childMatrix = inv * child.transform.matrix();
            auto verts = child.vertices;
            auto deform = child.deformation;
            auto origin = child.data.origin;
            size_t count = verts.length;
            for (size_t i = 0; i < count; ++i) {
                vec2 pos = verts[i] - origin;
                if (i < deform.length) {
                    pos += deform[i];
                }
                auto local = childMatrix * vec4(pos, 0, 1);
                if (first) {
                    bounds = vec4(local.x, local.y, local.x, local.y);
                    first = false;
                } else {
                    bounds.x = min(bounds.x, local.x);
                    bounds.y = min(bounds.y, local.y);
                    bounds.z = max(bounds.z, local.x);
                    bounds.w = max(bounds.w, local.y);
                }
            }
        }

        if (first) {
            return vec4(0, 0, 0, 0);
        }
        return bounds;
    }

    bool createSimpleMesh() {
        auto bounds = getChildrenBounds();
        vec2 size = bounds.zw - bounds.xy;
        if (size.x <= 0 || size.y <= 0) {
            return false;
        }

        auto newTextureOffset = (bounds.xy + bounds.zw) / 2;
        uint desiredWidth = cast(uint)ceil(size.x) + 1;
        uint desiredHeight = cast(uint)ceil(size.y) + 1;
        bool resizing = forceResize || textures[0] is null || textures[0].width != desiredWidth || textures[0].height != desiredHeight;
        forceResize = false;

        Vec2Array vertexArray = Vec2Array([
            vec2(bounds.x, bounds.y),
            vec2(bounds.x, bounds.w),
            vec2(bounds.z, bounds.y),
            vec2(bounds.z, bounds.w)
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
        } else {
            data.vertices = vertexArray;
            shouldUpdateVertices = true;
            updateVertices();
        }

        autoResizedSize = size;
        textureOffset = newTextureOffset;
        return resizing;
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
        Constructs a new composite
    */
    this(MeshData data, uint uuid, Node parent = null) {
        if (data.indices.length != 0) autoResizedMesh = false;
        super(data, uuid, parent);
    }

    @Ignore
    override
    Transform transform() {
        if (autoResizedMesh) {
            if (recalculateTransform) {
                localTransform.update();
                offsetTransform.update();

                if (lockToRoot())
                    globalTransform = localTransform.calcOffset(offsetTransform) * puppet.root.localTransform;
                else if (parent !is null)
                    globalTransform = localTransform.calcOffset(offsetTransform) * parent.transform;
                else
                    globalTransform = localTransform.calcOffset(offsetTransform);

                globalTransform.rotation = vec3(0, 0, 0);
                globalTransform.scale = vec2(1, 1);
                globalTransform.update();
                recalculateTransform = false;
            }

            return globalTransform;
        } else {
            return super.transform();
        }
    }

    override
    protected void runDynamicTask() {
        if (autoResizedMesh) {
            if (shouldUpdateVertices) {
                shouldUpdateVertices = false;
            }
            if (createSimpleMesh()) initialized = false;
        } else {
            super.runDynamicTask();
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
        foreach (Part child; subParts) {
            child.drawOne();
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

    override
    void registerRenderTasks(TaskScheduler scheduler) {
        if (scheduler is null) return;

        scheduler.addTask(TaskOrder.Init, TaskKind.Init, (ref RenderContext ctx) { runBeginTask(); });
        scheduler.addTask(TaskOrder.PreProcess, TaskKind.PreProcess, (ref RenderContext ctx) { runPreProcessTask(); });
        scheduler.addTask(TaskOrder.Dynamic, TaskKind.Dynamic, (ref RenderContext ctx) { runDynamicTask(); });
        scheduler.addTask(TaskOrder.Post0, TaskKind.PostProcess, (ref RenderContext ctx) { runPostTask(0); });
        scheduler.addTask(TaskOrder.Post1, TaskKind.PostProcess, (ref RenderContext ctx) { runPostTask(1); });
        scheduler.addTask(TaskOrder.Post2, TaskKind.PostProcess, (ref RenderContext ctx) { runPostTask(2); });

        bool allowRenderTasks = !hasDynamicCompositeAncestor();
        if (allowRenderTasks) {
            scheduler.addTask(TaskOrder.RenderBegin, TaskKind.Render, (ref RenderContext ctx) { runRenderBeginTask(ctx); });
            scheduler.addTask(TaskOrder.Render, TaskKind.Render, (ref RenderContext ctx) { runRenderTask(ctx); });
        }

        scheduler.addTask(TaskOrder.Final, TaskKind.Finalize, (ref RenderContext ctx) { runFinalTask(); });

        auto orderedChildren = children.dup;
        if (orderedChildren.length > 1) {
            import std.algorithm.sorting : sort;
            orderedChildren.sort!((a, b) => a.zSort > b.zSort);
        }

        foreach(child; orderedChildren) {
            child.registerRenderTasks(scheduler);
        }

        if (allowRenderTasks) {
            scheduler.addTask(TaskOrder.RenderEnd, TaskKind.Render, (ref RenderContext ctx) { runRenderEndTask(ctx); });
        }
    }

    private void dynamicRenderBegin(RenderContext ctx) {
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

        foreach (Part child; subParts) {
            auto finalMatrix = childBasis * child.transform.matrix();
            child.setOffscreenModelMatrix(finalMatrix);
            if (auto dynChild = cast(DynamicComposite)child) {
                dynChild.renderNestedOffscreen(ctx);
            } else {
                child.enqueueRenderCommands(ctx);
            }
            queuedOffscreenParts ~= child;
        }


    }

    private void dynamicRenderEnd(RenderContext ctx) {
        if (ctx.renderGraph is null) return;
        bool redrew = dynamicScopeActive;
        if (dynamicScopeActive) {
            ctx.renderGraph.popDynamicComposite(dynamicScopeToken, (ref RenderCommandBuffer buffer) {
                auto packet = makePartDrawPacket(this);
                bool hasMasks = masks.length > 0;
                bool useStencil = hasMasks && maskCount > 0;

                if (hasMasks) {
                    buffer.add(makeBeginMaskCommand(useStencil));
                    foreach (ref mask; masks) {
                        if (mask.maskSrc !is null) {
                            bool isDodge = mask.mode == MaskingMode.DodgeMask;
                            MaskApplyPacket applyPacket;
                            if (tryMakeMaskApplyPacket(mask.maskSrc, isDodge, applyPacket)) {
                                buffer.add(makeApplyMaskCommand(applyPacket));
                            }
                        }
                    }
                    buffer.add(makeBeginMaskContentCommand());
                }

                buffer.add(makeDrawPartCommand(packet));

                if (hasMasks) {
                    buffer.add(makeEndMaskCommand());
                }
            });
        } else {
            enqueueRenderCommands(ctx);
        }
        reuseCachedTextureThisFrame = false;
        foreach (part; queuedOffscreenParts) {
            part.clearOffscreenModelMatrix();
        }
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
    void delegatedRunRenderBeginTask(RenderContext ctx) {
        dynamicRenderBegin(ctx);
    }

    package(nijilive)
    void delegatedRunRenderTask(RenderContext ctx) {
    }

    package(nijilive)
    void delegatedRunRenderEndTask(RenderContext ctx) {
        dynamicRenderEnd(ctx);
    }

    package(nijilive)
    void registerDelegatedTasks(TaskScheduler scheduler) {
        if (scheduler is null) return;

        scheduler.addTask(TaskOrder.Init, TaskKind.Init, (ref RenderContext ctx) { runBeginTask(); });
        scheduler.addTask(TaskOrder.PreProcess, TaskKind.PreProcess, (ref RenderContext ctx) { runPreProcessTask(); });
        scheduler.addTask(TaskOrder.Dynamic, TaskKind.Dynamic, (ref RenderContext ctx) { runDynamicTask(); });
        scheduler.addTask(TaskOrder.Post0, TaskKind.PostProcess, (ref RenderContext ctx) { runPostTask(0); });
        scheduler.addTask(TaskOrder.Post1, TaskKind.PostProcess, (ref RenderContext ctx) { runPostTask(1); });
        scheduler.addTask(TaskOrder.Post2, TaskKind.PostProcess, (ref RenderContext ctx) { runPostTask(2); });
        scheduler.addTask(TaskOrder.Final, TaskKind.Finalize, (ref RenderContext ctx) { runFinalTask(); });
    }

    override
    protected void runRenderBeginTask(RenderContext ctx) {
        dynamicRenderBegin(ctx);
    }

    override
    protected void runRenderTask(RenderContext ctx) {
    }

    override
    protected void runRenderEndTask(RenderContext ctx) {
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
    }

    void scanSubParts(Node[] childNodes) { 
        subParts.length = 0;
        foreach (child; childNodes) {
            scanPartsRecurse(child);
        }
    }

    override
    bool setupChild(Node node) {
        setIgnorePuppetRecurse(node, true);
        if (puppet !is null) 
            puppet.rescanNodes();

        forceResize = true;

        return false;
    }

    override
    bool releaseChild(Node node) {
        setIgnorePuppetRecurse(node, false);
        scanSubParts(children);
        forceResize = true;

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
                if (prevTranslation != transform.translation || prevRotation != transform.rotation || prevScale != transform.scale) {
                    deferredChanged = true;
                    prevTranslation = transform.translation;
                    prevRotation    = transform.rotation;
                    prevScale       = transform.scale;
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
            textureInvalidated = true;
            hasValidOffscreenContent = false;
            loggedFirstRenderAttempt = false;
        }
        if (autoResizedMesh) {
            if (createSimpleMesh()) {
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
            if (autoResizedMesh) {
                createSimpleMesh();
                updateBounds();
            }
        } else {
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
