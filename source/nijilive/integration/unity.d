module nijilive.integration.unity;

version (UnityDLL) {

import std.algorithm : min, filter;
import std.array : array;
import std.stdio : writeln, writefln;
import std.conv : to;
import std.string : fromStringz;
import std.typecons : Nullable;
import std.algorithm.comparison : max;
import nijilive.core.animation.player : AnimationPlayer;
import nijilive.core.param : Parameter;

import nijilive : inUpdate, inSetTimingFunc;
import nijilive.core.runtime_state : initRendererCommon, inSetRenderBackend, inSetViewport, inGetViewport;
import nijilive.core.render.backends : RenderBackend, RenderResourceHandle, BackendEnum;
import nijilive.core.render.backends.queue : CommandQueueEmitter, QueuedCommand,
    RenderingBackend;
import nijilive.core.render.shared_deform_buffer :
    sharedVertexBufferData,
    sharedUvBufferData,
    sharedDeformBufferData;
import nijilive.core.texture : ngReleaseExternalHandle;
import nijilive.core.nodes.composite.projectable : Projectable;
import nijilive.core.render.commands :
    RenderCommandKind,
    MaskDrawableKind,
    MaskDrawPacket,
    PartDrawPacket,
    MaskApplyPacket,
    DynamicCompositePass;
import nijilive.core.puppet : Puppet;
import nijilive.core.texture : Texture;
import nijilive.math : vec2, vec3, vec4, mat4;
import core.memory : GC;

alias RendererHandle = void*;
alias PuppetHandle = void*;

extern(C) enum NjgResult {
    Ok = 0,
    InvalidArgument = 1,
    Failure = 2,
}

extern(C) enum NjgRenderCommandKind : uint {
    DrawPart,
    BeginDynamicComposite,
    EndDynamicComposite,
    BeginMask,
    ApplyMask,
    BeginMaskContent,
    EndMask,
}

extern(C) enum NjgQueryKind : uint {
    Parameters = 1,
}

extern(C) struct UnityRendererConfig {
    int viewportWidth;
    int viewportHeight;
}

extern(C) alias NjgLogFn = void function(const(char)* message, size_t length, void* userData);

extern(C) struct FrameConfig {
    int viewportWidth;
    int viewportHeight;
}

extern(C) struct PuppetParameterUpdate {
    uint parameterUuid;
    vec2 value;
}

extern(C) struct NjgParameterInfo {
    uint uuid;
    bool isVec2;
    vec2 min;
    vec2 max;
    vec2 defaults;
    const(char)* name;
    size_t nameLength;
    vec2 value;
    vec2 latestInternal;
}

extern(C) struct UnityResourceCallbacks {
    void* userData;
    size_t function(int width, int height, int channels, int mipLevels, int format, bool renderTarget, bool stencil, void* userData) createTexture;
    void function(size_t handle, const(ubyte)* data, size_t dataLen, int width, int height, int channels, void* userData) updateTexture;
    void function(size_t handle, void* userData) releaseTexture;
}

extern(C) struct NjgPartDrawPacket {
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
    int blendingMode;
    bool useMultistageBlend;
    bool hasEmissionOrBumpmap;
    size_t[3] textureHandles;
    size_t textureCount;
    vec2 origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t uvOffset;
    size_t uvAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    size_t indexHandle;
    const(ushort)* indices;
    size_t indexCount;
    size_t vertexCount;
}

extern(C) struct NjgMaskDrawPacket {
    mat4 modelMatrix;
    mat4 mvp;
    vec2 origin;
    size_t vertexOffset;
    size_t vertexAtlasStride;
    size_t deformOffset;
    size_t deformAtlasStride;
    size_t indexHandle;
    const(ushort)* indices;
    size_t indexCount;
    size_t vertexCount;
}

extern(C) struct NjgMaskApplyPacket {
    MaskDrawableKind kind;
    bool isDodge;
    NjgPartDrawPacket partPacket;
    NjgMaskDrawPacket maskPacket;
}

extern(C) struct NjgDynamicCompositePass {
    size_t[3] textures;
    size_t textureCount;
    size_t stencil;
    vec2 scale;
    float rotationZ;
    bool autoScaled;
    RenderResourceHandle origBuffer;
    int[4] origViewport;
    int drawBufferCount;
    bool hasStencil;
}

extern(C) struct NjgQueuedCommand {
    NjgRenderCommandKind kind;
    NjgPartDrawPacket partPacket;
    NjgMaskApplyPacket maskApplyPacket;
    NjgDynamicCompositePass dynamicPass;
    bool usesStencil;
}

extern(C) struct CommandQueueView {
    const(NjgQueuedCommand)* commands;
    size_t count;
}

extern(C) struct TextureStats {
    size_t created;
    size_t released;
    size_t current;
}

extern(C) struct NjgRenderTargets {
    size_t renderFramebuffer;
    size_t compositeFramebuffer;
    size_t blendFramebuffer;
    int viewportWidth;
    int viewportHeight;
}

extern(C) struct NjgBufferSlice {
    const(float)* data;
    size_t length;
}

extern(C) struct SharedBufferSnapshot {
    NjgBufferSlice vertices;
    NjgBufferSlice uvs;
    NjgBufferSlice deform;
    size_t vertexCount;
    size_t uvCount;
    size_t deformCount;
}


extern(C) struct NjgWasmLayout {
    uint sizeQueued;
    uint offQueuedPart;
    uint offQueuedMaskApply;
    uint offQueuedDynamic;
    uint offQueuedUsesStencil;

    uint sizePart;
    uint offPartTextureHandles;
    uint offPartTextureCount;
    uint offPartOrigin;
    uint offPartVertexOffset;
    uint offPartVertexStride;
    uint offPartUvOffset;
    uint offPartUvStride;
    uint offPartDeformOffset;
    uint offPartDeformStride;
    uint offPartIndexHandle;
    uint offPartIndicesPtr;
    uint offPartIndexCount;
    uint offPartVertexCount;

    uint sizeMaskDraw;
    uint offMaskDrawIndicesPtr;
    uint offMaskDrawIndexCount;
    uint offMaskDrawVertexOffset;
    uint offMaskDrawVertexStride;
    uint offMaskDrawDeformOffset;
    uint offMaskDrawDeformStride;
    uint offMaskDrawIndexHandle;
    uint offMaskDrawVertexCount;

    uint sizeMaskApply;
    uint offMaskKind;
    uint offMaskIsDodge;
    uint offMaskPartPacket;
    uint offMaskMaskPacket;

    uint sizeDynamicPass;
    uint offDynTextures;
    uint offDynTextureCount;
    uint offDynStencil;
    uint offDynScale;
    uint offDynRotationZ;
    uint offDynAutoScaled;
    uint offDynOrigBuffer;
    uint offDynOrigViewport;
    uint offDynDrawBufferCount;
    uint offDynHasStencil;
}


private UnityRenderer findRenderer(RendererHandle handle) {
    foreach (renderer; activeRenderers) if (cast(void*)renderer == handle) return renderer;
    return null;
}

extern(C) export NjgResult njgGetWasmLayout(NjgWasmLayout* outLayout) {
    if (outLayout is null) return NjgResult.InvalidArgument;

    NjgWasmLayout layout;
    layout.sizeQueued = cast(uint)NjgQueuedCommand.sizeof;
    layout.offQueuedPart = cast(uint)NjgQueuedCommand.partPacket.offsetof;
    layout.offQueuedMaskApply = cast(uint)NjgQueuedCommand.maskApplyPacket.offsetof;
    layout.offQueuedDynamic = cast(uint)NjgQueuedCommand.dynamicPass.offsetof;
    layout.offQueuedUsesStencil = cast(uint)NjgQueuedCommand.usesStencil.offsetof;

    layout.sizePart = cast(uint)NjgPartDrawPacket.sizeof;
    layout.offPartTextureHandles = cast(uint)NjgPartDrawPacket.textureHandles.offsetof;
    layout.offPartTextureCount = cast(uint)NjgPartDrawPacket.textureCount.offsetof;
    layout.offPartOrigin = cast(uint)NjgPartDrawPacket.origin.offsetof;
    layout.offPartVertexOffset = cast(uint)NjgPartDrawPacket.vertexOffset.offsetof;
    layout.offPartVertexStride = cast(uint)NjgPartDrawPacket.vertexAtlasStride.offsetof;
    layout.offPartUvOffset = cast(uint)NjgPartDrawPacket.uvOffset.offsetof;
    layout.offPartUvStride = cast(uint)NjgPartDrawPacket.uvAtlasStride.offsetof;
    layout.offPartDeformOffset = cast(uint)NjgPartDrawPacket.deformOffset.offsetof;
    layout.offPartDeformStride = cast(uint)NjgPartDrawPacket.deformAtlasStride.offsetof;
    layout.offPartIndexHandle = cast(uint)NjgPartDrawPacket.indexHandle.offsetof;
    layout.offPartIndicesPtr = cast(uint)NjgPartDrawPacket.indices.offsetof;
    layout.offPartIndexCount = cast(uint)NjgPartDrawPacket.indexCount.offsetof;
    layout.offPartVertexCount = cast(uint)NjgPartDrawPacket.vertexCount.offsetof;

    layout.sizeMaskDraw = cast(uint)NjgMaskDrawPacket.sizeof;
    layout.offMaskDrawIndicesPtr = cast(uint)NjgMaskDrawPacket.indices.offsetof;
    layout.offMaskDrawIndexCount = cast(uint)NjgMaskDrawPacket.indexCount.offsetof;
    layout.offMaskDrawVertexOffset = cast(uint)NjgMaskDrawPacket.vertexOffset.offsetof;
    layout.offMaskDrawVertexStride = cast(uint)NjgMaskDrawPacket.vertexAtlasStride.offsetof;
    layout.offMaskDrawDeformOffset = cast(uint)NjgMaskDrawPacket.deformOffset.offsetof;
    layout.offMaskDrawDeformStride = cast(uint)NjgMaskDrawPacket.deformAtlasStride.offsetof;
    layout.offMaskDrawIndexHandle = cast(uint)NjgMaskDrawPacket.indexHandle.offsetof;
    layout.offMaskDrawVertexCount = cast(uint)NjgMaskDrawPacket.vertexCount.offsetof;

    layout.sizeMaskApply = cast(uint)NjgMaskApplyPacket.sizeof;
    layout.offMaskKind = cast(uint)NjgMaskApplyPacket.kind.offsetof;
    layout.offMaskIsDodge = cast(uint)NjgMaskApplyPacket.isDodge.offsetof;
    layout.offMaskPartPacket = cast(uint)NjgMaskApplyPacket.partPacket.offsetof;
    layout.offMaskMaskPacket = cast(uint)NjgMaskApplyPacket.maskPacket.offsetof;

    layout.sizeDynamicPass = cast(uint)NjgDynamicCompositePass.sizeof;
    layout.offDynTextures = cast(uint)NjgDynamicCompositePass.textures.offsetof;
    layout.offDynTextureCount = cast(uint)NjgDynamicCompositePass.textureCount.offsetof;
    layout.offDynStencil = cast(uint)NjgDynamicCompositePass.stencil.offsetof;
    layout.offDynScale = cast(uint)NjgDynamicCompositePass.scale.offsetof;
    layout.offDynRotationZ = cast(uint)NjgDynamicCompositePass.rotationZ.offsetof;
    layout.offDynAutoScaled = cast(uint)NjgDynamicCompositePass.autoScaled.offsetof;
    layout.offDynOrigBuffer = cast(uint)NjgDynamicCompositePass.origBuffer.offsetof;
    layout.offDynOrigViewport = cast(uint)NjgDynamicCompositePass.origViewport.offsetof;
    layout.offDynDrawBufferCount = cast(uint)NjgDynamicCompositePass.drawBufferCount.offsetof;
    layout.offDynHasStencil = cast(uint)NjgDynamicCompositePass.hasStencil.offsetof;

    *outLayout = layout;
    return NjgResult.Ok;
}

private Puppet findPuppet(PuppetHandle handle) {
    foreach (renderer; activeRenderers) foreach (puppet; renderer.puppets)
        if (cast(void*)puppet == handle) return puppet;
    return null;
}
private bool ownsPuppet(UnityRenderer renderer, Puppet puppet) {
    foreach (candidate; renderer.puppets) if (candidate is puppet) return true;
    return false;
}

alias QueueBackend = RenderingBackend!(BackendEnum.OpenGL);

__gshared int logSnapshotCount;
__gshared int logPartPacketCount;
__gshared int logMaskPacketCount;
__gshared int logApplyMaskCount;
__gshared int logMaskFlowCount;

version (UseQueueBackend) {
    private struct ExternalTextureOwner { UnityRenderer renderer; size_t handle; Puppet puppet; }
    private __gshared ExternalTextureOwner[size_t] externalTextures;
    private __gshared size_t nextExternalToken = 1;
    extern(C) void unityReleaseExternalHandle(size_t token) {
        auto found = token in externalTextures;
        if (found is null) return;
        auto owner = *found;
        externalTextures.remove(token);
        if (owner.renderer.callbacks.releaseTexture !is null)
            owner.renderer.callbacks.releaseTexture(owner.handle, owner.renderer.callbacks.userData);
        owner.renderer.releasedTextures++;
    }
    private void releaseOwnedTextures(UnityRenderer renderer, Puppet puppet = null) {
        auto tokens = externalTextures.keys;
        foreach (token; tokens) {
            auto owner = externalTextures[token];
            if (owner.renderer is renderer && (puppet is null || owner.puppet is puppet))
                unityReleaseExternalHandle(token);
        }
    }
    shared static this() {
        import nijilive.core.texture : ngReleaseExternalHandle;
        ngReleaseExternalHandle = &unityReleaseExternalHandle;
    }
}

class UnityRenderer {
    RenderBackend backend;
    Puppet[] puppets;
    NjgQueuedCommand[] commandBuffer;
    UnityResourceCallbacks callbacks;
    int viewportWidth;
    int viewportHeight;
    size_t frameSeq = 0;
    size_t renderHandle;
    size_t compositeHandle;
    size_t createdTextures;
    size_t releasedTextures;
    Puppet emittingPuppet;
    AnimationPlayer[Puppet] animPlayers;

    this(RenderBackend backend, UnityResourceCallbacks callbacks) {
        this.backend = backend;
        this.callbacks = callbacks;
    }
}

__gshared double unityTimeTicker;
__gshared UnityRenderer[] activeRenderers;
__gshared NjgLogFn unityLogCallback;
__gshared void* unityLogUserData;
__gshared bool runtimeInitialized;
__gshared bool rendererInitialized;
__gshared bool mainThreadAttached;
private void ensureRuntimeInitialized() {
    njgRuntimeInit();
}

/// Fallback: explicitly register core node types to ensure the AA is created
/// even if module constructors were skipped in the host process.
private void ensureNodeFactoriesBuilt() {
    import nijilive.core.nodes.node : inInitNodes, inHasNodeType;
    import nijilive.core.nodes.drawable : inInitDrawable;
    import nijilive.core.nodes.part : inInitPart;
    import nijilive.core.nodes.mask : inInitMask;
    import nijilive.core.nodes.composite : inInitComposite;
    import nijilive.core.nodes.composite.dcomposite : inInitDComposite;
    import nijilive.core.nodes.meshgroup : inInitMeshGroup;
    import nijilive.core.nodes.deformer.grid : inInitGridDeformer;
    import nijilive.core.nodes.deformer.path : inInitPathDeformer;
    import nijilive.core.param : inParameterSetFactory, Parameter;
    import fghj : deserializeValue;

    // Repeatable: these initializers are idempotent and safe to re-run.
    inInitNodes();
    inInitDrawable();
    inInitPart();
    inInitMask();
    inInitComposite();
    inInitMeshGroup();
    inInitDComposite();
    inInitGridDeformer();
    inInitPathDeformer();
    inParameterSetFactory((data) {
        Parameter param = new Parameter;
        data.deserializeValue(param);
        return param;
    });

    if (!inHasNodeType("Node") || !inHasNodeType("Part")) {
        unityLog("[nijilive] WARN: node registry missing entries after registration");
    }
}

/// Explicit runtime entrypoint to be called by the host before any other API.
extern(C) export void njgRuntimeInit() {
    import core.runtime : Runtime, rt_init;
    import core.thread.osthread : thread_attachThis;
    // Druntime must be initialized before touching any Nijilive state.
    if (!runtimeInitialized) {
        rt_init();
        Runtime.initialize();
        runtimeInitialized = true;
    }
    if (!mainThreadAttached) {
        thread_attachThis();
        mainThreadAttached = true;
    }
    ensureNodeFactoriesBuilt();
    // Report registry state for early diagnostics (after host sets log callback).
    import nijilive.core.nodes.node : inHasNodeType;
    if (unityLogCallback !is null) {
        unityLog("[nijilive] runtime init: Node=" ~ (inHasNodeType("Node") ? "ok" : "missing") ~
                 " Part=" ~ (inHasNodeType("Part") ? "ok" : "missing"));
    }
}

/// Explicit runtime shutdown; optional for hosts that want deterministic teardown.
extern(C) export void njgRuntimeTerm() {
    import core.runtime : Runtime, rt_term;
    if (!runtimeInitialized) return;
    foreach (renderer; activeRenderers.dup) njgDestroyRenderer(cast(void*)renderer);
    rt_term();
    Runtime.terminate();
    runtimeInitialized = false;
    mainThreadAttached = false;
}

void unityLog(string msg) {
    auto cb = unityLogCallback;
    if (cb !is null) {
        cb(msg.ptr, msg.length, unityLogUserData);
    }
}

double unityNowD() {
    return unityTimeTicker;
}
extern(C) double njgUnityNow() {
    return unityNowD();
}

private NjgResult setViewport(FrameConfig* cfg) {
    if (cfg is null) return NjgResult.Ok;
    if (cfg.viewportWidth > 0 && cfg.viewportHeight > 0) {
        inSetViewport(cfg.viewportWidth, cfg.viewportHeight);
    }
    return NjgResult.Ok;
}

private size_t[] textureHandlesFromPacket(QueueBackend backend, UnityRenderer renderer, const(Texture)[] textures) {
    size_t[] handles;
    handles.length = textures.length;
    foreach (i, tex; textures) {
        if (tex is null) {
            handles[i] = 0;
            continue;
        }
        auto handle = (cast(Texture)tex).backendHandle();
        handles[i] = backend.textureHandleId(handle);
    }
    return handles;
}

private void ensureTextureHandle(UnityRenderer renderer, const(Texture) tex, bool renderTarget = false, bool stencil = false) {
    auto mutableTex = cast(Texture)tex;
    static if (__traits(compiles, mutableTex.getExternalHandle())) {
        if (mutableTex.getExternalHandle() != 0) return;
    } else {
        return;
    }
    if (renderer.callbacks.createTexture is null) {
        return;
    }
    auto w = mutableTex.width();
    auto h = mutableTex.height();
    auto c = mutableTex.channels();
    auto handle = renderer.callbacks.createTexture(w, h, c, 1, c, renderTarget, stencil, renderer.callbacks.userData);
    if (handle == 0) return;
    renderer.createdTextures += 1;
    auto token = nextExternalToken++;
    externalTextures[token] = ExternalTextureOwner(renderer, handle, renderer.emittingPuppet);
    auto data = mutableTex.getTextureData();
    if (renderer.callbacks.updateTexture !is null && data.length)
        renderer.callbacks.updateTexture(handle, data.ptr, data.length, w, h, c, renderer.callbacks.userData);
    static if (__traits(compiles, mutableTex.setExternalHandle(0))) {
        mutableTex.setExternalHandle(token);
        auto backend = cast(QueueBackend)renderer.backend;
        if (backend !is null && mutableTex.backendHandle() !is null) {
            backend.overrideTextureId(mutableTex.backendHandle(), handle);
        }
    }
}

private NjgPartDrawPacket serializePartPacket(QueueBackend backend, UnityRenderer renderer, const ref PartDrawPacket packet) {
    NjgPartDrawPacket result;
    result.isMask = packet.isMask;
    result.renderable = packet.renderable;
    result.modelMatrix = packet.modelMatrix;
    result.renderMatrix = packet.renderMatrix;
    result.renderRotation = packet.renderRotation;
    result.clampedTint = packet.clampedTint;
    result.clampedScreen = packet.clampedScreen;
    result.opacity = packet.opacity;
    result.emissionStrength = packet.emissionStrength;
    result.maskThreshold = packet.maskThreshold;
    result.blendingMode = packet.blendingMode;
    result.useMultistageBlend = packet.useMultistageBlend;
    result.hasEmissionOrBumpmap = packet.hasEmissionOrBumpmap;

    auto handles = textureHandlesFromPacket(backend, renderer, packet.textures);
    auto count = min(handles.length, result.textureHandles.length);
    result.textureCount = count;
    foreach (i; 0 .. count) {
        result.textureHandles[i] = handles[i];
    }

    result.origin = packet.origin;
    result.vertexOffset = packet.vertexOffset;
    result.vertexAtlasStride = packet.vertexAtlasStride;
    result.uvOffset = packet.uvOffset;
    result.uvAtlasStride = packet.uvAtlasStride;
    result.deformOffset = packet.deformOffset;
    result.deformAtlasStride = packet.deformAtlasStride;
    result.indexHandle = packet.indexBuffer;

    auto indices = backend.findIndexBuffer(packet.indexBuffer);
    result.indexCount = indices.length ? min(packet.indexCount, indices.length) : 0;
    result.vertexCount = packet.vertexCount;

    if (indices.length && result.indexCount > 0) {
        result.indices = indices.ptr;
    } else {
        // Indices missing: skip draw to avoid out-of-bounds
        result.indices = null;
        result.indexCount = 0;
        result.vertexCount = 0;
    }
    if (logPartPacketCount < 3) {
        auto idxPtr = result.indices is null ? 0 : cast(size_t)result.indices;
        version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] PartPacket idxHandle=%s idxPtr=%s idxCount=%s vCount=%s vOff/Stride=%s/%s uvOff/Stride=%s/%s deformOff/Stride=%s/%s",
            packet.indexBuffer, idxPtr, result.indexCount, result.vertexCount,
            packet.vertexOffset, packet.vertexAtlasStride,
            packet.uvOffset, packet.uvAtlasStride,
            packet.deformOffset, packet.deformAtlasStride);
        logPartPacketCount++;
    }
    return result;
}

private NjgMaskDrawPacket serializeMaskPacket(QueueBackend backend, UnityRenderer renderer, const ref MaskDrawPacket packet) {
    NjgMaskDrawPacket result;
    result.modelMatrix = packet.modelMatrix;
    result.mvp = packet.mvp;
    result.origin = packet.origin;
    result.vertexOffset = packet.vertexOffset;
    result.vertexAtlasStride = packet.vertexAtlasStride;
    result.deformOffset = packet.deformOffset;
    result.deformAtlasStride = packet.deformAtlasStride;
    result.indexHandle = packet.indexBuffer;

    auto indices = backend.findIndexBuffer(packet.indexBuffer);
    result.indexCount = indices.length ? min(packet.indexCount, indices.length) : 0;
    result.vertexCount = packet.vertexCount;

    if (indices.length && result.indexCount > 0) {
        result.indices = indices.ptr;
    } else {
        result.indices = null;
        result.indexCount = 0;
        result.vertexCount = 0;
    }
    if (logMaskPacketCount < 3) {
        auto idxPtr = result.indices is null ? 0 : cast(size_t)result.indices;
        version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] MaskPacket idxHandle=%s idxPtr=%s idxCount=%s vCount=%s vOff/Stride=%s/%s deformOff/Stride=%s/%s",
            packet.indexBuffer, idxPtr, result.indexCount, result.vertexCount,
            packet.vertexOffset, packet.vertexAtlasStride,
            packet.deformOffset, packet.deformAtlasStride);
        logMaskPacketCount++;
    }
    return result;
}

private NjgDynamicCompositePass serializeDynamicPass(QueueBackend backend, UnityRenderer renderer, const DynamicCompositePass pass) {
    NjgDynamicCompositePass result;
    if (pass is null) return result;
    result.scale = pass.scale;
    result.rotationZ = pass.rotationZ;
    result.autoScaled = pass.autoScaled;
    result.origBuffer = pass.origBuffer;
    result.origViewport = pass.origViewport;
    result.drawBufferCount = pass.surface is null ? 0 : cast(int)max(cast(int)pass.surface.textureCount, 1);
    result.hasStencil = pass.surface !is null && pass.surface.stencil !is null;
    // If queue backend didn't capture a viewport, fall back to current viewport for Unity playback.
    if (result.origViewport[2] == 0 || result.origViewport[3] == 0) {
        int vw, vh;
        inGetViewport(vw, vh);
        result.origViewport[0] = 0;
        result.origViewport[1] = 0;
        result.origViewport[2] = vw;
        result.origViewport[3] = vh;
    }
    if (pass.surface !is null) {
        result.textureCount = pass.surface.textureCount;
        foreach (i; 0 .. pass.surface.textures.length) {
            if (i >= result.textures.length) break;
            auto tex = pass.surface.textures[i];
            if (tex !is null) {
                // Ensure Unity-side RenderTexture exists and override handle.
                ensureTextureHandle(renderer, tex, true, false);
                result.textures[i] = backend.textureHandleId((cast(Texture)tex).backendHandle());
            } else {
                result.textures[i] = 0;
            }
        }
        if (pass.surface.stencil !is null) {
            auto stencilTex = cast(Texture)pass.surface.stencil;
            ensureTextureHandle(renderer, stencilTex, true, true);
            result.stencil = backend.textureHandleId(stencilTex.backendHandle());
        }
    }
    return result;
}

private NjgQueuedCommand serializeCommand(UnityRenderer renderer, QueueBackend backend, const(QueuedCommand) cmd) {
    static int logCmdSeq;
    NjgQueuedCommand outCmd;
    outCmd.kind = cast(NjgRenderCommandKind)cmd.kind;
    outCmd.usesStencil = cmd.usesStencil;
    if (logCmdSeq < 400) {
        import std.stdio : writefln;
        version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] cmd[%s] kind=%s usesStencil=%s", logCmdSeq, cmd.kind, cmd.usesStencil);
    }
    logCmdSeq++;
    final switch (cmd.kind) {
        case RenderCommandKind.DrawPart:
            outCmd.partPacket = serializePartPacket(backend, renderer, cmd.payload.partPacket);
            break;
        case RenderCommandKind.BeginDynamicComposite:
        case RenderCommandKind.EndDynamicComposite:
            outCmd.dynamicPass = serializeDynamicPass(backend, renderer, cmd.payload.dynamicPass);
            break;
        case RenderCommandKind.BeginMask:
            if (logMaskFlowCount < 200) {
                version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] BeginMask usesStencil=%s", cmd.usesStencil);
            }
            logMaskFlowCount++;
            break;
        case RenderCommandKind.BeginMaskContent:
            if (logMaskFlowCount < 200) {
                version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] BeginMaskContent");
            }
            logMaskFlowCount++;
            break;
        case RenderCommandKind.EndMask:
            if (logMaskFlowCount < 200) {
                version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] EndMask");
            }
            logMaskFlowCount++;
            break;
        case RenderCommandKind.ApplyMask:
        NjgMaskApplyPacket apply;
        apply.kind = cmd.payload.maskApplyPacket.kind;
        apply.isDodge = cmd.payload.maskApplyPacket.isDodge;
        apply.partPacket = serializePartPacket(backend, renderer, cmd.payload.maskApplyPacket.partPacket);
        // For Part masks, the mask-side packet is unused; only the Part packet is needed.
        if (apply.kind == MaskDrawableKind.Mask) {
            apply.maskPacket = serializeMaskPacket(backend, renderer, cmd.payload.maskApplyPacket.maskPacket);
        }
        outCmd.maskApplyPacket = apply;
        if (logApplyMaskCount < 200) {
            version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] ApplyMask kind=%s dodge=%s part.v=%s/%s mask.v=%s/%s",
                apply.kind, apply.isDodge,
                apply.partPacket.vertexCount, apply.partPacket.indexCount,
                apply.maskPacket.vertexCount, apply.maskPacket.indexCount);
            logApplyMaskCount++;
        }
        logMaskFlowCount++;
        break;
}
    return outCmd;
}

extern(C) export NjgResult njgCreateRenderer(const UnityRendererConfig* config,
                                             const UnityResourceCallbacks* callbacks,
                                             RendererHandle* outHandle) {
    if (config is null || outHandle is null) return NjgResult.InvalidArgument;
    try {
        ensureRuntimeInitialized();
        // Ensure node factories are populated before any renderer setup.
        import nijilive.core.nodes.node : inInitNodes;
        inInitNodes();
        initRendererCommon();
        rendererInitialized = true;
        auto backend = new RenderBackend();
        inSetRenderBackend(backend);
        backend.initializeRenderer();
        unityTimeTicker = 0;
        inSetTimingFunc(&unityNowD);

        if (config !is null && config.viewportWidth > 0 && config.viewportHeight > 0) {
            inSetViewport(config.viewportWidth, config.viewportHeight);
        }

        UnityResourceCallbacks cb = callbacks is null ? UnityResourceCallbacks.init : *cast(UnityResourceCallbacks*)callbacks;
        auto renderer = new UnityRenderer(backend, cb);
        activeRenderers ~= renderer;
        *outHandle = cast(RendererHandle)renderer;
        return NjgResult.Ok;
    } catch (Throwable ex) {
        unityLog("[nijilive] njgCreateRenderer failed: " ~ ex.msg);
        *outHandle = null;
        return NjgResult.Failure;
    }
}

extern(C) export void njgDestroyRenderer(RendererHandle handle) {
    if (handle is null) return;
    auto renderer = findRenderer(handle);
    if (renderer is null) return;
    releaseOwnedTextures(renderer);
    if (renderer.callbacks.releaseTexture !is null) {
        if (renderer.renderHandle) { renderer.callbacks.releaseTexture(renderer.renderHandle, renderer.callbacks.userData); renderer.releasedTextures++; }
        if (renderer.compositeHandle) { renderer.callbacks.releaseTexture(renderer.compositeHandle, renderer.callbacks.userData); renderer.releasedTextures++; }
    }
    renderer.renderHandle = renderer.compositeHandle = 0;
    renderer.animPlayers.clear();
    activeRenderers = activeRenderers.filter!(r => r !is renderer).array;
    renderer.puppets.length = 0;
    renderer.commandBuffer.length = 0;
}

extern(C) export NjgResult njgLoadPuppet(RendererHandle handle, const char* path, PuppetHandle* outPuppet) {
    if (handle is null || outPuppet is null || path is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    try {
        ensureRuntimeInitialized();
        ensureNodeFactoriesBuilt();
        // If renderer init somehow failed earlier, initialize core systems now.
        if (!rendererInitialized) {
            import nijilive.core.nodes.node : inInitNodes;
            inInitNodes();
            initRendererCommon();
            rendererInitialized = true;
        }
        import std.conv : to;
        // Defensive: always initialize node factories before deserialization.
        import nijilive.core.nodes.node : inInitNodes;
        inInitNodes();
        import nijilive.fmt : inLoadPuppet;
        inSetRenderBackend(renderer.backend);
        auto puppet = inLoadPuppet!Puppet(to!string(path));
        renderer.emittingPuppet = puppet;
        scope(exit) renderer.emittingPuppet = null;
        // For DynamicComposite offscreen children, ignore puppet transform like native GL path.
        foreach (proj; puppet.findNodesType!Projectable(puppet.actualRoot())) {
            proj.setIgnorePuppet(true);
        }
        puppet.rescanNodes();
        if (auto root = puppet.actualRoot()) {
            root.build(true);
        }
        foreach (tex; puppet.textureSlots) {
            if (tex is null) continue;
            ensureTextureHandle(renderer, tex);
        }
        renderer.puppets ~= puppet;
        *outPuppet = cast(PuppetHandle)puppet;
        return NjgResult.Ok;
    } catch (Throwable ex) {
        unityLog("[nijilive] njgLoadPuppet failed: " ~ ex.msg);
        *outPuppet = null;
        return NjgResult.Failure;
    }
}

extern(C) export NjgResult njgUnloadPuppet(RendererHandle handle, PuppetHandle puppetHandle) {
    if (handle is null || puppetHandle is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    if (!ownsPuppet(renderer, puppet)) return NjgResult.InvalidArgument;
    renderer.commandBuffer = null;
    if (auto emitter = cast(CommandQueueEmitter)puppet.queueEmitter()) emitter.clearQueue();
    releaseOwnedTextures(renderer, puppet);
    foreach (tex; puppet.textureSlots) if (tex !is null) tex.setExternalHandle(0);
    renderer.puppets = renderer.puppets.filter!(p => p !is puppet).array;
    renderer.animPlayers.remove(puppet);
    return NjgResult.Ok;
}

extern(C) export NjgResult njgBeginFrame(RendererHandle handle, const FrameConfig* config) {
    if (handle is null || config is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    inSetRenderBackend(renderer.backend);
    if (config.viewportWidth != renderer.viewportWidth || config.viewportHeight != renderer.viewportHeight) {
        if (renderer.callbacks.releaseTexture !is null) {
            if (renderer.renderHandle) { renderer.callbacks.releaseTexture(renderer.renderHandle, renderer.callbacks.userData); renderer.releasedTextures++; }
            if (renderer.compositeHandle) { renderer.callbacks.releaseTexture(renderer.compositeHandle, renderer.callbacks.userData); renderer.releasedTextures++; }
        }
        renderer.renderHandle = renderer.compositeHandle = 0;
    }
    renderer.commandBuffer.length = 0;
    renderer.frameSeq++;
    auto res = setViewport(cast(FrameConfig*)config);
    if (config !is null) {
        renderer.viewportWidth = config.viewportWidth;
        renderer.viewportHeight = config.viewportHeight;
    }
    if (renderer.callbacks.createTexture !is null && config !is null) {
        if (renderer.renderHandle == 0 && config.viewportWidth > 0 && config.viewportHeight > 0) {
            renderer.renderHandle = renderer.callbacks.createTexture(config.viewportWidth, config.viewportHeight, 4, 1, 4, true, false, renderer.callbacks.userData);
            renderer.compositeHandle = renderer.callbacks.createTexture(config.viewportWidth, config.viewportHeight, 4, 1, 4, true, false, renderer.callbacks.userData);
            if (renderer.renderHandle) renderer.createdTextures++;
            if (renderer.compositeHandle) renderer.createdTextures++;
            auto backend = cast(QueueBackend)renderer.backend;
            if (backend !is null) {
                backend.setRenderTargets(renderer.renderHandle, renderer.compositeHandle);
            }
        }
    }
    return res;
}

extern(C) export NjgResult njgTickPuppet(PuppetHandle puppetHandle, double deltaSeconds) {
    if (puppetHandle is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    unityTimeTicker += deltaSeconds;
    // External animation control: tick per-puppet AnimationPlayer if present.
    foreach (renderer; activeRenderers) {
        if (renderer is null || !ownsPuppet(renderer, puppet)) continue;
        inSetRenderBackend(renderer.backend);
        if (auto player = puppet in renderer.animPlayers) {
            if (player !is null) {
                player.update(cast(float)deltaSeconds);
            }
        }
    }
    inUpdate();
    puppet.update();
    return NjgResult.Ok;
}

extern(C) export NjgResult njgEmitCommands(RendererHandle handle, CommandQueueView* outView) {
    if (handle is null || outView is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    auto backend = cast(QueueBackend)renderer.backend;
    if (backend is null) return NjgResult.Failure;

    inSetRenderBackend(renderer.backend);
    renderer.commandBuffer.length = 0;
    scope(exit) renderer.emittingPuppet = null;
    bool maskOpen = false;
    foreach (puppet; renderer.puppets) {
        if (puppet is null) continue;
        renderer.emittingPuppet = puppet;
        puppet.draw();
        auto emitter = cast(CommandQueueEmitter)puppet.queueEmitter();
        if (emitter is null) continue;
        auto cmds = emitter.queuedCommands();
        if (cmds.length) {
            renderer.commandBuffer.reserve(renderer.commandBuffer.length + cmds.length);
            foreach (cmd; cmds) {
                switch (cmd.kind) {
                    case RenderCommandKind.BeginMask:
                        maskOpen = true;
                        break;
                    case RenderCommandKind.BeginMaskContent:
                        if (!maskOpen) {
                            version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] WARN: BeginMaskContent without BeginMask");
                            unityLog("[nijilive] WARN: BeginMaskContent without BeginMask");
                        }
                        break;
                    case RenderCommandKind.EndMask:
                        if (!maskOpen) {
                            version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] WARN: EndMask without BeginMask");
                            unityLog("[nijilive] WARN: EndMask without BeginMask");
                        }
                        maskOpen = false;
                        break;
                    case RenderCommandKind.ApplyMask:
                        if (!maskOpen) {
                            version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] WARN: ApplyMask without BeginMask");
                            unityLog("[nijilive] WARN: ApplyMask without BeginMask");
                        }
                        break;
                    default:
                        break;
                }
                renderer.commandBuffer ~= serializeCommand(renderer, backend, cmd);
            }
        }
        emitter.clearQueue();
    }

    outView.commands = renderer.commandBuffer.ptr;
    outView.count = renderer.commandBuffer.length;
    return NjgResult.Ok;
}

/// Clears the native command buffer and requests a GC collection.
/// Call only after the managed side has copied/consumed the commands.
extern(C) export void njgFlushCommandBuffer(RendererHandle handle) {
    if (handle is null) return;
    auto renderer = findRenderer(handle);
    if (renderer is null) return;
    renderer.commandBuffer.length = 0;
}

extern(C) export TextureStats njgGetTextureStats(RendererHandle handle) {
    TextureStats stats;
    if (handle is null) return stats;
    auto renderer = findRenderer(handle);
    if (renderer is null) return stats;
    stats.created = renderer.createdTextures;
    stats.released = renderer.releasedTextures;
    stats.current = renderer.createdTextures - renderer.releasedTextures;
    return stats;
}

extern(C) export NjgRenderTargets njgGetRenderTargets(RendererHandle handle) {
    NjgRenderTargets targets;
    if (handle is null) return targets;
    auto renderer = findRenderer(handle);
    if (renderer is null) return targets;
    targets.renderFramebuffer = renderer.renderHandle;
    targets.compositeFramebuffer = renderer.compositeHandle;
    targets.blendFramebuffer = 0; // queue backend does not manage a dedicated blend FBO
    targets.viewportWidth = renderer.viewportWidth;
    targets.viewportHeight = renderer.viewportHeight;
    return targets;
}

extern(C) export NjgResult njgGetSharedBuffers(RendererHandle handle, SharedBufferSnapshot* snapshot) {
    if (findRenderer(handle) is null || snapshot is null) return NjgResult.InvalidArgument;

    auto vertices = sharedVertexBufferData();
    auto uvs = sharedUvBufferData();
    auto deform = sharedDeformBufferData();

    auto vRaw = vertices.rawStorage();
    snapshot.vertices.data = vRaw.ptr;
    snapshot.vertices.length = vRaw.length;
    snapshot.vertexCount = vertices.length;

    auto uvRaw = uvs.rawStorage();
    snapshot.uvs.data = uvRaw.ptr;
    snapshot.uvs.length = uvRaw.length;
    snapshot.uvCount = uvs.length;

    auto dRaw = deform.rawStorage();
    snapshot.deform.data = dRaw.ptr;
    snapshot.deform.length = dRaw.length;
    snapshot.deformCount = deform.length;
    if (logSnapshotCount < 3) {
        version(NijiliveEnableDebugLog) debug (UnityDLLLog) writefln("[nijilive] SharedBuffers V:%s(U:%s) ptr=%s U:%s ptr=%s D:%s ptr=%s",
            snapshot.vertexCount, snapshot.vertices.length, cast(size_t)snapshot.vertices.data,
            snapshot.uvCount, cast(size_t)snapshot.uvs.data,
            snapshot.deformCount, cast(size_t)snapshot.deform.data);
        logSnapshotCount++;
    }

    return NjgResult.Ok;
}

extern(C) export void njgSetLogCallback(NjgLogFn callback, void* userData) {
    unityLogCallback = callback;
    unityLogUserData = userData;
}

extern(C) export size_t njgGetGcHeapSize() {
    auto stats = GC.stats;
    return stats.usedSize;
}

extern(C) export NjgResult njgGetParameters(PuppetHandle puppetHandle,
                                            NjgParameterInfo* buffer,
                                            size_t bufferLength,
                                            size_t* outCount) {
    if (outCount is null) return NjgResult.InvalidArgument;
    *outCount = 0;
    if (puppetHandle is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto params = puppet.parameters;
    *outCount = params.length;
    if (buffer is null) return NjgResult.Ok;
    if (bufferLength < params.length) return NjgResult.InvalidArgument;

    foreach (i, param; params) {
        buffer[i].uuid = param.uuid;
        buffer[i].isVec2 = param.isVec2;
        buffer[i].min = param.min;
        buffer[i].max = param.max;
        buffer[i].defaults = param.defaults;
        buffer[i].name = param.name.ptr;
        buffer[i].nameLength = param.name.length;
        buffer[i].value = param.value;
        buffer[i].latestInternal = param.latestInternal;
    }
    return NjgResult.Ok;
}

private void fillParameterInfo(ref NjgParameterInfo info, Parameter param) {
    info.uuid = param.uuid;
    info.isVec2 = param.isVec2;
    info.min = param.min;
    info.max = param.max;
    info.defaults = param.defaults;
    info.name = param.name.ptr;
    info.nameLength = param.name.length;
    info.value = param.value;
    info.latestInternal = param.latestInternal;
}

extern(C) export NjgResult njgQuery(void* handle,
                                    NjgQueryKind kind,
                                    void* buffer,
                                    size_t itemSize,
                                    size_t itemCapacity,
                                    size_t* outCount) {
    if (kind != NjgQueryKind.Parameters) return NjgResult.InvalidArgument;
    if (outCount is null) return NjgResult.InvalidArgument;
    *outCount = 0;
    if (handle is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(handle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto params = puppet.parameters;
    *outCount = params.length;
    if (buffer is null) return NjgResult.Ok;
    if (itemSize < NjgParameterInfo.sizeof) return NjgResult.InvalidArgument;
    if (itemCapacity < params.length) return NjgResult.InvalidArgument;

    auto bytes = cast(ubyte*)buffer;
    foreach (i, param; params) {
        auto item = cast(NjgParameterInfo*)(bytes + i * itemSize);
        fillParameterInfo(*item, param);
    }
    return NjgResult.Ok;
}

extern(C) export NjgResult njgUpdateParameters(PuppetHandle puppetHandle,
                                               const PuppetParameterUpdate* updates,
                                               size_t updateCount) {
    if (puppetHandle is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    if (updates is null || updateCount == 0) return NjgResult.Ok;
    foreach (i; 0 .. updateCount) {
        auto update = updates[i];
        auto param = puppet.findParameter(update.parameterUuid);
        if (param !is null) {
            if (param.isVec2) {
                param.value = update.value;
            } else {
                auto current = param.value;
                current.x = update.value.x;
                param.value = current;
            }
        }
    }
    return NjgResult.Ok;
}

extern(C) export NjgResult njgGetPuppetExtData(PuppetHandle puppetHandle,
                                               const char* key,
                                               const(ubyte)** outData,
                                               size_t* outLength) {
    if (puppetHandle is null || key is null || outData is null || outLength is null) {
        return NjgResult.InvalidArgument;
    }
    *outData = null;
    *outLength = 0;

    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto k = fromStringz(key);
    if (!(k in puppet.extData)) {
        return NjgResult.Failure;
    }

    // Keep returned pointer stable until next call.
    static __gshared ubyte[] sExtScratch;
    sExtScratch = puppet.extData[k].dup;
    if (sExtScratch.length == 0) {
        return NjgResult.Failure;
    }

    *outData = sExtScratch.ptr;
    *outLength = sExtScratch.length;
    return NjgResult.Ok;
}

private AnimationPlayer ensureAnimPlayer(UnityRenderer renderer, Puppet puppet) {
    if (renderer is null || puppet is null || !ownsPuppet(renderer, puppet)) return null;
    auto found = puppet in renderer.animPlayers;
    if (found !is null) return *found;
    auto player = new AnimationPlayer(puppet);
    renderer.animPlayers[puppet] = player;
    return player;
}

extern(C) export NjgResult njgPlayAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, bool loop, bool playLeadOut) {
    if (handle is null || puppetHandle is null || name is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto animName = to!string(name);
    auto player = ensureAnimPlayer(renderer, puppet);
    if (player is null) return NjgResult.Failure;
    auto playback = player.createOrGet(animName);
    if (playback is null) {
        unityLog("[nijilive] njgPlayAnimation failed: animation not found name=" ~ animName);
        return NjgResult.InvalidArgument;
    }
    playback.play(loop, playLeadOut);
    return NjgResult.Ok;
}

extern(C) export NjgResult njgPauseAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name) {
    if (handle is null || puppetHandle is null || name is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto animName = to!string(name);
    auto player = ensureAnimPlayer(renderer, puppet);
    if (player is null) return NjgResult.Failure;
    auto playback = player.createOrGet(animName);
    if (playback is null) {
        unityLog("[nijilive] njgPauseAnimation failed: animation not found name=" ~ animName);
        return NjgResult.InvalidArgument;
    }
    playback.pause();
    return NjgResult.Ok;
}

extern(C) export NjgResult njgStopAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, bool immediate) {
    if (handle is null || puppetHandle is null || name is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto animName = to!string(name);
    auto player = ensureAnimPlayer(renderer, puppet);
    if (player is null) return NjgResult.Failure;
    auto playback = player.createOrGet(animName);
    if (playback is null) {
        unityLog("[nijilive] njgStopAnimation failed: animation not found name=" ~ animName);
        return NjgResult.InvalidArgument;
    }
    playback.stop(immediate);
    return NjgResult.Ok;
}

extern(C) export NjgResult njgSeekAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, int frame) {
    if (handle is null || puppetHandle is null || name is null) return NjgResult.InvalidArgument;
    auto renderer = findRenderer(handle);
    if (renderer is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    auto animName = to!string(name);
    auto player = ensureAnimPlayer(renderer, puppet);
    if (player is null) return NjgResult.Failure;
    auto playback = player.createOrGet(animName);
    if (playback is null) {
        unityLog("[nijilive] njgSeekAnimation failed: animation not found name=" ~ animName);
        return NjgResult.InvalidArgument;
    }
    playback.seek(frame);
    return NjgResult.Ok;
}

/// Set puppet scale (x, y). Does not affect physics, only render transform.
extern(C) export NjgResult njgSetPuppetScale(PuppetHandle puppetHandle, float sx, float sy) {
    if (puppetHandle is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    puppet.transform.scale = vec2(sx, sy);
    puppet.transform.update();
    if (auto root = puppet.getPuppetRootNode()) {
        root.transformChanged();
    }
    return NjgResult.Ok;
}

/// Set puppet translation (x, y). Does not affect physics, only render transform.
extern(C) export NjgResult njgSetPuppetTranslation(PuppetHandle puppetHandle, float tx, float ty) {
    if (puppetHandle is null) return NjgResult.InvalidArgument;
    auto puppet = findPuppet(puppetHandle);
    if (puppet is null) return NjgResult.InvalidArgument;
    puppet.transform.translation.x = tx;
    puppet.transform.translation.y = ty;
    puppet.transform.update();
    if (auto root = puppet.getPuppetRootNode()) {
        root.transformChanged();
    }
    return NjgResult.Ok;
}

}
