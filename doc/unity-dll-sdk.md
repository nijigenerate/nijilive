# Unity DLL SDK Developer Guide

This guide is the authoritative developer documentation for
`nijilive-unity.dll`, based on `source/nijilive/integration/unity.d`.

## Table of Contents

- [1. Overview](#1-overview)
- [2. API Quick List](#2-api-quick-list)
- [3. Detailed API Reference](#3-detailed-api-reference)
- [4. Struct and Field Reference](#4-struct-and-field-reference)
- [5. Usage Examples](#5-usage-examples)
- [6. Operational Notes and Constraints](#6-operational-notes-and-constraints)
- [7. Troubleshooting](#7-troubleshooting)

## 1. Overview

### 1.0 C ABI type shape (exact representation)

For host-language binding authors, the public ABI-level shape is:

```c
typedef void*  RendererHandle;   // opaque pointer token
typedef void*  PuppetHandle;     // opaque pointer token

typedef enum NjgResult { Ok = 0, InvalidArgument = 1, Failure = 2 } NjgResult;
typedef enum NjgRenderCommandKind : unsigned int { ... } NjgRenderCommandKind;
```

Key primitive mappings used across the API:

- `size_t`: unsigned integer (pointer-width; 64-bit on typical x64 builds)
- `int`: 32-bit signed integer
- `float`: 32-bit IEEE 754 floating point
- `double`: 64-bit IEEE 754 floating point
- `bool`: C ABI boolean used by the compiler toolchain for this DLL
- `const char*`: UTF-8 byte pointer (may be non-null-terminated when paired
  with explicit length)

Important:

- `RendererHandle` / `PuppetHandle` are pointer-typed (`void*`), not integer IDs.
- Fields such as `size_t renderFramebuffer` / `size_t textureHandles[i]` are
  integer-like host resource handles, not SDK object pointers.

Ownership and release rules (critical):

- Ownership of memory behind `RendererHandle` and `PuppetHandle` stays in the SDK.
- Host must never call `free`, `delete`, `delete[]`, `CoTaskMemFree`, or any
  custom allocator on these handle values.
- Valid release path is API-only:
  - `PuppetHandle` -> `njgUnloadPuppet(renderer, puppet)`
  - `RendererHandle` -> `njgDestroyRenderer(renderer)`
- Recommended destruction order:
  1. unload puppets for a renderer
  2. destroy renderer
  3. terminate runtime (`njgRuntimeTerm`) at process shutdown
- Reason:
  - `PuppetHandle` is renderer-associated in usage/lifecycle.
  - `njgUnloadPuppet` requires both renderer and puppet handles.
  - after `njgDestroyRenderer`, that renderer handle is invalid, so targeted
    puppet unload is no longer possible.
- Minimum guarantee:
  - destroying renderer invalidates renderer-scoped state and makes all puppets
    in that renderer unusable from host perspective.
  - however, for deterministic per-puppet teardown, unload puppets first.
- After unload/destroy, the handle becomes invalid and must not be reused.
- Passing an invalidated handle to any API is undefined behavior.

### 1.1 Goal

The SDK exposes a native C ABI that lets a host application:

- initialize nijilive runtime
- load puppet files (`.inp` / `.inx`)
- update puppet state every frame
- receive serialized render commands
- receive shared geometry buffers (SoA)
- control parameters and animations

The host performs final rendering from command packets and shared buffers.

### 1.2 Runtime model

The API has two primary opaque handles:

- `RendererHandle`
  - Backed by `UnityRenderer*` (defined in `source/nijilive/integration/unity.d`)
  - Holds renderer-scoped state:
    - loaded puppets list
    - emitted command buffer
    - texture callback bridge
    - viewport/cache info

- `PuppetHandle`
  - Backed by `Puppet*`
  - Holds puppet-scoped state:
    - parameter values
    - transform values
    - animation player state

Important behavior:

- `njgLoadPuppet(renderer, ...)` registers the puppet into that renderer.
- `njgEmitCommands(renderer, ...)` emits commands for all puppets loaded in that renderer.

Important clarification:

- `RendererHandle` is an opaque pointer-like token to a DLL-internal
  `UnityRenderer` instance.
- It is not a GPU framebuffer/texture handle and not interchangeable with
  `NjgRenderTargets.*Framebuffer`.
- It is only valid inside the same process and only during its lifetime
  (`njgCreateRenderer` to `njgDestroyRenderer`).

### 1.3 Typical per-frame order

Use this order every frame:

1. `njgBeginFrame`
2. `njgTickPuppet` (for each puppet you update)
3. `njgEmitCommands`
4. `njgGetSharedBuffers`
5. host-side rendering
6. `njgFlushCommandBuffer`

If this order is broken, results are undefined or stale.

## 2. API Quick List

### 2.1 Runtime

- [`void njgRuntimeInit()`](#api-njgruntimeinit)
- [`void njgRuntimeTerm()`](#api-njgruntimeterm)
- [`void njgSetLogCallback(NjgLogFn callback, void* userData)`](#api-njgsetlogcallback)
- [`size_t njgGetGcHeapSize()`](#api-njggetgcheapsize)

### 2.2 Renderer and puppet lifecycle

- [`NjgResult njgCreateRenderer(const UnityRendererConfig* config, const UnityResourceCallbacks* callbacks, RendererHandle* outHandle)`](#api-njgcreaterenderer)
- [`void njgDestroyRenderer(RendererHandle handle)`](#api-njgdestroyrenderer)
- [`NjgResult njgLoadPuppet(RendererHandle handle, const char* path, PuppetHandle* outPuppet)`](#api-njgloadpuppet)
- [`NjgResult njgUnloadPuppet(RendererHandle handle, PuppetHandle puppetHandle)`](#api-njgunloadpuppet)

### 2.3 Frame execution

- [`NjgResult njgBeginFrame(RendererHandle handle, const FrameConfig* config)`](#api-njgbeginframe)
- [`NjgResult njgTickPuppet(PuppetHandle puppetHandle, double deltaSeconds)`](#api-njgtickpuppet)
- [`NjgResult njgEmitCommands(RendererHandle handle, CommandQueueView* outView)`](#api-njgemitcommands)
- [`void njgFlushCommandBuffer(RendererHandle handle)`](#api-njgflushcommandbuffer)
- [`NjgResult njgGetSharedBuffers(RendererHandle handle, SharedBufferSnapshot* snapshot)`](#api-njggetsharedbuffers)
- [`NjgRenderTargets njgGetRenderTargets(RendererHandle handle)`](#api-njggetrendertargets)
- [`TextureStats njgGetTextureStats(RendererHandle handle)`](#api-njggettexturestats)

### 2.4 Puppet controls

- [`NjgResult njgGetParameters(PuppetHandle puppetHandle, NjgParameterInfo* buffer, size_t bufferLength, size_t* outCount)`](#api-njggetparameters)
- [`NjgResult njgUpdateParameters(PuppetHandle puppetHandle, const PuppetParameterUpdate* updates, size_t updateCount)`](#api-njgupdateparameters)
- [`NjgResult njgGetPuppetExtData(PuppetHandle puppetHandle, const char* key, const(ubyte)** outData, size_t* outLength)`](#api-njggetpuppetextdata)
- [`NjgResult njgSetPuppetScale(PuppetHandle puppetHandle, float sx, float sy)`](#api-njgsetpuppetscale)
- [`NjgResult njgSetPuppetTranslation(PuppetHandle puppetHandle, float tx, float ty)`](#api-njgsetpuppettranslation)

### 2.5 Animation controls

- [`NjgResult njgPlayAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, bool loop, bool playLeadOut)`](#api-njgplayanimation)
- [`NjgResult njgPauseAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name)`](#api-njgpauseanimation)
- [`NjgResult njgStopAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, bool immediate)`](#api-njgstopanimation)
- [`NjgResult njgSeekAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, int frame)`](#api-njgseekanimation)

## 3. Detailed API Reference

## 3.1 Return codes

`NjgResult`:

- `Ok`: call succeeded
- `InvalidArgument`: one or more required inputs are null/invalid
- `Failure`: runtime/load/internal failure

## 3.2 Runtime APIs

<a id="api-njgruntimeinit"></a>
### `void njgRuntimeInit()`

Purpose:

- Initialize the SDK runtime before any renderer or puppet operation.
- Intended usage scene: application startup phase, after DLL load and before
  `njgCreateRenderer` / `njgLoadPuppet`.
- This call prepares runtime attachment and node factory registration used by
  puppet deserialization and graph execution.

Parameters:

- None

Returns:

- None

Side effects:

- Initializes runtime internals if not initialized.
- Safe and recommended as the first SDK call in process lifetime.

---

<a id="api-njgruntimeterm"></a>
### `void njgRuntimeTerm()`

Purpose:

- Explicitly terminates the SDK runtime at application shutdown.
- Intended usage scene: graceful app exit after all renderers/puppets are
  released.
- Use this to close runtime-level resources and detach runtime services.

Parameters:

- None

Returns:

- None

Side effects:

- Terminates runtime if active.
- Resets runtime initialization flags.
- Calling SDK APIs after termination is unsupported until re-initialized.

---

<a id="api-njgsetlogcallback"></a>
### `void njgSetLogCallback(NjgLogFn callback, void* userData)`

Purpose:

- Configure SDK diagnostics output sink.
- Intended usage scene: very early startup, so load/render failures are visible
  in host logs.
- Useful for integrating SDK logs into game engine consoles, editor logs, or
  telemetry pipelines.

Parameters:

- `callback`: function pointer invoked by SDK logging.
  - If non-null, SDK calls this on internal log emissions.
  - If null, callback logging is disabled and only default behavior remains.
  - Threading context depends on caller flow; treat callback as non-reentrant-safe
    unless your host explicitly synchronizes.
- `userData`: opaque pointer forwarded to `callback` unchanged.
  - Typical usage: pointer to logger instance, context struct, or dispatcher.
  - Lifetime must outlive any period where callback can be invoked.

Returns:

- None

Side effects:

- Replaces previously registered callback.

---

<a id="api-njggetgcheapsize"></a>
### `size_t njgGetGcHeapSize()`

Purpose:

- Query current GC used heap size for runtime diagnostics.
- Intended usage scene: periodic memory instrumentation, leak suspicion
  investigation, and before/after comparison around heavy operations.

Parameters:

- None

Returns:

- Current GC used size in bytes (`size_t`).
- Value is a runtime snapshot, not a strict upper bound of full process memory.

Side effects:

- None

## 3.3 Renderer and puppet lifecycle APIs

---

<a id="api-njgcreaterenderer"></a>
### `NjgResult njgCreateRenderer(const UnityRendererConfig* config, const UnityResourceCallbacks* callbacks, RendererHandle* outHandle)`

Purpose:

- Create one renderer context that owns frame state, command serialization
  buffers, and puppet registration list.
- Intended usage scene: when you need a command stream domain. Use one renderer
  for grouped puppets, or separate renderers for strict command isolation.
- This is the entry point that binds host texture callbacks to SDK resource
  lifecycle.

Parameters:

- `config`: optional pointer to initial renderer configuration.
  - If null, renderer uses internal defaults.
  - If non-null, positive `viewportWidth/viewportHeight` initialize viewport.
  - Invalid/non-positive dimensions are ignored rather than hard-failing.
- `callbacks`: optional pointer to host resource callbacks.
  - If non-null, SDK uses callback table for texture create/update/release.
  - If null, callback table is treated as empty; features depending on external
    resource bridging may be unavailable.
  - Callback function pointers and `userData` must remain valid while renderer is alive.
- `outHandle`: required output pointer for created `RendererHandle`.
  - Must be a valid writable pointer.
  - On failure, SDK writes null-equivalent into this output.

Returns:

- `InvalidArgument`: `outHandle` is null.
- `Failure`: exception during backend/runtime setup.
- `Ok`: renderer created successfully.

Side effects:

- Adds renderer to internal active renderer list.
- Initializes backend and timing function.
- Sets `*outHandle` to null on failure.
- Allocates renderer-owned transient buffers reused across frames.

---

<a id="api-njgdestroyrenderer"></a>
### `void njgDestroyRenderer(RendererHandle handle)`

Purpose:

- Destroy a renderer and release renderer-scoped runtime objects.
- Intended usage scene: renderer teardown when switching scenes, unloading
  subsystem, or process shutdown.
- Must be called after host is done consuming that renderer's command/snapshot
  outputs.

Parameters:

- `handle`: renderer handle to destroy.
  - Null is allowed and treated as no-op.
  - Non-null handle must be one previously returned by `njgCreateRenderer`.

Returns:

- None

Side effects:

- If handle is valid, clears command buffer, puppet list, and animation player map.
- Invalidates all transient pointers previously acquired from that renderer.

---

<a id="api-njgloadpuppet"></a>
### `NjgResult njgLoadPuppet(RendererHandle handle, const char* path, PuppetHandle* outPuppet)`

Purpose:

- Load a puppet asset (`.inx`/`.inp`) and register it into renderer draw set.
- Intended usage scene: character spawn or model swap workflows.
- This call performs deserialization and node graph preparation required for
  frame updates and command emission.

Parameters:

- `handle`: required target renderer handle.
  - Must be a valid renderer created by `njgCreateRenderer`.
  - Defines which renderer's `njgEmitCommands` stream will include this puppet.
- `path`: required UTF-8 path string.
  - Must point to a readable puppet file supported by nijilive loader.
  - Relative paths are resolved by host process working directory.
- `outPuppet`: required writable output pointer receiving created `PuppetHandle`.
  - On failure, output is reset to null-equivalent.
  - Handle lifetime is tied to successful load and later unload/destruction.

Returns:

- `InvalidArgument`: any required argument is null.
- `Failure`: load/deserialization/setup failure.
- `Ok`: puppet loaded and registered.

Side effects:

- Ensures node factories are initialized.
- Calls `puppet.rescanNodes()`.
- Calls `root.build(true)` when root exists.
- Creates/associates external texture handles through callbacks.
- Appends puppet to renderer puppet list.
- Writes null to `*outPuppet` on failure.
- Allocates puppet runtime objects and initializes per-puppet parameter state.

---

<a id="api-njgunloadpuppet"></a>
### `NjgResult njgUnloadPuppet(RendererHandle handle, PuppetHandle puppetHandle)`

Purpose:

- Detach a previously loaded puppet from renderer ownership and active draw set.
- Intended usage scene: despawn, model replacement, or reducing active workload.

Parameters:

- `handle`: required renderer that currently owns this puppet registration.
- `puppetHandle`: required puppet handle to remove.
  - Must correspond to a puppet previously loaded for this renderer.

Returns:

- `InvalidArgument`: `handle` or `puppetHandle` is null.
- `Ok`: puppet removed from renderer list.

Side effects:

- Removes animation player state for that puppet from this renderer.
- Puppet will no longer be advanced/drawn via this renderer's frame pipeline.

## 3.4 Frame execution APIs

---

<a id="api-njgbeginframe"></a>
### `NjgResult njgBeginFrame(RendererHandle handle, const FrameConfig* config)`

Purpose:

- Begin one logical SDK frame for a renderer.
- Intended usage scene: first call in every render loop iteration before ticking
  puppets and emitting commands.
- Prepares per-frame state and viewport-dependent render targets.

Parameters:

- `handle`: required renderer handle for frame begin.
- `config`: optional frame configuration.
  - If non-null and fields are positive, viewport is updated for this frame.
  - If null, previous viewport state is reused.
  - Width/height units are pixels in host render target space.

Returns:

- `InvalidArgument`: `handle` is null.
- `Ok`: frame began successfully.

Side effects:

- Clears renderer command buffer.
- Increments frame sequence.
- Lazily creates render/composite external targets via callback when needed.
- Resets transient queue accumulation for this frame cycle.

---

<a id="api-njgtickpuppet"></a>
### `NjgResult njgTickPuppet(PuppetHandle puppetHandle, double deltaSeconds)`

Purpose:

- Advance a single puppet simulation/animation state by elapsed time.
- Intended usage scene: per-frame update of each active puppet before draw emit.
- Keeps animation, parameter-driven motion, and node update graph in sync with
  host frame timing.

Parameters:

- `puppetHandle`: required puppet handle to update.
- `deltaSeconds`: elapsed time in seconds since last update for this puppet.
  - Expected non-negative finite value.
  - Excessively large spikes may cause visible animation jumps (host should clamp if needed).

Returns:

- `InvalidArgument`: `puppetHandle` is null.
- `Ok`: puppet updated.

Side effects:

- Updates global ticker and animation player state.
- Executes `inUpdate(); puppet.update();`.
- Mutates internal puppet state consumed by subsequent `njgEmitCommands`.

---

<a id="api-njgemitcommands"></a>
### `NjgResult njgEmitCommands(RendererHandle handle, CommandQueueView* outView)`

Purpose:

- Serialize all renderer-owned puppet draw operations into queue commands.
- Intended usage scene: after all `njgTickPuppet` calls, before host-side GPU
  submission.
- Provides backend-agnostic draw packets and state transitions for host
  renderer execution.

Parameters:

- `handle`: required renderer handle to emit from.
- `outView`: required writable output pointer for command view.
  - Receives pointer/count pair to transient command array.
  - Host must consume/copy data before next mutation point
    (`njgBeginFrame`, `njgEmitCommands`, `njgFlushCommandBuffer`, renderer destroy).

Returns:

- `InvalidArgument`: `handle` or `outView` is null.
- `Failure`: backend cast/setup failure.
- `Ok`: command view populated.

Side effects:

- Rebuilds renderer command buffer each call.
- Calls `puppet.draw()` for each loaded puppet.
- Serializes queue commands and clears per-puppet emitter queue.
- `outView.commands` points to internal transient memory.

Notes:

- Mask flow is validated during serialization.
- Empty mask apply packets may be converted to `EndMask`.
- Emitted command order is semantically meaningful and must be preserved.

---

<a id="api-njgflushcommandbuffer"></a>
### `void njgFlushCommandBuffer(RendererHandle handle)`

Purpose:

- Explicitly discard current command buffer for a renderer.
- Intended usage scene: after host has consumed/submitted command packets for
  the frame.

Parameters:

- `handle`: renderer handle whose command buffer should be cleared.
  - Null is allowed and treated as no-op.

Returns:

- None

Side effects:

- Resets command buffer length to zero.

---

<a id="api-njggetsharedbuffers"></a>
### `NjgResult njgGetSharedBuffers(RendererHandle handle, SharedBufferSnapshot* snapshot)`

Purpose:

- Expose shared geometry buffers (SoA layout) used by command packets.
- Intended usage scene: immediately after `njgEmitCommands`, when host resolves
  packet offsets/strides into actual vertex/uv/deform streams.

Parameters:

- `handle`: required renderer handle.
- `snapshot`: required writable output pointer.
  - Receives buffer slices and element counts.
  - Returned pointers are transient and tied to renderer/frame lifecycle.

Returns:

- `InvalidArgument`: `handle` or `snapshot` is null.
- `Ok`: snapshot filled.

Side effects:

- `snapshot` pointers reference internal transient storage.
- No deep copy is performed by SDK in this call.

---

<a id="api-njggetrendertargets"></a>
### `NjgRenderTargets njgGetRenderTargets(RendererHandle handle)`

Purpose:

- Query renderer-managed external render target handles and viewport dimensions.
- Intended usage scene: host backend integration that needs current target
  handles generated via texture callbacks.

Parameters:

- `handle`: renderer handle to query.
  - Null is allowed; function returns zero-initialized struct.

Returns:

- `NjgRenderTargets` value. Zero-initialized when handle is null.
- Includes render/composite target handles plus active viewport dimensions.

Side effects:

- None

---

<a id="api-njggettexturestats"></a>
### `TextureStats njgGetTextureStats(RendererHandle handle)`

Purpose:

- Return texture lifecycle counters observed by the renderer.
- Intended usage scene: diagnosing callback imbalance, leaked texture handles,
  and resource churn under load.

Parameters:

- `handle`: renderer handle to query.
  - Null is allowed; function returns zero-initialized stats.

Returns:

- `TextureStats` value. Zero-initialized when handle is null.
- Contains cumulative create/release counters tracked by renderer-side bridge.

Side effects:

- None

## 3.5 Puppet data and parameter APIs

---

<a id="api-njggetparameters"></a>
### `NjgResult njgGetParameters(PuppetHandle puppetHandle, NjgParameterInfo* buffer, size_t bufferLength, size_t* outCount)`

Purpose:

- Enumerate available puppet parameters and their metadata for UI/control
  binding.
- Intended usage scene: startup parameter discovery, editor inspector
  population, and runtime control mapping.

Parameters:

- `puppetHandle`: required puppet handle to inspect.
- `buffer`: optional writable array of `NjgParameterInfo`.
  - Pass null for count-only query.
  - If non-null, must contain at least `bufferLength` writable entries.
- `bufferLength`: number of entries available in `buffer`.
  - Ignored when `buffer` is null.
  - Must be at least discovered parameter count when fetching full table.
- `outCount`: required writable pointer receiving total parameter count.
  - Always written on success.

Returns:

- `InvalidArgument`: `puppetHandle` or `outCount` is null, or `bufferLength` is insufficient.
- `Ok`: success.

Side effects:

- Writes parameter count to `*outCount`.

Usage pattern:

- Call once with `buffer = null` to get count.
- Allocate `buffer`, call again to fetch entries.
- Cache UUIDs from this table; updates should use UUID, not localized names.

---

<a id="api-njgupdateparameters"></a>
### `NjgResult njgUpdateParameters(PuppetHandle puppetHandle, const PuppetParameterUpdate* updates, size_t updateCount)`

Purpose:

- Apply one or more parameter value updates to a puppet.
- Intended usage scene: driving expressions/rig from tracking input, gameplay
  logic, or external control protocols.

Parameters:

- `puppetHandle`: required target puppet handle.
- `updates`: pointer to updates array.
  - Null is allowed only when `updateCount == 0`.
  - Each entry references a parameter by UUID and value vector.
- `updateCount`: number of update entries in `updates`.
  - Zero means no-op and succeeds when handle is valid.

Returns:

- `InvalidArgument`: `puppetHandle` is null.
- `Ok`: updates processed.

Side effects:

- Mutates matching parameter values.
- Unknown UUID entries are ignored.
- Changes are consumed by subsequent puppet update/draw operations.

---

<a id="api-njggetpuppetextdata"></a>
### `NjgResult njgGetPuppetExtData(PuppetHandle puppetHandle, const char* key, const(ubyte)** outData, size_t* outLength)`

Purpose:

- Retrieve raw payload from puppet EXT section by key.
- Intended usage scene: loading custom binding/config blobs embedded in puppet
  file (for example, session mappings or app-specific metadata).

Parameters:

- `puppetHandle`: required puppet handle containing EXT data.
- `key`: required null-terminated key string.
  - Must match exact EXT key name.
  - Key lookup is case-sensitive unless producer guarantees otherwise.
- `outData`: required writable pointer receiving data pointer.
- `outLength`: required writable pointer receiving payload byte length.

Returns:

- `InvalidArgument`: required pointer is null.
- `Failure`: key missing or payload empty.
- `Ok`: payload returned.

Side effects:

- Uses internal static scratch buffer; pointer is invalidated by later calls.
- Host should copy returned payload immediately if persistence is needed.

## 3.6 Animation APIs

---

<a id="api-njgplayanimation"></a>
### `NjgResult njgPlayAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, bool loop, bool playLeadOut)`

Purpose:

- Start or restart named animation clip on target puppet.
- Intended usage scene: trigger-based animation playback (idle/gesture/reaction)
  from host logic.
- Renderer is required because animation players are stored per
  `(renderer, puppet)` pair.

Parameters:

- `handle`: required renderer handle owning animation player context.
- `puppetHandle`: required puppet handle to animate.
- `name`: required null-terminated animation clip name.
  - Must exist in puppet animation table.
- `loop`: playback loop flag.
  - `true`: loop continuously.
  - `false`: play once then stop/lead-out behavior applies.
- `playLeadOut`: whether clip lead-out section should be honored when
  applicable.

Returns:

- `InvalidArgument`: null handle/name or animation name not found.
- `Failure`: failed to prepare animation player.
- `Ok`: playback started.

Side effects:

- Creates animation player lazily for `(renderer, puppet)` pair.
- Alters active animation state used in subsequent `njgTickPuppet`.

---

<a id="api-njgpauseanimation"></a>
### `NjgResult njgPauseAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name)`

Purpose:

- Pause playback of one named animation clip for a puppet.
- Intended usage scene: temporary freeze of motion state without resetting
  timeline.

Parameters:

- `handle`: required renderer handle.
- `puppetHandle`: required puppet handle.
- `name`: required null-terminated animation name to pause.

Returns:

- `InvalidArgument`: null handle/name or animation name not found.
- `Failure`: failed to prepare animation player.
- `Ok`: paused.

Side effects:

- None

---

<a id="api-njgstopanimation"></a>
### `NjgResult njgStopAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, bool immediate)`

Purpose:

- Stop playback of one named animation clip.
- Intended usage scene: terminate clip due to state transitions, overrides, or
  cleanup on despawn.

Parameters:

- `handle`: required renderer handle.
- `puppetHandle`: required puppet handle.
- `name`: required null-terminated animation name.
- `immediate`: stop behavior selector.
  - `true`: force immediate stop.
  - `false`: allow non-immediate stop path when supported by player behavior.

Returns:

- `InvalidArgument`: null handle/name or animation name not found.
- `Failure`: failed to prepare animation player.
- `Ok`: stopped.

Side effects:

- None

---

<a id="api-njgseekanimation"></a>
### `NjgResult njgSeekAnimation(RendererHandle handle, PuppetHandle puppetHandle, const char* name, int frame)`

Purpose:

- Move a named animation clip playhead to a specific frame index.
- Intended usage scene: timeline scrubbing, deterministic synchronization, or
  editor preview controls.

Parameters:

- `handle`: required renderer handle.
- `puppetHandle`: required puppet handle.
- `name`: required null-terminated animation name.
- `frame`: destination frame index in clip frame space.
  - Host should pass value within clip range for predictable behavior.

Returns:

- `InvalidArgument`: null handle/name or animation name not found.
- `Failure`: failed to prepare animation player.
- `Ok`: seek applied.

Side effects:

- None

## 3.7 Puppet transform APIs

---

<a id="api-njgsetpuppetscale"></a>
### `NjgResult njgSetPuppetScale(PuppetHandle puppetHandle, float sx, float sy)`

Purpose:

- Set puppet render-space scale transform.
- Intended usage scene: host-controlled zoom, placement fitting, and UI-driven
  sizing adjustments.

Parameters:

- `puppetHandle`: required puppet handle.
- `sx`: horizontal scale factor.
  - `1.0` means original scale.
  - Negative values may mirror depending on host/render interpretation.
- `sy`: vertical scale factor.
  - `1.0` means original scale.

Returns:

- `InvalidArgument`: `puppetHandle` is null.
- `Ok`: scale updated.

Side effects:

- Marks puppet root transform changed.
- Affects render transform only (not physics state).
- New transform participates in next draw emission.

---

<a id="api-njgsetpuppettranslation"></a>
### `NjgResult njgSetPuppetTranslation(PuppetHandle puppetHandle, float tx, float ty)`

Purpose:

- Set puppet render-space translation transform.
- Intended usage scene: dragging mascot position, scripted placement, or camera
  independent 2D offset control.

Parameters:

- `puppetHandle`: required puppet handle.
- `tx`: horizontal translation in puppet render coordinate space.
- `ty`: vertical translation in puppet render coordinate space.

Returns:

- `InvalidArgument`: `puppetHandle` is null.
- `Ok`: translation updated.

Side effects:

- Marks puppet root transform changed.
- Affects render transform only (not physics state).
- Translation is applied in subsequent render command generation.

## 4. Struct and Field Reference

This section explains each struct in practical terms so host-side implementers
can map it to real rendering code without guessing.

## 4.1 Handle and enum fundamentals

### `RendererHandle` / `PuppetHandle`

Purpose:

- Opaque C handles returned by the SDK.
- Host treats them as identifiers only and must never dereference/cast them.

Concrete internal backing:

- `RendererHandle`:
  - Public type is `alias RendererHandle = void*`.
  - Internally points to a `UnityRenderer` object allocated by
    `njgCreateRenderer`.
  - `UnityRenderer` stores renderer-level state such as:
    - puppet list
    - command buffer
    - texture callback table
    - viewport fields and frame sequence
    - animation players mapped per puppet
- `PuppetHandle`:
  - Public type is `alias PuppetHandle = void*`.
  - Internally points to a loaded `Puppet` object.

What this is not:

- Not a graphics API resource handle.
- Not stable across process restart.
- Not valid after destroy/unload APIs.

Ownership summary:

- Allocated by SDK:
  - `RendererHandle` from `njgCreateRenderer`
  - `PuppetHandle` from `njgLoadPuppet`
- Released by SDK (triggered by host API call):
  - renderer object via `njgDestroyRenderer`
  - puppet object via `njgUnloadPuppet`
- Never released directly by host allocator calls.

Usage:

- `RendererHandle`: pass to frame/queue APIs.
- `PuppetHandle`: pass to puppet/parameter/animation APIs.

Lifetime:

- `RendererHandle` is valid from successful `njgCreateRenderer` until
  `njgDestroyRenderer`.
- `PuppetHandle` is valid from successful `njgLoadPuppet` until
  `njgUnloadPuppet` or owning renderer destruction.

### `NjgRenderCommandKind`

Purpose:

- Discriminant that tells host which union-like field in `NjgQueuedCommand`
  contains valid payload.

Values:

- `DrawPart`: draw one part using `partPacket`.
- `BeginDynamicComposite`: begin dynamic composite pass using `dynamicPass`.
- `EndDynamicComposite`: end dynamic composite pass using `dynamicPass`.
- `BeginMask`: start mask accumulation.
- `ApplyMask`: apply mask packet using `maskApplyPacket`.
- `BeginMaskContent`: begin drawing content affected by current mask.
- `EndMask`: close mask scope.

Host rule:

- Preserve command order exactly.
- Do not reorder across mask/composite boundaries.

## 4.2 Configuration structs

---

### `UnityRendererConfig`

Purpose:

- Initial configuration for `njgCreateRenderer`.
- Used to seed renderer viewport before first frame.

Fields:

- `int viewportWidth`
  - Initial viewport width in pixels.
  - Recommended `> 0`. Non-positive values are treated as unspecified.
- `int viewportHeight`
  - Initial viewport height in pixels.
  - Recommended `> 0`. Non-positive values are treated as unspecified.

Common usage:

- Pass same size as host render target at startup.
- Update per-frame later via `FrameConfig` when window size changes.

---

### `FrameConfig`

Purpose:

- Per-frame viewport input for `njgBeginFrame`.

Fields:

- `int viewportWidth`
  - Current frame viewport width in pixels.
- `int viewportHeight`
  - Current frame viewport height in pixels.

Behavior notes:

- If `FrameConfig*` is null in `njgBeginFrame`, previous viewport remains active.
- If fields are non-positive, viewport update is skipped.

## 4.3 Callback bridge struct

---

### `UnityResourceCallbacks`

Purpose:

- Bridge between SDK texture lifecycle and host graphics resources.
- Lets SDK request texture creation/update/release while host owns actual GPU
  object allocation policy.

Fields:

- `void* userData`
  - Opaque context pointer passed to all callbacks.
  - Typical value: host renderer/context struct pointer.
- `createTexture(width, height, channels, mipLevels, format, renderTarget, stencil, userData) -> size_t`
  - Called when SDK needs external handle for a texture/render target.
  - Must return stable non-zero host handle (`size_t`) on success.
  - Return `0` indicates unavailable/failed resource mapping.
- `updateTexture(handle, data, dataLen, width, height, channels, userData)`
  - Called after texture creation or when pixel payload must be uploaded.
  - `data` points to CPU bytes; host must validate `dataLen`.
- `releaseTexture(handle, userData)`
  - Called when SDK releases texture reference.
  - Host should free corresponding GPU-side resource mapping.

Contract notes:

- Callback pointers must stay valid for renderer lifetime.
- Handles returned here are later embedded in command packets
  (`textureHandles`, render targets).
- Implement callbacks as thread-safe if host may invoke SDK from multiple threads.

## 4.4 Queue container structs

---

### `NjgQueuedCommand`

Purpose:

- One serialized render command entry emitted by `njgEmitCommands`.

Fields:

- `NjgRenderCommandKind kind`
  - Selects which payload to read.
- `NjgPartDrawPacket partPacket`
  - Valid when `kind == DrawPart`.
- `NjgMaskApplyPacket maskApplyPacket`
  - Valid when `kind == ApplyMask`.
- `NjgDynamicCompositePass dynamicPass`
  - Valid for dynamic composite begin/end commands.
- `bool usesStencil`
  - Indicates command expects stencil path/state usage.

Host rule:

- Interpret only payload matching `kind`.
- Ignore unused payload fields for other kinds.

---

### `CommandQueueView`

Purpose:

- Lightweight view returned by `njgEmitCommands`.

Fields:

- `const(NjgQueuedCommand)* commands`
  - Pointer to first command entry.
  - Null when `count == 0`.
- `size_t count`
  - Number of valid commands.

Lifetime:

- Pointer is transient and owned by renderer.
- Copy immediately if you need persistence beyond current frame phase.

## 4.5 Draw and mask packet structs

---

### `NjgPartDrawPacket`

Purpose:

- Full draw payload for one renderable part.
- Contains transform, shading, textures, and geometry slice references.

Fields:

- `bool isMask`
  - True when part participates in mask-related flow.
- `bool renderable`
  - False means host should skip actual draw.
- `mat4 modelMatrix`
  - Part local/world transform matrix used in rendering pipeline.
- `mat4 renderMatrix`
  - Additional render-stage transform matrix.
- `float renderRotation`
  - Rotation component used by render pipeline.
- `vec3 clampedTint`
  - Multiplicative tint color (already clamped).
- `vec3 clampedScreen`
  - Screen/blend color component (already clamped).
- `float opacity`
  - Effective alpha-like multiplier.
- `float emissionStrength`
  - Emission intensity for emission-enabled paths.
- `float maskThreshold`
  - Threshold parameter used in mask processing.
- `int blendingMode`
  - Backend blend mode code from nijilive.
  - Host maps this value to graphics API blend state.
- `bool useMultistageBlend`
  - Indicates multistage blend logic is required.
- `bool hasEmissionOrBumpmap`
  - True when part references emission/bump-related resources.
- `size_t[3] textureHandles`
  - Host texture handles referenced by this draw.
- `size_t textureCount`
  - Number of valid entries in `textureHandles`.
- `vec2 origin`
  - Part origin/pivot in render coordinate context.
- `size_t vertexOffset`
  - Base offset into shared vertices SoA buffer.
- `size_t vertexAtlasStride`
  - Stride separating x lane and y lane.
- `size_t uvOffset`
  - Base offset into shared UV SoA buffer.
- `size_t uvAtlasStride`
  - Stride separating u lane and v lane.
- `size_t deformOffset`
  - Base offset into shared deform SoA buffer.
- `size_t deformAtlasStride`
  - Stride separating deform lanes.
- `const(ushort)* indices`
  - Pointer to index buffer data for this part.
- `size_t indexCount`
  - Number of valid indices.
- `size_t vertexCount`
  - Vertex count used by this draw.

Geometry interpretation:

- Fetch x/y with SoA rule:
  - `x = vertices[vertexOffset + i]`
  - `y = vertices[vertexOffset + vertexAtlasStride + i]`
- Same rule applies to UV and deform using their own offset/stride.

---

### `NjgMaskDrawPacket`

Purpose:

- Geometry/transform payload used for mask shape drawing.

Fields:

- `mat4 modelMatrix`
  - Model transform for mask geometry.
- `mat4 mvp`
  - Final model-view-projection matrix for mask pass.
- `vec2 origin`
  - Mask origin/pivot reference.
- `size_t vertexOffset`
  - Base offset into shared vertices.
- `size_t vertexAtlasStride`
  - Vertex SoA lane stride.
- `size_t deformOffset`
  - Base offset into shared deform data.
- `size_t deformAtlasStride`
  - Deform SoA lane stride.
- `const(ushort)* indices`
  - Index buffer pointer for mask geometry.
- `size_t indexCount`
  - Valid index count.
- `size_t vertexCount`
  - Vertex count for mask draw.

---

### `NjgMaskApplyPacket`

Purpose:

- Payload for `ApplyMask` command.
- Can carry either part packet or mask packet, selected by `kind`.

Fields:

- `MaskDrawableKind kind`
  - Selects active payload member semantics.
- `bool isDodge`
  - Indicates dodge-style mask behavior.
- `NjgPartDrawPacket partPacket`
  - Part payload path.
- `NjgMaskDrawPacket maskPacket`
  - Mask payload path.

Host rule:

- Interpret the matching packet based on `kind`.

---

### `NjgDynamicCompositePass`

Purpose:

- Describes dynamic composite render-target context switches.

Fields:

- `size_t[3] textures`
  - Color attachment handles for composite pass.
- `size_t textureCount`
  - Number of valid color handles.
- `size_t stencil`
  - Stencil attachment handle (0 means none).
- `vec2 scale`
  - Composite pass scale factor.
- `float rotationZ`
  - Composite pass Z rotation angle parameter.
- `bool autoScaled`
  - Indicates SDK auto-scaling was applied.
- `RenderResourceHandle origBuffer`
  - Original buffer handle to restore on pass end.
- `int[4] origViewport`
  - Original viewport snapshot (`x, y, width, height`).
- `int drawBufferCount`
  - Number of active draw buffers.
- `bool hasStencil`
  - Whether stencil attachment is active.

## 4.6 Renderer state snapshot structs

---

### `TextureStats`

Purpose:

- Aggregated texture lifecycle counters for diagnostics.

Fields:

- `size_t created`
  - Number of texture-create callback events observed.
- `size_t released`
  - Number of texture-release callback events observed.
- `size_t current`
  - Current live estimate (`created - released` at reporting time).

Use cases:

- Detect imbalance (created grows while released does not).
- Track resource churn during stress tests.

---

### `NjgRenderTargets`

Purpose:

- Snapshot of renderer's external target handles and active viewport.

Fields:

- `size_t renderFramebuffer`
  - Main render target handle.
- `size_t compositeFramebuffer`
  - Composite target handle.
- `size_t blendFramebuffer`
  - Blend-stage target handle.
- `int viewportWidth`
  - Active viewport width in pixels.
- `int viewportHeight`
  - Active viewport height in pixels.

Notes:

- Handle value `0` generally means "not available / not allocated".
- Exact mapping of these handles to host API objects is callback-defined.

## 4.7 Shared geometry buffer structs

---

### `NjgBufferSlice`

Purpose:

- Generic pointer-length pair for float array slices.

Fields:

- `const(float)* data`
  - Pointer to first float element.
- `size_t length`
  - Number of float elements, not bytes.

---

### `SharedBufferSnapshot`

Purpose:

- Frame-local view of shared SoA geometry buffers used by queue packets.

Fields:

- `NjgBufferSlice vertices`
  - Vertex coordinate storage (SoA).
- `NjgBufferSlice uvs`
  - UV coordinate storage (SoA).
- `NjgBufferSlice deform`
  - Deformation data storage (SoA).
- `size_t vertexCount`
  - Logical vertex element count.
- `size_t uvCount`
  - Logical UV element count.
- `size_t deformCount`
  - Logical deform element count.

Access pattern:

- Use packet offsets/strides to map each draw to this snapshot.
- Do not assume AoS layout.

Lifetime:

- Snapshot pointers are transient and must be treated as read-only borrowed data.
- Acquire/consume in same frame phase as `njgEmitCommands`.

## 4.8 Parameter structs

---

### `NjgParameterInfo`

Purpose:

- Metadata record returned by `njgGetParameters` for one parameter.

Fields:

- `uint uuid`
  - Stable numeric identifier used for update calls.
- `bool isVec2`
  - `true`: parameter semantically uses 2D value.
  - `false`: scalar parameter (use `.x` component).
- `vec2 min`
  - Minimum allowed range (component-wise).
- `vec2 max`
  - Maximum allowed range (component-wise).
- `vec2 defaults`
  - Default parameter value.
- `const(char)* name`
  - Pointer to UTF-8 parameter name bytes.
- `size_t nameLength`
  - Name length in bytes (not including implicit null terminator).

Notes:

- Prefer UUID for runtime updates; names may change or be localized.
- `name` pointer validity follows SDK-owned memory lifetime; copy if needed.

---

### `PuppetParameterUpdate`

Purpose:

- Input record used by `njgUpdateParameters` to set one parameter value.

Fields:

- `uint parameterUuid`
  - Target parameter UUID obtained from `NjgParameterInfo.uuid`.
- `vec2 value`
  - New value.
  - Scalar parameters read `value.x`.
  - Vec2 parameters use both components.

Batch usage:

- Pass an array of these records for multi-parameter updates in one call.

## 5. Usage Examples

Before reading the examples, assume the following host-side helper functions
exist. These are pseudo-code helpers, not SDK exports.

```cpp
// Receives SDK log callback messages.
// Parameters:
//   message: UTF-8 bytes (not guaranteed null-terminated)
//   length:  message byte length
//   userData: host-defined logger/context pointer
// Returns:
//   None
void LogFn(const char* message, size_t length, void* userData);
// Reference in nijiv:
//   - callback implementation: nijiv/source/app.d (logCallback)
//   - registration call site:  nijiv/source/app.d (api.setLogCallback)

// Converts SDK command packets + shared SoA buffers into backend draw calls.
// Parameters:
//   view: command list emitted by njgEmitCommands
//   snapshot: geometry/deform buffers matching the same frame
// Returns:
//   None
void RenderWithHost(const CommandQueueView& view, const SharedBufferSnapshot& snapshot);
// Reference in nijiv:
//   - call site:               nijiv/source/app.d (gfx.renderCommands)
//   - OpenGL implementation:   nijiv/source/opengl/opengl_backend.d (renderCommands)
//   - Vulkan implementation:   nijiv/source/vulkan/vulkan_backend.d (renderCommands)
//   - DirectX implementation:  nijiv/source/directx/directx_backend.d (renderCommands)

// Demo-only lookup helper to find parameter UUID by readable name.
// Parameters:
//   params: parameter table from njgGetParameters
//   name: target parameter name, e.g. "ParamAngleX"
// Returns:
//   UUID on success. Host should define fallback behavior for "not found".
uint FindParamUuid(const std::vector<NjgParameterInfo>& params, const char* name);
// Reference in nijiv:
//   - no direct equivalent helper found in current nijiv source.
//   - implement in host app as a small linear search over NjgParameterInfo.name.
```

## 5.1 Minimal startup and frame loop

```cpp
// 1) Register diagnostics output before initialization so startup/load errors
// are visible in host logs.
njgSetLogCallback(LogFn, userData);

// 2) Initialize SDK runtime once per process lifetime.
njgRuntimeInit();

// 3) Create one renderer context. This owns frame state and command buffers.
RendererHandle renderer{};
UnityRendererConfig rcfg{1280, 720};
njgCreateRenderer(&rcfg, &callbacks, &renderer);

// 4) Load one puppet and register it into this renderer.
PuppetHandle puppet{};
njgLoadPuppet(renderer, inxPath, &puppet);

while (running) {
  // 5) Begin frame with current host viewport size in pixels.
  FrameConfig fcfg{viewportW, viewportH};
  njgBeginFrame(renderer, &fcfg);

  // 6) Advance puppet simulation/animation by frame delta time (seconds).
  njgTickPuppet(puppet, deltaSec);

  // 7) Emit draw commands and fetch shared geometry for this same frame.
  CommandQueueView view{};
  SharedBufferSnapshot snapshot{};
  njgEmitCommands(renderer, &view);
  njgGetSharedBuffers(renderer, &snapshot);

  // 8) Host backend consumes packets and snapshot to submit GPU work.
  RenderWithHost(view, snapshot);

  // 9) Release transient command memory after host finished consuming it.
  njgFlushCommandBuffer(renderer);
}

// 10) Deterministic teardown order: puppet -> renderer -> runtime.
njgUnloadPuppet(renderer, puppet);
njgDestroyRenderer(renderer);
njgRuntimeTerm();
```

## 5.2 Parameter update pattern

```cpp
// First call: query required parameter array size.
size_t count = 0;
njgGetParameters(puppet, nullptr, 0, &count);

// Second call: fetch full parameter metadata table.
std::vector<NjgParameterInfo> params(count);
njgGetParameters(puppet, params.data(), params.size(), &count);

// Host helper resolves UUID from name for demonstration.
// In production, prefer caching UUIDs once at load time.
PuppetParameterUpdate u{};
u.parameterUuid = FindParamUuid(params, "ParamAngleX");

// value.x is used for scalar parameters; value.y is ignored in that case.
u.value = {0.2f, 0.0f};

// Apply one update entry.
njgUpdateParameters(puppet, &u, 1);
```

## 5.3 Multiple puppets in one renderer

```cpp
// Two puppets registered into the same renderer.
PuppetHandle p1{}, p2{};
njgLoadPuppet(renderer, path1, &p1);
njgLoadPuppet(renderer, path2, &p2);

// Both puppets are updated, then one emission contains both command sets.
njgBeginFrame(renderer, &fcfg);
njgTickPuppet(p1, dt);
njgTickPuppet(p2, dt);
njgEmitCommands(renderer, &view); // includes both p1 and p2
```

Behavior note:

- This pattern is useful when host wants one combined command stream.
- Per-puppet visibility filtering is not provided by current API.

## 5.4 One puppet per renderer

```cpp
// Independent renderer domains for strict isolation.
RendererHandle r1{}, r2{};
njgCreateRenderer(&cfg, &callbacks, &r1);
njgCreateRenderer(&cfg, &callbacks, &r2);
```

Use separate renderers when you need strict per-puppet command separation.

## 6. Operational Notes and Constraints

- Command and shared-buffer pointers are transient. Copy if you need persistence.
- `njgFlushCommandBuffer` should be called after queue consumption.
- Current API does not provide renderer-side visibility filtering per puppet.
- Thread safety is not guaranteed by this layer; use serialized calls unless you
  add host-side synchronization.
- Set a log callback early to capture diagnostics from loading/emission.

## 7. Troubleshooting

### Symptom: no commands emitted

Check:

- `njgBeginFrame` is called
- at least one puppet is loaded in the renderer
- `njgTickPuppet` is called before `njgEmitCommands`

### Symptom: geometry pointer becomes invalid

Cause:

- host retained pointers beyond frame lifetime

Fix:

- copy data immediately from `CommandQueueView` / `SharedBufferSnapshot`

### Symptom: animation API returns `InvalidArgument`

Check:

- animation name exists in puppet
- renderer/puppet handle pair is valid



