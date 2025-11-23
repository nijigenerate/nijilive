module nijilive.core.render.backends.queue;

version (UseQueueBackend) {

version (InDoesRender) {

import nijilive.core.render.command_emitter : RenderCommandEmitter, RenderBackend;
import nijilive.core.render.commands;
import nijilive.core.render.backends : RenderGpuState, RenderResourceHandle,
    RenderTextureHandle, RenderShaderHandle, BackendEnum;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.mask : Mask;
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
import nijilive.math : vec2, vec3, vec4, rect, mat4, Vec2Array, Vec3Array;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;
import nijilive.math.camera : Camera;
import std.algorithm : min;
import std.exception : enforce;

/// Captured command information emitted sequentially.
struct QueuedCommand {
    RenderCommandKind kind;
    union Payload {
        PartDrawPacket partPacket;
        MaskDrawPacket maskPacket;
        MaskApplyPacket maskApplyPacket;
        CompositeDrawPacket compositePacket;
        DynamicCompositePass dynamicPass;
    }
    Payload payload;
    bool usesStencil;
}

/// CommandEmitter implementation that records commands into an in-memory queue.
final class CommandQueueEmitter : RenderCommandEmitter {
private:
    QueuedCommand[] queueData;
    RenderBackend activeBackend;
    RenderGpuState* statePtr;

public:
    void beginFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        statePtr = &state;
        state = RenderGpuState.init;
        queueData.length = 0;
    }

    void drawPart(Part part, bool isMask) {
        if (part is null) return;
        auto packet = makePartDrawPacket(part, isMask);
        record(RenderCommandKind.DrawPart, (ref QueuedCommand cmd) {
            cmd.payload.partPacket = packet;
        });
    }

    void drawMask(Mask mask) {
        if (mask is null) return;
        auto packet = makeMaskDrawPacket(mask);
        record(RenderCommandKind.DrawMask, (ref QueuedCommand cmd) {
            cmd.payload.maskPacket = packet;
        });
    }

    void beginDynamicComposite(DynamicComposite composite, DynamicCompositePass passData) {
        record(RenderCommandKind.BeginDynamicComposite, (ref QueuedCommand cmd) {
            cmd.payload.dynamicPass = passData;
        });
    }

    void endDynamicComposite(DynamicComposite composite, DynamicCompositePass passData) {
        record(RenderCommandKind.EndDynamicComposite, (ref QueuedCommand cmd) {
            cmd.payload.dynamicPass = passData;
        });
    }

    void beginMask(bool useStencil) {
        record(RenderCommandKind.BeginMask, (ref QueuedCommand cmd) {
            cmd.usesStencil = useStencil;
        });
    }

    void applyMask(Drawable drawable, bool isDodge) {
        if (drawable is null) return;
        MaskApplyPacket packet;
        if (!tryMakeMaskApplyPacket(drawable, isDodge, packet)) return;
        record(RenderCommandKind.ApplyMask, (ref QueuedCommand cmd) {
            cmd.payload.maskApplyPacket = packet;
        });
    }

    void beginMaskContent() {
        record(RenderCommandKind.BeginMaskContent, (ref QueuedCommand) {});
    }

    void endMask() {
        record(RenderCommandKind.EndMask, (ref QueuedCommand) {});
    }

    void beginComposite(Composite composite) {
        record(RenderCommandKind.BeginComposite, (ref QueuedCommand) {});
    }

    void drawCompositeQuad(Composite composite) {
        if (composite is null) return;
        auto packet = makeCompositeDrawPacket(composite);
        record(RenderCommandKind.DrawCompositeQuad, (ref QueuedCommand cmd) {
            cmd.payload.compositePacket = packet;
        });
    }

    void endComposite(Composite composite) {
        record(RenderCommandKind.EndComposite, (ref QueuedCommand) {});
    }

    void endFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        statePtr = &state;
    }

    /// Returns a copy of the recorded commands.
    const(QueuedCommand)[] queuedCommands() const {
        return queueData;
    }

    /// Clears all recorded commands.
    void clearQueue() {
        queueData.length = 0;
    }

private:
    void record(RenderCommandKind kind, scope void delegate(ref QueuedCommand) fill) {
        QueuedCommand cmd;
        cmd.kind = kind;
        fill(cmd);
        queueData ~= cmd;
    }
}

/// Minimal render backend that tracks resource handles without issuing GPU work.
class RenderingBackend(BackendEnum backendType : BackendEnum.OpenGL) {
private:
    size_t framebuffer;
    size_t renderImage;
    size_t compositeFramebuffer;
    size_t compositeImage;
    size_t blendFramebuffer;
    size_t blendAlbedo;
    size_t blendEmissive;
    size_t blendBump;
    class QueueTextureHandle : RenderTextureHandle {
        size_t id;
        int width;
        int height;
        int inChannels;
        int outChannels;
        bool stencil;
        Filtering filtering = Filtering.Linear;
        Wrapping wrapping = Wrapping.Clamp;
        float anisotropy = 1.0f;
        ubyte[] data;
    }

    class QueueShaderHandle : RenderShaderHandle { }

    struct IndexBufferData {
        ushort[] indices;
    }

    size_t nextTextureId = 1;
    size_t nextIndexHandle = 1;
    IndexBufferData[RenderResourceHandle] indexBuffers;
    bool differenceAggregationEnabled = false;
    DifferenceEvaluationRegion differenceRegion;
    DifferenceEvaluationResult differenceResult;

    QueueTextureHandle requireTexture(RenderTextureHandle handle) {
        auto tex = cast(QueueTextureHandle)handle;
        enforce(tex !is null, "Invalid QueueTextureHandle provided.");
        return tex;
    }

public:
    void initializeRenderer() {}
    void resizeViewportTargets(int, int) {}
    void dumpViewport(ref ubyte[] data, int width, int height) {
        auto required = cast(size_t)width * cast(size_t)height * 4;
        if (data.length < required) return;
        data[0 .. required] = 0;
    }
    void beginScene() {}
    void endScene() {}
    void postProcessScene() {}

    void initializeDrawableResources() {}
    void bindDrawableVao() {}
    void createDrawableBuffers(out RenderResourceHandle ibo) {
        ibo = nextIndexHandle++;
    }
    void uploadDrawableIndices(RenderResourceHandle ibo, ushort[] indices) {
        indexBuffers[ibo] = IndexBufferData(indices.dup);
    }
    void uploadSharedVertexBuffer(Vec2Array) {}
    void uploadSharedUvBuffer(Vec2Array) {}
    void uploadSharedDeformBuffer(Vec2Array) {}
    void drawDrawableElements(RenderResourceHandle, size_t) {}

    bool supportsAdvancedBlend() { return false; }
    bool supportsAdvancedBlendCoherent() { return false; }
    void setAdvancedBlendCoherent(bool) {}
    void setLegacyBlendMode(BlendMode) {}
    void setAdvancedBlendEquation(BlendMode) {}
    void issueBlendBarrier() {}
    void initDebugRenderer() {}
    void setDebugPointSize(float) {}
    void setDebugLineWidth(float) {}
    void uploadDebugBuffer(Vec3Array, ushort[]) {}
    void setDebugExternalBuffer(size_t, size_t, int) {}
    void drawDebugPoints(vec4, mat4) {}
    void drawDebugLines(vec4, mat4) {}

    void drawPartPacket(ref PartDrawPacket) {}
    void drawMaskPacket(ref MaskDrawPacket) {}
    void beginDynamicComposite(DynamicCompositePass) {}
    void endDynamicComposite(DynamicCompositePass) {}
    void destroyDynamicComposite(DynamicCompositeSurface) {}
    void beginMask(bool) {}
    void applyMask(ref MaskApplyPacket) {}
    void beginMaskContent() {}
    void endMask() {}
    void beginComposite() {}
    void drawCompositeQuad(ref CompositeDrawPacket) {}
    void endComposite() {}
    void drawTextureAtPart(Texture, Part) {}
    void drawTextureAtPosition(Texture, vec2, float, vec3, vec3) {}
    void drawTextureAtRect(Texture, rect, rect, float, vec3, vec3, Shader, Camera) {}

    RenderResourceHandle framebufferHandle() { return framebuffer; }
    RenderResourceHandle renderImageHandle() { return renderImage; }
    RenderResourceHandle compositeFramebufferHandle() { return compositeFramebuffer; }
    RenderResourceHandle compositeImageHandle() { return compositeImage; }
    RenderResourceHandle mainAlbedoHandle() { return renderImage; }
    RenderResourceHandle mainEmissiveHandle() { return renderImage; }
    RenderResourceHandle mainBumpHandle() { return renderImage; }
    RenderResourceHandle compositeEmissiveHandle() { return compositeImage; }
    RenderResourceHandle compositeBumpHandle() { return compositeImage; }
    RenderResourceHandle blendFramebufferHandle() { return blendFramebuffer; }
    RenderResourceHandle blendAlbedoHandle() { return blendAlbedo; }
    RenderResourceHandle blendEmissiveHandle() { return blendEmissive; }
    RenderResourceHandle blendBumpHandle() { return blendBump; }
    void addBasicLightingPostProcess() {}
    void setDifferenceAggregationEnabled(bool enabled) { differenceAggregationEnabled = enabled; }
    bool isDifferenceAggregationEnabled() { return differenceAggregationEnabled; }
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion region) { differenceRegion = region; }
    DifferenceEvaluationRegion getDifferenceAggregationRegion() { return differenceRegion; }
    bool evaluateDifferenceAggregation(size_t, int, int) { return false; }
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        result = differenceResult;
        return false;
    }

    RenderShaderHandle createShader(string, string) { return new QueueShaderHandle(); }
    void destroyShader(RenderShaderHandle) {}
    void useShader(RenderShaderHandle) {}
    int getShaderUniformLocation(RenderShaderHandle, string) { return -1; }
    void setShaderUniform(RenderShaderHandle, int, bool) {}
    void setShaderUniform(RenderShaderHandle, int, int) {}
    void setShaderUniform(RenderShaderHandle, int, float) {}
    void setShaderUniform(RenderShaderHandle, int, vec2) {}
    void setShaderUniform(RenderShaderHandle, int, vec3) {}
    void setShaderUniform(RenderShaderHandle, int, vec4) {}
    void setShaderUniform(RenderShaderHandle, int, mat4) {}

    RenderTextureHandle createTextureHandle() {
        auto handle = new QueueTextureHandle();
        handle.id = nextTextureId++;
        return handle;
    }
    void destroyTextureHandle(RenderTextureHandle texture) {
        if (auto tex = cast(QueueTextureHandle)texture) {
            tex.data = null;
        }
    }
    void bindTextureHandle(RenderTextureHandle, uint) {}
    void uploadTextureData(RenderTextureHandle texture, int width, int height, int inChannels,
                           int outChannels, bool stencil, ubyte[] data) {
        auto tex = requireTexture(texture);
        tex.width = width;
        tex.height = height;
        tex.inChannels = inChannels;
        tex.outChannels = outChannels;
        tex.stencil = stencil;
        auto expected = cast(size_t)width * cast(size_t)height * cast(size_t)outChannels;
        tex.data.length = expected;
        if (expected == 0) return;
        if (data.length) {
            auto copyLen = min(expected, data.length);
            tex.data[0 .. copyLen] = data[0 .. copyLen];
            if (copyLen < expected) {
                tex.data[copyLen .. expected] = 0;
            }
        } else {
            tex.data[] = 0;
        }
    }
    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width, int height,
                             int channels, ubyte[] data) {
        auto tex = requireTexture(texture);
        if (tex.width == 0 || tex.height == 0 || tex.outChannels == 0) return;
        auto expected = cast(size_t)tex.width * tex.height * tex.outChannels;
        if (tex.data.length != expected) {
            tex.data.length = expected;
            tex.data[] = 0;
        }
        for (int row = 0; row < height; ++row) {
            auto dstStart = (cast(size_t)(y + row) * tex.width + x) * tex.outChannels;
            auto srcStart = cast(size_t)row * width * channels;
            auto copyCount = min(cast(size_t)width * tex.outChannels, data.length - srcStart);
            if (dstStart + copyCount > tex.data.length) break;
            if (srcStart + copyCount > data.length) break;
            tex.data[dstStart .. dstStart + copyCount] = data[srcStart .. srcStart + copyCount];
        }
    }
    void generateTextureMipmap(RenderTextureHandle) {}
    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex !is null) tex.filtering = filtering;
    }
    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex !is null) tex.wrapping = wrapping;
    }
    void applyTextureAnisotropy(RenderTextureHandle texture, float value) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex !is null) tex.anisotropy = value;
    }
    float maxTextureAnisotropy() { return 1.0f; }
    void readTextureData(RenderTextureHandle texture, int, bool, ubyte[] buffer) {
        auto tex = cast(QueueTextureHandle)texture;
        if (tex is null || buffer.length == 0) return;
        auto copyLen = min(buffer.length, tex.data.length);
        if (copyLen) {
            buffer[0 .. copyLen] = tex.data[0 .. copyLen];
        }
        if (copyLen < buffer.length) {
            buffer[copyLen .. $] = 0;
        }
    }
    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto tex = cast(QueueTextureHandle)texture;
        return tex is null ? 0 : tex.id;
    }

    package(nijilive) const(ushort)[] findIndexBuffer(RenderResourceHandle handle) {
        if (auto found = handle in indexBuffers) {
            return (*found).indices;
        }
        return null;
    }

    package(nijilive) size_t textureHandleId(RenderTextureHandle texture) {
        return textureNativeHandle(texture);
    }

    package(nijilive) void setRenderTargets(size_t renderHandle, size_t compositeHandle, size_t blendHandle = 0) {
        framebuffer = renderHandle;
        renderImage = renderHandle;
        compositeFramebuffer = compositeHandle;
        compositeImage = compositeHandle;
        blendFramebuffer = blendHandle;
        blendAlbedo = blendHandle;
        blendEmissive = blendHandle;
        blendBump = blendHandle;
    }

    package(nijilive) void overrideTextureId(RenderTextureHandle tex, size_t id) {
        auto q = cast(QueueTextureHandle)tex;
        if (q !is null) q.id = id;
    }
}

}

}
