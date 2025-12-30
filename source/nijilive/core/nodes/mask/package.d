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
import nijilive.core.render.command_emitter : RenderCommandEmitter;
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

    // 自分自身は描画しない: renderタスクを無効化する
    override
    protected void runRenderTask(ref RenderContext ctx) {
        return;
    }

    package(nijilive)
    void fillMaskDrawPacket(ref MaskDrawPacket packet) {
        mat4 modelMatrix = immediateModelMatrix();
        packet.modelMatrix = modelMatrix;

        mat4 puppetMatrix = puppet ? puppet.transform.matrix : mat4.identity;
        packet.mvp = inGetCamera().matrix * puppetMatrix * modelMatrix;

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
    void draw() {
        if (!enabled) return;
        foreach(child; children) {
            child.draw();
        }
    }

}
