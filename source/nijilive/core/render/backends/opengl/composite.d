module nijilive.core.render.backends.opengl.composite;

import nijilive.core.render.commands : CompositeDrawPacket;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.core.nodes.common : inSetBlendMode;
import nijilive.core.render.backends.opengl.runtime : oglPrepareCompositeScene;
import nijilive.core.shader : Shader;
import nijilive.math : mat4;

private __gshared Shader compositeShader;
private __gshared Shader compositeMaskShader;
private __gshared GLuint compositeVAO;
private __gshared GLuint compositeBuffer;
private __gshared GLint compositeOpacityUniform;
private __gshared GLint compositeMultColorUniform;
private __gshared GLint compositeScreenColorUniform;
private __gshared bool compositeResourcesInitialized = false;

private immutable float[] compositeVertexData = [
    // verts
    -1f, -1f,
    -1f, 1f,
    1f, -1f,
    1f, -1f,
    -1f, 1f,
    1f, 1f,

    // uvs
    0f, 0f,
    0f, 1f,
    1f, 0f,
    1f, 0f,
    0f, 1f,
    1f, 1f,
];

private void ensureCompositeBackendResources() {
    if (compositeResourcesInitialized) return;
    compositeResourcesInitialized = true;

    compositeShader = new Shader(
        import("basic/composite.vert"),
        import("basic/composite.frag")
    );

    compositeShader.use();
    compositeOpacityUniform = compositeShader.getUniformLocation("opacity");
    compositeMultColorUniform = compositeShader.getUniformLocation("multColor");
    compositeScreenColorUniform = compositeShader.getUniformLocation("screenColor");
    compositeShader.setUniform(compositeShader.getUniformLocation("albedo"), 0);
    compositeShader.setUniform(compositeShader.getUniformLocation("emissive"), 1);
    compositeShader.setUniform(compositeShader.getUniformLocation("bumpmap"), 2);

    compositeMaskShader = new Shader(
        import("basic/composite.vert"),
        import("basic/composite-mask.frag")
    );
    compositeMaskShader.use();
    compositeMaskShader.getUniformLocation("threshold");
    compositeMaskShader.getUniformLocation("opacity");

    glGenVertexArrays(1, &compositeVAO);
    glGenBuffers(1, &compositeBuffer);

    glBindVertexArray(compositeVAO);
    glBindBuffer(GL_ARRAY_BUFFER, compositeBuffer);
    glBufferData(GL_ARRAY_BUFFER, float.sizeof * compositeVertexData.length, compositeVertexData.ptr, GL_STATIC_DRAW);

    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, cast(void*)(12 * float.sizeof));

    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
}

GLuint oglGetCompositeVao() {
    ensureCompositeBackendResources();
    return compositeVAO;
}

GLuint oglGetCompositeBuffer() {
    ensureCompositeBackendResources();
    return compositeBuffer;
}

Shader oglGetCompositeShader() {
    ensureCompositeBackendResources();
    return compositeShader;
}

Shader oglGetCompositeMaskShader() {
    ensureCompositeBackendResources();
    return compositeMaskShader;
}

GLint oglGetCompositeOpacityUniform() {
    ensureCompositeBackendResources();
    return compositeOpacityUniform;
}

GLint oglGetCompositeMultColorUniform() {
    ensureCompositeBackendResources();
    return compositeMultColorUniform;
}

GLint oglGetCompositeScreenColorUniform() {
    ensureCompositeBackendResources();
    return compositeScreenColorUniform;
}

void oglDrawCompositeQuad(ref CompositeDrawPacket packet) {
    if (!packet.valid) return;

    ensureCompositeBackendResources();

    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glBindVertexArray(oglGetCompositeVao());

    auto shader = oglGetCompositeShader();
    shader.use();
    shader.setUniform(oglGetCompositeOpacityUniform(), packet.opacity);
    oglPrepareCompositeScene();
    shader.setUniform(oglGetCompositeMultColorUniform(), packet.tint);
    shader.setUniform(oglGetCompositeScreenColorUniform(), packet.screenTint);
    inSetBlendMode(packet.blendingMode, true);

    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, oglGetCompositeBuffer());
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, cast(void*)(12*float.sizeof));

    glDrawArrays(GL_TRIANGLES, 0, 6);
}

} else {

import nijilive.core.render.commands : CompositeDrawPacket;
import nijilive.core.shader : Shader;
alias GLuint = uint;
alias GLint = int;

GLuint oglGetCompositeVao() { return 0; }
GLuint oglGetCompositeBuffer() { return 0; }
Shader oglGetCompositeShader() { return null; }
Shader oglGetCompositeMaskShader() { return null; }
GLint oglGetCompositeOpacityUniform() { return 0; }
GLint oglGetCompositeMultColorUniform() { return 0; }
GLint oglGetCompositeScreenColorUniform() { return 0; }
void oglDrawCompositeQuad(ref CompositeDrawPacket) {}

}
