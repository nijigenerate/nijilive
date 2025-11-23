using System;
using System.Collections.Generic;
using Nijilive.Unity.Interop;

namespace Nijilive.Unity.Managed;

/// <summary>
/// Decodes native queued commands into managed DTOs for easier rendering integration.
/// This does not issue Unity rendering API calls directly; it prepares a stream you can
/// translate into CommandBuffer / material bindings on the Unity side.
/// </summary>
public static unsafe class CommandStream
{
    public abstract record Command(NijiliveNative.NjgRenderCommandKind Kind);

    public sealed record DrawPart(DrawPacket Part) : Command(NijiliveNative.NjgRenderCommandKind.DrawPart);
    public sealed record DrawMask(MaskPacket Mask) : Command(NijiliveNative.NjgRenderCommandKind.DrawMask);
    public sealed record ApplyMask(MaskApplyPacket Apply) : Command(NijiliveNative.NjgRenderCommandKind.ApplyMask);
    public sealed record BeginDynamicComposite(DynamicCompositePass Pass) : Command(NijiliveNative.NjgRenderCommandKind.BeginDynamicComposite);
    public sealed record EndDynamicComposite(DynamicCompositePass Pass) : Command(NijiliveNative.NjgRenderCommandKind.EndDynamicComposite);
    public sealed record BeginMask(bool UsesStencil) : Command(NijiliveNative.NjgRenderCommandKind.BeginMask);
    public sealed record BeginMaskContent() : Command(NijiliveNative.NjgRenderCommandKind.BeginMaskContent);
    public sealed record EndMask() : Command(NijiliveNative.NjgRenderCommandKind.EndMask);
    public sealed record BeginComposite() : Command(NijiliveNative.NjgRenderCommandKind.BeginComposite);
    public sealed record DrawCompositeQuad(CompositePacket Composite) : Command(NijiliveNative.NjgRenderCommandKind.DrawCompositeQuad);
    public sealed record EndComposite() : Command(NijiliveNative.NjgRenderCommandKind.EndComposite);

    public sealed record DrawPacket(
        bool IsMask,
        bool Renderable,
        NijiliveNative.Mat4 ModelMatrix,
        NijiliveNative.Mat4 PuppetMatrix,
        NijiliveNative.Vec3 ClampedTint,
        NijiliveNative.Vec3 ClampedScreen,
        float Opacity,
        float EmissionStrength,
        float MaskThreshold,
        int BlendingMode,
        bool UseMultistageBlend,
        bool HasEmissionOrBumpmap,
        ReadOnlyMemory<nuint> TextureHandles,
        NijiliveNative.Vec2 Origin,
        nuint VertexOffset,
        nuint VertexAtlasStride,
        nuint UvOffset,
        nuint UvAtlasStride,
        nuint DeformOffset,
        nuint DeformAtlasStride,
        IntPtr Indices,
        nuint IndexCount,
        nuint VertexCount);

    public sealed record MaskPacket(
        NijiliveNative.Mat4 ModelMatrix,
        NijiliveNative.Mat4 Mvp,
        NijiliveNative.Vec2 Origin,
        nuint VertexOffset,
        nuint VertexAtlasStride,
        nuint DeformOffset,
        nuint DeformAtlasStride,
        IntPtr Indices,
        nuint IndexCount,
        nuint VertexCount);

    public sealed record MaskApplyPacket(
        NijiliveNative.MaskDrawableKind Kind,
        bool IsDodge,
        DrawPacket Part,
        MaskPacket Mask);

    public sealed record CompositePacket(
        bool Valid,
        float Opacity,
        NijiliveNative.Vec3 Tint,
        NijiliveNative.Vec3 ScreenTint,
        int BlendingMode);

    public sealed record DynamicCompositePass(
        ReadOnlyMemory<nuint> Textures,
        nuint Stencil,
        NijiliveNative.Vec2 Scale,
        float RotationZ,
        nuint OrigBuffer,
        (int X, int Y, int W, int H) OrigViewport);

    public static IReadOnlyList<Command> Decode(ReadOnlySpan<NijiliveNative.NjgQueuedCommand> commands)
    {
        var list = new List<Command>(commands.Length);
        foreach (ref readonly var cmd in commands)
        {
            switch (cmd.Kind)
            {
                case NijiliveNative.NjgRenderCommandKind.DrawPart:
                    list.Add(new DrawPart(ToDrawPacket(cmd.PartPacket)));
                    break;
                case NijiliveNative.NjgRenderCommandKind.DrawMask:
                    list.Add(new DrawMask(ToMaskPacket(cmd.MaskPacket)));
                    break;
                case NijiliveNative.NjgRenderCommandKind.ApplyMask:
                    list.Add(new ApplyMask(new MaskApplyPacket(
                        cmd.MaskApplyPacket.Kind,
                        cmd.MaskApplyPacket.IsDodge,
                        ToDrawPacket(cmd.MaskApplyPacket.PartPacket),
                        ToMaskPacket(cmd.MaskApplyPacket.MaskPacket)
                    )));
                    break;
                case NijiliveNative.NjgRenderCommandKind.BeginDynamicComposite:
                    list.Add(new BeginDynamicComposite(ToDynamicPass(cmd.DynamicPass)));
                    break;
                case NijiliveNative.NjgRenderCommandKind.EndDynamicComposite:
                    list.Add(new EndDynamicComposite(ToDynamicPass(cmd.DynamicPass)));
                    break;
                case NijiliveNative.NjgRenderCommandKind.BeginMask:
                    list.Add(new BeginMask(cmd.UsesStencil));
                    break;
                case NijiliveNative.NjgRenderCommandKind.BeginMaskContent:
                    list.Add(new BeginMaskContent());
                    break;
                case NijiliveNative.NjgRenderCommandKind.EndMask:
                    list.Add(new EndMask());
                    break;
                case NijiliveNative.NjgRenderCommandKind.BeginComposite:
                    list.Add(new BeginComposite());
                    break;
                case NijiliveNative.NjgRenderCommandKind.DrawCompositeQuad:
                    list.Add(new DrawCompositeQuad(new CompositePacket(
                        cmd.CompositePacket.Valid,
                        cmd.CompositePacket.Opacity,
                        cmd.CompositePacket.Tint,
                        cmd.CompositePacket.ScreenTint,
                        cmd.CompositePacket.BlendingMode
                    )));
                    break;
                case NijiliveNative.NjgRenderCommandKind.EndComposite:
                    list.Add(new EndComposite());
                    break;
                default:
                    break;
            }
        }
        return list;
    }

    private static DrawPacket ToDrawPacket(in NijiliveNative.NjgPartDrawPacket p)
    {
        var handles = new nuint[checked((int)p.TextureCount)];
        if (handles.Length > 0)
        {
            if (handles.Length > 0) handles[0] = p.TextureHandle0;
            if (handles.Length > 1) handles[1] = p.TextureHandle1;
            if (handles.Length > 2) handles[2] = p.TextureHandle2;
        }
        return new DrawPacket(
            p.IsMask,
            p.Renderable,
            p.ModelMatrix,
            p.PuppetMatrix,
            p.ClampedTint,
            p.ClampedScreen,
            p.Opacity,
            p.EmissionStrength,
            p.MaskThreshold,
            p.BlendingMode,
            p.UseMultistageBlend,
            p.HasEmissionOrBumpmap,
            handles,
            p.Origin,
            p.VertexOffset,
            p.VertexAtlasStride,
            p.UvOffset,
            p.UvAtlasStride,
            p.DeformOffset,
            p.DeformAtlasStride,
            (IntPtr)p.Indices,
            p.IndexCount,
            p.VertexCount);
    }

    private static MaskPacket ToMaskPacket(in NijiliveNative.NjgMaskDrawPacket p)
    {
        return new MaskPacket(
            p.ModelMatrix,
            p.Mvp,
            p.Origin,
            p.VertexOffset,
            p.VertexAtlasStride,
            p.DeformOffset,
            p.DeformAtlasStride,
            (IntPtr)p.Indices,
            p.IndexCount,
            p.VertexCount);
    }

    private static DynamicCompositePass ToDynamicPass(in NijiliveNative.NjgDynamicCompositePass p)
    {
        var textures = new nuint[checked((int)p.TextureCount)];
        if (textures.Length > 0)
        {
            if (textures.Length > 0) textures[0] = p.Texture0;
            if (textures.Length > 1) textures[1] = p.Texture1;
            if (textures.Length > 2) textures[2] = p.Texture2;
        }
        return new DynamicCompositePass(
            textures,
            p.Stencil,
            p.Scale,
            p.RotationZ,
            p.OrigBuffer,
            (p.OrigViewport0, p.OrigViewport1, p.OrigViewport2, p.OrigViewport3));
    }
}
