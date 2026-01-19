/*
    nijilive Mask
    previously Inochi2D Mask

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.mask;
import nijilive.core.nodes.part;
import nijilive.core;
import nijilive.math;
import nijilive.core.render.shared_deform_buffer :
    sharedVertexAtlasStride,
    sharedDeformAtlasStride,
    sharedUvAtlasStride;
import std.exception;
import std.algorithm.mutation : copy;

public import nijilive.core.meshdata;

import nijilive.core.render.commands : MaskDrawPacket, MaskApplyPacket, MaskDrawableKind,
    makeMaskDrawPacket, PartDrawPacket;
import nijilive.core.render.scheduler : RenderContext;
import nijilive.fmt.serialize;

package(nijilive) {
    void inInitMask() {
        inRegisterNodeType!Mask;
    }
}

/**
    Dynamic Mask Part
*/
@TypeId("Mask")
class Mask : Part {
private:
    this() { }

    /*
        RENDERING
    */
    void drawSelf() { }

protected:

    override
    string typeId() { return "Mask"; }

public:
    /**
        Constructs a new mask
    */
    this(Node parent = null) {
        MeshData empty;
        this(empty, inCreateUUID(), parent);
    }

    /**
        Constructs a new mask
    */
    this(MeshData data, Node parent = null) {
        this(data, inCreateUUID(), parent);
    }

    /**
        Constructs a new mask
    */
    this(MeshData data, uint uuid, Node parent = null) {
        super(data, uuid, parent);
    }

    // Maskは画面に描かない：通常描画パケットは非レンダリングにする
    override
    void fillDrawPacket(ref PartDrawPacket packet, bool isMask = false) {
        super.fillDrawPacket(packet, isMask);
        packet.renderable = false;
        packet.textures.length = 0;
    }

    // Serialize/Deserialize is kept identical to legacy (Drawable) behavior.
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        Drawable.serializeSelfImpl(serializer, recursive, flags);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        return Drawable.deserializeFromFghj(data);
    }
    
    override
    void renderMask(bool dodge = false) {
        version (InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            MaskApplyPacket packet;
            packet.kind = MaskDrawableKind.Mask;
            packet.isDodge = dodge;
            packet.maskPacket = makeMaskDrawPacket(this);
            backend.applyMask(packet);
        }
    }

    // 自分自身は描画しない: renderタスクは登録しない（他タスクはNodeに任せる）
    package(nijilive)
    void fillMaskDrawPacket(ref MaskDrawPacket packet) {
        mat4 modelMatrix = immediateModelMatrix();
        packet.modelMatrix = modelMatrix;

        if (hasOffscreenModelMatrixActive()) {
            if (hasOffscreenRenderMatrixActive()) {
                packet.mvp = offscreenRenderMatrixValue() * modelMatrix;
            } else {
                packet.mvp = modelMatrix;
            }
        } else {
            auto renderSpace = currentRenderSpace();
            packet.mvp = renderSpace.matrix * modelMatrix;
        }

        packet.origin = data.origin;
        packet.vertexOffset = vertexSliceOffset;
        packet.vertexAtlasStride = sharedVertexAtlasStride();
        packet.deformOffset = deformSliceOffset;
        packet.deformAtlasStride = sharedDeformAtlasStride();
        packet.indexBuffer = ibo;
        packet.indexCount = cast(uint)data.indices.length;
        packet.vertexCount = cast(uint)data.vertices.length;
    }

    override
    protected void runRenderTask(ref RenderContext ctx) {
        // Masks never render their own color; they are only used as mask sources.
    }

    override
    void draw() {
        if (!enabled) return;
        foreach(child; children) {
            child.draw();
        }
    }

}
