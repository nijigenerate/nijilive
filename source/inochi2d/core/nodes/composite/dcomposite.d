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
import inochi2d;
import bindbc.opengl;
import std.exception;
import std.algorithm.sorting;
import std.stdio;

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

        if (beginComposite()) {
            mat4* origTransform = oneTimeTransform;
            mat4 tmpTransform = transform.matrix.inverse;
//            writefln("transform=%s", transform);
//            writefln("%10.3f: draw sub-parts: %s", currentTime(), name);
            setOneTimeTransform(&tmpTransform);
            foreach(Part child; subParts) {
                child.drawOne();
            }
            setOneTimeTransform(origTransform);
            endComposite();
            textures[0].genMipmap();
        }
        textureInvalidated = false;
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
    bool textureInvalidated = false;
    bool initTarget() {
        if (textures[0] !is null) {
            textures[0].dispose();
            textures[0] = null;
        }

        updateBounds();
        
        uint width = cast(uint)(bounds.z-bounds.x);
        uint height = cast(uint)(bounds.w-bounds.y);
        if (width == 0 || height == 0) return false;

        glGenFramebuffers(1, &cfBuffer);
        ubyte[] buffer;
        buffer.length = cast(uint)(width) * cast(uint)(height) * 4;
//        for (int i = 0; i < buffer.length; i++) buffer[i] = 255;
        textures = [new Texture(ShallowTexture(buffer, width, height)), null, null];
//        stencil = new Texture(ShallowTexture(buffer, width, height));

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, textures[0].getTextureId(), 0);
//        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, stencil.getTextureId(), 0);

        // go back to default fb
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        initialized = true;
        textureInvalidated = true;
        return true;
    }
    bool beginComposite() {
        if (!initialized) 
            if (!initTarget()) return false;
        if (textureInvalidated) {
            glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &origBuffer);
            glGetIntegerv(GL_VIEWPORT, cast(GLint*)origViewport);
    //        import std.stdio;
    //        writefln("framebuffer to %x, texture=%x(%dx%d)", cfBuffer, textures[0].getTextureId(), textures[0].width, textures[0].height);
            glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
            inPushViewport(textures[0].width, textures[0].height);
            inGetCamera.scale.y *= -1;
            glViewport(0, 0, textures[0].width, textures[0].height);
            glClearColor(0, 0, 0, 0);
            glClear(GL_COLOR_BUFFER_BIT);

            // Everything else is the actual texture used by the meshes at id 0
            glActiveTexture(GL_TEXTURE0);
            glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
        }
        return textureInvalidated;
    }
    bool endComposite() {
//        import std.stdio;
//        writefln("framebuffer to %x", origBuffer);
        if (textureInvalidated) {
            glBindFramebuffer(GL_FRAMEBUFFER, origBuffer);
            inPopViewport();
            glViewport(origViewport[0], origViewport[1], origViewport[2], origViewport[3]);
            glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
            glFlush();
            return true;
        } else {
            return false;
        }
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
    void beginUpdate() {

        super.beginUpdate();
    }

    override
    void drawOne() {
        if (!enabled) return;
        
        this.selfSort();
        this.drawContents();

        // No masks, draw normally
        drawSelf();
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

    override
    void normalizeUV(MeshData* data) {
        import std.algorithm: map;
        import std.algorithm: minElement, maxElement;
        float minX = data.uvs.map!(a => a.x).minElement;
        float maxX = data.uvs.map!(a => a.x).maxElement;
        float minY = data.uvs.map!(a => a.y).minElement;
        float maxY = data.uvs.map!(a => a.y).maxElement;
        float width = maxX - minX;
        float height = maxY - minY;
        float centerX = (minX + maxX) / 2 / width;
        float centerY = (minY + maxY) / 2 / height;
        foreach(i; 0..data.uvs.length) {
            // Texture 0 is always albedo texture
            auto tex = textures[0];
            data.uvs[i].x /= width;
            data.uvs[i].y /= height;
            data.uvs[i] += vec2(0.5, 0.5);
        }
    }

    override
    void notifyChange(Node target) {
        if (target != this) {
            textureInvalidated = true;
        }
        super.notifyChange(target);
    }

}