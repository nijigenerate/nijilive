module nijilive.core.render.backends.directx12.descriptor_pool;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import std.algorithm : sort;
import std.exception : enforce;

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;

import nijilive.core.render.backends.directx12.device : DirectX12Device;
import nijilive.core.render.backends.directx12.dxhelpers;

/// Simple pool for managing CBV/SRV/UAV descriptors
struct DescriptorPool {
private:
    struct FreeRange {
        uint start;
        uint count;
    }

    DXPtr!ID3D12DescriptorHeap heap;
    D3D12_GPU_DESCRIPTOR_HANDLE gpuStart;
    D3D12_CPU_DESCRIPTOR_HANDLE cpuStart;
    uint descriptorSize;
    uint capacity;
    uint cursor;
    FreeRange[] freeList;

public:
    void initialize(DirectX12Device* device, uint descriptorCount) {
        auto dev = device.device;
        if (dev is null) {
            enforce(false, "DirectX12 device is not initialized");
        }
        capacity = descriptorCount;
        cursor = 0;
        freeList.length = 0;

        D3D12_DESCRIPTOR_HEAP_DESC desc = D3D12_DESCRIPTOR_HEAP_DESC.init;
        desc.NumDescriptors = descriptorCount;
        desc.Type = D3D12_DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV;
        desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.SHADER_VISIBLE;
        ID3D12DescriptorHeap rawHeap = null;
        enforceHr(dev.CreateDescriptorHeap(&desc, iid!ID3D12DescriptorHeap, cast(void**)&rawHeap),
            "CreateDescriptorHeap (CBV/SRV/UAV) failed");
        heap = new DXPtr!ID3D12DescriptorHeap(rawHeap);
        cpuStart = heap.value.GetCPUDescriptorHandleForHeapStart();
        gpuStart = heap.value.GetGPUDescriptorHandleForHeapStart();
        descriptorSize = dev.GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE.CBV_SRV_UAV);
    }

    void reset() {
        cursor = 0;
        freeList.length = 0;
    }

    /// Allocate a contiguous block of descriptorCount and return CPU/GPU handles
    DescriptorAllocation allocate(uint descriptorCount) {
        assert(heap !is null, "Descriptor heap not initialized");
        DescriptorAllocation alloc;
        if (tryAllocateFromFreeList(descriptorCount, alloc)) {
            return alloc;
        }
        assert(cursor + descriptorCount <= capacity, "Descriptor heap exhausted");
        alloc = makeAllocation(cursor, descriptorCount);
        cursor += descriptorCount;
        return alloc;
    }

    void free(ref DescriptorAllocation allocation) {
        if (!allocation.valid) return;
        FreeRange range;
        range.start = allocation.startIndex;
        range.count = allocation.count;
        freeList ~= range;
        mergeFreeRanges();
        allocation = DescriptorAllocation.init;
    }

    ID3D12DescriptorHeap heapHandle() {
        return heap is null ? null : heap.value;
    }

private:
    DescriptorAllocation makeAllocation(uint startIndex, uint descriptorCount) {
        DescriptorAllocation alloc;
        alloc.cpuHandle = cpuStart;
        alloc.gpuHandle = gpuStart;
        alloc.cpuHandle.ptr += startIndex * descriptorSize;
        alloc.gpuHandle.ptr += startIndex * descriptorSize;
        alloc.descriptorSize = descriptorSize;
        alloc.startIndex = startIndex;
        alloc.count = descriptorCount;
        alloc.valid = true;
        return alloc;
    }

    bool tryAllocateFromFreeList(uint descriptorCount, out DescriptorAllocation allocation) {
        foreach (i, ref range; freeList) {
            if (range.count < descriptorCount) continue;
            allocation = makeAllocation(range.start, descriptorCount);
            if (range.count == descriptorCount) {
                range = freeList[$ - 1];
                freeList.length = freeList.length - 1;
            } else {
                range.start += descriptorCount;
                range.count -= descriptorCount;
            }
            return true;
        }
        return false;
    }

    void mergeFreeRanges() {
        if (freeList.length <= 1) return;
        freeList.sort!((a, b) => a.start < b.start);
        size_t writeIndex = 0;
        foreach (range; freeList) {
            if (writeIndex == 0) {
                freeList[writeIndex++] = range;
                continue;
            }
            auto prev = freeList[writeIndex - 1];
            if (prev.start + prev.count == range.start) {
                prev.count += range.count;
                freeList[writeIndex - 1] = prev;
            } else {
                freeList[writeIndex++] = range;
            }
        }
        freeList.length = writeIndex;
    }
}

struct DescriptorAllocation {
    D3D12_CPU_DESCRIPTOR_HANDLE cpuHandle;
    D3D12_GPU_DESCRIPTOR_HANDLE gpuHandle;
    uint descriptorSize;
    uint startIndex;
    uint count;
    bool valid;

    D3D12_CPU_DESCRIPTOR_HANDLE cpuAt(uint index) const {
        D3D12_CPU_DESCRIPTOR_HANDLE handle;
        handle.ptr = cpuHandle.ptr + index * descriptorSize;
        return handle;
    }

    D3D12_GPU_DESCRIPTOR_HANDLE gpuAt(uint index) const {
        D3D12_GPU_DESCRIPTOR_HANDLE handle;
        handle.ptr = gpuHandle.ptr + index * descriptorSize;
        return handle;
    }
}

}

}
