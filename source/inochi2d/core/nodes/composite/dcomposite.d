/*
    Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module inochi2d.core.nodes.dcomposite;
import inochi2d.core.nodes.common;
import inochi2d.core.nodes;
import inochi2d.fmt;
import inochi2d.core;
import inochi2d.math;
import bindbc.opengl;
import std.exception;
import std.algorithm.sorting;

private {
    GLuint cVAO;
    GLuint cBuffer;
    Shader cShader;
    Shader cShaderMask;

    GLint gopacity;
    GLint gMultColor;
    GLint gScreenColor;

    GLint mthreshold;
    GLint mopacity;
}

/**
    Composite Node
*/
@TypeId("Composite")
class DynamicComposite : Part {
private:
    bool initialized = false;

    this() { }

    void drawContents() {

        // Optimization: Nothing to be drawn, skip context switching
        if (subParts.length == 0) return;

        begin();

            mat4* tmpTransform = oneTimeTransform;
            mat4 transform = transform.matrix.inverse;
            setOneTimeTransform(&transform);
            foreach(Part child; subParts) {
                child.drawOne();
            }
            setOneTimeTransform(tmpTransform);

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
        if (Part part = cast(Part)node) {
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
    void initTarget() {
        if (textures[0] !is null)
            textures[0].dispose();

        updateBounds();
        glGenFramebuffers(1, &cfBuffer);
        
        uint width = cast(uint)(bounds.z-bounds.x);
        uint height = cast(uint)(bounds.w-bounds.y);
        ubyte[] buffer;
        buffer.length = cast(uint)(width) * cast(uint)(height) * 4;
        textures = [new Texture(ShallowTexture(buffer, width, height)), null, null];
        stencil = new Texture(ShallowTexture(buffer, width, height));

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[0].getTextureId(), 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, stencil.getTextureId(), 0);

        // go back to default fb
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        initialized = true;
    }
    void begin() {
        if (!initialized) initTarget();
        glGetIntegerv(GL_DRAW_FRAMEBUFFER, &origBuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cfBuffer);
        glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);
        glClearColor(0, 0, 0, 0);
        glClear(GL_COLOR_BUFFER_BIT);

        // Everything else is the actual texture used by the meshes at id 0
        glActiveTexture(GL_TEXTURE0);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);                
    }
    void end() {
        glBindFramebuffer(GL_FRAMEBUFFER, origBuffer);
        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glFlush();
    }

    Part[] subParts;
    
    override
    string typeId() { return "DynamicComposite(Slow)"; }

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
        this.drawSelf();
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
}