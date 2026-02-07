/*
    nijilive Part
    previously Inochi2D Part

    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.nodes.part;

import nijilive.core.render.scheduler;
import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.commands : PartDrawPacket, makePartDrawPacket,
    tryMakeMaskApplyPacket, MaskApplyPacket, MaskDrawableKind;
import nijilive.integration;
import nijilive.fmt;
import nijilive.core.nodes.drawable;
import nijilive.core;
import nijilive.math;
import nijilive.core.render.shared_deform_buffer;
version(InDoesRender) import nijilive.core.runtime_state : currentRenderBackend;
import nijilive.core.runtime_state : inGetCamera;
import std.exception;
import std.algorithm.mutation : copy;
public import nijilive.core.nodes.common;
import std.math : isNaN, isFinite;
import std.algorithm.comparison : min, max;

public import nijilive.core.meshdata;
public import nijilive.core.render.immediate : inDrawTextureAtPart, inDrawTextureAtPosition,
    inDrawTextureAtRect;

package(nijilive) {
    void inInitPart() {
        inRegisterNodeType!Part;
    }
}


/**
    Creates a simple part that is sized after the texture given
    part is created based on file path given.
    Supported file types are: png, tga and jpeg

    This is unoptimal for normal use and should only be used
    for real-time use when you want to add/remove parts on the fly
*/
Part inCreateSimplePart(string file, Node parent = null) {
    return inCreateSimplePart(ShallowTexture(file), parent, file);
}

/**
    Creates a simple part that is sized after the texture given

    This is unoptimal for normal use and should only be used
    for real-time use when you want to add/remove parts on the fly
*/
Part inCreateSimplePart(ShallowTexture texture, Node parent = null, string name = "New Part") {
	return inCreateSimplePart(new Texture(texture), parent, name);
}

/**
    Creates a simple part that is sized after the texture given

    This is unoptimal for normal use and should only be used
    for real-time use when you want to add/remove parts on the fly
*/
Part inCreateSimplePart(Texture tex, Node parent = null, string name = "New Part") {
	MeshData data;
    data.vertices = Vec2Array([
        vec2(-(tex.width/2), -(tex.height/2)),
        vec2(-(tex.width/2), tex.height/2),
        vec2(tex.width/2, -(tex.height/2)),
        vec2(tex.width/2, tex.height/2),
    ]);
    data.uvs = Vec2Array([
        vec2(0, 0),
        vec2(0, 1),
        vec2(1, 0),
        vec2(1, 1),
    ]);
    data.indices = [
        0, 1, 2,
        2, 1, 3
    ];
	Part p = new Part(data, [tex], parent);
	p.name = name;
    return p;
}

enum NO_TEXTURE = uint.max;

enum TextureUsage : size_t {
    Albedo,
    Emissive,
    Bumpmap,
    COUNT
}

/// Combined render-space parameters derived from camera and puppet transforms.
package(nijilive) struct RenderSpace {
    mat4 matrix;
    vec2 scale;
    float rotation;
}

/**
    Dynamic Mesh Part
*/
@TypeId("Part")
class Part : Drawable {
private:    
    void initPartTasks() {
        requireRenderTask();
    }

    void updateUVs() {
        sharedUvResize(data.uvs, data.uvs.length);
        sharedUvMarkDirty();
    }

protected:
    /*
        RENDERING
    */
    void drawSelf(bool isMask = false)() {
        version (InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            auto packet = makePartDrawPacket(this, isMask);
            backend.drawPartPacket(packet);
        }
    }

    /**
        Constructs a new part with no texture definition.
    */
    this(MeshData data, uint uuid, Node parent = null) {
        super(data, uuid, parent);
        initPartTasks();

        this.updateUVs();
    }

    override
    string typeId() { return "Part"; }

    /**
        Allows serializing self data (with pretty serializer)
    */
    override
    void serializeSelfImpl(ref InochiSerializer serializer, bool recursive = true, SerializeNodeFlags flags=SerializeNodeFlags.All) {
        super.serializeSelfImpl(serializer, recursive, flags);
        version (InDoesRender) {
            if ((flags & SerializeNodeFlags.Links) && inIsINPMode()) {
                serializer.putKey("textures");
                auto state = serializer.listBegin();
                    foreach(ref texture; textures) {
                        if (texture) {
                            ptrdiff_t index = puppet.getTextureSlotIndexFor(texture);
                            if (index >= 0) {
                                serializer.elemBegin;
                                serializer.putValue(cast(size_t)index);
                            } else {
                                serializer.elemBegin;
                                serializer.putValue(cast(size_t)NO_TEXTURE);
                            }
                        } else {
                            serializer.elemBegin;
                            serializer.putValue(cast(size_t)NO_TEXTURE);
                        }
                    }
                serializer.listEnd(state);
            }
        }

        if (flags & SerializeNodeFlags.State) {
            serializer.putKey("blend_mode");
            serializer.serializeValue(blendingMode);
            
            serializer.putKey("tint");
            tint.serialize(serializer);

            serializer.putKey("screenTint");
            screenTint.serialize(serializer);

            serializer.putKey("emissionStrength");
            serializer.serializeValue(emissionStrength);
        }

        if ((flags & SerializeNodeFlags.Links) && masks.length > 0) {
            serializer.putKey("masks");
            auto state = serializer.listBegin();
                foreach(m; masks) {
                    serializer.elemBegin;
                    serializer.serializeValue(m);
                }
            serializer.listEnd(state);
        }

        if (flags & SerializeNodeFlags.State) {
            serializer.putKey("mask_threshold");
            serializer.putValue(maskAlphaThreshold);

            serializer.putKey("opacity");
            serializer.putValue(opacity);
        }
    }

    override
    SerdeException deserializeFromFghj(Fghj data) {
        super.deserializeFromFghj(data);

    
        version(InRenderless) {
            if (inIsINPMode()) {
                foreach(texElement; data["textures"].byElement) {
                    uint textureId;
                    texElement.deserializeValue(textureId);
                    if (textureId == NO_TEXTURE) continue;

                    textureIds ~= textureId;
                }
            } else {
                assert(0, "Raw nijilive JSON not supported in renderless mode");
            }
            
            // Do nothing in this instance
        } else {
            if (inIsINPMode()) {

                size_t i;
                foreach(texElement; data["textures"].byElement) {
                    uint textureId;
                    texElement.deserializeValue(textureId);

                    // uint max = no texture set
                    if (textureId == NO_TEXTURE) continue;

                    textureIds ~= textureId;
                    this.textures[i++] = inGetTextureFromId(textureId);
                }
            } else {
                enforce(0, "Loading from texture path is deprecated.");
            }
        }

        data["opacity"].deserializeValue(this.opacity);
        data["mask_threshold"].deserializeValue(this.maskAlphaThreshold);

        // Older models may not have tint
        if (!data["tint"].isEmpty) deserialize(tint, data["tint"]);

        // Older models may not have screen tint
        if (!data["screenTint"].isEmpty) deserialize(screenTint, data["screenTint"]);

        // Older models may not have emission
        if (!data["emissionStrength"].isEmpty) deserialize(tint, data["emissionStrength"]);

        // Older models may not have blend mode
        if (!data["blend_mode"].isEmpty) data["blend_mode"].deserializeValue(this.blendingMode);

        if (!data["masked_by"].isEmpty) {
            MaskingMode mode;
            data["mask_mode"].deserializeValue(mode);

            // Go every masked part
            foreach(imask; data["masked_by"].byElement) {
                uint uuid;
                if (auto exc = imask.deserializeValue(uuid)) return exc;
                this.masks ~= MaskBinding(uuid, mode, null);
            }
        }

        if (!data["masks"].isEmpty) {
            data["masks"].deserializeValue(this.masks);
        }

        // Update indices and vertices
        this.updateUVs();
        return null;
    }

    override
    void serializePartial(ref InochiSerializer serializer, bool recursive=true) {
        super.serializePartial(serializer, recursive);
        serializer.putKey("textureUUIDs");
        auto state = serializer.listBegin();
            foreach(ref texture; textures) {
                uint uuid;
                if (texture !is null) {
                    uuid = texture.getRuntimeUUID();                                    
                } else {
                    uuid = InInvalidUUID;
                }
                serializer.elemBegin;
                serializer.putValue(cast(size_t)uuid);
            }
        serializer.listEnd(state);
    }

    //
    //      PARAMETER OFFSETS
    //
    float offsetMaskThreshold = 0;
    float offsetOpacity = 1;
    float offsetEmissionStrength = 1;
    vec3 offsetTint = vec3(0);
    vec3 offsetScreenTint = vec3(0);

    // TODO: Cache this
    size_t maskCount() {
        size_t c;
        foreach(m; masks) {
            if (m.maskSrc is null) continue;
            if (m.mode == MaskingMode.Mask || m.mode == MaskingMode.DodgeMask) c++;
        }
        return c;
    }

    size_t dodgeCount() {
        size_t c;
        foreach(m; masks) if (m.mode == MaskingMode.DodgeMask) c++;
        return c;
    }

public:
    /**
        List of textures this part can use

        TODO: use more than texture 0
    */
    Texture[TextureUsage.COUNT] textures;

    /**
        List of texture IDs
    */
    int[] textureIds;

    /**
        List of masks to apply
    */
    MaskBinding[] masks;

    /**
        Blending mode
    */
    BlendMode blendingMode = BlendMode.Normal;
    
    /**
        Alpha Threshold for the masking system, the higher the more opaque pixels will be discarded in the masking process
    */
    float maskAlphaThreshold = 0.5;

    /**
        Opacity of the mesh
    */
    float opacity = 1;

    /**
        Strength of emission
    */
    float emissionStrength = 1;

    /**
        Multiplicative tint color
    */
    vec3 tint = vec3(1, 1, 1);

    /**
        Screen tint color
    */
    vec3 screenTint = vec3(0, 0, 0);

    /**
        Gets the active texture
    */
    Texture activeTexture() {
        return textures[0];
    }

    /** 
        Ignore puppet.transform if set to true.
     */
    bool ignorePuppet = false;

private:
    bool hasOffscreenModelMatrix = false;
    mat4 offscreenModelMatrix;
    bool hasOffscreenRenderMatrix = false;
    mat4 offscreenRenderMatrix;

public:


    /**
        Constructs a new part
    */
    this(MeshData data, Texture[] textures, Node parent = null) {
        this(data, textures, inCreateUUID(), parent);
    }

    /**
        Constructs a new part
    */
    this(Node parent = null) {
        super(parent);
        initPartTasks();
        
        this.updateUVs();
    }

    /**
        Constructs a new part
    */
    this(MeshData data, Texture[] textures, uint uuid, Node parent = null) {
        super(data, uuid, parent);
        initPartTasks();
        foreach(i; 0..TextureUsage.COUNT) {
            if (i >= textures.length) break;
            this.textures[i] = textures[i];
        }

        this.updateUVs();
    }
    
    override
    void renderMask(bool dodge = false) {
        version(InDoesRender) {
            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            MaskApplyPacket packet;
            packet.kind = MaskDrawableKind.Part;
            packet.isDodge = dodge;
            packet.partPacket = makePartDrawPacket(this, true);
            backend.applyMask(packet);
        }
    }

    override
    bool hasParam(string key) {
        if (super.hasParam(key)) return true;

        switch(key) {
            case "alphaThreshold":
            case "opacity":
            case "tint.r":
            case "tint.g":
            case "tint.b":
            case "screenTint.r":
            case "screenTint.g":
            case "screenTint.b":
            case "emissionStrength":
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
            case "alphaThreshold":
                return 0;
            case "opacity":
            case "tint.r":
            case "tint.g":
            case "tint.b":
                return 1;
            case "screenTint.r":
            case "screenTint.g":
            case "screenTint.b":
                return 0;
            case "emissionStrength":
                return 1;
            default: return float();
        }
    }

    override
    bool setValue(string key, float value) {
        
        // Skip our list of our parent already handled it
        if (super.setValue(key, value)) return true;

        switch(key) {
            case "alphaThreshold":
                offsetMaskThreshold *= value;
                return true;
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
            case "emissionStrength":
                offsetEmissionStrength += value;
                return true;
            default: return false;
        }
    }
    
    override
    float getValue(string key) {
        switch(key) {
            case "alphaThreshold":  return offsetMaskThreshold;
            case "opacity":         return offsetOpacity;
            case "tint.r":          return offsetTint.x;
            case "tint.g":          return offsetTint.y;
            case "tint.b":          return offsetTint.z;
            case "screenTint.r":    return offsetScreenTint.x;
            case "screenTint.g":    return offsetScreenTint.y;
            case "screenTint.b":    return offsetScreenTint.z;
            case "emissionStrength":    return offsetEmissionStrength;
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
    protected void runBeginTask(ref RenderContext ctx) {
        offsetMaskThreshold = 0;
        offsetOpacity = 1;
        offsetTint = vec3(1, 1, 1);
        offsetScreenTint = vec3(0, 0, 0);
        offsetEmissionStrength = 1;
        super.runBeginTask(ctx);
    }
    
    override
    void rebuffer(ref MeshData data) {
        super.rebuffer(data);
        this.updateUVs();
    }

    override
    void draw() { }

    package(nijilive)
    void enqueueRenderCommands(RenderContext ctx, void delegate(RenderCommandEmitter) postCommands = null) {
        if (!renderEnabled() || ctx.renderGraph is null) return;

        MaskBinding[] dedupMaskBindings() {
            MaskBinding[] result;
            bool[ulong] seen;
            foreach (m; masks) {
                if (m.maskSrc is null) continue;
                auto key = (cast(ulong)m.maskSrc.uuid << 32) | cast(uint)m.mode;
                if (key in seen) continue;
                seen[key] = true;
                result ~= m;
            }
            return result;
        }

        auto maskBindings = dedupMaskBindings();
        bool hasMasks = maskBindings.length > 0;
        bool useStencil = false;
        foreach (m; maskBindings) {
            if (m.mode == MaskingMode.Mask) {
                useStencil = true;
                break;
            }
        }
        auto scopeHint = determineRenderScopeHint();
        if (scopeHint.skip) return;
        auto partNode = this;
        auto cleanup = postCommands;
        ctx.renderGraph.enqueueItem(zSort(), scopeHint, (RenderCommandEmitter emitter) {
            if (hasMasks) {
                emitter.beginMask(useStencil);
                foreach (binding; maskBindings) {
                    if (binding.maskSrc is null) continue;
                    bool isDodge = binding.mode == MaskingMode.DodgeMask;
                    import std.stdio : writefln;
                    debug (UnityDLLLog) writefln("[nijilive] applyMask part=%s(%s) maskSrc=%s(%s) mode=%s dodge=%s",
                        partNode.name, partNode.uuid,
                        binding.maskSrc.name, binding.maskSrc.uuid,
                        binding.mode, isDodge);
                    emitter.applyMask(binding.maskSrc, isDodge);
                }
                emitter.beginMaskContent();
            }

            emitter.drawPart(partNode, false);

            if (hasMasks) {
                emitter.endMask();
            }

            if (cleanup !is null) {
                cleanup(emitter);
            }
        });
    }

    override
    protected void runRenderTask(ref RenderContext ctx) {
        enqueueRenderCommands(ctx);
    }

    override
    void drawOne() {
        drawOneImmediate();
    }

    void drawOneImmediate() {
        version (InDoesRender) {
            if (!enabled) return;
            if (!data.isReady) return; // Yeah, don't even try

            auto backend = puppet ? puppet.renderBackend : null;
            if (backend is null) return;
            
            MaskBinding[] dedupMaskBindings() {
                MaskBinding[] result;
                bool[ulong] seen;
                foreach (m; masks) {
                    if (m.maskSrc is null) continue;
                    auto key = (cast(ulong)m.maskSrc.uuid << 32) | cast(uint)m.mode;
                    if (key in seen) continue;
                    seen[key] = true;
                    result ~= m;
                }
                return result;
            }

            auto maskBindings = dedupMaskBindings();
            bool hasNormalMask = false;
            foreach (m; maskBindings) {
                if (m.mode == MaskingMode.Mask) {
                    hasNormalMask = true;
                    break;
                }
            }

            if (maskBindings.length > 0) {
                // useStencil == true when there is at least one normal mask.
                backend.beginMask(hasNormalMask);

                foreach(ref mask; maskBindings) {
                    mask.maskSrc.renderMask(mask.mode == MaskingMode.DodgeMask);
                }

                backend.beginMaskContent();

                this.drawSelf();

                backend.endMask();
                return;
            }

            this.drawSelf();
        }
    }

    /// Build a render-space matrix/params that treat camera and puppet transforms uniformly.
    package(nijilive) RenderSpace currentRenderSpace(bool forceIgnorePuppet = false) {
        auto cam = inGetCamera();
        bool usePuppet = !forceIgnorePuppet && !ignorePuppet && puppet !is null;
        mat4 puppetMatrix = usePuppet ? puppet.transform.matrix : mat4.identity;
        vec2 puppetScale = usePuppet ? puppet.transform.scale : vec2(1, 1);
        float puppetRot = usePuppet ? puppet.transform.rotation.z : 0;

        float sx = cam.scale.x * puppetScale.x;
        float sy = cam.scale.y * puppetScale.y;
        if (!isFinite(sx) || sx == 0) sx = 1;
        if (!isFinite(sy) || sy == 0) sy = 1;

        float rot = cam.rotation + puppetRot;
        if (!isFinite(rot)) rot = 0;
        if (sx * sy < 0) rot = -rot;

        RenderSpace space;
        space.matrix = cam.matrix * puppetMatrix;
        space.scale = vec2(sx, sy);
        space.rotation = rot;
        debug (UnityDLLLog) {
            import std.stdio : writefln;
            writefln("[renderSpace] part=%s ignorePuppet=%s forceIgnore=%s usePuppet=%s puppetScale=%s camScale=%s",
                name, ignorePuppet, forceIgnorePuppet, usePuppet, puppetScale, cam.scale);
        }
        return space;
    }

    void fillDrawPacket(ref PartDrawPacket packet, bool isMask = false) {
        packet.isMask = isMask;
        packet.renderable = backendRenderable();

        mat4 modelMatrix = immediateModelMatrix();
        packet.modelMatrix = modelMatrix;
        // respect per-part ignorePuppet flag when building render space
        auto renderSpace = currentRenderSpace();
        packet.renderMatrix = renderSpace.matrix;
        packet.renderRotation = renderSpace.rotation;
        if (hasOffscreenModelMatrix) {
            // Use explicit offscreen render matrix when provided; otherwise keep current render space.
            if (hasOffscreenRenderMatrix) {
                packet.renderMatrix = offscreenRenderMatrix;
                packet.renderRotation = 0;
            }
        }

        packet.opacity = clamp(offsetOpacity * opacity, 0, 1);
        packet.emissionStrength = emissionStrength * offsetEmissionStrength;
        packet.blendingMode = blendingMode;
        packet.useMultistageBlend = inUseMultistageBlending(blendingMode);
        packet.hasEmissionOrBumpmap = textures.length > 2 && (textures[1] !is null || textures[2] !is null);
        packet.maskThreshold = clamp(offsetMaskThreshold + maskAlphaThreshold, 0, 1);

        vec3 clampedTint = tint;
        if (!offsetTint.x.isNaN) clampedTint.x = clamp(tint.x * offsetTint.x, 0, 1);
        if (!offsetTint.y.isNaN) clampedTint.y = clamp(tint.y * offsetTint.y, 0, 1);
        if (!offsetTint.z.isNaN) clampedTint.z = clamp(tint.z * offsetTint.z, 0, 1);
        packet.clampedTint = clampedTint;

        vec3 clampedScreen = screenTint;
        if (!offsetScreenTint.x.isNaN) clampedScreen.x = clamp(screenTint.x + offsetScreenTint.x, 0, 1);
        if (!offsetScreenTint.y.isNaN) clampedScreen.y = clamp(screenTint.y + offsetScreenTint.y, 0, 1);
        if (!offsetScreenTint.z.isNaN) clampedScreen.z = clamp(screenTint.z + offsetScreenTint.z, 0, 1);
        packet.clampedScreen = clampedScreen;
        packet.textures = textures.dup;
        packet.origin = data.origin;
        packet.vertexOffset = vertexSliceOffset;
        packet.vertexAtlasStride = sharedVertexAtlasStride();
        packet.uvOffset = uvSliceOffset;
        packet.uvAtlasStride = sharedUvAtlasStride();
        packet.deformOffset = deformSliceOffset;
        packet.deformAtlasStride = sharedDeformAtlasStride();
        packet.indexBuffer = ibo;
        packet.indexCount = cast(uint)data.indices.length;
        packet.vertexCount = cast(uint)data.vertices.length;
    }

    package(nijilive) mat4 immediateModelMatrix() {
        mat4 modelMatrix = hasOffscreenModelMatrix ? offscreenModelMatrix : transform.matrix();
        if (overrideTransformMatrix !is null)
            modelMatrix = overrideTransformMatrix.matrix;
        if (oneTimeTransform !is null)
            modelMatrix = (*oneTimeTransform) * modelMatrix;
        return modelMatrix;
    }

package(nijilive) void setOffscreenModelMatrix(const mat4 matrix) {
    offscreenModelMatrix = matrix;
    hasOffscreenModelMatrix = true;
}

package(nijilive) void setOffscreenRenderMatrix(const mat4 matrix) {
    offscreenRenderMatrix = matrix;
    hasOffscreenRenderMatrix = true;
}

package(nijilive) bool hasOffscreenModelMatrixActive() const {
    return hasOffscreenModelMatrix;
}

package(nijilive) bool hasOffscreenRenderMatrixActive() const {
    return hasOffscreenRenderMatrix;
}

package(nijilive) mat4 offscreenRenderMatrixValue() const {
    return offscreenRenderMatrix;
}

package(nijilive) void clearOffscreenModelMatrix() {
    hasOffscreenModelMatrix = false;
}

package(nijilive) void clearOffscreenRenderMatrix() {
    hasOffscreenRenderMatrix = false;
}

package(nijilive) bool backendRenderable() {
    return enabled && data.isReady();
}

    package(nijilive) size_t backendMaskCount() {
        return maskCount();
    }

    package(nijilive) MaskBinding[] backendMasks() {
        return masks;
    }

    override
    void drawOneDirect(bool forMasking) {
        if (forMasking) this.drawSelf!true();
        else this.drawSelf!false();
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


    override
    void setOneTimeTransform(mat4* transform) {
        super.setOneTimeTransform(transform);
        foreach (m; masks) {
            m.maskSrc.oneTimeTransform = transform;
        }
    }

    override
    void normalizeUV(MeshData* data) {
        auto tex = textures[0];
        foreach (i; 0..data.uvs.length) {
            data.uvs[i].x /= cast(float)tex.width;
            data.uvs[i].y /= cast(float)tex.height;
            data.uvs[i] += vec2(0.5, 0.5);
        }
    }

    override
    void copyFrom(Node src, bool clone = false, bool deepCopy = true) {
        if ((cast(DynamicComposite)src) !is null &&
            (cast(DynamicComposite)this) is null) {
                deepCopy = false;
        }
        super.copyFrom(src, clone, deepCopy);

        if (auto part = cast(Part)src) {
            offsetMaskThreshold = 0;
            offsetOpacity = 1;
            offsetEmissionStrength = 1;
            offsetTint = vec3(0);
            offsetScreenTint = vec3(0);

            textures = part.textures.dup;
            textureIds = part.textureIds.dup;
            masks = part.masks.dup;
            blendingMode = part.blendingMode;
            maskAlphaThreshold = part.maskAlphaThreshold;
            opacity = part.opacity;
            emissionStrength = part.emissionStrength;
            tint = part.tint;
            screenTint = part.screenTint;
        }
    }
}
