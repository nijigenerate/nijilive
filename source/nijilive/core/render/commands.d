module nijilive.core.render.commands;

import nijilive.core.nodes;
import nijilive.core.nodes.part;
import nijilive.core.nodes.composite;
import nijilive.core.nodes.drawable;
import nijilive.core.nodes.mask : Mask;
import nijilive.math;
import nijilive.core.texture : Texture;
import nijilive.core.render.backends : RenderResourceHandle;
import nijilive.core.render.passes : RenderPassKind;

/// GPU command kinds; backends switch on these during rendering.
enum RenderCommandKind {
    DrawPart,
    DrawMask,
    BeginDynamicComposite,
    EndDynamicComposite,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
    BeginComposite,
    DrawCompositeQuad,
    EndComposite,
}

enum MaskDrawableKind {
    Part,
    Mask,
}

struct PartDrawPacket {
    bool isMask;
    bool renderable;
    mat4 modelMatrix;
    mat4 renderMatrix;
    vec2 renderScale;
    float renderRotation;
    vec3 clampedTint;
    vec3 clampedScreen;
    float opacity;
    float emissionStrength;
    float maskThreshold;
    BlendMode blendingMode;
    bool useMultistageBlend;
    bool hasEmissionOrBumpmap;
    Texture[] textures;
    vec2 origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t uvOffset;
    size_t uvAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    RenderResourceHandle indexBuffer;
    uint indexCount;
    uint vertexCount;
}

struct MaskDrawPacket {
    mat4 modelMatrix;
    mat4 mvp;
    vec2 origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    RenderResourceHandle indexBuffer;
    uint indexCount;
    uint vertexCount;
}

struct MaskApplyPacket {
    MaskDrawableKind kind;
    bool isDodge;
    PartDrawPacket partPacket;
    MaskDrawPacket maskPacket;
}

struct CompositeDrawPacket {
    bool valid;
    float opacity;
    vec3 tint;
    vec3 screenTint;
    BlendMode blendingMode;
}

class DynamicCompositeSurface {
    Texture[3] textures;
    size_t textureCount;
    Texture stencil;
    RenderResourceHandle framebuffer;
}

class DynamicCompositePass {
    DynamicCompositeSurface surface;
    vec2 scale;
    float rotationZ;
    RenderResourceHandle origBuffer;
    int[4] origViewport;
    bool autoScaled;
    int prevDrawBufferCount;
    uint[3] prevDrawBuffers;
}

PartDrawPacket makePartDrawPacket(Part part, bool isMask = false) {
    PartDrawPacket packet;
    if (part !is null) {
        part.fillDrawPacket(packet, isMask);
    }
    return packet;
}

MaskDrawPacket makeMaskDrawPacket(Mask mask) {
    MaskDrawPacket packet;
    if (mask !is null) {
        mask.fillMaskDrawPacket(packet);
    }
    return packet;
}

bool tryMakeMaskApplyPacket(Drawable drawable, bool isDodge, out MaskApplyPacket packet) {
    if (drawable is null) return false;
    // Prefer the explicit Mask path even though Mask inherits Part.
    if (auto mask = cast(Mask)drawable) {
        packet.kind = MaskDrawableKind.Mask;
        packet.maskPacket = makeMaskDrawPacket(mask);
        packet.isDodge = isDodge;
        auto mesh = mask.getMesh();
        if (mesh.indices.length > 0) {
            size_t maxIdx = 0;
            foreach (idx; mesh.indices) {
                if (idx > maxIdx) maxIdx = idx;
            }
            if (maxIdx >= mesh.vertices.length) {
                debug (UnityDLLLog) {
                    import std.stdio : writefln;
                    debug (UnityDLLLog) writefln("[nijilive] tryMakeMaskApplyPacket skip: mask name=%s uuid=%s index out of range max=%s verts=%s",
                        mask.name, mask.uuid, maxIdx, mesh.vertices.length);
                }
                return false;
            }
        }
        if (packet.maskPacket.indexCount == 0 || packet.maskPacket.indexBuffer == RenderResourceHandle.init) {
            debug (UnityDLLLog) {
                import std.stdio : writefln;
                debug (UnityDLLLog) writefln("[nijilive] tryMakeMaskApplyPacket skip: mask ibo=%s idxCount=%s", packet.maskPacket.indexBuffer, packet.maskPacket.indexCount);
            }
            return false;
        }
        return true;
    }
    if (auto part = cast(Part)drawable) {
        packet.kind = MaskDrawableKind.Part;
        packet.partPacket = makePartDrawPacket(part, true);
        packet.isDodge = isDodge;
        // index range check to avoid CPU/GPU crash
        auto mesh = part.getMesh();
        if (mesh.indices.length > 0) {
            size_t maxIdx = 0;
            foreach (idx; mesh.indices) {
                if (idx > maxIdx) maxIdx = idx;
            }
            if (maxIdx >= mesh.vertices.length) {
                debug (UnityDLLLog) {
                    import std.stdio : writefln;
                    debug (UnityDLLLog) writefln("[nijilive] tryMakeMaskApplyPacket skip: part name=%s uuid=%s index out of range max=%s verts=%s",
                        part.name, part.uuid, maxIdx, mesh.vertices.length);
                }
                return false;
            }
        }
        // index buffer resource must be valid before issuing commands
        if (packet.partPacket.indexCount == 0 || packet.partPacket.indexBuffer == RenderResourceHandle.init) {
            debug (UnityDLLLog) {
                import std.stdio : writefln;
                debug (UnityDLLLog) writefln("[nijilive] tryMakeMaskApplyPacket skip: part ibo=%s idxCount=%s", packet.partPacket.indexBuffer, packet.partPacket.indexCount);
            }
            return false;
        }
        return true;
    }
    return false;
}

CompositeDrawPacket makeCompositeDrawPacket(Composite composite) {
    CompositeDrawPacket packet;
    if (composite !is null) {
        packet.valid = true;
        float offsetOpacity = composite.getValue("opacity");
        packet.opacity = composite.opacity * offsetOpacity;

        vec3 clampedTint = composite.tint;
        float offsetTintR = composite.getValue("tint.r");
        float offsetTintG = composite.getValue("tint.g");
        float offsetTintB = composite.getValue("tint.b");
        if (!offsetTintR.isNaN) clampedTint.x = clamp(composite.tint.x * offsetTintR, 0, 1);
        if (!offsetTintG.isNaN) clampedTint.y = clamp(composite.tint.y * offsetTintG, 0, 1);
        if (!offsetTintB.isNaN) clampedTint.z = clamp(composite.tint.z * offsetTintB, 0, 1);
        packet.tint = clampedTint;

        vec3 clampedScreenTint = composite.screenTint;
        float offsetScreenTintR = composite.getValue("screenTint.r");
        float offsetScreenTintG = composite.getValue("screenTint.g");
        float offsetScreenTintB = composite.getValue("screenTint.b");
        if (!offsetScreenTintR.isNaN) clampedScreenTint.x = clamp(composite.screenTint.x + offsetScreenTintR, 0, 1);
        if (!offsetScreenTintG.isNaN) clampedScreenTint.y = clamp(composite.screenTint.y + offsetScreenTintG, 0, 1);
        if (!offsetScreenTintB.isNaN) clampedScreenTint.z = clamp(composite.screenTint.z + offsetScreenTintB, 0, 1);
        packet.screenTint = clampedScreenTint;
        packet.blendingMode = composite.blendingMode;
    }
    return packet;
}
