module nijilive.core.render.backends.opengl.shader_backend;

import nijilive.math : mat4, vec2, vec3, vec4;

version (InDoesRender) {

import bindbc.opengl;
import std.exception;
import std.string : toStringz;

struct ShaderProgramHandle {
    uint program;
    uint vert;
    uint frag;
}

private void checkShader(GLuint shader) {
    GLint status;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &status);
    if (status == GL_FALSE) {
        GLint length;
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
        if (length > 0) {
            char[] log = new char[length];
            glGetShaderInfoLog(shader, length, null, log.ptr);
            throw new Exception(cast(string)log);
        }
        throw new Exception("Shader compile failed");
    }
}

private void checkProgram(GLuint program) {
    GLint status;
    glGetProgramiv(program, GL_LINK_STATUS, &status);
    if (status == GL_FALSE) {
        GLint length;
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
        if (length > 0) {
            char[] log = new char[length];
            glGetProgramInfoLog(program, length, null, log.ptr);
            throw new Exception(cast(string)log);
        }
        throw new Exception("Program link failed");
    }
}

void oglCreateShaderProgram(ref ShaderProgramHandle handle, string vertex, string fragment) {
    handle.vert = glCreateShader(GL_VERTEX_SHADER);
    auto vsrc = vertex.toStringz;
    glShaderSource(handle.vert, 1, &vsrc, null);
    glCompileShader(handle.vert);
    checkShader(handle.vert);

    handle.frag = glCreateShader(GL_FRAGMENT_SHADER);
    auto fsrc = fragment.toStringz;
    glShaderSource(handle.frag, 1, &fsrc, null);
    glCompileShader(handle.frag);
    checkShader(handle.frag);

    handle.program = glCreateProgram();
    glAttachShader(handle.program, handle.vert);
    glAttachShader(handle.program, handle.frag);
    glLinkProgram(handle.program);
    checkProgram(handle.program);
}

void oglDestroyShaderProgram(ref ShaderProgramHandle handle) {
    if (handle.program) {
        glDetachShader(handle.program, handle.vert);
        glDetachShader(handle.program, handle.frag);
        glDeleteProgram(handle.program);
    }
    if (handle.vert) glDeleteShader(handle.vert);
    if (handle.frag) glDeleteShader(handle.frag);
    handle = ShaderProgramHandle.init;
}

void oglUseShaderProgram(ref ShaderProgramHandle handle) {
    glUseProgram(handle.program);
}

int oglShaderGetUniformLocation(ref ShaderProgramHandle handle, string name) {
    return glGetUniformLocation(handle.program, name.toStringz);
}

void oglSetUniformBool(int location, bool value) {
    glUniform1i(location, value ? 1 : 0);
}

void oglSetUniformInt(int location, int value) {
    glUniform1i(location, value);
}

void oglSetUniformFloat(int location, float value) {
    glUniform1f(location, value);
}

void oglSetUniformVec2(int location, vec2 value) {
    glUniform2f(location, value.x, value.y);
}

void oglSetUniformVec3(int location, vec3 value) {
    glUniform3f(location, value.x, value.y, value.z);
}

void oglSetUniformVec4(int location, vec4 value) {
    glUniform4f(location, value.x, value.y, value.z, value.w);
}

void oglSetUniformMat4(int location, mat4 value) {
    glUniformMatrix4fv(location, 1, GL_TRUE, value.ptr);
}

} else {

struct ShaderProgramHandle { }

void oglCreateShaderProgram(ref ShaderProgramHandle handle, string vertex, string fragment) { }
void oglDestroyShaderProgram(ref ShaderProgramHandle handle) { }
void oglUseShaderProgram(ref ShaderProgramHandle handle) { }
int oglShaderGetUniformLocation(ref ShaderProgramHandle handle, string name) { return -1; }
void oglSetUniformBool(int, bool) { }
void oglSetUniformInt(int, int) { }
void oglSetUniformFloat(int, float) { }
void oglSetUniformVec2(int, vec2) { }
void oglSetUniformVec3(int, vec3) { }
void oglSetUniformVec4(int, vec4) { }
void oglSetUniformMat4(int, mat4) { }

}
