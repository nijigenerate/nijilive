/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.shader;
import nijilive.math;
import nijilive.core.render.backends.opengl.shader_backend :
    ShaderProgramHandle,
    oglCreateShaderProgram,
    oglDestroyShaderProgram,
    oglUseShaderProgram,
    oglShaderGetUniformLocation,
    oglSetUniformBool,
    oglSetUniformInt,
    oglSetUniformFloat,
    oglSetUniformVec2,
    oglSetUniformVec3,
    oglSetUniformVec4,
    oglSetUniformMat4;

/**
    A shader
*/
class Shader {
private:
    ShaderProgramHandle handle;

public:

    /**
        Destructor
    */
    ~this() {
        oglDestroyShaderProgram(handle);
    }

    /**
        Creates a new shader object from source
    */
    this(string vertex, string fragment) {
        oglCreateShaderProgram(handle, vertex, fragment);
    }

    /**
        Use the shader
    */
    void use() {
        oglUseShaderProgram(handle);
    }

    int getUniformLocation(string name) {
        return oglShaderGetUniformLocation(handle, name);
    }

    void setUniform(int uniform, bool value) {
        oglSetUniformBool(uniform, value);
    }

    void setUniform(int uniform, int value) {
        oglSetUniformInt(uniform, value);
    }

    void setUniform(int uniform, float value) {
        oglSetUniformFloat(uniform, value);
    }

    void setUniform(int uniform, vec2 value) {
        oglSetUniformVec2(uniform, value);
    }

    void setUniform(int uniform, vec3 value) {
        oglSetUniformVec3(uniform, value);
    }

    void setUniform(int uniform, vec4 value) {
        oglSetUniformVec4(uniform, value);
    }

    void setUniform(int uniform, mat4 value) {
        oglSetUniformMat4(uniform, value);
    }
}
