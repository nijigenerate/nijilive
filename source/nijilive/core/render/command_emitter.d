module nijilive.core.render.command_emitter;

import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.nodes.composite.projectable : Projectable;
import nijilive.core.render.commands : DynamicCompositePass;
version (UseQueueBackend) {
    import nijilive.core.render.backends : RenderGpuState, BackendEnum;
    import nijilive.core.render.backends.queue : RenderingBackend;
    alias RenderBackend = RenderingBackend!(BackendEnum.OpenGL);
} else {
    import nijilive.core.render.backends : RenderBackend, RenderGpuState;
}

interface RenderCommandEmitter {
    void beginFrame(RenderBackend backend, ref RenderGpuState state);
    void drawPart(Part part, bool isMask);
    void beginDynamicComposite(Projectable composite, DynamicCompositePass passData);
    void endDynamicComposite(Projectable composite, DynamicCompositePass passData);
    void beginMask(bool useStencil);
    void applyMask(Drawable drawable, bool isDodge);
    void beginMaskContent();
    void endMask();
    void endFrame(RenderBackend backend, ref RenderGpuState state);
}
