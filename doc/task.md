# Rendering Command Stream Tasks

- [x] Definition: finalize the `RenderCommandEmitter` interface so nodes hand off references instead of baked packets.
- [x] GraphBuilder: remove `RenderCommandBuffer`/`RenderCommandData` and store emitter builders per pass.
- [x] Nodes: update Part/Composite/DynamicComposite to enqueue emitter closures rather than constructing packets.
- [x] Cache & Tests: drop the puppet command cache and introduce a `RecordingEmitter` so unit tests can validate the new flow.
- [x] OpenGL: turn the old `RenderQueue` into the OpenGL emitter, including packet generation and per-frame buffer uploads.
- [x] Docs: refresh `doc/rendering.md` / `doc/new_rendering.md` to describe the emitter-based pipeline.
