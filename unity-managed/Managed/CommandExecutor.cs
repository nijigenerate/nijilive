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
        private static int _frameSeq;
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
            DumpCommands(commands);
            LogCommandUsage(commands);
            sink.Begin(sharedBuffers, viewportWidth, viewportHeight, pixelsPerUnit);
            foreach (var cmd in commands)
            {
                switch (cmd)
                {
                    case CommandStream.DrawPart part:
                        sink.DrawPart(part.Part);
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
                    default:
                        sink.Unknown(cmd);
                        break;
                }
            }
            sink.End();
        }
        private static void DumpCommands(IReadOnlyList<CommandStream.Command> commands)
        {
            try
            {
                var temp = System.IO.Path.GetTempPath();
                var path = System.IO.Path.Combine(temp, "nijilive_cmd_managed.txt");
                var lines = new List<string>(commands.Count + 2);
                lines.Add($"Frame {_frameSeq} count={commands.Count}");
                for (int i = 0; i < commands.Count; i++)
                {
                    var cmd = commands[i];
                    switch (cmd)
                    {
                        case CommandStream.DrawPart p:
                            lines.Add($"{i} kind=DrawPart isMask={p.Part.IsMask} v={p.Part.VertexCount}/{p.Part.IndexCount}");
                            break;
                        case CommandStream.ApplyMask a:
                            lines.Add($"{i} kind=ApplyMask apply.kind={a.Apply.Kind} dodge={a.Apply.IsDodge} part.v={a.Apply.Part.VertexCount}/{a.Apply.Part.IndexCount} mask.v={a.Apply.Mask.VertexCount}/{a.Apply.Mask.IndexCount}");
                            break;
                        default:
                            lines.Add($"{i} kind={cmd.Kind}");
                            break;
                    }
                }
                lines.Add(string.Empty);
                System.IO.File.AppendAllLines(path, lines);
                _frameSeq++;
            }
            catch
            {
                // Ignore logging errors
            }
        }
        private static void LogCommandUsage(IReadOnlyList<CommandStream.Command> commands)
        {
            int maxV = 0, maxI = 0;
            foreach (var cmd in commands)
            {
                switch (cmd)
                {
                    case CommandStream.DrawPart p:
                        maxV = Math.Max(maxV, (int)p.Part.VertexCount);
                        maxI = Math.Max(maxI, (int)p.Part.IndexCount);
                        break;
                    case CommandStream.ApplyMask a:
                        maxV = Math.Max(maxV, (int)a.Apply.Part.VertexCount);
                        maxI = Math.Max(maxI, (int)a.Apply.Part.IndexCount);
                        maxV = Math.Max(maxV, (int)a.Apply.Mask.VertexCount);
                        maxI = Math.Max(maxI, (int)a.Apply.Mask.IndexCount);
                        break;
                }
            }
            Log($"[Nijilive] Command usage max vertices={maxV} max indices={maxI} cmds={commands.Count}");
        }
    }
    public interface IRenderCommandSink
    {
        void Begin(NijiliveNative.SharedBufferSnapshot sharedBuffers, int viewportWidth, int viewportHeight, float pixelsPerUnit);
        void End();
        void DrawPart(CommandStream.DrawPacket part);
        void ApplyMask(CommandStream.MaskApplyPacket apply);
        void BeginDynamicComposite(CommandStream.DynamicCompositePass pass);
        void EndDynamicComposite(CommandStream.DynamicCompositePass pass);
        void BeginMask(bool usesStencil);
        void BeginMaskContent();
        void EndMask();
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
        public void ApplyMask(CommandStream.MaskApplyPacket apply) => Recorded.Add(new CommandStream.ApplyMask(apply));
        public void BeginDynamicComposite(CommandStream.DynamicCompositePass pass) => Recorded.Add(new CommandStream.BeginDynamicComposite(pass));
        public void EndDynamicComposite(CommandStream.DynamicCompositePass pass) => Recorded.Add(new CommandStream.EndDynamicComposite(pass));
        public void BeginMask(bool usesStencil) => Recorded.Add(new CommandStream.BeginMask(usesStencil));
        public void BeginMaskContent() => Recorded.Add(new CommandStream.BeginMaskContent());
        public void EndMask() => Recorded.Add(new CommandStream.EndMask());
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
        private readonly Material _maskWriteMaterial;
        private readonly Mesh _quadMesh;
        private readonly TextureRegistry _textures;
        private readonly SharedBufferUploader _buffers;
        private readonly MaterialPropertyBlock _mpb = new();
        private readonly PropertyConfig _props;
        private readonly int _vertProp;
        private readonly int _uvProp;
        private readonly int _deformProp;
        private readonly Dictionary<int, Material> _materialCache = new();
        private readonly Stack<RenderTargetIdentifier> _targetStack = new();
        private readonly Stack<float> _ppuStack = new();
        private readonly Stack<ProjectionState> _projectionStack = new();
        private readonly List<Mesh> _meshPool = new();
        private readonly List<RenderTexture> _rtReleaseQueue = new();
        private int _frameId;
        private static Mesh BuildMeshSkipped(string reason)
        {
            LogWarning($"[Nijilive] BuildMesh skipped: {reason}");
            return null;
        }
        private int _meshPoolCursor;
        private Vector3[] _vertexBuffer = Array.Empty<Vector3>();
        private Vector2[] _uvBuffer = Array.Empty<Vector2>();
        private int[] _indexBuffer = Array.Empty<int>();
        private bool _inDynamicComposite;
        private int _dynRtWidth;
        private int _dynRtHeight;
        private RenderTargetIdentifier _currentTarget = BuiltinRenderTextureType.CameraTarget;
        private bool _stencilActive;
        private bool _maskActive;
        private RenderTexture _maskDepth;
        private int _maskDepthCounter;
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
            _maskWriteMaterial = new Material(_partMaterial) { name = $"{_partMaterial.name}/MaskWrite" };
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
            _frameId = Time.frameCount;
            _snapshot = sharedBuffers;
            _stencilActive = false;
            _inDynamicComposite = false;
            _viewportW = viewportWidth;
            _viewportH = viewportHeight;
            _pixelsPerUnit = Mathf.Max(0.001f, pixelsPerUnit);
            _targetStack.Clear();
                        _ppuStack.Clear();
            _projectionStack.Clear();
            _rtReleaseQueue.Clear();
            _meshPoolCursor = 0;
            _dynRtWidth = 0;
            _dynRtHeight = 0;
            _currentTarget = BuiltinRenderTextureType.CameraTarget;
            _maskDepthCounter = 0;
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
            Log($"[Nijilive] Begin frame={_frameId} size={_viewportW}x{_viewportH} ppu={_pixelsPerUnit}");
        }
        public void End()
        {
            if (_rtReleaseQueue.Count > 0)
            {
                Log($"[Nijilive] Release queued RTs count={_rtReleaseQueue.Count} frame={_frameId}");
                foreach (var rt in _rtReleaseQueue)
                {
                    if (rt != null)
                    {
                        Log($"[Nijilive]   Release RT {rt.name} size={rt.width}x{rt.height}");
                        RenderTexture.ReleaseTemporary(rt);
                    }
                }
                _rtReleaseQueue.Clear();
            }
            ReleaseSharedCompositeRt();
        }
        public void BeginMask(bool usesStencil)
        {
            _maskDepthCounter++;
            _maskActive = true;
            _stencilActive = false;
            var w = Mathf.Max(1, _viewportW);
            var h = Mathf.Max(1, _viewportH);
            if (_maskDepth != null)
            {
                if (_maskDepth.width != w || _maskDepth.height != h)
                {
                    Log($"[Nijilive] MaskDepth resize old={_maskDepth.width}x{_maskDepth.height} new={w}x{h} frame={_frameId}");
                    ReleaseMaskDepth();
                }
            }
            if (_maskDepth == null)
            {
                var desc = new RenderTextureDescriptor(w, h)
                {
                    depthBufferBits = 24,
                    msaaSamples = 1,
                    volumeDepth = 1,
                    graphicsFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.None,
                    depthStencilFormat = UnityEngine.Experimental.Rendering.GraphicsFormat.D24_UNorm_S8_UInt,
                };
                _maskDepth = RenderTexture.GetTemporary(desc);
                _maskDepth.name = "Nijilive/MaskDepth";
                Log($"[Nijilive] Allocate MaskDepth RT size={w}x{h} frame={_frameId}");
            }
            if (_maskDepth == null)
            {
                Debug.LogError($"[Nijilive] MaskDepth allocation failed size={w}x{h} frame={_frameId}");
                _maskActive = false;
                return;
            }
            else
            {
                Log($"[Nijilive] Use MaskDepth RT size={_maskDepth.width}x{_maskDepth.height} frame={_frameId} counter={_maskDepthCounter}");
            }
            // Keep drawing color to the current target while sharing depth-stencil.
            _cb.SetRenderTarget(_currentTarget, new RenderTargetIdentifier(_maskDepth));
            // Clear depth/stencil only; keep color buffer untouched.
            _cb.ClearRenderTarget(true, false, Color.clear);
            // Match OpenGL semantics: stencil defaults to 0 for normal masks, 1 for dodge masks.
            FillStencil(usesStencil ? 0 : 1);
        }
        public void BeginMaskContent()
        {
            if (!_maskActive) return;
            if (_maskDepthCounter <= 0)
            {
                LogWarning("[Nijilive] BeginMaskContent without active BeginMask");
            }
            _stencilActive = true;
            if (_maskDepth != null)
            {
                _cb.SetRenderTarget(_currentTarget, new RenderTargetIdentifier(_maskDepth));
            }
        }
        public void EndMask()
        {
            if (_maskDepthCounter <= 0)
            {
                LogWarning("[Nijilive] EndMask without active BeginMask");
            }
            else
            {
                _maskDepthCounter--;
            }
            _stencilActive = false;
            _maskActive = false;
            _cb.SetRenderTarget(_currentTarget);
        }
        public void BeginComposite() { }
        public void EndComposite() { }
        public void DrawCompositeQuad(CommandStream.CompositePacket composite) { }
        public void Unknown(CommandStream.Command cmd)
        {
            LogWarning($"Unknown command: {cmd.Kind}");
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
            // Validate shared buffer bounds to avoid Unity buffer update crashes.
            bool HasRoom(NijiliveNative.NjgBufferSlice slice, nuint offset, nuint stride, nuint count)
            {
                if (slice.Data == IntPtr.Zero || slice.Length == 0) return false;
                var lane0End = offset + count;
                var lane1End = offset + stride + count;
                return lane0End <= slice.Length && lane1End <= slice.Length;
            }
            var vSlice = _snapshot.Vertices;
            var uvSlice = _snapshot.Uvs;
            var dSlice = _snapshot.Deform;
            if (indexCount > 0 && indicesPtr == IntPtr.Zero)
            {
                return BuildMeshSkipped("indices pointer is null");
            }
            if (!HasRoom(vSlice, vertexOffset, vertexStride, vertexCount))
            {
                return BuildMeshSkipped($"vertex bounds overrun (offset={vertexOffset}, stride={vertexStride}, count={vertexCount}, buf={vSlice.Length})");
            }
            if (uvStride != 0 && !HasRoom(uvSlice, uvOffset, uvStride, vertexCount))
            {
                return BuildMeshSkipped($"uv bounds overrun (offset={uvOffset}, stride={uvStride}, count={vertexCount}, buf={uvSlice.Length})");
            }
            if (deformStride != 0 && !HasRoom(dSlice, deformOffset, deformStride, vertexCount))
            {
                return BuildMeshSkipped($"deform bounds overrun (offset={deformOffset}, stride={deformStride}, count={vertexCount}, buf={dSlice.Length})");
            }
            if (vertexCount > int.MaxValue)
            {
                return BuildMeshSkipped($"vertexCount too large ({vertexCount})");
            }
            if (indexCount > int.MaxValue)
            {
                return BuildMeshSkipped($"indexCount too large ({indexCount})");
            }
            var count = checked((int)vertexCount);
            EnsureVertexCapacity(count);
            var verts = _vertexBuffer;
            var uvs = _uvBuffer;
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
            var mesh = AcquireMesh();
            mesh.SetVertices(verts, 0, count);
            mesh.SetUVs(0, uvs, 0, count);
            if (indexCount > 0 && indicesPtr != IntPtr.Zero)
            {
                var icount = checked((int)indexCount);
                EnsureIndexCapacity(icount);
                var ints = _indexBuffer;
                int maxIndex = -1;
                unsafe
                {
                    var span = new ReadOnlySpan<ushort>((void*)indicesPtr, icount);
                    for (int i = 0; i < icount; i++)
                    {
                        var v = span[i];
                        ints[i] = v;
                        if (v > maxIndex) maxIndex = v;
                    }
                }
                if (maxIndex >= count)
                {
                    LogWarning($"[Nijilive] BuildMesh skipped: index out of range (max={maxIndex} >= verts={count})");
                    return null;
                }
                mesh.SetIndices(ints, 0, icount, MeshTopology.Triangles, 0);
            }
            else
            {
                EnsureIndexCapacity(count);
                for (int i = 0; i < count; i++) _indexBuffer[i] = i;
                mesh.SetIndices(_indexBuffer, 0, count, MeshTopology.Triangles, 0);
            }
            mesh.RecalculateBounds();
            return mesh;
        }
        private Mesh AcquireMesh()
        {
            if (_meshPoolCursor < _meshPool.Count)
            {
                var pooled = _meshPool[_meshPoolCursor++];
                pooled.Clear();
                return pooled;
            }
            var mesh = new Mesh { name = $"Nijilive/ReusableMesh/{_meshPool.Count}" };
            _meshPool.Add(mesh);
            _meshPoolCursor++;
            return mesh;
        }
        private Material ResolveMaterial(int blendMode, bool useCompositeMaterial)
        {
            // Clamp to supported blend modes to avoid unbounded material creation.
            int clamped = Mathf.Clamp(blendMode, 0, 18);
            int key = (useCompositeMaterial ? 1 << 16 : 0) | clamped;
            if (_materialCache.TryGetValue(key, out var cached)) return cached;
            var source = useCompositeMaterial ? _compositeMaterial : _partMaterial;
            var mat = new Material(source) { name = $"{source.name}/blend{clamped}" };
            _materialCache[key] = mat;
            return mat;
        }
        private void EnsureVertexCapacity(int count)
        {
            if (_vertexBuffer.Length < count) _vertexBuffer = new Vector3[count];
            if (_uvBuffer.Length < count) _uvBuffer = new Vector2[count];
        }
        private void EnsureIndexCapacity(int count)
        {
            if (_indexBuffer.Length < count) _indexBuffer = new int[count];
        }
        private void ReleaseMaskDepth()
        {
            if (_maskDepth != null)
            {
                Log($"[Nijilive] Release MaskDepth RT size={_maskDepth.width}x{_maskDepth.height} frame={_frameId}");
                RenderTexture.ReleaseTemporary(_maskDepth);
                _maskDepth = null;
            }
        }
        private void FillStencil(int refValue)
        {
            _maskWriteMaterial.SetInt(_props.SrcBlend, (int)UnityEngine.Rendering.BlendMode.Zero);
            _maskWriteMaterial.SetInt(_props.DstBlend, (int)UnityEngine.Rendering.BlendMode.One);
            _maskWriteMaterial.SetInt(_props.BlendOp, (int)UnityEngine.Rendering.BlendOp.Add);
            _maskWriteMaterial.SetInt(_props.ZWrite, 0);
            _maskWriteMaterial.SetInt(_props.UsesStencil, 1);
            _mpb.Clear();
            _mpb.SetInt(_props.StencilRef, refValue);
            _mpb.SetInt(_props.StencilComp, (int)CompareFunction.Always);
            _mpb.SetInt(_props.StencilPass, (int)StencilOp.Replace);
            _mpb.SetInt(_props.UsesStencil, 1);
            _cb.DrawMesh(_quadMesh, Matrix4x4.identity, _maskWriteMaterial, 0, 0, _mpb);
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
        private void ApplyBlendToMaterial(Material material, int mode)
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
            material.SetInt(_props.SrcBlend, (int)src);
            material.SetInt(_props.DstBlend, (int)dst);
            material.SetInt(_props.BlendOp, (int)op);
            material.SetInt(_props.ZWrite, 0);
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
            Log("[Nijilive] Created placeholder white texture");
            return _white;
        }
        private static Texture2D PlaceholderBlack()
        {
            if (_black != null) return _black;
            _black = new Texture2D(1, 1, TextureFormat.RGBA32, false) { name = "Nijilive/Black" };
            _black.SetPixel(0, 0, Color.black);
            _black.Apply();
            _black.hideFlags = HideFlags.HideAndDontSave;
            Log("[Nijilive] Created placeholder black texture");
            return _black;
        }
    }
#endif
}
