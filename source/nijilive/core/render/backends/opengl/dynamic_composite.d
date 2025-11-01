module nijilive.core.render.backends.opengl.dynamic_composite;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.nodes.composite.dcomposite : DynamicComposite;
import nijilive.core : inPushViewport, inPopViewport;

void beginDynamicCompositeGL(DynamicComposite composite) {
    if (composite is null) return;
    auto tex = composite.textures[0];
    if (tex is null) return;

    if (composite.cfBuffer == 0) {
        glGenFramebuffers(1, &composite.cfBuffer);
    }

    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &composite.origBuffer);
    glGetIntegerv(GL_VIEWPORT, composite.origViewport.ptr);

    glBindFramebuffer(GL_FRAMEBUFFER, composite.cfBuffer);

    GLuint[3] drawBuffers;
    size_t bufferCount;

    void attachColor(size_t index, GLenum attachment) {
        auto texture = index < composite.textures.length ? composite.textures[index] : null;
        if (texture !is null) {
            glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, texture.getTextureId(), 0);
            drawBuffers[bufferCount++] = attachment;
        } else {
            glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, 0, 0);
        }
    }

    attachColor(0, GL_COLOR_ATTACHMENT0);
    attachColor(1, GL_COLOR_ATTACHMENT1);
    attachColor(2, GL_COLOR_ATTACHMENT2);

    if (bufferCount == 0) {
        drawBuffers[bufferCount++] = GL_COLOR_ATTACHMENT0;
    }

    if (composite.stencil !is null) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, composite.stencil.getTextureId(), 0);
        glClear(GL_STENCIL_BUFFER_BIT);
    } else {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, 0, 0);
    }

    inPushViewport(tex.width, tex.height);

    glDrawBuffers(cast(int)bufferCount, drawBuffers.ptr);
    glViewport(0, 0, tex.width, tex.height);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

void endDynamicCompositeGL(DynamicComposite composite) {
    if (composite is null) return;

    glBindFramebuffer(GL_FRAMEBUFFER, composite.origBuffer);
    inPopViewport();
    glViewport(composite.origViewport[0], composite.origViewport[1],
        composite.origViewport[2], composite.origViewport[3]);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glFlush();

    auto tex = composite.textures[0];
    if (tex !is null) {
        tex.genMipmap();
    }
}
