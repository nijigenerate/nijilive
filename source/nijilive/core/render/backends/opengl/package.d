module nijilive.core.render.backends.opengl;

import nijilive.core.render.backends;
import nijilive.core.render.commands : PartDrawPacket;
import nijilive.core.nodes : Node;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.drawable : Drawable, inBeginMask, inBeginMaskContent, inEndMask;
import nijilive.core.render.backends.opengl.part : glDrawPartPacket;

class GLRenderBackend : RenderBackend {
    override void drawNode(Node node) {
        if (node is null) return;
        node.drawOne();
    }

    override void drawPartPacket(ref PartDrawPacket packet) {
        glDrawPartPacket(packet);
    }

    override void drawCompositeRaw(Composite composite) {
        if (composite is null) return;
        composite.drawOneImmediate();
    }

    override void drawCompositeMask(Composite composite, Part[] masks) {
        if (composite is null) return;
        composite.renderMaskImmediate(masks);
    }

    override void beginMask(bool useStencil) {
        inBeginMask(useStencil);
    }

    override void applyMask(Drawable drawable, bool isDodge) {
        if (drawable is null) return;
        drawable.renderMask(isDodge);
    }

    override void beginMaskContent() {
        inBeginMaskContent();
    }

    override void endMask() {
        inEndMask();
    }
}
