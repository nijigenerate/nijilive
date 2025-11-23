# Nijilive Unity Plugin

This directory contains everything you need to run `nijilive` puppets directly inside Unity.

- Native DLL: `nijilive-unity.dll` (fully statically linked runtime)
- Managed DLL: `Nijilive.Unity.Managed.dll` (`NijiliveUnity.csproj`, `netstandard2.1`)
- C# sources: `Interop/*.cs`, `Managed/*.cs`, `Editor/*.cs`
- Shader: `Shaders/NijiliveUnlit.shader` (URP unlit-style)

Following this README, you should be able to **drop the plugin into a Unity project and run a puppet** with minimal setup.

---

## 1. Requirements

- Unity 2021 or newer (URP project recommended)
- Windows x86_64 (the native DLL is built for Win64)
- GPU: anything that can run URP

---

## 2. Building the DLLs

If you already built the repository, you should have:

- Native DLL: `nijilive/nijilive-unity.dll`
- Managed DLL: `nijilive/unity-managed/bin/Debug/netstandard2.1/Nijilive.Unity.Managed.dll`

To rebuild from source, use **Visual Studio 2022 Developer PowerShell**:

```powershell
cd path\to\nijigenerate\nijilive

# Ensure ldc 1.41 is on PATH (adjust path as needed)
$env:PATH = "C:\opt\ldc-1.41\bin;" + $env:PATH

# Build Unity DLL (static runtime, dllimport disabled)
$env:DFLAGS="--dllimport=none -link-defaultlib-shared=false"
dub build -q --config=unity-dll --compiler=ldc2 --force

# Build managed C# assembly
cd unity-managed
dotnet build NijiliveUnity.csproj -c Debug
```

Outputs:

- `nijilive-unity.dll` / `.lib` / `.exp` in `nijilive/`
- `Nijilive.Unity.Managed.dll` in `nijilive/unity-managed/bin/Debug/netstandard2.1/`

---

## 3. Unity project layout

In your Unity project, we recommend the following layout:

```text
<YourUnityProject>/
  Assets/
    Plugins/
      x86_64/
        nijilive-unity.dll                 # native plugin

    Nijilive/
      Runtime/
        Nijilive.Unity.Managed.dll         # managed assembly
        Interop/
          NijiliveNative.cs
          IsExternalInit.cs
        Managed/
          NijiliveRenderer.cs
          NijiliveBehaviour.cs
          CommandStream.cs
          CommandExecutor.cs
          TextureRegistry.cs
          SharedBufferUploader.cs
        Shaders/
          NijiliveUnlit.shader

      Editor/
        NijiliveBehaviourEditor.cs
        NijiliveParameterEditorWindow.cs
```

The simplest way is to copy the entire `unity-managed` folder into `Assets/Nijilive` and then adjust namespaces/assembly definitions only if you want to split things up.

Notes:

- Place `nijilive-unity.dll` under `Assets/Plugins/x86_64/` so Unity can find and load it on Windows.
- Place `Nijilive.Unity.Managed.dll` under a runtime folder (`Assets/Nijilive/Runtime/` or similar).

---

## 4. Puppet assets

Prepare your `nijilive` puppet files (`.inp` / `.inx`) and their textures inside the Unity project.

Suggested structure:

```text
<YourUnityProject>/
  Assets/
    StreamingAssets/
      Puppets/
        MyPuppet.inp
        # Referenced textures etc. (nijilive resolves these)
```

`NijiliveBehaviour` resolves relative `PuppetPath` from `Application.streamingAssetsPath`. For example:

- If you set `PuppetPath = "Puppets/MyPuppet.inp"`, it will try to load `Assets/StreamingAssets/Puppets/MyPuppet.inp`.

You can also use an absolute filesystem path if you prefer.

---

## 5. Scene setup

1. Open your Unity project and create an empty GameObject in a scene (e.g., `NijiliveRenderer`).
2. Add the `NijiliveBehaviour` component to that GameObject  
   (it lives in the `Nijilive.Unity.Managed` namespace).
3. In the Inspector, configure:

- **Puppet Path**  
  - Example: `Puppets/MyPuppet.inp` (relative to `StreamingAssets`)
- **Viewport**  
  - Leave `(0,0)` to automatically use `Screen.width x Screen.height`.
- **Part Material / Composite Material**  
  - If left null, they are auto-created from `Shader.Find("Nijilive/UnlitURP")`.
- **Property Config**  
  - Only adjust if your shader property names differ from the defaults.
- **Texture Bindings**  
  - Only needed for manual overrides; by default textures are auto-created and managed.

4. Ensure your scene has a Camera and URP is configured as the active render pipeline.
5. Enter Play mode.

At runtime, `NijiliveBehaviour` will:

- Create a renderer via `nijilive-unity.dll`
- Load the puppet
- Each frame:
  - Call `BeginFrame` / `TickPuppet` / `EmitCommands` / `GetSharedBuffers`
  - Build a `CommandBuffer` via `UnityCommandBufferSink`
  - Attach the buffer at `CameraEvent.BeforeImageEffects`

You should see the puppet rendered with the unlit URP shader.

---

## 6. Editing puppet parameters in the Editor

The plugin includes an Editor window for adjusting puppet parameters (1D and 2D) at runtime.

### 6.1 Opening the parameter editor

1. In Unity’s top menu, select: `Nijilive/Parameter Editor`.
2. The `NijiliveParameterEditorWindow` will open.

### 6.2 Usage

1. Select a GameObject in the scene that has a `NijiliveBehaviour` component.
2. The parameter editor’s `Target` field will automatically pick that behaviour.
3. Make sure you are in Play mode and the puppet is loaded.
4. Click **Load Parameters** if the list does not appear automatically.

The window will display each puppet parameter:

- Name and UUID
- 1D parameters: a single `Value` slider (`min.x`–`max.x`)
- 2D parameters: `X` and `Y` sliders (`min.x`–`max.x`, `min.y`–`max.y`)

Behaviour:

- Moving sliders updates the desired values in the editor window.
- Clicking **Apply** sends the current values to the native side via `njgUpdateParameters`, updating the puppet.
- Clicking **Reload** re-queries the parameter list from the DLL (useful after puppet changes).

---

## 7. File layout overview

- `Interop/NijiliveNative.cs`  
  P/Invoke definitions that mirror the C ABI of `nijilive-unity.dll` (structs, enums, exported functions).

- `Managed/NijiliveRenderer.cs`  
  High-level wrapper around the native renderer:
  - Creates/destroys renderers and puppets
  - Calls `njgBeginFrame` / `njgEmitCommands` / `njgGetSharedBuffers`
  - Implements Unity texture callbacks (`UnityResourceCallbacks`) for auto resource creation.

- `Managed/Puppet` (inner type in `NijiliveRenderer.cs`)  
  - Holds a puppet handle
  - Provides `UpdateParameters` and `GetParameters` (UUID, min/max, defaults, 1D/2D flag).

- `Managed/CommandStream.cs`  
  Converts native `NjgQueuedCommand` into managed record types:
  - `DrawPart`, `DrawMask`, `ApplyMask`, `DynamicCompositePass`, etc.

- `Managed/CommandExecutor.cs` / `UnityCommandBufferSink`  
  - Walk decoded commands and emit Unity `CommandBuffer` calls.
  - URP-oriented sink with blend/stencil/material property configuration (`PropertyConfig`).

- `Managed/NijiliveBehaviour.cs`  
  - MonoBehaviour that owns a `NijiliveRenderer` and a single puppet.
  - Handles frame ticking, CommandBuffer creation, and hook registration.

- `Managed/TextureRegistry.cs` / `SharedBufferUploader.cs`  
  - Maps texture handle IDs to `Texture/RenderTexture`.
  - Uploads shared SOA buffers into `ComputeBuffer` / `GraphicsBuffer`.

- `Editor/NijiliveBehaviourEditor.cs`  
  - Custom inspector for `NijiliveBehaviour` (Browse / Reload buttons, property grouping).

- `Editor/NijiliveParameterEditorWindow.cs`  
  - Dedicated parameter editor window for 1D/2D parameter sliders and Apply/Reload.

- `Shaders/NijiliveUnlit.shader`  
  - URP unlit shader that matches `UnityCommandBufferSink.PropertyConfig`:
    - Texture slots, opacity, tint/screen tint, emission, mask threshold, blend/stencil settings, etc.

---

## 8. Troubleshooting

- **P/Invoke / DLL not found**
  - Verify `nijilive-unity.dll` is under `Assets/Plugins/x86_64/`.
  - In the plugin import settings, make sure it is enabled for Windows x86_64 only.

- **Nothing is drawn**
  - Check the Unity Console for `NijiliveInteropException`.
  - Confirm `PuppetPath` is correct and the file exists under `StreamingAssets` (or the absolute path).
  - Ensure there is an active camera and URP is configured as the render pipeline.

- **Parameter Editor shows nothing**
  - Enter Play mode and verify the puppet is loaded (no errors).
  - Select the GameObject with `NijiliveBehaviour`.
  - Use `Nijilive/Parameter Editor` and press **Load Parameters**.

---

## 9. Customization

- **Custom shaders/materials**
  - Adjust `UnityCommandBufferSink.PropertyConfig` to match your own shader property names (`_BaseMap`, `_Color`, etc.).
  - Use `Shaders/NijiliveUnlit.shader` as a starting point and tweak RenderQueue / Blend / Stencil as needed.

- **Different render pipelines**
  - For HDRP or Built-in, implement your own sink based on `IRenderCommandSink` and replace or extend `UnityCommandBufferSink`.

The goal is that, with this layout, you can **drop the DLL and C# code into your project, add `NijiliveBehaviour` to a GameObject, set the puppet path, and hit Play** to see your puppet running. 
