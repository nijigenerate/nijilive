module nijilive.core.render.backends.opengl.part;

version (InDoesRender) {

import bindbc.opengl;
import std.algorithm : min;
import nijilive.core.nodes.common : inUseMultistageBlending, nlIsTripleBufferFallbackEnabled,
    inSetBlendMode, inBlendModeBarrier;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.render.commands : PartDrawPacket;
import nijilive.core.runtime_state : inGetViewport;
import nijilive.core.render.backends.opengl.runtime :
    oglGetFramebuffer,
    oglGetCompositeFramebuffer,
    oglGetBlendFramebuffer,
    oglGetMainAlbedo,
    oglGetCompositeImage,
    oglGetMainEmissive,
    oglGetCompositeEmissive,
    oglGetMainBump,
    oglGetCompositeBump,
    oglGetBlendAlbedo,
    oglGetBlendEmissive,
    oglGetBlendBump,
    oglSwapMainCompositeBuffers,
    oglGetActiveDrawBufferCount,
    oglSetActiveDrawBuffers,
    oglApplyActiveDrawBuffers,
    oglIsMaskContentActive;
import nijilive.core.render.backends.opengl.blend : oglGetBlendShader, oglBlendToBuffer;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader, shaderAsset, ShaderAsset;
import nijilive.math : mat4;
import nijilive.core.render.backends.opengl.drawable_buffers :
    oglGetSharedDeformBuffer,
    oglGetSharedVertexBuffer,
    oglGetSharedUvBuffer;
import nijilive.core.render.backends.opengl.buffer_sync : markBufferInUse;

package(nijilive) {
    __gshared Texture boundAlbedo;
    __gshared Shader partShader;
    __gshared Shader partShaderStage1;
    __gshared Shader partShaderStage2;
    __gshared Shader partMaskShader;
    __gshared GLint mvp;
    __gshared GLint offset;
    __gshared GLint gopacity;
    __gshared GLint gMultColor;
    __gshared GLint gScreenColor;
    __gshared GLint gEmissionStrength;
    __gshared GLint gs1mvp;
    __gshared GLint gs1offset;
    __gshared GLint gs1opacity;
    __gshared GLint gs1MultColor;
    __gshared GLint gs1ScreenColor;
    __gshared GLint gs2mvp;
    __gshared GLint gs2offset;
    __gshared GLint gs2opacity;
    __gshared GLint gs2EmissionStrength;
    __gshared GLint gs2MultColor;
    __gshared GLint gs2ScreenColor;
    __gshared GLint mmvp;
    __gshared GLint mthreshold;
    __gshared bool partBackendInitialized = false;

enum ShaderAsset PartShaderSource = shaderAsset!("opengl/basic/basic.vert","opengl/basic/basic.frag")();
enum ShaderAsset PartShaderStage1Source = shaderAsset!("opengl/basic/basic.vert","opengl/basic/basic-stage1.frag")();
enum ShaderAsset PartShaderStage2Source = shaderAsset!("opengl/basic/basic.vert","opengl/basic/basic-stage2.frag")();
enum ShaderAsset PartMaskShaderSource = shaderAsset!("opengl/basic/basic.vert","opengl/basic/basic-mask.frag")();
}

void oglInitPartBackendResources() {
    if (partBackendInitialized) return;
    partBackendInitialized = true;

    partShader = new Shader(PartShaderSource);
    partShaderStage1 = new Shader(PartShaderStage1Source);
    partShaderStage2 = new Shader(PartShaderStage2Source);
    partMaskShader = new Shader(PartMaskShaderSource);

    incDrawableBindVAO();

    partShader.use();
    partShader.setUniform(partShader.getUniformLocation("albedo"), 0);
    partShader.setUniform(partShader.getUniformLocation("emissive"), 1);
    partShader.setUniform(partShader.getUniformLocation("bumpmap"), 2);
    mvp = partShader.getUniformLocation("mvp");
    offset = partShader.getUniformLocation("offset");
    gopacity = partShader.getUniformLocation("opacity");
    gMultColor = partShader.getUniformLocation("multColor");
    gScreenColor = partShader.getUniformLocation("screenColor");
    gEmissionStrength = partShader.getUniformLocation("emissionStrength");

    partShaderStage1.use();
    partShaderStage1.setUniform(partShader.getUniformLocation("albedo"), 0);
    gs1mvp = partShaderStage1.getUniformLocation("mvp");
    gs1offset = partShaderStage1.getUniformLocation("offset");
    gs1opacity = partShaderStage1.getUniformLocation("opacity");
    gs1MultColor = partShaderStage1.getUniformLocation("multColor");
    gs1ScreenColor = partShaderStage1.getUniformLocation("screenColor");

    partShaderStage2.use();
    partShaderStage2.setUniform(partShaderStage2.getUniformLocation("emissive"), 1);
    partShaderStage2.setUniform(partShaderStage2.getUniformLocation("bumpmap"), 2);
    gs2mvp = partShaderStage2.getUniformLocation("mvp");
    gs2offset = partShaderStage2.getUniformLocation("offset");
    gs2opacity = partShaderStage2.getUniformLocation("opacity");
    gs2MultColor = partShaderStage2.getUniformLocation("multColor");
    gs2ScreenColor = partShaderStage2.getUniformLocation("screenColor");
    gs2EmissionStrength = partShaderStage2.getUniformLocation("emissionStrength");

    partMaskShader.use();
    partMaskShader.setUniform(partMaskShader.getUniformLocation("albedo"), 0);
    partMaskShader.setUniform(partMaskShader.getUniformLocation("emissive"), 1);
    partMaskShader.setUniform(partMaskShader.getUniformLocation("bumpmap"), 2);
    mmvp = partMaskShader.getUniformLocation("mvp");
    mthreshold = partMaskShader.getUniformLocation("threshold");

}

void oglDrawPartPacket(ref PartDrawPacket packet) {
    if (!packet.renderable) return;
    oglExecutePartPacket(packet);
}

void oglExecutePartPacket(ref PartDrawPacket packet) {
    auto textures = packet.textures;
    if (textures.length == 0) return;

    incDrawableBindVAO();

    if (!packet.isMask && !oglIsMaskContentActive()) {
        glDisable(GL_STENCIL_TEST);
    }

    if (boundAlbedo != textures[0]) {
        foreach(i, ref texture; textures) {
            if (texture) texture.bind(cast(uint)i);
            else {
                glActiveTexture(GL_TEXTURE0 + cast(uint)i);
                glBindTexture(GL_TEXTURE_2D, 0);
            }
        }
        boundAlbedo = textures[0];
    }

    auto matrix = packet.modelMatrix;
    mat4 renderMatrix = packet.renderMatrix;

    if (packet.isMask) {
        mat4 mvpMatrix = renderMatrix * matrix;

        partMaskShader.use();
        partMaskShader.setUniform(offset, packet.origin);
        partMaskShader.setUniform(mmvp, mvpMatrix);
        partMaskShader.setUniform(mthreshold, packet.maskThreshold);

        glBlendEquation(GL_FUNC_ADD);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        renderStage(packet, false);
    } else {
        if (packet.useMultistageBlend) {
            auto drawCount = oglGetActiveDrawBufferCount();
            setupShaderStage(packet, 0, matrix, renderMatrix, drawCount);
            renderStage(packet, true);

            if (packet.hasEmissionOrBumpmap && drawCount >= 2) {
                setupShaderStage(packet, 1, matrix, renderMatrix, drawCount);
                renderStage(packet, false);
            }
        } else {
            if (nlIsTripleBufferFallbackEnabled()) {
                auto blendShader = oglGetBlendShader(packet.blendingMode);
                if (blendShader) {
                    // Save full GL state that we modify in the fallback path.
                    struct SavedState {
                        GLint drawFbo;
                        GLint readFbo;
                        GLint readBuffer;
                        GLint[4] viewport;
                        GLfloat[4] clearColor;
                        GLint[4] drawBuffers;
                        GLint drawBufferCount;
                        GLint blendSrcRGB;
                        GLint blendDstRGB;
                        GLint blendSrcA;
                        GLint blendDstA;
                        GLint blendEqRGB;
                        GLint blendEqA;
                        GLboolean[4] colorMask;
                        GLboolean depthEnabled;
                        GLboolean stencilEnabled;
                    }
                    SavedState prev;
                    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &prev.drawFbo);
                    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &prev.readFbo);
                    glGetIntegerv(GL_READ_BUFFER, &prev.readBuffer);
                    glGetIntegerv(GL_VIEWPORT, prev.viewport.ptr);
                    GLint maxDrawBuffers = 0;
                    glGetIntegerv(GL_MAX_DRAW_BUFFERS, &maxDrawBuffers);
                    maxDrawBuffers = min(maxDrawBuffers, cast(int)prev.drawBuffers.length);
                    int bufCount = 0;
                    for (int i = 0; i < maxDrawBuffers; ++i) {
                        GLint buf = 0;
                        glGetIntegerv(GL_DRAW_BUFFER0 + i, &buf);
                        prev.drawBuffers[i] = buf;
                        if (buf != GL_NONE) bufCount = i + 1;
                    }
                    if (bufCount == 0) {
                        prev.drawBufferCount = 3;
                        prev.drawBuffers[0] = GL_COLOR_ATTACHMENT0;
                        prev.drawBuffers[1] = GL_COLOR_ATTACHMENT1;
                        prev.drawBuffers[2] = GL_COLOR_ATTACHMENT2;
                    } else {
                        prev.drawBufferCount = bufCount;
                    }
                    glGetFloatv(GL_COLOR_CLEAR_VALUE, prev.clearColor.ptr);
                    glGetIntegerv(GL_BLEND_SRC_RGB, &prev.blendSrcRGB);
                    glGetIntegerv(GL_BLEND_DST_RGB, &prev.blendDstRGB);
                    glGetIntegerv(GL_BLEND_SRC_ALPHA, &prev.blendSrcA);
                    glGetIntegerv(GL_BLEND_DST_ALPHA, &prev.blendDstA);
                    glGetIntegerv(GL_BLEND_EQUATION_RGB, &prev.blendEqRGB);
                    glGetIntegerv(GL_BLEND_EQUATION_ALPHA, &prev.blendEqA);
                    glGetBooleanv(GL_COLOR_WRITEMASK, prev.colorMask.ptr);
                    prev.depthEnabled = glIsEnabled(GL_DEPTH_TEST);
                    prev.stencilEnabled = glIsEnabled(GL_STENCIL_TEST);

                    bool drawingMainBuffer = prev.drawFbo == oglGetFramebuffer();
                    bool drawingCompositeBuffer = prev.drawFbo == oglGetCompositeFramebuffer();

                    if (!drawingMainBuffer && !drawingCompositeBuffer) {
                        auto drawCount = oglGetActiveDrawBufferCount();
                        setupShaderStage(packet, 2, matrix, renderMatrix, drawCount);
                        renderStage(packet, false);
                        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                        glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.readFbo);
                        glReadBuffer(prev.readBuffer);
                        GLenum[4] restoredBuffers;
                        foreach (i; 0 .. prev.drawBufferCount) {
                            restoredBuffers[i] = cast(GLenum)prev.drawBuffers[i];
                        }
                        oglSetActiveDrawBuffers(restoredBuffers[0 .. prev.drawBufferCount]);
                        glViewport(prev.viewport[0], prev.viewport[1], prev.viewport[2], prev.viewport[3]);
                        glClearColor(prev.clearColor[0], prev.clearColor[1], prev.clearColor[2], prev.clearColor[3]);
                        glBlendEquationSeparate(prev.blendEqRGB, prev.blendEqA);
                        glBlendFuncSeparate(prev.blendSrcRGB, prev.blendDstRGB, prev.blendSrcA, prev.blendDstA);
                        glColorMask(prev.colorMask[0], prev.colorMask[1], prev.colorMask[2], prev.colorMask[3]);
                        if (prev.depthEnabled) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
                        if (prev.stencilEnabled) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
                        return;
                    }

                    int viewportWidth, viewportHeight;
                    inGetViewport(viewportWidth, viewportHeight);

                    GLuint blendFramebuffer = oglGetBlendFramebuffer();
                    // Copy current target into blend buffer as a backup.
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.drawFbo);
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                    foreach(att; 0 .. 3) {
                        GLenum buf = GL_COLOR_ATTACHMENT0 + att;
                        glReadBuffer(buf);
                        glDrawBuffer(buf);
                        glBlitFramebuffer(0, 0, viewportWidth, viewportHeight,
                            0, 0, viewportWidth, viewportHeight,
                            GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    }

                    // Draw the part into the blend buffer.
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                    oglApplyActiveDrawBuffers();
                    glViewport(0, 0, viewportWidth, viewportHeight);
                    auto drawCount = oglGetActiveDrawBufferCount();
                    setupShaderStage(packet, 2, matrix, renderMatrix, drawCount);
                    renderStage(packet, false);

                    // Copy result back to original target.
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, blendFramebuffer);
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                    foreach(att; 0 .. 3) {
                        GLenum buf = GL_COLOR_ATTACHMENT0 + att;
                        glReadBuffer(buf);
                        glDrawBuffer(buf);
                        glBlitFramebuffer(0, 0, viewportWidth, viewportHeight,
                            0, 0, viewportWidth, viewportHeight,
                            GL_COLOR_BUFFER_BIT, GL_NEAREST);
                    }

                    // Restore original state after blending.
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, prev.drawFbo);
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, prev.readFbo);
                    glReadBuffer(prev.readBuffer);
                    GLenum[4] restoredBuffers;
                    foreach (i; 0 .. prev.drawBufferCount) {
                        restoredBuffers[i] = cast(GLenum)prev.drawBuffers[i];
                    }
                    oglSetActiveDrawBuffers(restoredBuffers[0 .. prev.drawBufferCount]);
                    glViewport(prev.viewport[0], prev.viewport[1], prev.viewport[2], prev.viewport[3]);
                    glClearColor(prev.clearColor[0], prev.clearColor[1], prev.clearColor[2], prev.clearColor[3]);
                    glBlendEquationSeparate(prev.blendEqRGB, prev.blendEqA);
                    glBlendFuncSeparate(prev.blendSrcRGB, prev.blendDstRGB, prev.blendSrcA, prev.blendDstA);
                    glColorMask(prev.colorMask[0], prev.colorMask[1], prev.colorMask[2], prev.colorMask[3]);
                    if (prev.depthEnabled) glEnable(GL_DEPTH_TEST); else glDisable(GL_DEPTH_TEST);
                    if (prev.stencilEnabled) glEnable(GL_STENCIL_TEST); else glDisable(GL_STENCIL_TEST);
                    boundAlbedo = null; // force texture rebind after fallback path
                    return;
                }
            }

            auto drawCount = oglGetActiveDrawBufferCount();
            setupShaderStage(packet, 2, matrix, renderMatrix, drawCount);
            renderStage(packet, false);
        }
    }

    oglApplyActiveDrawBuffers();
    glBlendEquation(GL_FUNC_ADD);
}

private void setupShaderStage(ref PartDrawPacket packet, int stage, mat4 matrix, mat4 renderMatrix, int drawCount) {
    mat4 mvpMatrix = renderMatrix * matrix;

    switch (stage) {
        case 0:
            glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);

            partShaderStage1.use();
            partShaderStage1.setUniform(gs1offset, packet.origin);
            partShaderStage1.setUniform(gs1mvp, mvpMatrix);
            partShaderStage1.setUniform(gs1opacity, packet.opacity);
            partShaderStage1.setUniform(gs1MultColor, packet.clampedTint);
            partShaderStage1.setUniform(gs1ScreenColor, packet.clampedScreen);
            inSetBlendMode(packet.blendingMode, false);
            break;
        case 1:
            if (drawCount >= 2) {
                glDrawBuffers(2, [GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
            } else {
                return;
            }

            partShaderStage2.use();
            partShaderStage2.setUniform(gs2offset, packet.origin);
            partShaderStage2.setUniform(gs2mvp, mvpMatrix);
            partShaderStage2.setUniform(gs2opacity, packet.opacity);
            partShaderStage2.setUniform(gs2EmissionStrength, packet.emissionStrength);
            partShaderStage2.setUniform(gs2MultColor, packet.clampedTint);
            partShaderStage2.setUniform(gs2ScreenColor, packet.clampedScreen);
            inSetBlendMode(packet.blendingMode, true);
            break;
        case 2:
            if (drawCount >= 3) {
                glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
            } else {
                glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);
            }

            partShader.use();
            partShader.setUniform(offset, packet.origin);
            partShader.setUniform(mvp, mvpMatrix);
            partShader.setUniform(gopacity, packet.opacity);
            partShader.setUniform(gEmissionStrength, packet.emissionStrength);
            partShader.setUniform(gMultColor, packet.clampedTint);
            partShader.setUniform(gScreenColor, packet.clampedScreen);
            inSetBlendMode(packet.blendingMode, true);
            break;
        default:
            return;
    }
}

private void renderStage(ref PartDrawPacket packet, bool advanced) {
    auto ibo = cast(GLuint)packet.indexBuffer;
    auto indexCount = packet.indexCount;

    if (!ibo || indexCount == 0 || packet.vertexCount == 0) return;
    if (packet.vertexAtlasStride == 0 || packet.uvAtlasStride == 0 || packet.deformAtlasStride == 0) return;

    auto vertexBuffer = oglGetSharedVertexBuffer();
    auto uvBuffer = oglGetSharedUvBuffer();
    auto deformBuffer = oglGetSharedDeformBuffer();
    if (vertexBuffer == 0 || uvBuffer == 0 || deformBuffer == 0) return;

    auto vertexOffsetBytes = cast(ptrdiff_t)packet.vertexOffset * float.sizeof;
    auto uvOffsetBytes = cast(ptrdiff_t)packet.uvOffset * float.sizeof;
    auto deformOffsetBytes = cast(ptrdiff_t)packet.deformOffset * float.sizeof;

    auto vertexStrideBytes = cast(ptrdiff_t)packet.vertexAtlasStride * float.sizeof;
    auto uvStrideBytes = cast(ptrdiff_t)packet.uvAtlasStride * float.sizeof;
    auto deformStrideBytes = cast(ptrdiff_t)packet.deformAtlasStride * float.sizeof;

    auto vertexLane1Offset = vertexStrideBytes + vertexOffsetBytes;
    auto uvLane1Offset = uvStrideBytes + uvOffsetBytes;
    auto deformLane1Offset = deformStrideBytes + deformOffsetBytes;

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexOffsetBytes);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)vertexLane1Offset);

    glEnableVertexAttribArray(2);
    glBindBuffer(GL_ARRAY_BUFFER, uvBuffer);
    glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)uvOffsetBytes);

    glEnableVertexAttribArray(3);
    glBindBuffer(GL_ARRAY_BUFFER, uvBuffer);
    glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)uvLane1Offset);

    glEnableVertexAttribArray(4);
    glBindBuffer(GL_ARRAY_BUFFER, deformBuffer);
    glVertexAttribPointer(4, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformOffsetBytes);

    glEnableVertexAttribArray(5);
    glBindBuffer(GL_ARRAY_BUFFER, deformBuffer);
    glVertexAttribPointer(5, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)deformLane1Offset);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glDrawElements(GL_TRIANGLES, cast(int)indexCount, GL_UNSIGNED_SHORT, null);
    markBufferInUse(vertexBuffer);
    markBufferInUse(uvBuffer);
    markBufferInUse(deformBuffer);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
    glDisableVertexAttribArray(4);
    glDisableVertexAttribArray(5);

    if (advanced) {
        inBlendModeBarrier(packet.blendingMode);
    }
}

} else {

import nijilive.core.render.commands : PartDrawPacket;

void oglInitPartBackendResources() {}
void oglDrawPartPacket(ref PartDrawPacket) {}
void oglExecutePartPacket(ref PartDrawPacket) {}

}
