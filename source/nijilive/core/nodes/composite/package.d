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
import nijilive.core.runtime_state : inGetCamera;
import std.stdio : writefln;
import std.math : isFinite;
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
    // Ensure serialization writes correct node type (not Part's typeId).
    override string typeId() { return "Composite"; }
    private vec2 prevCompositeScale;
    private bool hasPrevCompositeScale = false;

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

    // Serialize only legacy Composite fields for compatibility.
    override void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        // Serialize base Node/Part state via super.
        Node.serializeSelfImpl(serializer, recursive, flags);

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
            foreach (m; masks) {
                serializer.elemBegin;
                serializer.serializeValue(m);
            }
            serializer.listEnd(state);
        }
    }

    override SerdeException deserializeFromFghj(Fghj data) {
        // Base Node/Part first.
        auto result = Node.deserializeFromFghj(data);

        // Legacy keys only
        if (!data["opacity"].isEmpty) data["opacity"].deserializeValue(this.opacity);
        if (!data["mask_threshold"].isEmpty) data["mask_threshold"].deserializeValue(this.threshold);
        if (!data["tint"].isEmpty) deserialize(this.tint, data["tint"]);
        if (!data["screenTint"].isEmpty) deserialize(this.screenTint, data["screenTint"]);
        if (!data["blend_mode"].isEmpty) data["blend_mode"].deserializeValue(this.blendingMode);
        if (!data["masks"].isEmpty) data["masks"].deserializeValue(this.masks);
        if (!data["propagate_meshgroup"].isEmpty)
            data["propagate_meshgroup"].deserializeValue(propagateMeshGroup);
        else
            propagateMeshGroup = false;

        // Default legacy behavior: auto-resized meshes and no textures.
        autoResizedMesh = true;
        textures = [null, null, null];

        return result;
    }

    override void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        super.copyFrom(src, clone, deepCopy);
    }

protected:
    // Local copy: Projectable's helper is private there.
    private vec2 deformationTranslationOffsetLocal() const {
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

    private vec2 compositeAutoScale() {
        auto camera = inGetCamera();
        vec2 scale = camera.scale;
        if (!isFinite(scale.x) || scale.x == 0) scale.x = 1;
        if (!isFinite(scale.y) || scale.y == 0) scale.y = 1;
        if (puppet !is null) {
            auto puppetScale = puppet.transform.scale;
            if (!isFinite(puppetScale.x) || puppetScale.x == 0) puppetScale.x = 1;
            if (!isFinite(puppetScale.y) || puppetScale.y == 0) puppetScale.y = 1;
            scale.x *= puppetScale.x;
            scale.y *= puppetScale.y;
        }
        return vec2(abs(scale.x), abs(scale.y));
    }

    override bool updateDynamicRenderStateFlags() {
        auto currentScale = compositeAutoScale();
        enum float scaleEps = 0.0001f;
        bool scaleChanged = !hasPrevCompositeScale ||
            abs(currentScale.x - prevCompositeScale.x) > scaleEps ||
            abs(currentScale.y - prevCompositeScale.y) > scaleEps;
        if (scaleChanged) {
            prevCompositeScale = currentScale;
            hasPrevCompositeScale = true;
            forceResize = true;
            useMaxChildrenBounds = false;
            boundsDirty = true;
            textureInvalidated = true;
            hasValidOffscreenContent = false;
            loggedFirstRenderAttempt = false;
        }
        return super.updateDynamicRenderStateFlags();
    }

    override DynamicCompositePass prepareDynamicCompositePass() {
        auto pass = super.prepareDynamicCompositePass();
        if (pass !is null) {
            pass.autoScaled = true;
        }
        return pass;
    }

    /// Build child matrix with texture offset; treat Composite as transparent.
    mat4 childOffscreenMatrix(Part child) {
        auto scale = compositeAutoScale();
        auto scaleMat = mat4.identity.scaling(scale.x, scale.y, 1);
        auto offset = textureOffset;
        if (!isFinite(offset.x) || !isFinite(offset.y)) {
            offset = vec2(0, 0);
        }
        // Composite auto-scales: keep rotation/scale in offscreen render,
        // only remove translation to align with texture space.
        auto trans = transform();
        auto invTranslate = mat4.translation(-trans.translation.x * scale.x, -trans.translation.y * scale.y, 0);
        auto childLocal = invTranslate * (scaleMat * child.transform.matrix);
        auto translate = mat4.translation(-offset.x, -offset.y, 0);
        return translate * childLocal;
    }

    /// Core child matrix without texture offset (for bounds calculation).
    mat4 childCoreMatrix(Part child) {
        return child.transform.matrix;
    }

    override void fillDrawPacket(ref PartDrawPacket packet, bool isMask = false) {
        super.fillDrawPacket(packet, isMask);
        if (!packet.renderable) return;

        // Composite consumes its own rotation/scale offscreen; display uses translation only.
        auto screen = transform();
        screen.rotation = vec3(0, 0, 0);
        screen.scale = vec2(1, 1);
        screen.update();
        packet.modelMatrix = screen.matrix;

        // Cancel camera scale/rotation around the composite's current screen-space origin.
        auto cam = inGetCamera();
        auto camMatrix = cam.matrix;
        auto origin4 = camMatrix * packet.puppetMatrix * packet.modelMatrix * vec4(0, 0, 0, 1);
        vec2 origin = origin4.xy;
        float invScaleX = cam.scale.x == 0 ? 1 : 1 / cam.scale.x;
        float invScaleY = cam.scale.y == 0 ? 1 : 1 / cam.scale.y;
        if (!isFinite(invScaleX)) invScaleX = 1;
        if (!isFinite(invScaleY)) invScaleY = 1;
        float rot = cam.rotation;
        if (!isFinite(rot)) rot = 0;
        if (cam.scale.x * cam.scale.y < 0) {
            rot = -rot;
        }
        auto cancel = mat4.translation(origin.x, origin.y, 0) *
            mat4.identity.rotateZ(-rot) *
            mat4.identity.scaling(invScaleX, invScaleY, 1) *
            mat4.translation(-origin.x, -origin.y, 0);
        auto correction = camMatrix.inverse * cancel * camMatrix;
        packet.puppetMatrix = correction * packet.puppetMatrix;
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
        auto scale = compositeAutoScale();
        auto scaleMat = mat4.identity.scaling(scale.x, scale.y, 1);
        auto frameId = currentDynamicCompositeFrame();
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
        bool useMatrixBounds = autoResizedMesh;
        if (useMatrixBounds) {
            bool hasBounds = false;
            foreach (part; subParts) {
                auto childMatrix = scaleMat * childCoreMatrix(part);
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
                bounds = vec4(transform.translation.x * scale.x, transform.translation.y * scale.y,
                    transform.translation.x * scale.x, transform.translation.y * scale.y);
            }
        } else {
            bounds = mergeBounds(subParts.map!(p=>p.bounds), transform.translation.xyxy);
        }
        if (!useMaxChildrenBounds) {
            maxChildrenBounds = bounds;
            useMaxChildrenBounds = true;
            maxBoundsStartFrame = frameId;
        }
        return bounds;
    }

    override bool createSimpleMesh() {
        version (NijiliveRenderProfiler) auto __prof = profileScope("Composite:createSimpleMesh");
        auto bounds = getChildrenBounds();
        vec2 size = bounds.zw - bounds.xy;
        if (size.x <= 0 || size.y <= 0) {
            return false;
        }

        auto scale = compositeAutoScale();
        auto deformOffset = deformationTranslationOffsetLocal();
        auto scaledDeformOffset = vec2(deformOffset.x * scale.x, deformOffset.y * scale.y);
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

        auto originOffset = vec2(transform.translation.x * scale.x, transform.translation.y * scale.y) + scaledDeformOffset;
        Vec2Array vertexArray = Vec2Array([
            vec2(bounds.x, bounds.y) + scaledDeformOffset - originOffset,
            vec2(bounds.x, bounds.w) + scaledDeformOffset - originOffset,
            vec2(bounds.z, bounds.y) + scaledDeformOffset - originOffset,
            vec2(bounds.z, bounds.w) + scaledDeformOffset - originOffset
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
            textureOffset = (bounds.xy + bounds.zw) / 2 + scaledDeformOffset - originOffset;
        } else {
            auto newTextureOffset = (bounds.xy + bounds.zw) / 2 + scaledDeformOffset - originOffset;
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

    override void enableMaxChildrenBounds(Node target = null) {
        Drawable targetDrawable = cast(Drawable)target;
        if (targetDrawable !is null) {
            targetDrawable.updateBounds();
        }
        auto frameId = currentDynamicCompositeFrame();
        maxChildrenBounds = getChildrenBounds(false);
        useMaxChildrenBounds = true;
        maxBoundsStartFrame = frameId;
        if (targetDrawable !is null) {
            vec4 b = targetDrawable.bounds;
            if (!boundsFinite(b)) {
                if (auto targetPart = cast(Part)targetDrawable) {
                    b = localBoundsFromMatrix(targetPart, childCoreMatrix(targetPart));
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
