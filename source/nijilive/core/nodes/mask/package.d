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
import bindbc.opengl;
import std.exception;
import std.algorithm.mutation : copy;

public import nijilive.core.meshdata;


package(nijilive) {
    private {
        Shader maskShader;
    }

    /* GLSL Uniforms (Normal) */
    GLint mvp;
    GLint offset;

    void inInitMask() {
        inRegisterNodeType!Mask;
        version(InDoesRender) {
            maskShader = new Shader(import("mask.vert"), import("mask.frag"));
            offset = maskShader.getUniformLocation("offset");
            mvp = maskShader.getUniformLocation("mvp");
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

        // Bind the vertex array
        incDrawableBindVAO();
        // Calculate matrix
        mat4 matrix = transform.matrix();
        if (overrideTransformMatrix !is null)
            matrix = overrideTransformMatrix.matrix;
        if (oneTimeTransform !is null)
            matrix = (*oneTimeTransform) * matrix;
        
        maskShader.use();
        maskShader.setUniform(offset, data.origin);
//        maskShader.setUniform(mvp, inGetCamera().matrix * transform.matrix());
        maskShader.setUniform(mvp, inGetCamera().matrix * puppet.transform.matrix * matrix);
        
        // Enable points array
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, vbo);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);
        glEnableVertexAttribArray(1); // deforms
        glBindBuffer(GL_ARRAY_BUFFER, dbo);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

        // Bind index buffer
        this.bindIndex();

        // Disable the vertex attribs after use
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);
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
        
        // Enable writing to stencil buffer and disable writing to color buffer
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
        glStencilFunc(GL_ALWAYS, dodge ? 0 : 1, 0xFF);
        glStencilMask(0xFF);

        // Draw ourselves to the stencil buffer
        drawSelf();

        // Disable writing to stencil buffer and enable writing to color buffer
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
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
        this.drawSelf();
    }

    override
    void draw() {
        if (!enabled) return;
        foreach(child; children) {
            child.draw();
        }
    }

}
