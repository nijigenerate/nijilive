module nijilive.core.render.backends.opengl;

import nijilive.core.render.commands;
import nijilive.core.nodes : Node;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.render.backends.opengl.part : glDrawPart;

class GLRenderBackend : RenderBackend {
    override void drawNode(Node node) {
        if (node is null) return;
        node.drawOne();
    }

    override void drawPartRaw(Part part) {
        glDrawPart(part);
    }

    override void drawCompositeRaw(Composite composite) {
        if (composite is null) return;
        composite.drawOneImmediate();
    }

    override void drawCompositeMask(Composite composite, Part[] masks) {
        if (composite is null) return;
        composite.renderMaskImmediate(masks);
    }
}
