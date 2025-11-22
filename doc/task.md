# Aurora DirectX Backend Tasks

- [x] Aurora investigation: studied device/command queue/descriptor heap APIs and built the bootstrap + shared buffer upload scaffolding (device.d, shared_buffers.d).
- [x] DirectX texture management: add DxTextureHandle + upload command path, and replace create/upload/destroy with DirectX implementations.
- [x] PSO / root signature expansion: update HLSL/PSO to include texture SRVs + sampler, mapping Filtering/Wrapping to D3D12 states.
- [x] Port remaining draw paths: implement mask/composite/dynamicComposite and drawTextureAt* on D3D12 command lists, including RTV/DSV switching and stencil control.
- [ ] Runtime/config/fallback: add backend selection options and fallback behavior to runtime_state / configuration files.
- [ ] Testing & docs: add a DirectX smoke test + documentation updates, and keep RecordingEmitter tests in sync.

## Unity Integration Tasks
- [ ] Export DLL lifecycle APIs (`njgCreateRenderer`, `njgDestroyRenderer`) that accept Unity’s resource callbacks so textures/FBOs are created on the C# side.
- [ ] Add puppet/scene management exports (`njgLoadPuppet`, `njgUnloadPuppet`, `njgUpdateParameters`, animation triggers) with error propagation through `njgSetLogCallback`.
- [ ] Implement frame execution exports (`njgBeginFrame`, `njgTickPuppet`, `njgEmitCommands`, `njgGetSharedBuffers`) that expose serialized `QueuedCommand` data and SOA buffer snapshots for Unity’s CommandBuffer pipeline.
