using System;
using System.Collections.Generic;
#if UNITY_5_3_OR_NEWER
using UnityEngine;
#endif

namespace Nijilive.Unity.Managed
{
/// <summary>
/// Maps native texture handle ids to managed objects.
/// The actual Unity objects are abstracted via the ITextureBinding interface to allow
/// headless/editor testing.
/// </summary>
public sealed class TextureRegistry
{
    private nuint _nextHandle = 1;
    private readonly Dictionary<nuint, ITextureBinding> _bindings = new();

    public bool Contains(nuint handle) => _bindings.ContainsKey(handle);

    public nuint Allocate(ITextureBinding binding)
    {
        var handle = _nextHandle++;
        Register(handle, binding);
        return handle;
    }

    public void Register(nuint handle, ITextureBinding binding)
    {
        if (handle == 0) throw new ArgumentException("Handle must be non-zero", nameof(handle));
        _bindings[handle] = binding ?? throw new ArgumentNullException(nameof(binding));
    }

    public bool TryGet(nuint handle, out ITextureBinding binding)
    {
        if (handle == 0)
        {
            binding = null!;
            return false;
        }
        return _bindings.TryGetValue(handle, out binding!);
    }

    public void Unregister(nuint handle)
    {
        if (handle == 0) return;
        if (_bindings.TryGetValue(handle, out var binding))
        {
            binding.Dispose();
            _bindings.Remove(handle);
        }
    }

    public void Clear()
    {
        foreach (var kv in _bindings)
        {
            kv.Value.Dispose();
        }
        _bindings.Clear();
        _nextHandle = 1;
    }

    /// <summary>
    /// Enumerate all registered texture bindings (for debugging / editor tools).
    /// </summary>
    public IEnumerable<KeyValuePair<nuint, ITextureBinding>> Enumerate()
    {
        return _bindings;
    }
}

/// <summary>
/// Abstracts Unity texture/rendertexture bindings for tests/editor.
/// </summary>
public interface ITextureBinding : IDisposable
{
    object NativeObject { get; }
}

#if UNITY_5_3_OR_NEWER
/// <summary>
/// Unity binding that wraps Texture/RenderTexture.
/// </summary>
public sealed class UnityTextureBinding : ITextureBinding
{
    public Texture Texture { get; }
    public object NativeObject => Texture;

    public UnityTextureBinding(Texture texture)
    {
        Texture = texture;
    }

    public static UnityTextureBinding FromColor(Color color, string name)
    {
        var tex = new Texture2D(1, 1, TextureFormat.RGBA32, false) { name = name };
        tex.SetPixel(0, 0, color);
        tex.Apply();
        tex.hideFlags = HideFlags.HideAndDontSave;
        return new UnityTextureBinding(tex);
    }

    public void Dispose()
    {
        // Do not destroy here; ownership is managed by caller/Unity lifecycle.
    }
}
#endif
}
