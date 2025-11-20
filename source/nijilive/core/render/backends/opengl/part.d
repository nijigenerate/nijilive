module nijilive.core.render.backends.opengl.part;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.core.nodes.common : inUseMultistageBlending, nlIsTripleBufferFallbackEnabled,
    inSetBlendMode, inBlendModeBarrier;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.render.commands : PartDrawPacket;
import nijilive.core.runtime_state : inGetCamera, inGetViewport;
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
    oglSwapMainCompositeBuffers;
import nijilive.core.render.backends.opengl.blend : oglGetBlendShader, oglBlendToBuffer;
import nijilive.core.texture : Texture;
import nijilive.core.shader : Shader;
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
}

void oglInitPartBackendResources() {
    if (partBackendInitialized) return;
    partBackendInitialized = true;

    partShader = new Shader(import("basic/basic.vert"), import("basic/basic.frag"));
    partShaderStage1 = new Shader(import("basic/basic.vert"), import("basic/basic-stage1.frag"));
    partShaderStage2 = new Shader(import("basic/basic.vert"), import("basic/basic-stage2.frag"));
    partMaskShader = new Shader(import("basic/basic.vert"), import("basic/basic-mask.frag"));

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
    mat4 puppetMatrix = packet.puppetMatrix;
    mat4 cameraMatrix = inGetCamera().matrix;

    if (packet.isMask) {
        mat4 mvpMatrix = cameraMatrix * puppetMatrix * matrix;

        partMaskShader.use();
        partMaskShader.setUniform(offset, packet.origin);
        partMaskShader.setUniform(mmvp, mvpMatrix);
        partMaskShader.setUniform(mthreshold, packet.maskThreshold);

        glBlendEquation(GL_FUNC_ADD);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        renderStage(packet, false);
    } else {
        if (packet.useMultistageBlend) {
            setupShaderStage(packet, 0, matrix, cameraMatrix, puppetMatrix);
            renderStage(packet, true);

            if (packet.hasEmissionOrBumpmap) {
                setupShaderStage(packet, 1, matrix, cameraMatrix, puppetMatrix);
                renderStage(packet, false);
            }
        } else {
            if (nlIsTripleBufferFallbackEnabled()) {
                auto blendShader = oglGetBlendShader(packet.blendingMode);
                if (blendShader) {
                    GLint previous_draw_fbo;
                    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previous_draw_fbo);
                    GLint previous_read_fbo;
                    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &previous_read_fbo);
                    GLfloat[4] previous_clear_color;
                    glGetFloatv(GL_COLOR_CLEAR_VALUE, previous_clear_color.ptr);

                    bool drawingMainBuffer = previous_draw_fbo == oglGetFramebuffer();
                    bool drawingCompositeBuffer = previous_draw_fbo == oglGetCompositeFramebuffer();

                    if (!drawingMainBuffer && !drawingCompositeBuffer) {
                        setupShaderStage(packet, 2, matrix, cameraMatrix, puppetMatrix);
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

                    GLuint blendFramebuffer = oglGetBlendFramebuffer();
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, blendFramebuffer);
                    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                    glViewport(0, 0, viewportWidth, viewportHeight);
                    glClearColor(0f, 0f, 0f, 0f);
                    glClear(GL_COLOR_BUFFER_BIT);
                    setupShaderStage(packet, 2, matrix, cameraMatrix, puppetMatrix);
                    renderStage(packet, false);

                    GLuint bgAlbedo = drawingMainBuffer ? oglGetMainAlbedo() : oglGetCompositeImage();
                    GLuint bgEmissive = drawingMainBuffer ? oglGetMainEmissive() : oglGetCompositeEmissive();
                    GLuint bgBump = drawingMainBuffer ? oglGetMainBump() : oglGetCompositeBump();

                    GLuint fgAlbedo = oglGetBlendAlbedo();
                    GLuint fgEmissive = oglGetBlendEmissive();
                    GLuint fgBump = oglGetBlendBump();

                    GLuint destinationFBO = drawingMainBuffer ? oglGetCompositeFramebuffer() : oglGetFramebuffer();
                    oglBlendToBuffer(
                        blendShader,
                        packet.blendingMode,
                        destinationFBO,
                        bgAlbedo, bgEmissive, bgBump,
                        fgAlbedo, fgEmissive, fgBump
                    );

                    oglSwapMainCompositeBuffers();

                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, drawingMainBuffer ? oglGetFramebuffer() : oglGetCompositeFramebuffer());
                    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
                    glBindFramebuffer(GL_READ_FRAMEBUFFER, previous_read_fbo);
                    glViewport(previousViewport[0], previousViewport[1], previousViewport[2], previousViewport[3]);
                    glClearColor(previous_clear_color[0], previous_clear_color[1], previous_clear_color[2], previous_clear_color[3]);
                    return;
                }
            }

            setupShaderStage(packet, 2, matrix, cameraMatrix, puppetMatrix);
            renderStage(packet, false);
        }
    }

    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glBlendEquation(GL_FUNC_ADD);
}

private void setupShaderStage(ref PartDrawPacket packet, int stage, mat4 matrix, mat4 cameraMatrix, mat4 puppetMatrix) {
    mat4 mvpMatrix = cameraMatrix * puppetMatrix * matrix;

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
            glDrawBuffers(2, [GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

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
            glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

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
