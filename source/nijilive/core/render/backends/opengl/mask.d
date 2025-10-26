module nijilive.core.render.backends.opengl.mask;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.render.backends.opengl.mask_resources : maskShader, maskOffsetUniform,
    maskMvpUniform, initMaskBackendResources;
import nijilive.core.render.backends.opengl.part : executePartPacket;
import nijilive.core.render.commands : MaskDrawPacket, MaskApplyPacket, MaskDrawableKind;

static this() {
    initMaskBackendResources();
}

void executeMaskPacket(ref MaskDrawPacket packet) {
    if (packet.indexCount == 0) return;

    incDrawableBindVAO();

    maskShader.use();
    maskShader.setUniform(maskOffsetUniform, packet.origin);
    maskShader.setUniform(maskMvpUniform, packet.mvp);

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, packet.vertexBuffer);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, packet.deformBuffer);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, packet.indexBuffer);
    glDrawElements(GL_TRIANGLES, cast(int)packet.indexCount, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
}

void executeMaskApplyPacket(ref MaskApplyPacket packet) {
    glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
    glStencilFunc(GL_ALWAYS, packet.isDodge ? 0 : 1, 0xFF);
    glStencilMask(0xFF);

    final switch (packet.kind) {
        case MaskDrawableKind.Part:
            executePartPacket(packet.partPacket);
            break;
        case MaskDrawableKind.Mask:
            executeMaskPacket(packet.maskPacket);
            break;
    }

    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
}
