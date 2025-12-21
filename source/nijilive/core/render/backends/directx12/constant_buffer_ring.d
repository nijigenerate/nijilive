module nijilive.core.render.backends.directx12.constant_buffer_ring;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import core.stdc.string : memcpy;
import std.algorithm : max;
import std.exception : enforce;

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;

import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.dxhelpers;

/// Upload-type CBV ring buffer reused within a frame
struct ConstantBufferRing {
private:
    DirectX12Device* device;
    DXPtr!ID3D12Resource buffer;
    ubyte* mappedPtr;
    size_t capacity;
    size_t cursor;

public:
    void attach(DirectX12Device* device) {
        this.device = device;
    }

    void reset() {
        cursor = 0;
    }

    D3D12_GPU_VIRTUAL_ADDRESS upload(const void* data, size_t bytes) {
        if (device is null || device.device is null) {
            enforce(false, "ConstantBufferRing has no device");
        }
        auto alignedBytes = align256(bytes);
        ensureCapacity(cursor + alignedBytes);
        enforce(buffer !is null && mappedPtr !is null, "ConstantBufferRing buffer is not mapped");
        auto dstPtr = mappedPtr + cursor;
        memcpy(dstPtr, data, bytes);
        auto gpuAddress = buffer.value.GetGPUVirtualAddress() + cursor;
        cursor += alignedBytes;
        return gpuAddress;
    }

    void shutdown() {
        if (buffer !is null && mappedPtr !is null) {
            buffer.value.Unmap(0, null);
        }
        buffer = null;
        mappedPtr = null;
        capacity = 0;
        cursor = 0;
    }

private:
    static size_t align256(size_t value) {
        return (value + 255) & ~cast(size_t)255;
    }

    void ensureCapacity(size_t required) {
        if (buffer !is null && required <= capacity) {
            return;
        }
        size_t newCapacity = max(align256(required), max(capacity * 2, cast(size_t)64 * 1024));
        createBuffer(newCapacity);
    }

    void createBuffer(size_t bytes) {
        if (buffer !is null && mappedPtr !is null) {
            buffer.value.Unmap(0, null);
        }

        D3D12_HEAP_PROPERTIES heapProps = D3D12_HEAP_PROPERTIES.init;
        heapProps.Type = D3D12_HEAP_TYPE.UPLOAD;
        heapProps.CPUPageProperty = D3D12_CPU_PAGE_PROPERTY.UNKNOWN;
        heapProps.MemoryPoolPreference = D3D12_MEMORY_POOL.POOL_UNKNOWN;
        heapProps.CreationNodeMask = 1;
        heapProps.VisibleNodeMask = 1;

        D3D12_RESOURCE_DESC desc = D3D12_RESOURCE_DESC.init;
        desc.Dimension = D3D12_RESOURCE_DIMENSION.BUFFER;
        desc.Width = bytes;
        desc.Height = 1;
        desc.DepthOrArraySize = 1;
        desc.MipLevels = 1;
        desc.Format = DXGI_FORMAT.UNKNOWN;
        desc.SampleDesc.Count = 1;
        desc.SampleDesc.Quality = 0;
        desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        desc.Flags = D3D12_RESOURCE_FLAGS.NONE;

        ID3D12Resource rawBuffer = null;
        enforceHr(device.device.CreateCommittedResource(
            &heapProps,
            D3D12_HEAP_FLAGS.NONE,
            &desc,
            D3D12_RESOURCE_STATES.GENERIC_READ,
            null,
            iid!ID3D12Resource,
            cast(void**)&rawBuffer),
            "CreateCommittedResource (constant buffer ring) failed");
        buffer = new DXPtr!ID3D12Resource(rawBuffer);

        D3D12_RANGE range = D3D12_RANGE.init;
        void* mapped = null;
        enforceHr(buffer.value.Map(0, &range, &mapped), "Failed to map constant buffer ring");
        mappedPtr = cast(ubyte*)mapped;
        capacity = bytes;
        cursor = 0;
    }
}

}

}
