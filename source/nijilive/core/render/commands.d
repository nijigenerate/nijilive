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
    BeginDynamicComposite,
    EndDynamicComposite,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
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
    int drawBufferCount;
    bool hasStencil;
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
