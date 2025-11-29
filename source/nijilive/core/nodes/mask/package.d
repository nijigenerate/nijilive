/*
    nijilive Mask
    previously Inochi2D Mask

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.mask;
import nijilive.core.nodes.drawable;
import nijilive.core;
import nijilive.math;
import nijilive.core.render.shared_deform_buffer :
    sharedVertexAtlasStride,
    sharedDeformAtlasStride;
import nijilive.core.render.shared_deform_buffer : sharedDeformAtlasStride;
import std.exception;
import std.algorithm.mutation : copy;

public import nijilive.core.meshdata;

import nijilive.core.render.commands : MaskDrawPacket, MaskApplyPacket, MaskDrawableKind,
    makeMaskDrawPacket;

package(nijilive) {
    void inInitMask() {
        inRegisterNodeType!Mask;
    }
}

/**
    Dynamic Mask Part
*/
@TypeId("Mask")
class Mask : Drawable {
private:
    this() { }

    /*
        RENDERING
    */
    void drawSelf() {
        version (InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            auto packet = makeMaskDrawPacket(this);
            backend.drawMaskPacket(packet);
        }
    }

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

    override
    void rebuffer(ref MeshData data) {
        super.rebuffer(data);
    }

    override
    void drawOne() {
        super.drawOne();
    }

    override
    void drawOneDirect(bool forMasking) {
        version (InDoesRender) {
            this.drawSelf();
        }
    }

    package(nijilive)
    void fillMaskDrawPacket(ref MaskDrawPacket packet) {
        mat4 modelMatrix = transform.matrix();
        if (overrideTransformMatrix !is null)
            modelMatrix = overrideTransformMatrix.matrix;
        if (oneTimeTransform !is null)
            modelMatrix = (*oneTimeTransform) * modelMatrix;
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
        debug (UnityDLLLog) {
            import std.stdio : writefln;
            debug (UnityDLLLog) writefln("[nijilive] fillMaskDrawPacket ibo=%s vCount=%s iCount=%s vOff/Stride=%s/%s deformOff/Stride=%s/%s",
                ibo, packet.vertexCount, packet.indexCount,
                packet.vertexOffset, packet.vertexAtlasStride,
                packet.deformOffset, packet.deformAtlasStride);
        }
    }

    override
    void draw() {
        if (!enabled) return;
        foreach(child; children) {
            child.draw();
        }
    }

}
