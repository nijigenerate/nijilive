using System;
using System.Collections.Generic;
using Nijilive.Unity.Interop;
#if UNITY_5_3_OR_NEWER
using UnityEngine;
using UnityEngine.Rendering;
#endif

namespace Nijilive.Unity.Managed
{

#if UNITY_5_3_OR_NEWER
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
    public UnityCommandBufferSink.PropertyConfig PropertyConfig =
        new UnityCommandBufferSink.PropertyConfig();

    [Tooltip("Use RenderPipeline hook to drive frames automatically.")]
    public bool UseRenderPipelineHook = true;

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
    private TextureRegistry _textures;
    private SharedBufferUploader _buffers;
    private static readonly List<NijiliveBehaviour> Active = new();
    private static bool _hooked;
    private int _lastFrameRun = -1;

    // Exposed for editor tooling (Parameter editor, etc.)
    public NijiliveRenderer Renderer => _renderer;
    public Puppet Puppet => _puppet;

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
        _textures = _renderer.TextureRegistry;
        if (!string.IsNullOrWhiteSpace(PuppetPath))
            _puppet = _renderer.LoadPuppet(ResolvePath(PuppetPath));

        RegisterTextures();

        _cb = new CommandBuffer { name = "nijilive" };
        _buffers = new SharedBufferUploader();
        _sink = new UnityCommandBufferSink(_cb, PartMaterial, CompositeMaterial, _textures, _buffers, null, PropertyConfig);
        Camera.main?.AddCommandBuffer(CameraEvent.BeforeImageEffects, _cb);
        RegisterHook();
    }

    private void Update()
    {
        if (_renderer == null) return;
        if (UseRenderPipelineHook && _lastFrameRun == Time.frameCount) return;
        RunFrame(Time.deltaTime);
    }

    private void OnEnable()
    {
        if (!Active.Contains(this)) Active.Add(this);
        RegisterHook();
    }

    private void OnDisable()
    {
        Active.Remove(this);
        if (Active.Count == 0 && _hooked)
        {
#if UNITY_5_3_OR_NEWER
            UnityEngine.Rendering.RenderPipelineManager.beginFrameRendering -= OnBeginFrameRendering;
#endif
            _hooked = false;
        }
    }

    private void OnBeginFrameRendering(UnityEngine.Rendering.ScriptableRenderContext ctx, Camera[] cams)
    {
        if (_renderer == null) return;
        if (_lastFrameRun == Time.frameCount) return;
        RunFrame(Time.deltaTime);
    }

    private void RunFrame(float delta)
    {
        _lastFrameRun = Time.frameCount;
        var vp = Viewport;
        if (vp.x <= 0 || vp.y <= 0)
            vp = new Vector2Int(Screen.width, Screen.height);

        _renderer.BeginFrame(vp.x, vp.y);
        if (_puppet != null)
            _renderer.TickPuppet(_puppet, delta);

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

    private void RegisterHook()
    {
#if UNITY_5_3_OR_NEWER
        if (UseRenderPipelineHook && !_hooked)
        {
            UnityEngine.Rendering.RenderPipelineManager.beginFrameRendering += OnBeginFrameRendering;
            _hooked = true;
        }
#endif
    }
}
#endif
}
