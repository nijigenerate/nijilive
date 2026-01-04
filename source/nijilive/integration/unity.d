module nijilive.integration.unity;

version (UnityDLL) {

import std.algorithm : min, filter;
import std.array : array;
import std.stdio : writeln, writefln;

import nijilive : inUpdate, inSetTimingFunc;
import nijilive.core.runtime_state : initRendererCommon, inSetRenderBackend, inSetViewport;
import nijilive.core.render.backends : RenderBackend, RenderResourceHandle, BackendEnum;
import nijilive.core.render.backends.queue : CommandQueueEmitter, QueuedCommand,
    RenderingBackend;
import nijilive.core.render.shared_deform_buffer :
    sharedVertexBufferData,
    sharedUvBufferData,
    sharedDeformBufferData;
import nijilive.core.texture : ngReleaseExternalHandle;
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

extern(C) struct UnityRendererConfig {
    int viewportWidth;
    int viewportHeight;
}

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
    mat4 puppetMatrix;
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

extern(C) struct NjgCompositeDrawPacket {
    bool valid;
    float opacity;
    vec3 tint;
    vec3 screenTint;
    int blendingMode;
}

extern(C) struct NjgDynamicCompositePass {
    size_t[3] textures;
    size_t textureCount;
    size_t stencil;
    vec2 scale;
    float rotationZ;
    RenderResourceHandle origBuffer;
    int[4] origViewport;
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

alias QueueBackend = RenderingBackend!(BackendEnum.OpenGL);

__gshared int logSnapshotCount;
__gshared int logPartPacketCount;
__gshared int logMaskPacketCount;
__gshared int logApplyMaskCount;
__gshared int logMaskFlowCount;

version (UseQueueBackend) {
    extern(C) void unityReleaseExternalHandle(size_t handle) {
        foreach (renderer; activeRenderers) {
            if (renderer is null) continue;
            auto cb = renderer.callbacks;
            if (cb.releaseTexture !is null) {
                cb.releaseTexture(handle, cb.userData);
                return;
            }
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
    size_t frameSeq = 0;
    size_t renderHandle;
    size_t compositeHandle;
    size_t createdTextures;
    size_t releasedTextures;

    this(RenderBackend backend, UnityResourceCallbacks callbacks) {
        this.backend = backend;
        this.callbacks = callbacks;
    }
}

__gshared double unityTimeTicker;
__gshared UnityRenderer[] activeRenderers;

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
    if (renderer.callbacks.createTexture is null || renderer.callbacks.updateTexture is null) {
        return;
    }
    auto w = mutableTex.width();
    auto h = mutableTex.height();
    auto c = mutableTex.channels();
    auto handle = renderer.callbacks.createTexture(w, h, c, 1, c, renderTarget, stencil, renderer.callbacks.userData);
    renderer.createdTextures += 1;
    auto data = mutableTex.getTextureData();
    renderer.callbacks.updateTexture(handle, data.ptr, data.length, w, h, c, renderer.callbacks.userData);
    static if (__traits(compiles, mutableTex.setExternalHandle(0))) {
        mutableTex.setExternalHandle(handle);
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
    result.puppetMatrix = packet.puppetMatrix;
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
        debug (UnityDLLLog) writefln("[nijilive] PartPacket idxHandle=%s idxPtr=%s idxCount=%s vCount=%s vOff/Stride=%s/%s uvOff/Stride=%s/%s deformOff/Stride=%s/%s",
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
        debug (UnityDLLLog) writefln("[nijilive] MaskPacket idxHandle=%s idxPtr=%s idxCount=%s vCount=%s vOff/Stride=%s/%s deformOff/Stride=%s/%s",
            packet.indexBuffer, idxPtr, result.indexCount, result.vertexCount,
            packet.vertexOffset, packet.vertexAtlasStride,
            packet.deformOffset, packet.deformAtlasStride);
        auto dbgIndices = backend.findIndexBuffer(packet.indexBuffer);
        writefln("[nijilive] MaskPacket backend indices len=%s ptr=%s", dbgIndices.length, dbgIndices.length ? cast(size_t)dbgIndices.ptr : 0);
        logMaskPacketCount++;
    }
    return result;
}

private NjgDynamicCompositePass serializeDynamicPass(QueueBackend backend, UnityRenderer renderer, const DynamicCompositePass pass) {
    NjgDynamicCompositePass result;
    if (pass is null) return result;
    result.scale = pass.scale;
    result.rotationZ = pass.rotationZ;
    result.origBuffer = pass.origBuffer;
    result.origViewport = pass.origViewport;
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
        debug (UnityDLLLog) writefln("[nijilive] cmd[%s] kind=%s usesStencil=%s", logCmdSeq, cmd.kind, cmd.usesStencil);
    }
    logCmdSeq++;
    final switch (cmd.kind) {
        case RenderCommandKind.DrawPart:
            outCmd.partPacket = serializePartPacket(backend, renderer, cmd.payload.partPacket);
            break;
        case RenderCommandKind.DrawMask:
            // Queue backend no longer emits DrawMask; keep stub for exhaustive switch.
            break;
        case RenderCommandKind.BeginDynamicComposite:
        case RenderCommandKind.EndDynamicComposite:
            outCmd.dynamicPass = serializeDynamicPass(backend, renderer, cmd.payload.dynamicPass);
            break;
        case RenderCommandKind.BeginMask:
            if (logMaskFlowCount < 200) {
                debug (UnityDLLLog) writefln("[nijilive] BeginMask usesStencil=%s", cmd.usesStencil);
            }
            logMaskFlowCount++;
            break;
        case RenderCommandKind.BeginMaskContent:
            if (logMaskFlowCount < 200) {
                debug (UnityDLLLog) writefln("[nijilive] BeginMaskContent");
            }
            logMaskFlowCount++;
            break;
        case RenderCommandKind.EndMask:
            if (logMaskFlowCount < 200) {
                debug (UnityDLLLog) writefln("[nijilive] EndMask");
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
        // Skip no-op ApplyMask for empty geometry
        if ((apply.kind == MaskDrawableKind.Part &&
             (apply.partPacket.vertexCount == 0 || apply.partPacket.indexCount == 0)) ||
            (apply.kind == MaskDrawableKind.Mask &&
             (apply.maskPacket.vertexCount == 0 || apply.maskPacket.indexCount == 0)))
        {
            if (logApplyMaskCount < 200) {
                debug (UnityDLLLog) writefln("[nijilive] ApplyMask skipped: empty geometry kind=%s part.v=%s/%s mask.v=%s/%s",
                    apply.kind,
                    apply.partPacket.vertexCount, apply.partPacket.indexCount,
                    apply.maskPacket.vertexCount, apply.maskPacket.indexCount);
                logApplyMaskCount++;
            }
            outCmd.kind = NjgRenderCommandKind.EndMask;
            return outCmd;
        }
        outCmd.maskApplyPacket = apply;
        if (logApplyMaskCount < 200) {
            debug (UnityDLLLog) writefln("[nijilive] ApplyMask kind=%s dodge=%s part.v=%s/%s mask.v=%s/%s",
                apply.kind, apply.isDodge,
                apply.partPacket.vertexCount, apply.partPacket.indexCount,
                apply.maskPacket.vertexCount, apply.maskPacket.indexCount);
            logApplyMaskCount++;
        }
        logMaskFlowCount++;
        break;
        case RenderCommandKind.BeginComposite:
        case RenderCommandKind.DrawCompositeQuad:
        case RenderCommandKind.EndComposite:
            // Composite commands are not emitted in the current queue backend.
            break;
}
    return outCmd;
}

extern(C) export NjgResult njgCreateRenderer(const UnityRendererConfig* config,
                                             const UnityResourceCallbacks* callbacks,
                                             RendererHandle* outHandle) {
    if (outHandle is null) return NjgResult.InvalidArgument;
    try {
        initRendererCommon();
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
    } catch (Throwable) {
        *outHandle = null;
        return NjgResult.Failure;
    }
}

extern(C) export void njgDestroyRenderer(RendererHandle handle) {
    if (handle is null) return;
    auto renderer = cast(UnityRenderer)handle;
    activeRenderers = activeRenderers.filter!(r => r !is renderer).array;
    renderer.puppets.length = 0;
    renderer.commandBuffer.length = 0;
}

extern(C) export NjgResult njgLoadPuppet(RendererHandle handle, const char* path, PuppetHandle* outPuppet) {
    if (handle is null || outPuppet is null || path is null) return NjgResult.InvalidArgument;
    auto renderer = cast(UnityRenderer)handle;
    try {
        import std.conv : to;
        import nijilive.fmt : inLoadPuppet;
        auto puppet = inLoadPuppet!Puppet(to!string(path));
        foreach (tex; puppet.textureSlots) {
            if (tex is null) continue;
            ensureTextureHandle(renderer, tex);
        }
        renderer.puppets ~= puppet;
        *outPuppet = cast(PuppetHandle)puppet;
        return NjgResult.Ok;
    } catch (Throwable) {
        *outPuppet = null;
        return NjgResult.Failure;
    }
}

extern(C) export NjgResult njgUnloadPuppet(RendererHandle handle, PuppetHandle puppetHandle) {
    if (handle is null || puppetHandle is null) return NjgResult.InvalidArgument;
    auto renderer = cast(UnityRenderer)handle;
    auto puppet = cast(Puppet)puppetHandle;
    renderer.puppets = renderer.puppets.filter!(p => p !is puppet).array;
    return NjgResult.Ok;
}

extern(C) export NjgResult njgBeginFrame(RendererHandle handle, const FrameConfig* config) {
    if (handle is null) return NjgResult.InvalidArgument;
    auto renderer = cast(UnityRenderer)handle;
    renderer.commandBuffer.length = 0;
    renderer.frameSeq++;
    auto res = setViewport(cast(FrameConfig*)config);
    if (renderer.callbacks.createTexture !is null && config !is null) {
        if (renderer.renderHandle == 0 && config.viewportWidth > 0 && config.viewportHeight > 0) {
            renderer.renderHandle = renderer.callbacks.createTexture(config.viewportWidth, config.viewportHeight, 4, 1, 4, true, false, renderer.callbacks.userData);
            renderer.compositeHandle = renderer.callbacks.createTexture(config.viewportWidth, config.viewportHeight, 4, 1, 4, true, false, renderer.callbacks.userData);
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
    auto puppet = cast(Puppet)puppetHandle;
    unityTimeTicker += deltaSeconds;
    inUpdate();
    puppet.update();
    return NjgResult.Ok;
}

extern(C) export NjgResult njgEmitCommands(RendererHandle handle, CommandQueueView* outView) {
    if (handle is null || outView is null) return NjgResult.InvalidArgument;
    auto renderer = cast(UnityRenderer)handle;
    auto backend = cast(QueueBackend)renderer.backend;
    if (backend is null) return NjgResult.Failure;

    renderer.commandBuffer.length = 0;
    bool maskOpen = false;
    foreach (puppet; renderer.puppets) {
        if (puppet is null) continue;
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
                        if (!maskOpen) debug (UnityDLLLog) writefln("[nijilive] WARN: BeginMaskContent without BeginMask");
                        break;
                    case RenderCommandKind.EndMask:
                        if (!maskOpen) debug (UnityDLLLog) writefln("[nijilive] WARN: EndMask without BeginMask");
                        maskOpen = false;
                        break;
                    case RenderCommandKind.ApplyMask:
                        if (!maskOpen) {
                            debug (UnityDLLLog) writefln("[nijilive] WARN: ApplyMask without BeginMask");
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

    // Dump all commands to temp file for debugging.
    import std.file : append;
    import std.path : buildPath;
    import std.process : environment;
    string temp = environment.get("TEMP", "."); // fallback to cwd
    string path = buildPath(temp, "nijilive_cmd_native.txt");
    import std.array : appender;
    import std.format : formattedWrite;
    auto app = appender!string();
    formattedWrite(app, "Frame %s count=%s\n", renderer.frameSeq, renderer.commandBuffer.length);
    foreach (i, cmd; renderer.commandBuffer) {
        formattedWrite(app, "%s kind=%s usesStencil=%s\n", i, cmd.kind, cmd.usesStencil);
        switch (cmd.kind) {
            case NjgRenderCommandKind.ApplyMask:
                formattedWrite(app, "  apply.kind=%s dodge=%s part.v=%s/%s mask.v=%s/%s\n",
                    cmd.maskApplyPacket.kind, cmd.maskApplyPacket.isDodge,
                    cmd.maskApplyPacket.partPacket.vertexCount, cmd.maskApplyPacket.partPacket.indexCount,
                    cmd.maskApplyPacket.maskPacket.vertexCount, cmd.maskApplyPacket.maskPacket.indexCount);
                break;
            case NjgRenderCommandKind.DrawPart:
                formattedWrite(app, "  part.v=%s/%s isMask=%s\n",
                    cmd.partPacket.vertexCount, cmd.partPacket.indexCount, cmd.partPacket.isMask);
                break;
            default:
                break;
        }
    }
    app.put('\n');
    append(path, app.data);

    outView.commands = renderer.commandBuffer.ptr;
    outView.count = renderer.commandBuffer.length;
    return NjgResult.Ok;
}

/// Clears the native command buffer and requests a GC collection.
/// Call only after the managed side has copied/consumed the commands.
extern(C) export void njgFlushCommandBuffer(RendererHandle handle) {
    if (handle is null) return;
    auto renderer = cast(UnityRenderer)handle;
    renderer.commandBuffer.length = 0;
}

extern(C) export TextureStats njgGetTextureStats(RendererHandle handle) {
    TextureStats stats;
    if (handle is null) return stats;
    auto renderer = cast(UnityRenderer)handle;
    stats.created = renderer.createdTextures;
    stats.released = renderer.releasedTextures;
    stats.current = renderer.createdTextures - renderer.releasedTextures;
    return stats;
}

extern(C) export NjgResult njgGetSharedBuffers(RendererHandle handle, SharedBufferSnapshot* snapshot) {
    if (handle is null || snapshot is null) return NjgResult.InvalidArgument;

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
        debug (UnityDLLLog) writefln("[nijilive] SharedBuffers V:%s(U:%s) ptr=%s U:%s ptr=%s D:%s ptr=%s",
            snapshot.vertexCount, snapshot.vertices.length, cast(size_t)snapshot.vertices.data,
            snapshot.uvCount, cast(size_t)snapshot.uvs.data,
            snapshot.deformCount, cast(size_t)snapshot.deform.data);
        debug {
            import std.algorithm : sort;
            import std.conv : to;
            auto handles = backend.indexBuffers.keys.array;
            handles.sort;
            debug (UnityDLLLog) writefln("[nijilive] Queue index buffers registered=%s", handles.to!string);
        }
        logSnapshotCount++;
    }

    return NjgResult.Ok;
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
    auto puppet = cast(Puppet)puppetHandle;
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
    }
    return NjgResult.Ok;
}

extern(C) export NjgResult njgUpdateParameters(PuppetHandle puppetHandle,
                                               const PuppetParameterUpdate* updates,
                                               size_t updateCount) {
    if (puppetHandle is null) return NjgResult.InvalidArgument;
    auto puppet = cast(Puppet)puppetHandle;
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

}
