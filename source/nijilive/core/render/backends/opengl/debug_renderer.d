module nijilive.core.render.backends.opengl.debug_renderer;

import nijilive.math : vec3, vec4, mat4;

version (InDoesRender) {

import bindbc.opengl;
import nijilive.core.shader : Shader;

private Shader lineShader;
private Shader pointShader;
private GLuint vao;
private GLuint vbo;
private GLuint ibo;
private GLuint currentVbo;
private int indexCount;
private int lineMvpLocation = -1;
private int lineColorLocation = -1;
private int pointMvpLocation = -1;
private int pointColorLocation = -1;

private void ensureInitialized() {
    if (lineShader !is null) return;

    lineShader = new Shader(import("dbg.vert"), import("dbgline.frag"));
    pointShader = new Shader(import("dbg.vert"), import("dbgpoint.frag"));

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

package(nijilive) void oglUploadDebugBuffer(vec3[] points, ushort[] indices) {
    ensureInitialized();
    if (points.length == 0 || indices.length == 0) {
        indexCount = 0;
        return;
    }

    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vbo);
    glBufferData(GL_ARRAY_BUFFER, points.length * vec3.sizeof, points.ptr, GL_DYNAMIC_DRAW);
    currentVbo = vbo;

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, ibo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, indices.length * ushort.sizeof, indices.ptr, GL_DYNAMIC_DRAW);
    indexCount = cast(int)indices.length;
}

package(nijilive) void oglSetDebugExternalBuffer(uint vertexBuffer, uint indexBuffer, int count) {
    ensureInitialized();

    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, indexBuffer);
    currentVbo = vertexBuffer;
    indexCount = count;
}

private void prepareDraw(Shader shader, int mvpLocation, int colorLocation, mat4 mvp, vec4 color) {
    if (shader is null || indexCount <= 0) return;

    shader.use();
    shader.setUniform(mvpLocation, mvp);
    shader.setUniform(colorLocation, color);

    glBindVertexArray(vao);
    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, currentVbo);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, null);
}

private void finishDraw() {
    glDisableVertexAttribArray(0);
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
package(nijilive) void oglUploadDebugBuffer(vec3[], ushort[]) {}
package(nijilive) void oglSetDebugExternalBuffer(uint, uint, int) {}
package(nijilive) void oglDrawDebugPoints(vec4, mat4) {}
package(nijilive) void oglDrawDebugLines(vec4, mat4) {}

}
