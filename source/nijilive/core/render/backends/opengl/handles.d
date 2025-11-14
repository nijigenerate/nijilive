module nijilive.core.render.backends.opengl.handles;

import std.exception : enforce;
import nijilive.core.render.backends : RenderShaderHandle, RenderTextureHandle;
import nijilive.core.render.backends.opengl.shader_backend : ShaderProgramHandle;
import nijilive.core.render.backends.opengl.texture_backend : GLId;

class GLShaderHandle : RenderShaderHandle {
    ShaderProgramHandle shader;
}

class GLTextureHandle : RenderTextureHandle {
    GLId id;
}

GLShaderHandle requireGLShader(RenderShaderHandle handle) {
    auto result = cast(GLShaderHandle)handle;
    enforce(result !is null, "Shader handle is not backed by OpenGL");
    return result;
}

GLTextureHandle requireGLTexture(RenderTextureHandle handle) {
    auto result = cast(GLTextureHandle)handle;
    enforce(result !is null, "Texture handle is not backed by OpenGL");
    return result;
}
