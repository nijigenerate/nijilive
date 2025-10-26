module nijilive.core.render.backends.opengl.mask_state;

version (InDoesRender):

import bindbc.opengl;

void beginMaskGL(bool hasMasks) {
    glEnable(GL_STENCIL_TEST);
    glClearStencil(hasMasks ? 0 : 1);
    glClear(GL_STENCIL_BUFFER_BIT);
}

void endMaskGL() {
    glStencilMask(0xFF);
    glStencilFunc(GL_ALWAYS, 1, 0xFF);
    glDisable(GL_STENCIL_TEST);
}

void beginMaskContentGL() {
    glStencilFunc(GL_EQUAL, 1, 0xFF);
    glStencilMask(0x00);
}
