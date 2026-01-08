module nijilive.core.render.backends.opengl.dynamic_composite;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.core.render.commands : DynamicCompositePass, DynamicCompositeSurface;
import nijilive.core.runtime_state : inPushViewport, inPopViewport, inGetCamera, inSetCamera;
import nijilive.core.render.backends.opengl.runtime : oglRebindActiveTargets;
import nijilive.math : mat4, vec2, vec3, vec4;
import nijilive.core.texture : Texture;
import nijilive.core.render.backends.opengl.handles : requireGLTexture;
import nijilive.core.render.backends : RenderResourceHandle;
version (NijiliveRenderProfiler) {
    import nijilive.core.render.profiler : renderProfilerAddSampleUsec;
    import core.time : MonoTime;

    __gshared ulong gCompositeCpuAccumUsec;
    __gshared ulong gCompositeGpuAccumUsec;

    void resetCompositeAccum() {
        gCompositeCpuAccumUsec = 0;
        gCompositeGpuAccumUsec = 0;
    }

    ulong compositeCpuAccumUsec() { return gCompositeCpuAccumUsec; }
    ulong compositeGpuAccumUsec() { return gCompositeGpuAccumUsec; }
}

private GLuint textureId(Texture texture) {
    if (texture is null) return 0;
    auto handle = texture.backendHandle();
    if (handle is null) return 0;
    return requireGLTexture(handle).id;
}

private {
    version (NijiliveRenderProfiler) {
        GLuint compositeTimeQuery;
        bool compositeTimerInit;
        bool compositeTimerActive;
        MonoTime compositeCpuStart;
        bool compositeCpuActive;

        void ensureCompositeTimer() {
            if (compositeTimerInit) return;
            compositeTimerInit = true;
            glGenQueries(1, &compositeTimeQuery);
        }
    }
}

void oglBeginDynamicComposite(DynamicCompositePass pass) {
    if (pass is null) return;
    auto surface = pass.surface;
    if (surface is null || surface.textureCount == 0) return;
    auto tex = surface.textures[0];
    if (tex is null) return;

    if (surface.framebuffer == 0) {
        GLuint newFramebuffer;
        glGenFramebuffers(1, &newFramebuffer);
        surface.framebuffer = cast(RenderResourceHandle)newFramebuffer;
    }


    GLint previousFramebuffer;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &previousFramebuffer);
    pass.origBuffer = cast(RenderResourceHandle)previousFramebuffer;
    glGetIntegerv(GL_VIEWPORT, pass.origViewport.ptr);

    glBindFramebuffer(GL_FRAMEBUFFER, cast(GLuint)surface.framebuffer);

    GLuint[3] drawBuffers;
    size_t bufferCount;
    foreach (i; 0 .. surface.textureCount) {
        auto attachment = GL_COLOR_ATTACHMENT0 + cast(GLenum)i;
        auto attachmentTexture = surface.textures[i];
        if (attachmentTexture !is null) {
            glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, textureId(attachmentTexture), 0);
            drawBuffers[bufferCount++] = attachment;
        } else {
            glFramebufferTexture2D(GL_FRAMEBUFFER, attachment, GL_TEXTURE_2D, 0, 0);
        }
    }

    if (bufferCount == 0) {
        drawBuffers[bufferCount++] = GL_COLOR_ATTACHMENT0;
    }

    if (surface.stencil !is null) {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, textureId(surface.stencil), 0);
        glClear(GL_STENCIL_BUFFER_BIT);
    } else {
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_TEXTURE_2D, 0, 0);
    }

    inPushViewport(tex.width, tex.height);

    auto camera = inGetCamera();
    camera.scale = vec2(1, -1);

    float invScaleX = pass.scale.x == 0 ? 0 : 1 / pass.scale.x;
    float invScaleY = pass.scale.y == 0 ? 0 : 1 / pass.scale.y;
    auto scaling = mat4.identity.scaling(invScaleX, invScaleY, 1);
    auto rotation = mat4.identity.rotateZ(-pass.rotationZ);
    auto offsetMatrix = scaling * rotation;
    camera.position = (offsetMatrix * -vec4(0, 0, 0, 1)).xy;
    inSetCamera(camera);

    glDrawBuffers(cast(int)bufferCount, drawBuffers.ptr);
    glViewport(0, 0, tex.width, tex.height);
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    glActiveTexture(GL_TEXTURE0);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);

    version (NijiliveRenderProfiler) {
        if (!compositeCpuActive) {
            compositeCpuActive = true;
            compositeCpuStart = MonoTime.currTime;
        }
        ensureCompositeTimer();
        if (!compositeTimerActive && compositeTimeQuery != 0) {
            glBeginQuery(GL_TIME_ELAPSED, compositeTimeQuery);
            compositeTimerActive = true;
        }
    }
}

void oglEndDynamicComposite(DynamicCompositePass pass) {
    if (pass is null || pass.surface is null) return;

    // Rebind active attachments (respecting any swaps that happened while rendering).
    oglRebindActiveTargets();

    glBindFramebuffer(GL_FRAMEBUFFER, cast(GLuint)pass.origBuffer);
    inPopViewport();
    glViewport(pass.origViewport[0], pass.origViewport[1],
        pass.origViewport[2], pass.origViewport[3]);
    glDrawBuffers(3, [GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1, GL_COLOR_ATTACHMENT2].ptr);
    version (NijiliveRenderProfiler) {
        if (compositeTimerActive && compositeTimeQuery != 0) {
            glEndQuery(GL_TIME_ELAPSED);
            ulong ns = 0;
            glGetQueryObjectui64v(compositeTimeQuery, GL_QUERY_RESULT, &ns);
            renderProfilerAddSampleUsec("Composite.Offscreen", ns / 1000);
            gCompositeGpuAccumUsec += ns / 1000;
            compositeTimerActive = false;
        }
        if (compositeCpuActive) {
            auto dur = MonoTime.currTime - compositeCpuStart;
            renderProfilerAddSampleUsec("Composite.Offscreen.CPU", dur.total!"usecs");
            gCompositeCpuAccumUsec += dur.total!"usecs";
            compositeCpuActive = false;
        }
    }
    glFlush();

    auto tex = pass.surface.textureCount > 0 ? pass.surface.textures[0] : null;
    if (tex !is null && !pass.autoScaled) {
        tex.genMipmap();
    }
}

void oglDestroyDynamicComposite(DynamicCompositeSurface surface) {
    if (surface is null) return;
    if (surface.framebuffer != 0) {
        auto buffer = cast(GLuint)surface.framebuffer;
        glDeleteFramebuffers(1, &buffer);
        surface.framebuffer = 0;
    }
}

} else {

import nijilive.core.render.commands : DynamicCompositePass, DynamicCompositeSurface;

void oglBeginDynamicComposite(DynamicCompositePass) {}
void oglEndDynamicComposite(DynamicCompositePass) {}
void oglDestroyDynamicComposite(DynamicCompositeSurface) {}

}
