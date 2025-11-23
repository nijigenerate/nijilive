using System;

namespace Nijilive.Unity.Managed;

#if UNITY_5_3_OR_NEWER
using UnityEngine;

/// <summary>
/// Uploads shared SOA buffers into ComputeBuffers/GraphicsBuffers for shader access.
/// </summary>
public sealed class SharedBufferUploader : IDisposable
{
    public ComputeBuffer VertexBuffer { get; private set; }
    public ComputeBuffer UvBuffer { get; private set; }
    public ComputeBuffer DeformBuffer { get; private set; }

    public void Upload(Nijilive.Unity.Interop.NijiliveNative.SharedBufferSnapshot snapshot)
    {
        Upload(ref VertexBuffer, snapshot.Vertices);
        Upload(ref UvBuffer, snapshot.Uvs);
        Upload(ref DeformBuffer, snapshot.Deform);
    }

    private static void Upload(ref ComputeBuffer buffer, Nijilive.Unity.Interop.NijiliveNative.NjgBufferSlice slice)
    {
        var length = (int)slice.Length;
        if (length <= 0 || slice.Data == IntPtr.Zero)
        {
            buffer?.Release();
            buffer = null;
            return;
        }
        if (buffer == null || buffer.count != length)
        {
            buffer?.Release();
            buffer = new ComputeBuffer(length, sizeof(float));
        }
        buffer.SetData(slice.Data, 0, 0, length);
    }

    public void Dispose()
    {
        VertexBuffer?.Release();
        UvBuffer?.Release();
        DeformBuffer?.Release();
    }
}
#endif
