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
