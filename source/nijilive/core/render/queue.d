module nijilive.core.render.queue;

import nijilive.core.render.commands;
import nijilive.core.render.backends : RenderBackend, RenderGpuState;

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

    void setCommands(RenderCommandData[] prepared) {
        commands = prepared.dup;
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
        foreach (ref command; commands) {
            final switch (command.kind) {
                case RenderCommandKind.DrawPart:
                    backend.drawPartPacket(command.partPacket);
                    break;
                case RenderCommandKind.DrawMask:
                    backend.drawMaskPacket(command.maskDrawPacket);
                    break;
                case RenderCommandKind.BeginDynamicComposite:
                    if (command.dynamicComposite !is null) backend.beginDynamicComposite(command.dynamicComposite);
                    break;
                case RenderCommandKind.EndDynamicComposite:
                    if (command.dynamicComposite !is null) backend.endDynamicComposite(command.dynamicComposite);
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
