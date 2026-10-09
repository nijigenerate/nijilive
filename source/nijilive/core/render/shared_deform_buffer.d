module nijilive.core.render.shared_deform_buffer;

import std.algorithm : min;
import core.memory : GC;
import core.atomic : cas, atomicStore;
import core.stdc.stdlib : malloc, free;
import core.exception : onOutOfMemoryError;

import nijilive.math : Vec2Array;

private struct SharedVecAtlas {
    private struct Binding {
        Vec2Array* target;
        size_t* offsetSink;
        size_t length;
        size_t offset;
    }

    Vec2Array storage;
    Binding[] bindings;
    size_t[Vec2Array*] lookup;
    bool dirty;
    private struct PendingRemoval {
        Vec2Array* target;
        PendingRemoval* next;
    }
    private PendingRemoval* pendingRemovals;
    private shared int removalLock;

    private void lockRemovals() {
        while (!cas(&removalLock, 0, 1)) {}
    }

    private void enqueueRemoval(Vec2Array* target) {
        // Finalizers may run on a worker. No GC allocation or atlas mutation here.
        auto entry = cast(PendingRemoval*)malloc(PendingRemoval.sizeof);
        if (entry is null) onOutOfMemoryError();
        entry.target = target;
        lockRemovals();
        entry.next = pendingRemovals;
        pendingRemovals = entry;
        atomicStore(removalLock, 0);
    }

    void processPendingRemovals() {
        // Detach under an allocation-free lock before rebuilding on the editor thread.
        lockRemovals();
        auto entries = pendingRemovals;
        pendingRemovals = null;
        atomicStore(removalLock, 0);
        bool changed;
        while (entries !is null) {
            auto next = entries.next;
            changed = removeArray(entries.target) || changed;
            free(entries);
            entries = next;
        }
        if (changed) rebuild();
    }

    private bool removeArray(Vec2Array* ptr) {
        if (auto found = ptr in lookup) {
            auto idx = *found;
            auto last = bindings.length - 1;
            lookup.remove(ptr);
            if (idx != last) {
                bindings[idx] = bindings[last];
                lookup[bindings[idx].target] = idx;
            }
            bindings[last] = Binding.init;
            bindings.length = last;
            return true;
        }
        return false;
    }

    void registerArray(ref Vec2Array target, size_t* offsetSink) {
        processPendingRemovals();
        auto ptr = &target;
        if (auto found = ptr in lookup) {
            auto idx = *found;
            bindings[idx].offsetSink = offsetSink;
            return;
        }
        auto idx = bindings.length;
        lookup[ptr] = idx;
        bindings ~= Binding(ptr, offsetSink, target.length, 0);
        rebuild();
    }

    void unregisterArray(ref Vec2Array target) {
        if (GC.inFinalizer) {
            enqueueRemoval(&target);
            return;
        }
        processPendingRemovals();
        if (removeArray(&target)) rebuild();
    }

    void resizeArray(ref Vec2Array target, size_t newLength) {
        processPendingRemovals();
        auto ptr = &target;
        if (auto found = ptr in lookup) {
            auto idx = *found;
            if (bindings[idx].length == newLength) {
                return;
            }
            bindings[idx].length = newLength;
            rebuild();
        }
    }

    size_t stride() const {
        return storage.length;
    }

    ref Vec2Array data() {
        return storage;
    }

    bool isDirty() {
        processPendingRemovals();
        return dirty;
    }

    void markDirty() {
        dirty = true;
    }

    void markUploaded() {
        dirty = false;
    }

private:
    void rebuild() {
        size_t total = 0;
        foreach (binding; bindings) {
            total += binding.length;
        }

        Vec2Array newStorage;
        if (total) {
            newStorage.length = total;
            size_t offset = 0;
            foreach (ref binding; bindings) {
                auto len = binding.length;
                if (len) {
                    auto dstX = newStorage.lane(0)[offset .. offset + len];
                    auto dstY = newStorage.lane(1)[offset .. offset + len];
                    auto src = *binding.target;
                    auto copyLen = min(len, src.length);
                    if (copyLen) {
                        dstX[0 .. copyLen] = src.lane(0)[0 .. copyLen];
                        dstY[0 .. copyLen] = src.lane(1)[0 .. copyLen];
                    }
                    if (copyLen < len) {
                        dstX[copyLen .. len] = 0;
                        dstY[copyLen .. len] = 0;
                    }
                } else {
                    (*binding.target).clear();
                }
                binding.offset = offset;
                offset += len;
            }
        } else {
            foreach (ref binding; bindings) {
                binding.offset = 0;
                (*binding.target).clear();
            }
        }

        storage = newStorage;
        foreach (ref binding; bindings) {
            if (binding.length) {
                (*binding.target).bindExternalStorage(storage, binding.offset, binding.length);
            } else {
                (*binding.target).clear();
            }
            if (binding.offsetSink !is null) {
                *binding.offsetSink = binding.offset;
            }
        }
        dirty = true;
    }
}

private __gshared {
    SharedVecAtlas deformAtlas;
    SharedVecAtlas vertexAtlas;
    SharedVecAtlas uvAtlas;
}

/** Read-only accounting of the shared rendering atlas registrations. */
ulong[6] ngSharedRenderAtlasMemoryInfo() {
    deformAtlas.processPendingRemovals();
    vertexAtlas.processPendingRemovals();
    uvAtlas.processPendingRemovals();
    return [cast(ulong)deformAtlas.bindings.length, cast(ulong)vertexAtlas.bindings.length,
        cast(ulong)uvAtlas.bindings.length, cast(ulong)deformAtlas.storage.length * 2 * float.sizeof,
        cast(ulong)vertexAtlas.storage.length * 2 * float.sizeof,
        cast(ulong)uvAtlas.storage.length * 2 * float.sizeof];
}

package(nijilive) void sharedDeformRegister(ref Vec2Array target, size_t* offsetSink) {
    deformAtlas.registerArray(target, offsetSink);
}

package(nijilive) void sharedDeformUnregister(ref Vec2Array target) {
    deformAtlas.unregisterArray(target);
}

package(nijilive) void sharedDeformResize(ref Vec2Array target, size_t newLength) {
    deformAtlas.resizeArray(target, newLength);
}

package(nijilive) size_t sharedDeformAtlasStride() {
    return deformAtlas.stride();
}

package(nijilive) ref Vec2Array sharedDeformBufferData() {
    return deformAtlas.data();
}

package(nijilive) bool sharedDeformBufferDirty() {
    return deformAtlas.isDirty();
}

package(nijilive) void sharedDeformMarkDirty() {
    deformAtlas.markDirty();
}

package(nijilive) void sharedDeformMarkUploaded() {
    deformAtlas.markUploaded();
}

package(nijilive) void sharedVertexRegister(ref Vec2Array target, size_t* offsetSink) {
    vertexAtlas.registerArray(target, offsetSink);
}

package(nijilive) void sharedVertexUnregister(ref Vec2Array target) {
    vertexAtlas.unregisterArray(target);
}

package(nijilive) void sharedVertexResize(ref Vec2Array target, size_t newLength) {
    vertexAtlas.resizeArray(target, newLength);
}

package(nijilive) size_t sharedVertexAtlasStride() {
    return vertexAtlas.stride();
}

package(nijilive) ref Vec2Array sharedVertexBufferData() {
    return vertexAtlas.data();
}

package(nijilive) bool sharedVertexBufferDirty() {
    return vertexAtlas.isDirty();
}

package(nijilive) void sharedVertexMarkDirty() {
    vertexAtlas.markDirty();
}

package(nijilive) void sharedVertexMarkUploaded() {
    vertexAtlas.markUploaded();
}

package(nijilive) void sharedUvRegister(ref Vec2Array target, size_t* offsetSink) {
    uvAtlas.registerArray(target, offsetSink);
}

package(nijilive) void sharedUvUnregister(ref Vec2Array target) {
    uvAtlas.unregisterArray(target);
}

package(nijilive) void sharedUvResize(ref Vec2Array target, size_t newLength) {
    uvAtlas.resizeArray(target, newLength);
}

package(nijilive) size_t sharedUvAtlasStride() {
    return uvAtlas.stride();
}

package(nijilive) ref Vec2Array sharedUvBufferData() {
    return uvAtlas.data();
}

package(nijilive) bool sharedUvBufferDirty() {
    return uvAtlas.isDirty();
}

package(nijilive) void sharedUvMarkDirty() {
    uvAtlas.markDirty();
}

package(nijilive) void sharedUvMarkUploaded() {
    uvAtlas.markUploaded();
}
