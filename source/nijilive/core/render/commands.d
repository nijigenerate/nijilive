module nijilive.core.render.commands;

import nijilive.core.nodes;
import nijilive.core.nodes.part;
import nijilive.core.nodes.composite;
import nijilive.core.nodes.drawable;
import nijilive.math;
import nijilive.core.texture : Texture;
import bindbc.opengl : GLuint;

/// GPUコマンド種別。Backend 側で switch して処理する。
enum RenderCommandKind {
    DrawNode,
    DrawPart,
    DrawComposite,
    DrawCompositeMask,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
}

struct PartDrawPacket {
    Part part;
    bool isMask;
    mat4 modelMatrix;
    mat4 mvp;
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
    GLuint vertexBuffer;
    GLuint uvBuffer;
    GLuint deformBuffer;
    GLuint indexBuffer;
    uint indexCount;
}

/// RenderQueue に積まれる汎用パケット。
struct RenderCommandData {
    RenderCommandKind kind;
    Node node;
    PartDrawPacket partPacket;
    Composite composite;
    Part[] masks;
    bool maskUsesStencil;
    Drawable maskDrawable;
    bool maskIsDodge;
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

RenderCommandData makeDrawCompositeCommand(Composite composite) {
    RenderCommandData data;
    data.kind = RenderCommandKind.DrawComposite;
    data.composite = composite;
    return data;
}

RenderCommandData makeDrawCompositeMaskCommand(Composite composite, Part[] masks) {
    RenderCommandData data;
    data.kind = RenderCommandKind.DrawCompositeMask;
    data.composite = composite;
    data.masks = masks;
    return data;
}

RenderCommandData makeBeginMaskCommand(bool useStencil) {
    RenderCommandData data;
    data.kind = RenderCommandKind.BeginMask;
    data.maskUsesStencil = useStencil;
    return data;
}

RenderCommandData makeApplyMaskCommand(Drawable drawable, bool isDodge) {
    RenderCommandData data;
    data.kind = RenderCommandKind.ApplyMask;
    data.maskDrawable = drawable;
    data.maskIsDodge = isDodge;
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
