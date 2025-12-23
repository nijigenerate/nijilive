using System;
using System.Runtime.InteropServices;

namespace Nijilive.Unity.Interop
{
/// <summary>
/// P/Invoke surface that mirrors the C ABI exported by nijilive-unity.dll.
/// Struct layouts and field types must stay aligned with source/nijilive/integration/unity.d.
/// </summary>
public static class NijiliveNative
{
    private const string DllName = "nijilive-unity";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate nuint CreateTextureDelegate(int width, int height, int channels, int mipLevels, int format, [MarshalAs(UnmanagedType.I1)] bool renderTarget, [MarshalAs(UnmanagedType.I1)] bool stencil, IntPtr userData);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void UpdateTextureDelegate(nuint handle, IntPtr data, nuint dataLen, int width, int height, int channels, IntPtr userData);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void ReleaseTextureDelegate(nuint handle, IntPtr userData);

    public enum NjgResult : int
    {
        Ok = 0,
        InvalidArgument = 1,
        Failure = 2,
    }

    public enum NjgRenderCommandKind : uint
    {
        DrawPart,
        DrawMask,
        BeginDynamicComposite,
        EndDynamicComposite,
        BeginMask,
        ApplyMask,
        BeginMaskContent,
        EndMask,
        BeginComposite,
        DrawCompositeQuad,
        EndComposite,
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct UnityRendererConfig
    {
        public int ViewportWidth;
        public int ViewportHeight;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct FrameConfig
    {
        public int ViewportWidth;
        public int ViewportHeight;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PuppetParameterUpdate
    {
        public uint ParameterUuid;
        public Vec2 Value;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ParameterInfo
    {
        public uint Uuid;
        [MarshalAs(UnmanagedType.I1)] public bool IsVec2;
        public Vec2 Min;
        public Vec2 Max;
        public Vec2 Defaults;
        public IntPtr Name;
        public nuint NameLength;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct UnityResourceCallbacks
    {
        public IntPtr UserData;
        public IntPtr CreateTexture;
        public IntPtr UpdateTexture;
        public IntPtr ReleaseTexture;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Vec2
    {
        public float X;
        public float Y;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Vec3
    {
        public float X;
        public float Y;
        public float Z;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Vec4
    {
        public float X;
        public float Y;
        public float Z;
        public float W;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct Mat4
    {
        public float M11; public float M12; public float M13; public float M14;
        public float M21; public float M22; public float M23; public float M24;
        public float M31; public float M32; public float M33; public float M34;
        public float M41; public float M42; public float M43; public float M44;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct NjgPartDrawPacket
    {
        [MarshalAs(UnmanagedType.I1)] public bool IsMask;
        [MarshalAs(UnmanagedType.I1)] public bool Renderable;
        public Mat4 ModelMatrix;
        public Mat4 PuppetMatrix;
        public Vec3 ClampedTint;
        public Vec3 ClampedScreen;
        public float Opacity;
        public float EmissionStrength;
        public float MaskThreshold;
        public int BlendingMode;
        [MarshalAs(UnmanagedType.I1)] public bool UseMultistageBlend;
        [MarshalAs(UnmanagedType.I1)] public bool HasEmissionOrBumpmap;
        public nuint TextureHandle0;
        public nuint TextureHandle1;
        public nuint TextureHandle2;
        public nuint TextureCount;
        public Vec2 Origin;
        public nuint VertexOffset;
        public nuint VertexAtlasStride;
        public nuint UvOffset;
        public nuint UvAtlasStride;
        public nuint DeformOffset;
        public nuint DeformAtlasStride;
        public ushort* Indices;
        public nuint IndexCount;
        public nuint VertexCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct NjgMaskDrawPacket
    {
        public Mat4 ModelMatrix;
        public Mat4 Mvp;
        public Vec2 Origin;
        public nuint VertexOffset;
        public nuint VertexAtlasStride;
        public nuint DeformOffset;
        public nuint DeformAtlasStride;
        public ushort* Indices;
        public nuint IndexCount;
        public nuint VertexCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NjgCompositeDrawPacket
    {
        [MarshalAs(UnmanagedType.I1)] public bool Valid;
        public float Opacity;
        public Vec3 Tint;
        public Vec3 ScreenTint;
        public int BlendingMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NjgDynamicCompositePass
    {
        public nuint Texture0;
        public nuint Texture1;
        public nuint Texture2;
        public nuint TextureCount;
        public nuint Stencil;
        public Vec2 Scale;
        public float RotationZ;
        public nuint OrigBuffer;
        public int OrigViewport0;
        public int OrigViewport1;
        public int OrigViewport2;
        public int OrigViewport3;
    }

    [StructLayout(LayoutKind.Sequential)]
    public unsafe struct NjgMaskApplyPacket
    {
        public MaskDrawableKind Kind;
        [MarshalAs(UnmanagedType.I1)] public bool IsDodge;
        public NjgPartDrawPacket PartPacket;
        public NjgMaskDrawPacket MaskPacket;
    }

    public enum MaskDrawableKind : int
    {
        // Keep in sync with nijilive.core.render.commands.MaskDrawableKind
        Part = 0,
        Mask = 1,
        // Reserved for future use; not emitted by the native side today.
        Composite = 2,
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct NjgQueuedCommand
    {
        public NjgRenderCommandKind Kind;
        public NjgPartDrawPacket PartPacket;
        public NjgMaskDrawPacket MaskPacket;
        public NjgMaskApplyPacket MaskApplyPacket;
        public NjgCompositeDrawPacket CompositePacket;
        public NjgDynamicCompositePass DynamicPass;
        [MarshalAs(UnmanagedType.I1)] public bool UsesStencil;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct CommandQueueView
    {
        public IntPtr Commands;
        public nuint Count;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TextureStats
    {
        public nuint Created;
        public nuint Released;
        public nuint Current;
    }

    [DllImport(DllName, EntryPoint = "njgFlushCommandBuffer", CallingConvention = CallingConvention.Cdecl)]
    public static extern NjgResult FlushCommandBuffer(IntPtr renderer);

    [DllImport(DllName, EntryPoint = "njgGetGcHeapSize", CallingConvention = CallingConvention.Cdecl)]
    public static extern nuint GetGcHeapSize();

    [DllImport(DllName, EntryPoint = "njgGetTextureStats", CallingConvention = CallingConvention.Cdecl)]
    public static extern TextureStats GetTextureStats(IntPtr renderer);

    [StructLayout(LayoutKind.Sequential)]
    public struct NjgBufferSlice
    {
        public IntPtr Data;
        public nuint Length;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SharedBufferSnapshot
    {
        public NjgBufferSlice Vertices;
        public NjgBufferSlice Uvs;
        public NjgBufferSlice Deform;
        public nuint VertexCount;
        public nuint UvCount;
        public nuint DeformCount;
    }

    [DllImport(DllName, EntryPoint = "njgCreateRenderer", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult CreateRenderer(ref UnityRendererConfig config, ref UnityResourceCallbacks callbacks, out IntPtr renderer);

    [DllImport(DllName, EntryPoint = "njgDestroyRenderer", CallingConvention = CallingConvention.Cdecl)]
    internal static extern void DestroyRenderer(IntPtr renderer);

    [DllImport(DllName, EntryPoint = "njgLoadPuppet", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult LoadPuppet(IntPtr renderer, [MarshalAs(UnmanagedType.LPUTF8Str)] string path, out IntPtr puppet);

    [DllImport(DllName, EntryPoint = "njgUnloadPuppet", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult UnloadPuppet(IntPtr renderer, IntPtr puppet);

    [DllImport(DllName, EntryPoint = "njgBeginFrame", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult BeginFrame(IntPtr renderer, ref FrameConfig config);

    [DllImport(DllName, EntryPoint = "njgTickPuppet", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult TickPuppet(IntPtr puppet, double deltaSeconds);

    [DllImport(DllName, EntryPoint = "njgEmitCommands", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult EmitCommands(IntPtr renderer, out CommandQueueView view);

    [DllImport(DllName, EntryPoint = "njgGetSharedBuffers", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult GetSharedBuffers(IntPtr renderer, out SharedBufferSnapshot snapshot);

    [DllImport(DllName, EntryPoint = "njgGetParameters", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult GetParameters(IntPtr puppet, IntPtr buffer, nuint bufferLength, out nuint outCount);

    [DllImport(DllName, EntryPoint = "njgUpdateParameters", CallingConvention = CallingConvention.Cdecl)]
    internal static extern NjgResult UpdateParameters(IntPtr puppet, IntPtr updates, nuint updateCount);
}
}
