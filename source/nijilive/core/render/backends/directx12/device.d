module nijilive.core.render.backends.directx12.device;

version (RenderBackendDirectX12) {

version (InDoesRender) {

import core.sys.windows.com : CoInitializeEx, COINIT_MULTITHREADED;
import core.sys.windows.windows : HANDLE, CloseHandle, CreateEventW, WaitForSingleObject, INFINITE, BOOL;
import std.exception : enforce;

import aurora.directx.com : DXPtr;
import aurora.directx.d3d12;
import aurora.directx.d3d12.d3d12sdklayers : ID3D12Debug;
import aurora.directx.dxgi.dxgi : DXGI_ERROR_NOT_FOUND;
import aurora.directx.dxgi.dxgi1_3 : CreateDXGIFactory2;
import aurora.directx.dxgi.dxgi1_6;

import nijilive.core.render.backends.directx12.dxhelpers;

/// Owning wrapper around the fundamental D3D12 device state.
struct DirectX12Device {
private:
    DXPtr!IDXGIFactory6 factoryPtr;
    DXPtr!IDXGIAdapter4 adapterPtr;
    DXPtr!ID3D12Device devicePtr;
    DXPtr!ID3D12CommandQueue graphicsQueuePtr;
    DXPtr!ID3D12CommandAllocator commandAllocatorPtr;
    DXPtr!ID3D12GraphicsCommandList commandListPtr;
    DXPtr!ID3D12CommandAllocator uploadAllocatorPtr;
    DXPtr!ID3D12GraphicsCommandList uploadCommandListPtr;
    DXPtr!ID3D12Fence frameFencePtr;
    DXPtr!ID3D12Fence uploadFencePtr;
    HANDLE fenceEvent = null;
    HANDLE uploadFenceEvent = null;
    ulong fenceValue = 0;
    ulong uploadFenceValue = 0;
    bool initialized;

public:
    /// Returns true when the device finished initialization.
    @property bool isInitialized() const {
        return initialized;
    }

    /// Raw D3D12 device pointer.
    @property ID3D12Device device() {
        return devicePtr is null ? null : devicePtr.value;
    }

    /// Initializes D3D12 and the shared command infrastructure.
    void initialize(bool enableDebugLayer) {
        if (initialized) return;
        CoInitializeEx(null, COINIT_MULTITHREADED);

        if (enableDebugLayer) {
            ID3D12Debug debugInterface = null;
            auto hr = D3D12GetDebugInterface(iid!ID3D12Debug, cast(void**)&debugInterface);
            if (dxSucceeded(hr) && debugInterface !is null) {
                debugInterface.EnableDebugLayer();
                debugInterface.Release();
            }
        }

        uint factoryFlags = enableDebugLayer ? DXGI_CREATE_FACTORY_DEBUG : DXGI_CREATE_FACTORY_NORMAL;
        IDXGIFactory6 rawFactory = null;
        enforceHr(CreateDXGIFactory2(factoryFlags, iidAurora!IDXGIFactory6, cast(void**)&rawFactory),
            "CreateDXGIFactory2 failed");
        factoryPtr = new DXPtr!IDXGIFactory6(rawFactory);

        pickAdapter();
        enforce(adapterPtr !is null, "Failed to locate a DirectX 12 capable adapter");

        ID3D12Device rawDevice = null;
        auto hr = D3D12CreateDevice(adapterPtr.value, D3D_FEATURE_LEVEL_12_1, iid!ID3D12Device, cast(void**)&rawDevice);
        if (dxFailed(hr)) {
            enforceHr(D3D12CreateDevice(adapterPtr.value, D3D_FEATURE_LEVEL_12_0, iid!ID3D12Device, cast(void**)&rawDevice),
                "D3D12CreateDevice failed");
        }
        devicePtr = new DXPtr!ID3D12Device(rawDevice);

        D3D12_COMMAND_QUEUE_DESC queueDesc = D3D12_COMMAND_QUEUE_DESC.init;
        queueDesc.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
        queueDesc.Flags = D3D12_COMMAND_QUEUE_FLAG_NONE;
        ID3D12CommandQueue rawQueue = null;
        enforceHr(devicePtr.value.CreateCommandQueue(&queueDesc, iid!ID3D12CommandQueue, cast(void**)&rawQueue),
            "CreateCommandQueue failed");
        graphicsQueuePtr = new DXPtr!ID3D12CommandQueue(rawQueue);

        ID3D12CommandAllocator rawAllocator = null;
        enforceHr(devicePtr.value.CreateCommandAllocator(
            D3D12_COMMAND_LIST_TYPE_DIRECT,
            iid!ID3D12CommandAllocator,
            cast(void**)&rawAllocator),
            "CreateCommandAllocator failed");
        commandAllocatorPtr = new DXPtr!ID3D12CommandAllocator(rawAllocator);

        ID3D12GraphicsCommandList rawList = null;
        enforceHr(devicePtr.value.CreateCommandList(
            0,
            D3D12_COMMAND_LIST_TYPE_DIRECT,
            commandAllocatorPtr.value,
            null,
            iid!ID3D12GraphicsCommandList,
            cast(void**)&rawList),
            "CreateCommandList failed");
        commandListPtr = new DXPtr!ID3D12GraphicsCommandList(rawList);
        commandListPtr.value.Close();

        ID3D12CommandAllocator rawUploadAllocator = null;
        enforceHr(devicePtr.value.CreateCommandAllocator(
            D3D12_COMMAND_LIST_TYPE_DIRECT,
            iid!ID3D12CommandAllocator,
            cast(void**)&rawUploadAllocator),
            "CreateCommandAllocator (upload) failed");
        uploadAllocatorPtr = new DXPtr!ID3D12CommandAllocator(rawUploadAllocator);

        ID3D12GraphicsCommandList rawUploadList = null;
        enforceHr(devicePtr.value.CreateCommandList(
            0,
            D3D12_COMMAND_LIST_TYPE_DIRECT,
            uploadAllocatorPtr.value,
            null,
            iid!ID3D12GraphicsCommandList,
            cast(void**)&rawUploadList),
            "CreateCommandList (upload) failed");
        uploadCommandListPtr = new DXPtr!ID3D12GraphicsCommandList(rawUploadList);
        uploadCommandListPtr.value.Close();

        ID3D12Fence rawFence = null;
        enforceHr(devicePtr.value.CreateFence(
            0,
            D3D12_FENCE_FLAG_NONE,
            iid!ID3D12Fence,
            cast(void**)&rawFence),
            "CreateFence failed");
        frameFencePtr = new DXPtr!ID3D12Fence(rawFence);
        fenceValue = 1;
        fenceEvent = CreateEventW(null, false, false, null);
        enforce(fenceEvent !is null, "Failed to create fence event");

        ID3D12Fence rawUploadFence = null;
        enforceHr(devicePtr.value.CreateFence(
            0,
            D3D12_FENCE_FLAG_NONE,
            iid!ID3D12Fence,
            cast(void**)&rawUploadFence),
            "CreateFence (upload) failed");
        uploadFencePtr = new DXPtr!ID3D12Fence(rawUploadFence);
        uploadFenceEvent = CreateEventW(null, false, false, null);
        enforce(uploadFenceEvent !is null, "Failed to create upload fence event");
        initialized = true;
    }

    /// Releases COM resources.
    void shutdown() {
        if (!initialized) return;
        waitForGpu();
        flushUploadQueue();
        if (fenceEvent !is null) {
            CloseHandle(fenceEvent);
            fenceEvent = null;
        }
        if (uploadFenceEvent !is null) {
            CloseHandle(uploadFenceEvent);
            uploadFenceEvent = null;
        }
        frameFencePtr = null;
        uploadFencePtr = null;
        commandListPtr = null;
        uploadCommandListPtr = null;
        commandAllocatorPtr = null;
        uploadAllocatorPtr = null;
        graphicsQueuePtr = null;
        devicePtr = null;
        adapterPtr = null;
        factoryPtr = null;
        initialized = false;
    }

    /// Resets the command allocator/list for a new frame.
    void beginFrame() {
        enforce(initialized, "DirectX12Device is not initialized");
        enforceHr(commandAllocatorPtr.value.Reset(), "Command allocator reset failed");
        enforceHr(commandListPtr.value.Reset(commandAllocatorPtr.value, null), "Command list reset failed");
    }

    /// Executes the current command list and waits for completion.
    void endFrame() {
        enforce(initialized, "DirectX12Device is not initialized");
        enforceHr(commandListPtr.value.Close(), "Failed to close command list");
        ID3D12CommandList[1] lists;
        lists[0] = cast(ID3D12CommandList)commandListPtr.value;
        graphicsQueuePtr.value.ExecuteCommandLists(1, cast(const(ID3D12CommandList)*)lists.ptr);
        waitForGpu();
    }

    /// Accessor for the shared command list (useful for future passes).
    @property ID3D12GraphicsCommandList commandList() {
        return commandListPtr is null ? null : commandListPtr.value;
    }

    /// Executes a short-lived command list for resource uploads and waits for completion.
    void submitUploadCommands(scope void delegate(ID3D12GraphicsCommandList) encode) {
        enforce(initialized, "DirectX12Device is not initialized");
        enforce(uploadAllocatorPtr !is null && uploadCommandListPtr !is null,
            "Upload command list is not available");
        enforceHr(uploadAllocatorPtr.value.Reset(), "Upload allocator reset failed");
        enforceHr(uploadCommandListPtr.value.Reset(uploadAllocatorPtr.value, null),
            "Upload command list reset failed");
        encode(uploadCommandListPtr.value);
        enforceHr(uploadCommandListPtr.value.Close(), "Failed to close upload command list");
        ID3D12CommandList[1] lists;
        lists[0] = cast(ID3D12CommandList)uploadCommandListPtr.value;
        graphicsQueuePtr.value.ExecuteCommandLists(1, cast(const(ID3D12CommandList)*)lists.ptr);
        flushUploadQueue();
    }

private:
    void pickAdapter() {
        uint adapterIndex = 0;
        while (true) {
            IDXGIAdapter4 rawAdapter = null;
            auto hr = factoryPtr.value.EnumAdapterByGpuPreference(
                adapterIndex,
                DXGI_GPU_PREFERENCE.DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE,
                iid!IDXGIAdapter4,
                cast(void**)&rawAdapter);
            if (hr == DXGI_ERROR_NOT_FOUND) {
                break;
            }
            if (dxSucceeded(hr) && rawAdapter !is null) {
                DXGI_ADAPTER_DESC3 desc;
                rawAdapter.GetDesc3(&desc);
                bool isSoftware = (cast(uint)desc.Flags & cast(uint)DXGI_ADAPTER_FLAG3.SOFTWARE) != 0;
                if (!isSoftware) {
                    adapterPtr = new DXPtr!IDXGIAdapter4(rawAdapter);
                    return;
                }
                rawAdapter.Release();
            }
            adapterIndex++;
        }
    }

    void waitForGpu() {
        if (graphicsQueuePtr is null || frameFencePtr is null) return;
        fenceValue++;
        graphicsQueuePtr.value.Signal(frameFencePtr.value, fenceValue);
        if (frameFencePtr.value.GetCompletedValue() < fenceValue) {
            frameFencePtr.value.SetEventOnCompletion(fenceValue, fenceEvent);
            WaitForSingleObject(fenceEvent, INFINITE);
        }
    }

    void flushUploadQueue() {
        if (graphicsQueuePtr is null || uploadFencePtr is null) return;
        uploadFenceValue++;
        graphicsQueuePtr.value.Signal(uploadFencePtr.value, uploadFenceValue);
        if (uploadFencePtr.value.GetCompletedValue() < uploadFenceValue) {
            uploadFencePtr.value.SetEventOnCompletion(uploadFenceValue, uploadFenceEvent);
            WaitForSingleObject(uploadFenceEvent, INFINITE);
        }
    }
}

}

}
