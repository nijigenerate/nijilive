using System;
using System.Collections.Generic;
using Nijilive.Unity.Interop;

namespace Nijilive.Unity.Managed;

#if UNITY_5_3_OR_NEWER
using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// MonoBehaviour glue to drive nijilive-unity each frame and emit CommandBuffers.
/// This is a minimal sample; adapt for your pipeline (URP/HDRP/Built-in).
/// </summary>
public sealed class NijiliveBehaviour : MonoBehaviour
{
    [Tooltip("Puppet asset path (StreamingAssets or absolute).")]
    public string PuppetPath;

    [Tooltip("Viewport size; defaults to Screen dimensions when zero.")]
    public Vector2Int Viewport;

    [Tooltip("Material used for part rendering.")]
    public Material PartMaterial;

    [Tooltip("Material used for composite passes (optional).")]
    public Material CompositeMaterial;

    [Header("Property Config (URP)")]
    public CommandExecutor.UnityCommandBufferSink.PropertyConfig PropertyConfig =
        new CommandExecutor.UnityCommandBufferSink.PropertyConfig();

    [Serializable]
    public struct TextureBindingEntry
    {
        public ulong Handle;
        public Texture Texture;
    }

    [Tooltip("Manual mapping from native texture handles to Unity textures.")]
    public TextureBindingEntry[] TextureBindings;

    private NijiliveRenderer _renderer;
    private Puppet _puppet;
    private CommandBuffer _cb;
    private UnityCommandBufferSink _sink;
    private readonly TextureRegistry _textures = new();
    private SharedBufferUploader _buffers;

    [ContextMenu("Reload Puppet")]
    public void ReloadPuppet()
    {
        if (_renderer == null) return;
        _puppet?.Dispose();
        if (!string.IsNullOrWhiteSpace(PuppetPath))
            _puppet = _renderer.LoadPuppet(PuppetPath);
    }

    private void Start()
    {
        var vp = Viewport;
        if (vp.x <= 0 || vp.y <= 0)
            vp = new Vector2Int(Screen.width, Screen.height);

        EnsureMaterials();
        _renderer = NijiliveRenderer.Create(vp.x, vp.y);
        if (!string.IsNullOrWhiteSpace(PuppetPath))
            _puppet = _renderer.LoadPuppet(ResolvePath(PuppetPath));

        RegisterTextures();
        _cb = new CommandBuffer { name = "nijilive" };
        _buffers = new SharedBufferUploader();
        _sink = new UnityCommandBufferSink(_cb, PartMaterial, CompositeMaterial, _textures, _buffers, null, PropertyConfig);
        Camera.main?.AddCommandBuffer(CameraEvent.BeforeImageEffects, _cb);
    }

    private void Update()
    {
        if (_renderer == null) return;
        var vp = Viewport;
        if (vp.x <= 0 || vp.y <= 0)
            vp = new Vector2Int(Screen.width, Screen.height);

        _renderer.BeginFrame(vp.x, vp.y);
        if (_puppet != null)
            _renderer.TickPuppet(_puppet, Time.deltaTime);

        var commands = _renderer.DecodeCommands();
        var shared = _renderer.GetSharedBuffers();
        _buffers.Upload(shared.Raw);
        CommandExecutor.Execute(commands, shared.Raw, _sink, vp.x, vp.y);
    }

    private void OnDestroy()
    {
        if (_cb != null && Camera.main != null)
            Camera.main.RemoveCommandBuffer(CameraEvent.BeforeImageEffects, _cb);
        _cb?.Dispose();
        _textures.Clear();
        _buffers?.Dispose();
        _puppet?.Dispose();
        _renderer?.Dispose();
    }

    private void RegisterTextures()
    {
        if (TextureBindings == null) return;
        foreach (var entry in TextureBindings)
        {
            if (entry.Handle == 0 || entry.Texture == null) continue;
            _textures.Register((nuint)entry.Handle, new UnityTextureBinding(entry.Texture));
        }
    }

    private void EnsureMaterials()
    {
        var shader = Shader.Find(PropertyConfig.ShaderName ?? "Nijilive/UnlitURP");
        if (PartMaterial == null)
        {
            PartMaterial = new Material(shader) { name = "Nijilive/PartMaterial" };
        }
        if (CompositeMaterial == null)
        {
            CompositeMaterial = new Material(shader) { name = "Nijilive/CompositeMaterial" };
        }
    }

    private static string ResolvePath(string path)
    {
        if (System.IO.Path.IsPathRooted(path))
            return path;
        return System.IO.Path.Combine(Application.streamingAssetsPath, path);
    }
}
#endif
