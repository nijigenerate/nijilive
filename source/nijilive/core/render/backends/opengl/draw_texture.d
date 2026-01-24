module nijilive.core.render.backends.opengl.draw_texture;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core;
import nijilive.math;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.texture : Texture;
import nijilive.core.nodes.part : Part;
import nijilive.core.render.backends.opengl.part : partShader, gopacity, gMultColor,
    gScreenColor, mvp, offset;

private __gshared GLuint quadVertexBuffer;
private __gshared GLuint quadUvBuffer;
private __gshared GLuint quadElementBuffer;

private void ensureQuadBuffers() {
    if (quadVertexBuffer == 0) {
        glGenBuffers(1, &quadVertexBuffer);
    }
    if (quadUvBuffer == 0) {
        glGenBuffers(1, &quadUvBuffer);
    }
    if (quadElementBuffer == 0) {
        glGenBuffers(1, &quadElementBuffer);
    }
}

void oglDrawTextureAtPart(Texture texture, Part part) {
    if (texture is null || part is null) return;

    const float texWidthP = texture.width()/2;
    const float texHeightP = texture.height()/2;

    incDrawableBindVAO();
    ensureQuadBuffers();

    mat4 modelMatrix = part.immediateModelMatrix();
    auto renderSpace = part.currentRenderSpace();

    partShader.use();
    partShader.setUniform(mvp,
        renderSpace.matrix *
        modelMatrix
    );
    partShader.setUniform(offset, part.getMesh().origin);
    partShader.setUniform(gopacity, part.opacity);
    partShader.setUniform(gMultColor, part.tint);
    partShader.setUniform(gScreenColor, part.screenTint);

    texture.bind();

    enum vertexCount = 4;
    float[vertexCount * 2] vertexSoa;
    auto vx = vertexSoa[0 .. vertexCount];
    auto vy = vertexSoa[vertexCount .. $];
    vx[] = [-texWidthP, texWidthP, -texWidthP, texWidthP];
    vy[] = [-texHeightP, -texHeightP, texHeightP, texHeightP];
    float[vertexCount * 2] uvSoa;
    auto ux = uvSoa[0 .. vertexCount];
    auto uy = uvSoa[vertexCount .. $];
    ux[] = [0f, 1f, 0f, 1f];
    uy[] = [0f, 0f, 1f, 1f];
    auto laneBytes = cast(ptrdiff_t)vertexCount * float.sizeof;

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, quadVertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, vertexSoa.length * float.sizeof, vertexSoa.ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)0);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, quadVertexBuffer);
    glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)laneBytes);

    glEnableVertexAttribArray(2);
    glBindBuffer(GL_ARRAY_BUFFER, quadUvBuffer);
    glBufferData(GL_ARRAY_BUFFER, uvSoa.length * float.sizeof, uvSoa.ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)0);

    glEnableVertexAttribArray(3);
    glBindBuffer(GL_ARRAY_BUFFER, quadUvBuffer);
    glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)laneBytes);

    glDisableVertexAttribArray(4);
    glVertexAttrib1f(4, 0);
    glDisableVertexAttribArray(5);
    glVertexAttrib1f(5, 0);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, quadElementBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, 6*ushort.sizeof, (cast(ushort[])[
        0u, 1u, 2u,
        2u, 1u, 3u
    ]).ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
}

void oglDrawTextureAtPosition(Texture texture, vec2 position, float opacity = 1, vec3 color = vec3(1, 1, 1), vec3 screenColor = vec3(0, 0, 0)) {
    if (texture is null) return;

    vec2 texSize = vec2(cast(float)texture.width(), cast(float)texture.height());
    vec2 halfSize = texSize * 0.5f;
    rect area = rect(
        position.x - halfSize.x,
        position.y - halfSize.y,
        texSize.x,
        texSize.y
    );

    oglDrawTextureAtRect(texture, area, rect(0, 0, 1, 1), opacity, color, screenColor);
}

void oglDrawTextureAtRect(Texture texture, rect area, rect uvs = rect(0, 0, 1, 1), float opacity = 1, vec3 color = vec3(1, 1, 1), vec3 screenColor = vec3(0, 0, 0), Shader s = null, Camera cam = null) {
    if (texture is null) return;

    incDrawableBindVAO();
    ensureQuadBuffers();

    if (!s) s = partShader;
    if (!cam) cam = inGetCamera();
    s.use();
    s.setUniform(s.getUniformLocation("mvp"),
        cam.matrix *
        mat4.scaling(1, 1, 1)
    );
    auto offsetLocation = s.getUniformLocation("offset");
    if (offsetLocation != -1) {
        s.setUniform(offsetLocation, vec2(0, 0));
    }
    s.setUniform(s.getUniformLocation("opacity"), opacity);
    s.setUniform(s.getUniformLocation("multColor"), color);
    s.setUniform(s.getUniformLocation("screenColor"), screenColor);

    texture.bind();

    enum vertexCount = 4;
    float[vertexCount * 2] vertexSoa;
    auto vx = vertexSoa[0 .. vertexCount];
    auto vy = vertexSoa[vertexCount .. $];
    vx[] = [area.left, area.right, area.left, area.right];
    vy[] = [area.top, area.top, area.bottom, area.bottom];
    float[vertexCount * 2] uvSoa;
    auto ux = uvSoa[0 .. vertexCount];
    auto uy = uvSoa[vertexCount .. $];
    ux[] = [uvs.x, uvs.width, uvs.x, uvs.width];
    uy[] = [uvs.y, uvs.y, uvs.height, uvs.height];
    auto laneBytes = cast(ptrdiff_t)vertexCount * float.sizeof;

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, quadVertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, vertexSoa.length * float.sizeof, vertexSoa.ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)0);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, quadVertexBuffer);
    glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)laneBytes);

    glEnableVertexAttribArray(2);
    glBindBuffer(GL_ARRAY_BUFFER, quadUvBuffer);
    glBufferData(GL_ARRAY_BUFFER, uvSoa.length * float.sizeof, uvSoa.ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(2, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)0);

    glEnableVertexAttribArray(3);
    glBindBuffer(GL_ARRAY_BUFFER, quadUvBuffer);
    glVertexAttribPointer(3, 1, GL_FLOAT, GL_FALSE, 0, cast(void*)laneBytes);

    glDisableVertexAttribArray(4);
    glVertexAttrib1f(4, 0);
    glDisableVertexAttribArray(5);
    glVertexAttrib1f(5, 0);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, quadElementBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, 6*ushort.sizeof, (cast(ushort[])[
        0u, 1u, 2u,
        2u, 1u, 3u
    ]).ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glDisableVertexAttribArray(2);
    glDisableVertexAttribArray(3);
}
