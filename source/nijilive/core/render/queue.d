module nijilive.core.render.queue;

import nijilive.core.render.commands;
import nijilive.core.render.backends : RenderBackend, RenderGpuState;

final class RenderQueue {
private:
    RenderCommandData[] commands;
public:
    void clear() {
        commands.length = 0;
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
                case RenderCommandKind.DrawNode:
                    if (command.node !is null) backend.drawNode(command.node);
                    break;
                case RenderCommandKind.DrawPart:
                    backend.drawPartPacket(command.partPacket);
                    break;
                case RenderCommandKind.DrawComposite:
                    if (command.composite !is null) backend.drawCompositeRaw(command.composite);
                    break;
                case RenderCommandKind.BeginMask:
                    backend.beginMask(command.maskUsesStencil);
                    break;
                case RenderCommandKind.ApplyMask:
                    backend.applyMask(command.maskDrawable, command.maskIsDodge);
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

    bool empty() const {
        return commands.length == 0;
    }
}
