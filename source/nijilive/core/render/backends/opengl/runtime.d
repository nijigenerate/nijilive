module nijilive.core.render.backends.opengl.runtime;

import bindbc.opengl;
import std.algorithm.comparison : max;
import std.algorithm.mutation : swap;
import core.stdc.string : memcpy;

import nijilive.math;
import nijilive.core.shader : Shader, shaderAsset, ShaderAsset;
import nijilive.core.dbg : inInitDebug;
// Composite backend removed; no-op imports.
import nijilive.core.runtime_state :
    inSetViewport,
    inViewportWidth,
    inViewportHeight,
    inClearColor,
    inGetClearColor,
    inSceneAmbientLight;

version(Windows) {
    // Ask Windows nicely to use dedicated GPUs :)
    export extern(C) int NvOptimusEnablement = 0x00000001;
    export extern(C) int AmdPowerXpressRequestHighPerformance = 0x00000001;
}

struct PostProcessingShader {
private:
    GLint[string] uniformCache;

public:
    Shader shader;
    this(Shader shader) {
        this.shader = shader;

        shader.use();
        shader.setUniform(shader.getUniformLocation("albedo"), 0);
        shader.setUniform(shader.getUniformLocation("emissive"), 1);
        shader.setUniform(shader.getUniformLocation("bumpmap"), 2);
    }

    /**
        Gets the location of the specified uniform
    */
    GLuint getUniform(string name) {
        if (this.hasUniform(name)) return uniformCache[name];
        GLint element = shader.getUniformLocation(name);
        uniformCache[name] = element;
        return element;
    }

    /**
        Returns true if the uniform is present in the shader cache 
    */
    bool hasUniform(string name) {
        return (name in uniformCache) !is null;
    }
}

// Internal rendering constants
private {
    GLuint sceneVAO;
    GLuint sceneVBO;

    GLuint fBuffer;
    GLuint fAlbedo;
    GLuint fEmissive;
    GLuint fBump;
    GLuint fStencil;

    GLuint cfBuffer;
    GLuint cfAlbedo;
    GLuint cfEmissive;
    GLuint cfBump;
    GLuint cfStencil;

    GLuint blendFBO;
    GLuint blendAlbedo;
    GLuint blendEmissive;
    GLuint blendBump;
    GLuint blendStencil;

    PostProcessingShader basicSceneShader;
    PostProcessingShader basicSceneLighting;
    PostProcessingShader[] postProcessingStack;
    enum ShaderAsset SceneShaderSource = shaderAsset!("opengl/scene.vert","opengl/scene.frag")();
    enum ShaderAsset LightingShaderSource = shaderAsset!("opengl/scene.vert","opengl/lighting.frag")();

    bool isCompositing;
    struct CompositeFrameState {
        GLint framebuffer;
        GLint[4] viewport;
    }
    CompositeFrameState[] compositeScopeStack;

    void renderScene(vec4 area, PostProcessingShader shaderToUse, GLuint albedo, GLuint emissive, GLuint bump) {
        glViewport(0, 0, cast(int)area.z, cast(int)area.w);

        // Bind our vertex array
        glBindVertexArray(sceneVAO);
        
        glDisable(GL_CULL_FACE);
        glDisable(GL_DEPTH_TEST);
        glEnable(GL_BLEND);
        glBlendEquation(GL_FUNC_ADD);
        glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

        shaderToUse.shader.use();
        shaderToUse.shader.setUniform(shaderToUse.getUniform("mvp"), 
            mat4.orthographic(0, area.z, area.w, 0, 0, max(area.z, area.w)) * 
            mat4.translation(area.x, area.y, 0)
        );

        // Ambient light
        GLint ambientLightUniform = shaderToUse.getUniform("ambientLight");
        if (ambientLightUniform != -1) shaderToUse.shader.setUniform(ambientLightUniform, inSceneAmbientLight);

        // framebuffer size
        GLint fbSizeUniform = shaderToUse.getUniform("fbSize");
        if (fbSizeUniform != -1) shaderToUse.shader.setUniform(fbSizeUniform, vec2(inViewportWidth[$-1], inViewportHeight[$-1]));

        // Bind the texture
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, albedo);
        glActiveTexture(GL_TEXTURE1);
        glBindTexture(GL_TEXTURE_2D, emissive);
        glActiveTexture(GL_TEXTURE2);
        glBindTexture(GL_TEXTURE_2D, bump);

        // Enable points array
        glEnableVertexAttribArray(0); // verts
        glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4*float.sizeof, null);

        // Enable UVs array
        glEnableVertexAttribArray(1); // uvs
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4*float.sizeof, cast(float*)(2*float.sizeof));

        // Draw
        glDrawArrays(GL_TRIANGLES, 0, 6);

        // Disable the vertex attribs after use
        glDisableVertexAttribArray(0);
        glDisableVertexAttribArray(1);

        glDisable(GL_BLEND);
    }
}

// Things only available internally for nijilive rendering
package(nijilive) {
    
    /**
        Initializes the renderer (OpenGL-specific portion)
    */
    void oglInitRenderer() {

        // Set the viewport and by extension set the textures
        inSetViewport(640, 480);
        version(InDoesRender) inInitDebug();

        version (InDoesRender) {
            
            // Shader for scene
            basicSceneShader = PostProcessingShader(new Shader(SceneShaderSource));
            glGenVertexArrays(1, &sceneVAO);
            glGenBuffers(1, &sceneVBO);

            // Generate the framebuffer we'll be using to render the model and composites
            glGenFramebuffers(1, &fBuffer);
            glGenFramebuffers(1, &cfBuffer);
            glGenFramebuffers(1, &blendFBO);
            
            // Generate the color and stencil-depth textures needed
            // Note: we're not using the depth buffer but OpenGL 3.4 does not support stencil-only buffers
            glGenTextures(1, &fAlbedo);
            glGenTextures(1, &fEmissive);
            glGenTextures(1, &fBump);
            glGenTextures(1, &fStencil);

            glGenTextures(1, &cfAlbedo);
            glGenTextures(1, &cfEmissive);
            glGenTextures(1, &cfBump);
            glGenTextures(1, &cfStencil);

            glGenTextures(1, &blendAlbedo);
            glGenTextures(1, &blendEmissive);
            glGenTextures(1, &blendBump);
            glGenTextures(1, &blendStencil);

            // Attach textures to framebuffer
            glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);

            glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

            glBindFramebuffer(GL_FRAMEBUFFER, blendFBO);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blendAlbedo, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, blendEmissive, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, blendBump, 0);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, blendStencil, 0);

            // go back to default fb
            glBindFramebuffer(GL_FRAMEBUFFER, 0);

        }
    }
}

/**
    Begins rendering to the framebuffer
*/
void oglBeginScene() {
    glBindVertexArray(sceneVAO);
    glEnable(GL_BLEND);
    glEnablei(GL_BLEND, 0);
    glEnablei(GL_BLEND, 1);
    glEnablei(GL_BLEND, 2);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);

    // Make sure to reset our viewport if someone has messed with it
    glViewport(0, 0, inViewportWidth[$-1], inViewportHeight[$-1]);

    // Bind and clear composite framebuffer
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cfBuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glClearColor(0, 0, 0, 0);

    // Bind our framebuffer
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fBuffer);

    // First clear buffer 0
    glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);
    glClearColor(inClearColor.r, inClearColor.g, inClearColor.b, inClearColor.a);
    glClear(GL_COLOR_BUFFER_BIT);

    // Then clear others with black
    glDrawBuffers(2, [GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT);

    // Everything else is the actual texture used by the meshes at id 0
    glActiveTexture(GL_TEXTURE0);

    // Finally we render to all buffers
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
}

/**
    Begins a composition step
*/
void oglBeginComposite() {

    CompositeFrameState frameState;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &frameState.framebuffer);
    glGetIntegerv(GL_VIEWPORT, frameState.viewport.ptr);
    compositeScopeStack ~= frameState;
    isCompositing = true;

    immutable(GLenum[3]) attachments = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cfBuffer);
    glDrawBuffers(cast(GLsizei)attachments.length, attachments.ptr);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);

    glActiveTexture(GL_TEXTURE0);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
}

/**
    Ends a composition step, re-binding the internal framebuffer
*/
void oglEndComposite() {
    if (compositeScopeStack.length == 0) return;

    auto frameState = compositeScopeStack[$ - 1];
    compositeScopeStack.length -= 1;

    immutable(GLenum[3]) attachments = [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2];
    glBindFramebuffer(GL_FRAMEBUFFER, frameState.framebuffer);
    glViewport(frameState.viewport[0], frameState.viewport[1], frameState.viewport[2], frameState.viewport[3]);
    glDrawBuffers(cast(GLsizei)attachments.length, attachments.ptr);

    if (compositeScopeStack.length == 0) {
        glFlush();
        isCompositing = false;
    }
}

/**
    Ends rendering to the framebuffer
*/
void oglEndScene() {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);

    glDisablei(GL_BLEND, 0);
    glDisablei(GL_BLEND, 1);
    glDisablei(GL_BLEND, 2);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_CULL_FACE);
    glDisable(GL_BLEND);
    glFlush();
    glDrawBuffers(1, [GL_COLOR_ATTACHMENT0].ptr);

//    import std.stdio;
//    writefln("end render");
}

/**
    Runs post processing on the scene
*/
void oglPostProcessScene() {
    if (postProcessingStack.length == 0) return;
    
    bool targetBuffer;

    // These are passed to glSetClearColor for transparent export
    float r, g, b, a;
    inGetClearColor(r, g, b, a);

    // Render area
    vec4 area = vec4(
        0, 0,
        inViewportWidth[$-1], inViewportHeight[$-1]
    );

    // Tell OpenGL the resolution to render at
    float[] data = [
        area.x,         area.y+area.w,          0, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y+area.w,          1, 0,
        
        area.x+area.z,  area.y+area.w,          1, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y,                 1, 1,
    ];
    glBindBuffer(GL_ARRAY_BUFFER, sceneVBO);
    glBufferData(GL_ARRAY_BUFFER, 24*float.sizeof, data.ptr, GL_DYNAMIC_DRAW);


    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, fEmissive);
    glGenerateMipmap(GL_TEXTURE_2D);

    // We want to be able to post process all the attachments
    glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    glClearColor(r, g, b, a);
    glClear(GL_COLOR_BUFFER_BIT);

    glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);

    foreach(shader; postProcessingStack) {
        targetBuffer = !targetBuffer;

        if (targetBuffer) {

            // Main buffer -> Composite buffer
            glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer); // dst
            renderScene(area, shader, fAlbedo, fEmissive, fBump); // src
        } else {

            // Composite buffer -> Main buffer 
            glBindFramebuffer(GL_FRAMEBUFFER, fBuffer); // dst
            renderScene(area, shader, cfAlbedo, cfEmissive, cfBump); // src
        }
    }

    if (targetBuffer) {
        glBindFramebuffer(GL_READ_FRAMEBUFFER, cfBuffer);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fBuffer);
        glBlitFramebuffer(
            0, 0, inViewportWidth[$-1], inViewportHeight[$-1], // src rect
            0, 0, inViewportWidth[$-1], inViewportHeight[$-1], // dst rect
            GL_COLOR_BUFFER_BIT, // blit mask
            GL_LINEAR // blit filter
        );
    }
    
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

/**
    Add basic lighting shader to processing stack
*/
void oglAddBasicLightingPostProcess() {
    postProcessingStack ~= PostProcessingShader(new Shader(LightingShaderSource));
}

/**
    Clears the post processing stack
*/
ref PostProcessingShader[] oglGetPostProcessingStack() {
    return postProcessingStack;
}

/**
    Draw scene to area
*/
void oglDrawScene(vec4 area) {
    float[] data = [
        area.x,         area.y+area.w,          0, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y+area.w,          1, 0,
        
        area.x+area.z,  area.y+area.w,          1, 0,
        area.x,         area.y,                 0, 1,
        area.x+area.z,  area.y,                 1, 1,
    ];

    glBindBuffer(GL_ARRAY_BUFFER, sceneVBO);
    glBufferData(GL_ARRAY_BUFFER, 24*float.sizeof, data.ptr, GL_DYNAMIC_DRAW);
    renderScene(area, basicSceneShader, fAlbedo, fEmissive, fBump);
}

void oglPrepareCompositeScene() {
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, cfAlbedo);
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, cfEmissive);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, cfBump);
}

/**
    Gets the nijilive framebuffer 

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetFramebuffer() {
    return fBuffer;
}

/**
    Gets the nijilive framebuffer render image

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetRenderImage() {
    return fAlbedo;
}

/**
    Gets the nijilive composite render image

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetCompositeImage() {
    return cfAlbedo;
}

package(nijilive) GLuint oglGetCompositeFramebuffer() {
    return cfBuffer;
}

package(nijilive) GLuint oglGetBlendFramebuffer() {
    return blendFBO;
}

package(nijilive) GLuint oglGetMainEmissive() {
    return fEmissive;
}

package(nijilive) GLuint oglGetMainBump() {
    return fBump;
}

package(nijilive) GLuint oglGetCompositeEmissive() {
    return cfEmissive;
}

package(nijilive) GLuint oglGetCompositeBump() {
    return cfBump;
}

package(nijilive) GLuint oglGetBlendAlbedo() {
    return blendAlbedo;
}

package(nijilive) GLuint oglGetBlendEmissive() {
    return blendEmissive;
}

package(nijilive) GLuint oglGetBlendBump() {
    return blendBump;
}

/**
    Gets the nijilive main albedo render image

    DO NOT MODIFY THIS IMAGE!
*/
GLuint oglGetMainAlbedo() {
    return fAlbedo;
}

/**
    Gets the blend shader for the specified mode
*/
package(nijilive) void oglSwapMainCompositeBuffers() {
    swap(fAlbedo, cfAlbedo);
    swap(fEmissive, cfEmissive);
    swap(fBump, cfBump);
    swap(fStencil, cfStencil);

    GLint previous_fbo;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous_fbo);

    glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);

    glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

    glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo);
}
package(nijilive)
void oglResizeViewport(int width, int height) {
    version(InDoesRender) {
        // Render Framebuffer
        glBindTexture(GL_TEXTURE_2D, fAlbedo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, fEmissive);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, fBump);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, fStencil);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);

        glBindFramebuffer(GL_FRAMEBUFFER, fBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, fEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, fBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, fStencil, 0);
        

        // Composite framebuffer
        glBindTexture(GL_TEXTURE_2D, cfAlbedo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, cfEmissive);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, cfBump);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, cfStencil);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);

        glBindFramebuffer(GL_FRAMEBUFFER, cfBuffer);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, cfAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, cfEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, cfBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, cfStencil, 0);

        // Blend framebuffer
        glBindTexture(GL_TEXTURE_2D, blendAlbedo);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, blendEmissive);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_FLOAT, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, blendBump);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, null);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        
        glBindTexture(GL_TEXTURE_2D, blendStencil);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8, width, height, 0, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, null);

        glBindFramebuffer(GL_FRAMEBUFFER, blendFBO);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, blendAlbedo, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT1, GL_TEXTURE_2D, blendEmissive, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT2, GL_TEXTURE_2D, blendBump, 0);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_TEXTURE_2D, blendStencil, 0);
        
        glBindFramebuffer(GL_FRAMEBUFFER, 0);

        glViewport(0, 0, width, height);
    }
}

/**
    Dumps viewport data to texture stream
*/
package(nijilive)
void oglDumpViewport(ref ubyte[] dumpTo, int width, int height) {
    version(InDoesRender) {
        if (width == 0 || height == 0) return;
        glBindTexture(GL_TEXTURE_2D, fAlbedo);
        glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, dumpTo.ptr);
    }
}
