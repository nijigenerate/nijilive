module nijilive.core.render.backends.opengl.part;

import nijilive.core.nodes.part;
import nijilive.core.nodes.drawable : inBeginMask, inBeginMaskContent, inEndMask;

void glDrawPart(Part part) {
    if (part is null || !part.enabled || part.data.isNull) return;

    size_t cMasks = part.maskCount;

    if (part.masks.length > 0) {
        inBeginMask(cMasks > 0);

        foreach (ref mask; part.masks) {
            mask.maskSrc.renderMask(mask.mode == MaskingMode.DodgeMask);
        }

        inBeginMaskContent();
        part.drawSelf();
        inEndMask();
    } else {
        part.drawSelf();
    }
}
