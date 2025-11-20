# Rendering Pipeline Overview

This document summarises the emitter-based rendering flow implemented in `nijilive`.
For historical context and deep dives see `doc/new_rendering.md`.

## Stages

1. **Task Scheduling** – Every frame the puppet rebuilds `RenderGraphBuilder` via the task scheduler
   (Init → Parameters → PreProcess → … → Final). Nodes push/pop composite scopes and enqueue work
   through `RenderGraphBuilder.enqueueItem` using delegates that accept a `RenderCommandEmitter`.
2. **Graph Playback** – `Puppet.draw()` checks whether the graph has pending work. If so it calls
   `commandEmitter.beginFrame(renderBackend, gpuState)` followed by `renderGraph.playback(commandEmitter)`
   and finishes with `commandEmitter.endFrame`. Immediate drawing is used as a fallback when no graph
   data exists (e.g. before the first update or when rendering is disabled).
3. **Emitter Implementations** – Backends provide their own emitter implementations.
   The OpenGL build reuses `RenderQueue` as the emitter and constructs `PartDrawPacket`/
   `MaskApplyPacket` data on demand. Unit tests use `RecordingEmitter`, which records command order
   and derived packets for assertions.

## Backends

- `RenderCommandEmitter` is the minimal interface used by GraphBuilder closures. It exposes begin/end
  hooks for frame scopes, composite scopes, dynamic composites, masking, and part/composite draws.
- OpenGL: `nijilive.core.render.backends.opengl.queue.RenderQueue` implements the interface.
  Its `beginFrame` method uploads dirty shared atlases once per frame, and each draw call translates
  node references into packets before invoking the existing backend entry points.
- Tests: `RecordingEmitter` (see `source/nijilive/core/render/tests/render_queue.d`) captures command
  sequences plus the packets derived from nodes, allowing high-level tests to assert ordering without
  depending on the GPU backend.

## Shared Buffer Uploads

- Shared vertex/UV/deform atlases live in `nijilive.core.render.shared_deform_buffer`. Nodes register
  their `Vec*Array` slices and receive persistent offsets.
- During `beginFrame`, the emitter checks atlas dirty flags and uploads the packed arrays into the
  backend buffers once. Subsequent draw calls only reference offsets, so the GPU work remains minimal.

## Tests

- `source/nijilive/core/render/tests/render_queue.d` uses the `RecordingEmitter` helper to validate
  GraphBuilder ordering, mask handling, composites, and dynamic composites.
- Because the emitter records the derived packets, existing assertions about opacity, masking order,
  etc., remain effective without requiring a real backend.
