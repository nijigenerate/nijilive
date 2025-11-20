module nijilive.core.render.tests.render_queue;

version(unittest) {

import std.algorithm : equal, filter, map;
import std.array : array;
import std.conv : to;
import std.range : iota;

import nijilive.math : vec2, vec3, mat4;
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
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.render.graph_builder;
import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.commands : RenderCommandKind, MaskApplyPacket, PartDrawPacket,
    MaskDrawPacket, MaskDrawableKind, CompositeDrawPacket, DynamicCompositePass,
    DynamicCompositeSurface, makePartDrawPacket, makeMaskDrawPacket,
    makeCompositeDrawPacket, tryMakeMaskApplyPacket;
import nijilive.core.render.backends : RenderBackend, RenderGpuState;
import nijilive.core.render.scheduler : RenderContext, TaskScheduler;
import nijilive.core.meshdata;
import nijilive.core.texture : Texture;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.core.nodes.part : TextureUsage;
import nijilive.core.nodes.common : MaskBinding, MaskingMode;

final class RecordingEmitter : RenderCommandEmitter {
    struct RecordedCommand {
        RenderCommandKind kind;
        PartDrawPacket partPacket;
        MaskDrawPacket maskDrawPacket;
        DynamicCompositePass dynamicPass;
        bool maskUsesStencil;
        MaskApplyPacket maskPacket;
        CompositeDrawPacket compositePacket;
    }

    RecordedCommand[] commands;

    void beginFrame(RenderBackend, ref RenderGpuState) {
        commands.length = 0;
    }

    void endFrame(RenderBackend, ref RenderGpuState) {}

    void drawPart(Part part, bool isMask) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.DrawPart;
        cmd.partPacket = makePartDrawPacket(part, isMask);
        commands ~= cmd;
    }

    void drawMask(Mask mask) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.DrawMask;
        cmd.maskDrawPacket = makeMaskDrawPacket(mask);
        commands ~= cmd;
    }

    void beginDynamicComposite(DynamicComposite, DynamicCompositePass passData) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginDynamicComposite;
        cmd.dynamicPass = passData;
        commands ~= cmd;
    }

    void endDynamicComposite(DynamicComposite, DynamicCompositePass passData) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.EndDynamicComposite;
        cmd.dynamicPass = passData;
        commands ~= cmd;
    }

    void beginMask(bool useStencil) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginMask;
        cmd.maskUsesStencil = useStencil;
        commands ~= cmd;
    }

    void applyMask(Drawable drawable, bool isDodge) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.ApplyMask;
        MaskApplyPacket packet;
        if (tryMakeMaskApplyPacket(drawable, isDodge, packet)) {
            cmd.maskPacket = packet;
        }
        commands ~= cmd;
    }

    void beginMaskContent() {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginMaskContent;
        commands ~= cmd;
    }

    void endMask() {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.EndMask;
        commands ~= cmd;
    }

    void beginComposite(Composite) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.BeginComposite;
        commands ~= cmd;
    }

    void drawCompositeQuad(Composite composite) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.DrawCompositeQuad;
        cmd.compositePacket = makeCompositeDrawPacket(composite);
        commands ~= cmd;
    }

    void endComposite(Composite) {
        RecordedCommand cmd;
        cmd.kind = RenderCommandKind.EndComposite;
        commands ~= cmd;
    }
}

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

alias RecordedCommand = RecordingEmitter.RecordedCommand;

RecordedCommand[] executeFrame(Puppet puppet) {
    inEnsureCameraStackForTests();
    inEnsureViewportForTests();
    auto graph = new RenderGraphBuilder();
    RenderContext ctx;
    ctx.renderGraph = &graph;
    ctx.renderBackend = null;
    ctx.gpuState = RenderGpuState.init;

    auto scheduler = new TaskScheduler();
    if (auto root = puppet.actualRoot()) {
        scheduler.clearTasks();
        root.registerRenderTasks(scheduler);
        graph.beginFrame();
        scheduler.execute(ctx);
    }

    auto emitter = new RecordingEmitter();
    emitter.beginFrame(null, ctx.gpuState);
    graph.playback(emitter);
    emitter.endFrame(null, ctx.gpuState);
    return emitter.commands.dup;
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
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
    back.opacity = 0.25f;

    auto front = new Part(quad, textures, inCreateUUID(), puppet.root);
    front.name = "Foreground";
    front.zSort = 0.5f;
    front.opacity = 0.75f;

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto drawOpacities = commands
        .filter!(c => c.kind == RenderCommandKind.DrawPart)
        .map!(c => c.partPacket.opacity)
        .array;
    assert(drawOpacities == [0.75f, 0.25f],
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [
        RenderCommandKind.BeginMask,
        RenderCommandKind.ApplyMask,
        RenderCommandKind.BeginMaskContent,
        RenderCommandKind.DrawPart,
        RenderCommandKind.EndMask
    ], "Masked part should emit mask begin/apply/content commands around DrawPart.");

    assert(commands[1].maskPacket.kind == MaskDrawableKind.Mask,
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
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

    auto first = new Composite(puppet.root);
    first.name = "FirstComposite";
    auto firstPart = new Part(quad, textures, inCreateUUID(), first);
    firstPart.name = "FirstChild";

    auto second = new Composite(puppet.root);
    second.name = "SecondComposite";
    second.zSort = -0.1f;
    auto secondPart = new Part(quad, textures, inCreateUUID(), second);
    secondPart.name = "SecondChild";

    puppet.rescanNodes();
    auto commands = executeFrame(puppet);
    auto compositeDraws = commands
        .filter!(c => c.kind == RenderCommandKind.DrawCompositeQuad)
        .array;
    assert(compositeDraws.length == 2,
        "Sibling composites should each emit a DrawCompositeQuad command.");
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
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
    auto commands = executeFrame(puppet);
    auto kinds = commands.map!(c => c.kind).array;
    assert(kinds == [RenderCommandKind.DrawPart],
        "CPU-only deformers should not emit additional GPU commands.");
}
