module nijilive.core.render.backends.opengl.debug_renderer;

import nijilive.math : vec3, vec4, mat4, Vec3Array;
import nijilive.core.render.backends : RenderResourceHandle;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.core.shader : Shader, shaderAsset, ShaderAsset;
import nijilive.core.render.backends.opengl.soa_upload : glUploadFloatVecArray;

private Shader lineShader;
private Shader pointShader;
enum ShaderAsset LineShaderSource = shaderAsset!("opengl/dbg.vert","opengl/dbgline.frag")();
enum ShaderAsset PointShaderSource = shaderAsset!("opengl/dbg.vert","opengl/dbgpoint.frag")();
private GLuint vao;
private GLuint vbo;
private GLuint ibo;
private GLuint currentVbo;
private int indexCount;
private int lineMvpLocation = -1;
private int lineColorLocation = -1;
private int pointMvpLocation = -1;
private int pointColorLocation = -1;
private __gshared int pointCount;
private __gshared bool bufferIsSoA;

private void ensureInitialized() {
    if (lineShader !is null) return;

    lineShader = new Shader(LineShaderSource);
    pointShader = new Shader(PointShaderSource);

    lineMvpLocation = lineShader.getUniformLocation("mvp");
    lineColorLocation = lineShader.getUniformLocation("color");
    pointMvpLocation = pointShader.getUniformLocation("mvp");
    pointColorLocation = pointShader.getUniformLocation("color");

    glGenVertexArrays(1, &vao);
    glGenBuffers(1, &vbo);
    glGenBuffers(1, &ibo);
    currentVbo = vbo;
    indexCount = 0;
}

package(nijilive) void oglInitDebugRenderer() {
    ensureInitialized();
}

package(nijilive) void oglSetDebugPointSize(float size) {
    glPointSize(size);
}

package(nijilive) void oglSetDebugLineWidth(float size) {
    glLineWidth(size);
}

package(nijilive) void oglUploadDebugBuffer(Vec3Array points, ushort[] indices) {
    ensureInitialized();
    if (points.length == 0 || indices.length == 0) {
        indexCount = 0;
        pointCount = 0;
        bufferIsSoA = false;
        return;
    }

    glBindVertexArray(vao);
    glUploadFloatVecArray(vbo, points, GL_DYNAMIC_DRAW, "UploadDebug");
    currentVbo = vbo;
    pointCount = cast(int)points.length;
    bufferIsSoA = true;

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_DYNAMIC_DRAW);
    indexCount = cast(int)indices.length;
}

package(nijilive) void oglSetDebugExternalBuffer(RenderResourceHandle vertexBuffer, RenderResourceHandle indexBuffer, int count) {
    ensureInitialized();

    auto vertexHandle = cast(GLuint)vertexBuffer;
    auto indexHandle = cast(GLuint)indexBuffer;

    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vertexHandle);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexHandle);
    currentVbo = vertexHandle;
    indexCount = count;
    bufferIsSoA = false;
    pointCount = 0;
}

private void prepareDraw(Shader shader, int mvpLocation, int colorLocation, mat4 mvp, vec4 color) {
    if (shader is null || indexCount <= 0) return;

    shader.use();
    shader.setUniform(mvpLocation, mvp);
    shader.setUniform(colorLocation, color);

    glBindVertexArray(vao);
    if (bufferIsSoA && pointCount > 0) {
        auto laneBytes = cast(ptrdiff_t)pointCount * float.sizeof;
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)0);

        glEnableVertexAttribArray(1);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)laneBytes);

        glEnableVertexAttribArray(2);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)(laneBytes * 2));
    } else {
        glEnableVertexAttribArray(0);
        glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, null);
        glDisableVertexAttribArray(1);
        glDisableVertexAttribArray(2);
    }
}

private void finishDraw() {
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glBindVertexArray(0);
}

package(nijilive) void oglDrawDebugPoints(vec4 color, mat4 mvp) {
    ensureInitialized();
    if (indexCount <= 0) return;

    glBlendEquation(GL_FUNC_ADD);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);

    prepareDraw(pointShader, pointMvpLocation, pointColorLocation, mvp, color);
    glDrawElements(GL_POINTS, indexCount, GL_UNSIGNED_SHORT, null);
    finishDraw();

    glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);
}

package(nijilive) void oglDrawDebugLines(vec4 color, mat4 mvp) {
    ensureInitialized();
    if (indexCount <= 0) return;

    glEnable(GL_LINE_SMOOTH);
    glBlendEquation(GL_FUNC_ADD);
    glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);

    prepareDraw(lineShader, lineMvpLocation, lineColorLocation, mvp, color);
    glDrawElements(GL_LINES, indexCount, GL_UNSIGNED_SHORT, null);
    finishDraw();

    glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE);
    glDisable(GL_LINE_SMOOTH);
}

} else {

package(nijilive) void oglInitDebugRenderer() {}
package(nijilive) void oglSetDebugPointSize(float) {}
package(nijilive) void oglSetDebugLineWidth(float) {}
package(nijilive) void oglUploadDebugBuffer(Vec3Array, ushort[]) {}
package(nijilive) void oglSetDebugExternalBuffer(RenderResourceHandle, RenderResourceHandle, int) {}
package(nijilive) void oglDrawDebugPoints(vec4, mat4) {}
package(nijilive) void oglDrawDebugLines(vec4, mat4) {}

}




