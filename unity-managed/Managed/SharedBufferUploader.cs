using System;
#if UNITY_5_3_OR_NEWER
using UnityEngine;
#endif

namespace Nijilive.Unity.Managed
{
#if UNITY_5_3_OR_NEWER
    /// <summary>
    /// Uploads shared SOA buffers into ComputeBuffers/GraphicsBuffers for shader access.
    /// </summary>
    public sealed class SharedBufferUploader : IDisposable
    {
        private ComputeBuffer _vertexBuffer;
        private ComputeBuffer _uvBuffer;
        private ComputeBuffer _deformBuffer;

        public ComputeBuffer VertexBuffer => _vertexBuffer;
        public ComputeBuffer UvBuffer => _uvBuffer;
        public ComputeBuffer DeformBuffer => _deformBuffer;

        public void Upload(Nijilive.Unity.Interop.NijiliveNative.SharedBufferSnapshot snapshot)
        {
            Upload(ref _vertexBuffer, snapshot.Vertices, "Vertices");
            Upload(ref _uvBuffer, snapshot.Uvs, "UVs");
            Upload(ref _deformBuffer, snapshot.Deform, "Deform");
            Debug.Log($"[Nijilive] SharedBuffer lengths V={snapshot.Vertices.Length} U={snapshot.Uvs.Length} D={snapshot.Deform.Length} counts V={snapshot.VertexCount} U={snapshot.UvCount} D={snapshot.DeformCount}");
        }

        private static unsafe void Upload(ref ComputeBuffer buffer, Nijilive.Unity.Interop.NijiliveNative.NjgBufferSlice slice, string label)
        {
            var length = (int)slice.Length;
            if (length <= 0 || slice.Data == IntPtr.Zero)
            {
                if (buffer != null)
                {
                    Debug.LogWarning($"[Nijilive] SharedBuffer {label} length={length} data=null, releasing buffer");
                }
                buffer?.Release();
                buffer = null;
                return;
            }
            if (buffer == null || buffer.count != length)
            {
                if (buffer != null)
                {
                    Debug.LogWarning($"[Nijilive] SharedBuffer {label} resize {buffer.count} -> {length}");
                }
                buffer?.Release();
                buffer = new ComputeBuffer(length, sizeof(float));
            }

            // Copy from native float* to managed array, then upload.
            var data = new float[length];
            var src = (float*)slice.Data;
            for (int i = 0; i < length; i++)
            {
                data[i] = src[i];
            }
            buffer.SetData(data);
        }

        public void Dispose()
        {
            _vertexBuffer?.Release();
            _uvBuffer?.Release();
            _deformBuffer?.Release();
        }
    }
#endif
}
