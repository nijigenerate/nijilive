/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nijilive.core.shader;
import nijilive.math;
import nijilive.core.render.backends : RenderShaderHandle;
version (InDoesRender) {
    import nijilive.core.runtime_state : currentRenderBackend, tryRenderBackend;
}

/**
    A shader
*/
class Shader {
private:
    RenderShaderHandle handle;

public:

    /**
        Destructor
    */
    ~this() {
        version (InDoesRender) {
            if (handle is null) return;
            auto backend = tryRenderBackend();
            if (backend !is null) {
                backend.destroyShader(handle);
            }
            handle = null;
        }
    }

    /**
        Creates a new shader object from source
    */
    this(string vertex, string fragment) {
        version (InDoesRender) {
            handle = currentRenderBackend().createShader(vertex, fragment);
        }
    }

    /**
        Use the shader
    */
    void use() {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().useShader(handle);
        }
    }

    int getUniformLocation(string name) {
        version (InDoesRender) {
            if (handle is null) return -1;
            return currentRenderBackend().getShaderUniformLocation(handle, name);
        }
        return -1;
    }

    void setUniform(int uniform, bool value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, int value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, float value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, vec2 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, vec3 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, vec4 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }

    void setUniform(int uniform, mat4 value) {
        version (InDoesRender) {
            if (handle is null) return;
            currentRenderBackend().setShaderUniform(handle, uniform, value);
        }
    }
}
