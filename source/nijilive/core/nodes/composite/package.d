/*
    nijilive Composite Node
    previously Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite;
import nijilive.core.nodes.common;
import nijilive.core.render.commands : makeCompositeDrawPacket, tryMakeMaskApplyPacket,
    MaskApplyPacket;
import nijilive.core.nodes.composite.dcomposite;
import nijilive.core.nodes;
import nijilive.fmt;
import nijilive.core;
import nijilive.math;
import std.exception;
import std.algorithm.sorting;
import nijilive.core.render.scheduler : RenderContext, TaskScheduler, TaskOrder, TaskKind;
//import std.stdio;
package(nijilive) {
    void inInitComposite() {
        inRegisterNodeType!Composite;

    }
}

/**
    Composite Node
*/
@TypeId("Composite")
class Composite : Node {
public:
    DynamicComposite delegated = null;
private:
    bool compositeScopeActive = false;
    size_t compositeScopeToken = size_t.max;
    package(nijilive) void markCompositeScopeClosed() {
        compositeScopeActive = false;
        compositeScopeToken = size_t.max;
    }

    package(nijilive) bool isCompositeScopeActive() const {
        return compositeScopeActive;
    }

    package(nijilive) size_t compositeScopeTokenValue() const {
        return compositeScopeToken;
    }

    this() { }

    void synchronizeDelegated() {
        if (delegated) {
            delegated.opacity = opacity;
            delegated.blendingMode = blendingMode;
            delegated.zSort = relZSort;
            if (oneTimeTransform) {
                delegated.setOneTimeTransform(oneTimeTransform);
            }
        }
    }

    void drawContents() {
        if (delegated) {
//            writefln("%s: delegate drawContents", name);
            delegated.drawContents();
            return;
        }

        // Optimization: Nothing to be drawn, skip context switching
        if (subParts.length == 0) return;

        version(InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            backend.beginComposite();

            foreach(Part child; subParts) {
                child.drawOne();
            }

            backend.endComposite();
        }
    }

    /*
        RENDERING
    */
    void drawSelf() {
        if (delegated) {
            synchronizeDelegated();
            delegated.drawSelf();
            return;
        }
        drawSelfImmediate();
    }

    void drawSelfImmediate() {
        version(InDoesRender) {
            if (subParts.length == 0) return;
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            auto packet = makeCompositeDrawPacket(this);
            backend.drawCompositeQuad(packet);
        }
    }

    void selfSort() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: selfSort", name);
            delegated.selfSort();
            return;
        }

        sort!((a, b) => a.zSort > b.zSort)(subParts);
    }

    void scanPartsRecurse(ref Node node) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate scanPartsRecurse", name);
            delegated.scanPartsRecurse(node);
            return;
        }

        // Don't need to scan null nodes
        if (node is null) return;

        // Do the main check
        if (Part part = cast(Part)node) {
            subParts ~= part;
            part.ignorePuppet = false;
            foreach(child; part.children) {
                scanPartsRecurse(child);
            }
            
        } else if (auto innerComp = cast(Composite)node) {
            if (innerComp is this) return;
            // Nested composites manage their own parts.
            return;
        } else if (auto innerDynamic = cast(DynamicComposite)node) {
            // Dynamic composites manage their own parts.
            return;
        } else {

            // Non-part nodes just need to be recursed through,
            // they don't draw anything.
            foreach(child; node.children) {
                scanPartsRecurse(child);
            }
        }
    }

protected:
    Part[] subParts;

    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive=true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);

        if (flags & SerializeNodeFlags.State) {
            serializer.putKey("blend_mode");
            serializer.serializeValue(blendingMode);

            serializer.putKey("tint");
            tint.serialize(serializer);

            serializer.putKey("screenTint");
            screenTint.serialize(serializer);

            serializer.putKey("mask_threshold");
            serializer.putValue(threshold);

            serializer.putKey("opacity");
            serializer.putValue(opacity);

            serializer.putKey("propagate_meshgroup");
            serializer.serializeValue(propagateMeshGroup);
        }

        if ((flags & SerializeNodeFlags.Links) && masks.length > 0) {
            serializer.putKey("masks");
            auto state = serializer.listBegin();
                foreach(m; masks) {
                    serializer.elemBegin;
                    serializer.serializeValue(m);
                }
            serializer.listEnd(state);

        }
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {

        // Older models may not have these tags
        if (!data["opacity"].isEmpty) data["opacity"].deserializeValue(this.opacity);
        if (!data["mask_threshold"].isEmpty) data["mask_threshold"].deserializeValue(this.threshold);
        if (!data["tint"].isEmpty) deserialize(this.tint, data["tint"]);
        if (!data["screenTint"].isEmpty) deserialize(this.screenTint, data["screenTint"]);
        if (!data["blend_mode"].isEmpty) data["blend_mode"].deserializeValue(this.blendingMode);
        if (!data["masks"].isEmpty) data["masks"].deserializeValue(this.masks);
        if (!data["propagate_meshgroup"].isEmpty)
            data["propagate_meshgroup"].deserializeValue(propagateMeshGroup);
        else // falls back to legacy default
            propagateMeshGroup = false;

        return super.deserializeFromFghj(data);
    }

    //
    //      PARAMETER OFFSETS
    //
public:
    float offsetOpacity = 1;
    vec3 offsetTint = vec3(0);
    vec3 offsetScreenTint = vec3(0);

    override
    string typeId() { return "Composite"; }

    // TODO: Cache this
    size_t maskCount() {
        size_t c;
        foreach(m; masks) if (m.mode == MaskingMode.Mask) c++;
        return c;
    }

    size_t dodgeCount() {
        size_t c;
        foreach(m; masks) if (m.mode == MaskingMode.DodgeMask) c++;
        return c;
    }

    float effectiveOpacity() const {
        return clamp(offsetOpacity * opacity, 0, 1);
    }

    vec3 computeClampedTint() const {
        vec3 clamped = tint;
        if (!offsetTint.x.isNaN) clamped.x = clamp(tint.x * offsetTint.x, 0, 1);
        if (!offsetTint.y.isNaN) clamped.y = clamp(tint.y * offsetTint.y, 0, 1);
        if (!offsetTint.z.isNaN) clamped.z = clamp(tint.z * offsetTint.z, 0, 1);
        return clamped;
    }

    vec3 computeClampedScreenTint() const {
        vec3 clamped = screenTint;
        if (!offsetScreenTint.x.isNaN) clamped.x = clamp(screenTint.x + offsetScreenTint.x, 0, 1);
        if (!offsetScreenTint.y.isNaN) clamped.y = clamp(screenTint.y + offsetScreenTint.y, 0, 1);
        if (!offsetScreenTint.z.isNaN) clamped.z = clamp(screenTint.z + offsetScreenTint.z, 0, 1);
        return clamped;
    }

    override
    void preProcess() {
        if (delegated) {
            delegated.preProcess();
        }
        if (!propagateMeshGroup)
            Node.preProcess();
    }

    override
    void postProcess(int id = 0) {
        if (delegated) {
            delegated.postProcess(id);
        }
        if (!propagateMeshGroup)
            Node.postProcess(id);
    }

public:
    bool propagateMeshGroup = true;

    /**
        The blending mode
    */
    BlendMode blendingMode;

    /**
        The opacity of the composite
    */
    float opacity = 1;

    /**
        The threshold for rendering masks
    */
    float threshold = 0.5;

    /**
        Multiplicative tint color
    */
    vec3 tint = vec3(1, 1, 1);

    /**
        Screen tint color
    */
    vec3 screenTint = vec3(0, 0, 0);

    /**
        List of masks to apply
    */
    MaskBinding[] masks;


    /**
        Constructs a new mask
    */
    this(Node parent = null) {
        this(inCreateUUID(), parent);
    }

    /**
        Constructs a new composite
    */
    this(uint uuid, Node parent = null) {
        super(uuid, parent);
    }

    override
    bool hasParam(string key) {
        if (super.hasParam(key)) return true;

        switch(key) {
            case "opacity":
            case "tint.r":
            case "tint.g":
            case "tint.b":
            case "screenTint.r":
            case "screenTint.g":
            case "screenTint.b":
                return true;
            default:
                return false;
        }
    }

    override
    float getDefaultValue(string key) {
        // Skip our list of our parent already handled it
        float def = super.getDefaultValue(key);
        if (!isNaN(def)) return def;

        switch(key) {
            case "opacity":
            case "tint.r":
            case "tint.g":
            case "tint.b":
                return 1;
            case "screenTint.r":
            case "screenTint.g":
            case "screenTint.b":
                return 0;
            default: return float();
        }
    }

    override
    bool setValue(string key, float value) {
        
        // Skip our list of our parent already handled it
        if (super.setValue(key, value)) return true;

        switch(key) {
            case "opacity":
                offsetOpacity *= value;
                return true;
            case "tint.r":
                offsetTint.x *= value;
                return true;
            case "tint.g":
                offsetTint.y *= value;
                return true;
            case "tint.b":
                offsetTint.z *= value;
                return true;
            case "screenTint.r":
                offsetScreenTint.x += value;
                return true;
            case "screenTint.g":
                offsetScreenTint.y += value;
                return true;
            case "screenTint.b":
                offsetScreenTint.z += value;
                return true;
            default: return false;
        }
    }
    
    override
    float getValue(string key) {
        switch(key) {
            case "opacity":         return offsetOpacity;
            case "tint.r":          return offsetTint.x;
            case "tint.g":          return offsetTint.y;
            case "tint.b":          return offsetTint.z;
            case "screenTint.r":    return offsetScreenTint.x;
            case "screenTint.g":    return offsetScreenTint.y;
            case "screenTint.b":    return offsetScreenTint.z;
            default:                return super.getValue(key);
        }
    }

    bool isMaskedBy(Drawable drawable) {
        foreach(mask; masks) {
            if (mask.maskSrc.uuid == drawable.uuid) return true;
        }
        return false;
    }

    ptrdiff_t getMaskIdx(Drawable drawable) {
        if (drawable is null) return -1;
        foreach(i, ref mask; masks) {
            if (mask.maskSrc.uuid == drawable.uuid) return i;
        }
        return -1;
    }

    ptrdiff_t getMaskIdx(uint uuid) {
        foreach(i, ref mask; masks) {
            if (mask.maskSrc.uuid == uuid) return i;
        }
        return -1;
    }

    override
    protected void runBeginTask(ref RenderContext ctx) {
        offsetOpacity = 1;
        offsetTint = vec3(1, 1, 1);
        offsetScreenTint = vec3(0, 0, 0);
        super.runBeginTask(ctx);
    }

    override
    protected void runRenderBeginTask(ref RenderContext ctx) {
        if (!renderEnabled() || ctx.renderGraph is null) return;
        if (delegated) {
            delegated.delegatedRunRenderBeginTask(ctx);
            return;
        }
        selfSort();
        if (subParts.length == 0) {
            // 万が一スキャンが漏れていた場合に備え、その場で更新して描画を継続できるようにする
            scanParts();
            if (subParts.length == 0) return;
        }

        MaskApplyPacket[] maskPackets;
        bool useStencil = false;
        if (masks.length > 0) {
            useStencil = maskCount() > 0;
            foreach (ref mask; masks) {
                if (mask.maskSrc !is null) {
                    bool isDodge = mask.mode == MaskingMode.DodgeMask;
                    MaskApplyPacket applyPacket;
                    if (tryMakeMaskApplyPacket(mask.maskSrc, isDodge, applyPacket)) {
                        maskPackets ~= applyPacket;
                    }
                }
            }
        }

        auto drawPacket = makeCompositeDrawPacket(this);
        compositeScopeToken = ctx.renderGraph.pushComposite(this, zSort(), drawPacket, useStencil, maskPackets);
        compositeScopeActive = true;
    }

    override
    protected void runRenderTask(ref RenderContext ctx) {
        if (delegated) {
            delegated.delegatedRunRenderTask(ctx);
        }
    }

    override
    protected void runRenderEndTask(ref RenderContext ctx) {
        if (ctx.renderGraph is null) return;
        if (delegated) {
            delegated.delegatedRunRenderEndTask(ctx);
            return;
        }

        if (!compositeScopeActive) return;

        ctx.renderGraph.popComposite(compositeScopeToken);
        markCompositeScopeClosed();
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
        scheduler.addTask(TaskOrder.RenderBegin, TaskKind.Render, &runRenderBeginTask);
        scheduler.addTask(TaskOrder.Render, TaskKind.Render, &runRenderTask);
        scheduler.addTask(TaskOrder.Final, TaskKind.Finalize, &runFinalTask);

        if (delegated !is null) {
            delegated.registerDelegatedTasks(scheduler);
        }

        auto orderedChildren = children.dup;
        if (orderedChildren.length > 1) {
            import std.algorithm.sorting : sort;
            orderedChildren.sort!((a, b) => a.zSort > b.zSort);
        }

        foreach (child; orderedChildren) {
            child.registerRenderTasks(scheduler);
        }

        scheduler.addTask(TaskOrder.RenderEnd, TaskKind.Render, &runRenderEndTask);
    }

    override
    void drawOne() {
        if (delegated) {
            synchronizeDelegated();
            delegated.drawOne();
            return;
        }
        if (!enabled) return;
        
        this.selfSort();
        this.drawContents();

        version(InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;

            size_t cMasks = maskCount;

            if (masks.length > 0) {
                backend.beginMask(cMasks > 0);

                foreach(ref mask; masks) {
                    mask.maskSrc.renderMask(mask.mode == MaskingMode.DodgeMask);
                }

                backend.beginMaskContent();

                drawSelfImmediate();

                backend.endMask();
                return;
            }

            drawSelfImmediate();
        }
    }

    override
    void draw() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: draw", name);
            delegated.draw();
            return;
        } else {
//            writefln("%s: draw", name);
        }
        if (!enabled) return;
        this.drawOne();
    }

    override
    void finalize() {
        super.finalize();
        
        MaskBinding[] validMasks;
        foreach(i; 0..masks.length) {
            if (Drawable nMask = puppet.find!Drawable(masks[i].maskSrcUUID)) {
                masks[i].maskSrc = nMask;
                validMasks ~= masks[i];
            }
        }

        // Remove invalid masks
        masks = validMasks;
    }

    /**
        Scans for parts to render
    */
    void scanParts() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: scanParts", name);
            delegated.scanSubParts(children);
            return;
        }
        subParts.length = 0;
        foreach (child; children) {
            scanPartsRecurse(child);
        }
    }

    override
    bool setupChild(Node node) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: setupChild", name);
            delegated.setupChild(node);
        }
        return mustPropagate;
    }

    override
    bool releaseChild(Node node) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: releaseChild", name);
            delegated.releaseChild(node);
        }
        return mustPropagate;
    }

    override
    void setupSelf() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: setupSelf", name);
            delegated.setupSelf();
        }
    }

    override
    void normalizeUV(MeshData* data) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: normalizeUV", name);
            delegated.normalizeUV(data);
        }
    }

    override
    void notifyChange(Node target, NotifyReason reason = NotifyReason.Transformed) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: notifyChange, %s", name, target.name);
            delegated.notifyChange(target, reason);
        } else {
            super.notifyChange(target, reason);
        }
    }

    override
    void transformChanged() {
        super.transformChanged();
        if (delegated) {
            delegated.recalculateTransform = true;
        }
    }

    override
    void centralize() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: centralize", name);
            delegated.centralize();
            return;
        }
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
        clearCache();
        foreach (i, child; children) {
            child.localTransform.translation = (transform.matrix.inverse * childTranslations[i]).xyz;
            child.transformChanged();
        }

    }

    void setDelegation(DynamicComposite delegated) {
        if (this.delegated && this.delegated != delegated) {
            this.delegated.releaseSelf();
            this.delegated.children_ref.length = 0;
            this.delegated.parent = null;
        }
        if (this.delegated != delegated) {
            this.delegated = delegated;
            if (this.delegated)
                this.delegated.setupSelf();
        }
    }

    override
    void flushNotifyChange() {
        if (delegated) {
            delegated.flushNotifyChange();
        }
        super.flushNotifyChange();
    }

    override
    bool mustPropagate() { return propagateMeshGroup; }
}
