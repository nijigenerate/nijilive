# Aurora DirectX Backend Tasks

- [x] Aurora investigation: studied device/command queue/descriptor heap APIs and built the bootstrap + shared buffer upload scaffolding (device.d, shared_buffers.d).
- [x] DirectX texture management: add DxTextureHandle + upload command path, and replace create/upload/destroy with DirectX implementations.
- [x] PSO / root signature expansion: update HLSL/PSO to include texture SRVs + sampler, mapping Filtering/Wrapping to D3D12 states.
- [x] Port remaining draw paths: implement mask/composite/dynamicComposite and drawTextureAt* on D3D12 command lists, including RTV/DSV switching and stencil control.
- [ ] Runtime/config/fallback: add backend selection options and fallback behavior to runtime_state / configuration files.
- [ ] Testing & docs: add a DirectX smoke test + documentation updates, and keep RecordingEmitter tests in sync.

## Unity Integration Tasks
- [x] Export DLL lifecycle APIs (`njgCreateRenderer`, `njgDestroyRenderer`) that accept Unity’s resource callbacks so textures/FBOs are created on the C# side.
- [x] Add puppet/scene management exports: `njgLoadPuppet`/`njgUnloadPuppet`/`njgUpdateParameters` and log callback (`njgSetLogCallback`) are in place; animation trigger APIs provided as native exports backed by per-renderer `AnimationPlayer` instances (no core puppet changes).
- [x] Implement frame execution exports (`njgBeginFrame`, `njgTickPuppet`, `njgEmitCommands`, `njgGetSharedBuffers`) that expose serialized `QueuedCommand` data and SOA buffer snapshots for Unity’s CommandBuffer pipeline.

## Unity/Queue Rendering Parity (match OpenGL pipeline data)
- Queue backend is intentionally record-only; parity here means exporting the same render state/commands that OpenGL consumes so Unity’s managed renderer can reproduce the output.
- [x] Mirror dynamic composite begin/end semantics from `nijilive/source/nijilive/core/render/backends/opengl/dynamic_composite.d` on the Unity side: bind MRT targets (color+optional stencil), push/pop viewport, apply scale/rotation camera tweak, clear attachments, rebind previous targets, and generate mipmaps only when `autoScaled` is false. Extend `NjgDynamicCompositePass`/`serializeDynamicPass` to carry `autoScaled` and the pre-pass viewport so Unity can restore state. (Implemented: pass export, Unity CommandBuffer sink binds color/stencil RTs, restores targets, generates mips.)
- [x] Implement the mask pipeline equivalent to `oglBeginMask`/`oglExecuteMaskApplyPacket`/`oglBeginMaskContent`/`oglEndMask` in Unity’s playback, honoring `usesStencil` and the dodge-vs-mask split emitted by `CommandQueueEmitter` in `nijilive/source/nijilive/core/render/backends/queue/package.d`.
- [x] Recreate `oglDrawPartPacket`’s MRT path in Unity (albedo/emissive/bump outputs, `useMultistageBlend`, advanced-blend fallback/triple-buffer logic, tint/screen/emission handling) so queued `PartDrawPacket` data renders identically. (Added MRT-capable shader + CommandBuffer keyword toggling; draws emit to multiple targets when provided.)
- [x] Track framebuffer/draw-buffer state like `oglInitRenderer`/`oglBeginScene`/`oglRebindActiveTargets` in Unity-managed rendering, keeping root/composite/blend targets in sync with queue playback instead of relying solely on placeholder handles from `RenderingBackend`’s `setRenderTargets`. (Managed renderer now exposes render/composite handles, viewport, and binds provided RTs.)
- [ ] Add parity validation: cover nested composites + mask flows from `nijilive/source/nijilive/core/render/tests/render_queue.d` in Unity-side tests and image comparisons against the OpenGL backend. (Structural validation helper added in `unity-managed/Managed/ParityValidator.cs`; pixel validation still pending.)
