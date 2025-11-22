# Aurora DirectX Backend Plan

## Current Status
- DirectX12 backend already handles device / command queue bootstrap and shared SOA atlas uploads via aurora-directx (source/nijilive/core/render/backends/directx12/device.d, shared_buffers.d).
- Render targets for main/composite/blend plus RTV/DSV descriptor management are implemented and expose RenderResourceHandle values (render_targets.d, descriptor_heap.d).
- Part rendering now has a root signature / PSO scaffold, constant buffer ring, shared-buffer SRV allocation, and vertex/index binding using the atlas data (pipeline.d, pso_cache.d, constant_buffer_ring.d, package.d).
- Texture creation/upload/destroy and filtering/wrapping hooks are implemented via DxTextureHandle + descriptor pool management, and part draw packets now bind up to three SRVs (package.d).
- Runtime config wiring and DX12 smoke tests are still pending; only part geometry was rendered prior to the new draw paths.
- Mask, composite, dynamic composite, and drawTexture passes now run on DirectX12 command lists with stencil/RTV switching and CPU fallback removed.

## Next Steps
1. **Mask / Composite / DynamicComposite / drawTexture Paths**
   - Port RTV/DSV switching, stencil/blend configuration, multi-stage blend logic, and offscreen surfaces to D3D12.
2. **Runtime/config/fallback**
   - Expose DirectX12 backend selection & fallback in runtime_state/configuration files and ensure existing flows keep working.
3. **Testing & Docs**
   - Add a DirectX smoke test (e.g., RecordingEmitter) and update doc/task.md, doc/rendering.md, and plan status with current limitations.

## Build / Run Environment
- Launch `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoExit -File "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\Tools\Launch-VsDevShell.ps1"` (the VS2022 Developer PowerShell) before doing anything else.
- Run `set PATH=C:\opt\ldc-1.41\bin;%PATH%` in that shell so LDC 1.41 is used for all `dub` commands.
- Build via `dub build -q` from inside the same shell to ensure `link.exe`, `rc.exe`, etc., resolve correctly.
- Place DirectX12 shaders under `shaders/directx12/...`; the project imports them with `import("directx12/…")` and the existing `-Jshaders` switch must continue to find them.

## Unity Integration Interface (DLL Exports)
When `nijilive` is consumed as a Unity plug-in, Unity (C#/Mono) owns render targets, textures, and the graphics API. The `nijilive` DLL therefore focuses on producing logical command buffers and buffer snapshots. Expose the following C ABI:

1. **Renderer Lifecycle**
   - `njgCreateRenderer(const UnityRendererConfig*, const UnityResourceCallbacks*, RendererHandle*)`
   - `njgDestroyRenderer(RendererHandle)`
   - Callbacks provide `CreateTexture`, `ReleaseTexture`, `MapBuffer`, `UnmapBuffer`, etc., so Unity allocates GPU assets and returns handles back to D.

2. **Scene / Puppet Management**
   - `njgLoadPuppet(RendererHandle, const char* path, PuppetHandle*)`
   - `njgUnloadPuppet(RendererHandle, PuppetHandle)`
   - `njgUpdateParameters(PuppetHandle, const PuppetParameterUpdate*)`, `njgTriggerAnimation`, etc.

3. **Frame Execution**
   - `njgBeginFrame(RendererHandle, const FrameConfig*)`
   - `njgTickPuppet(PuppetHandle, double deltaSeconds)`
   - `njgEmitCommands(RendererHandle, CommandQueueView*)` — returns a view over serialized `QueuedCommand` (Part/Mask/Composite/DynamicComposite packets).
   - `njgGetSharedBuffers(RendererHandle, SharedBufferSnapshot*)` — provides SOA vertex/uv/deform slices for Unity to copy into `ComputeBuffer` や `NativeArray`.

4. **Resource Synchronization**
   - Unity registers `UnityTextureHandle` for every `Texture` referenced by packets; `nijilive` stores lightweight IDs and asks for uploads via callbacks.
   - Unity supplies RenderTexture/FBO handles for composite targets and dynamic composites; `DynamicCompositePass` inside the queue references those handles.

5. **Logging / Errors**
   - `njgSetLogCallback(void(*)(LogLevel, const char*))` so file-loading failures or validation errors are surfaced to managed code.

This interface keeps graphics ownership on the Unity side while `nijilive` remains a logical backend that emits command queues and shared buffer contents for Unity’s CommandBuffer pipeline.

### Unity C# Host Responsibilities
The managed side (Mono/Unity) must provide the following pieces to consume the DLL:

1. **P/Invoke Definitions and Handles**
   - Declare `[DllImport]` stubs for `njgCreateRenderer`, `njgDestroyRenderer`, `njgLoadPuppet`, `njgEmitCommands`, etc.
   - Implement `SafeHandle`/`IntPtr` wrappers for `RendererHandle`, `PuppetHandle`, `UnityTextureHandle`, ensuring proper disposal semantics.

2. **Resource Callback Struct**
   - Define a `struct UnityResourceCallbacks` in C# containing function pointers/delegates such as `CreateTexture`, `ReleaseTexture`, `MapSharedBuffer`, `UnmapSharedBuffer`, `Log`.
   - Populate this struct with methods that allocate Unity `Texture2D`/`RenderTexture`, wrap `GraphicsBuffer`, and raise managed exceptions on failure.

3. **Buffer/Texture Managers**
   - Maintain dictionaries that map nijilive texture IDs to Unity objects, upload SOA vertex/uv/deform data into `ComputeBuffer`/`NativeArray`.
   - Convert `QueuedCommand` packets into Unity `CommandBuffer.DrawMesh` / `DrawProcedural` invocations, binding the correct materials and textures.

4. **Frame Loop Integration**
   - Create a `MonoBehaviour` or RenderPipeline hook that calls `njgBeginFrame`, `njgTickPuppet`, `njgEmitCommands`, and `njgGetSharedBuffers` each frame.
   - Translate the emitted commands into Unity `CommandBuffer`s inserted in URP/HDRP/Built-in pipelines.

5. **Logging/Error Reporting**
   - Register a managed callback via `njgSetLogCallback` to surface DLL logs/exceptions into Unity’s console or UI.

These components ensure Unity controls graphics resources while reusing nijilive’s animation/command logic through a clean DLL boundary.
