module nijilive.core.render.backends.opengl.part;

import bindbc.opengl;
import nijilive.core.nodes.part : Part;
static import partmodule = nijilive.core.nodes.part;
import nijilive.core.nodes.common : inUseMultistageBlending, nlIsTripleBufferFallbackEnabled;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.render.commands : PartDrawPacket;
import nijilive.core;
import nijilive.math : mat4;

void glDrawPartPacket(ref PartDrawPacket packet) {
    auto part = packet.part;
    if (part is null || !part.backendRenderable()) return;
    executePartPacket(packet);
}

void executePartPacket(ref PartDrawPacket packet) {
    auto part = packet.part;
    if (part is null) return;

    auto textures = packet.textures.length ? packet.textures : part.textures;
    if (textures.length == 0) return;

    incDrawableBindVAO();

    if (partmodule.boundAlbedo != textures[0]) {
        foreach(i, ref texture; textures) {
            if (texture) texture.bind(cast(uint)i);
            else {
                glActiveTexture(GL_TEXTURE0 + cast(uint)i);
                glBindTexture(GL_TEXTURE_2D, 0);
            }
        }
        partmodule.boundAlbedo = textures[0];
    }

    auto matrix = packet.modelMatrix;

    if (packet.isMask) {
        partmodule.partMaskShader.use();
        partmodule.partMaskShader.setUniform(partmodule.offset, packet.origin);
        partmodule.partMaskShader.setUniform(partmodule.mmvp, packet.mvp);
        partmodule.partMaskShader.setUniform(partmodule.mthreshold, packet.maskThreshold);

        glBlendEquation(GL_FUNC_ADD);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        renderStage(packet, false);
    } else {
        if (packet.useMultistageBlend) {
            setupShaderStage(packet, 0, matrix);
            renderStage(packet, true);

            if (packet.hasEmissionOrBumpmap) {
                setupShaderStage(packet, 1, matrix);
                renderStage(packet, false);
            }
        } else {
            if (nlIsTripleBufferFallbackEnabled()) {
                auto blendShader = inGetBlendShader(packet.blendingMode);
                if (blendShader) {
                    GLint previous_draw_fbo;
                    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previous_draw_fbo);
                    GLint previous_read_fbo;
                    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previous_read_fbo);
                    GLfloat[4] previous_clear_color;
                    glGetFloatv(GL_COLOR_CLEAR_VALUE, previous_clear_color.ptr);

                    bool drawingMainBuffer = previous_draw_fbo == inGetFramebuffer();
                    bool drawingCompositeBuffer = previous_draw_fbo == inGetCompositeFramebuffer();

                    if (!drawingMainBuffer && !drawingCompositeBuffer) {
                        setupShaderStage(packet, 2, matrix);
                        renderStage(packet, false);
                        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, previous_draw_fbo);
                        glBindFramebuffer(GL_READ_FRAMEBUFFER, previous_read_fbo);
                        glClearColor(previous_clear_color[0], previous_clear_color[1], previous_clear_color[2], previous_clear_color[3]);
                        return;
                    }

                    int viewportWidth, viewportHeight;
                    inGetViewport(viewportWidth, viewportHeight);
                    GLint[4] previousViewport;
                    glGetIntegerv(GL_VIEWPORT, previousViewport.ptr);

                    GLuint blendFramebuffer = inGetBlendFramebuffer();
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                    glViewport(0, 0, viewportWidth, viewportHeight);
                    glClearColor(0f, 0f, 0f, 0f);
                    glClear(GL_COLOR_BUFFER_BIT);
                    setupShaderStage(packet, 2, matrix);
                    renderStage(packet, false);

                    GLuint bgAlbedo = drawingMainBuffer ? inGetMainAlbedo() : inGetCompositeImage();
                    GLuint bgEmissive = drawingMainBuffer ? inGetMainEmissive() : inGetCompositeEmissive();
                    GLuint bgBump = drawingMainBuffer ? inGetMainBump() : inGetCompositeBump();

                    GLuint fgAlbedo = inGetBlendAlbedo();
                    GLuint fgEmissive = inGetBlendEmissive();
                    GLuint fgBump = inGetBlendBump();

                    GLuint destinationFBO = drawingMainBuffer ? inGetCompositeFramebuffer() : inGetFramebuffer();
                    inBlendToBuffer(
                        blendShader,
                        packet.blendingMode,
                        destinationFBO,
                        bgAlbedo, bgEmissive, bgBump,
                        fgAlbedo, fgEmissive, fgBump
                    );

                    inSwapMainCompositeBuffers();

                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawingMainBuffer ? inGetFramebuffer() : inGetCompositeFramebuffer());
                    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, previous_read_fbo);
                    glViewport(previousViewport[0], previousViewport[1], previousViewport[2], previousViewport[3]);
                    glClearColor(previous_clear_color[0], previous_clear_color[1], previous_clear_color[2], previous_clear_color[3]);
                    return;
                }
            }

            setupShaderStage(packet, 2, matrix);
            renderStage(packet, false);
        }
    }

    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glBlendEquation(GL_FUNC_ADD);
}

private void setupShaderStage(ref PartDrawPacket packet, int stage, mat4 matrix) {
    auto part = packet.part;
    auto puppetMatrix = (part !is null && part.ignorePuppet) ? mat4.identity : (part ? part.puppet.transform.matrix : mat4.identity);
    mat4 mvpMatrix = inGetCamera().matrix * puppetMatrix * matrix;

    switch (stage) {
        case 0:
            glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);

            partmodule.partShaderStage1.use();
            partmodule.partShaderStage1.setUniform(partmodule.gs1offset, packet.origin);
            partmodule.partShaderStage1.setUniform(partmodule.gs1mvp, mvpMatrix);
            partmodule.partShaderStage1.setUniform(partmodule.gs1opacity, packet.opacity);
            partmodule.partShaderStage1.setUniform(partmodule.gs1MultColor, packet.clampedTint);
            partmodule.partShaderStage1.setUniform(partmodule.gs1ScreenColor, packet.clampedScreen);
            inSetBlendMode(packet.blendingMode, false);
            break;
        case 1:
            glDrawBuffers(2, [GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

            partmodule.partShaderStage2.use();
            partmodule.partShaderStage2.setUniform(partmodule.gs2offset, packet.origin);
            partmodule.partShaderStage2.setUniform(partmodule.gs2mvp, mvpMatrix);
            partmodule.partShaderStage2.setUniform(partmodule.gs2opacity, packet.opacity);
            partmodule.partShaderStage2.setUniform(partmodule.gs2EmissionStrength, packet.emissionStrength);
            partmodule.partShaderStage2.setUniform(partmodule.gs2MultColor, packet.clampedTint);
            partmodule.partShaderStage2.setUniform(partmodule.gs2ScreenColor, packet.clampedScreen);
            inSetBlendMode(packet.blendingMode, true);
            break;
        case 2:
            glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

            partmodule.partShader.use();
            partmodule.partShader.setUniform(partmodule.offset, packet.origin);
            partmodule.partShader.setUniform(partmodule.mvp, mvpMatrix);
            partmodule.partShader.setUniform(partmodule.gopacity, packet.opacity);
            partmodule.partShader.setUniform(partmodule.gEmissionStrength, packet.emissionStrength);
            partmodule.partShader.setUniform(partmodule.gMultColor, packet.clampedTint);
            partmodule.partShader.setUniform(partmodule.gScreenColor, packet.clampedScreen);
            inSetBlendMode(packet.blendingMode, true);
            break;
        default:
            return;
    }
}

private void renderStage(ref PartDrawPacket packet, bool advanced) {
    auto vbo = packet.vertexBuffer;
    auto uvbo = packet.uvBuffer;
    auto dbo = packet.deformBuffer;
    auto ibo = packet.indexBuffer;
    auto indexCount = packet.indexCount;

    if (!vbo || !uvbo || !dbo || !ibo || indexCount == 0) return;

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, uvbo);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

    glEnableVertexAttribArray(2);
    glBindBuffer(GL_ARRAY_BUFFER, dbo);
    glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 0, null);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);

    if (advanced) {
        inBlendModeBarrier(packet.blendingMode);
    }
}
