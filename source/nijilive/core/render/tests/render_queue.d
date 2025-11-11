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
import nijilive.core.render.queue;
import nijilive.core.render.graph_builder;
import nijilive.core.render.commands : RenderCommandKind, MaskApplyPacket, PartDrawPacket,
    MaskDrawPacket, MaskDrawableKind, CompositeDrawPacket, DynamicCompositePass,
    DynamicCompositeSurface;
import nijilive.core.render.backends : RenderingBackend, BackendEnum;
import nijilive.core.render.scheduler : RenderContext, TaskScheduler;
import nijilive.core.meshdata;
import nijilive.core.texture : Texture;
import nijilive.core.texture_types : Filtering, Wrapping;
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
    PartDrawPacket partPacket;
    MaskApplyPacket maskApplyPacket;
    bool maskUsesStencil;
    MaskDrawableKind maskKind;
}

class RecordingBackend : RenderingBackendStub!(BackendEnum.Mock) {
    CommandRecord[] records;
    uint nextHandle;

    override void initializeRenderer() {}
    override void resizeViewportTargets(int width, int height) {}
    override void dumpViewport(ref ubyte[] data, int width, int height) {}
    override void beginScene() {}
    override void endScene() {}
    override void postProcessScene() {}
    override void initializeDrawableResources() {}
    override void bindDrawableVao() {}
    override void createDrawableBuffers(out uint vbo, out uint ibo, out uint dbo) {
        vbo = ++nextHandle;
        ibo = ++nextHandle;
        dbo = ++nextHandle;
    }
    override void uploadDrawableIndices(uint ibo, ushort[] indices) {}
    override void uploadDrawableVertices(uint vbo, vec2[] vertices) {}
    override void uploadDrawableDeform(uint dbo, vec2[] deform) {}
    override void drawDrawableElements(uint ibo, size_t indexCount) {}
    override uint createPartUvBuffer() { return ++nextHandle; }
    override void updatePartUvBuffer(uint buffer, ref MeshData data) {}
    override bool supportsAdvancedBlend() { return false; }
    override bool supportsAdvancedBlendCoherent() { return false; }
    override void setAdvancedBlendCoherent(bool) {}
    override void setLegacyBlendMode(BlendMode) {}
    override void setAdvancedBlendEquation(BlendMode) {}
    override void issueBlendBarrier() {}

    override void drawPartPacket(ref PartDrawPacket packet) {
        records ~= CommandRecord(RenderCommandKind.DrawPart,
            packet,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void drawMaskPacket(ref MaskDrawPacket packet) {
        records ~= CommandRecord(RenderCommandKind.DrawMask,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Mask);
    }

    override void beginDynamicComposite(DynamicCompositePass) {
        records ~= CommandRecord(RenderCommandKind.BeginDynamicComposite,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void endDynamicComposite(DynamicCompositePass) {
        records ~= CommandRecord(RenderCommandKind.EndDynamicComposite,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void destroyDynamicComposite(DynamicCompositeSurface) {
    }

    override void beginMask(bool useStencil) {
        records ~= CommandRecord(RenderCommandKind.BeginMask,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            useStencil,
            MaskDrawableKind.Part);
    }

    override void applyMask(ref MaskApplyPacket packet) {
        records ~= CommandRecord(RenderCommandKind.ApplyMask,
            packet.kind == MaskDrawableKind.Part ? packet.partPacket : PartDrawPacket.init,
            packet,
            false,
            packet.kind);
    }

    override void beginMaskContent() {
        records ~= CommandRecord(RenderCommandKind.BeginMaskContent,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void endMask() {
        records ~= CommandRecord(RenderCommandKind.EndMask,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void beginComposite() {
        records ~= CommandRecord(RenderCommandKind.BeginComposite,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void drawCompositeQuad(ref CompositeDrawPacket packet) {
        records ~= CommandRecord(RenderCommandKind.DrawCompositeQuad,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void endComposite() {
        records ~= CommandRecord(RenderCommandKind.EndComposite,
            PartDrawPacket.init,
            MaskApplyPacket.init,
            false,
            MaskDrawableKind.Part);
    }

    override void drawTextureAtPart(Texture texture, Part part) {}

    override void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                                        vec3 color, vec3 screenColor) {}

    override void drawTextureAtRect(Texture texture, rect area, rect uvs,
                                    float opacity, vec3 color, vec3 screenColor,
                                    Shader shader = null, Camera cam = null) {}

    override RenderShaderHandle createShader(string, string) {
        return null;
    }

    override void destroyShader(RenderShaderHandle) {}

    override void useShader(RenderShaderHandle) {}

    override int getShaderUniformLocation(RenderShaderHandle, string) {
        return -1;
    }

    override void setShaderUniform(RenderShaderHandle, int, bool) {}
    override void setShaderUniform(RenderShaderHandle, int, int) {}
    override void setShaderUniform(RenderShaderHandle, int, float) {}
    override void setShaderUniform(RenderShaderHandle, int, vec2) {}
    override void setShaderUniform(RenderShaderHandle, int, vec3) {}
    override void setShaderUniform(RenderShaderHandle, int, vec4) {}
    override void setShaderUniform(RenderShaderHandle, int, mat4) {}

    override RenderTextureHandle createTextureHandle() {
        return null;
    }

    override void destroyTextureHandle(RenderTextureHandle) {}
    override void bindTextureHandle(RenderTextureHandle, uint) {}
    override void uploadTextureData(RenderTextureHandle, int, int, int, int, bool, ubyte[]) {}
    override void updateTextureRegion(RenderTextureHandle, int, int, int, int, int, ubyte[]) {}
    override void generateTextureMipmap(RenderTextureHandle) {}
    override void applyTextureFiltering(RenderTextureHandle, Filtering) {}
    override void applyTextureWrapping(RenderTextureHandle, Wrapping) {}
    override void applyTextureAnisotropy(RenderTextureHandle, float) {}
    override float maxTextureAnisotropy() { return 1; }
    override void readTextureData(RenderTextureHandle, int, bool, ubyte[]) {}
    override size_t textureNativeHandle(RenderTextureHandle) { return 0; }
}

CommandRecord[] executeFrame(Puppet puppet) {
    inEnsureCameraStackForTests();
    inEnsureViewportForTests();
    auto backend = new RecordingBackend();
    auto queue = new RenderQueue();
    auto graph = new RenderGraphBuilder();
    RenderContext ctx;
    ctx.renderQueue = &queue;
    ctx.renderGraph = &graph;
    ctx.renderBackend = backend;
    ctx.gpuState = RenderGpuState.init;

    auto scheduler = new TaskScheduler();
    if (auto root = puppet.actualRoot()) {
        scheduler.clearTasks();
        root.registerRenderTasks(scheduler);
        graph.beginFrame();
        scheduler.execute(ctx);
    }

    queue.setCommands(graph.takeCommands());
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
    back.opacity = 0.25f;

    auto front = new Part(quad, textures, inCreateUUID(), puppet.root);
    front.name = "Foreground";
    front.zSort = 0.5f;
    front.opacity = 0.75f;

    puppet.rescanNodes();
    auto records = executeFrame(puppet);
    auto drawOpacities = records
        .filter!(r => r.kind == RenderCommandKind.DrawPart)
        .map!(r => r.partPacket.opacity)
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
    auto records = executeFrame(puppet);
    auto compositeDraws = records
        .filter!(r => r.kind == RenderCommandKind.DrawCompositeQuad)
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
