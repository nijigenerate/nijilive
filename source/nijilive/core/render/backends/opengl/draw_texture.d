module nijilive.core.render.backends.opengl.draw_texture;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core;
import nijilive.math;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.texture : Texture;
import nijilive.core.nodes.part : Part;
import nijilive.core.render.backends.opengl.part : partShader, gopacity, gMultColor,
    gScreenColor, mvp, sVertexBuffer, sUVBuffer, sElementBuffer;

void oglDrawTextureAtPart(Texture texture, Part part) {
    if (texture is null || part is null) return;

    const float texWidthP = texture.width()/2;
    const float texHeightP = texture.height()/2;

    incDrawableBindVAO();

    partShader.use();
    partShader.setUniform(mvp,
        inGetCamera().matrix *
        mat4.translation(vec3(part.transform.matrix() * vec4(1, 1, 1, 1)))
    );
    partShader.setUniform(gopacity, part.opacity);
    partShader.setUniform(gMultColor, part.tint);
    partShader.setUniform(gScreenColor, part.screenTint);

    texture.bind();

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, sVertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, 4*vec2.sizeof, [
        -texWidthP, -texHeightP,
        texWidthP, -texHeightP,
        -texWidthP, texHeightP,
        texWidthP, texHeightP,
    ].ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, sUVBuffer);
    glBufferData(GL_ARRAY_BUFFER, 4*vec2.sizeof, [
        0, 0,
        1, 0,
        0, 1,
        1, 1,
    ].ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sElementBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, 6*ushort.sizeof, (cast(ushort[])[
        0u, 1u, 2u,
        2u, 1u, 3u
    ]).ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
}

void oglDrawTextureAtPosition(Texture texture, vec2 position, float opacity = 1, vec3 color = vec3(1, 1, 1), vec3 screenColor = vec3(0, 0, 0)) {
    if (texture is null) return;

    const float texWidthP = texture.width()/2;
    const float texHeightP = texture.height()/2;

    incDrawableBindVAO();

    partShader.use();
    partShader.setUniform(mvp,
        inGetCamera().matrix *
        mat4.scaling(1, 1, 1) *
        mat4.translation(vec3(position, 0))
    );
    partShader.setUniform(gopacity, opacity);
    partShader.setUniform(gMultColor, color);
    partShader.setUniform(gScreenColor, screenColor);

    texture.bind();

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, sVertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, 4*vec2.sizeof, [
        -texWidthP, -texHeightP,
        texWidthP, -texHeightP,
        -texWidthP, texHeightP,
        texWidthP, texHeightP,
    ].ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, sUVBuffer);
    glBufferData(GL_ARRAY_BUFFER, 4*vec2.sizeof, [
        0, 0,
        1, 0,
        0, 1,
        1, 1,
    ].ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sElementBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, 6*ushort.sizeof, (cast(ushort[])[
        0u, 1u, 2u,
        2u, 1u, 3u
    ]).ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
}

void oglDrawTextureAtRect(Texture texture, rect area, rect uvs = rect(0, 0, 1, 1), float opacity = 1, vec3 color = vec3(1, 1, 1), vec3 screenColor = vec3(0, 0, 0), Shader s = null, Camera cam = null) {
    if (texture is null) return;

    incDrawableBindVAO();

    if (!s) s = partShader;
    if (!cam) cam = inGetCamera();
    s.use();
    s.setUniform(s.getUniformLocation("mvp"),
        cam.matrix *
        mat4.scaling(1, 1, 1)
    );
    s.setUniform(s.getUniformLocation("opacity"), opacity);
    s.setUniform(s.getUniformLocation("multColor"), color);
    s.setUniform(s.getUniformLocation("screenColor"), screenColor);

    texture.bind();

    glEnableVertexAttribArray(0);
    glBindBuffer(GL_ARRAY_BUFFER, sVertexBuffer);
    glBufferData(GL_ARRAY_BUFFER, 4*vec2.sizeof, [
        area.left, area.top,
        area.right, area.top,
        area.left, area.bottom,
        area.right, area.bottom,
    ].ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, null);

    glEnableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, sUVBuffer);
    glBufferData(GL_ARRAY_BUFFER, 4*vec2.sizeof, [
        uvs.x, uvs.y,
        uvs.width, uvs.y,
        uvs.x, uvs.height,
        uvs.width, uvs.height,
    ].ptr, GL_STATIC_DRAW);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, null);

    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, sElementBuffer);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, 6*ushort.sizeof, (cast(ushort[])[
        0u, 1u, 2u,
        2u, 1u, 3u
    ]).ptr, GL_STATIC_DRAW);
    glDrawElements(GL_TRIANGLES, 6, GL_UNSIGNED_SHORT, null);

    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
}
