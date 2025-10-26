module nijilive.core.render.backends.opengl.part_resources;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.nodes.part : Part;
import nijilive.core.meshdata : MeshData;
import nijilive.core.texture : Texture;
import nijilive.core.shader;
import nijilive.math : vec2;

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
__gshared GLuint sVertexBuffer;
__gshared GLuint sUVBuffer;
__gshared GLuint sElementBuffer;
__gshared bool partBackendInitialized = false;

void initPartBackendResources() {
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

    glGenBuffers(1, &sVertexBuffer);
    glGenBuffers(1, &sUVBuffer);
    glGenBuffers(1, &sElementBuffer);
}

uint createPartUVBuffer() {
    uint buffer;
    glGenBuffers(1, &buffer);
    return buffer;
}

void updatePartUVBuffer(uint uvbo, ref MeshData data) {
    glBindBuffer(GL_ARRAY_BUFFER, uvbo);
    glBufferData(GL_ARRAY_BUFFER, data.uvs.length * vec2.sizeof, data.uvs.ptr, GL_STATIC_DRAW);
}
