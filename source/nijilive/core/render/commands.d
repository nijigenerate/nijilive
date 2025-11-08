module nijilive.core.render.commands;

import nijilive.core.nodes;
import nijilive.core.nodes.part;
import nijilive.core.nodes.composite;
import nijilive.core.nodes.drawable;
import nijilive.core.nodes.mask : Mask;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
import nijilive.math;
import nijilive.core.texture : Texture;

/// GPUコマンド種別。Backend 側で switch して処理する。
enum RenderCommandKind {
    DrawNode,
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
    Part part;
    bool isMask;
    mat4 modelMatrix;
    mat4 mvp;
    bool ignoreCamera;
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
    uint vertexBuffer;
    uint uvBuffer;
    uint deformBuffer;
    uint indexBuffer;
    uint indexCount;
}

struct MaskDrawPacket {
    Mask mask;
    mat4 modelMatrix;
    mat4 mvp;
    vec2 origin;
    uint vertexBuffer;
    uint deformBuffer;
    uint indexBuffer;
    uint indexCount;
}

struct MaskApplyPacket {
    MaskDrawableKind kind;
    bool isDodge;
    PartDrawPacket partPacket;
    MaskDrawPacket maskPacket;
}

/// RenderQueue に積まれる汎用パケット。
struct RenderCommandData {
    RenderCommandKind kind;
    Node node;
    PartDrawPacket partPacket;
    MaskDrawPacket maskDrawPacket;
    DynamicComposite dynamicComposite;
    bool maskUsesStencil;
    MaskApplyPacket maskPacket;
    CompositeDrawPacket compositePacket;
}

struct CompositeDrawPacket {
    Composite composite;
    float opacity;
    vec3 tint;
    vec3 screenTint;
}

RenderCommandData makeDrawNodeCommand(Node node) {
    RenderCommandData data;
    data.kind = RenderCommandKind.DrawNode;
    data.node = node;
    return data;
}

PartDrawPacket makePartDrawPacket(Part part, bool isMask = false) {
    PartDrawPacket packet;
    if (part !is null) {
        part.fillDrawPacket(packet, isMask);
    }
    return packet;
}

RenderCommandData makeDrawPartCommand(PartDrawPacket packet) {
    RenderCommandData data;
    data.kind = RenderCommandKind.DrawPart;
    data.partPacket = packet;
    return data;
}

RenderCommandData makeDrawMaskCommand(MaskDrawPacket packet) {
    RenderCommandData data;
    data.kind = RenderCommandKind.DrawMask;
    data.maskDrawPacket = packet;
    return data;
}

RenderCommandData makeBeginDynamicCompositeCommand(DynamicComposite composite) {
    RenderCommandData data;
    data.kind = RenderCommandKind.BeginDynamicComposite;
    data.dynamicComposite = composite;
    return data;
}

RenderCommandData makeEndDynamicCompositeCommand(DynamicComposite composite) {
    RenderCommandData data;
    data.kind = RenderCommandKind.EndDynamicComposite;
    data.dynamicComposite = composite;
    return data;
}

RenderCommandData makeBeginMaskCommand(bool useStencil) {
    RenderCommandData data;
    data.kind = RenderCommandKind.BeginMask;
    data.maskUsesStencil = useStencil;
    return data;
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
    if (auto part = cast(Part)drawable) {
        packet.kind = MaskDrawableKind.Part;
        packet.partPacket = makePartDrawPacket(part, true);
        packet.isDodge = isDodge;
        return true;
    }
    if (auto mask = cast(Mask)drawable) {
        packet.kind = MaskDrawableKind.Mask;
        packet.maskPacket = makeMaskDrawPacket(mask);
        packet.isDodge = isDodge;
        return true;
    }
    return false;
}

RenderCommandData makeApplyMaskCommand(MaskApplyPacket packet) {
    RenderCommandData data;
    data.kind = RenderCommandKind.ApplyMask;
    data.maskPacket = packet;
    return data;
}

RenderCommandData makeBeginMaskContentCommand() {
    RenderCommandData data;
    data.kind = RenderCommandKind.BeginMaskContent;
    return data;
}

RenderCommandData makeEndMaskCommand() {
    RenderCommandData data;
    data.kind = RenderCommandKind.EndMask;
    return data;
}

CompositeDrawPacket makeCompositeDrawPacket(Composite composite) {
    CompositeDrawPacket packet;
    if (composite !is null) {
        packet.composite = composite;
        packet.opacity = composite.opacity * composite.offsetOpacity;
        packet.tint = composite.computeClampedTint();
        packet.screenTint = composite.computeClampedScreenTint();
    }
    return packet;
}

RenderCommandData makeBeginCompositeCommand() {
    RenderCommandData data;
    data.kind = RenderCommandKind.BeginComposite;
    return data;
}

RenderCommandData makeDrawCompositeQuadCommand(CompositeDrawPacket packet) {
    RenderCommandData data;
    data.kind = RenderCommandKind.DrawCompositeQuad;
    data.compositePacket = packet;
    return data;
}

RenderCommandData makeEndCompositeCommand() {
    RenderCommandData data;
    data.kind = RenderCommandKind.EndComposite;
    return data;
}
