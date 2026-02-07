module nijilive.core.render.backends.directx12;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import core.stdc.string : memcpy;
import std.exception : enforce;

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;

import nijilive.core.render.backends;
import nijilive.core.render.backends.directx12.descriptor_heap : DescriptorAllocator;
import nijilive.core.render.backends.directx12.descriptor_pool : DescriptorPool, DescriptorAllocation;
import nijilive.core.render.backends.directx12.constant_buffer_ring : ConstantBufferRing;
import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.frame : registerDirectXFrameHooks;
import nijilive.core.render.backends.directx12.pipeline : PartRootSignature;
import nijilive.core.render.backends.directx12.render_targets : RenderTargets;
import nijilive.core.render.backends.directx12.shared_buffers : SharedBufferUploader, SharedBufferKind, SharedBufferEntry;
import nijilive.core.render.backends.directx12.part_constants : PartVertexConstants, PartPixelConstants;
import nijilive.core.render.backends.directx12.pso_cache : PartPipelineState, PartPipelineMode,
    MaskPipelineState, CompositePipelineState, QuadPipelineState;
import nijilive.core.render.backends.directx12.dxhelpers;
import nijilive.core.runtime_state : inGetCamera, inGetClearColor;
import nijilive.core.render.commands : PartDrawPacket, MaskApplyPacket,
    MaskDrawPacket, DynamicCompositeSurface, DynamicCompositePass;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.nodes.part : Part;
import nijilive.core.texture : Texture;
import nijilive.core.texture_types : Filtering, Wrapping;
import nijilive.core.shader : Shader;
import nijilive.math : vec2, vec3, vec4, rect, mat4, Vec2Array, Vec3Array;
import nijilive.math.camera : Camera;
import nijilive.core.diff_collect : DifferenceEvaluationRegion, DifferenceEvaluationResult;

class DxTextureHandle : RenderTextureHandle {
    DXPtr!ID3D12Resource resource;
    DescriptorAllocation descriptor;
    D3D12_RESOURCE_STATES currentState;
    DXGI_FORMAT format;
    uint width;
    uint height;
    uint channels;
    bool stencil;
    bool renderTarget;
    Filtering filtering = Filtering.Linear;
    Wrapping wrapping = Wrapping.Clamp;
}

/// D3D12 backend skeleton built on top of aurora-directx definitions.
class RenderingBackend(BackendEnum backendType : BackendEnum.DirectX12) {
private:
    DirectX12Device device;
    SharedBufferUploader sharedBuffers;
    DescriptorAllocator rtvDescriptorHeap;
    DescriptorAllocator dsvDescriptorHeap;
    DescriptorPool cbvSrvUavHeap;
    DescriptorAllocation sharedBufferDescriptorTable;
    RenderTargets renderTargets;
    PartRootSignature partRootSignature;
    PartPipelineState partPso;
    MaskPipelineState maskPso;
    CompositePipelineState compositePso;
    QuadPipelineState quadTexturePso;
    ConstantBufferRing constantBufferRing;
    bool rendererInitialized;
    bool descriptorHeapsInitialized;
    DescriptorAllocation partTextureDescriptorTable;
    DxTextureHandle fallbackWhiteTexture;
    int viewportWidth;
    int viewportHeight;
    struct DxIndexBuffer {
        DXPtr!ID3D12Resource resource;
        size_t sizeInBytes;
        size_t indexCount;
    }
    DxIndexBuffer[uint] indexBuffers;
    uint nextIndexBufferHandle = 1;
    enum MaskStage { none, content }
    MaskStage maskStage;
    bool maskWriteActive;
    uint maskStencilRef = 1;
    struct RenderTargetScope {
        D3D12_CPU_DESCRIPTOR_HANDLE[3] rtvs;
        uint rtvCount;
        D3D12_CPU_DESCRIPTOR_HANDLE dsv;
        D3D12_VIEWPORT viewport;
        D3D12_RECT scissor;
    }
    RenderTargetScope currentScope;
    RenderTargetScope[] scopeStack;
    struct MaskVertexConstants {
        mat4 mvp;
        vec4 origin;
    }
    struct DynamicCompositeState {
        DXPtr!ID3D12DescriptorHeap rtvHeap;
        D3D12_CPU_DESCRIPTOR_HANDLE[3] rtvs;
        uint rtvCount;
        int width;
        int height;
    }
    struct QuadVertexConstants {
        mat4 transform;
        vec4 uvRect;
    }

public:
    this() {
        sharedBuffers.attach(&device);
        renderTargets.attach(&device, &rtvDescriptorHeap, &dsvDescriptorHeap, &cbvSrvUavHeap);
        sharedBufferDescriptorTable = DescriptorAllocation.init;
        constantBufferRing.attach(&device);
        registerDirectXFrameHooks(
            (RenderGpuState* state) { beginFrameHook(state); },
            (RenderGpuState* state) { endFrameHook(state); }
        );
    }

    ~this() {
        releaseDxTexture(fallbackWhiteTexture);
        fallbackWhiteTexture = null;
        partRootSignature.shutdown();
        partPso.shutdown();
        maskPso.shutdown();
        compositePso.shutdown();
        quadTexturePso.shutdown();
        constantBufferRing.shutdown();
        renderTargets.release();
        device.shutdown();
    }

    void initializeRenderer() {
        device.initialize(debugLayerEnabled());
        initializeDescriptorHeaps();
        partRootSignature.initialize(&device);
        partPso.initialize(&device, &partRootSignature, &renderTargets);
        maskPso.initialize(&device, &partRootSignature);
        compositePso.initialize(&device, &partRootSignature);
        quadTexturePso.initialize(&device, &partRootSignature,
            import("directx12/quad_vs.hlsl"),
            import("directx12/quad_ps.hlsl"),
            "quad_vs.hlsl",
            "quad_ps.hlsl");
        createSharedBufferDescriptors();
        createFallbackTexture();
        rendererInitialized = true;
    }

    void resizeViewportTargets(int width, int height) {
        viewportWidth = width;
        viewportHeight = height;
        if (descriptorHeapsInitialized) {
            renderTargets.resize(width, height);
        }
    }

    void dumpViewport(ref ubyte[] data, int width, int height) {
        data[0 .. data.length] = 0;
        enforce(false, "DirectX12 dumpViewport is not implemented yet");
    }

    void beginScene() {
        if (!rendererInitialized) return;
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        scopeStack.length = 0;
        auto targetScope = makeMainScope();
        applyScope(targetScope);
        float r, g, b, a;
        inGetClearColor(r, g, b, a);
        float[4] clearColor = [r, g, b, a];
        float[4] clearZero = [0, 0, 0, 0];
        cmdList.ClearRenderTargetView(renderTargets.mainAlbedoRtv(), clearColor.ptr, 0, null);
        cmdList.ClearRenderTargetView(renderTargets.mainEmissiveRtv(), clearZero.ptr, 0, null);
        cmdList.ClearRenderTargetView(renderTargets.mainBumpRtv(), clearZero.ptr, 0, null);
        cmdList.ClearDepthStencilView(renderTargets.depthStencilDsv(),
            D3D12_CLEAR_FLAG_DEPTH | D3D12_CLEAR_FLAG_STENCIL, 1.0f, 1, 0, null);
        maskStage = MaskStage.none;
        maskWriteActive = false;
        maskStencilRef = 1;
    }
    void endScene() {}
    void postProcessScene() {}
    void addBasicLightingPostProcess() {}

    void initializeDrawableResources() {}
    void bindDrawableVao() {}
    void createDrawableBuffers(out uint ibo) {
        ibo = nextIndexBufferHandle++;
        indexBuffers[ibo] = DxIndexBuffer.init;
    }
    void uploadDrawableIndices(uint ibo, ushort[] indices) {
        if (ibo == 0 || indices.length == 0 || device.device is null) return;
        auto entry = ibo in indexBuffers;
        if (entry is null) {
            indexBuffers[ibo] = DxIndexBuffer.init;
            entry = ibo in indexBuffers;
        }
        auto bytes = indices.length * ushort.sizeof;
        if (entry.resource is null || entry.sizeInBytes < bytes) {
            entry.resource = createUploadBuffer(bytes);
            entry.sizeInBytes = bytes;
        }
        D3D12_RANGE range = D3D12_RANGE.init;
        void* mapped = null;
        enforceHr(entry.resource.value.Map(0, &range, &mapped), "Failed to map drawable index buffer");
        memcpy(mapped, indices.ptr, bytes);
        entry.resource.value.Unmap(0, null);
        entry.indexCount = indices.length;
    }

    void uploadSharedVertexBuffer(Vec2Array vertices) {
        if (!rendererInitialized) return;
        sharedBuffers.upload(SharedBufferKind.vertex, vertices);
    }
    void uploadSharedUvBuffer(Vec2Array uvs) {
        if (!rendererInitialized) return;
        sharedBuffers.upload(SharedBufferKind.uv, uvs);
    }
    void uploadSharedDeformBuffer(Vec2Array deform) {
        if (!rendererInitialized) return;
        sharedBuffers.upload(SharedBufferKind.deform, deform);
    }
    void drawDrawableElements(uint ibo, size_t indexCount) {
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        if (!bindIndexBuffer(cmdList, ibo, indexCount)) return;
        cmdList.DrawIndexedInstanced(cast(uint)indexCount, 1, 0, 0, 0);
    }

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
    void setDebugExternalBuffer(uint, uint, int) {}
    void drawDebugPoints(vec4, mat4) {}
    void drawDebugLines(vec4, mat4) {}

    void drawPartPacket(ref PartDrawPacket packet) {
        if (!rendererInitialized || !packet.renderable || packet.indexCount == 0 || packet.vertexCount == 0) return;
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        auto rootSig = partRootSignature.value();
        auto pipeline = partPso.value(currentPartPipelineMode());
        if (rootSig is null || pipeline is null) return;

        cmdList.SetGraphicsRootSignature(rootSig);
        ID3D12DescriptorHeap[] descriptorHeaps = [cbvSrvUavHeap.heapHandle()];
        cmdList.SetDescriptorHeaps(descriptorHeaps.length, descriptorHeaps.ptr);
        cmdList.SetGraphicsRootDescriptorTable(0, sharedBufferDescriptorTable.gpuHandle);
        cmdList.SetGraphicsRootDescriptorTable(1, partTextureDescriptorTable.gpuHandle);
        bindPacketTextures(cmdList, packet.textures);

        PartVertexConstants vertexConsts;
        vertexConsts.modelMatrix = packet.modelMatrix;
        vertexConsts.renderMatrix = packet.renderMatrix;
        vertexConsts.origin = vec4(packet.origin.x, packet.origin.y, 0, 0);
        auto vertexGpu = constantBufferRing.upload(&vertexConsts, PartVertexConstants.sizeof);
        cmdList.SetGraphicsRootConstantBufferView(2, vertexGpu);

        PartPixelConstants pixelConsts;
        pixelConsts.tint = vec4(packet.clampedTint, packet.opacity);
        pixelConsts.screen = vec4(packet.clampedScreen, packet.opacity);
        pixelConsts.extra = vec4(packet.maskThreshold, packet.emissionStrength, packet.isMask ? 1 : 0, 0);
        auto pixelGpu = constantBufferRing.upload(&pixelConsts, PartPixelConstants.sizeof);
        cmdList.SetGraphicsRootConstantBufferView(3, pixelGpu);

        cmdList.SetPipelineState(pipeline);
        cmdList.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        if (!bindSharedVertexBuffers(cmdList, packet)) return;

        cmdList.OMSetStencilRef(maskStencilRef);

        auto iboHandle = cast(uint)packet.indexBuffer;
        if (!bindIndexBuffer(cmdList, iboHandle, packet.indexCount)) return;
        cmdList.DrawIndexedInstanced(cast(uint)packet.indexCount, 1, 0, 0, 0);
    }
    void drawMaskPacket(ref MaskDrawPacket packet) {
        if (!rendererInitialized || packet.indexCount == 0 || packet.vertexCount == 0) return;
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        auto rootSig = partRootSignature.value();
        auto pipeline = maskPso.value();
        if (rootSig is null || pipeline is null) return;

        cmdList.SetGraphicsRootSignature(rootSig);
        ID3D12DescriptorHeap[] descriptorHeaps = [cbvSrvUavHeap.heapHandle()];
        cmdList.SetDescriptorHeaps(descriptorHeaps.length, descriptorHeaps.ptr);
        cmdList.SetGraphicsRootDescriptorTable(0, sharedBufferDescriptorTable.gpuHandle);
        cmdList.SetGraphicsRootDescriptorTable(1, partTextureDescriptorTable.gpuHandle);

        MaskVertexConstants constants;
        constants.mvp = packet.mvp;
        constants.origin = vec4(packet.origin.x, packet.origin.y, 0, 0);
        auto vertexGpu = constantBufferRing.upload(&constants, MaskVertexConstants.sizeof);
        cmdList.SetGraphicsRootConstantBufferView(2, vertexGpu);

        cmdList.SetPipelineState(pipeline);
        cmdList.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        if (!bindMaskVertexBuffers(cmdList, packet)) return;
        cmdList.OMSetStencilRef(maskStencilRef);

        auto iboHandle = cast(uint)packet.indexBuffer;
        if (!bindIndexBuffer(cmdList, iboHandle, packet.indexCount)) return;
        cmdList.DrawIndexedInstanced(cast(uint)packet.indexCount, 1, 0, 0, 0);
    }
    void beginDynamicComposite(DynamicCompositePass pass) {
        if (!rendererInitialized || pass is null || pass.surface is null) return;
        auto surface = pass.surface;
        if (surface.textureCount == 0) return;
        auto state = decodeDynamicCompositeState(surface.framebuffer);
        if (state is null) {
            state = new DynamicCompositeState();
            surface.framebuffer = encodeDynamicCompositeState(state);
        }

        state.rtvCount = surface.textureCount;
        state.width = surface.textureCount > 0 && surface.textures[0] !is null
            ? surface.textures[0].width() : viewportWidth;
        state.height = surface.textureCount > 0 && surface.textures[0] !is null
            ? surface.textures[0].height() : viewportHeight;

        if (state.rtvHeap is null || state.rtvHeap.value is null) {
            D3D12_DESCRIPTOR_HEAP_DESC desc = D3D12_DESCRIPTOR_HEAP_DESC.init;
            desc.NumDescriptors = 3;
            desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
            desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.NONE;
            ID3D12DescriptorHeap rawHeap = null;
            enforceHr(device.device.CreateDescriptorHeap(&desc, iid!ID3D12DescriptorHeap, cast(void**)&rawHeap),
                "CreateDescriptorHeap (dynamic composite RTV) failed");
            state.rtvHeap = new DXPtr!ID3D12DescriptorHeap(rawHeap);
        }

        auto increment = device.device.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        auto baseHandle = state.rtvHeap.value.GetCPUDescriptorHandleForHeapStart();
        auto cmdList = device.commandList();
        foreach (i; 0 .. surface.textureCount) {
            auto tex = surface.textures[i];
            if (tex is null) continue;
            ensureTextureRenderTarget(tex);
            auto handle = requireDxTexture(tex.backendHandle(), __FUNCTION__);
            state.rtvs[i] = baseHandle;
            state.rtvs[i].ptr += i * increment;
            device.device.CreateRenderTargetView(handle.resource.value, null, state.rtvs[i]);
            if (cmdList !is null) {
                transitionTexture(cmdList, handle, D3D12_RESOURCE_STATE_RENDER_TARGET);
            }
        }

        auto targetScope = makeScope(state.rtvs, state.rtvCount, renderTargets.depthStencilDsv(), state.width, state.height);
        pushScope(targetScope);
        float[4] clearZero = [0, 0, 0, 0];
        foreach (i; 0 .. state.rtvCount) {
            cmdList.ClearRenderTargetView(state.rtvs[i], clearZero.ptr, 0, null);
        }
    }
    void endDynamicComposite(DynamicCompositePass pass) {
        if (!rendererInitialized || pass is null || pass.surface is null) return;
        auto surface = pass.surface;
        auto state = decodeDynamicCompositeState(surface.framebuffer);
        if (state is null) {
            popScope();
            return;
        }
        auto cmdList = device.commandList();
        foreach (tex; surface.textures[0 .. surface.textureCount]) {
            if (tex is null) continue;
            auto handle = requireDxTexture(tex.backendHandle(), __FUNCTION__);
            if (cmdList !is null) {
                transitionTexture(cmdList, handle, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
            }
        }
        popScope();

        auto tex = surface.textureCount > 0 ? surface.textures[0] : null;
        if (tex !is null) {
            tex.genMipmap();
        }
    }
    void destroyDynamicComposite(DynamicCompositeSurface surface) {
        auto state = decodeDynamicCompositeState(surface.framebuffer);
        if (state is null) return;
        state.rtvHeap = null;
        surface.framebuffer = 0;
    }
    void beginMask(bool useStencil) {
        if (!rendererInitialized) return;
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        auto dsv = renderTargets.depthStencilDsv();
        auto clearValue = useStencil ? 0u : 1u;
        cmdList.ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_STENCIL, 1.0f, cast(uint)clearValue, 0, null);
        maskStage = MaskStage.none;
        maskWriteActive = false;
        maskStencilRef = 1;
    }
    void applyMask(ref MaskApplyPacket packet) {
        if (!rendererInitialized) return;
        maskWriteActive = true;
        maskStencilRef = packet.isDodge ? 0 : 1;
        final switch (packet.kind) {
            case MaskDrawableKind.Part:
                drawPartPacket(packet.partPacket);
                break;
            case MaskDrawableKind.Mask:
                drawMaskPacket(packet.maskPacket);
                break;
        }
        maskWriteActive = false;
    }
    void beginMaskContent() {
        maskStage = MaskStage.content;
        maskStencilRef = 1;
    }
    void endMask() {
        maskStage = MaskStage.none;
        maskStencilRef = 1;
    }
    void beginComposite() {}
    // CompositeDrawPacket removed; legacy no-op dropped.
    void endComposite() {}

    void drawTextureAtPart(Texture texture, Part part) {
        if (texture is null || part is null) return;
        auto modelMatrix = part.immediateModelMatrix();
        auto renderSpace = part.currentRenderSpace();
        auto quad = mat4.scaling(cast(float)texture.width(), cast(float)texture.height(), 1);
        auto transform = renderSpace.matrix * modelMatrix * quad;
        rect uvRect = rect(0, 0, 1, 1);
        drawTextureWithTransform(texture, transform, uvRect, part.opacity, part.tint, part.screenTint, null);
    }
    void drawTextureAtPosition(Texture texture, vec2 position, float opacity,
                               vec3 color, vec3 screenColor) {
        if (texture is null) return;
        float width = cast(float)texture.width();
        float height = cast(float)texture.height();
        auto translate = mat4.translation(position.x, position.y, 0);
        auto scale = mat4.scaling(width, height, 1);
        auto transform = translate * scale;
        rect uvRect = rect(0, 0, 1, 1);
        drawTextureWithTransform(texture, transform, uvRect, opacity, color, screenColor, null);
    }
    void drawTextureAtRect(Texture texture, rect area, rect uvs, float opacity,
                           vec3 color, vec3 screenColor, Shader shader = null, Camera cam = null) {
        if (texture is null) return;
        auto translate = mat4.translation(area.x + area.width * 0.5f, area.y + area.height * 0.5f, 0);
        auto scale = mat4.scaling(area.width, area.height, 1);
        auto transform = translate * scale;
        drawTextureWithTransform(texture, transform, uvs, opacity, color, screenColor, cam);
    }

    RenderResourceHandle framebufferHandle() { return renderTargets.framebufferHandle(); }
    RenderResourceHandle renderImageHandle() { return renderTargets.renderImageHandle(); }
    RenderResourceHandle compositeFramebufferHandle() { return renderTargets.compositeFramebufferHandle(); }
    RenderResourceHandle compositeImageHandle() { return renderTargets.compositeImageHandle(); }
    RenderResourceHandle mainAlbedoHandle() { return renderTargets.mainAlbedoHandle(); }
    RenderResourceHandle mainEmissiveHandle() { return renderTargets.mainEmissiveHandle(); }
    RenderResourceHandle mainBumpHandle() { return renderTargets.mainBumpHandle(); }
    RenderResourceHandle compositeEmissiveHandle() { return renderTargets.compositeEmissiveHandle(); }
    RenderResourceHandle compositeBumpHandle() { return renderTargets.compositeBumpHandle(); }
    RenderResourceHandle blendFramebufferHandle() { return renderTargets.blendFramebufferHandle(); }
    RenderResourceHandle blendAlbedoHandle() { return renderTargets.blendAlbedoHandle(); }
    RenderResourceHandle blendEmissiveHandle() { return renderTargets.blendEmissiveHandle(); }
    RenderResourceHandle blendBumpHandle() { return renderTargets.blendBumpHandle(); }

    void setDifferenceAggregationEnabled(bool) {}
    bool isDifferenceAggregationEnabled() { return false; }
    void setDifferenceAggregationRegion(DifferenceEvaluationRegion) {}
    DifferenceEvaluationRegion getDifferenceAggregationRegion() {
        return DifferenceEvaluationRegion.init;
    }
    bool evaluateDifferenceAggregation(RenderResourceHandle, int, int) { return false; }
    bool fetchDifferenceAggregationResult(out DifferenceEvaluationResult result) {
        result = DifferenceEvaluationResult.init;
        return false;
    }

    RenderShaderHandle createShader(string, string) {
        enforce(false, "DirectX12 shader creation is not implemented yet");
        return null;
    }
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
        enforce(descriptorHeapsInitialized, "Descriptor heaps are not initialized");
        auto handle = new DxTextureHandle();
        handle.descriptor = cbvSrvUavHeap.allocate(1);
        return handle;
    }
    void destroyTextureHandle(RenderTextureHandle texture) {
        releaseDxTexture(cast(DxTextureHandle)texture);
    }
    void bindTextureHandle(RenderTextureHandle texture, uint unit) {
        if (!descriptorHeapsInitialized || unit >= 3) return;
        auto handle = cast(DxTextureHandle)texture;
        if (handle is null) return;
        if (handle.width == 0 || handle.height == 0) return;
        ensureTextureResource(handle, cast(int)handle.width, cast(int)handle.height, cast(int)handle.channels, handle.stencil);
        createTextureSrv(handle);
        if (!handle.descriptor.valid) return;
        auto dest = partTextureDescriptorTable.cpuAt(unit);
        device.device.CopyDescriptorsSimple(
            1,
            dest,
            handle.descriptor.cpuHandle,
            D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
    }
    void uploadTextureData(RenderTextureHandle texture, int width, int height,
                           int inChannels, int outChannels, bool stencil, ubyte[] data) {
        auto handle = requireDxTexture(texture, __FUNCTION__);
        ensureTextureResource(handle, width, height, outChannels, stencil);
        if (!stencil) {
            auto prepared = prepareTextureData(data, width, height, inChannels, outChannels);
            uploadTextureBytes(handle, prepared, 0, 0, width, height);
        }
    }
    void updateTextureRegion(RenderTextureHandle texture, int x, int y, int width, int height,
                             int channels, ubyte[] data) {
        auto handle = requireDxTexture(texture, __FUNCTION__);
        if (handle.stencil) return;
        auto prepared = prepareTextureData(data, width, height, channels, handle.channels);
        uploadTextureBytes(handle, prepared, x, y, width, height);
    }
    void generateTextureMipmap(RenderTextureHandle) {}
    void applyTextureFiltering(RenderTextureHandle texture, Filtering filtering, bool) {
        auto handle = cast(DxTextureHandle)texture;
        if (handle !is null) {
            handle.filtering = filtering;
        }
    }
    void applyTextureWrapping(RenderTextureHandle texture, Wrapping wrapping) {
        auto handle = cast(DxTextureHandle)texture;
        if (handle !is null) {
            handle.wrapping = wrapping;
        }
    }
    void applyTextureAnisotropy(RenderTextureHandle, float) {}
    float maxTextureAnisotropy() { return 1.0f; }
    void readTextureData(RenderTextureHandle texture, int channels, bool stencil, ubyte[] buffer) {
        auto handle = requireDxTexture(texture, __FUNCTION__);
        if (handle.resource is null || buffer.length == 0) return;
        if (handle.stencil || stencil) {
            buffer[] = 0;
            return;
        }
        auto width = handle.width;
        auto height = handle.height;
        auto bpp = bytesPerPixel(handle.format);
        auto rowSize = cast(size_t)width * bpp;
        auto rowPitch = alignPitch(rowSize);
        auto totalBytes = rowPitch * height;
        auto readback = createReadbackBuffer(totalBytes);

        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT.init;
        footprint.Footprint.Format = handle.format;
        footprint.Footprint.Width = width;
        footprint.Footprint.Height = height;
        footprint.Footprint.Depth = 1;
        footprint.Footprint.RowPitch = cast(uint)rowPitch;

        device.submitUploadCommands((cmdList) {
            transitionTexture(cmdList, handle, D3D12_RESOURCE_STATE_COPY_SOURCE);
            D3D12_TEXTURE_COPY_LOCATION dst = D3D12_TEXTURE_COPY_LOCATION.init;
            dst.pResource = readback.value;
            dst.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            dst.PlacedFootprint = footprint;

            D3D12_TEXTURE_COPY_LOCATION src = D3D12_TEXTURE_COPY_LOCATION.init;
            src.pResource = handle.resource.value;
            src.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            src.SubresourceIndex = 0;

            cmdList.CopyTextureRegion(&dst, 0, 0, 0, &src, null);
            transitionTexture(cmdList, handle, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        });

        D3D12_RANGE range;
        range.Begin = 0;
        range.End = totalBytes;
        void* mapped = null;
        enforceHr(readback.value.Map(0, &range, &mapped), "Failed to map texture readback buffer");
        scope(exit) readback.value.Unmap(0, null);

        enforce(buffer.length >= cast(size_t)width * height * channels, "Texture readback buffer is too small");
        auto srcBase = cast(ubyte*)mapped;
        auto handleChannels = cast(int)(handle.channels == 0 ? bpp : handle.channels);
        foreach (y; 0 .. height) {
            auto rowPtr = srcBase + rowPitch * y;
            foreach (x; 0 .. width) {
                auto src = rowPtr + x * bpp;
                auto dstIndex = (y * width + x) * channels;
                auto copyCount = handleChannels < channels ? handleChannels : channels;
                foreach (c; 0 .. copyCount) {
                    buffer[dstIndex + c] = src[c];
                }
                foreach (c; copyCount .. channels) {
                    buffer[dstIndex + c] = (c == 3) ? 255 : 0;
                }
            }
        }
    }
    size_t textureNativeHandle(RenderTextureHandle texture) {
        auto handle = cast(DxTextureHandle)texture;
        return handle is null || handle.resource is null ? 0 : cast(size_t)cast(void*)handle.resource.value;
    }

private:
    void initializeDescriptorHeaps() {
        if (descriptorHeapsInitialized) return;
        auto dev = device.device;
        enforce(dev !is null, "DirectX12 device is not available");
        rtvDescriptorHeap.initialize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 32);
        dsvDescriptorHeap.initialize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 8);
        cbvSrvUavHeap.initialize(&device, 256);
        descriptorHeapsInitialized = true;
        sharedBufferDescriptorTable = cbvSrvUavHeap.allocate(6);
        partTextureDescriptorTable = cbvSrvUavHeap.allocate(3);
        assignSharedBufferSrvHandles();
        renderTargets.resize(viewportWidth, viewportHeight);
    }

    bool debugLayerEnabled() const {
        version (RenderBackendDxDebug) {
            return true;
        } else {
            return false;
        }
    }

    void beginFrameHook(RenderGpuState* state) {
        if (!rendererInitialized) return;
        device.beginFrame();
        constantBufferRing.reset();
    }

    void endFrameHook(RenderGpuState* state) {
        if (!rendererInitialized) return;
        device.endFrame();
    }

    D3D12_VIEWPORT makeViewport(int width, int height) const {
        D3D12_VIEWPORT viewport;
        viewport.TopLeftX = 0.0f;
        viewport.TopLeftY = 0.0f;
        viewport.Width = cast(float)width;
        viewport.Height = cast(float)height;
        viewport.MinDepth = 0.0f;
        viewport.MaxDepth = 1.0f;
        return viewport;
    }

    D3D12_RECT makeScissor(int width, int height) const {
        D3D12_RECT rect;
        rect.left = 0;
        rect.top = 0;
        rect.right = width;
        rect.bottom = height;
        return rect;
    }

    RenderTargetScope makeScope(D3D12_CPU_DESCRIPTOR_HANDLE[3] rtvs, uint rtvCount,
                                D3D12_CPU_DESCRIPTOR_HANDLE dsv, int width, int height) const {
        RenderTargetScope result;
        result.rtvCount = rtvCount;
        foreach (i; 0 .. rtvCount) {
            result.rtvs[i] = rtvs[i];
        }
        result.dsv = dsv;
        result.viewport = makeViewport(width, height);
        result.scissor = makeScissor(width, height);
        return result;
    }

    RenderTargetScope makeMainScope() const {
        D3D12_CPU_DESCRIPTOR_HANDLE[3] handles;
        handles[0] = renderTargets.mainAlbedoRtv();
        handles[1] = renderTargets.mainEmissiveRtv();
        handles[2] = renderTargets.mainBumpRtv();
        auto dsv = renderTargets.depthStencilDsv();
        return makeScope(handles, 3, dsv, viewportWidth, viewportHeight);
    }

    RenderTargetScope makeCompositeScope() const {
        D3D12_CPU_DESCRIPTOR_HANDLE[3] handles;
        handles[0] = renderTargets.compositeAlbedoRtv();
        handles[1] = renderTargets.compositeEmissiveRtv();
        handles[2] = renderTargets.compositeBumpRtv();
        auto dsv = renderTargets.depthStencilDsv();
        return makeScope(handles, 3, dsv, viewportWidth, viewportHeight);
    }

    RenderTargetScope makeBlendScope() const {
        D3D12_CPU_DESCRIPTOR_HANDLE[3] handles;
        handles[0] = renderTargets.blendAlbedoRtv();
        handles[1] = renderTargets.blendEmissiveRtv();
        handles[2] = renderTargets.blendBumpRtv();
        auto dsv = renderTargets.depthStencilDsv();
        return makeScope(handles, 3, dsv, viewportWidth, viewportHeight);
    }

    void applyScope(ref RenderTargetScope targetScope) {
        auto cmdList = device.commandList();
        if (cmdList is null || targetScope.rtvCount == 0) return;
        auto range = targetScope.rtvs[0 .. targetScope.rtvCount];
        auto dsvPtr = targetScope.dsv.ptr == 0 ? null : &targetScope.dsv;
        cmdList.OMSetRenderTargets(targetScope.rtvCount, range.ptr, true, dsvPtr);
        cmdList.RSSetViewports(1, &targetScope.viewport);
        cmdList.RSSetScissorRects(1, &targetScope.scissor);
        currentScope = targetScope;
    }

    void pushScope(ref RenderTargetScope targetScope) {
        scopeStack ~= currentScope;
        applyScope(targetScope);
    }

    void popScope() {
        if (scopeStack.length == 0) return;
        auto restoreScope = scopeStack[$ - 1];
        scopeStack.length = scopeStack.length - 1;
        applyScope(restoreScope);
    }

    void clearCompositeTargets() {
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        float[4] clearZero = [0, 0, 0, 0];
        cmdList.ClearRenderTargetView(renderTargets.compositeAlbedoRtv(), clearZero.ptr, 0, null);
        cmdList.ClearRenderTargetView(renderTargets.compositeEmissiveRtv(), clearZero.ptr, 0, null);
        cmdList.ClearRenderTargetView(renderTargets.compositeBumpRtv(), clearZero.ptr, 0, null);
    }

    void createSharedBufferDescriptors() {
        if (!descriptorHeapsInitialized) return;
        assignSharedBufferSrvHandles();
        sharedBuffers.refreshDescriptors();
    }

    void assignSharedBufferSrvHandles() {
        if (sharedBufferDescriptorTable.cpuHandle.ptr == 0) return;
        auto vertexEntry = sharedBuffers.entry(SharedBufferKind.vertex);
        vertexEntry.srvCpuHandle = sharedBufferDescriptorTable.cpuAt(0);
        vertexEntry.srvGpuHandle = sharedBufferDescriptorTable.gpuAt(0);
        auto uvEntry = sharedBuffers.entry(SharedBufferKind.uv);
        uvEntry.srvCpuHandle = sharedBufferDescriptorTable.cpuAt(1);
        uvEntry.srvGpuHandle = sharedBufferDescriptorTable.gpuAt(1);
        auto deformEntry = sharedBuffers.entry(SharedBufferKind.deform);
        deformEntry.srvCpuHandle = sharedBufferDescriptorTable.cpuAt(2);
        deformEntry.srvGpuHandle = sharedBufferDescriptorTable.gpuAt(2);
    }

    PartPipelineMode currentPartPipelineMode() const {
        if (maskWriteActive) return PartPipelineMode.maskWrite;
        if (maskStage == MaskStage.content) return PartPipelineMode.maskedContent;
        return PartPipelineMode.standard;
    }

    void drawTextureWithTransform(Texture texture, mat4 transform, rect uvRect,
                                  float opacity, vec3 color, vec3 screenColor, Camera cam) {
        if (!rendererInitialized || texture is null) return;
        auto cmdList = device.commandList();
        if (cmdList is null) return;
        auto rootSig = partRootSignature.value();
        auto pipeline = quadTexturePso.value();
        if (rootSig is null || pipeline is null) return;

        cmdList.SetGraphicsRootSignature(rootSig);
        ID3D12DescriptorHeap[] descriptorHeaps = [cbvSrvUavHeap.heapHandle()];
        cmdList.SetDescriptorHeaps(descriptorHeaps.length, descriptorHeaps.ptr);
        cmdList.SetGraphicsRootDescriptorTable(0, sharedBufferDescriptorTable.gpuHandle);
        cmdList.SetGraphicsRootDescriptorTable(1, partTextureDescriptorTable.gpuHandle);

        auto cameraMatrix = cam is null ? inGetCamera().matrix : cam.matrix;
        QuadVertexConstants vertexConsts;
        vertexConsts.transform = cameraMatrix * transform;
        vertexConsts.uvRect = vec4(uvRect.x, uvRect.y, uvRect.width, uvRect.height);
        auto vertexGpu = constantBufferRing.upload(&vertexConsts, QuadVertexConstants.sizeof);
        cmdList.SetGraphicsRootConstantBufferView(2, vertexGpu);

        PartPixelConstants pixelConsts;
        pixelConsts.tint = vec4(color, opacity);
        pixelConsts.screen = vec4(screenColor, opacity);
        pixelConsts.extra = vec4(0, 0, 0, 0);
        auto pixelGpu = constantBufferRing.upload(&pixelConsts, PartPixelConstants.sizeof);
        cmdList.SetGraphicsRootConstantBufferView(3, pixelGpu);

        bindTextureHandle(texture.backendHandle(), 0);

        cmdList.SetPipelineState(pipeline);
        cmdList.IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        cmdList.DrawInstanced(6, 1, 0, 0);
    }

    DXPtr!ID3D12Resource createUploadBuffer(size_t bytes) {
        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE_UPLOAD;
        heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
        heapProps.CreationNodeMask = 1;
        heapProps.VisibleNodeMask = 1;

        D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = bytes;
        desc.Height = 1;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = DXGI_FORMAT_UNKNOWN;
        desc.SampleDesc.Count = 1;
        desc.SampleDesc.Quality = 0;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        desc.Flags = D3D12_RESOURCE_FLAG_NONE;

        ID3D12Resource rawBuffer = null;
        enforceHr(device.device.CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            D3D12_RESOURCE_STATE_GENERIC_READ,
            null,
            iid!ID3D12Resource,
            cast(void**)&rawBuffer),
            "CreateCommittedResource (index upload buffer) failed");
        return new DXPtr!ID3D12Resource(rawBuffer);
    }

    DXPtr!ID3D12Resource createReadbackBuffer(size_t bytes) {
        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE_READBACK;
        heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
        heapProps.CreationNodeMask = 1;
        heapProps.VisibleNodeMask = 1;

        D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
        desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        desc.Width = bytes;
        desc.Height = 1;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = DXGI_FORMAT_UNKNOWN;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        desc.Flags = D3D12_RESOURCE_FLAG_NONE;

        ID3D12Resource rawBuffer = null;
        enforceHr(device.device.CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            D3D12_RESOURCE_STATE_COPY_DEST,
            null,
            iid!ID3D12Resource,
            cast(void**)&rawBuffer),
            "CreateCommittedResource (readback buffer) failed");
        return new DXPtr!ID3D12Resource(rawBuffer);
    }

    bool bindIndexBuffer(ID3D12GraphicsCommandList cmdList, uint ibo, size_t requiredCount) {
        if (ibo == 0 || requiredCount == 0) return false;
        auto entry = ibo in indexBuffers;
        if (entry is null || entry.resource is null || entry.indexCount < requiredCount) {
            return false;
        }
        D3D12_INDEX_BUFFER_VIEW view = D3D12_INDEX_BUFFER_VIEW.init;
        view.BufferLocation = entry.resource.value.GetGPUVirtualAddress();
        view.SizeInBytes = cast(uint)(entry.indexCount * ushort.sizeof);
        view.Format = DXGI_FORMAT_R16_UINT;
        cmdList.IASetIndexBuffer(&view);
        return true;
    }

    bool bindSharedVertexBuffers(ID3D12GraphicsCommandList cmdList, ref PartDrawPacket packet) {
        if (packet.vertexCount == 0) return false;
        if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) {
            return false;
        }
        auto vertexEntry = sharedBuffers.entry(SharedBufferKind.vertex);
        auto uvEntry = sharedBuffers.entry(SharedBufferKind.uv);
        auto deformEntry = sharedBuffers.entry(SharedBufferKind.deform);
        if (vertexEntry is null || uvEntry is null || deformEntry is null) return false;
        if (vertexEntry.defaultResource is null || uvEntry.defaultResource is null || deformEntry.defaultResource is null) {
            return false;
        }

        D3D12_VERTEX_BUFFER_VIEW[6] views;
        views[0] = makeVertexBufferView(vertexEntry, packet.vertexOffset, packet.vertexCount);
        views[1] = makeVertexBufferView(vertexEntry, packet.vertexAtlasStride + packet.vertexOffset, packet.vertexCount);
        views[2] = makeVertexBufferView(uvEntry, packet.uvOffset, packet.vertexCount);
        views[3] = makeVertexBufferView(uvEntry, packet.uvAtlasStride + packet.uvOffset, packet.vertexCount);
        views[4] = makeVertexBufferView(deformEntry, packet.deformOffset, packet.vertexCount);
        views[5] = makeVertexBufferView(deformEntry, packet.deformAtlasStride + packet.deformOffset, packet.vertexCount);
        cmdList.IASetVertexBuffers(0, views.length, views.ptr);
        return true;
    }

    bool bindMaskVertexBuffers(ID3D12GraphicsCommandList cmdList, ref MaskDrawPacket packet) {
        if (packet.vertexCount == 0) return false;
        if (packet.vertexAtlasStride == 0 || packet.deformAtlasStride == 0) return false;
        auto vertexEntry = sharedBuffers.entry(SharedBufferKind.vertex);
        auto deformEntry = sharedBuffers.entry(SharedBufferKind.deform);
        if (vertexEntry is null || deformEntry is null) return false;
        if (vertexEntry.defaultResource is null || deformEntry.defaultResource is null) return false;

        D3D12_VERTEX_BUFFER_VIEW[4] views;
        views[0] = makeVertexBufferView(vertexEntry, packet.vertexOffset, packet.vertexCount);
        views[1] = makeVertexBufferView(vertexEntry, packet.vertexAtlasStride + packet.vertexOffset, packet.vertexCount);
        views[2] = makeVertexBufferView(deformEntry, packet.deformOffset, packet.vertexCount);
        views[3] = makeVertexBufferView(deformEntry, packet.deformAtlasStride + packet.deformOffset, packet.vertexCount);
        cmdList.IASetVertexBuffers(0, views.length, views.ptr);
        return true;
    }

    D3D12_VERTEX_BUFFER_VIEW makeVertexBufferView(SharedBufferEntry* entry, size_t baseOffsetFloats, size_t vertexCount) {
        D3D12_VERTEX_BUFFER_VIEW view = D3D12_VERTEX_BUFFER_VIEW.init;
        auto resource = entry.defaultResource.value;
        view.BufferLocation = resource.GetGPUVirtualAddress() + baseOffsetFloats * float.sizeof;
        view.StrideInBytes = float.sizeof;
        view.SizeInBytes = cast(uint)(vertexCount * float.sizeof);
        return view;
    }

    DxTextureHandle requireDxTexture(RenderTextureHandle texture, string functionName) {
        auto handle = cast(DxTextureHandle)texture;
        enforce(handle !is null, functionName ~ ": invalid DxTextureHandle");
        enforce(descriptorHeapsInitialized, functionName ~ ": descriptor heap not initialized");
        return handle;
    }

    void ensureTextureRenderTarget(Texture texture) {
        if (texture is null) return;
        auto handle = requireDxTexture(texture.backendHandle(), __FUNCTION__);
        ensureTextureResource(handle, texture.width(), texture.height(), texture.channels(), false, true);
    }

    void releaseDxTexture(DxTextureHandle handle) {
        if (handle is null) return;
        if (descriptorHeapsInitialized && handle.descriptor.valid) {
            cbvSrvUavHeap.free(handle.descriptor);
            handle.descriptor = DescriptorAllocation.init;
        }
        handle.resource = null;
    }

    DynamicCompositeState* decodeDynamicCompositeState(RenderResourceHandle handle) const {
        return handle == 0 ? null : cast(DynamicCompositeState*)cast(size_t)handle;
    }

    RenderResourceHandle encodeDynamicCompositeState(DynamicCompositeState* state) const {
        return state is null ? 0 : cast(RenderResourceHandle)cast(size_t)state;
    }

    void ensureTextureResource(DxTextureHandle handle, int width, int height, int channels, bool stencil, bool forceRenderTarget = false) {
        auto format = selectTextureFormat(channels, stencil);
        bool needsRenderTarget = forceRenderTarget || handle.renderTarget;
        bool allocateNew = handle.resource is null ||
            handle.width != width ||
            handle.height != height ||
            handle.channels != channels ||
            handle.stencil != stencil ||
            handle.format != format ||
            handle.renderTarget != needsRenderTarget;
        if (!allocateNew) return;

        handle.width = cast(uint)width;
        handle.height = cast(uint)height;
        handle.channels = cast(uint)channels;
        handle.stencil = stencil;
        handle.format = format;
        handle.renderTarget = needsRenderTarget;
        handle.resource = createTextureResource(width, height, format, stencil, needsRenderTarget);
        handle.currentState = stencil ? D3D12_RESOURCE_STATE_DEPTH_WRITE
            : (needsRenderTarget ? D3D12_RESOURCE_STATE_RENDER_TARGET : D3D12_RESOURCE_STATE_COPY_DEST);
        createTextureSrv(handle);
    }

    void createTextureSrv(DxTextureHandle handle) {
        if (handle is null || handle.resource is null || handle.stencil) return;
        if (!handle.descriptor.valid) {
            handle.descriptor = cbvSrvUavHeap.allocate(1);
        }
        D3D12_SHADER_RESOURCE_VIEW_DESC desc = D3D12_SHADER_RESOURCE_VIEW_DESC.init;
        desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        desc.Format = handle.format;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        desc.Texture2D.MostDetailedMip = 0;
        desc.Texture2D.MipLevels = 1;
        desc.Texture2D.ResourceMinLODClamp = 0.0f;
        device.device.CreateShaderResourceView(handle.resource.value, &desc, handle.descriptor.cpuHandle);
    }

    DXPtr!ID3D12Resource createTextureResource(int width, int height, DXGI_FORMAT format, bool stencil, bool allowRenderTarget = false) {
        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;
        heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
        heapProps.CreationNodeMask = 1;
        heapProps.VisibleNodeMask = 1;

        D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = cast(uint)width;
        desc.Height = cast(uint)height;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = format;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        if (stencil) {
            desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;
        } else if (allowRenderTarget) {
            desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        } else {
            desc.Flags = D3D12_RESOURCE_FLAG_NONE;
        }

        D3D12_CLEAR_VALUE* clearValue = null;
        D3D12_CLEAR_VALUE depthClear;
        if (stencil) {
            depthClear = D3D12_CLEAR_VALUE.init;
            depthClear.Format = format;
            depthClear.DepthStencil.Depth = 1.0f;
            depthClear.DepthStencil.Stencil = 0;
            clearValue = &depthClear;
        } else if (allowRenderTarget) {
            depthClear = D3D12_CLEAR_VALUE.init;
            depthClear.Format = format;
            depthClear.Color[0] = 0;
            depthClear.Color[1] = 0;
            depthClear.Color[2] = 0;
            depthClear.Color[3] = 0;
            clearValue = &depthClear;
        }

        ID3D12Resource rawResource = null;
        enforceHr(device.device.CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            stencil ? D3D12_RESOURCE_STATE_DEPTH_WRITE
                : (allowRenderTarget ? D3D12_RESOURCE_STATE_RENDER_TARGET : D3D12_RESOURCE_STATE_COPY_DEST),
            clearValue,
            iid!ID3D12Resource,
            cast(void**)&rawResource),
            "CreateCommittedResource (texture) failed");
        return new DXPtr!ID3D12Resource(rawResource);
    }

    DXGI_FORMAT selectTextureFormat(int channels, bool stencil) {
        if (stencil) {
            return DXGI_FORMAT_D24_UNORM_S8_UINT;
        }
        switch (channels) {
            case 1: return DXGI_FORMAT_R8_UNORM;
            case 2: return DXGI_FORMAT_R8G8_UNORM;
            default:
                return DXGI_FORMAT_R8G8B8A8_UNORM;
        }
    }

    size_t bytesPerPixel(DXGI_FORMAT format) {
        final switch (format) {
            case DXGI_FORMAT_R8_UNORM:
                return 1;
            case DXGI_FORMAT_R8G8_UNORM:
                return 2;
            default:
                return 4;
        }
    }

    ubyte[] prepareTextureData(const ubyte[] data, int width, int height, int inChannels, int outChannels) {
        auto required = cast(size_t)width * cast(size_t)height * cast(size_t)inChannels;
        enforce(data.length >= required || required == 0, "Texture upload buffer is too small");
        if (data.length == 0 || inChannels == outChannels) {
            return data.dup;
        }
        auto pixels = cast(size_t)width * cast(size_t)height;
        auto converted = new ubyte[pixels * cast(size_t)outChannels];
        foreach (i; 0 .. pixels) {
            auto srcBase = i * inChannels;
            auto dstBase = i * outChannels;
            auto copyCount = inChannels < outChannels ? inChannels : outChannels;
            foreach (c; 0 .. copyCount) {
                converted[dstBase + c] = data[srcBase + c];
            }
            foreach (c; copyCount .. outChannels) {
                converted[dstBase + c] = (c == 3) ? 255 : 0;
            }
        }
        return converted;
    }

    size_t alignPitch(size_t value) {
        enum size_t alignment = 256;
        return (value + alignment - 1) & ~(alignment - 1);
    }

    void uploadTextureBytes(DxTextureHandle handle, ubyte[] data, uint destX, uint destY, uint width, uint height) {
        if (handle is null || handle.resource is null || width == 0 || height == 0) return;
        auto bpp = bytesPerPixel(handle.format);
        auto rowSize = cast(size_t)width * bpp;
        auto rowPitch = alignPitch(rowSize);
        auto totalBytes = rowPitch * height;
        auto upload = createUploadBuffer(totalBytes);

        D3D12_RANGE range = D3D12_RANGE.init;
        void* mapped = null;
        enforceHr(upload.value.Map(0, &range, &mapped), "Failed to map texture upload buffer");
        auto dstBytes = cast(ubyte*)mapped;
        foreach (row; 0 .. height) {
            auto dst = dstBytes + rowPitch * row;
            auto src = data.ptr + rowSize * row;
            memcpy(dst, src, rowSize);
        }
        upload.value.Unmap(0, null);

        D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint = D3D12_PLACED_SUBRESOURCE_FOOTPRINT.init;
        footprint.Footprint.Width = width;
        footprint.Footprint.Height = height;
        footprint.Footprint.Depth = 1;
        footprint.Footprint.RowPitch = cast(uint)rowPitch;
        footprint.Footprint.Format = handle.format;

        device.submitUploadCommands((cmdList) {
            transitionTexture(cmdList, handle, D3D12_RESOURCE_STATE_COPY_DEST);
            D3D12_TEXTURE_COPY_LOCATION dst = D3D12_TEXTURE_COPY_LOCATION.init;
            dst.pResource = handle.resource.value;
            dst.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            dst.SubresourceIndex = 0;

            D3D12_TEXTURE_COPY_LOCATION src = D3D12_TEXTURE_COPY_LOCATION.init;
            src.pResource = upload.value;
            src.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
            src.PlacedFootprint = footprint;

            cmdList.CopyTextureRegion(&dst, destX, destY, 0, &src, null);
            transitionTexture(cmdList, handle, D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        });
    }

    void transitionTexture(ID3D12GraphicsCommandList cmdList, DxTextureHandle handle, D3D12_RESOURCE_STATES targetState) {
        if (handle.currentState == targetState || handle.resource is null) return;
        D3D12_RESOURCE_BARRIER barrier = D3D12_RESOURCE_BARRIER.init;
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition.pResource = handle.resource.value;
        barrier.Transition.StateBefore = handle.currentState;
        barrier.Transition.StateAfter = targetState;
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        cmdList.ResourceBarrier(1, &barrier);
        handle.currentState = targetState;
    }

    void bindPacketTextures(ID3D12GraphicsCommandList cmdList, Texture[] textures) {
        if (!partTextureDescriptorTable.valid || device.device is null) return;
        foreach (i; 0 .. 3) {
            DxTextureHandle texHandle = fallbackWhiteTexture;
            if (i < textures.length && textures[i] !is null) {
                auto backendHandle = textures[i].backendHandle();
                auto candidate = cast(DxTextureHandle)backendHandle;
                if (candidate !is null && candidate.resource !is null) {
                    texHandle = candidate;
                }
            }
            if (texHandle is null) continue;
            createTextureSrv(texHandle);
            auto srcHandle = texHandle.descriptor.cpuHandle;
            auto dstHandle = partTextureDescriptorTable.cpuAt(i);
            device.device.CopyDescriptorsSimple(
                1,
                dstHandle,
                srcHandle,
                D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        }
        cmdList.SetGraphicsRootDescriptorTable(1, partTextureDescriptorTable.gpuHandle);
    }

    void createFallbackTexture() {
        if (fallbackWhiteTexture !is null || !descriptorHeapsInitialized) return;
        auto handle = cast(DxTextureHandle)createTextureHandle();
        ensureTextureResource(handle, 1, 1, 4, false);
        ubyte[4] white = [255, 255, 255, 255];
        uploadTextureBytes(handle, white[], 0, 0, 1, 1);
        fallbackWhiteTexture = handle;
    }
}

}

}
