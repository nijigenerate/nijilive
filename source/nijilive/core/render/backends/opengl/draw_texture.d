module nijilive.core.render.backends.opengl.draw_texture;

version (InDoesRender):

import bindbc.opengl;
import nijilive.core;
import nijilive.math;
import nijilive.core.nodes.drawable : incDrawableBindVAO;
import nijilive.core.texture : Texture;
import nijilive.core.nodes.part : Part;
import nijilive.core.render.backends.opengl.part : partShader, gopacity, gMultColor,
    gScreenColor, mvp, offset, sVertexBuffer, sUVBuffer, sElementBuffer;

void oglDrawTextureAtPart(Texture texture, Part part) {
    if (texture is null || part is null) return;

    const float texWidthP = texture.width()/2;
    const float texHeightP = texture.height()/2;

    incDrawableBindVAO();

    mat4 modelMatrix = part.immediateModelMatrix();
    mat4 puppetMatrix = (!part.ignorePuppet && part.puppet !is null)
        ? part.puppet.transform.matrix
        : mat4.identity;

    partShader.use();
    partShader.setUniform(mvp,
        inGetCamera().matrix *
        puppetMatrix *
        modelMatrix
    );
    partShader.setUniform(offset, part.getMesh().origin);
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
