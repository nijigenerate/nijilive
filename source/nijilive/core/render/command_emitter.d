module nijilive.core.render.command_emitter;

import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.mask : Mask;
import nijilive.core.nodes.drawable : Drawable;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
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
    void drawMask(Mask mask);
    void beginDynamicComposite(DynamicComposite composite, DynamicCompositePass passData);
    void endDynamicComposite(DynamicComposite composite, DynamicCompositePass passData);
    void beginMask(bool useStencil);
    void applyMask(Drawable drawable, bool isDodge);
    void beginMaskContent();
    void endMask();
    void beginComposite(Composite composite);
    void drawCompositeQuad(Composite composite);
    void endComposite(Composite composite);
    void endFrame(RenderBackend backend, ref RenderGpuState state);
}
