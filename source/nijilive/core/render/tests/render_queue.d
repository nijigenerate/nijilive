module nijilive.core.render.tests.render_queue;

version(unittest) {

import std.algorithm : equal, filter, map;
import std.array : array;
import std.conv : to;
import std.range : iota;

import nijilive.math : vec2, vec3;
import nijilive.core;
import nijilive.core : inEnsureCameraStackForTests, inEnsureViewportForTests;
import nijilive.core.nodes;
import nijilive.core.nodes.composite;
import nijilive.core.nodes.mask;
import nijilive.core.nodes.meshgroup;
import nijilive.core.nodes.part;
import nijilive.core.nodes.deformer.grid;
import nijilive.core.nodes.deformer.path;
import nijilive.core.nodes.composite.dcomposite;
import nijilive.core.render.queue;
import nijilive.core.render.graph;
import nijilive.core.render.commands : RenderCommandKind, MaskApplyPacket, PartDrawPacket,
    MaskDrawPacket, MaskDrawableKind, CompositeDrawPacket;
import nijilive.core.render.backends;
import nijilive.core.render.scheduler : RenderContext;
import nijilive.core.meshdata;
import nijilive.core.texture : Texture;
import nijilive.core.nodes.part : TextureUsage;
import nijilive.core.nodes.common : MaskBinding, MaskingMode;

private:

shared static this() {
    inEnsureCameraStackForTests();
    inEnsureViewportForTests();
}

MeshData makeQuadMesh(float size = 1.0f) {
    auto half = size / 2.0f;
    MeshData data;
    data.vertices = [
        vec2(-half, -half),
        vec2( half, -half),
        vec2(-half,  half),
        vec2( half,  half),
    ];
    data.uvs = [
        vec2(0, 0),
        vec2(1, 0),
        vec2(0, 1),
        vec2(1, 1),
    ];
    data.indices = [
        cast(ushort)0, 1, 2,
        cast(ushort)2, 1, 3,
    ];
    data.origin = vec2(0, 0);
    return data;
}

struct CommandRecord {
    RenderCommandKind kind;
    string nodeName;
    bool maskUsesStencil;
    MaskDrawableKind maskKind;
}

class RecordingBackend : RenderBackend {
    CommandRecord[] records;

    override void drawNode(Node node) {
        records ~= CommandRecord(RenderCommandKind.DrawNode, node ? node.name : "", false, MaskDrawableKind.Part);
    }

    override void drawPartPacket(ref PartDrawPacket packet) {
        records ~= CommandRecord(RenderCommandKind.DrawPart,
            packet.part ? packet.part.name : "",
            false,
            MaskDrawableKind.Part);
    }

    override void drawMaskPacket(ref MaskDrawPacket packet) {
        records ~= CommandRecord(RenderCommandKind.DrawMask,
            packet.mask ? packet.mask.name : "",
            false,
            MaskDrawableKind.Mask);
    }

    override void beginDynamicComposite(DynamicComposite composite) {
        records ~= CommandRecord(RenderCommandKind.BeginDynamicComposite,
            composite ? composite.name : "",
            false,
            MaskDrawableKind.Part);
    }

    override void endDynamicComposite(DynamicComposite composite) {
        records ~= CommandRecord(RenderCommandKind.EndDynamicComposite,
            composite ? composite.name : "",
            false,
            MaskDrawableKind.Part);
    }

    override void beginMask(bool useStencil) {
        records ~= CommandRecord(RenderCommandKind.BeginMask, "", useStencil, MaskDrawableKind.Part);
    }

    override void applyMask(ref MaskApplyPacket packet) {
        records ~= CommandRecord(RenderCommandKind.ApplyMask,
            packet.kind == MaskDrawableKind.Part && packet.partPacket.part !is null
                ? packet.partPacket.part.name
                : packet.kind == MaskDrawableKind.Mask && packet.maskPacket.mask !is null
                    ? packet.maskPacket.mask.name
                    : "",
            false,
            packet.kind);
    }

    override void beginMaskContent() {
        records ~= CommandRecord(RenderCommandKind.BeginMaskContent, "", false, MaskDrawableKind.Part);
    }

    override void endMask() {
        records ~= CommandRecord(RenderCommandKind.EndMask, "", false, MaskDrawableKind.Part);
    }

    override void beginComposite() {
        records ~= CommandRecord(RenderCommandKind.BeginComposite, "", false, MaskDrawableKind.Part);
    }

    override void drawCompositeQuad(ref CompositeDrawPacket packet) {
        records ~= CommandRecord(RenderCommandKind.DrawCompositeQuad,
            packet.composite ? packet.composite.name : "",
            false,
            MaskDrawableKind.Part);
    }

    override void endComposite() {
        records ~= CommandRecord(RenderCommandKind.EndComposite, "", false, MaskDrawableKind.Part);
    }
}

CommandRecord[] executeFrame(Puppet puppet) {
    inEnsureCameraStackForTests();
    inEnsureViewportForTests();
    auto backend = new RecordingBackend();
    auto queue = new RenderQueue();
    RenderContext ctx;
    ctx.renderQueue = &queue;
    ctx.renderBackend = backend;
    ctx.gpuState = RenderGpuState.init;

    RenderGraph graph = new RenderGraph();
    graph.buildFrame(puppet.actualRoot());
    graph.execute(ctx);

    queue.flush(ctx.renderBackend, ctx.gpuState);
    return backend.records.dup;
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto part = new Part(quad, textures, inCreateUUID(), puppet.root);
    part.name = "StandalonePart";

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [RenderCommandKind.DrawPart], "Standalone part should enqueue exactly one DrawPart command.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto back = new Part(quad, textures, inCreateUUID(), puppet.root);
    back.name = "Background";
    back.zSort = -0.5f;

    auto front = new Part(quad, textures, inCreateUUID(), puppet.root);
    front.name = "Foreground";
    front.zSort = 0.5f;

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto drawNames = records
        .filter!(r => r.kind == RenderCommandKind.DrawPart)
        .map!(r => r.nodeName)
        .array;
    assert(drawNames == ["Foreground", "Background"],
        "Render tasks must be flushed in descending zSort order.");
}

} // version(unittest)

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto part = new Part(quad, textures, inCreateUUID(), puppet.root);
    part.name = "MaskedPart";

    auto mask = new Mask(quad, inCreateUUID(), part);
    mask.name = "LocalMask";

    MaskBinding binding;
    binding.maskSrcUUID = mask.uuid;
    binding.mode = MaskingMode.Mask;
    binding.maskSrc = mask;
    part.masks = [binding];

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginMask,
        RenderCommandKind.ApplyMask,
        RenderCommandKind.BeginMaskContent,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndMask
    ], "Masked part should emit mask begin/apply/content commands around DrawPart.");

    assert(records[1].maskKind == MaskDrawableKind.Mask,
        "ApplyMask should reference Mask drawable when masking.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto composite = new Composite(puppet.root);
    composite.name = "Composite";

    auto child = new Part(quad, textures, inCreateUUID(), composite);
    child.name = "ChildPart";

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginComposite,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndComposite,
        RenderCommandKind.DrawCompositeQuad
    ], "Composite should render children into its offscreen target before drawing the quad.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto composite = new Composite(puppet.root);
    composite.name = "MaskedComposite";

    auto child = new Part(quad, textures, inCreateUUID(), composite);
    child.name = "ChildPart";

    auto maskNode = new Mask(quad, inCreateUUID(), composite);
    maskNode.name = "CompositeMask";

    MaskBinding binding;
    binding.maskSrcUUID = maskNode.uuid;
    binding.mode = MaskingMode.Mask;
    binding.maskSrc = maskNode;
    composite.masks = [binding];

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginComposite,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndComposite,
        RenderCommandKind.BeginMask,
        RenderCommandKind.ApplyMask,
        RenderCommandKind.BeginMaskContent,
        RenderCommandKind.DrawCompositeQuad,
        RenderCommandKind.EndMask
    ], "Composite masks must wrap the transfer step, not child rendering.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto outer = new Composite(puppet.root);
    outer.name = "OuterComposite";

    auto inner = new Composite(outer);
    inner.name = "InnerComposite";

    auto innerPart = new Part(quad, textures, inCreateUUID(), inner);
    innerPart.name = "InnerPart";

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginComposite,      // outer begin
        RenderCommandKind.BeginComposite,      // inner begin
        RenderCommandKind.DrawPart,            // inner child
        RenderCommandKind.EndComposite,        // inner end
        RenderCommandKind.DrawCompositeQuad,   // inner transfer to outer FBO
        RenderCommandKind.EndComposite,        // outer end
        RenderCommandKind.DrawCompositeQuad    // outer transfer to parent
    ], "Nested composites should finalize inner scopes before closing the outer scope.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto dynamic = new DynamicComposite(false);
    dynamic.name = "Dynamic";
    dynamic.textures = [null, null, null];
    dynamic.invalidate();
    dynamic.parent = puppet.root;

    auto child = new Part(quad, textures, inCreateUUID(), dynamic);
    child.name = "DynamicChild";

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginDynamicComposite,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndDynamicComposite,
        RenderCommandKind.DrawPart
    ], "DynamicComposite should render into its target before emitting its draw command.");
}

unittest {
    auto puppet = new Puppet();
    puppet.root.name = "Root";

    auto quad = makeQuadMesh();
    Texture[] textures;
    textures.length = TextureUsage.COUNT;

    auto meshGroup = new MeshGroup(puppet.root);
    meshGroup.name = "MeshGroup";

    auto grid = new GridDeformer(meshGroup);
    grid.name = "GridDeformer";

    auto path = new PathDeformer(grid);
    path.name = "PathDeformer";
    path.rebuffer([vec2(0, 0), vec2(1, 0)]);

    auto part = new Part(quad, textures, inCreateUUID(), path);
    part.name = "NestedPart";

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto kinds = records.map!(r => r.kind).array;
    assert(kinds == [RenderCommandKind.DrawPart],
        "CPU-only deformers should not emit additional GPU commands.");
}
