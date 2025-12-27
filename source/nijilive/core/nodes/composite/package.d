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
import nijilive.fmt;
import nijilive.math;
import nijilive.core.runtime_state : inGetCamera;
import nijilive.core.render.commands : PartDrawPacket, DynamicCompositePass;
import nijilive.core.render.scheduler : RenderContext;
import std.math : abs, isFinite;
import std.algorithm : map;
import std.algorithm.comparison : min, max;

package(nijilive) {
    void inInitComposite() {
        inRegisterNodeType!Composite;
    }
}

@TypeId("Composite")
class Composite : DynamicComposite {
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

protected:
    override bool mustPropagate() { return propagateMeshGroup; }

protected:
    vec2 appliedAutoScale() {
        if (!effectiveAutoScaled()) return vec2(1, 1);
        vec2 scale = puppetScale();
        auto camScale = cameraScale();
        scale.x *= camScale.x;
        scale.y *= camScale.y;
        return scale;
    }

    mat4 applyAutoScale(mat4 matrix) {
        auto scale = appliedAutoScale();
        if (scale.x == 1 && scale.y == 1) {
            return matrix;
        }
        auto scaleMatrix = mat4.identity.scaling(scale.x, scale.y, 1);
        return scaleMatrix * matrix;
    }

    mat4 applyAutoScaleToChild(Part child, mat4 matrix) {
        if (!effectiveAutoScaled()) return matrix;
        if (cast(DynamicComposite)child !is null) return matrix;
        return applyAutoScale(matrix);
    }

    protected vec2 puppetScale() {
        if (puppet !is null) {
            return puppet.transform.scale;
        }
        return vec2(1, 1);
    }

    protected Node ancestorAutoScaleController() {
        for (Node node = parent; node !is null; node = node.parent) {
            if (cast(Composite)node !is null) {
                return node;
            }
            if (cast(DynamicComposite)node !is null) {
                return node;
            }
        }
        return null;
    }

    protected bool effectiveAutoScaled() {
        if (auto ancestor = ancestorAutoScaleController()) {
            if (auto comp = cast(Composite)ancestor) {
                return true; // Compositeは常にautoScaled扱い
            }
            if (auto dyn = cast(DynamicComposite)ancestor) {
                // DynamicComposite側は常にautoscale無効なのでここではfalse
                return false;
            }
        }
        return true;
    }

    protected vec2 cameraScale() {
        auto cam = inGetCamera();
        if (cam is null) return vec2(1, 1);
        return vec2(abs(cam.scale.x), abs(cam.scale.y));
    }

    protected vec2 safeInverse(vec2 scale) {
        const float epsilon = 1e-6f;
        vec2 result;
        result.x = abs(scale.x) < epsilon ? 1 : 1 / scale.x;
        result.y = abs(scale.y) < epsilon ? 1 : 1 / scale.y;
        return result;
    }

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

    override void fillDrawPacket(ref PartDrawPacket packet, bool isMask = false) {
        super.fillDrawPacket(packet, isMask);
        if (!effectiveAutoScaled()) return;
        auto scale = appliedAutoScale();
        if (scale.x == 1 && scale.y == 1) {
            return;
        }
        auto inv = safeInverse(scale);
        auto invCam = safeInverse(cameraScale());
        auto cancelCamera = mat4.identity.scaling(invCam.x, invCam.y, 1);

        if (!ignorePuppet && puppet !is null) {
            auto puppetTransformNoScale = puppet.transform;
            puppetTransformNoScale.scale = vec2(1, 1);
            puppetTransformNoScale.update();
            packet.puppetMatrix = cancelCamera * puppetTransformNoScale.matrix;
        } else {
            auto invScale = mat4.identity.scaling(inv.x, inv.y, 1);
            packet.puppetMatrix = cancelCamera * packet.puppetMatrix * invScale;
        }
    }

    // Use a neutral pass so offscreen camera is not skewed by local scale/rotation;
    // texture offset handling stays in DynamicComposite.
    override DynamicCompositePass prepareDynamicCompositePass() {
        auto pass = super.prepareDynamicCompositePass();
        if (pass !is null) {
            auto scale = appliedAutoScale();
            pass.scale = vec2(transform.scale.x * scale.x, transform.scale.y * scale.y);
            pass.rotationZ = transform.rotation.z;
            pass.autoScaled = effectiveAutoScaled();
        }
        return pass;
    }

protected:
    /// Build child matrix with texture offset; apply auto scale to non-dynamic children.
    mat4 childOffscreenMatrix(Part child) {
        auto offset = textureOffset;
        if (!isFinite(offset.x) || !isFinite(offset.y)) {
            offset = vec2(0, 0);
        }
        auto correction = compositeFullTransformMatrix() * transform.matrix.inverse;
        auto scaled = applyAutoScaleToChild(child, correction * child.transform.matrix);
        auto translate = mat4.translation(-offset.x, -offset.y, 0);
        auto childBasis = translate * transform.matrix.inverse;
        return childBasis * scaled;
    }

    /// Core child matrix without texture offset (for bounds calculation).
    mat4 childCoreMatrix(Part child) {
        auto correction = compositeFullTransformMatrix() * transform.matrix.inverse;
        return applyAutoScaleToChild(child, correction * child.transform.matrix);
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

    // Recreate full transform matrix locally (base implementation is private).
    Transform compositeFullTransform() {
        localTransform.update();
        offsetTransform.update();
        if (lockToRoot()) {
            Transform trans = (puppet !is null && puppet.root !is null)
                ? puppet.root.localTransform
                : Transform(vec3(0, 0, 0));
            return localTransform.calcOffset(offsetTransform) * trans;
        }
        if (parent !is null) {
            return localTransform.calcOffset(offsetTransform) * parent.transform();
        }
        return localTransform.calcOffset(offsetTransform);
    }

    mat4 compositeFullTransformMatrix() {
        return compositeFullTransform().matrix;
    }

    override vec4 getChildrenBounds(bool forceUpdate = true) {
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
        dynamicScopeToken = ctx.renderGraph.pushDynamicComposite(this, passData, zSort());
        dynamicScopeActive = true;

        queuedOffscreenParts.length = 0;

        foreach (Part child; subParts) {
            auto finalMatrix = childOffscreenMatrix(child);
            child.setOffscreenModelMatrix(finalMatrix);
            if (auto dynChild = cast(DynamicComposite)child) {
                dynChild.renderNestedOffscreen(ctx);
            } else {
                child.enqueueRenderCommands(ctx);
            }
            queuedOffscreenParts ~= child;
        }
    }

    // no override of dynamicRenderBegin; uses base implementation
}
