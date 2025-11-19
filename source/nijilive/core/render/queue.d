module nijilive.core.render.queue;

import nijilive.core.render.commands;
import nijilive.core.render.backends : RenderingBackend, BackendEnum, RenderGpuState;
import nijilive.core.render.profiler : profileScope;
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

alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);

/// Simple GPU command queue that replays prepared command lists.
final class RenderQueue {
private:
    RenderCommandData[] commands;

public:
    void clear() {
        commands.length = 0;
    }

    bool empty() const {
        return commands.length == 0;
    }

    void setCommands(RenderCommandData[] prepared, bool copy = true) {
        if (copy) {
            commands = prepared.dup;
        } else {
            commands = prepared;
        }
    }

    void appendCommands(RenderCommandData[] prepared) {
        commands ~= prepared;
    }

    void enqueue(RenderCommandData command) {
        commands ~= command;
    }

    void flush(RenderBackend backend, ref RenderGpuState state) {
        if (backend is null) {
            clear();
            return;
        }

        state = RenderGpuState.init;
        auto profiling = profileScope("RenderQueue.Flush");
        if (sharedVertexBufferDirty()) {
            auto vertices = sharedVertexBufferData();
            if (vertices.length) {
                backend.uploadSharedVertexBuffer(vertices);
            }
            sharedVertexMarkUploaded();
        }
        if (sharedUvBufferDirty()) {
            auto uvs = sharedUvBufferData();
            if (uvs.length) {
                backend.uploadSharedUvBuffer(uvs);
            }
            sharedUvMarkUploaded();
        }
        if (sharedDeformBufferDirty()) {
            auto data = sharedDeformBufferData();
            if (data.length) {
                backend.uploadSharedDeformBuffer(data);
            }
            sharedDeformMarkUploaded();
        }
        foreach (ref command; commands) {
            final switch (command.kind) {
                case RenderCommandKind.DrawPart:
                    backend.drawPartPacket(command.partPacket);
                    break;
                case RenderCommandKind.DrawMask:
                    backend.drawMaskPacket(command.maskDrawPacket);
                    break;
                case RenderCommandKind.BeginDynamicComposite:
                    if (command.dynamicCompositePass !is null) backend.beginDynamicComposite(command.dynamicCompositePass);
                    break;
                case RenderCommandKind.EndDynamicComposite:
                    if (command.dynamicCompositePass !is null) backend.endDynamicComposite(command.dynamicCompositePass);
                    break;
                case RenderCommandKind.BeginMask:
                    backend.beginMask(command.maskUsesStencil);
                    break;
                case RenderCommandKind.ApplyMask:
                    backend.applyMask(command.maskPacket);
                    break;
                case RenderCommandKind.BeginMaskContent:
                    backend.beginMaskContent();
                    break;
                case RenderCommandKind.EndMask:
                    backend.endMask();
                    break;
                case RenderCommandKind.BeginComposite:
                    backend.beginComposite();
                    break;
                case RenderCommandKind.DrawCompositeQuad:
                    backend.drawCompositeQuad(command.compositePacket);
                    break;
                case RenderCommandKind.EndComposite:
                    backend.endComposite();
                    break;
            }
        }

        clear();
    }
}
