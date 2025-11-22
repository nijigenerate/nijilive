module nijilive.core.render.backends.directx12.descriptor_heap;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;
import nijilive.core.render.backends.directx12.dxhelpers;

/// Simple CPU descriptor heap allocator for RTV/DSV heaps.
struct DescriptorAllocator {
private:
    DXPtr!ID3D12DescriptorHeap heap;
    D3D12_DESCRIPTOR_HEAP_TYPE heapType;
    D3D12_CPU_DESCRIPTOR_HANDLE startHandle;
    uint descriptorSize;
    uint capacity;
    uint nextIndex;

public:
    void initialize(ID3D12Device device, D3D12_DESCRIPTOR_HEAP_TYPE type, uint descriptorCount) {
        heapType = type;
        capacity = descriptorCount;
        nextIndex = 0;

        D3D12_DESCRIPTOR_HEAP_DESC desc = D3D12_DESCRIPTOR_HEAP_DESC.init;
        desc.NumDescriptors = descriptorCount;
        desc.Type = type;
        desc.Flags = D3D12_DESCRIPTOR_HEAP_FLAGS.NONE;
        ID3D12DescriptorHeap rawHeap = null;
        enforceHr(device.CreateDescriptorHeap(&desc, iid!ID3D12DescriptorHeap, cast(void**)&rawHeap),
            "CreateDescriptorHeap failed");
        heap = new DXPtr!ID3D12DescriptorHeap(rawHeap);
        startHandle = heap.value.GetCPUDescriptorHandleForHeapStart();
        descriptorSize = device.GetDescriptorHandleIncrementSize(type);
    }

    /// Reset the allocation cursor to reuse descriptors after a resize.
    void reset() {
        nextIndex = 0;
    }

    /// Allocate the next CPU descriptor handle from the heap.
    D3D12_CPU_DESCRIPTOR_HANDLE allocate() {
        assert(heap !is null, "Descriptor heap not initialized");
        assert(nextIndex < capacity, "Descriptor heap exhausted");
        D3D12_CPU_DESCRIPTOR_HANDLE handle = startHandle;
        handle.ptr += nextIndex * descriptorSize;
        nextIndex++;
        return handle;
    }
}

}

}
