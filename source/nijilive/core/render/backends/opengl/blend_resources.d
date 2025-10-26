module nijilive.core.render.backends.opengl.blend_resources;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.shader;
import nijilive.core.nodes.common : BlendMode;
import nijilive.core.render.backends.opengl.composite_resources : getCompositeVAO;
import nijilive.math : mat4, vec2;

private __gshared Shader[BlendMode] blendShaders;

private void ensureBlendShadersInitialized() {
    if (blendShaders.length > 0) return;

    auto advancedBlendShader = new Shader(import("basic/basic.vert"), import("basic/advanced_blend.frag"));
    BlendMode[] advancedModes = [
        BlendMode.Multiply,
        BlendMode.Screen,
        BlendMode.Overlay,
        BlendMode.Darken,
        BlendMode.Lighten,
        BlendMode.ColorDodge,
        BlendMode.ColorBurn,
        BlendMode.HardLight,
        BlendMode.SoftLight,
        BlendMode.Difference,
        BlendMode.Exclusion
    ];
    foreach (mode; advancedModes) {
        blendShaders[mode] = advancedBlendShader;
    }
}

Shader getBlendShader(BlendMode mode) {
    ensureBlendShadersInitialized();
    auto shader = mode in blendShaders;
    return shader ? *shader : null;
}

void blendToBuffer(
    Shader shader,
    BlendMode mode,
    GLuint dstFramebuffer,
    GLuint bgAlbedo, GLuint bgEmissive, GLuint bgBump,
    GLuint fgAlbedo, GLuint fgEmissive, GLuint fgBump
) {
    if (shader is null) return;

    glBindFramebuffer(GL_FRAMEBUFFER, dstFramebuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

    shader.use();
    GLint modeUniform = shader.getUniformLocation("blend_mode");
    if (modeUniform != -1) {
        shader.setUniform(modeUniform, cast(int)mode);
    }

    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, bgAlbedo);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, bgEmissive);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, bgBump);

    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, fgAlbedo);
    glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, fgEmissive);
    glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, fgBump);

    shader.setUniform(shader.getUniformLocation("bg_albedo"), 0);
    shader.setUniform(shader.getUniformLocation("bg_emissive"), 1);
    shader.setUniform(shader.getUniformLocation("bg_bump"), 2);
    shader.setUniform(shader.getUniformLocation("fg_albedo"), 3);
    shader.setUniform(shader.getUniformLocation("fg_emissive"), 4);
    shader.setUniform(shader.getUniformLocation("fg_bump"), 5);

    GLint mvpUniform = shader.getUniformLocation("mvp");
    if (mvpUniform != -1) {
        shader.setUniform(mvpUniform, mat4.identity);
    }

    GLint offsetUniform = shader.getUniformLocation("offset");
    if (offsetUniform != -1) {
        shader.setUniform(offsetUniform, vec2(0, 0));
    }

    glBindVertexArray(getCompositeVAO());
    glDrawArrays(GL_TRIANGLES, 0, 6);

    glActiveTexture(GL_TEXTURE5); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE4); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_2D, 0);
    glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, 0);
}
