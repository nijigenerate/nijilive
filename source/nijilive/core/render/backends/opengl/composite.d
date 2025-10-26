module nijilive.core.render.backends.opengl.composite;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.nodes.composite : Composite;
import nijilive.core.nodes.common : inSetBlendMode;
import nijilive.core : incCompositePrepareRender;
import nijilive.core.render.commands : CompositeDrawPacket;
import nijilive.core.render.backends.opengl.composite_resources : initCompositeBackendResources,
    getCompositeVAO, getCompositeBuffer, getCompositeShader, getCompositeOpacityUniform,
    getCompositeMultColorUniform, getCompositeScreenColorUniform;

void compositeDrawQuad(ref CompositeDrawPacket packet) {
    auto comp = packet.composite;
    if (comp is null) return;

    initCompositeBackendResources();

    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glBindVertexArray(getCompositeVAO());

    auto shader = getCompositeShader();
    shader.use();
    shader.setUniform(getCompositeOpacityUniform(), packet.opacity);
    incCompositePrepareRender();
    shader.setUniform(getCompositeMultColorUniform(), packet.tint);
    shader.setUniform(getCompositeScreenColorUniform(), packet.screenTint);
    inSetBlendMode(comp.blendingMode, true);

    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, getCompositeBuffer());
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, cast(void*)(12*float.sizeof));

    glDrawArrays(GL_TRIANGLES, 0, 6);
}
