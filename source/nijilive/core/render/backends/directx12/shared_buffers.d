module nijilive.core.render.backends.directx12.shared_buffers;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import core.stdc.string : memcpy;
import std.exception : enforce;

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;

import nijilive.core.render.backends : RenderResourceHandle;
import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.dxhelpers;
import nijilive.math : Vec2Array;

enum SharedBufferKind : size_t {
    vertex,
    uv,
    deform,
}

private enum sharedBufferCount = SharedBufferKind.max + 1;

struct SharedBufferEntry {
    DXPtr!ID3D12Resource uploadResource;
    DXPtr!ID3D12Resource defaultResource;
    D3D12_CPU_DESCRIPTOR_HANDLE srvCpuHandle;
    D3D12_GPU_DESCRIPTOR_HANDLE srvGpuHandle;
    size_t sizeInBytes;
    D3D12_RESOURCE_STATES currentState;
}

/// Uploads Vec2Array data into persistent D3D12 upload buffers.
struct SharedBufferUploader {
private:
    DirectX12Device* device;
    ID3D12Device d3dDevice;
    SharedBufferEntry[sharedBufferCount] buffers;

public:
    void attach(DirectX12Device* device) {
        this.device = device;
        d3dDevice = device is null ? null : device.device;
    }

    SharedBufferEntry* entry(SharedBufferKind kind) {
        return &buffers[kind];
    }

    void upload(SharedBufferKind kind, Vec2Array data) {
        if (data.length == 0 || device is null || device.device is null) return;
        auto raw = data.rawStorage();
        if (raw.length == 0) return;
        auto bytes = raw.length * float.sizeof;
        auto entry = &buffers[kind];
        if (entry.uploadResource is null || entry.sizeInBytes < bytes) {
            entry.uploadResource = createUploadBuffer(bytes);
            entry.defaultResource = createDefaultBuffer(bytes);
            entry.sizeInBytes = bytes;
            entry.currentState = D3D12_RESOURCE_STATE_COPY_DEST;
        }

        D3D12_RANGE range = D3D12_RANGE.init;
        void* mapped = null;
        enforceHr(entry.uploadResource.value.Map(0, &range, &mapped), "Failed to map shared upload buffer");
        memcpy(mapped, raw.ptr, bytes);
        entry.uploadResource.value.Unmap(0, null);

        auto cmdList = device.commandList();
        enforce(cmdList !is null, "Command list is not available for shared buffer upload");
        transitionResource(cmdList, entry, D3D12_RESOURCE_STATE_COPY_DEST);
        cmdList.CopyBufferRegion(entry.defaultResource.value, 0, entry.uploadResource.value, 0, bytes);
        transitionResource(cmdList, entry,
            D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE |
            D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE |
            D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER);
        createSrv(entry, kind);
    }

    RenderResourceHandle handle(SharedBufferKind kind) {
        auto res = buffers[kind].defaultResource;
        return res is null ? 0 : cast(RenderResourceHandle)cast(void*)res.value;
    }

    void refreshDescriptors() {
        foreach (kind; [SharedBufferKind.vertex, SharedBufferKind.uv, SharedBufferKind.deform]) {
            createSrv(&buffers[kind], kind);
        }
    }

private:
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
            "CreateCommittedResource for shared upload buffer failed");
        return new DXPtr!ID3D12Resource(rawBuffer);
    }

    DXPtr!ID3D12Resource createDefaultBuffer(size_t bytes) {
        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE_DEFAULT;
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
            D3D12_RESOURCE_STATE_COPY_DEST,
            null,
            iid!ID3D12Resource,
            cast(void**)&rawBuffer),
            "CreateCommittedResource for shared default buffer failed");
        return new DXPtr!ID3D12Resource(rawBuffer);
    }

    void createSrv(SharedBufferEntry* entry, SharedBufferKind kind) {
        if (entry.defaultResource is null || d3dDevice is null) return;
        D3D12_SHADER_RESOURCE_VIEW_DESC desc = D3D12_SHADER_RESOURCE_VIEW_DESC.init;
        desc.ViewDimension = D3D12_SRV_DIMENSION_BUFFER;
        desc.Format = DXGI_FORMAT_UNKNOWN;
        desc.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        desc.Buffer.FirstElement = 0;
        desc.Buffer.NumElements = cast(uint)(entry.sizeInBytes / float.sizeof);
        desc.Buffer.StructureByteStride = float.sizeof;
        desc.Buffer.Flags = D3D12_BUFFER_SRV_FLAG_NONE;

        if (entry.srvCpuHandle.ptr == 0) {
            // SRV handles will be assigned externally via DescriptorPool; keep as zero for now.
            return;
        }
        d3dDevice.CreateShaderResourceView(entry.defaultResource.value, &desc, entry.srvCpuHandle);
    }

    void transitionResource(ID3D12GraphicsCommandList cmdList, SharedBufferEntry* entry,
                            D3D12_RESOURCE_STATES targetState) {
        if (entry.defaultResource is null || entry.currentState == targetState) return;
        D3D12_RESOURCE_BARRIER barrier = D3D12_RESOURCE_BARRIER.init;
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Flags = D3D12_RESOURCE_BARRIER_FLAG_NONE;
        barrier.Transition.pResource = entry.defaultResource.value;
        barrier.Transition.StateBefore = entry.currentState;
        barrier.Transition.StateAfter = targetState;
        barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        cmdList.ResourceBarrier(1, &barrier);
        entry.currentState = targetState;
    }
}

}

}
