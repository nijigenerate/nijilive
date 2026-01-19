/*
    nijilive Composite Node
    previously Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite.composite;

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
import std.math : isFinite, abs;
import std.algorithm.comparison : min, max;
import std.algorithm.iteration : map;
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
    private float prevCompositeRotation = 0;
    private float prevCameraRotation = 0;
    private bool hasPrevCompositeScale = false;
    // Bounds cache: ローカル座標で保持し、返却時に現在スケールを掛ける
    private vec4 maxChildrenBoundsLocal;
    private bool hasMaxChildrenBoundsLocal = false;

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

    // Preserve auto-resize flag even when rebuffering generated meshes.
    override void rebuffer(ref MeshData data) {
        super.rebuffer(data);
        autoResizedMesh = true;
    }

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
        autoResizedMesh = true;
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
        return vec2(1, 1);
    }

    private float compositeRotation() {
        float rot = transform().rotation.z;
        if (!isFinite(rot)) rot = 0;
        return rot;
    }

    private float cameraRotation() {
        auto cam = inGetCamera();
        float rot = cam.rotation;
        if (!isFinite(rot)) rot = 0;
        return rot;
    }

    override bool updateDynamicRenderStateFlags() {
        bool wasAuto = autoResizedMesh;

        auto currentScale = compositeAutoScale();
        auto currentRot = compositeRotation();
        auto camRot = cameraRotation();
        enum float scaleEps = 0.0001f;
        enum float rotEps = 0.0001f;
        bool scaleChanged = !hasPrevCompositeScale ||
            abs(currentScale.x - prevCompositeScale.x) > scaleEps ||
            abs(currentScale.y - prevCompositeScale.y) > scaleEps;
        bool rotChanged = !hasPrevCompositeScale ||
            abs(currentRot - prevCompositeRotation) > rotEps ||
            abs(camRot - prevCameraRotation) > rotEps;
        // 変化検知→フラグ立ての後に必ず基底を呼ぶ。
        bool changed = false;
        if (scaleChanged || rotChanged) {
            //writefln("[Composite] scale/rotation changed: %s", name);
            prevCompositeScale = currentScale;
            prevCompositeRotation = currentRot;
            prevCameraRotation = camRot;
            hasPrevCompositeScale = true;
            useMaxChildrenBounds = false;
            changed = true;
        }
        bool base = super.updateDynamicRenderStateFlags();
        return changed || (autoResizedMesh && !wasAuto) || base;
    }

    override DynamicCompositePass prepareDynamicCompositePass() {
        auto pass = super.prepareDynamicCompositePass();
        if (pass !is null) {
            pass.autoScaled = true;
        }
        return pass;
    }

    /// Build child matrix with texture offset; remove Composite transform for offscreen.
    mat4 childOffscreenMatrix(Part child) {
        vec2 offset = vec2(0, 0);
        if (isFinite(textureOffset.x) && isFinite(textureOffset.y)) {
            offset = textureOffset;
        }
        auto trans = transform();
        float sx = (trans.scale.x == 0 || !isFinite(trans.scale.x)) ? 1 : trans.scale.x;
        float sy = (trans.scale.y == 0 || !isFinite(trans.scale.y)) ? 1 : trans.scale.y;
        auto invComposite = mat4.translation(-trans.translation.x, -trans.translation.y, 0) *
            mat4.scaling(1 / sx, 1 / sy, 1);
        auto childLocal = invComposite * child.transform.matrix;
        auto translate = mat4.translation(-offset.x, -offset.y, 0);
        return translate * childLocal;
    }

    /// Core child matrix without texture offset (for bounds calculation).
    mat4 childCoreMatrix(Part child) {
        return child.transform.matrix;
    }

    private struct ScreenSpaceData {
        mat4 renderMatrix;
        mat4 modelMatrix;
    }

    private ScreenSpaceData screenSpaceData() {
        auto renderSpace = currentRenderSpace();
        auto screen = transform();
        screen.update();
        ScreenSpaceData data;
        data.renderMatrix = renderSpace.matrix;
        // textureOffset is already baked into the auto-resized mesh vertices.
        data.modelMatrix = screen.matrix;
        return data;
    }
    private mat4 offscreenRenderMatrix() {
        auto tex = textures.length > 0 ? textures[0] : null;
        if (tex is null) return mat4.identity;
        float halfW = cast(float)tex.width / 2;
        float halfH = cast(float)tex.height / 2;
        auto onscreenMatrix = currentRenderSpace().matrix;
        float onscreenY = onscreenMatrix[1][1];
        auto ortho = mat4.orthographic(-halfW, halfW, halfH, -halfH, 0, ushort.max);
        if (onscreenY != 0 && (ortho[1][1] > 0) != (onscreenY > 0)) {
            ortho = mat4.orthographic(-halfW, halfW, -halfH, halfH, 0, ushort.max);
        }
        // Offscreen Y is inverted relative to onscreen; flip here to match expected orientation.
        return mat4.scaling(1, -1, 1) * ortho;
    }

    override void fillDrawPacket(ref PartDrawPacket packet, bool isMask = false) {
        super.fillDrawPacket(packet, isMask);
        if (!packet.renderable) return;

        bool nested = hasProjectableAncestor();
        if (nested) {
            // ネスト時: superがセットしたmodelMatrixを使いつつ、ローカルスケールだけ打ち消し、回転もキャンセル。
            mat4 m = packet.modelMatrix;

            // 自身のローカルスケールを逆方向に掛けて打ち消す（親やパペット/カメラのスケールは維持）。
            auto localScale = transform().scale;
            float invLocalX = (localScale.x == 0 || !isFinite(localScale.x)) ? 1 : 1 / localScale.x;
            float invLocalY = (localScale.y == 0 || !isFinite(localScale.y)) ? 1 : 1 / localScale.y;
            m = m * mat4.identity.scaling(invLocalX, invLocalY, 1);

            // 回転部分のみリセットし、スケールと平行移動を残す。
            float sx = sqrt(m[0][0] * m[0][0] + m[1][0] * m[1][0]);
            float sy = sqrt(m[0][1] * m[0][1] + m[1][1] * m[1][1]);
            if (sx == 0) sx = 1;
            if (sy == 0) sy = 1;
            m[0][0] = sx; m[0][1] = 0;
            m[1][0] = 0;  m[1][1] = sy;
            packet.modelMatrix = m;
            return;
        }

        // 非ネスト時: 従来のComposite挙動（自スケール無視＋カメラ補正あり）。
        auto screenSpace = screenSpaceData();
        packet.modelMatrix = screenSpace.modelMatrix;
        packet.renderMatrix = screenSpace.renderMatrix;
        packet.renderScale = vec2(1, 1);
        packet.renderRotation = 0;
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
        auto frameId = currentDynamicCompositeFrame();
        if (useMaxChildrenBounds) {
            if (frameId - maxBoundsStartFrame < MaxBoundsResetInterval) {
                if (hasMaxChildrenBoundsLocal) {
                    vec4 scaled = maxChildrenBoundsLocal;
                    scaled.x *= scale.x;
                    scaled.z *= scale.x;
                    scaled.y *= scale.y;
                    scaled.w *= scale.y;
                    return scaled;
                }
                return maxChildrenBounds;
            }
            useMaxChildrenBounds = false;
            hasMaxChildrenBoundsLocal = false;
        }
        if (forceUpdate) {
            foreach (p; subParts) {
                if (p !is null) p.updateBounds();
            }
        }
        vec4 bounds;          // スケール適用後
        vec4 localBounds;     // スケール適用前（キャッシュ用）
        bool useMatrixBounds = autoResizedMesh;
        if (useMatrixBounds) {
            bool hasBounds = false;
            foreach (part; subParts) {
                auto childMatrix = childCoreMatrix(part);
                auto childBounds = localBoundsFromMatrix(part, childMatrix);
                if (!hasBounds) {
                    localBounds = childBounds;
                    hasBounds = true;
                } else {
                    localBounds.x = min(localBounds.x, childBounds.x);
                    localBounds.y = min(localBounds.y, childBounds.y);
                    localBounds.z = max(localBounds.z, childBounds.z);
                    localBounds.w = max(localBounds.w, childBounds.w);
                }
            }
            if (!hasBounds) {
                localBounds = vec4(transform.translation.x, transform.translation.y,
                    transform.translation.x, transform.translation.y);
            }
            bounds = localBounds;
            bounds.x *= scale.x;
            bounds.z *= scale.x;
            bounds.y *= scale.y;
            bounds.w *= scale.y;
        } else {
            bounds = mergeBounds(subParts.map!(p=>p.bounds), transform.translation.xyxy);
        }
        if (!useMaxChildrenBounds) {
            maxChildrenBounds = bounds;
            useMaxChildrenBounds = true;
            maxBoundsStartFrame = frameId;
            if (useMatrixBounds) {
                maxChildrenBoundsLocal = localBounds;
                hasMaxChildrenBoundsLocal = true;
            } else {
                hasMaxChildrenBoundsLocal = false;
            }
        }
        return bounds;
    }

    override bool createSimpleMesh() {
        version (NijiliveRenderProfiler) auto __prof = profileScope("Composite:createSimpleMesh");
        // キャッシュが有効な場合はそれを活用し、無効時のみ再計算してコストを下げる
        auto bounds = getChildrenBounds(!useMaxChildrenBounds);
        vec2 size = bounds.zw - bounds.xy;
        if (size.x <= 0 || size.y <= 0) {
//            writefln("[CreateSimpleMesh] Oops! %s %s = %s", name, size, bounds);
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
            // override rebuffer() で autoResizedMesh を維持するため自分の rebuffer を呼ぶ
            rebuffer(newData);
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
//        if (resizing) writefln("[CreateSimpleMesh] %s %s -> %s", name, origSize, size);
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
        if (autoResizedMesh) {
            // 現在スケールでのboundsからローカルキャッシュを復元
            auto scale = compositeAutoScale();
            maxChildrenBoundsLocal = maxChildrenBounds;
            if (scale.x != 0 && scale.y != 0) {
                maxChildrenBoundsLocal.x /= scale.x;
                maxChildrenBoundsLocal.z /= scale.x;
                maxChildrenBoundsLocal.y /= scale.y;
                maxChildrenBoundsLocal.w /= scale.y;
            }
            hasMaxChildrenBoundsLocal = true;
        } else {
            hasMaxChildrenBoundsLocal = false;
        }
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

        bool applyScreenSpace = !hasProjectableAncestor();
        mat4 renderMatrix = applyScreenSpace ? offscreenRenderMatrix() : mat4.identity;
        foreach (Part child; subParts) {
            auto childMatrix = childOffscreenMatrix(child);
            child.setOffscreenModelMatrix(childMatrix);
            if (applyScreenSpace) {
                child.setOffscreenRenderMatrix(renderMatrix);
            } else {
                child.clearOffscreenRenderMatrix();
            }
            child.drawOne();
            child.clearOffscreenModelMatrix();
            child.clearOffscreenRenderMatrix();
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
        updateDynamicRenderStateFlags();
        //writefln("[dynamicRenderBegin]dynamicRenderBegin, autoResizedMesh=%s", autoResizedMesh);
        if (!hasValidOffscreenContent) {
            textureInvalidated = true;
        }
        if (autoResizedMesh && createSimpleMesh()) {
            textureInvalidated = true;
        }
        queuedOffscreenParts.length = 0;
        if (!renderEnabled() || ctx.renderGraph is null) {
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

        bool applyScreenSpace = !hasProjectableAncestor();
        mat4 renderMatrix = applyScreenSpace ? offscreenRenderMatrix() : mat4.identity;
        foreach (Part child; subParts) {
            auto finalMatrix = childOffscreenMatrix(child);
            child.setOffscreenModelMatrix(finalMatrix);
            if (applyScreenSpace) {
                child.setOffscreenRenderMatrix(renderMatrix);
            } else {
                child.clearOffscreenRenderMatrix();
            }
            if (auto dynChild = cast(Projectable)child) {
                dynChild.renderNestedOffscreen(ctx);
            } else {
                child.enqueueRenderCommands(ctx);
            }
            queuedOffscreenParts ~= child;
        }
    }
}
