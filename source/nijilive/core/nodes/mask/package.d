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
import std.exception;
import std.algorithm.mutation : copy;

public import nijilive.core.meshdata;

import nijilive.core.render.commands : MaskDrawPacket, MaskApplyPacket, MaskDrawableKind,
    makeMaskDrawPacket;
version (InDoesRender) {
    import nijilive.core.render.backends.opengl.mask_resources : initMaskBackendResources;
}

package(nijilive) {
    void inInitMask() {
        inRegisterNodeType!Mask;
        version(InDoesRender) {
            initMaskBackendResources();
        }
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
        packet.mask = this;

        mat4 modelMatrix = transform.matrix();
        if (overrideTransformMatrix !is null)
            modelMatrix = overrideTransformMatrix.matrix;
        if (oneTimeTransform !is null)
            modelMatrix = (*oneTimeTransform) * modelMatrix;
        packet.modelMatrix = modelMatrix;

        mat4 puppetMatrix = puppet ? puppet.transform.matrix : mat4.identity;
        packet.mvp = inGetCamera().matrix * puppetMatrix * modelMatrix;

        packet.origin = data.origin;
        packet.vertexBuffer = vbo;
        packet.deformBuffer = dbo;
        packet.indexBuffer = ibo;
        packet.indexCount = cast(uint)data.indices.length;
    }

    override
    void draw() {
        if (!enabled) return;
        foreach(child; children) {
            child.draw();
        }
    }

}
