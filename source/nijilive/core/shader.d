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
    createShaderProgram,
    destroyShaderProgram,
    useShaderProgram,
    shaderGetUniformLocation = getUniformLocation,
    setUniformBool,
    setUniformInt,
    setUniformFloat,
    setUniformVec2,
    setUniformVec3,
    setUniformVec4,
    setUniformMat4;

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
        destroyShaderProgram(handle);
    }

    /**
        Creates a new shader object from source
    */
    this(string vertex, string fragment) {
        createShaderProgram(handle, vertex, fragment);
    }

    /**
        Use the shader
    */
    void use() {
        useShaderProgram(handle);
    }

    int getUniformLocation(string name) {
        return shaderGetUniformLocation(handle, name);
    }

    void setUniform(int uniform, bool value) {
        setUniformBool(uniform, value);
    }

    void setUniform(int uniform, int value) {
        setUniformInt(uniform, value);
    }

    void setUniform(int uniform, float value) {
        setUniformFloat(uniform, value);
    }

    void setUniform(int uniform, vec2 value) {
        setUniformVec2(uniform, value);
    }

    void setUniform(int uniform, vec3 value) {
        setUniformVec3(uniform, value);
    }

    void setUniform(int uniform, vec4 value) {
        setUniformVec4(uniform, value);
    }

    void setUniform(int uniform, mat4 value) {
        setUniformMat4(uniform, value);
    }
}
