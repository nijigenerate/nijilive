/*
    nijilive Composite Node
    previously Inochi2D Composite Node

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.composite;
import nijilive.core.nodes.common;
import nijilive.core.nodes.composite.dcomposite;
import nijilive.core.nodes;
import nijilive.fmt;
import nijilive.core;
import nijilive.math;
import bindbc.opengl;
import std.exception;
import std.algorithm.sorting;
//import std.stdio;

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

package(nijilive) {
    void inInitComposite() {
        inRegisterNodeType!Composite;

        version(InDoesRender) {
            cShader = new Shader(
                import("basic/composite.vert"),
                import("basic/composite.frag")
            );

            cShader.use();
            gopacity = cShader.getUniformLocation("opacity");
            gMultColor = cShader.getUniformLocation("multColor");
            gScreenColor = cShader.getUniformLocation("screenColor");
            cShader.setUniform(cShader.getUniformLocation("albedo"), 0);
            cShader.setUniform(cShader.getUniformLocation("emissive"), 1);
            cShader.setUniform(cShader.getUniformLocation("bumpmap"), 2);

            cShaderMask = new Shader(
                import("basic/composite.vert"),
                import("basic/composite-mask.frag")
            );
            cShaderMask.use();
            mthreshold = cShader.getUniformLocation("threshold");
            mopacity = cShader.getUniformLocation("opacity");

            glGenVertexArrays(1, &cVAO);
            glGenBuffers(1, &cBuffer);

            // Clip space vertex data since we'll just be superimposing
            // Our composite framebuffer over the main framebuffer
            float[] vertexData = [
                // verts
                -1f, -1f,
                -1f, 1f,
                1f, -1f,
                1f, -1f,
                -1f, 1f,
                1f, 1f,

                // uvs
                0f, 0f,
                0f, 1f,
                1f, 0f,
                1f, 0f,
                0f, 1f,
                1f, 1f,
            ];

            glBindVertexArray(cVAO);
            glBindBuffer(GL_ARRAY_BUFFER, cBuffer);
            glBufferData(GL_ARRAY_BUFFER, float.sizeof*vertexData.length, vertexData.ptr, GL_STATIC_DRAW);
        }
    }
}

/**
    Composite Node
*/
@TypeId("Composite")
class Composite : Node {
public:
    DynamicComposite delegated = null;
private:

    this() { }

    void synchronizeDelegated() {
        if (delegated) {
            delegated.opacity = opacity;
            delegated.blendingMode = blendingMode;
            delegated.zSort = relZSort;
            if (oneTimeTransform) {
                delegated.setOneTimeTransform(oneTimeTransform);
            }
        }
    }

    void drawContents() {
        if (delegated) {
//            writefln("%s: delegate drawContents", name);
            delegated.drawContents();
            return;
        }

        // Optimization: Nothing to be drawn, skip context switching
        if (subParts.length == 0) return;

        inBeginComposite();

            foreach(Part child; subParts) {
                child.drawOne();
            }

        inEndComposite();
    }

    /*
        RENDERING
    */
    void drawSelf() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate drawSelf", name);
            delegated.drawSelf();
            return;
        } else {
//            writefln("%s: drawSelf", name);
        }
        if (subParts.length == 0) return;
        glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
        glBindVertexArray(cVAO);

        cShader.use();
        cShader.setUniform(gopacity, clamp(offsetOpacity * opacity, 0, 1));
        incCompositePrepareRender();
        
        vec3 clampedColor = tint;
        if (!offsetTint.x.isNaN) clampedColor.x = clamp(tint.x*offsetTint.x, 0, 1);
        if (!offsetTint.y.isNaN) clampedColor.y = clamp(tint.y*offsetTint.y, 0, 1);
        if (!offsetTint.z.isNaN) clampedColor.z = clamp(tint.z*offsetTint.z, 0, 1);
        cShader.setUniform(gMultColor, clampedColor);

        clampedColor = screenTint;
        if (!offsetScreenTint.x.isNaN) clampedColor.x = clamp(screenTint.x+offsetScreenTint.x, 0, 1);
        if (!offsetScreenTint.y.isNaN) clampedColor.y = clamp(screenTint.y+offsetScreenTint.y, 0, 1);
        if (!offsetScreenTint.z.isNaN) clampedColor.z = clamp(screenTint.z+offsetScreenTint.z, 0, 1);
        cShader.setUniform(gScreenColor, clampedColor);
        inSetBlendMode(blendingMode, true);

        // Enable points array
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, cBuffer);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, cast(void*)(12*float.sizeof));

        // Bind the texture
        glDrawArrays(GL_TRIANGLES, 0, 6);
    }

    void selfSort() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: selfSort", name);
            delegated.selfSort();
            return;
        }

        import std.math : cmp;
        sort!((a, b) => cmp(
            a.zSort, 
            b.zSort) > 0)(subParts);
    }

    void scanPartsRecurse(ref Node node) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate scanPartsRecurse", name);
            delegated.scanPartsRecurse(node);
            return;
        }

        // Don't need to scan null nodes
        if (node is null) return;

        // Do the main check
        if (Part part = cast(Part)node) {
            subParts ~= part;
            part.ignorePuppet = false;
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
    Part[] subParts;
    
    void renderMask() {
        inBeginComposite();

            // Enable writing to stencil buffer and disable writing to color buffer
            glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
            glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
            glStencilFunc(GL_ALWAYS, 1, 0xFF);
            glStencilMask(0xFF);

            foreach(Part child; subParts) {
                child.drawOneDirect(true);
            }

            // Disable writing to stencil buffer and enable writing to color buffer
            glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        inEndComposite();


        glBindVertexArray(cVAO);
        cShaderMask.use();
        cShaderMask.setUniform(mopacity, opacity);
        cShaderMask.setUniform(mthreshold, threshold);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        // Enable points array
        glEnableVertexAttribArray(0);
        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, cBuffer);
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, cast(void*)(12*float.sizeof));

        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, inGetCompositeImage());
        glDrawArrays(GL_TRIANGLES, 0, 6);
    }

    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive=true) {
        super.serializeSelfImpl(serializer, recursive);

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

        if (masks.length > 0) {
            serializer.putKey("masks");
            auto state = serializer.arrayBegin();
                foreach(m; masks) {
                    serializer.elemBegin;
                    serializer.serializeValue(m);
                }
            serializer.arrayEnd(state);

        }
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {

        // Older models may not have these tags
        if (!data["opacity"].isEmpty) data["opacity"].deserializeValue(this.opacity);
        if (!data["mask_threshold"].isEmpty) data["mask_threshold"].deserializeValue(this.threshold);
        if (!data["tint"].isEmpty) deserialize(this.tint, data["tint"]);
        if (!data["screenTint"].isEmpty) deserialize(this.screenTint, data["screenTint"]);
        if (!data["blend_mode"].isEmpty) data["blend_mode"].deserializeValue(this.blendingMode);
        if (!data["masks"].isEmpty) data["masks"].deserializeValue(this.masks);
        if (!data["propagate_meshgroup"].isEmpty)
            data["propagate_meshgroup"].deserializeValue(propagateMeshGroup);
        else // falls back to legacy default
            propagateMeshGroup = false;

        return super.deserializeFromFghj(data);
    }

    //
    //      PARAMETER OFFSETS
    //
    float offsetOpacity = 1;
    vec3 offsetTint = vec3(0);
    vec3 offsetScreenTint = vec3(0);

    override
    string typeId() { return "Composite"; }

    // TODO: Cache this
    size_t maskCount() {
        size_t c;
        foreach(m; masks) if (m.mode == MaskingMode.Mask) c++;
        return c;
    }

    size_t dodgeCount() {
        size_t c;
        foreach(m; masks) if (m.mode == MaskingMode.DodgeMask) c++;
        return c;
    }

    override
    void preProcess() {
        if (delegated) {
            delegated.preProcess();
        }
        if (!propagateMeshGroup)
            Node.preProcess();
    }

    override
    void postProcess(int id = 0) {
        if (delegated) {
            delegated.postProcess(id);
        }
        if (!propagateMeshGroup)
            Node.postProcess(id);
    }

public:
    bool propagateMeshGroup = true;

    /**
        The blending mode
    */
    BlendMode blendingMode;

    /**
        The opacity of the composite
    */
    float opacity = 1;

    /**
        The threshold for rendering masks
    */
    float threshold = 0.5;

    /**
        Multiplicative tint color
    */
    vec3 tint = vec3(1, 1, 1);

    /**
        Screen tint color
    */
    vec3 screenTint = vec3(0, 0, 0);

    /**
        List of masks to apply
    */
    MaskBinding[] masks;


    /**
        Constructs a new mask
    */
    this(Node parent = null) {
        this(inCreateUUID(), parent);
    }

    /**
        Constructs a new composite
    */
    this(uint uuid, Node parent = null) {
        super(uuid, parent);
    }

    override
    bool hasParam(string key) {
        if (super.hasParam(key)) return true;

        switch(key) {
            case "opacity":
            case "tint.r":
            case "tint.g":
            case "tint.b":
            case "screenTint.r":
            case "screenTint.g":
            case "screenTint.b":
                return true;
            default:
                return false;
        }
    }

    override
    float getDefaultValue(string key) {
        // Skip our list of our parent already handled it
        float def = super.getDefaultValue(key);
        if (!isNaN(def)) return def;

        switch(key) {
            case "opacity":
            case "tint.r":
            case "tint.g":
            case "tint.b":
                return 1;
            case "screenTint.r":
            case "screenTint.g":
            case "screenTint.b":
                return 0;
            default: return float();
        }
    }

    override
    bool setValue(string key, float value) {
        
        // Skip our list of our parent already handled it
        if (super.setValue(key, value)) return true;

        switch(key) {
            case "opacity":
                offsetOpacity *= value;
                return true;
            case "tint.r":
                offsetTint.x *= value;
                return true;
            case "tint.g":
                offsetTint.y *= value;
                return true;
            case "tint.b":
                offsetTint.z *= value;
                return true;
            case "screenTint.r":
                offsetScreenTint.x += value;
                return true;
            case "screenTint.g":
                offsetScreenTint.y += value;
                return true;
            case "screenTint.b":
                offsetScreenTint.z += value;
                return true;
            default: return false;
        }
    }
    
    override
    float getValue(string key) {
        switch(key) {
            case "opacity":         return offsetOpacity;
            case "tint.r":          return offsetTint.x;
            case "tint.g":          return offsetTint.y;
            case "tint.b":          return offsetTint.z;
            case "screenTint.r":    return offsetScreenTint.x;
            case "screenTint.g":    return offsetScreenTint.y;
            case "screenTint.b":    return offsetScreenTint.z;
            default:                return super.getValue(key);
        }
    }

    bool isMaskedBy(Drawable drawable) {
        foreach(mask; masks) {
            if (mask.maskSrc.uuid == drawable.uuid) return true;
        }
        return false;
    }

    ptrdiff_t getMaskIdx(Drawable drawable) {
        if (drawable is null) return -1;
        foreach(i, ref mask; masks) {
            if (mask.maskSrc.uuid == drawable.uuid) return i;
        }
        return -1;
    }

    ptrdiff_t getMaskIdx(uint uuid) {
        foreach(i, ref mask; masks) {
            if (mask.maskSrc.uuid == uuid) return i;
        }
        return -1;
    }

    override
    void beginUpdate() {
        if (delegated) {
            delegated.beginUpdate();
        }
        offsetOpacity = 1;
        offsetTint = vec3(1, 1, 1);
        offsetScreenTint = vec3(0, 0, 0);
        super.beginUpdate();
    }

    override
    void update() {
        super.update();
        if (delegated) {
            delegated.update();
        }
    }

    override
    void drawOne() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: drawOne", name);
            delegated.drawOne();
            return;
        } else {
//            writefln("%s: drawOne", name);
        }
        if (!enabled) return;
        
        this.selfSort();
        this.drawContents();

        size_t cMasks = maskCount;

        if (masks.length > 0) {
            inBeginMask(cMasks > 0);

            foreach(ref mask; masks) {
                mask.maskSrc.renderMask(mask.mode == MaskingMode.DodgeMask);
            }

            inBeginMaskContent();

            // We are the content
            this.drawSelf();

            inEndMask();
            return;
        }

        // No masks, draw normally
        super.drawOne();
        this.drawSelf();
    }

    override
    void draw() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: draw", name);
            delegated.draw();
            return;
        } else {
//            writefln("%s: draw", name);
        }
        if (!enabled) return;
        this.drawOne();
    }

    override
    void finalize() {
        super.finalize();
        
        MaskBinding[] validMasks;
        foreach(i; 0..masks.length) {
            if (Drawable nMask = puppet.find!Drawable(masks[i].maskSrcUUID)) {
                masks[i].maskSrc = nMask;
                validMasks ~= masks[i];
            }
        }

        // Remove invalid masks
        masks = validMasks;
    }

    /**
        Scans for parts to render
    */
    void scanParts() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: scanParts", name);
            delegated.scanSubParts(children);
            return;
        }
        subParts.length = 0;
        if (children.length > 0) {
            scanPartsRecurse(children[0].parent);
        }
    }

    override
    bool setupChild(Node node) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: setupChild", name);
            delegated.setupChild(node);
        }
        return mustPropagate;
    }

    override
    bool releaseChild(Node node) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: releaseChild", name);
            delegated.releaseChild(node);
        }
        return mustPropagate;
    }

    override
    void setupSelf() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: setupSelf", name);
            delegated.setupSelf();
        }
    }

    override
    void normalizeUV(MeshData* data) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: normalizeUV", name);
            delegated.normalizeUV(data);
        }
    }

    override
    void notifyChange(Node target, NotifyReason reason = NotifyReason.Transformed) {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: delegate: notifyChange, %s", name, target.name);
            delegated.notifyChange(target, reason);
        } else {
            super.notifyChange(target, reason);
        }
    }

    override
    void transformChanged() {
        super.transformChanged();
        if (delegated) {
            delegated.recalculateTransform = true;
        }
    }

    override
    void centralize() {
        if (delegated) {
            synchronizeDelegated();
//            writefln("%s: centralize", name);
            delegated.centralize();
            return;
        }
        super.centralize();
        vec4 bounds;
        vec4[] childTranslations;
        if (children.length > 0) {
            bounds = children[0].getCombinedBounds();
            foreach (child; children) {
                auto cbounds = child.getCombinedBounds();
                bounds.x = min(bounds.x, cbounds.x);
                bounds.y = min(bounds.y, cbounds.y);
                bounds.z = max(bounds.z, cbounds.z);
                bounds.w = max(bounds.w, cbounds.w);
                childTranslations ~= child.transform.matrix() * vec4(0, 0, 0, 1);
            }
        } else {
            bounds = transform.translation.xyxy;
        }
        vec2 center = (bounds.xy + bounds.zw) / 2;
        if (parent !is null) {
            center = (parent.transform.matrix.inverse * vec4(center, 0, 1)).xy;
        }
        auto diff = center - localTransform.translation.xy;
        localTransform.translation.x = center.x;
        localTransform.translation.y = center.y;
        clearCache();
        foreach (i, child; children) {
            child.localTransform.translation = (transform.matrix.inverse * childTranslations[i]).xyz;
            child.transformChanged();
        }

    }

    void setDelegation(DynamicComposite delegated) {
        if (this.delegated && this.delegated != delegated) {
            this.delegated.releaseSelf();
            this.delegated.children_ref.length = 0;
            this.delegated.parent = null;
        }
        if (this.delegated != delegated) {
            this.delegated = delegated;
            if (this.delegated)
                this.delegated.setupSelf();
        }
    }

    override
    void flushNotifyChange() {
        if (delegated) {
            delegated.flushNotifyChange();
        }
        super.flushNotifyChange();
    }

    override
    bool mustPropagate() { return propagateMeshGroup; }
}