module nijilive.core.render.backends.opengl.composite_resources;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core.shader;

__gshared Shader compositeShader;
__gshared Shader compositeMaskShader;
__gshared GLuint compositeVAO;
__gshared GLuint compositeBuffer;
__gshared GLint compositeOpacityUniform;
__gshared GLint compositeMultColorUniform;
__gshared GLint compositeScreenColorUniform;
__gshared bool compositeResourcesInitialized = false;

immutable float[] compositeVertexData = [
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

void initCompositeBackendResources() {
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

GLuint getCompositeVAO() {
    initCompositeBackendResources();
    return compositeVAO;
}

GLuint getCompositeBuffer() {
    initCompositeBackendResources();
    return compositeBuffer;
}

Shader getCompositeShader() {
    initCompositeBackendResources();
    return compositeShader;
}

Shader getCompositeMaskShader() {
    initCompositeBackendResources();
    return compositeMaskShader;
}

GLint getCompositeOpacityUniform() {
    initCompositeBackendResources();
    return compositeOpacityUniform;
}

GLint getCompositeMultColorUniform() {
    initCompositeBackendResources();
    return compositeMultColorUniform;
}

GLint getCompositeScreenColorUniform() {
    initCompositeBackendResources();
    return compositeScreenColorUniform;
}
