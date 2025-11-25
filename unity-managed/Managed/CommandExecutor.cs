using System;
using System.Collections.Generic;
using Nijilive.Unity.Interop;
#if UNITY_5_3_OR_NEWER
using UnityEngine;
using UnityEngine.Rendering;
#endif

namespace Nijilive.Unity.Managed
{
    public static class CommandExecutor
    {
        public static void Execute(
            IReadOnlyList<CommandStream.Command> commands,
            NijiliveNative.SharedBufferSnapshot sharedBuffers,
            IRenderCommandSink sink,
            int viewportWidth,
            int viewportHeight,
            float pixelsPerUnit = 100f)
        {
            if (commands == null) throw new ArgumentNullException(nameof(commands));
            if (sink == null) throw new ArgumentNullException(nameof(sink));

            sink.Begin(sharedBuffers, viewportWidth, viewportHeight, pixelsPerUnit);
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

    public interface IRenderCommandSink
    {
        void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight, float pixelsPerUnit);
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

    public sealed class RecordingSink : IRenderCommandSink
    {
        public readonly List<CommandStream.Command> Recorded = new();
        public NijiliveNative.SharedBufferSnapshot SharedBuffers;
        public int ViewportWidth;
        public int ViewportHeight;
        public float PixelsPerUnit;

        public void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight, float pixelsPerUnit)
        {
            SharedBuffers = sharedBuffers;
            ViewportWidth = viewportWidth;
            ViewportHeight = viewportHeight;
            PixelsPerUnit = pixelsPerUnit;
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
    public sealed class UnityCommandBufferSink : IRenderCommandSink
    {
        public sealed class PropertyConfig
        {
            public string ShaderName = "Nijilive/UnlitURP";
            public string MainTex = "_BaseMap";
            public string MaskTex = "_MaskTex";
            public string ExtraTex = "_ExtraTex";
            public string Opacity = "_BaseColorAlpha";
            public string Tint = "_BaseColor";
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
        private readonly Stack<RenderTargetIdentifier> _targetStack = new();
        private readonly Stack<RenderTexture> _compositeTargets = new();
        private readonly Stack<float> _ppuStack = new();
        private readonly Stack<ProjectionState> _projectionStack = new();
        private bool _inDynamicComposite;
        private int _dynRtWidth;
        private int _dynRtHeight;
        private RenderTargetIdentifier _currentTarget = BuiltinRenderTextureType.CameraTarget;
        private bool _stencilActive;
        private NijiliveNative.SharedBufferSnapshot _snapshot;
        private int _viewportW;
        private int _viewportH;
        private float _pixelsPerUnit;
        private ProjectionState _currentProjection;

        private struct ProjectionState
        {
            public int Width;
            public int Height;
            public float PixelsPerUnit;
            public bool RenderToTexture;
        }

        public UnityCommandBufferSink(
            CommandBuffer cb,
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

        public void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight, float pixelsPerUnit)
        {
            _cb.Clear();
            _snapshot = sharedBuffers;
            _stencilActive = false;
            _inDynamicComposite = false;
            _viewportW = viewportWidth;
            _viewportH = viewportHeight;
            _pixelsPerUnit = Mathf.Max(0.001f, pixelsPerUnit);
            _targetStack.Clear();
            _compositeTargets.Clear();
            _ppuStack.Clear();
            _projectionStack.Clear();
            _dynRtWidth = 0;
            _dynRtHeight = 0;
            _currentTarget = BuiltinRenderTextureType.CameraTarget;
            _currentProjection = new ProjectionState
            {
                Width = _viewportW,
                Height = _viewportH,
                PixelsPerUnit = _pixelsPerUnit,
                RenderToTexture = false
            };
            ApplyProjectionState(_currentProjection);
            if (_buffers.VertexBuffer != null) _cb.SetGlobalBuffer(_vertProp, _buffers.VertexBuffer);
            if (_buffers.UvBuffer != null) _cb.SetGlobalBuffer(_uvProp, _buffers.UvBuffer);
            if (_buffers.DeformBuffer != null) _cb.SetGlobalBuffer(_deformProp, _buffers.DeformBuffer);
        }

        public void End() { }
        public void BeginMask(bool usesStencil) { _stencilActive = usesStencil; }
        public void BeginMaskContent() { }
        public void EndMask() { }

        public void BeginComposite()
        {
            // Render composite contents into a temporary RenderTexture,
            // then DrawCompositeQuad will blit it back to the parent target.
            var previous = _currentTarget;
            _targetStack.Push(previous);
            _projectionStack.Push(_currentProjection);
            var width = Mathf.Max(1, _viewportW);
            var height = Mathf.Max(1, _viewportH);
            var rt = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGB32);
            rt.name = "Nijilive/CompositeRT";
            _compositeTargets.Push(rt);
            _currentTarget = new RenderTargetIdentifier(rt);
            _currentProjection = new ProjectionState
            {
                Width = width,
                Height = height,
                PixelsPerUnit = _pixelsPerUnit,
                RenderToTexture = true
            };
            ApplyProjectionState(_currentProjection);
            _cb.SetRenderTarget(rt);
            _cb.ClearRenderTarget(true, true, Color.clear);
        }

        public void EndComposite()
        {
            if (_targetStack.Count > 0)
            {
                _currentTarget = _targetStack.Pop();
            }
            else
            {
                _currentTarget = BuiltinRenderTextureType.CameraTarget;
            }
            if (_projectionStack.Count > 0)
            {
                _currentProjection = _projectionStack.Pop();
                _pixelsPerUnit = _currentProjection.PixelsPerUnit;
                ApplyProjectionState(_currentProjection);
            }
            _cb.SetRenderTarget(_currentTarget);
        }

        public void BeginDynamicComposite(CommandStream.DynamicCompositePass pass)
        {
            // Route subsequent draws into the first dynamic composite texture if available.
            var previous = _currentTarget;
            _targetStack.Push(previous);
            _ppuStack.Push(_pixelsPerUnit);
            _projectionStack.Push(_currentProjection);
            RenderTexture target = null;
            var texSpan = pass.Textures.Span;
            if (texSpan.Length > 0)
            {
                var handle = texSpan[0];
                if (handle != 0 && _textures.TryGet(handle, out var binding) && binding.NativeObject is RenderTexture rt)
                {
                    target = rt;
                }
            }
            if (target == null)
            {
                _currentTarget = previous;
                if (_ppuStack.Count > 0)
                    _pixelsPerUnit = _ppuStack.Pop(); // restore immediately
                if (_projectionStack.Count > 0)
                {
                    _currentProjection = _projectionStack.Pop();
                    ApplyProjectionState(_currentProjection);
                }
                _inDynamicComposite = false;
                _cb.SetRenderTarget(_currentTarget);
                // Ensure alpha from prior work does not bleed into the reference for Clip/Slice.
                _cb.ClearRenderTarget(true, true, Color.clear);
                return;
            }
            _currentTarget = new RenderTargetIdentifier(target);
            _dynRtWidth = Mathf.Max(1, target.width);
            _dynRtHeight = Mathf.Max(1, target.height);
            // Use RT pixel space where (w, h) maps to (w, h) after transform.
            _pixelsPerUnit = 1f;
            _currentProjection = new ProjectionState
            {
                Width = _dynRtWidth,
                Height = _dynRtHeight,
                PixelsPerUnit = _pixelsPerUnit,
                RenderToTexture = true
            };
            _inDynamicComposite = true;
            ApplyProjectionState(_currentProjection);
            _cb.SetRenderTarget(target);
            _cb.ClearRenderTarget(true, true, Color.clear);
        }

        public void EndDynamicComposite(CommandStream.DynamicCompositePass pass)
        {
            if (_targetStack.Count > 0)
            {
                _currentTarget = _targetStack.Pop();
            }
            else
            {
                _currentTarget = BuiltinRenderTextureType.CameraTarget;
            }
            if (_ppuStack.Count > 0)
            {
                _pixelsPerUnit = _ppuStack.Pop();
            }
            if (_projectionStack.Count > 0)
            {
                _currentProjection = _projectionStack.Pop();
                _pixelsPerUnit = _currentProjection.PixelsPerUnit;
                ApplyProjectionState(_currentProjection);
            }
            _inDynamicComposite = false;
            _dynRtWidth = 0;
            _dynRtHeight = 0;
            _cb.SetRenderTarget(_currentTarget);
        }

        public void DrawPart(CommandStream.DrawPacket part)
        {
            var matrix = Matrix4x4.identity;
            _mpb.Clear();
            BindTextures(_mpb, part.TextureHandles);
            var blendingMode = part.BlendingMode;
            var opacity = part.Opacity;
            // ClipToLower should rely solely on destination alpha; force src alpha to 1.
            if (blendingMode == 17) opacity = 1f;
            _mpb.SetFloat(_props.Opacity, opacity);
            _mpb.SetColor(_props.Tint, new Color(part.ClampedTint.X, part.ClampedTint.Y, part.ClampedTint.Z, 1));
            _mpb.SetColor(_props.ScreenTint, new Color(part.ClampedScreen.X, part.ClampedScreen.Y, part.ClampedScreen.Z, 1));
            _mpb.SetColor(_props.Emission, new Color(part.EmissionStrength, part.EmissionStrength, part.EmissionStrength, 1));
            _mpb.SetFloat(_props.MaskThreshold, part.MaskThreshold);
            _mpb.SetInt(_props.BlendMode, blendingMode);
            _mpb.SetInt(_props.UseMultistageBlend, part.UseMultistageBlend ? 1 : 0);
            _mpb.SetInt(_props.UsesStencil, _stencilActive ? 1 : 0);
            ApplyBlend(_mpb, part.BlendingMode);
            ApplyStencil(_mpb, _stencilActive ? StencilMode.TestEqual : StencilMode.Off);
            var mesh = BuildMesh(
                part.ModelMatrix,
                part.PuppetMatrix,
                part.Origin,
                part.VertexOffset, part.VertexAtlasStride,
                part.UvOffset, part.UvAtlasStride,
                part.DeformOffset, part.DeformAtlasStride,
                part.VertexCount, part.IndexCount, part.Indices);
            _cb.DrawMesh(mesh, matrix, _partMaterial, 0, 0, _mpb);
        }

        public void DrawMask(CommandStream.MaskPacket mask)
        {
            var matrix = Matrix4x4.identity;
            var mesh = BuildMesh(
                mask.ModelMatrix,
                default,
                mask.Origin,
                mask.VertexOffset, mask.VertexAtlasStride,
                0, 0,
                mask.DeformOffset, mask.DeformAtlasStride,
                mask.VertexCount, mask.IndexCount, mask.Indices);
            _mpb.Clear();
            _mpb.SetInt(_props.UsesStencil, 1);
            ApplyStencil(_mpb, StencilMode.WriteReplace);
            ApplyBlend(_mpb, 0);
            _cb.DrawMesh(mesh, matrix, _partMaterial, 0, 0, _mpb);
        }

        public void ApplyMask(CommandStream.MaskApplyPacket apply)
        {
            _mpb.Clear();
            _mpb.SetFloat(_props.MaskThreshold, apply.IsDodge ? 1f : 0f);
        }

        public void DrawCompositeQuad(CommandStream.CompositePacket composite)
        {
            if (!composite.Valid)
                return;
            if (_compositeTargets.Count == 0)
                return;
            var rt = _compositeTargets.Pop();
            _mpb.Clear();
            _mpb.SetTexture(_props.MainTex, rt);
            _mpb.SetTexture(_props.MaskTex, PlaceholderWhite());
            _mpb.SetTexture(_props.ExtraTex, PlaceholderBlack());
            _mpb.SetFloat(_props.Opacity, composite.Opacity);
            _mpb.SetInt(_props.BlendMode, composite.BlendingMode);
            _mpb.SetInt(_props.UseMultistageBlend, 0);
            _mpb.SetInt(_props.UsesStencil, 0);
            ApplyBlend(_mpb, composite.BlendingMode);
            ApplyStencil(_mpb, StencilMode.Off);
            // OpenGL backend draws a full-screen quad (clip space -1..1) with UV 0..1.
            // Mirror that behaviour: fixed full-screen scale, no per-RT scaling.
            var matrix = Matrix4x4.TRS(Vector3.zero, Quaternion.identity, new Vector3(2f, 2f, 1f));

            _cb.DrawMesh(_quadMesh, matrix, _compositeMaterial, 0, 0, _mpb);
            RenderTexture.ReleaseTemporary(rt);
        }

        public void Unknown(CommandStream.Command cmd)
        {
            Debug.LogWarning($"Unknown command: {cmd.Kind}");
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
            mesh.triangles = new[] { 0, 1, 2, 0, 2, 3 };
            mesh.RecalculateNormals();
            return mesh;
        }

        private void BindTextures(MaterialPropertyBlock block, ReadOnlyMemory<nuint> handles)
        {
            var span = handles.Span;
            Texture tex0 = ResolveTexture(span, 0, Color.white);
            Texture tex1 = ResolveTexture(span, 1, Color.white);
            Texture tex2 = ResolveTexture(span, 2, Color.black);

            if (tex0 == null) tex0 = PlaceholderWhite();
            if (tex1 == null) tex1 = PlaceholderWhite();
            if (tex2 == null) tex2 = PlaceholderBlack();

            block.SetTexture(_props.MainTex, tex0);
            block.SetTexture(_props.MaskTex, tex1);
            block.SetTexture(_props.ExtraTex, tex2);
        }

        private Mesh BuildMesh(
            NijiliveNative.Mat4 model,
            NijiliveNative.Mat4 puppet,
            NijiliveNative.Vec2 origin,
            nuint vertexOffset, nuint vertexStride,
            nuint uvOffset, nuint uvStride,
            nuint deformOffset, nuint deformStride,
            nuint vertexCount, nuint indexCount,
            IntPtr indicesPtr)
        {
            var count = checked((int)vertexCount);
            var verts = new Vector3[count];
            var uvs = new Vector2[count];
            var vSlice = _snapshot.Vertices;
            var uvSlice = _snapshot.Uvs;
            var dSlice = _snapshot.Deform;

            unsafe
            {
                var vPtr = (float*)vSlice.Data;
                var uvPtr = (float*)uvSlice.Data;
                var dPtr = (float*)dSlice.Data;
                var mModel = ToMatrix(model);
                var mPuppet = puppet.M11 == 0 && puppet.M22 == 0 && puppet.M33 == 0 && puppet.M44 == 0
                    ? Matrix4x4.identity
                    : ToMatrix(puppet);
                var m = mPuppet * mModel;
                var ox = origin.X;
                var oy = origin.Y;
                var hasDeform = dSlice.Data != IntPtr.Zero && dSlice.Length > 0 && deformStride != 0;
                var pxPerUnit = Mathf.Max(0.001f, _pixelsPerUnit);


                for (int i = 0; i < count; i++)
                {
                    var idx = (nuint)i;
                    var vx = vPtr[vertexOffset + idx];
                    var vy = vPtr[vertexOffset + vertexStride + idx];
                    float dx = 0, dy = 0;
                    if (hasDeform)
                    {
                        dx = dPtr[deformOffset + idx];
                        dy = dPtr[deformOffset + deformStride + idx];
                    }
                    var local = new Vector4(vx - ox + dx, vy - oy + dy, 0, 1);
                    var world = m * local;
                    var nx = world.x / pxPerUnit;
                    // Flip Y for both main and DynamicComposite to keep texture orientation consistent.
                    var ny = -world.y / pxPerUnit;
                    verts[i] = new Vector3(nx, ny, 0);

                    if (uvSlice.Data != IntPtr.Zero && uvSlice.Length > 0 && uvStride != 0)
                    {
                        var ux = uvPtr[uvOffset + idx];
                        var uy = uvPtr[uvOffset + uvStride + idx];
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
                var seq = new int[count];
                for (int i = 0; i < count; i++) seq[i] = i;
                mesh.SetIndices(seq, MeshTopology.Triangles, 0);
            }

            mesh.RecalculateBounds();
            return mesh;
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

        private enum StencilMode { Off, WriteReplace, TestEqual }

        private void ApplyStencil(MaterialPropertyBlock block, StencilMode mode)
        {
            switch (mode)
            {
                case StencilMode.WriteReplace:
                    block.SetInt(_props.StencilRef, 1);
                    block.SetInt(_props.StencilComp, (int)CompareFunction.Always);
                    block.SetInt(_props.StencilPass, (int)StencilOp.Replace);
                    break;
                case StencilMode.TestEqual:
                    block.SetInt(_props.StencilRef, 1);
                    block.SetInt(_props.StencilComp, (int)CompareFunction.Equal);
                    block.SetInt(_props.StencilPass, (int)StencilOp.Keep);
                    break;
                default:
                    block.SetInt(_props.StencilRef, 0);
                    block.SetInt(_props.StencilComp, (int)CompareFunction.Always);
                    block.SetInt(_props.StencilPass, (int)StencilOp.Keep);
                    break;
            }
        }

        private void ApplyBlend(MaterialPropertyBlock block, int mode)
        {
            // Mappings based on standard Live2D/Nijilive specs
            BlendMode src, dst;
            BlendOp op = BlendOp.Add;

            switch (mode)
            {
                case 0: // Normal
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 1: // Multiply
                    src = BlendMode.DstColor;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 2: // Screen
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcColor;
                    break;
                case 3: // Overlay (Not supported by HW blend)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 4: // Darken
                    src = BlendMode.One;
                    dst = BlendMode.One;
                    op = BlendOp.Min;
                    break;
                case 5: // Lighten
                    src = BlendMode.One;
                    dst = BlendMode.One;
                    op = BlendOp.Max;
                    break;
                case 6: // ColorDodge (Not supported)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 7: // LinearDodge (Add)
                    src = BlendMode.One;
                    dst = BlendMode.One;
                    break;
                case 8: // AddGlow (Add)
                    src = BlendMode.One;
                    dst = BlendMode.One;
                    break;
                case 9: // ColorBurn (Not supported)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 10: // HardLight (Not supported)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 11: // SoftLight (Not supported)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 12: // Difference (Not supported by standard BlendOp)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 13: // Exclusion (Not supported)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 14: // Subtract (RevSub)
                    src = BlendMode.One;
                    dst = BlendMode.One;
                    op = BlendOp.ReverseSubtract;
                    break;
                case 15: // Inverse (Not supported)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 16: // DestinationIn (Masking)
                    src = BlendMode.Zero;
                    dst = BlendMode.SrcAlpha;
                    break;
                case 17: // ClipToLower
                    src = BlendMode.DstAlpha;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                case 18: // SliceFromLower
                    src = BlendMode.Zero;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
                default: // Normal or Special (Clip/Slice)
                    src = BlendMode.One;
                    dst = BlendMode.OneMinusSrcAlpha;
                    break;
            }

            block.SetInt(_props.SrcBlend, (int)src);
            block.SetInt(_props.DstBlend, (int)dst);
            block.SetInt(_props.BlendOp, (int)op);
            block.SetInt(_props.ZWrite, 0);
        }

        private static Texture2D _white, _black;

        private Texture ResolveTexture(ReadOnlySpan<nuint> handles, int index, Color fallbackColor)
        {
            if (handles.Length <= index) return null;
            var handle = handles[index];
            if (handle == 0) return null;

            if (_textures.TryGet(handle, out var binding))
            {
                return binding.NativeObject as Texture;
            }

            return null;
        }

        private void ApplyProjectionState(in ProjectionState state)
        {
            var width = Mathf.Max(1, state.Width);
            var height = Mathf.Max(1, state.Height);
            // Vertices are already scaled by PPU; use pixel-aligned ortho based solely on target size.
            var halfW = (float)width * 0.5f;
            var halfH = (float)height * 0.5f;
            var proj = Matrix4x4.Ortho(-halfW, halfW, -halfH, halfH, -1f, 1f);
            proj = GL.GetGPUProjectionMatrix(proj, state.RenderToTexture);
            _cb.SetViewport(new Rect(0, 0, width, height));
            _cb.SetViewProjectionMatrices(Matrix4x4.identity, proj);
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
}
