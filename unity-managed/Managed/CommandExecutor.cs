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
                        case CommandStream.DrawMask m:
                            lines.Add($"{i} kind=DrawMask v={m.Mask.VertexCount}/{m.Mask.IndexCount}");
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
                    case CommandStream.DrawMask m:
                        maxV = Math.Max(maxV, (int)m.Mask.VertexCount);
                        maxI = Math.Max(maxI, (int)m.Mask.IndexCount);
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
        private readonly Stack<CompositeContext> _composites = new();
        private readonly Stack<bool> _compositeDrawn = new();
        private readonly Stack<float> _ppuStack = new();
        private readonly Stack<ProjectionState> _projectionStack = new();
        private readonly List<Mesh> _meshPool = new();
        private readonly List<RenderTexture> _rtReleaseQueue = new();
        private int _frameId;
        private RenderTexture _sharedCompositeRt;
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
        private int _nextCompositeId;
        private struct CompositeContext
        {
            public RenderTexture Rt;
            public int Id;
            public RenderTargetIdentifier ParentTarget;
            public ProjectionState ParentProjection;
        }
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
            _composites.Clear();
            _ppuStack.Clear();
            _projectionStack.Clear();
            _rtReleaseQueue.Clear();
            ReleaseSharedCompositeRt();
            _meshPoolCursor = 0;
            _dynRtWidth = 0;
            _dynRtHeight = 0;
            _currentTarget = BuiltinRenderTextureType.CameraTarget;
            _nextCompositeId = 0;
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
        public void BeginComposite()
        {
            if (_composites.Count > 0)
            {
                LogWarning($"[Nijilive] BeginComposite ignored: composite already active (nesting unsupported) frame={_frameId}");
                return;
            }
            // Render composite contents into a shared temporary RenderTexture,
            // then DrawCompositeQuad will blit it back to the parent target.
            var compositeId = ++_nextCompositeId;
            var previous = _currentTarget;
            var width = Mathf.Max(1, _viewportW);
            var height = Mathf.Max(1, _viewportH);
            if (_sharedCompositeRt != null && (_sharedCompositeRt.width != width || _sharedCompositeRt.height != height))
            {
                Log($"[Nijilive] Resize shared Composite RT {_sharedCompositeRt.width}x{_sharedCompositeRt.height} -> {width}x{height} frame={_frameId}");
                ReleaseSharedCompositeRt();
            }
            if (_sharedCompositeRt == null)
            {
                _sharedCompositeRt = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGB32);
                _sharedCompositeRt.name = "Nijilive/CompositeRT";
                Log($"[Nijilive] Allocate shared Composite RT size={width}x{height} frame={_frameId}");
            }
            _composites.Push(new CompositeContext
            {
                Rt = _sharedCompositeRt,
                Id = compositeId,
                ParentTarget = previous,
                ParentProjection = _currentProjection
            });
            _currentTarget = new RenderTargetIdentifier(_sharedCompositeRt);
            _currentProjection = new ProjectionState
            {
                Width = width,
                Height = height,
                PixelsPerUnit = _pixelsPerUnit,
                RenderToTexture = true
            };
            ApplyProjectionState(_currentProjection);
            _cb.SetRenderTarget(_sharedCompositeRt);
            _cb.ClearRenderTarget(true, true, Color.clear);
            Log($"[Nijilive] BeginComposite#{compositeId} -> RT {_sharedCompositeRt.name} size={width}x{height} frame={_frameId}");
        }
        public void EndComposite()
        {
            // 陝・腸・ｿ・ｽE隰蜀怜愛驍ｨ繧・ｽｺ繝ｻ繝ｻ・ｽ繝ｻ・ｽ髫包ｽｪ邵ｺ・ｫ隰鯉ｽｻ邵ｺ蜷ｶ窶ｲRT邵ｺ・ｯ闖ｫ譎・亜邵ｺ蜉ｱ笳・ｸｺ・ｾ邵ｺ・ｾDrawCompositeQuad邵ｺ・ｧ雎ｸ驛・ｽｲ・ｻ邵ｺ蜷ｶ・狗ｸｲ繝ｻ
            if (_composites.Count > 0)
            {
                var ctx = _composites.Peek();
                _currentTarget = ctx.ParentTarget;
                _currentProjection = ctx.ParentProjection;
                _pixelsPerUnit = _currentProjection.PixelsPerUnit;
                ApplyProjectionState(_currentProjection);
                _cb.SetRenderTarget(_currentTarget);
            }
            else
            {
                _currentTarget = BuiltinRenderTextureType.CameraTarget;
                _cb.SetRenderTarget(_currentTarget);
            }
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
                LogWarning($"[Nijilive] BeginDynamicComposite: no target texture (frame={_frameId})");
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
            Log($"[Nijilive] BeginDynamicComposite target={target.name} size={target.width}x{target.height} frame={_frameId}");
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
            Log($"[Nijilive] EndDynamicComposite frame={_frameId}");
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
            var material = ResolveMaterial(blendingMode, false);
            ApplyBlendToMaterial(material, blendingMode);
            ApplyStencil(_mpb, _stencilActive ? StencilMode.TestEqual : StencilMode.Off);
            var mesh = BuildMesh(
                part.ModelMatrix,
                part.PuppetMatrix,
                part.Origin,
                part.VertexOffset, part.VertexAtlasStride,
                part.UvOffset, part.UvAtlasStride,
                part.DeformOffset, part.DeformAtlasStride,
                part.VertexCount, part.IndexCount, part.Indices);
            if (mesh == null)
            {
                LogWarning(
                    $"[Nijilive] DrawPart mesh null vtx={part.VertexCount} idx={part.IndexCount} " +
                    $"vo={part.VertexOffset}/{part.VertexAtlasStride} uo={part.UvOffset}/{part.UvAtlasStride} do={part.DeformOffset}/{part.DeformAtlasStride} " +
                    $"bufLens V={_snapshot.Vertices.Length} U={_snapshot.Uvs.Length} D={_snapshot.Deform.Length}");
                return;
            }
            _cb.DrawMesh(mesh, matrix, material, 0, 0, _mpb);
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
            if (mesh == null)
            {
                LogWarning(
                    $"[Nijilive] DrawMask mesh null vtx={mask.VertexCount} idx={mask.IndexCount} " +
                    $"vo={mask.VertexOffset}/{mask.VertexAtlasStride} do={mask.DeformOffset}/{mask.DeformAtlasStride} " +
                    $"bufLens V={_snapshot.Vertices.Length} U={_snapshot.Uvs.Length} D={_snapshot.Deform.Length}");
                return;
            }
            _mpb.SetFloat(_props.Opacity, 1f);
            _mpb.SetFloat(_props.MaskThreshold, 0f);
            // Masks use geometry only; bind placeholders to avoid stale bindings.
            BindTextures(_mpb, ReadOnlyMemory<nuint>.Empty);
            _mpb.SetInt(_props.UsesStencil, 1);
            ApplyStencil(_mpb, StencilMode.WriteReplace);
            var material = ResolveMaterial(0, false);
            ApplyBlendToMaterial(material, 0);
            _cb.DrawMesh(mesh, matrix, material, 0, 0, _mpb);
        }
        public void ApplyMask(CommandStream.MaskApplyPacket apply)
        {
            _mpb.Clear();
            var threshold = apply.Kind == NijiliveNative.MaskDrawableKind.Part
                ? apply.Part.MaskThreshold
                : 0f;
            var handles = apply.Kind == NijiliveNative.MaskDrawableKind.Part
                ? apply.Part.TextureHandles
                : ReadOnlyMemory<nuint>.Empty;
            _mpb.SetFloat(_props.MaskThreshold, threshold);
            if (!_maskActive) return;
            if (_maskDepthCounter <= 0)
            {
                LogWarning("[Nijilive] ApplyMask issued without BeginMask");
            }
            var indexCount = apply.Kind == NijiliveNative.MaskDrawableKind.Part
                ? checked((int)apply.Part.IndexCount)
                : checked((int)apply.Mask.IndexCount);
            var vertexCount = apply.Kind == NijiliveNative.MaskDrawableKind.Part
                ? checked((int)apply.Part.VertexCount)
                : checked((int)apply.Mask.VertexCount);
            if (indexCount == 0 || vertexCount == 0)
            {
                LogWarning("[Nijilive] ApplyMask skipped: empty mask geometry");
                _maskActive = false;
                _stencilActive = false;
                return;
            }
            var refValue = apply.IsDodge ? 0 : 1;
            _maskWriteMaterial.SetInt(_props.SrcBlend, (int)UnityEngine.Rendering.BlendMode.Zero);
            _maskWriteMaterial.SetInt(_props.DstBlend, (int)UnityEngine.Rendering.BlendMode.One);
            _maskWriteMaterial.SetInt(_props.BlendOp, (int)UnityEngine.Rendering.BlendOp.Add);
            _maskWriteMaterial.SetInt(_props.ZWrite, 0);
            _maskWriteMaterial.SetInt(_props.UsesStencil, 1);
            _mpb.SetInt(_props.StencilRef, refValue);
            _mpb.SetInt(_props.StencilComp, (int)CompareFunction.Always);
            _mpb.SetInt(_props.StencilPass, (int)StencilOp.Replace);
            _mpb.SetInt(_props.UsesStencil, 1);
            BindTextures(_mpb, handles);
            Mesh mesh = null;
            var matrix = Matrix4x4.identity;
            if (apply.Kind == NijiliveNative.MaskDrawableKind.Part)
            {
                var part = apply.Part;
                mesh = BuildMesh(
                    part.ModelMatrix,
                    part.PuppetMatrix,
                    part.Origin,
                    part.VertexOffset, part.VertexAtlasStride,
                    part.UvOffset, part.UvAtlasStride,
                    part.DeformOffset, part.DeformAtlasStride,
                    part.VertexCount, part.IndexCount, part.Indices);
            }
            else
            {
                var mask = apply.Mask;
                mesh = BuildMesh(
                    mask.ModelMatrix,
                    default,
                    mask.Origin,
                    mask.VertexOffset, mask.VertexAtlasStride,
                    0, 0,
                    mask.DeformOffset, mask.DeformAtlasStride,
                    mask.VertexCount, mask.IndexCount, mask.Indices);
            }
            if (mesh == null)
            {
                LogWarning(
                    $"[Nijilive] ApplyMask mesh null kind={apply.Kind} vtx={vertexCount} idx={indexCount} " +
                    $"bufLens V={_snapshot.Vertices.Length} U={_snapshot.Uvs.Length} D={_snapshot.Deform.Length}");
                return;
            }
            _cb.DrawMesh(mesh, matrix, _maskWriteMaterial, 0, 0, _mpb);
        }
        public void DrawCompositeQuad(CommandStream.CompositePacket composite)
        {
            if (_composites.Count == 0)
            {
                LogWarning("[Nijilive] DrawCompositeQuad called with no pending composite RT");
                return;
            }
            var ctx = _composites.Pop();
            var rt = ctx.Rt;
            var compositeId = ctx.Id;
            if (!composite.Valid)
            {
                Log($"[Nijilive] DrawCompositeQuad#{compositeId} skipped: invalid packet frame={_frameId}");
                return;
            }
            Log($"[Nijilive] DrawCompositeQuad#{compositeId} srcRT={rt.name} size={rt.width}x{rt.height} target={_currentTarget} frame={_frameId}");
            _mpb.Clear();
            _mpb.SetTexture(_props.MainTex, rt);
            _mpb.SetTexture(_props.MaskTex, PlaceholderWhite());
            _mpb.SetTexture(_props.ExtraTex, PlaceholderBlack());
            _mpb.SetFloat(_props.Opacity, composite.Opacity);
            _mpb.SetInt(_props.BlendMode, composite.BlendingMode);
            _mpb.SetInt(_props.UseMultistageBlend, 0);
            _mpb.SetInt(_props.UsesStencil, 0);
            var material = ResolveMaterial(composite.BlendingMode, true);
            ApplyBlendToMaterial(material, composite.BlendingMode);
            ApplyStencil(_mpb, StencilMode.Off);
            // Blit back to the parent target using clip-space full-screen quad.
            var parentTarget = ctx.ParentTarget;
            var parentProj = ctx.ParentProjection;
            _currentTarget = parentTarget;
            _currentProjection = parentProj;
            _cb.SetRenderTarget(parentTarget);
            _cb.SetViewport(new Rect(0, 0, parentProj.Width, parentProj.Height));
            _cb.SetViewProjectionMatrices(Matrix4x4.identity, Matrix4x4.identity);
            // Full-screen quad (-1..1) -> scale 2 in clip space. Flip Y to account for RT vertical inversion.
            var matrix = Matrix4x4.TRS(Vector3.zero, Quaternion.identity, new Vector3(2f, -2f, 1f));
            _cb.DrawMesh(_quadMesh, matrix, material, 0, 0, _mpb);
            // 髫包ｽｪ邵ｺ・ｮ陝・・繝ｻ・ｽ繝ｻ・ｽ髫ｪ・ｭ陞ｳ螢ｹ・定墓ｪ趣ｽｶ螢ｽ邱帝包ｽｻ邵ｺ・ｮ邵ｺ貅假ｽ∫ｸｺ・ｫ陟包ｽｩ陷医・繝ｻ・ｽ繝ｻ・ｽ郢ｧ繝ｻ
            ApplyProjectionState(_currentProjection);
        }
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
        private void ReleaseSharedCompositeRt()
        {
            if (_sharedCompositeRt != null)
            {
                Log($"[Nijilive] Release shared Composite RT size={_sharedCompositeRt.width}x{_sharedCompositeRt.height} frame={_frameId}");
                RenderTexture.ReleaseTemporary(_sharedCompositeRt);
                _sharedCompositeRt = null;
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
