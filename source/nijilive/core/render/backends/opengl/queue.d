module nijilive.core.render.backends.opengl.queue;

import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.nodes.composite.projectable : Projectable;
import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.commands :
    makePartDrawPacket,
    tryMakeMaskApplyPacket,
    DynamicCompositePass,
    MaskApplyPacket;
import nijilive.core.render.backends : RenderBackend, RenderGpuState;
import nijilive.core.render.shared_deform_buffer :
    sharedDeformBufferDirty,
    sharedDeformBufferData,
    sharedDeformMarkUploaded,
    sharedVertexBufferDirty,
    sharedVertexBufferData,
    sharedVertexMarkUploaded,
    sharedUvBufferDirty,
    sharedUvBufferData,
    sharedUvMarkUploaded;
version (RenderBackendDirectX12) {
    import nijilive.core.render.backends.directx12.frame : dxBeginFrame, dxEndFrame;
}

version (InDoesRender) {

/// OpenGL-backed command emitter that translates node references into GPU packets.
final class RenderQueue : RenderCommandEmitter {
private:
    RenderBackend activeBackend;
    RenderGpuState* frameState;

    bool ready() const {
        return activeBackend !is null && frameState !is null;
    }

    void uploadSharedBuffers() {
        if (activeBackend is null) return;
        if (sharedVertexBufferDirty()) {
            auto vertices = sharedVertexBufferData();
            if (vertices.length) {
                activeBackend.uploadSharedVertexBuffer(vertices);
            }
            sharedVertexMarkUploaded();
        }
        if (sharedUvBufferDirty()) {
            auto uvs = sharedUvBufferData();
            if (uvs.length) {
                activeBackend.uploadSharedUvBuffer(uvs);
            }
            sharedUvMarkUploaded();
        }
        if (sharedDeformBufferDirty()) {
            auto data = sharedDeformBufferData();
            if (data.length) {
                activeBackend.uploadSharedDeformBuffer(data);
            }
            sharedDeformMarkUploaded();
        }
    }

public:
    void beginFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        frameState = &state;
        state = RenderGpuState.init;
        version (RenderBackendDirectX12) {
            dxBeginFrame(frameState);
        }
        uploadSharedBuffers();
    }

    void endFrame(RenderBackend, ref RenderGpuState state) {
        version (RenderBackendDirectX12) {
            dxEndFrame(&state);
        }
        activeBackend = null;
        frameState = null;
    }

    void drawPart(Part part, bool isMask) {
        if (!ready() || part is null) return;
        auto packet = makePartDrawPacket(part, isMask);
        activeBackend.drawPartPacket(packet);
    }

    void beginDynamicComposite(Projectable, DynamicCompositePass passData) {
        if (!ready() || passData is null) return;
        activeBackend.beginDynamicComposite(passData);
    }

    void endDynamicComposite(Projectable, DynamicCompositePass passData) {
        if (!ready() || passData is null) return;
        activeBackend.endDynamicComposite(passData);
    }

    void beginMask(bool useStencil) {
        if (!ready()) return;
        // useStencil == true when normal masks exist; false when dodge-only.
        activeBackend.beginMask(useStencil);
    }

    void applyMask(Drawable drawable, bool isDodge) {
        if (!ready() || drawable is null) return;
        MaskApplyPacket packet;
        if (tryMakeMaskApplyPacket(drawable, isDodge, packet)) {
            activeBackend.applyMask(packet);
        }
    }

    void beginMaskContent() {
        if (!ready()) return;
        activeBackend.beginMaskContent();
    }

    void endMask() {
        if (!ready()) return;
        activeBackend.endMask();
    }

}

} else {

final class RenderQueue : RenderCommandEmitter {
    void beginFrame(RenderBackend, ref RenderGpuState) {}
    void drawPart(Part, bool) {}
    void beginDynamicComposite(Projectable, DynamicCompositePass) {}
    void endDynamicComposite(Projectable, DynamicCompositePass) {}
    void beginMask(bool) {}
    void applyMask(Drawable, bool) {}
    void beginMaskContent() {}
    void endMask() {}
    void endFrame(RenderBackend, ref RenderGpuState) {}
}

}
