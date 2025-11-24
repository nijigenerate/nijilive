module nijilive.integration.unity;

version (UnityDLL) {

import std.algorithm : min, filter;
import std.array : array;

import nijilive : inUpdate, inSetTimingFunc;
import nijilive.core.runtime_state : initRendererCommon, inSetRenderBackend, inSetViewport;
import nijilive.core.render.backends : RenderBackend, RenderResourceHandle, BackendEnum;
import nijilive.core.render.backends.queue : CommandQueueEmitter, QueuedCommand,
    RenderingBackend;
import nijilive.core.render.shared_deform_buffer :
    sharedVertexBufferData,
    sharedUvBufferData,
    sharedDeformBufferData;
import nijilive.core.render.commands :
    RenderCommandKind,
    MaskDrawableKind,
    PartDrawPacket,
    MaskDrawPacket,
    MaskApplyPacket,
    CompositeDrawPacket,
    DynamicCompositePass;
import nijilive.core.puppet : Puppet;
import nijilive.core.texture : Texture;
import nijilive.math : vec2, vec3, vec4, mat4;

alias RendererHandle = void*;
alias PuppetHandle = void*;

extern(C) enum NjgResult {
    Ok = 0,
    InvalidArgument = 1,
    Failure = 2,
}

extern(C) enum NjgRenderCommandKind : uint {
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
    NjgMaskDrawPacket maskPacket;
    NjgMaskApplyPacket maskApplyPacket;
    NjgCompositeDrawPacket compositePacket;
    NjgDynamicCompositePass dynamicPass;
    bool usesStencil;
}

extern(C) struct CommandQueueView {
    const(NjgQueuedCommand)* commands;
    size_t count;
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

class UnityRenderer {
    RenderBackend backend;
    Puppet[] puppets;
    NjgQueuedCommand[] commandBuffer;
    UnityResourceCallbacks callbacks;
    size_t renderHandle;
    size_t compositeHandle;

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
    result.indexCount = packet.indexCount;
    result.vertexCount = packet.vertexCount;

    auto indices = backend.findIndexBuffer(packet.indexBuffer);
    if (indices.length) {
        result.indices = indices.ptr;
    } else {
        result.indices = null;
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
    result.indexCount = packet.indexCount;
    result.vertexCount = packet.vertexCount;

    auto indices = backend.findIndexBuffer(packet.indexBuffer);
    result.indices = indices.length ? indices.ptr : null;
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
    NjgQueuedCommand outCmd;
    outCmd.kind = cast(NjgRenderCommandKind)cmd.kind;
    outCmd.usesStencil = cmd.usesStencil;
    final switch (cmd.kind) {
        case RenderCommandKind.DrawPart:
            outCmd.partPacket = serializePartPacket(backend, renderer, cmd.payload.partPacket);
            break;
        case RenderCommandKind.DrawMask:
            outCmd.maskPacket = serializeMaskPacket(backend, renderer, cmd.payload.maskPacket);
            break;
        case RenderCommandKind.BeginDynamicComposite:
        case RenderCommandKind.EndDynamicComposite:
            outCmd.dynamicPass = serializeDynamicPass(backend, renderer, cmd.payload.dynamicPass);
            break;
        case RenderCommandKind.BeginMask:
        case RenderCommandKind.BeginMaskContent:
        case RenderCommandKind.EndMask:
        case RenderCommandKind.BeginComposite:
        case RenderCommandKind.DrawCompositeQuad:
        case RenderCommandKind.EndComposite:
            if (cmd.kind == RenderCommandKind.DrawCompositeQuad) {
                auto packet = cmd.payload.compositePacket;
                NjgCompositeDrawPacket composite;
                composite.valid = packet.valid;
                composite.opacity = packet.opacity;
                composite.tint = packet.tint;
                composite.screenTint = packet.screenTint;
                composite.blendingMode = packet.blendingMode;
                outCmd.compositePacket = composite;
            }
            break;
        case RenderCommandKind.ApplyMask:
            NjgMaskApplyPacket apply;
            apply.kind = cmd.payload.maskApplyPacket.kind;
            apply.isDodge = cmd.payload.maskApplyPacket.isDodge;
            apply.partPacket = serializePartPacket(backend, renderer, cmd.payload.maskApplyPacket.partPacket);
            apply.maskPacket = serializeMaskPacket(backend, renderer, cmd.payload.maskApplyPacket.maskPacket);
            outCmd.maskApplyPacket = apply;
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
    foreach (puppet; renderer.puppets) {
        if (puppet is null) continue;
        puppet.draw();
        auto emitter = cast(CommandQueueEmitter)puppet.queueEmitter();
        if (emitter is null) continue;
        foreach (cmd; emitter.queuedCommands()) {
            renderer.commandBuffer ~= serializeCommand(renderer, backend, cmd);
        }
        emitter.clearQueue();
    }

    outView.commands = renderer.commandBuffer.ptr;
    outView.count = renderer.commandBuffer.length;
    return NjgResult.Ok;
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

    return NjgResult.Ok;
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
