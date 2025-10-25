module nijilive.core.render.commands;

import nijilive.core.nodes;
import nijilive.core.nodes.part;
import nijilive.core.nodes.composite;

interface RenderBackend {
    void drawNode(Node node);
    void drawPartRaw(Part part);
    void drawCompositeRaw(Composite composite);
    void drawCompositeMask(Composite composite, Part[] masks);
}

abstract class RenderCommand {
    abstract void execute(RenderBackend backend);
}

final class DrawNodeCommand : RenderCommand {
    Node node;
    this(Node node) {
        this.node = node;
    }
    override void execute(RenderBackend backend) {
        if (node is null || backend is null) return;
        backend.drawNode(node);
    }
}

final class DrawPartCommand : RenderCommand {
    Part part;
    this(Part part) {
        this.part = part;
    }
    override void execute(RenderBackend backend) {
        if (part is null || backend is null) return;
        backend.drawPartRaw(part);
    }
}

final class DrawCompositeCommand : RenderCommand {
    Composite composite;
    this(Composite composite) {
        this.composite = composite;
    }
    override void execute(RenderBackend backend) {
        if (composite is null || backend is null) return;
        backend.drawCompositeRaw(composite);
    }
}

final class DrawCompositeMaskCommand : RenderCommand {
    Composite composite;
    Part[] masks;
    this(Composite composite, Part[] masks) {
        this.composite = composite;
        this.masks = masks;
    }
    override void execute(RenderBackend backend) {
        if (composite is null || backend is null) return;
        backend.drawCompositeMask(composite, masks);
    }
}
