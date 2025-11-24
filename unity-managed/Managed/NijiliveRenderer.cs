using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Nijilive.Unity.Interop;

namespace Nijilive.Unity.Managed
{
/// <summary>
/// Minimal managed wrapper around the nijilive-unity native plugin.
/// Handles renderer/puppet lifecycles, command emission, and shared buffer access.
/// </summary>
public sealed class NijiliveRenderer : IDisposable
{
    private static readonly NijiliveNative.CreateTextureDelegate CreateTextureThunk = OnCreateTexture;
    private static readonly NijiliveNative.UpdateTextureDelegate UpdateTextureThunk = OnUpdateTexture;
    private static readonly NijiliveNative.ReleaseTextureDelegate ReleaseTextureThunk = OnReleaseTexture;

        private static NijiliveRenderer _current;

    private IntPtr _renderer;
    private readonly List<Puppet> _puppets = new();
    private readonly TextureRegistry _registry = new();
    private nuint _nextHandle = 1;
    private GCHandle _selfHandle;
    private bool _disposed;
        private CommandStream.Command[] _decodedCache;

    private NijiliveRenderer()
    {
        _selfHandle = GCHandle.Alloc(this);
        _current = this;
    }

    public TextureRegistry TextureRegistry => _registry;

    public static NijiliveRenderer Create(int viewportWidth, int viewportHeight)
    {
        var renderer = new NijiliveRenderer();
        var cfg = new NijiliveNative.UnityRendererConfig
        {
            ViewportWidth = viewportWidth,
            ViewportHeight = viewportHeight,
        };
        var callbacks = renderer.BuildCallbacks();
        EnsureOk(NijiliveNative.CreateRenderer(ref cfg, ref callbacks, out var handle), "CreateRenderer");
        renderer._renderer = handle;
        return renderer;
    }

    public Puppet LoadPuppet(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new ArgumentNullException(nameof(path));
        var res = NijiliveNative.LoadPuppet(_renderer, path, out var puppetPtr);
        EnsureOk(res, "LoadPuppet");
        var puppet = new Puppet(this, puppetPtr);
        _puppets.Add(puppet);
        return puppet;
    }

    public void BeginFrame(int viewportWidth, int viewportHeight)
    {
        var cfg = new NijiliveNative.FrameConfig { ViewportWidth = viewportWidth, ViewportHeight = viewportHeight };
        EnsureOk(NijiliveNative.BeginFrame(_renderer, ref cfg), "BeginFrame");
    }

    public void TickPuppet(Puppet puppet, double deltaSeconds)
    {
        if (puppet is null) throw new ArgumentNullException(nameof(puppet));
        EnsureOk(NijiliveNative.TickPuppet(puppet.Handle, deltaSeconds), "TickPuppet");
    }

    public unsafe ReadOnlySpan<NijiliveNative.NjgQueuedCommand> EmitCommands()
    {
        EnsureOk(NijiliveNative.EmitCommands(_renderer, out var view), "EmitCommands");
        if (view.Count == 0 || view.Commands == IntPtr.Zero)
            return ReadOnlySpan<NijiliveNative.NjgQueuedCommand>.Empty;
        return new ReadOnlySpan<NijiliveNative.NjgQueuedCommand>((void*)view.Commands, checked((int)view.Count));
    }

    /// <summary>
    /// Convenience helper to decode the native command span into managed DTOs for rendering.
    /// </summary>
    public IReadOnlyList<CommandStream.Command> DecodeCommands()
    {
        var native = EmitCommands();
        if (native.IsEmpty)
        {
            _decodedCache = Array.Empty<CommandStream.Command>();
            return _decodedCache;
        }
        var decoded = CommandStream.Decode(native);
        _decodedCache = decoded as CommandStream.Command[] ?? new List<CommandStream.Command>(decoded).ToArray();
        return _decodedCache;
    }

    public NijiliveSharedBuffers GetSharedBuffers()
    {
        EnsureOk(NijiliveNative.GetSharedBuffers(_renderer, out var snapshot), "GetSharedBuffers");
        return new NijiliveSharedBuffers(snapshot);
    }

    internal void UnloadPuppet(Puppet puppet)
    {
        if (puppet == null || puppet.Handle == IntPtr.Zero) return;
        NijiliveNative.UnloadPuppet(_renderer, puppet.Handle);
        _puppets.Remove(puppet);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        foreach (var puppet in _puppets.ToArray())
        {
            puppet.Dispose();
        }
        _puppets.Clear();

        if (_renderer != IntPtr.Zero)
        {
            NijiliveNative.DestroyRenderer(_renderer);
            _renderer = IntPtr.Zero;
        }
        _registry.Clear();
        if (_selfHandle.IsAllocated) _selfHandle.Free();
        if (ReferenceEquals(_current, this)) _current = null;
    }

    internal static void EnsureOk(NijiliveNative.NjgResult result, string context)
    {
        if (result == NijiliveNative.NjgResult.Ok) return;
        throw new NijiliveInteropException($"{context} failed: {result}");
    }

    private NijiliveNative.UnityResourceCallbacks BuildCallbacks()
    {
        return new NijiliveNative.UnityResourceCallbacks
        {
            UserData = GCHandle.ToIntPtr(_selfHandle),
            CreateTexture = Marshal.GetFunctionPointerForDelegate(CreateTextureThunk),
            UpdateTexture = Marshal.GetFunctionPointerForDelegate(UpdateTextureThunk),
            ReleaseTexture = Marshal.GetFunctionPointerForDelegate(ReleaseTextureThunk),
        };
    }

    private static NijiliveRenderer FromUserData(IntPtr userData)
    {
        if (userData != IntPtr.Zero)
        {
            var handle = GCHandle.FromIntPtr(userData);
            return (NijiliveRenderer)handle.Target!;
        }
        if (_current == null) throw new InvalidOperationException("Renderer userData is null");
        return _current;
    }

    private static nuint OnCreateTexture(int width, int height, int channels, int mipLevels, int format, bool renderTarget, bool stencil, IntPtr userData)
    {
        var renderer = FromUserData(userData);
        var handle = renderer._nextHandle++;
#if UNITY_5_3_OR_NEWER
        UnityEngine.Debug.Log($"[Nijilive] OnCreateTexture: Handle={handle}, W={width}, H={height}, Channels={channels}, Format={format}, RT={renderTarget}");
#endif
#if UNITY_5_3_OR_NEWER
        if (renderTarget)
        {
            var rt = new UnityEngine.RenderTexture(width, height, stencil ? 16 : 0, UnityEngine.RenderTextureFormat.ARGB32)
            {
                name = $"Nijilive/RT/{handle}",
                autoGenerateMips = mipLevels > 1,
                useMipMap = mipLevels > 1
            };
            renderer._registry.Register(handle, new UnityTextureBinding(rt));
        }
        else
        {
            var tex = new UnityEngine.Texture2D(width, height, UnityEngine.TextureFormat.RGBA32, mipLevels > 1, false)
            {
                name = $"Nijilive/Tex/{handle}"
            };
            renderer._registry.Register(handle, new UnityTextureBinding(tex));
        }
#endif
        return handle;
    }

    private static void OnUpdateTexture(nuint handle, IntPtr data, nuint dataLen, int width, int height, int channels, IntPtr userData)
    {
        var renderer = FromUserData(userData);
        if (!renderer._registry.TryGet(handle, out var binding)) return;
#if UNITY_5_3_OR_NEWER
        if (binding.NativeObject is UnityEngine.Texture2D tex)
        {
            var len = checked((int)dataLen);
            var tmp = new byte[len];
            Marshal.Copy(data, tmp, 0, len);
            tex.LoadRawTextureData(tmp);
            tex.Apply();
        }
#endif
    }

    private static void OnReleaseTexture(nuint handle, IntPtr userData)
    {
        var renderer = FromUserData(userData);
        renderer._registry.Unregister(handle);
    }
}

public sealed class Puppet : IDisposable
{
    internal IntPtr Handle { get; private set; }
    private readonly NijiliveRenderer _owner;
    private bool _disposed;

    internal Puppet(NijiliveRenderer owner, IntPtr handle)
    {
        _owner = owner;
        Handle = handle;
    }

    public unsafe void UpdateParameters(ReadOnlySpan<NijiliveNative.PuppetParameterUpdate> updates)
    {
        if (_disposed) throw new ObjectDisposedException(nameof(Puppet));
        if (updates.IsEmpty) return;
        fixed (NijiliveNative.PuppetParameterUpdate* ptr = updates)
        {
            var res = NijiliveNative.UpdateParameters(Handle, (IntPtr)ptr, (nuint)updates.Length);
            if (res != NijiliveNative.NjgResult.Ok)
            {
                throw new NijiliveInteropException($"UpdateParameters failed: {res}");
            }
        }
    }

    public IReadOnlyList<ParameterDescriptor> GetParameters()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(Puppet));

        NijiliveRenderer.EnsureOk(NijiliveNative.GetParameters(Handle, IntPtr.Zero, 0, out var count), "GetParameters(count)");
        if (count == 0) return Array.Empty<ParameterDescriptor>();

        var infos = new NijiliveNative.ParameterInfo[count];
        unsafe
        {
            fixed (NijiliveNative.ParameterInfo* ptr = infos)
            {
                NijiliveRenderer.EnsureOk(NijiliveNative.GetParameters(Handle, (IntPtr)ptr, count, out _), "GetParameters(data)");
            }
        }

        var list = new List<ParameterDescriptor>(infos.Length);
        foreach (var info in infos)
        {
            var name = Marshal.PtrToStringUTF8(info.Name, checked((int)info.NameLength)) ?? string.Empty;
            list.Add(new ParameterDescriptor(
                info.Uuid,
                name,
                info.IsVec2,
                info.Min,
                info.Max,
                info.Defaults));
        }
        return list;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (Handle != IntPtr.Zero)
        {
            _owner.UnloadPuppet(this);
            Handle = IntPtr.Zero;
        }
    }
}

/// <summary>
/// Provides typed spans over the shared SOA buffers.
/// </summary>
public sealed class NijiliveSharedBuffers
{
    public float[] Vertices { get; }
    public float[] Uvs { get; }
    public float[] Deform { get; }
    public nuint VertexCount { get; }
    public nuint UvCount { get; }
    public nuint DeformCount { get; }
    public NijiliveNative.SharedBufferSnapshot Raw { get; }

    internal unsafe NijiliveSharedBuffers(NijiliveNative.SharedBufferSnapshot snapshot)
    {
        Raw = snapshot;
        Vertices = CopySlice(snapshot.Vertices);
        Uvs = CopySlice(snapshot.Uvs);
        Deform = CopySlice(snapshot.Deform);
        VertexCount = snapshot.VertexCount;
        UvCount = snapshot.UvCount;
        DeformCount = snapshot.DeformCount;
    }

    private static unsafe float[] CopySlice(NijiliveNative.NjgBufferSlice slice)
    {
        if (slice.Length == 0 || slice.Data == IntPtr.Zero) return Array.Empty<float>();
        var len = checked((int)slice.Length);
        var arr = new float[len];
        var span = new ReadOnlySpan<float>((void*)slice.Data, len);
        span.CopyTo(arr);
        return arr;
    }
}

    public sealed class NijiliveInteropException : Exception
    {
        public NijiliveInteropException(string message) : base(message) { }
    }

    public struct ParameterDescriptor
    {
        public uint Uuid;
        public string Name;
        public bool IsVec2;
        public NijiliveNative.Vec2 Min;
        public NijiliveNative.Vec2 Max;
        public NijiliveNative.Vec2 Defaults;

        public ParameterDescriptor(
            uint uuid,
            string name,
            bool isVec2,
            NijiliveNative.Vec2 min,
            NijiliveNative.Vec2 max,
            NijiliveNative.Vec2 defaults)
        {
            Uuid = uuid;
            Name = name;
            IsVec2 = isVec2;
            Min = min;
            Max = max;
            Defaults = defaults;
        }
    }
}
