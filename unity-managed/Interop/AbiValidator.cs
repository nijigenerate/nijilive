// ABI validation mirrored from nicxlive unity_backend/unity_backend.cs (BSD-2-Clause).
using System;
using System.Runtime.InteropServices;
namespace Nijilive.Unity.Interop
{
    internal static class AbiValidator
    {
        private static bool _validated;

        public static void ValidateOrThrow()
        {
            if (_validated)
            {
                return;
            }

            var result = NijiliveNative.GetWasmLayout(out var native);
            if (result != NijiliveNative.NjgResult.Ok)
            {
                throw new InvalidOperationException($"njgGetWasmLayout failed: {result}");
            }

            RequireEqual("sizeof(NjgQueuedCommand)", (uint)Marshal.SizeOf<NijiliveNative.NjgQueuedCommand>(), native.SizeQueued);
            RequireEqual("offsetof(NjgQueuedCommand.PartPacket)", Offset<NijiliveNative.NjgQueuedCommand>(nameof(NijiliveNative.NjgQueuedCommand.PartPacket)), native.OffQueuedPart);
            RequireEqual("offsetof(NjgQueuedCommand.MaskApplyPacket)", Offset<NijiliveNative.NjgQueuedCommand>(nameof(NijiliveNative.NjgQueuedCommand.MaskApplyPacket)), native.OffQueuedMaskApply);
            RequireEqual("offsetof(NjgQueuedCommand.DynamicPass)", Offset<NijiliveNative.NjgQueuedCommand>(nameof(NijiliveNative.NjgQueuedCommand.DynamicPass)), native.OffQueuedDynamic);
            RequireEqual("offsetof(NjgQueuedCommand.UsesStencil)", Offset<NijiliveNative.NjgQueuedCommand>(nameof(NijiliveNative.NjgQueuedCommand.UsesStencil)), native.OffQueuedUsesStencil);

            RequireEqual("sizeof(NjgPartDrawPacket)", (uint)Marshal.SizeOf<NijiliveNative.NjgPartDrawPacket>(), native.SizePart);
            RequireEqual("offsetof(NjgPartDrawPacket.TextureHandle0)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.TextureHandle0)), native.OffPartTextureHandles);
            RequireEqual("offsetof(NjgPartDrawPacket.TextureCount)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.TextureCount)), native.OffPartTextureCount);
            RequireEqual("offsetof(NjgPartDrawPacket.Origin)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.Origin)), native.OffPartOrigin);
            RequireEqual("offsetof(NjgPartDrawPacket.VertexOffset)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.VertexOffset)), native.OffPartVertexOffset);
            RequireEqual("offsetof(NjgPartDrawPacket.VertexAtlasStride)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.VertexAtlasStride)), native.OffPartVertexStride);
            RequireEqual("offsetof(NjgPartDrawPacket.UvOffset)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.UvOffset)), native.OffPartUvOffset);
            RequireEqual("offsetof(NjgPartDrawPacket.UvAtlasStride)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.UvAtlasStride)), native.OffPartUvStride);
            RequireEqual("offsetof(NjgPartDrawPacket.DeformOffset)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.DeformOffset)), native.OffPartDeformOffset);
            RequireEqual("offsetof(NjgPartDrawPacket.DeformAtlasStride)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.DeformAtlasStride)), native.OffPartDeformStride);
            RequireEqual("offsetof(NjgPartDrawPacket.IndexHandle)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.IndexHandle)), native.OffPartIndexHandle);
            RequireEqual("offsetof(NjgPartDrawPacket.Indices)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.Indices)), native.OffPartIndicesPtr);
            RequireEqual("offsetof(NjgPartDrawPacket.IndexCount)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.IndexCount)), native.OffPartIndexCount);
            RequireEqual("offsetof(NjgPartDrawPacket.VertexCount)", Offset<NijiliveNative.NjgPartDrawPacket>(nameof(NijiliveNative.NjgPartDrawPacket.VertexCount)), native.OffPartVertexCount);

            RequireEqual("sizeof(NjgMaskDrawPacket)", (uint)Marshal.SizeOf<NijiliveNative.NjgMaskDrawPacket>(), native.SizeMaskDraw);
            RequireEqual("offsetof(NjgMaskDrawPacket.Indices)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.Indices)), native.OffMaskDrawIndicesPtr);
            RequireEqual("offsetof(NjgMaskDrawPacket.IndexCount)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.IndexCount)), native.OffMaskDrawIndexCount);
            RequireEqual("offsetof(NjgMaskDrawPacket.VertexOffset)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.VertexOffset)), native.OffMaskDrawVertexOffset);
            RequireEqual("offsetof(NjgMaskDrawPacket.VertexAtlasStride)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.VertexAtlasStride)), native.OffMaskDrawVertexStride);
            RequireEqual("offsetof(NjgMaskDrawPacket.DeformOffset)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.DeformOffset)), native.OffMaskDrawDeformOffset);
            RequireEqual("offsetof(NjgMaskDrawPacket.DeformAtlasStride)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.DeformAtlasStride)), native.OffMaskDrawDeformStride);
            RequireEqual("offsetof(NjgMaskDrawPacket.IndexHandle)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.IndexHandle)), native.OffMaskDrawIndexHandle);
            RequireEqual("offsetof(NjgMaskDrawPacket.VertexCount)", Offset<NijiliveNative.NjgMaskDrawPacket>(nameof(NijiliveNative.NjgMaskDrawPacket.VertexCount)), native.OffMaskDrawVertexCount);

            RequireEqual("sizeof(NjgMaskApplyPacket)", (uint)Marshal.SizeOf<NijiliveNative.NjgMaskApplyPacket>(), native.SizeMaskApply);
            RequireEqual("offsetof(NjgMaskApplyPacket.Kind)", Offset<NijiliveNative.NjgMaskApplyPacket>(nameof(NijiliveNative.NjgMaskApplyPacket.Kind)), native.OffMaskKind);
            RequireEqual("offsetof(NjgMaskApplyPacket.IsDodge)", Offset<NijiliveNative.NjgMaskApplyPacket>(nameof(NijiliveNative.NjgMaskApplyPacket.IsDodge)), native.OffMaskIsDodge);
            RequireEqual("offsetof(NjgMaskApplyPacket.PartPacket)", Offset<NijiliveNative.NjgMaskApplyPacket>(nameof(NijiliveNative.NjgMaskApplyPacket.PartPacket)), native.OffMaskPartPacket);
            RequireEqual("offsetof(NjgMaskApplyPacket.MaskPacket)", Offset<NijiliveNative.NjgMaskApplyPacket>(nameof(NijiliveNative.NjgMaskApplyPacket.MaskPacket)), native.OffMaskMaskPacket);

            RequireEqual("sizeof(NjgDynamicCompositePass)", (uint)Marshal.SizeOf<NijiliveNative.NjgDynamicCompositePass>(), native.SizeDynamicPass);
            RequireEqual("offsetof(NjgDynamicCompositePass.Texture0)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.Texture0)), native.OffDynTextures);
            RequireEqual("offsetof(NjgDynamicCompositePass.TextureCount)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.TextureCount)), native.OffDynTextureCount);
            RequireEqual("offsetof(NjgDynamicCompositePass.Stencil)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.Stencil)), native.OffDynStencil);
            RequireEqual("offsetof(NjgDynamicCompositePass.Scale)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.Scale)), native.OffDynScale);
            RequireEqual("offsetof(NjgDynamicCompositePass.RotationZ)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.RotationZ)), native.OffDynRotationZ);
            RequireEqual("offsetof(NjgDynamicCompositePass.AutoScaled)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.AutoScaled)), native.OffDynAutoScaled);
            RequireEqual("offsetof(NjgDynamicCompositePass.OrigBuffer)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.OrigBuffer)), native.OffDynOrigBuffer);
            RequireEqual("offsetof(NjgDynamicCompositePass.OrigViewport0)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.OrigViewport0)), native.OffDynOrigViewport);
            RequireEqual("offsetof(NjgDynamicCompositePass.DrawBufferCount)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.DrawBufferCount)), native.OffDynDrawBufferCount);
            RequireEqual("offsetof(NjgDynamicCompositePass.HasStencil)", Offset<NijiliveNative.NjgDynamicCompositePass>(nameof(NijiliveNative.NjgDynamicCompositePass.HasStencil)), native.OffDynHasStencil);

            _validated = true;
        }

        private static uint Offset<T>(string fieldName) where T : struct
        {
            return (uint)Marshal.OffsetOf<T>(fieldName).ToInt64();
        }

        private static void RequireEqual(string label, uint managed, uint native)
        {
            if (managed != native)
            {
                throw new InvalidOperationException($"{label} mismatch managed={managed} native={native}");
            }
        }
    }

}
