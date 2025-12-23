module nijilive.core.render.backends.directx12.render_targets;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;

import nijilive.core.render.backends : RenderResourceHandle;
import nijilive.core.render.backends.directx12.descriptor_heap : DescriptorAllocator;
import nijilive.core.render.backends.directx12.descriptor_pool : DescriptorPool, DescriptorAllocation;
import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.dxhelpers;

struct RenderTarget {
    DXPtr!ID3D12Resource resource;
    D3D12_CPU_DESCRIPTOR_HANDLE rtvHandle;

    void release() {
        resource = null;
        rtvHandle.ptr = 0;
    }
}

struct RenderTargetGroup {
    RenderTarget albedo;
    RenderTarget emissive;
    RenderTarget bump;

    void release() {
        albedo.release();
        emissive.release();
        bump.release();
    }
}

struct RenderTargets {
private:
    DirectX12Device* device;
    DescriptorAllocator* rtvAllocator;
    DescriptorAllocator* dsvAllocator;
    DescriptorPool* srvPool;
    RenderTargetGroup mainTargets;
    RenderTargetGroup compositeTargets;
    RenderTargetGroup blendTargets;
    DXPtr!ID3D12Resource depthStencil;
    D3D12_CPU_DESCRIPTOR_HANDLE depthHandle;
    DescriptorAllocation colorSrvTable;
    int width;
    int height;
    enum uint colorTargetCount = 9;

public:
    void attach(DirectX12Device* device, DescriptorAllocator* rtvAlloc,
                DescriptorAllocator* dsvAlloc, DescriptorPool* srvPool) {
        this.device = device;
        rtvAllocator = rtvAlloc;
        dsvAllocator = dsvAlloc;
        this.srvPool = srvPool;
    }

    void resize(int width, int height) {
        if (this.width == width && this.height == height) return;
        release();
        this.width = width;
        this.height = height;
        if (device is null || device.device is null || width <= 0 || height <= 0) {
            return;
        }
        if (rtvAllocator !is null) rtvAllocator.reset();
        if (dsvAllocator !is null) dsvAllocator.reset();
        mainTargets = createColorGroup(width, height);
        compositeTargets = createColorGroup(width, height);
        blendTargets = createColorGroup(width, height);
        createDepthTarget(width, height);
        createColorSrvs();
    }

    void release() {
        mainTargets.release();
        compositeTargets.release();
        blendTargets.release();
        depthStencil = null;
        depthHandle.ptr = 0;
        if (srvPool !is null && colorSrvTable.valid) {
            srvPool.free(colorSrvTable);
        }
        colorSrvTable = DescriptorAllocation.init;
    }

    RenderResourceHandle renderImageHandle() {
        return handleOf(mainTargets.albedo.resource);
    }

    RenderResourceHandle framebufferHandle() {
        return handleOf(depthStencil);
    }

    RenderResourceHandle compositeImageHandle() {
        return handleOf(compositeTargets.albedo.resource);
    }

    RenderResourceHandle compositeFramebufferHandle() {
        return handleOf(depthStencil);
    }

    RenderResourceHandle mainAlbedoHandle() {
        return handleOf(mainTargets.albedo.resource);
    }

    RenderResourceHandle mainEmissiveHandle() {
        return handleOf(mainTargets.emissive.resource);
    }

    RenderResourceHandle mainBumpHandle() {
        return handleOf(mainTargets.bump.resource);
    }

    RenderResourceHandle compositeEmissiveHandle() {
        return handleOf(compositeTargets.emissive.resource);
    }

    RenderResourceHandle compositeBumpHandle() {
        return handleOf(compositeTargets.bump.resource);
    }

    RenderResourceHandle blendFramebufferHandle() {
        return handleOf(depthStencil);
    }

    RenderResourceHandle blendAlbedoHandle() {
        return handleOf(blendTargets.albedo.resource);
    }

    RenderResourceHandle blendEmissiveHandle() {
        return handleOf(blendTargets.emissive.resource);
    }

    RenderResourceHandle blendBumpHandle() {
        return handleOf(blendTargets.bump.resource);
    }

    D3D12_CPU_DESCRIPTOR_HANDLE mainAlbedoRtv() { return mainTargets.albedo.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE mainEmissiveRtv() { return mainTargets.emissive.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE mainBumpRtv() { return mainTargets.bump.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE compositeAlbedoRtv() { return compositeTargets.albedo.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE compositeEmissiveRtv() { return compositeTargets.emissive.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE compositeBumpRtv() { return compositeTargets.bump.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE blendAlbedoRtv() { return blendTargets.albedo.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE blendEmissiveRtv() { return blendTargets.emissive.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE blendBumpRtv() { return blendTargets.bump.rtvHandle; }
    D3D12_CPU_DESCRIPTOR_HANDLE depthStencilDsv() { return depthHandle; }
    D3D12_GPU_DESCRIPTOR_HANDLE mainSrvHandle(uint index) {
        return srvHandleAt(index);
    }
    D3D12_GPU_DESCRIPTOR_HANDLE compositeSrvHandle(uint index) {
        return srvHandleAt(3 + index);
    }
    D3D12_GPU_DESCRIPTOR_HANDLE blendSrvHandle(uint index) {
        return srvHandleAt(6 + index);
    }

private:
    RenderTargetGroup createColorGroup(int width, int height) {
        RenderTargetGroup group;
        group.albedo = createColorTarget(width, height, DXGI_FORMAT_R8G8B8A8_UNORM);
        group.emissive = createColorTarget(width, height, DXGI_FORMAT_R16G16B16A16_FLOAT);
        group.bump = createColorTarget(width, height, DXGI_FORMAT_R16G16B16A16_FLOAT);
        return group;
    }

    RenderTarget createColorTarget(int width, int height, DXGI_FORMAT format) {
        RenderTarget target;
        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;
        heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
        heapProps.CreationNodeMask = 1;
        heapProps.VisibleNodeMask = 1;

        D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = width;
        desc.Height = cast(uint)height;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = format;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;

        D3D12_CLEAR_VALUE clear = D3D12_CLEAR_VALUE.init;
        clear.Format = format;
        clear.Color[0] = 0;
        clear.Color[1] = 0;
        clear.Color[2] = 0;
        clear.Color[3] = 0;

        ID3D12Resource resource = null;
        enforceHr(device.device.CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            D3D12_RESOURCE_STATE_RENDER_TARGET,
            &clear,
            iid!ID3D12Resource,
            cast(void**)&resource
        ), "CreateCommittedResource (color target) failed");
        target.resource = new DXPtr!ID3D12Resource(resource);
        if (rtvAllocator !is null) {
            target.rtvHandle = rtvAllocator.allocate();
            device.device.CreateRenderTargetView(target.resource.value, null, target.rtvHandle);
        }
        return target;
    }

    void createDepthTarget(int width, int height) {
        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;
        heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY_UNKNOWN;
        heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL_UNKNOWN;
        heapProps.CreationNodeMask = 1;
        heapProps.VisibleNodeMask = 1;

        D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
        desc.Dimension = D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        desc.Width = width;
        desc.Height = cast(uint)height;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
        desc.SampleDesc.Count = 1;
        desc.Layout = D3D12_TEXTURE_LAYOUT_UNKNOWN;
        desc.Flags = D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL;

        D3D12_CLEAR_VALUE clear = D3D12_CLEAR_VALUE.init;
        clear.Format = DXGI_FORMAT_D24_UNORM_S8_UINT;
        clear.DepthStencil.Depth = 1.0f;
        clear.DepthStencil.Stencil = 0;

        ID3D12Resource resource = null;
        enforceHr(device.device.CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAG_NONE,
            &desc,
            D3D12_RESOURCE_STATE_DEPTH_WRITE,
            &clear,
            iid!ID3D12Resource,
            cast(void**)&resource
        ), "CreateCommittedResource (depth target) failed");
        depthStencil = new DXPtr!ID3D12Resource(resource);
        if (dsvAllocator !is null) {
            depthHandle = dsvAllocator.allocate();
            device.device.CreateDepthStencilView(depthStencil.value, null, depthHandle);
        }
    }

    RenderResourceHandle handleOf(DXPtr!ID3D12Resource resource) const {
        return resource is null ? 0 : cast(RenderResourceHandle)cast(void*)resource.value;
    }

    void createColorSrvs() {
        if (srvPool is null) return;
        if (!colorSrvTable.valid) {
            colorSrvTable = srvPool.allocate(colorTargetCount);
        }
        if (!colorSrvTable.valid || device is null || device.device is null) return;
        createGroupSrvs(mainTargets, 0);
        createGroupSrvs(compositeTargets, 3);
        createGroupSrvs(blendTargets, 6);
    }

    void createGroupSrvs(ref RenderTargetGroup group, uint offset) {
        createColorSrv(group.albedo, offset + 0);
        createColorSrv(group.emissive, offset + 1);
        createColorSrv(group.bump, offset + 2);
    }

    void createColorSrv(ref RenderTarget target, uint descriptorIndex) {
        if (target.resource is null || !colorSrvTable.valid) return;
        D3D12_SHADER_RESOURCE_VIEW_DESC desc = D3D12_SHADER_RESOURCE_VIEW_DESC.init;
        desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        auto resDesc = target.resource.value.GetDesc();
        desc.Format = resDesc.Format;
        desc.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D;
        desc.Texture2D.MostDetailedMip = 0;
        desc.Texture2D.MipLevels = 1;
        desc.Texture2D.ResourceMinLODClamp = 0.0f;
        auto cpuHandle = colorSrvTable.cpuAt(descriptorIndex);
        device.device.CreateShaderResourceView(target.resource.value, &desc, cpuHandle);
    }

    D3D12_GPU_DESCRIPTOR_HANDLE srvHandleAt(uint index) const {
        if (!colorSrvTable.valid) {
            D3D12_GPU_DESCRIPTOR_HANDLE handle;
            handle.ptr = 0;
            return handle;
        }
        return colorSrvTable.gpuAt(index);
    }
}

}

}
