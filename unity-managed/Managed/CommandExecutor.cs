using System;
using System.Collections.Generic;
using Nijilive.Unity.Interop;

namespace Nijilive.Unity.Managed;

/// <summary>
/// Walks decoded commands and dispatches them to a render sink.
/// The sink can be implemented for Unity CommandBuffer, a preview window, or tests.
/// </summary>
public static class CommandExecutor
{
    public static void Execute(
        IReadOnlyList<CommandStream.Command> commands,
        NijiliveNative.SharedBufferSnapshot sharedBuffers,
        IRenderCommandSink sink,
        int viewportWidth,
        int viewportHeight)
    {
        if (commands == null) throw new ArgumentNullException(nameof(commands));
        if (sink == null) throw new ArgumentNullException(nameof(sink));

        sink.Begin(sharedBuffers, viewportWidth, viewportHeight);
        foreach (var cmd in commands)
        {
            switch (cmd)
            {
                case CommandStream.DrawPart part:
                    sink.DrawPart(part.Part);
                    break;
                case CommandStream.DrawMask mask:
                    sink.DrawMask(mask.Mask);
                    break;
                case CommandStream.ApplyMask apply:
                    sink.ApplyMask(apply.Apply);
                    break;
                case CommandStream.BeginDynamicComposite beginDyn:
                    sink.BeginDynamicComposite(beginDyn.Pass);
                    break;
                case CommandStream.EndDynamicComposite endDyn:
                    sink.EndDynamicComposite(endDyn.Pass);
                    break;
                case CommandStream.BeginMask beginMask:
                    sink.BeginMask(beginMask.UsesStencil);
                    break;
                case CommandStream.BeginMaskContent:
                    sink.BeginMaskContent();
                    break;
                case CommandStream.EndMask:
                    sink.EndMask();
                    break;
                case CommandStream.BeginComposite:
                    sink.BeginComposite();
                    break;
                case CommandStream.DrawCompositeQuad composite:
                    sink.DrawCompositeQuad(composite.Composite);
                    break;
                case CommandStream.EndComposite:
                    sink.EndComposite();
                    break;
                default:
                    sink.Unknown(cmd);
                    break;
            }
        }
        sink.End();
    }
}

/// <summary>
/// Rendering sink that consumes decoded commands.
/// Implement this in Unity to convert to CommandBuffer/material bindings.
/// </summary>
public interface IRenderCommandSink
{
    void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight);
    void End();
    void DrawPart(CommandStream.DrawPacket part);
    void DrawMask(CommandStream.MaskPacket mask);
    void ApplyMask(CommandStream.MaskApplyPacket apply);
    void BeginDynamicComposite(CommandStream.DynamicCompositePass pass);
    void EndDynamicComposite(CommandStream.DynamicCompositePass pass);
    void BeginMask(bool usesStencil);
    void BeginMaskContent();
    void EndMask();
    void BeginComposite();
    void DrawCompositeQuad(CommandStream.CompositePacket composite);
    void EndComposite();
    void Unknown(CommandStream.Command cmd);
}

/// <summary>
/// Simple sink that records commands for debugging or editor preview logic.
/// </summary>
public sealed class RecordingSink : IRenderCommandSink
{
    public readonly List<CommandStream.Command> Recorded = new();
    public NijiliveNative.SharedBufferSnapshot SharedBuffers;
    public int ViewportWidth;
    public int ViewportHeight;

    public void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight)
    {
        SharedBuffers = sharedBuffers;
        ViewportWidth = viewportWidth;
        ViewportHeight = viewportHeight;
    }
    public void End() { }
    public void DrawPart(CommandStream.DrawPacket part) => Recorded.Add(new CommandStream.DrawPart(part));
    public void DrawMask(CommandStream.MaskPacket mask) => Recorded.Add(new CommandStream.DrawMask(mask));
    public void ApplyMask(CommandStream.MaskApplyPacket apply) => Recorded.Add(new CommandStream.ApplyMask(apply));
    public void BeginDynamicComposite(CommandStream.DynamicCompositePass pass) => Recorded.Add(new CommandStream.BeginDynamicComposite(pass));
    public void EndDynamicComposite(CommandStream.DynamicCompositePass pass) => Recorded.Add(new CommandStream.EndDynamicComposite(pass));
    public void BeginMask(bool usesStencil) => Recorded.Add(new CommandStream.BeginMask(usesStencil));
    public void BeginMaskContent() => Recorded.Add(new CommandStream.BeginMaskContent());
    public void EndMask() => Recorded.Add(new CommandStream.EndMask());
    public void BeginComposite() => Recorded.Add(new CommandStream.BeginComposite());
    public void DrawCompositeQuad(CommandStream.CompositePacket composite) => Recorded.Add(new CommandStream.DrawCompositeQuad(composite));
    public void EndComposite() => Recorded.Add(new CommandStream.EndComposite());
    public void Unknown(CommandStream.Command cmd) => Recorded.Add(cmd);
}

#if UNITY_5_3_OR_NEWER
using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// Unity-specific sink that emits draw calls into a CommandBuffer.
/// This is a minimal sample; adapt material/shader bindings to your project.
/// </summary>
public sealed class UnityCommandBufferSink : IRenderCommandSink
{
    public sealed class PropertyConfig
    {
        public string ShaderName = "Nijilive/UnlitURP";
        public string MainTex = "_BaseMap"; // URP Lit/Unlit default
        public string MaskTex = "_MaskTex";
        public string ExtraTex = "_ExtraTex";
        public string Opacity = "_BaseColorAlpha";
        public string Tint = "_BaseColor"; // URP base color
        public string ScreenTint = "_ScreenTint";
        public string Emission = "_EmissionColor";
        public string MaskThreshold = "_MaskThreshold";
        public string BlendMode = "_BlendMode";
        public string UseMultistageBlend = "_UseMultistageBlend";
        public string UsesStencil = "_UsesStencil";
        public string VertexBuffer = "_VertexBuffer";
        public string UvBuffer = "_UvBuffer";
        public string DeformBuffer = "_DeformBuffer";
        public string SrcBlend = "_SrcBlend";
        public string DstBlend = "_DstBlend";
        public string BlendOp = "_BlendOp";
        public string ZWrite = "_ZWrite";
        public string StencilRef = "_StencilRef";
        public string StencilComp = "_StencilComp";
        public string StencilPass = "_StencilPass";
    }

    private readonly CommandBuffer _cb;
    private readonly Material _partMaterial;
    private readonly Material _compositeMaterial;
    private readonly Mesh _quadMesh;
    private readonly TextureRegistry _textures;
    private readonly SharedBufferUploader _buffers;
    private readonly MaterialPropertyBlock _mpb = new();
    private readonly PropertyConfig _props;
    private readonly int _vertProp;
    private readonly int _uvProp;
    private readonly int _deformProp;
    private bool _stencilActive;
    private NijiliveNative.SharedBufferSnapshot _snapshot;
    private int _viewportW;
    private int _viewportH;

    public UnityCommandBufferSink(CommandBuffer cb,
                                  Material partMaterial,
                                  Material compositeMaterial,
                                  TextureRegistry textures,
                                  SharedBufferUploader buffers,
                                  Mesh quadMesh = null,
                                  PropertyConfig props = null)
    {
        _cb = cb ?? throw new ArgumentNullException(nameof(cb));
        _partMaterial = partMaterial ?? throw new ArgumentNullException(nameof(partMaterial));
        _compositeMaterial = compositeMaterial ?? partMaterial;
        _textures = textures ?? throw new ArgumentNullException(nameof(textures));
        _buffers = buffers ?? throw new ArgumentNullException(nameof(buffers));
        _quadMesh = quadMesh ?? GenerateQuad();
        _props = props ?? new PropertyConfig();
        _vertProp = Shader.PropertyToID(_props.VertexBuffer);
        _uvProp = Shader.PropertyToID(_props.UvBuffer);
        _deformProp = Shader.PropertyToID(_props.DeformBuffer);
    }

    public void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight)
    {
        _cb.Clear();
        _snapshot = sharedBuffers;
        _stencilActive = false;
        _viewportW = viewportWidth;
        _viewportH = viewportHeight;
        if (_buffers.VertexBuffer != null) _cb.SetGlobalBuffer(_vertProp, _buffers.VertexBuffer);
        if (_buffers.UvBuffer != null) _cb.SetGlobalBuffer(_uvProp, _buffers.UvBuffer);
        if (_buffers.DeformBuffer != null) _cb.SetGlobalBuffer(_deformProp, _buffers.DeformBuffer);
    }

    public void End() { }
    public void BeginMask(bool usesStencil)
    {
        _stencilActive = usesStencil;
    }
    public void BeginMaskContent() { }
    public void EndMask() { }
    public void BeginComposite() { }
    public void EndComposite() { }
    public void BeginDynamicComposite(CommandStream.DynamicCompositePass pass) { }
    public void EndDynamicComposite(CommandStream.DynamicCompositePass pass) { }

    public void DrawPart(CommandStream.DrawPacket part)
    {
        var matrix = ToMatrix(part.ModelMatrix);
        BindTextures(_partMaterial, part.TextureHandles);
        _mpb.Clear();
        _mpb.SetFloat(_props.Opacity, part.Opacity);
        _mpb.SetColor(_props.Tint, new Color(part.ClampedTint.X, part.ClampedTint.Y, part.ClampedTint.Z, 1));
        _mpb.SetColor(_props.ScreenTint, new Color(part.ClampedScreen.X, part.ClampedScreen.Y, part.ClampedScreen.Z, 1));
        _mpb.SetColor(_props.Emission, new Color(part.EmissionStrength, part.EmissionStrength, part.EmissionStrength, 1));
        _mpb.SetFloat(_props.MaskThreshold, part.MaskThreshold);
        _mpb.SetInt(_props.BlendMode, part.BlendingMode);
        _mpb.SetInt(_props.UseMultistageBlend, part.UseMultistageBlend ? 1 : 0);
        _mpb.SetInt(_props.UsesStencil, _stencilActive ? 1 : 0);
        ApplyBlend(ref _mpb, part.BlendingMode);
        ApplyStencil(ref _mpb, _stencilActive ? StencilMode.TestEqual : StencilMode.Off);
        var mesh = BuildMesh(part.VertexOffset, part.VertexAtlasStride, part.UvOffset, part.UvAtlasStride, part.VertexCount, part.IndexCount, part.Indices);
        _cb.DrawMesh(mesh, matrix, _partMaterial, 0, 0, _mpb);
    }

    public void DrawMask(CommandStream.MaskPacket mask)
    {
        var matrix = ToMatrix(mask.ModelMatrix);
        var mesh = BuildMesh(mask.VertexOffset, mask.VertexAtlasStride, 0, 0, mask.VertexCount, mask.IndexCount, mask.Indices);
        _mpb.Clear();
        _mpb.SetInt(_props.UsesStencil, 1);
        ApplyStencil(ref _mpb, StencilMode.WriteReplace);
        ApplyBlend(ref _mpb, 0);
        _cb.DrawMesh(mesh, matrix, _partMaterial, 0, 0, _mpb);
    }

    public void ApplyMask(CommandStream.MaskApplyPacket apply)
    {
        // URP: set a property to switch mask mode
        _mpb.Clear();
        _mpb.SetFloat(_props.MaskThreshold, apply.IsDodge ? 1f : 0f);
    }

    public void DrawCompositeQuad(CommandStream.CompositePacket composite)
    {
        var matrix = Matrix4x4.identity;
        _mpb.Clear();
        _mpb.SetFloat(_props.Opacity, composite.Opacity);
        _mpb.SetColor(_props.Tint, new Color(composite.Tint.X, composite.Tint.Y, composite.Tint.Z, 1));
        _mpb.SetColor(_props.ScreenTint, new Color(composite.ScreenTint.X, composite.ScreenTint.Y, composite.ScreenTint.Z, 1));
        _mpb.SetInt(_props.BlendMode, composite.BlendingMode);
        ApplyBlend(ref _mpb, composite.BlendingMode);
        _cb.DrawMesh(_quadMesh, matrix, _compositeMaterial, 0, 0, _mpb);
    }

    public void Unknown(CommandStream.Command cmd)
    {
        Debug.LogWarning($"Unknown command: {cmd.Kind}");
    }

    private static Matrix4x4 ToMatrix(NijiliveNative.Mat4 m)
    {
        var mat = new Matrix4x4
        {
            m00 = m.M11, m01 = m.M12, m02 = m.M13, m03 = m.M14,
            m10 = m.M21, m11 = m.M22, m12 = m.M23, m13 = m.M24,
            m20 = m.M31, m21 = m.M32, m22 = m.M33, m23 = m.M34,
            m30 = m.M41, m31 = m.M42, m32 = m.M43, m33 = m.M44,
        };
        return mat;
    }

    private static Mesh GenerateQuad()
    {
        var mesh = new Mesh { name = "Nijilive/Quad" };
        mesh.vertices = new[]
        {
            new Vector3(-0.5f, -0.5f, 0),
            new Vector3( 0.5f, -0.5f, 0),
            new Vector3( 0.5f,  0.5f, 0),
            new Vector3(-0.5f,  0.5f, 0),
        };
        mesh.uv = new[]
        {
            new Vector2(0,0), new Vector2(1,0),
            new Vector2(1,1), new Vector2(0,1),
        };
        mesh.triangles = new[] { 0,1,2, 0,2,3 };
        mesh.RecalculateNormals();
        return mesh;
    }

    private void BindTextures(Material mat, ReadOnlyMemory<nuint> handles)
    {
        var span = handles.Span;
        Texture tex0 = null, tex1 = null, tex2 = null;
        tex0 = ResolveTexture(span, 0, Color.white);
        tex1 = ResolveTexture(span, 1, Color.white);
        tex2 = ResolveTexture(span, 2, Color.black);
        if (tex0 == null) tex0 = PlaceholderWhite();
        if (tex1 == null) tex1 = PlaceholderWhite();
        if (tex2 == null) tex2 = PlaceholderBlack();
        mat.SetTexture(_props.MainTex, tex0);
        mat.SetTexture(_props.MaskTex, tex1);
        mat.SetTexture(_props.ExtraTex, tex2);
    }

    private Mesh BuildMesh(nuint vertexOffset, nuint vertexStride, nuint uvOffset, nuint uvStride, nuint vertexCount, nuint indexCount, IntPtr indicesPtr)
    {
        var count = checked((int)vertexCount);
        var verts = new Vector3[count];
        var uvs = new Vector2[count];
        var vSlice = _snapshot.Vertices;
        var uvSlice = _snapshot.Uvs;
        unsafe
        {
            var vPtr = (float*)vSlice.Data;
            var uvPtr = (float*)uvSlice.Data;
            for (int i = 0; i < count; i++)
            {
                var vx = vPtr[vertexOffset + (nuint)i];
                var vy = vPtr[vertexOffset + vertexStride + (nuint)i];
                verts[i] = new Vector3(vx, vy, 0);
                if (uvSlice.Data != IntPtr.Zero && uvSlice.Length > 0)
                {
                    var ux = uvPtr[uvOffset + (nuint)i];
                    var uy = uvPtr[uvOffset + uvStride + (nuint)i];
                    uvs[i] = new Vector2(ux, uy);
                }
            }
        }

        var mesh = new Mesh();
        mesh.SetVertices(verts);
        mesh.SetUVs(0, uvs);

        if (indexCount > 0 && indicesPtr != IntPtr.Zero)
        {
            var icount = checked((int)indexCount);
            var indices = new ushort[icount];
            unsafe
            {
                var span = new ReadOnlySpan<ushort>((void*)indicesPtr, icount);
                span.CopyTo(indices);
            }
            var ints = new int[icount];
            for (int i = 0; i < icount; i++) ints[i] = indices[i];
            mesh.SetIndices(ints, MeshTopology.Triangles, 0);
        }
        else
        {
            // Fallback draw as strip if no indices
            var seq = new int[count];
            for (int i = 0; i < count; i++) seq[i] = i;
            mesh.SetIndices(seq, MeshTopology.Triangles, 0);
        }

        mesh.RecalculateBounds();
        return mesh;
    }

    private enum StencilMode
    {
        Off,
        WriteReplace,
        TestEqual,
    }

    private void ApplyStencil(ref MaterialPropertyBlock block, StencilMode mode)
    {
        switch (mode)
        {
            case StencilMode.WriteReplace:
                block.SetInt(_props.StencilRef, 1);
                block.SetInt(_props.StencilComp, (int)UnityEngine.Rendering.CompareFunction.Always);
                block.SetInt(_props.StencilPass, (int)UnityEngine.Rendering.StencilOp.Replace);
                break;
            case StencilMode.TestEqual:
                block.SetInt(_props.StencilRef, 1);
                block.SetInt(_props.StencilComp, (int)UnityEngine.Rendering.CompareFunction.Equal);
                block.SetInt(_props.StencilPass, (int)UnityEngine.Rendering.StencilOp.Keep);
                break;
            default:
                block.SetInt(_props.StencilRef, 0);
                block.SetInt(_props.StencilComp, (int)UnityEngine.Rendering.CompareFunction.Always);
                block.SetInt(_props.StencilPass, (int)UnityEngine.Rendering.StencilOp.Keep);
                break;
        }
    }

    private void ApplyBlend(ref MaterialPropertyBlock block, int mode)
    {
        // mode 0: alpha blend, mode 1: additive
        var src = mode == 1 ? UnityEngine.Rendering.BlendMode.One : UnityEngine.Rendering.BlendMode.SrcAlpha;
        var dst = mode == 1 ? UnityEngine.Rendering.BlendMode.One : UnityEngine.Rendering.BlendMode.OneMinusSrcAlpha;
        var op = UnityEngine.Rendering.BlendOp.Add;
        block.SetInt(_props.SrcBlend, (int)src);
        block.SetInt(_props.DstBlend, (int)dst);
        block.SetInt(_props.BlendOp, (int)op);
        block.SetInt(_props.ZWrite, 0);

        // Adjust render queue for additive to render later.
        _partMaterial.renderQueue = mode == 1 ? (int)UnityEngine.Rendering.RenderQueue.Transparent + 50 : (int)UnityEngine.Rendering.RenderQueue.Transparent;
        _compositeMaterial.renderQueue = _partMaterial.renderQueue;
    }

    private static Texture2D _white, _black;
    private Texture ResolveTexture(ReadOnlySpan<nuint> handles, int index, Color fallbackColor)
    {
        if (handles.Length <= index) return null;
        var handle = handles[index];
        if (handle == 0) return null;
        if (_textures.TryGet(handle, out var binding))
            return binding.NativeObject as Texture;

        // Create RenderTexture for composite/dynamic if size hint available
        if (_viewportW > 0 && _viewportH > 0)
        {
            var rt = new RenderTexture(Mathf.Max(1, _viewportW), Mathf.Max(1, _viewportH), 0, RenderTextureFormat.ARGB32)
            {
                name = $"Nijilive/AutoRT/{handle}",
                autoGenerateMips = false,
                useMipMap = false
            };
            _textures.Register(handle, new UnityTextureBinding(rt));
            return rt;
        }

        var auto = UnityTextureBinding.FromColor(fallbackColor, $"Nijilive/AutoColor/{handle}");
        _textures.Register(handle, auto);
        return auto.Texture;
    }

    private static Texture2D PlaceholderWhite()
    {
        if (_white != null) return _white;
        _white = new Texture2D(1, 1, TextureFormat.RGBA32, false) { name = "Nijilive/White" };
        _white.SetPixel(0, 0, Color.white);
        _white.Apply();
        _white.hideFlags = HideFlags.HideAndDontSave;
        return _white;
    }
    private static Texture2D PlaceholderBlack()
    {
        if (_black != null) return _black;
        _black = new Texture2D(1, 1, TextureFormat.RGBA32, false) { name = "Nijilive/Black" };
        _black.SetPixel(0, 0, Color.black);
        _black.Apply();
        _black.hideFlags = HideFlags.HideAndDontSave;
        return _black;
    }
}
#endif
