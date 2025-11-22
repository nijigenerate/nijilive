module nijilive.core.render.backends.queue;

version (UseQueueBackend) {

version (InDoesRender) {

import nijilive.core.render.command_emitter : RenderCommandEmitter;
import nijilive.core.render.commands;
import nijilive.core.render.backends : RenderBackend, RenderGpuState;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.mask : Mask;
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;

/// Captured command information emitted sequentially.
struct QueuedCommand {
    RenderCommandKind kind;
    union Payload {
        PartDrawPacket partPacket;
        MaskDrawPacket maskPacket;
        MaskApplyPacket maskApplyPacket;
        CompositeDrawPacket compositePacket;
        DynamicCompositePass dynamicPass;
    }
    Payload payload;
    bool usesStencil;
}

/// CommandEmitter implementation that records commands into an in-memory queue.
final class CommandQueueEmitter : RenderCommandEmitter {
private:
    QueuedCommand[] queueData;
    RenderBackend activeBackend;
    RenderGpuState* statePtr;

public:
    void beginFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        statePtr = &state;
        state = RenderGpuState.init;
        queueData.length = 0;
    }

    void drawPart(Part part, bool isMask) {
        if (part is null) return;
        auto packet = makePartDrawPacket(part, isMask);
        record(RenderCommandKind.DrawPart, (ref QueuedCommand cmd) {
            cmd.payload.partPacket = packet;
        });
    }

    void drawMask(Mask mask) {
        if (mask is null) return;
        auto packet = makeMaskDrawPacket(mask);
        record(RenderCommandKind.DrawMask, (ref QueuedCommand cmd) {
            cmd.payload.maskPacket = packet;
        });
    }

    void beginDynamicComposite(DynamicComposite composite, DynamicCompositePass passData) {
        record(RenderCommandKind.BeginDynamicComposite, (ref QueuedCommand cmd) {
            cmd.payload.dynamicPass = passData;
        });
    }

    void endDynamicComposite(DynamicComposite composite, DynamicCompositePass passData) {
        record(RenderCommandKind.EndDynamicComposite, (ref QueuedCommand cmd) {
            cmd.payload.dynamicPass = passData;
        });
    }

    void beginMask(bool useStencil) {
        record(RenderCommandKind.BeginMask, (ref QueuedCommand cmd) {
            cmd.usesStencil = useStencil;
        });
    }

    void applyMask(Drawable drawable, bool isDodge) {
        if (drawable is null) return;
        MaskApplyPacket packet;
        if (!tryMakeMaskApplyPacket(drawable, isDodge, packet)) return;
        record(RenderCommandKind.ApplyMask, (ref QueuedCommand cmd) {
            cmd.payload.maskApplyPacket = packet;
        });
    }

    void beginMaskContent() {
        record(RenderCommandKind.BeginMaskContent, (ref QueuedCommand) {});
    }

    void endMask() {
        record(RenderCommandKind.EndMask, (ref QueuedCommand) {});
    }

    void beginComposite(Composite composite) {
        record(RenderCommandKind.BeginComposite, (ref QueuedCommand) {});
    }

    void drawCompositeQuad(Composite composite) {
        if (composite is null) return;
        auto packet = makeCompositeDrawPacket(composite);
        record(RenderCommandKind.DrawCompositeQuad, (ref QueuedCommand cmd) {
            cmd.payload.compositePacket = packet;
        });
    }

    void endComposite(Composite composite) {
        record(RenderCommandKind.EndComposite, (ref QueuedCommand) {});
    }

    void endFrame(RenderBackend backend, ref RenderGpuState state) {
        activeBackend = backend;
        statePtr = &state;
    }

    /// Returns a copy of the recorded commands.
    const(QueuedCommand)[] queuedCommands() const {
        return queueData;
    }

    /// Clears all recorded commands.
    void clearQueue() {
        queueData.length = 0;
    }

private:
    void record(RenderCommandKind kind, scope void delegate(ref QueuedCommand) fill) {
        QueuedCommand cmd;
        cmd.kind = kind;
        fill(cmd);
        queueData ~= cmd;
    }
}

}

}
