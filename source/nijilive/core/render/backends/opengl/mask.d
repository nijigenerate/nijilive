module nijilive.core.render.backends.opengl.mask;

import nijilive.core.render.commands : MaskApplyPacket, MaskDrawPacket, MaskDrawableKind;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.render.backends.opengl.part : oglExecutePartPacket;
import nijilive.core.shader : Shader;

private __gshared Shader maskShader;
private __gshared GLint maskOffsetUniform;
private __gshared GLint maskMvpUniform;
private __gshared bool maskBackendInitialized = false;

private void ensureMaskBackendInitialized() {
    if (maskBackendInitialized) return;
    maskBackendInitialized = true;

    maskShader = new Shader(import("mask.vert"), import("mask.frag"));
    maskOffsetUniform = maskShader.getUniformLocation("offset");
    maskMvpUniform = maskShader.getUniformLocation("mvp");
}

void oglInitMaskBackend() {
    ensureMaskBackendInitialized();
}

void oglBeginMask(bool hasMasks) {
    glEnable(GL_STENCIL_TEST);
    glClearStencil(hasMasks ? 0 : 1);
    glClear(GL_STENCIL_BUFFER_BIT);
}

void oglEndMask() {
    glStencilMask(0xFF);
    glStencilFunc(GL_ALWAYS, 1, 0xFF);
    glDisable(GL_STENCIL_TEST);
}

void oglBeginMaskContent() {
    glStencilFunc(GL_EQUAL, 1, 0xFF);
    glStencilMask(0x00);
}

void oglExecuteMaskPacket(ref MaskDrawPacket packet) {
    ensureMaskBackendInitialized();
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

void oglExecuteMaskApplyPacket(ref MaskApplyPacket packet) {
    ensureMaskBackendInitialized();
    glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);
    glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
    glStencilFunc(GL_ALWAYS, packet.isDodge ? 0 : 1, 0xFF);
    glStencilMask(0xFF);

    final switch (packet.kind) {
        case MaskDrawableKind.Part:
            oglExecutePartPacket(packet.partPacket);
            break;
        case MaskDrawableKind.Mask:
            oglExecuteMaskPacket(packet.maskPacket);
            break;
    }

    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
}

} else {

import nijilive.core.render.commands : MaskApplyPacket, MaskDrawPacket;

void oglBeginMask(bool) {}
void oglEndMask() {}
void oglBeginMaskContent() {}
void oglExecuteMaskPacket(ref MaskDrawPacket) {}
void oglExecuteMaskApplyPacket(ref MaskApplyPacket) {}
void oglInitMaskBackend() {}

}
