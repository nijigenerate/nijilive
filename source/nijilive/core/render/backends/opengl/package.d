module nijilive.core.render.backends.opengl;

import nijilive.core.render.backends;
import nijilive.core.render.commands : PartDrawPacket, CompositeDrawPacket, MaskApplyPacket;
import nijilive.core.nodes : Node;
import nijilive.core.nodes.part : Part;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.drawable : inBeginMask, inBeginMaskContent, inEndMask;
import nijilive.core : inBeginComposite, inEndComposite;
import nijilive.core.render.backends.opengl.part : glDrawPartPacket;
import nijilive.core.render.backends.opengl.composite : compositeDrawQuad;
import nijilive.core.render.backends.opengl.mask : executeMaskApplyPacket;

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
        composite.drawOne();
    }

    override void beginMask(bool useStencil) {
        inBeginMask(useStencil);
    }

    override void applyMask(ref MaskApplyPacket packet) {
        executeMaskApplyPacket(packet);
    }

    override void beginMaskContent() {
        inBeginMaskContent();
    }

    override void endMask() {
        inEndMask();
    }
    override void beginComposite() {
        inBeginComposite();
    }

    override void drawCompositeQuad(ref CompositeDrawPacket packet) {
        compositeDrawQuad(packet);
    }

    override void endComposite() {
        inEndComposite();
    }
}
