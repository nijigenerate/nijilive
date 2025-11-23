# Nijilive Unity Managed Stubs

Managed C# bindings for `nijilive-unity.dll`. This mirrors the C ABI described in `doc/plan.md`:

- P/Invoke surface in `Interop/NijiliveNative.cs` maps all exported structs/enums/functions.
- `Managed/NijiliveRenderer.cs` offers a minimal lifecycle wrapper (renderer creation, puppet load/unload, frame tick, command emission, shared buffer access).
- `Managed/CommandStream.cs` decodes native `NjgQueuedCommand` into managed DTOs (`DrawPart`, `DrawMask`, etc.).
- `Managed/CommandExecutor.cs` walks the decoded commands and dispatches them to an `IRenderCommandSink` (for CommandBuffer integration or editor previews). Includes a Unity URP-oriented `CommandBuffer` sink behind `UNITY_5_3_OR_NEWER`.
- `Managed/NijiliveBehaviour.cs` provides a sample MonoBehaviour that runs the frame loop and emits a `CommandBuffer` (placeholder rendering).
- `Managed/TextureRegistry.cs` maps native texture handles to managed texture bindings (Unity wrapper included).
- `Managed/SharedBufferUploader.cs` uploads shared SOA buffers into `ComputeBuffer`/`GraphicsBuffer` for shaders.
- `Shaders/NijiliveUnlit.shader` is a URP Unlit-style shader matching the property names used by the sink.
- Build as a Unity plugin companion: `dotnet build unity-managed/NijiliveUnity.csproj` (target: `netstandard2.1`, unsafe enabled).

Usage (outline):
1. Place `nijilive-unity.dll` next to the managed assembly inside your Unity project.
2. Call `NijiliveRenderer.Create()` to boot the renderer; load puppets via `LoadPuppet`.
3. Each frame: `BeginFrame`, `TickPuppet`, `EmitCommands` (to translate into Unity `CommandBuffer`s), and `GetSharedBuffers` to upload SOA data to `ComputeBuffer`/`NativeArray`.
4. Dispose renderer/puppets to release native handles.

Extending:
- Implement `IRenderCommandSink` for your pipeline (URP/HDRP/Built-in) to bind textures/materials and issue actual draw calls (UnityCommandBufferSink is a placeholder).
- Populate `TextureRegistry` from `TextureHandles` in `DrawPart`/`DynamicCompositePass` and bind them to materials.
- Upload `SharedBufferSnapshot` into `ComputeBuffer`/`GraphicsBuffer` and use them in shaders (sample behaviour wires `SharedBufferUploader` into the sink; still needs real shader hookup).
- Populate `UnityResourceCallbacks` when the native side starts using Unity-driven resource allocation.
- Add translation helpers that convert `NjgQueuedCommand` into concrete URP/HDRP/Built-in draw commands.
