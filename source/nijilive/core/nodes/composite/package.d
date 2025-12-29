/*
    nijilive Composite Node
    previously Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite;

import nijilive.core;
import nijilive.core.meshdata;
import nijilive.core.nodes;
import nijilive.core.nodes.common;
import nijilive.core.nodes.composite.dcomposite;
import nijilive.core.nodes.composite.projectable;
import nijilive.core.nodes.mask : Mask;
import nijilive.fmt;
import nijilive.math;
import nijilive.core.render.commands : DynamicCompositePass, PartDrawPacket;
import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.scheduler : RenderContext;
import std.stdio : writefln;
import std.math : isFinite;
import std.algorithm : map;
import std.algorithm.comparison : min, max;
version (NijiliveRenderProfiler) import nijilive.core.render.profiler : profileScope;

package(nijilive) {
    void inInitComposite() {
        inRegisterNodeType!Composite;
    }
}

@TypeId("Composite")
class Composite : Projectable {
public:
    bool propagateMeshGroup = true;
    alias threshold = maskAlphaThreshold;

    this(Node parent = null) {
        super(parent);
        autoResizedMesh = true;
    }

    this(MeshData data, uint uuid, Node parent = null) {
        super(data, uuid, parent);
        autoResizedMesh = true;
    }

public:
    // Keep rotation/scale intact even when autoResizedMesh is true.
    override Transform transform() {
        return Part.transform();
    }

protected:
    override bool mustPropagate() { return propagateMeshGroup; }

    override void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);
    }

    override SerdeException deserializeFromFghj(Fghj data) {
        auto result = super.deserializeFromFghj(data);
        return result;
    }

    override void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);
    }

protected:
    // Keep camera neutral; only use DynamicComposite offscreen surface.
    override DynamicCompositePass prepareDynamicCompositePass() {
        auto pass = super.prepareDynamicCompositePass();
        if (pass !is null) {
            pass.scale = vec2(1, 1);
            pass.rotationZ = 0;
            pass.autoScaled = false;
        }
        return pass;
    }

    /// Build child matrix with texture offset; treat Composite as transparent.
    mat4 childOffscreenMatrix(Part child) {
        auto offset = textureOffset;
        if (!isFinite(offset.x) || !isFinite(offset.y)) {
            offset = vec2(0, 0);
        }
        auto invComposite = transform().matrix.inverse;
        auto childLocal = invComposite * child.transform.matrix;
        auto translate = mat4.translation(-offset.x, -offset.y, 0);
        return translate * childLocal;
    }

    /// Core child matrix without texture offset (for bounds calculation).
    mat4 childCoreMatrix(Part child) {
        return child.transform.matrix;
    }

    vec4 localBoundsFromMatrix(Part child, const mat4 matrix) {
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

    override vec4 getChildrenBounds(bool forceUpdate = true) {
        version (NijiliveRenderProfiler) auto __prof = profileScope("Composite:getChildrenBounds");
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
        bool useMatrixBounds = autoResizedMesh;
        if (useMatrixBounds) {
            bool hasBounds = false;
            foreach (part; subParts) {
                auto childMatrix = childCoreMatrix(part);
                auto childBounds = localBoundsFromMatrix(part, childMatrix);
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

    override void enableMaxChildrenBounds(Node target = null) {
        Drawable targetDrawable = cast(Drawable)target;
        if (targetDrawable !is null && (!autoResizedMesh)) {
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
            if (autoResizedMesh) {
                if (auto targetPart = cast(Part)targetDrawable) {
                    b = localBoundsFromMatrix(targetPart, childCoreMatrix(targetPart));
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

    override void drawContents() {
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

        foreach (Part child; subParts) {
            auto childMatrix = childOffscreenMatrix(child);
            child.setOffscreenModelMatrix(childMatrix);
            child.drawOne();
            child.clearOffscreenModelMatrix();
        }

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

    /// Compositeは子を素のスケール/回転のまま描き、textureOffsetだけ平行移動してオフスクリーンへ描く。
    protected override void dynamicRenderBegin(ref RenderContext ctx) {
        dynamicScopeActive = false;
        dynamicScopeToken = size_t.max;
        reuseCachedTextureThisFrame = false;
        if (!hasValidOffscreenContent) {
            textureInvalidated = true;
        }
        if (autoResizedMesh && createSimpleMesh()) {
            textureInvalidated = true;
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
        // CompositeもDynamicCompositeパスでレンダリングし、転送はdrawOne()内のdrawSelf。
        dynamicScopeToken = ctx.renderGraph.pushDynamicComposite(this, passData, zSort());
        dynamicScopeActive = true;

        queuedOffscreenParts.length = 0;

        foreach (Part child; subParts) {
            auto finalMatrix = childOffscreenMatrix(child);
            child.setOffscreenModelMatrix(finalMatrix);
            if (auto dynChild = cast(Projectable)child) {
                dynChild.renderNestedOffscreen(ctx);
            } else {
                child.enqueueRenderCommands(ctx);
            }
            queuedOffscreenParts ~= child;
        }
    }
}
