module nijilive.core.render.immediate;

import nijilive.core.texture : Texture;
import nijilive.core.nodes.part : Part;
import nijilive.math : vec2, vec3, rect;
import nijilive.core.shader : Shader;
import nijilive.math.camera : Camera;
version(InDoesRender) import nijilive.core.runtime_state : currentRenderBackend;

version(InDoesRender) {
    void inDrawTextureAtPart(Texture texture, Part part) {
        if (texture is null || part is null) return;
        auto backend = currentRenderBackend();
        if (backend is null) return;
        backend.drawTextureAtPart(texture, part);
    }

    void inDrawTextureAtPosition(Texture texture, vec2 position, float opacity = 1,
                                 vec3 color = vec3(1, 1, 1), vec3 screenColor = vec3(0, 0, 0)) {
        if (texture is null) return;
        auto backend = currentRenderBackend();
        if (backend is null) return;
        backend.drawTextureAtPosition(texture, position, opacity, color, screenColor);
    }

    void inDrawTextureAtRect(Texture texture, rect area, rect uvs = rect(0, 0, 1, 1),
                             float opacity = 1, vec3 color = vec3(1, 1, 1),
                             vec3 screenColor = vec3(0, 0, 0), Shader shader = null,
                             Camera cam = null) {
        if (texture is null) return;
        auto backend = currentRenderBackend();
        if (backend is null) return;
        backend.drawTextureAtRect(texture, area, uvs, opacity, color, screenColor, shader, cam);
    }
} else {
    void inDrawTextureAtPart(Texture, Part) {}
    void inDrawTextureAtPosition(Texture, vec2, float opacity = 1, vec3 color = vec3(1, 1, 1),
                                 vec3 screenColor = vec3(0, 0, 0)) {}
    void inDrawTextureAtRect(Texture, rect, rect uvs = rect(0, 0, 1, 1), float opacity = 1,
                             vec3 color = vec3(1, 1, 1), vec3 screenColor = vec3(0, 0, 0),
                             Shader shader = null, Camera cam = null) {}
}
