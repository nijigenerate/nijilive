/*
    Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module inochi2d.core.nodes.composite.dcomposite;
import inochi2d.core.nodes.common;
import inochi2d.core.nodes;
import inochi2d.fmt;
import inochi2d.core;
import inochi2d.math;
import bindbc.opengl;
import std.exception;
import std.algorithm.sorting;

package(inochi2d) {
    void inInitDComposite() {
        inRegisterNodeType!DynamicComposite;
    }
}

/**
    Composite Node
*/
@TypeId("DynamicComposite")
class DynamicComposite : Part {
private:
    bool initialized = false;

    this() { }

    void drawContents() {
        // Optimization: Nothing to be drawn, skip context switching
        if (subParts.length == 0) return;

        begin();
/*
            mat4* tmpTransform = oneTimeTransform;
            mat4 transform = transform.matrix.inverse;
            setOneTimeTransform(&transform);
            foreach(Part child; subParts) {
                child.drawOne();
            }
            setOneTimeTransform(tmpTransform);
*/
        end();
    }


    void selfSort() {
        import std.math : cmp;
        sort!((a, b) => cmp(
            a.zSort, 
            b.zSort) > 0)(subParts);
    }

    void scanPartsRecurse(ref Node node) {

        // Don't need to scan null nodes
        if (node is null) return;

        // Do the main check
        DynamicComposite dcomposite = cast(DynamicComposite)node;
        Part part = cast(Part)node;
        if (dcomposite is null && part !is null) {
            subParts ~= part;
            foreach(child; part.children) {
                scanPartsRecurse(child);
            }
            
        } else {

            // Non-part nodes just need to be recursed through,
            // they don't draw anything.
            foreach(child; node.children) {
                scanPartsRecurse(child);
            }
        }
    }

protected:
    GLuint cfBuffer;
    GLint origBuffer;
    Texture stencil;
    GLint[4] origViewport;
    void initTarget() {
        if (textures[0] !is null)
            textures[0].dispose();

        updateBounds();
        glGenFramebuffers(1, &cfBuffer);
        
        uint width = cast(uint)(bounds.z-bounds.x);
        uint height = cast(uint)(bounds.w-bounds.y);
        ubyte[] buffer;
        buffer.length = cast(uint)(width) * cast(uint)(height) * 4;
        for (int i = 0; i < buffer.length; i++) buffer[i] = 255;
        textures = [new Texture(ShallowTexture(buffer, width, height)), null, null];
//        stencil = new Texture(ShallowTexture(buffer, width, height));

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[0].getTextureId(), 0);
//        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, stencil.getTextureId(), 0);

        // go back to default fb
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        initialized = true;
    }
    void begin() {
        if (!initialized) initTarget();
        /*
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &origBuffer);
        glGetIntegerv(GL_VIEWPORT, cast(GLint*)origViewport);
        import std.stdio;
        writefln("framebuffer to %x, texture=%x(%dx%d)", cfBuffer, textures[0].getTextureId(), textures[0].width, textures[0].height);
        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glViewport(0, 0, textures[0].width, textures[0].height);
        glClearColor(1, 1, 1, 1);
        glClear(GL_COLOR_BUFFER_BIT);

        // Everything else is the actual texture used by the meshes at id 0
        glActiveTexture(GL_TEXTURE0);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        */
    }
    void end() {
        /*
        import std.stdio;
        writefln("framebuffer to %x", origBuffer);
        glBindFramebuffer(GL_FRAMEBUFFER, origBuffer);
        glViewport(origViewport[0], origViewport[1], origViewport[2], origViewport[3]);
        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glFlush();
        */
    }

    Part[] subParts;
    
    override
    string typeId() { return "DynamicComposite"; }

    /**
        Allows serializing self data (with pretty serializer)
    */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true) {
        import std.stdio;
        writefln("Serialize %s", name);
        super.serializeSelfImpl(serializer, recursive);
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        import std.stdio;
        auto result = super.deserializeFromFghj(data);
        writefln("Deserialize %s", name);
        return result;
    }

public:

    /**
        Constructs a new mask
    */
    this(Node parent = null) {
        super(parent);
    }

    /**
        Constructs a new composite
    */
    this(MeshData data, uint uuid, Node parent = null) {
        super(data, uuid, parent);
    }

    override
    void drawOne() {
        if (!enabled) return;
        
        this.selfSort();
        this.drawContents();

        // No masks, draw normally
        super.drawOne();
    }

    override
    void draw() {
        if (!enabled) return;
        this.drawOne();
    }


    /**
        Scans for parts to render
    */
    void scanParts() {
        subParts.length = 0;
        if (children.length > 0) {
            scanPartsRecurse(children[0].parent);
        }
    }

    override
    void clearCache() {
        initialized = false;
    }
}